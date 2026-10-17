// VMHost: the minimal QEMU-side VM operation table for the aemu snapshot path.
//
// Why this file exists
// --------------------
// `android::snapshot::Snapshotter::save()/load()` do not talk to QEMU directly:
// they call through `mVmOperations`, a table of function pointers
// (`QAndroidVmOperations` in host-common/vm_operations.h). In the official
// emulator that table is filled in by `android-qemu2-glue/qemu-vm-operations-impl.cpp`
// — a file we deliberately do not build (it drags in gRPC, the emulator
// console and the whole frontend). Without it the table is all NULL and
// `Snapshotter::save()` dies on the first call (we measured SIGSEGV pc=0).
//
// So this file supplies that table. But the official frontend also registers a
// **second pair** of things, and both are needed:
//
//   1) QEMUSnapshotCallbacks — qemu-vm-operations-impl.cpp:794
//      `set_snapshot_callbacks()`. aemu's Saver/Loader objects are created
//      from these callbacks.
//   2) QEMUFileHooks + RAM address translation — qemu-vm-operations-impl.cpp:667
//      `sSaveHooks`, :731 `sLoadHooks`, :784 `tcg_gpa2hva`. QEMU's savevm hands
//      the RAM stream to aemu's RamSaver/RamLoader only through these hooks
//      (qemu_savevm() does `qemu_file_set_hooks(f, sSaveFileHooks)`,
//      migration/savevm.c:2509; `sSaveFileHooks` is what
//      `migrate_set_file_hooks()` fills in, migration/savevm.c:1359).
//
// We had (1) only at first, and `Snapshotter::save()` then returned Ok after
// ~100ms with nothing on disk: `mVmOperations.snapshotSave()` reaches QEMU but
// QEMU never gives the RAM to aemu, so the Saver is never created on the save
// path and Snapshotter.cpp falls through to its "In unit tests, we don't have
// a saver, so trivially succeed." branch. That is also why the C ABI bridge
// (vmhost_snapshot_glue.cpp) now re-checks the result on disk.
//
// QEMU side symbols come from QEMU's **real headers** (build_qemu_aosp.sh adds
// -I$SRC_DIR -I$SRC_DIR/include and the sysroot glib cflags for this one TU):
//   qemu/osdep.h          QEMU's mandatory prelude (pulls in glib)
//   exec/cpu-common.h     qemu_ram_block_by_name / qemu_ram_pagesize /
//                         qemu_ram_foreach_migrate_block_with_file_info /
//                         cpu_physical_memory_get_addr / ram_size
//   migration/qemu-file.h QEMUFileHooks / migrate_set_file_hooks /
//                         RAM_CONTROL_* / RAM_SAVE_FLAG_HOOK / qemu_put_be64 /
//                         RAM_SAVE_CONTROL_DELAYED
//   migration/snapshot.h  save_snapshot / load_snapshot
//   sysemu/cpus.h         smp_cores / smp_threads
//   sysemu/sysemu.h       smp_cpus / QEMUSnapshotCallbacks / vm_start /
//                         runstate_is_running / qemu_set_snapshot_callbacks /
//                         qemu_set_snapshot_protobuf / qemu_set_ram_load_callback
//   qapi/error.h          Error / error_get_pretty / error_free
//   qemu-common.h         tcg_enabled()
// aemu side:
//   host-common/vm_operations.h     SnapshotCallbacks / SnapshotRamCallbacks /
//                                   VmConfiguration
//   snapshot/common.h               SnapshotRamBlock（vm_operations.h 只有前向声明）
//   android/snapshot/MemoryWatch.h  set_address_translation_funcs / gpa2hva_call
//   android/snapshot/PathUtils.h    getSnapshotBaseDir()
//   aemu/base/files/PathUtils.h     android::base::PathUtils::relativeTo
//
// 注意：glib 在 C++ 下会 include <type_traits> 之类的 C++ 头，那必须发生在
// extern "C" 之外（否则 "templates must have C++ linkage"），所以先预包含
// 标准头，再用 extern "C" 包 QEMU 头（官方 qemu-vm-operations-impl.cpp 也是
// 用 extern "C" 包的）。

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <set>
#include <string>
#include <type_traits>
#include <utility>

extern "C" {
#include "qemu/osdep.h"

#include "exec/cpu-common.h"
#include "exec/memory-remap.h"   // qemu_user_backed_ram_map/unmap + USER_BACKED_RAM_FLAGS_*
#include "migration/qemu-file.h"
#include "migration/snapshot.h"
#include "qapi/error.h"
#include "qemu-common.h"
#include "sysemu/cpus.h"
#include "sysemu/sysemu.h"
}

#include "android/snapshot/MemoryWatch.h"
#include "android/snapshot/PathUtils.h"
#include "android/snapshot/Snapshotter.h"
#include "aemu/base/files/PathUtils.h"
#include "host-common/vm_operations.h"
#include "host-common/window_agent.h"
#include "snapshot/common.h"

namespace {

// Set by Snapshotter when it wants progress/error callbacks. The default
// callbacks only feed the (absent) emulator console, so storing them is
// enough — nothing else consumes them on this integration path.
const SnapshotCallbacks* g_snapshotCallbacks = nullptr;
void* g_snapshotCallbacksOpaque = nullptr;
bool g_skipSnapshotSave = false;

// ---- aemu <-> QEMU snapshot callback adapters ----------------------------
//
// QEMU calls these (see the QEMUSnapshotCallbacks registration below); each one
// forwards to the aemu Snapshotter, which is where the Saver/Loader objects are
// created.

// aemu 的 SnapshotCallbacks 是按操作分组的：ops[SNAPSHOT_SAVE/LOAD/DEL]，
// 每组四个回调。QEMU 侧则分 savevm/loadvm/delvm 三个槽 —— 一一对应转发。
template <int op>
int qemu_cb_on_start(const char* name) {
    if (g_snapshotCallbacks && g_snapshotCallbacks->ops[op].onStart) {
        return g_snapshotCallbacks->ops[op].onStart(g_snapshotCallbacksOpaque,
                                                    name);
    }
    return 0;
}

template <int op>
void qemu_cb_on_end(const char* name, int res) {
    if (g_snapshotCallbacks && g_snapshotCallbacks->ops[op].onEnd) {
        g_snapshotCallbacks->ops[op].onEnd(g_snapshotCallbacksOpaque, name,
                                           res);
    }
}

template <int op>
void qemu_cb_on_quick_fail(const char* name, int res) {
    if (g_snapshotCallbacks && g_snapshotCallbacks->ops[op].onQuickFail) {
        g_snapshotCallbacks->ops[op].onQuickFail(g_snapshotCallbacksOpaque,
                                                 name, res);
    }
}

template <int op>
bool qemu_cb_is_canceled(const char* name) {
    if (g_snapshotCallbacks && g_snapshotCallbacks->ops[op].isCanceled) {
        return g_snapshotCallbacks->ops[op].isCanceled(
                g_snapshotCallbacksOpaque, name);
    }
    return false;
}

// 模板参数是 int（C++17 里可以当非类型模板参数用），这里取具体实例的地址。
// QEMUCallbackSet 就是 include/sysemu/sysemu.h:98-104 里那个结构。
QEMUCallbackSet make_qemu_callback_set(int op) {
    QEMUCallbackSet set = {};
    switch (op) {
        case SNAPSHOT_SAVE:
            set = {qemu_cb_on_start<SNAPSHOT_SAVE>, qemu_cb_on_end<SNAPSHOT_SAVE>,
                   qemu_cb_on_quick_fail<SNAPSHOT_SAVE>,
                   qemu_cb_is_canceled<SNAPSHOT_SAVE>};
            break;
        case SNAPSHOT_LOAD:
            set = {qemu_cb_on_start<SNAPSHOT_LOAD>, qemu_cb_on_end<SNAPSHOT_LOAD>,
                   qemu_cb_on_quick_fail<SNAPSHOT_LOAD>,
                   qemu_cb_is_canceled<SNAPSHOT_LOAD>};
            break;
        default:
            set = {qemu_cb_on_start<SNAPSHOT_DEL>, qemu_cb_on_end<SNAPSHOT_DEL>,
                   qemu_cb_on_quick_fail<SNAPSHOT_DEL>,
                   qemu_cb_is_canceled<SNAPSHOT_DEL>};
            break;
    }
    return set;
}

// ---- QEMUFileHooks：savevm 的 RAM 流 → aemu RamSaver / RamLoader ----------
//
// 照抄 android-qemu2-glue/qemu-vm-operations-impl.cpp:667-788（那三个 hook
// 在官方是 lambda，这里写成同签名的函数，别的一个字没改；HVF/HAX/WHPX/AEHD/
// KVM 分支在本移植里不存在，只有 TCG）。没有这一段，QEMU 的 savevm 会把 RAM
// 当成普通流写进自己的 QEMUFile，aemu 的 RamSaver 永远收不到页。

// sSaveHooks.before_ram_iterate（impl:669-703）。每轮 RAM 迭代前写一个
// RAM_SAVE_FLAG_HOOK 标记；RAM_CONTROL_SETUP 时把所有可迁移 RAM block 注册给
// aemu 的 Saver。
//
// VMHOST_SKIP_ANON_RAMBLOCK：空名字的匿名 user-backed RAMBlock
// （gfxstream/gralloc 的临时共享区）**不注册给 aemu**。它们的 idstr 是空的，
// 恢复时 `qemu_ram_block_by_name("")` 必然查不到，QEMU 会直接
// "Unknown ramblock \"\"" 终止整次 load；而且它们在恢复进程里也未必存在。
// 两边都不认它们，页面在 vmhost_ram_save_page 里被丢弃。这里把"注册过的
// block offset"记下来，供 save_page 判断。
static std::set<int64_t> g_registeredRamBlockOffsets;

int vmhost_ram_save_before_iterate(QEMUFile* f, void*, uint64_t flags, void*) {
    std::fprintf(stderr, "VMHOSTSNAP before_iterate flags=%llu\n",
                 (unsigned long long)flags);
    qemu_put_be64(f, RAM_SAVE_FLAG_HOOK);
    if (flags != RAM_CONTROL_SETUP) {
        return 0;
    }
    g_registeredRamBlockOffsets.clear();
    qemu_ram_foreach_migrate_block_with_file_info(
            [](const char* block_name, void* host_addr, ram_addr_t offset,
               ram_addr_t length, uint32_t block_flags, const char* path,
               bool readonly, void*) -> int {
                if (!block_name || !block_name[0]) {
                    std::fprintf(stderr,
                                 "VMHOST_SKIP_ANON_RAMBLOCK offset=%llu "
                                 "len=%llu（空名字，不进快照）\n",
                                 (unsigned long long)offset,
                                 (unsigned long long)length);
                    return 0;
                }
                g_registeredRamBlockOffsets.insert((int64_t)offset);
                // 官方把路径相对化到快照目录，便于快照跨目录/跨进程恢复
                // （impl:677-679）。
                const std::string relativePath =
                        android::base::PathUtils::relativeTo(
                                android::snapshot::getSnapshotBaseDir(),
                                path ? path : "");
                SnapshotRamBlock block = {
                        block_name,
                        (int64_t)offset,
                        (uint8_t*)host_addr,
                        (int64_t)length,
                        0 /* page size，下面补 */,
                        block_flags,
                        relativePath,
                        readonly,
                        false /* needRestoreFromRamFile */};
                RAMBlock* const qemuBlock = qemu_ram_block_by_name(block_name);
                if (!qemuBlock) {
                    std::fprintf(stderr,
                                 "VMHOSTSNAP ram save: no RAMBlock named '%s'\n",
                                 block_name ? block_name : "(null)");
                    return 0;
                }
                block.pageSize = (int32_t)qemu_ram_pagesize(qemuBlock);
                if (g_snapshotCallbacks &&
                    g_snapshotCallbacks->ramOps.registerBlock) {
                    g_snapshotCallbacks->ramOps.registerBlock(
                            g_snapshotCallbacksOpaque, SNAPSHOT_SAVE, &block);
                }
                return 0;
            },
            nullptr);
    return 0;
}

// sSaveHooks.after_ram_iterate（impl:705-711）。RAM_CONTROL_FINISH 时通知
// aemu 收尾（RamSaver::join + 落盘）。
int vmhost_ram_save_after_iterate(QEMUFile*, void*, uint64_t flags, void*) {
    std::fprintf(stderr, "VMHOSTSNAP after_iterate flags=%llu\n",
                 (unsigned long long)flags);
    if (flags == RAM_CONTROL_FINISH && g_snapshotCallbacks &&
        g_snapshotCallbacks->ramOps.savingComplete) {
        const int rc = g_snapshotCallbacks->ramOps.savingComplete(
                g_snapshotCallbacksOpaque);
        std::fprintf(stderr, "VMHOSTSNAP savingComplete rc=%d\n", rc);
        return rc;
    }
    return 0;
}

// sSaveHooks.save_page（impl:715-728）。每一页交给 aemu，并返回
// RAM_SAVE_CONTROL_DELAYED：QEMU 不再自己写这一页，位置更新由 aemu 负责。
size_t vmhost_ram_save_page(QEMUFile*, void*, ram_addr_t block_offset,
                            ram_addr_t offset, size_t size,
                            uint64_t* bytes_sent) {
    static uint64_t s_pageCount = 0;
    if ((++s_pageCount % 20000) == 0) {
        std::fprintf(stderr, "VMHOSTSNAP save_page n=%llu size=%llu\n",
                     (unsigned long long)s_pageCount,
                     (unsigned long long)size);
    }
    if (g_registeredRamBlockOffsets.find((int64_t)block_offset) ==
        g_registeredRamBlockOffsets.end()) {
        /* 匿名块：QEMU 照样会迭代它的页，这里直接丢掉 —— 既不进 aemu 的
           ram.bin 索引，也不写进迁移流（返回 DELAYED 且 bytes_sent=size
           就是"这页我处理了"）。 */
        *bytes_sent = size;
        return size_t(RAM_SAVE_CONTROL_DELAYED);
    }
    if (g_snapshotCallbacks && g_snapshotCallbacks->ramOps.savePage) {
        g_snapshotCallbacks->ramOps.savePage(g_snapshotCallbacksOpaque,
                                             (int64_t)block_offset,
                                             (int64_t)offset, (int32_t)size);
    }
    // 必须把 bytes_sent 设成非 0，否则 QEMU 会自己再存一遍这一页。
    *bytes_sent = size;
    return size_t(RAM_SAVE_CONTROL_DELAYED);
}

// sLoadHooks.hook_ram_load（impl:737-782）。RAM_CONTROL_BLOCK_REG 时把流里
// 的 block id 对上 QEMU 的 RAMBlock 并注册给 aemu 的 Loader；
// RAM_CONTROL_HOOK 时让 aemu 开始（可能延迟的）装载。
int vmhost_ram_load_hook(QEMUFile*, void*, uint64_t flags, void* data) {
    switch (flags) {
        case RAM_CONTROL_BLOCK_REG: {
            SnapshotRamBlock block = {};
            block.id = static_cast<const char*>(data);
            qemu_ram_foreach_migrate_block_with_file_info(
                    [](const char* block_name, void* host_addr,
                       ram_addr_t offset, ram_addr_t length,
                       uint32_t block_flags, const char* path, bool readonly,
                       void* opaque) -> int {
                        auto* out = static_cast<SnapshotRamBlock*>(opaque);
                        if (out->id != block_name) {
                            return 0;
                        }
                        // 同 save 侧：路径相对化（impl:753-756）。
                        out->startOffset = offset;
                        out->hostPtr = (uint8_t*)host_addr;
                        out->totalSize = length;
                        out->flags = block_flags;
                        out->path = android::base::PathUtils::relativeTo(
                                android::snapshot::getSnapshotBaseDir(),
                                path ? path : "");
                        out->readonly = readonly;
                        out->needRestoreFromRamFile = false;
                        return 1;  // 命中即停
                    },
                    &block);

            RAMBlock* const qemuBlock = qemu_ram_block_by_name(block.id.data());
            if (!qemuBlock) {
                std::fprintf(stderr,
                             "VMHOSTSNAP ram load: no RAMBlock named '%s'\n",
                             block.id.c_str());
                break;
            }
            block.pageSize = (int32_t)qemu_ram_pagesize(qemuBlock);
            if (g_snapshotCallbacks &&
                g_snapshotCallbacks->ramOps.registerBlock) {
                g_snapshotCallbacks->ramOps.registerBlock(
                        g_snapshotCallbacksOpaque, SNAPSHOT_LOAD, &block);
            }
            break;
        }
        case RAM_CONTROL_HOOK:
            if (g_snapshotCallbacks &&
                g_snapshotCallbacks->ramOps.startLoading) {
                return g_snapshotCallbacks->ramOps.startLoading(
                        g_snapshotCallbacksOpaque);
            }
            break;
        default:
            break;
    }
    return 0;
}

const QEMUFileHooks sSaveHooks = {
        vmhost_ram_save_before_iterate,  // before_ram_iterate
        vmhost_ram_save_after_iterate,   // after_ram_iterate
        nullptr,                         // hook_ram_load（save 方向不用）
        vmhost_ram_save_page,            // save_page
};

const QEMUFileHooks sLoadHooks = {
        nullptr,               // before_ram_iterate
        nullptr,               // after_ram_iterate
        vmhost_ram_load_hook,  // hook_ram_load
        nullptr,               // save_page
};

// 官方 tcg_gpa2hva（impl:784-788）：GPA → HVA，找不到就把 *found 留 false。
void* tcg_gpa2hva(uint64_t gpa, bool* found) {
    void* res = cpu_physical_memory_get_addr(gpa);
    if (res != nullptr) {
        *found = true;
    }
    return res;
}

// qemu_set_ram_load_callback 的回调（impl:805-808）：QEMU 侧延迟装载 RAM 时
// 把宿主指针交回 aemu 的 RamLoader。
void vmhost_qemu_ram_load_callback(void* hostRam, uint64_t size) {
    if (g_snapshotCallbacks && g_snapshotCallbacks->ramOps.loadRam) {
        g_snapshotCallbacks->ramOps.loadRam(g_snapshotCallbacksOpaque, hostRam,
                                            size);
    }
}

void vmhost_report_error(LineConsumerCallback errConsumer,
                         void* opaque,
                         const char* message) {
    if (errConsumer && message) {
        errConsumer(opaque, message, static_cast<int>(std::strlen(message)));
    }
}

// ---- snapshot operations -------------------------------------------------

bool vmhost_snapshot_save(const char* name, void* opaque,
                          LineConsumerCallback errConsumer) {
    // save_snapshot/load_snapshot 的原型见 include/migration/snapshot.h:18-19。
    Error* err = nullptr;
    const int rc = save_snapshot(name, &err);
    if (rc != 0) {
        char message[512];
        std::snprintf(message, sizeof(message),
                      "save_snapshot('%s') failed: %s\n", name,
                      err ? error_get_pretty(err) : "unknown error");
        vmhost_report_error(errConsumer, opaque, message);
        if (err) {
            error_free(err);
        }
        return false;
    }
    return true;
}

bool vmhost_snapshot_load(const char* name, void* opaque,
                          LineConsumerCallback errConsumer) {
    Error* err = nullptr;
    const int rc = load_snapshot(name, &err);
    if (rc != 0) {
        char message[512];
        std::snprintf(message, sizeof(message),
                      "load_snapshot('%s') failed: %s\n", name,
                      err ? error_get_pretty(err) : "unknown error");
        vmhost_report_error(errConsumer, opaque, message);
        if (err) {
            error_free(err);
        }
        return false;
    }
    return true;
}

// We keep no snapshot catalogue of our own: the only snapshot we ever deal
// with is "default_boot", and its presence is tracked by the engine via
// <dataDir>/snapshot.state. Listing/deleting through this table is therefore
// not implemented; the engine deletes the directory itself when a snapshot is
// rejected.
bool vmhost_snapshot_list(void*, LineConsumerCallback, LineConsumerCallback) {
    return false;
}

bool vmhost_snapshot_delete(const char*, void* opaque,
                            LineConsumerCallback errConsumer) {
    vmhost_report_error(errConsumer, opaque,
                        "snapshot delete is handled by the engine\n");
    return false;
}

bool vmhost_snapshot_remap(bool, void*, LineConsumerCallback) { return false; }
bool vmhost_snapshot_export(const char*, const char*, void*,
                            LineConsumerCallback) {
    return false;
}
bool vmhost_snapshot_last_loaded(void*, LineConsumerCallback,
                                 LineConsumerCallback) {
    return false;
}

void vmhost_set_snapshot_callbacks(void* opaque,
                                   const SnapshotCallbacks* callbacks) {
    g_snapshotCallbacksOpaque = opaque;
    g_snapshotCallbacks = callbacks;

    // 官方在同一个函数里注册**四件东西**（qemu-vm-operations-impl.cpp:794-854），
    // 这里按同样的顺序来：
    //   1) QEMUSnapshotCallbacks —— 把 aemu 侧的回调转发给 QEMU。QEMU 的
    //      save_snapshot() 会在开始时调 on_start，aemu 的 Saver/Loader 就是
    //      在那一步被创建出来的；不转发的话 Snapshotter 因为 mSaver == nullptr
    //      而直接返回 Ok（我们实测：0.1 秒"成功"、磁盘上什么都没有）。
    //   2) qemu_set_ram_load_callback —— QEMU 延迟装载 RAM 时把宿主指针交回
    //      aemu 的 RamLoader（impl:805-808）。
    //   3) set_address_translation_funcs —— GPA↔HVA。官方按加速器分支选
    //      hvf/hax/whpx/aehd/kvm 的实现，我们只有 TCG，等价于它的 default
    //      分支 set_address_translation_funcs(0, tcg_gpa2hva)（impl:835-837）。
    //   4) migrate_set_file_hooks —— (2) 那对 QEMUFileHooks，RAM 流靠它进
    //      aemu（impl:840）。缺了它 QEMU 会把 RAM 写进自己的流，aemu 一个字节
    //      都收不到。
    if (!opaque || !callbacks) {
        // 官方清空分支（impl:796-800）。
        qemu_set_snapshot_callbacks(nullptr);
        qemu_set_ram_load_callback(nullptr);
        migrate_set_file_hooks(nullptr, nullptr);
        return;
    }

    static const QEMUSnapshotCallbacks kQemuCallbacks = [] {
        QEMUSnapshotCallbacks cbs = {
            make_qemu_callback_set(SNAPSHOT_SAVE),
            make_qemu_callback_set(SNAPSHOT_LOAD),
            make_qemu_callback_set(SNAPSHOT_DEL),
        };
        return cbs;
    }();
    qemu_set_snapshot_callbacks(&kQemuCallbacks);
    qemu_set_ram_load_callback(vmhost_qemu_ram_load_callback);
    set_address_translation_funcs(nullptr /* hva2gpa：官方同样传 0 */,
                                  tcg_gpa2hva);
    migrate_set_file_hooks(&sSaveHooks, &sLoadHooks);
}

// The "compatible" protobuf is only consumed by the emulator frontend to
// advertise snapshot compatibility to Studio; nothing here reads it.
void vmhost_set_snapshot_protobuf(void* pb) {
    // QEMU 侧用它把 compatible.pb 写进快照；交给 QEMU 自己管理即可。
    qemu_set_snapshot_protobuf(pb);
}

void vmhost_set_failure_reason(const char* name, int reason) {
    std::fprintf(stderr, "VMHOSTSNAP failure reason name=%s reason=%d\n",
                 name ? name : "(null)", reason);
}

void vmhost_set_exiting(void) {}

void vmhost_set_skip_snapshot_save(bool used) { g_skipSnapshotSave = used; }
bool vmhost_is_snapshot_save_skipped(void) { return g_skipSnapshotSave; }

// ---- VM control ----------------------------------------------------------

bool vmhost_vm_is_running(void) { return runstate_is_running(); }
bool vmhost_vm_start(void) {
    vm_start();
    return true;
}

// Stop/reset/shutdown are driven by the engine through QMP (`stop`) before it
// asks for a snapshot, so these do not need to do anything here.
bool vmhost_vm_stop(void) { return true; }
bool vmhost_vm_pause(void) { return true; }
bool vmhost_vm_resume(void) { return true; }
void vmhost_vm_reset(void) {}
void vmhost_vm_shutdown(void) {}

// ---- RAM / host memory ---------------------------------------------------

// The address-space devices used by gfxstream are plugged by QEMU's own
// snapshot hooks (the VMHOST_MIG_ZERO_LOAD messages seen on the load path), so
// the frontend-side mapping callbacks are intentionally not used here.
// goldfish_pipe / 地址空间设备在恢复时要把快照里记录的 guest 缓冲区"插回"宿主
// 地址空间（goldfish_pipe_load_v2 → map_guest_buffer）。官方前端就是在这一步调
// qemu_user_backed_ram_map/unmap；我们一开始写成 no-op，结果 load 直接报
//   error while loading state for instance 0x0 of device 'goldfish_pipe'
//   Error -5 while loading VM state
void vmhost_map_user_backed_ram(uint64_t gpa, void* hva, uint64_t size) {
    qemu_user_backed_ram_map(
            gpa, hva, size,
            USER_BACKED_RAM_FLAGS_READ | USER_BACKED_RAM_FLAGS_WRITE);
}

void vmhost_unmap_user_backed_ram(uint64_t gpa, uint64_t size) {
    qemu_user_backed_ram_unmap(gpa, size);
}

// 官方 physical_memory_get_addr（qemu-vm-operations-impl.cpp:921-929）：走上面
// set_address_translation_funcs 装进去的 gpa2hva（TCG 下就是 tcg_gpa2hva），
// 没装上或者没找到就返回 nullptr。
void* vmhost_physical_memory_get_addr(uint64_t gpa) {
    if (!gpa2hva_call) {
        return nullptr;
    }
    bool found = false;
    void* res = gpa2hva_call(gpa, &found);
    return found ? res : nullptr;
}

uint64_t vmhost_hostmem_register(const struct MemEntry*) { return 0; }
void vmhost_hostmem_unregister(uint64_t) {}
struct HostmemEntry vmhost_hostmem_get_info(uint64_t) {
    struct HostmemEntry entry = {};
    return entry;
}

// 快照兼容性校验用（官方 get_vm_config，qemu-vm-operations-impl.cpp:856-872）：
// 存/取两侧的 CPU 核数与 RAM 大小必须逐项相同，否则 Snapshotter 判不兼容。
// 官方按加速器填 hypervisorType；我们只有 TCG，对应它 tcg_enabled() 那一支。
void vmhost_get_vm_configuration(VmConfiguration* out) {
    if (!out) {
        return;
    }
    std::memset(out, 0, sizeof(*out));
    out->numberOfCpuCores = smp_cpus * smp_cores * smp_threads;
    out->ramSizeBytes = static_cast<int64_t>(ram_size);
    out->hypervisorType = tcg_enabled() ? HV_NONE : HV_UNKNOWN;
}

EmuRunState vmhost_get_run_state(void) {
    return runstate_is_running() ? QEMU_RUN_STATE_RUNNING : QEMU_RUN_STATE_PAUSED;
}

// ---- audio / display -----------------------------------------------------

// Snapshotter only ever calls the window agent for one thing: reporting an
// error to the user (Snapshotter.cpp:535 -> showMessage). Everything else in
// this table stays NULL, which is safe because nothing on the save/load path
// looks at it.
void vmhost_window_show_message(const char* message, WindowMessageType type,
                                int timeoutMs) {
    std::fprintf(stderr, "VMHOSTSNAP window message (type=%d, timeout=%d): %s\n",
                 static_cast<int>(type), timeoutMs, message ? message : "");
}

// Snapshot.cpp 在保存/恢复时还会读当前旋转、并按快照里的旋转去转宿主窗口
// （Snapshot.cpp:548 保存时读、:945-951 恢复时转 + 改可伸缩显示）。VMHost 的
// 窗口由引擎/Activity 自己管，这里报"没有旋转、转不动"即可 —— 关键是这几个
// 指针**不能为 NULL**，否则调用即 pc=0（我们实测就是 getRotation 崩的）。
int vmhost_window_get_rotation(void) { return 0; }
bool vmhost_window_rotate(int) { return false; }
bool vmhost_window_change_resizable_display(int) { return false; }

const QAndroidEmulatorWindowAgent& build_window_agent(void) {
    static const QAndroidEmulatorWindowAgent agent = [] {
        QAndroidEmulatorWindowAgent a = {};
        a.showMessage = vmhost_window_show_message;
        a.getRotation = vmhost_window_get_rotation;
        a.rotate = vmhost_window_rotate;
        a.changeResizableDisplay = vmhost_window_change_resizable_display;
        return a;
    }();
    return agent;
}

void vmhost_allow_real_audio(bool) {}
bool vmhost_is_real_audio_allowed(void) { return false; }
bool vmhost_set_display(int32_t, int32_t, int32_t, uint32_t) { return false; }
void vmhost_system_shutdown_request(QemuShutdownCause) {}

const QAndroidVmOperations* build_vm_operations(void) {
    static const QAndroidVmOperations ops = [] {
        QAndroidVmOperations o = {};
        o.vmStop = vmhost_vm_stop;
        o.vmStart = vmhost_vm_start;
        o.vmReset = vmhost_vm_reset;
        o.vmShutdown = vmhost_vm_shutdown;
        o.vmPause = vmhost_vm_pause;
        o.vmResume = vmhost_vm_resume;
        o.vmIsRunning = vmhost_vm_is_running;
        o.snapshotList = vmhost_snapshot_list;
        o.snapshotSave = vmhost_snapshot_save;
        o.snapshotLoad = vmhost_snapshot_load;
        o.snapshotDelete = vmhost_snapshot_delete;
        o.snapshotRemap = vmhost_snapshot_remap;
        o.snapshotExport = vmhost_snapshot_export;
        o.snapshotLastLoaded = vmhost_snapshot_last_loaded;
        o.setSnapshotCallbacks = vmhost_set_snapshot_callbacks;
        o.setSnapshotProtobuf = vmhost_set_snapshot_protobuf;
        o.mapUserBackedRam = vmhost_map_user_backed_ram;
        o.unmapUserBackedRam = vmhost_unmap_user_backed_ram;
        o.getVmConfiguration = vmhost_get_vm_configuration;
        o.setFailureReason = vmhost_set_failure_reason;
        o.setExiting = vmhost_set_exiting;
        o.allowRealAudio = vmhost_allow_real_audio;
        o.physicalMemoryGetAddr = vmhost_physical_memory_get_addr;
        o.isRealAudioAllowed = vmhost_is_real_audio_allowed;
        o.setSkipSnapshotSave = vmhost_set_skip_snapshot_save;
        o.isSnapshotSaveSkipped = vmhost_is_snapshot_save_skipped;
        o.hostmemRegister = vmhost_hostmem_register;
        o.hostmemUnregister = vmhost_hostmem_unregister;
        o.hostmemGetInfo = vmhost_hostmem_get_info;
        o.getRunState = vmhost_get_run_state;
        o.setDisplay = vmhost_set_display;
        o.system_shutdown_request = vmhost_system_shutdown_request;
        return o;
    }();
    return &ops;
}

}  // namespace

// Called by the C ABI bridge (vmhost_snapshot_glue.cpp) before the first
// Snapshotter operation. Snapshotter asserts that setSnapshotCallbacks is
// present, so the table must be complete before initialize() runs.
//
// initialize() 会立刻回调 setSnapshotCallbacks（Snapshotter.cpp:265
// `mVmOperations.setSnapshotCallbacks(this, &kCallbacks)`），上面那四件注册
// 就是在那一步完成的 —— 也就是说在第一次 save/load 之前，QEMU 侧的
// QEMUFileHooks 一定已经挂好。
void vmhost_snapshot_initialize_snapshotter(void) {
    static bool initialized = false;
    if (initialized) {
        return;
    }
    android::snapshot::Snapshotter::get().initialize(*build_vm_operations(),
                                                     build_window_agent());
    initialized = true;
}

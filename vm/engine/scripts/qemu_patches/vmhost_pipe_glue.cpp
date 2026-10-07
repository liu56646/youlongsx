// VMHost: Android pipe 宿主侧接线。
//
// 等价于 aemu 上游 android-qemu2-glue/emulation/android_pipe_device.cpp +
// VmLock.cpp 的最小可编译子集，作用是把 QEMU 的 goldfish-pipe 虚拟设备
// （hw/misc/goldfish_pipe.c）与 aemu 的通用 pipe 服务（AndroidPipe.cpp /
// GoldfishDma.cpp）对接起来：
//
//   设备侧需要 GoldfishPipeServiceOps  -> 通过 goldfish_pipe_set_service_ops() 注入
//   服务侧需要 AndroidPipeHwFuncs vtbl -> 由 QEMU 设备在 hwpipe 里自带
//
// 与上游的差别：去掉了对 protobuf / QemuFileStream 的依赖。快照相关的回调
// （guest_pre/post_load|save、guest_load/save、dma_save/load_mappings）全部
// 用空实现——本工程不使用 QEMU save/load 快照，这些回调不会被触发。

#include <arpa/inet.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/uio.h>
#include <ucontext.h>
#include <unistd.h>

#include <algorithm>
#include <memory>
#include <random>
#include <string>
#include <vector>

// 这里只声明需要的 QEMU C 函数，**不 include qemu/osdep.h**：
// osdep.h 会把 glib 拉进来，而 glib 在 C++ 模式下会 include <type_traits>
// 等 libc++ 头，一旦整体裹在 extern "C" 里就会报
// "templates must have C++ linkage"。直接按 C 链接声明最省事。
extern "C" {
void qemu_mutex_lock_iothread(void);
void qemu_mutex_unlock_iothread(void);
bool qemu_mutex_iothread_locked(void);
// exec/cpu-common.h（hwaddr 即 uint64_t）
void* cpu_physical_memory_map(uint64_t addr, uint64_t* plen, int is_write);
void cpu_physical_memory_unmap(void* buffer, uint64_t len, int is_write,
                               uint64_t access_len);
}

#include "android-qemu2-glue/emulation/VmLock.h"

#include "host-common/AndroidPipe.h"
#include "host-common/android_pipe_common.h"
#include "host-common/android_pipe_device.h"
#include "host-common/DmaMap.h"
#include "host-common/GoldfishDma.h"
#include "host-common/GoldfishSyncCommandQueue.h"
#include "host-common/VmLock.h"
#include "host-common/goldfish_sync.h"
#include "host-common/address_space_device.h"
#include "host-common/vm_operations.h"

extern "C" {
#include "host-common/goldfish_pipe.h"
}

// VMHOSTPIPESVC=1 时打印服务侧调用（判断访客请求有没有真正走到 aemu 的
// AndroidPipe 服务上）。默认关闭，避免正常运行时刷屏。
static bool vmhost_pipe_log_on() {
    static int enabled = -1;
    if (enabled < 0) {
        enabled = getenv("VMHOSTPIPE_SVC") ? 1 : 0;
    }
    return enabled == 1;
}

static void vmhost_pipe_log(const char* what, long a = 0, long b = 0) {
    if (vmhost_pipe_log_on()) {
        fprintf(stderr, "VMHOSTPIPESVC %s a=%ld b=%ld\n", what, a, b);
    }
}

// 打印首包内容：goldfish pipe 的服务名是访客在 pipe 上第一次 send 的数据
// （形如 "pipe:<name>" 或 "qemud:<name>"），这里直接把它打出来。
static void vmhost_pipe_log_buf(const char* what, const void* p, size_t n) {
    if (!vmhost_pipe_log_on() || !p) {
        return;
    }
    char out[65];
    size_t k = n > 48 ? 48 : n;
    const unsigned char* b = static_cast<const unsigned char*>(p);
    for (size_t i = 0; i < k; i++) {
        out[i] = (b[i] >= 32 && b[i] < 127) ? static_cast<char>(b[i]) : '.';
    }
    out[k] = '\0';
    char hex[3 * 33];
    size_t hk = n > 32 ? 32 : n;
    for (size_t i = 0; i < hk; i++) {
        snprintf(hex + i * 3, 4, "%02x ", b[i]);
    }
    hex[hk * 3] = '\0';
    fprintf(stderr, "VMHOSTPIPESVC %s data=\"%s\" size=%zu hex=[%s]\n", what, out,
            n, hex);
}

// ------------------------------------------------------------------ VmLock
// 与上游 android-qemu2-glue/emulation/VmLock.cpp 完全一致：
// pipe 的宿主侧回调可能跑在其它线程上，进 QEMU 设备状态前必须拿 BQL。
namespace qemu2 {

void VmLock::lock() {
    qemu_mutex_lock_iothread();
}

void VmLock::unlock() {
    qemu_mutex_unlock_iothread();
}

bool VmLock::isLockedBySelf() const {
    return qemu_mutex_iothread_locked();
}

}  // namespace qemu2

// ------------------------------------------------------------------ DmaMap
// 等价于上游 android-qemu2-glue/emulation/DmaMap.cpp。
//
// 必须有：aemu 的 DmaMap::get() 只是返回静态 sInstance，没人 set 就是 nullptr。
// goldfish_pipe 在 VERSION 寄存器读取时就会走
//   reset_pipe_device() -> service_ops->dma_reset_host_mappings()
//   -> android_goldfish_dma_reset_host_mappings() -> DmaMap::get()->resetHostMappings()
// 不上这一层就会空指针崩在访客驱动加载的那一刻（实测 guest 时间 ~2.8s）。
class VmHostQemuDmaMap : public android::DmaMap {
public:
    void* doMap(uint64_t addr, uint64_t sz) override {
        uint64_t sz_reg = sz;
        void* res = cpu_physical_memory_map(addr, &sz_reg, /*is_write*/ 1);
        if (sz_reg != sz) {
            if (res) {
                cpu_physical_memory_unmap(res, sz_reg, /*is_write*/ 1, sz_reg);
            }
            return nullptr;
        }
        return res;
    }

    void doUnmap(void* mapped, uint64_t sz) override {
        cpu_physical_memory_unmap(mapped, sz, /*is_write*/ 1, sz);
    }
};

// ------------------------------------------------------------ qemud 服务
// 访客用 goldfish pipe 走 qemud 协议访问一批 host 服务。实测（Android 11 guest）
// 依次请求：qemud:boot-properties、qemud:sensors、qemud:fingerprintlisten。
//
// aemu 的连接名处理：先找名为 "qemud:<name>" 的服务，找不到则回退到名为 "qemud"
// 的服务，并把 "<name>[:args]" 作为 args 传给 Service::create()。
// 这里就注册唯一一个名为 "qemud" 的服务，按 args 里的客户端名分发。
//
// 分帧：每条消息 = 4 个 ASCII 十六进制字符（负载长度）+ 负载。解析时也兼容
// 高位置 1 的二进制大端帧头（与上游 qemud_framelen 一致）。
// boot-properties 协议（见 android/emu/hardware/src/android/boot-properties.c）：
// 访客发 "list"，host 逐条回 "<name>=<value>"，最后回一个 1 字节的 NUL 结束。

static int vmhost_hex2int(const uint8_t* s, int n) {
    int v = 0;
    for (int i = 0; i < n; i++) {
        int c = s[i];
        if (c >= '0' && c <= '9') {
            c -= '0';
        } else if (c >= 'a' && c <= 'f') {
            c = c - 'a' + 10;
        } else if (c >= 'A' && c <= 'F') {
            c = c - 'A' + 10;
        } else {
            return -1;
        }
        v = (v << 4) | c;
    }
    return v;
}

static void vmhost_int2hex(uint8_t* s, int n, unsigned v) {
    static const char kDigits[] = "0123456789abcdef";
    for (int i = n - 1; i >= 0; i--) {
        s[i] = kDigits[v & 0xf];
        v >>= 4;
    }
}

// 默认下发的引导属性。可用 VMHOST_BOOT_PROPS 覆盖（分号分隔的 name=value）。
static std::vector<std::string> vmhost_boot_props() {
    std::vector<std::string> props;
    const char* env = getenv("VMHOST_BOOT_PROPS");
    if (env && *env) {
        std::string s(env);
        size_t pos = 0;
        for (;;) {
            size_t sep = s.find(';', pos);
            std::string item = s.substr(
                    pos, sep == std::string::npos ? std::string::npos : sep - pos);
            if (!item.empty()) {
                props.push_back(item);
            }
            if (sep == std::string::npos) break;
            pos = sep + 1;
        }
        return props;
    }
    // 与 emulator 正常启动时 host 下发的关键项保持一致
    props.push_back("qemu.hw.mainkeys=0");
    props.push_back("qemu.adb.secure=0");
    // 访客 init.ranchu.rc 会执行 setprop ro.opengles.version ${ro.kernel.qemu.opengles.version}
    // （实测因该属性不存在而报 "doesn't exist while expanding"），所以必须提供的是
    // ro.kernel.qemu.opengles.version；直接给 ro.opengles.version 反而会因只读属性冲突而失败。
    props.push_back("ro.kernel.qemu.opengles.version=196610");  // 0x30002 -> GLES 3.0
    return props;
}

class VmHostQemudPipe : public android::AndroidPipe {
public:
    VmHostQemudPipe(void* hwPipe, Service* service, std::string client)
        : AndroidPipe(hwPipe, service), mClient(std::move(client)) {}

    void onGuestClose(PipeCloseReason reason) override {
        vmhost_pipe_log("qemud_close", (long) mClient.size());
        delete this;
    }

    unsigned onGuestPoll() const override {
        // 有回包时告诉访客可读，否则只表示可写
        return mOutPos < mOut.size() ? (PIPE_POLL_IN | PIPE_POLL_OUT)
                                     : PIPE_POLL_OUT;
    }

    int onGuestRecv(AndroidPipeBuffer* buffers, int numBuffers) override {
        if (mOutPos >= mOut.size()) {
            return PIPE_ERROR_AGAIN;
        }
        int transferred = 0;
        for (int i = 0; i < numBuffers && mOutPos < mOut.size(); i++) {
            size_t avail = mOut.size() - mOutPos;
            size_t n = std::min(buffers[i].size, avail);
            memcpy(buffers[i].data, mOut.data() + mOutPos, n);
            mOutPos += n;
            transferred += static_cast<int>(n);
        }
        if (mOutPos >= mOut.size()) {
            mOut.clear();
            mOutPos = 0;
        }
        return transferred;
    }

    int onGuestSend(const AndroidPipeBuffer* buffers, int numBuffers,
                    void** newPipePtr) override {
        int transferred = 0;
        for (int i = 0; i < numBuffers; i++) {
            mIn.append(reinterpret_cast<const char*>(buffers[i].data),
                       buffers[i].size);
            transferred += static_cast<int>(buffers[i].size);
        }
        processInput();
        return transferred;
    }

    void onGuestWantWakeOn(int flags) override {}

private:
    // 从 mIn 里按帧解码，逐条交给 handleMessage
    void processInput() {
        while (mIn.size() >= 4) {
            const uint8_t* hdr = reinterpret_cast<const uint8_t*>(mIn.data());
            int len;
            if (hdr[0] & 0x80) {  // 二进制大端帧头
                uint32_t v;
                memcpy(&v, hdr, 4);
                v = ntohl(v) & 0x7fffffff;
                len = static_cast<int>(v);
            } else {
                len = vmhost_hex2int(hdr, 4);
            }
            if (len < 0) {  // 帧头坏了，丢弃缓冲重新同步
                vmhost_pipe_log("qemud_badframe", mIn.size());
                mIn.clear();
                return;
            }
            if (mIn.size() < static_cast<size_t>(4 + len)) {
                return;  // 还没收全
            }
            std::string msg = mIn.substr(4, len);
            mIn.erase(0, 4 + len);
            handleMessage(msg);
        }
    }

    void handleMessage(const std::string& msg) {
        if (mClient == "boot-properties") {
            // 访客发 "list"，逐条回 "<name>=<value>"，末尾回 1 字节 NUL 结束。
            if (msg.size() == 4 && msg.compare(0, 4, "list") == 0) {
                std::vector<std::string> props = vmhost_boot_props();
                for (const std::string& p : props) {
                    appendFramed(p);
                }
                appendFramed(std::string(1, '\0'));
                vmhost_pipe_log("qemud_props_sent", (long) props.size());
            }
            return;
        }
        if (mClient == "sensors") {
            // 参考 android/android-emu/android/hw-sensors.cpp：
            // "list-sensors" 回一个十进制的传感器位图（这里没有任何启用的传感器，回 0），
            // "wake" 原样回 "wake"。"set-delay:" 等其余消息忽略。
            if (msg == "list-sensors") {
                appendFramed("0");
                vmhost_pipe_log("qemud_sensors_list", 0);
            } else if (msg == "wake") {
                appendFramed("wake");
            }
            return;
        }
        // fingerprintlisten 等其它 qemud 客户端：只收不回，让连接建立即可。
    }

    void appendFramed(const std::string& payload) {
        uint8_t hdr[4];
        vmhost_int2hex(hdr, 4, static_cast<unsigned>(payload.size()));
        mOut.append(reinterpret_cast<const char*>(hdr), 4);
        mOut.append(payload);
    }

    std::string mClient;   // 客户端名（args 的前缀），如 "boot-properties"
    std::string mIn;       // 访客 -> host 的待解码字节
    std::string mOut;      // host -> 访客的待发送字节
    size_t mOutPos = 0;
};

class VmHostQemudService : public android::AndroidPipe::Service {
public:
    VmHostQemudService() : android::AndroidPipe::Service("qemud") {}

    android::AndroidPipe* create(void* hwPipe, const char* args,
                                 AndroidPipeFlags flags) override {
        // args 形如 "boot-properties" 或 "boot-properties:0"
        std::string client = args ? args : "";
        size_t sep = client.find(':');
        if (sep != std::string::npos) {
            client.resize(sep);
        }
        vmhost_pipe_log("qemud_create", (long) client.size());
        return new VmHostQemudPipe(hwPipe, this, client);
    }
};


// ------------------------------------------------------------ QemuMiscPipe
// guest 用 `pipe:QemuMiscPipe` 发短命令，host 回原始字节。
// 分帧（AndroidMessagePipe）：[4 字节本机序长度][负载]，双向都是。
//
// 上游实现 android/emu/hardware/src/android/emulation/QemuMiscPipe.cpp 挂在
// 一大堆前端依赖上（AVD skin 布局、AdbInterface、metrics、protobuf、
// getConsoleAgents…），搬不动也不需要；这里只保留 guest 启动路径真正会用的命令：
//   heartbeat      -> "OK\0"
//   bootcomplete   -> "OK\0"
//   get_random=N   -> N 个随机字节（guest 用它做熵种子）
//   其它           -> "KO\0"

class VmHostMiscPipe : public android::AndroidPipe {
public:
    VmHostMiscPipe(void* hwPipe, Service* service)
        : AndroidPipe(hwPipe, service) {}

    void onGuestClose(PipeCloseReason reason) override {
        (void)reason;
        delete this;
    }

    unsigned onGuestPoll() const override {
        return mOutPos < mOut.size() ? (PIPE_POLL_IN | PIPE_POLL_OUT)
                                     : PIPE_POLL_OUT;
    }

    int onGuestRecv(AndroidPipeBuffer* buffers, int numBuffers) override {
        if (mOutPos >= mOut.size()) {
            return PIPE_ERROR_AGAIN;
        }
        int transferred = 0;
        for (int i = 0; i < numBuffers && mOutPos < mOut.size(); i++) {
            size_t avail = mOut.size() - mOutPos;
            size_t n = std::min(buffers[i].size, avail);
            memcpy(buffers[i].data, mOut.data() + mOutPos, n);
            mOutPos += n;
            transferred += static_cast<int>(n);
        }
        if (mOutPos >= mOut.size()) {
            mOut.clear();
            mOutPos = 0;
        }
        return transferred;
    }

    int onGuestSend(const AndroidPipeBuffer* buffers, int numBuffers,
                    void** newPipePtr) override {
        int transferred = 0;
        for (int i = 0; i < numBuffers; i++) {
            mIn.append(reinterpret_cast<const char*>(buffers[i].data),
                       buffers[i].size);
            transferred += static_cast<int>(buffers[i].size);
        }
        processInput();
        return transferred;
    }

    void onGuestWantWakeOn(int flags) override { (void)flags; }

private:
    void processInput() {
        for (;;) {
            if (!mHaveLen) {
                if (mIn.size() < 4) {
                    return;
                }
                uint32_t n = 0;
                memcpy(&n, mIn.data(), 4);
                mIn.erase(0, 4);
                // 0 或异常大的长度视为坏帧，清空重新同步
                if (n == 0 || n > (1u << 20)) {
                    vmhost_pipe_log("misc_badlen", (long) n);
                    mIn.clear();
                    return;
                }
                mMsgLen = n;
                mHaveLen = true;
            }
            if (mIn.size() < mMsgLen) {
                return;
            }
            std::string msg = mIn.substr(0, mMsgLen);
            mIn.erase(0, mMsgLen);
            mHaveLen = false;
            handleMessage(msg);
        }
    }

    void handleMessage(const std::string& msg) {
        std::string reply;
        if (msg.compare(0, 9, "heartbeat") == 0) {
            reply.assign("OK", 3);  // "OK\0"
            vmhost_pipe_log("misc_heartbeat");
        } else if (msg.compare(0, 12, "bootcomplete") == 0) {
            reply.assign("OK", 3);
            vmhost_pipe_log("misc_bootcomplete");
        } else if (msg.compare(0, 11, "get_random=") == 0) {
            int n = atoi(msg.c_str() + 11);
            if (n < 0) {
                n = 0;
            }
            if (n > 4096) {
                n = 4096;
            }
            reply.resize(n);
            for (int i = 0; i < n; i++) {
                reply[i] = static_cast<char>(randGen()() & 0xff);
            }
            vmhost_pipe_log("misc_get_random", n);
        } else {
            reply.assign("KO", 3);
            vmhost_pipe_log("misc_unknown", (long) msg.size());
        }
        appendReply(reply);
        signalWake(PIPE_WAKE_READ);
    }

    void appendReply(const std::string& payload) {
        uint32_t n = static_cast<uint32_t>(payload.size());
        char hdr[4];
        memcpy(hdr, &n, 4);
        mOut.append(hdr, 4);
        mOut.append(payload);
    }

    static std::mt19937& randGen() {
        static std::mt19937 gen(0x564d484fU);  // "VMHO"
        return gen;
    }

    std::string mIn;   // 访客 -> host 的待解码字节
    std::string mOut;  // host -> 访客的待发送字节
    size_t mOutPos = 0;
    uint32_t mMsgLen = 0;
    bool mHaveLen = false;
};

class VmHostMiscPipeService : public android::AndroidPipe::Service {
public:
    VmHostMiscPipeService() : android::AndroidPipe::Service("QemuMiscPipe") {}

    android::AndroidPipe* create(void* hwPipe, const char* args,
                                 AndroidPipeFlags flags) override {
        (void)args;
        (void)flags;
        vmhost_pipe_log("misc_create");
        return new VmHostMiscPipe(hwPipe, this);
    }
};

// ------------------------------------------------------- ServiceOps 接线
// 成员顺序必须与 host-common/goldfish_pipe.h 中 GoldfishPipeServiceOps 完全一致。
static const GoldfishPipeServiceOps goldfish_pipe_service_ops = {
    // guest_open()
    [](GoldfishHwPipe* hwPipe) -> GoldfishHostPipe* {
        GoldfishHostPipe* hostPipe = static_cast<GoldfishHostPipe*>(
                android_pipe_guest_open(hwPipe));
        vmhost_pipe_log("open", (long) (intptr_t) hostPipe);
        return hostPipe;
    },
    // guest_open_with_flags()
    [](GoldfishHwPipe* hwPipe, uint32_t flags) -> GoldfishHostPipe* {
        GoldfishHostPipe* hostPipe = static_cast<GoldfishHostPipe*>(
                android_pipe_guest_open_with_flags(hwPipe, flags));
        vmhost_pipe_log("open_flags", (long) flags, (long) (intptr_t) hostPipe);
        return hostPipe;
    },
    // guest_close()
    [](GoldfishHostPipe* hostPipe, GoldfishPipeCloseReason reason) {
        vmhost_pipe_log("close", (long) reason);
        android_pipe_guest_close(hostPipe,
                                 static_cast<PipeCloseReason>(reason));
    },
    // guest_pre_load()
    [](QEMUFile*) {},
    // guest_post_load()
    [](QEMUFile*) {},
    // guest_pre_save()
    [](QEMUFile*) {},
    // guest_post_save()
    [](QEMUFile*) {},
    // guest_load()
    [](QEMUFile*, GoldfishHwPipe*, char*) -> GoldfishHostPipe* {
        return nullptr;
    },
    // guest_save()
    [](GoldfishHostPipe*, QEMUFile*) {},
    // guest_poll()
    [](GoldfishHostPipe* hostPipe) -> GoldfishPipePollFlags {
        return static_cast<GoldfishPipePollFlags>(
                android_pipe_guest_poll(hostPipe));
    },
    // guest_recv()
    [](GoldfishHostPipe* hostPipe, GoldfishPipeBuffer* buffers,
       int numBuffers) -> int {
        // AndroidPipeBuffer 与 GoldfishPipeBuffer 布局一致（同上游假设）
        int ret = android_pipe_guest_recv(
                hostPipe, reinterpret_cast<AndroidPipeBuffer*>(buffers),
                numBuffers);
        vmhost_pipe_log("recv", (long) ret, (long) numBuffers);
        return ret;
    },
    // wait_guest_recv()
    [](GoldfishHostPipe* hostPipe) {
        android_pipe_wait_guest_recv(hostPipe);
    },
    // guest_send()
    [](GoldfishHostPipe** hostPipe, const GoldfishPipeBuffer* buffers,
       int numBuffers) -> int {
        if (numBuffers >= 1 && buffers) {
            vmhost_pipe_log_buf("send_data", buffers[0].data, buffers[0].size);
        }
        int ret = android_pipe_guest_send(
                reinterpret_cast<void**>(hostPipe),
                reinterpret_cast<const AndroidPipeBuffer*>(buffers),
                numBuffers);
        vmhost_pipe_log("send", (long) ret, (long) numBuffers);
        return ret;
    },
    // wait_guest_send()
    [](GoldfishHostPipe* hostPipe) {
        android_pipe_wait_guest_send(hostPipe);
    },
    // guest_wake_on()
    [](GoldfishHostPipe* hostPipe, GoldfishPipeWakeFlags wakeFlags) {
        android_pipe_guest_wake_on(hostPipe, static_cast<int>(wakeFlags));
    },
    // dma_add_buffer()
    [](void* pipe, uint64_t paddr, uint64_t sz) {
        vmhost_pipe_log("dma_add", (long) paddr, (long) sz);
        android_goldfish_dma_ops.add_buffer(pipe, paddr, sz);
    },
    // dma_remove_buffer()
    [](uint64_t paddr) {
        android_goldfish_dma_ops.remove_buffer(paddr);
    },
    // dma_invalidate_host_mappings()
    []() { android_goldfish_dma_ops.invalidate_host_mappings(); },
    // dma_reset_host_mappings()
    []() { android_goldfish_dma_ops.reset_host_mappings(); },
    // dma_save_mappings()
    [](QEMUFile*) {},
    // dma_load_mappings()
    [](QEMUFile*) {},
};

static void* goldfish_pipe_lookup_by_id_wrapper(int id) {
    return goldfish_pipe_lookup_by_id(id);
}

bool qemu_android_pipe_init(android::VmLock* vmLock) {
    goldfish_pipe_set_service_ops(&goldfish_pipe_service_ops);
    android_pipe_append_lookup_by_id_callback(
            &goldfish_pipe_lookup_by_id_wrapper, "goldfish_pipe");
    android::AndroidPipe::initThreading(vmLock);
    return true;
}

// ------------------------------------------------- goldfish_sync 宿主侧接线
// guest 的 EmuHWC2 / gralloc 会用 /dev/goldfish_sync 做 fence。设备侧
// hw/misc/goldfish_sync.c 通过 service_ops 回调宿主；上游在
// android-qemu2-glue/qemu-setup.cpp 里调 qemu_android_sync_init() 装配它，
// 我们一直没接 —— 于是 service_ops 是 NULL，guest 的 fence 请求没有宿主响应。
// （这很可能就是 HWC 起来约 60s 后 abort 的原因。）
//
// 这里做 qemu_android_sync_init() 的等价三件事：
//   initThreading(vmLock) + set_service_ops + set_hw_funcs
//
// GoldfishSyncServiceOps 定义在 QEMU 的 include/hw/misc/goldfish_sync.h 里，
// 该头会拉进 QEMU 内部类型，所以按老规矩**只声明不 include**（结构与字段顺序
// 必须与那个头完全一致）。QEMUFile 只做不透明指针，我们不支持快照，save/load 空实现。
typedef struct QEMUFile QEMUFile;

struct VmHostGoldfishSyncServiceOps {
    void (*receive_hostcmd_result)(uint32_t cmd, uint64_t handle,
                                   uint32_t time_arg, uint64_t hostcmd_handle);
    void (*trigger_host_wait)(uint64_t glsync_ptr, uint64_t thread_ptr,
                              uint64_t timeline);
    void (*save)(QEMUFile* file);
    void (*load)(QEMUFile* file);
};

extern "C" {
void goldfish_sync_set_service_ops(const VmHostGoldfishSyncServiceOps* ops);
void goldfish_sync_send_command(uint32_t cmd, uint64_t handle,
                                uint32_t time_arg, uint64_t hostcmd_handle);
}

static trigger_wait_fn_t sVmHostSyncTriggerWaitFn = nullptr;

static const VmHostGoldfishSyncServiceOps vmhost_goldfish_sync_service_ops = {
    // 来自 aemu host-common/goldfish_sync.cpp
    .receive_hostcmd_result = goldfish_sync_receive_hostcmd_result,
    .trigger_host_wait =
            [](uint64_t glsync_ptr, uint64_t thread_ptr, uint64_t timeline) {
                if (sVmHostSyncTriggerWaitFn) {
                    sVmHostSyncTriggerWaitFn(glsync_ptr, thread_ptr, timeline);
                } else {
                    vmhost_pipe_log("sync_no_trigger_wait");
                }
            },
    .save = [](QEMUFile* file) { (void)file; },  // 不支持 QEMU 快照
    .load = [](QEMUFile* file) { (void)file; },
};

static GoldfishSyncDeviceInterface vmhost_goldfish_sync_hw_funcs = {
    // QEMU 设备侧：往 guest 送命令
    .doHostCommand = goldfish_sync_send_command,
    .registerTriggerWait =
            [](trigger_wait_fn_t fn) { sVmHostSyncTriggerWaitFn = fn; },
};

static void vmhost_sync_init(android::VmLock* vmLock) {
    // 命令队列要和 AndroidPipe 一样跑在设备线程上
    android::GoldfishSyncCommandQueue::initThreading(vmLock);
    goldfish_sync_set_service_ops(&vmhost_goldfish_sync_service_ops);
    goldfish_sync_set_hw_funcs(&vmhost_goldfish_sync_hw_funcs);
    vmhost_pipe_log("goldfish_sync 宿主侧已接线");
}

// ------------------------------------------------- 地址空间设备宿主侧接线
// ranchu 现在有 PCIe + goldfish_address_space 设备了（vendor 的 gralloc 必需）。
// 「地址空间设备」的宿主实现（HostMemoryAllocator / SharedSlotsHostMemoryAllocator …）
// 都要用这套 AddressSpaceHwFuncs：以前设备不存在时是惰性的、不会触发，
// 现在会真被调用——不接就是空指针解引用（实测 guest SF 起来做 GL 时 QEMU SIGSEGV）。
// 等价于上游 AOSP glue 的 qemu_android_address_space_device_init()。
extern "C" {
int goldfish_address_space_alloc_shared_host_region(uint64_t page_aligned_size, uint64_t* offset);
int goldfish_address_space_free_shared_host_region(uint64_t offset);
int goldfish_address_space_alloc_shared_host_region_locked(uint64_t page_aligned_size, uint64_t* offset);
int goldfish_address_space_free_shared_host_region_locked(uint64_t offset);
uint64_t goldfish_address_space_get_phys_addr_start(void);
uint64_t goldfish_address_space_get_phys_addr_start_locked(void);
uint32_t goldfish_address_space_get_guest_page_size(void);
int goldfish_address_space_alloc_shared_host_region_fixed_locked(uint64_t page_aligned_size, uint64_t offset);
// QEMU 侧控制 ops（guest 发 GEN_HANDLE/DESTROY_HANDLE/TELL_PING_INFO/PING 时会调用）。
// 上游在 android-qemu2-glue/qemu-setup.cpp:271 把 aemu 的实现 cast 后装进来；
// 两个结构体布局一致（见 include/sysemu/sysemu.h 与 aemu host-common/address_space_device.h）。
struct qemu_address_space_device_control_ops;
void qemu_set_address_space_device_control_ops(struct qemu_address_space_device_control_ops* ops);
}  // extern "C"

// ---- 地址空间设备需要的 VM operations（aemu 的 sVmOps）----
// 不接的后果（实测）：guest 发 TELL_PING_INFO 时 aemu 的
// AddressSpaceDeviceState::tellPingInfo -> sVmOps->physicalMemoryGetAddr() 解引用空表
// （si_addr=0xB0）→ QEMU SIGSEGV。上游在 qemu-setup.cpp 里装 getConsoleAgents()->vm，
// 我们这边只实现地址空间设备真正会用到的 5 个成员，其余留 0。
static void* vmhost_physical_memory_get_addr(uint64_t gpa) {
    uint64_t len = 0x1000;
    return cpu_physical_memory_map(gpa, &len, 0);
}

static void vmhost_map_user_backed_ram(uint64_t gpa, void* hva, uint64_t size) {
    (void)gpa; (void)hva; (void)size;
}

static void vmhost_unmap_user_backed_ram(uint64_t gpa, uint64_t size) {
    (void)gpa; (void)size;
}

static uint64_t vmhost_hostmem_register(const struct MemEntry* entry) {
    (void)entry;
    return 0;
}

static void vmhost_hostmem_unregister(uint64_t id) { (void)id; }

static QAndroidVmOperations vmhost_vm_ops;

static void vmhost_vm_ops_init(void) {
    memset(&vmhost_vm_ops, 0, sizeof vmhost_vm_ops);
    vmhost_vm_ops.physicalMemoryGetAddr = vmhost_physical_memory_get_addr;
    vmhost_vm_ops.mapUserBackedRam = vmhost_map_user_backed_ram;
    vmhost_vm_ops.unmapUserBackedRam = vmhost_unmap_user_backed_ram;
    vmhost_vm_ops.hostmemRegister = vmhost_hostmem_register;
    vmhost_vm_ops.hostmemUnregister = vmhost_hostmem_unregister;
}

static const struct AddressSpaceHwFuncs vmhost_address_space_hw_funcs = {
    goldfish_address_space_alloc_shared_host_region,
    goldfish_address_space_free_shared_host_region,
    goldfish_address_space_alloc_shared_host_region_locked,
    goldfish_address_space_free_shared_host_region_locked,
    goldfish_address_space_get_phys_addr_start,
    goldfish_address_space_get_phys_addr_start_locked,
    goldfish_address_space_get_guest_page_size,
    goldfish_address_space_alloc_shared_host_region_fixed_locked,
};

// ------------------------------------------------- 宿主崩溃捕获（拿 QEMU 崩溃回溯）
// QEMU 树里没有任何 SIGSEGV 处理器，所以进程级 handler 一定由我们接管。
// 崩时把「信号信息 + PC/SP/FP/LR + 帧指针回溯 + 完整 maps」写文件，事后离线符号化。
static int vmhost_crash_fd = -1;

static void vmhost_crash_w(const char *s) {
    if (vmhost_crash_fd >= 0) {
        ssize_t r = write(vmhost_crash_fd, s, strlen(s));
        (void)r;
    }
}

static void vmhost_crash_pc(uint64_t v) {
    char b[48];
    int n = snprintf(b, sizeof b, "  0x%llx\n", (unsigned long long)v);
    if (vmhost_crash_fd >= 0) {
        ssize_t r = write(vmhost_crash_fd, b, (size_t)n);
        (void)r;
    }
}

/*
 * 崩溃处理器里读内存：必须走 process_vm_readv。
 * 直接解引用一个坏指针会在处理 SIGSEGV 的过程中再触发一次 SIGSEGV ——
 * 那时该信号已被屏蔽，内核直接打死进程，连已写好的 dump 都可能丢。
 * process_vm_readv 对坏地址只返回 -1/EFAULT。
 */
static bool vmhost_crash_peek(uint64_t addr, uint64_t *out) {
    if (addr == 0 || addr < 4096 || (addr & 0x7) != 0) {
        return false;
    }
    struct iovec local = { out, sizeof *out };
    struct iovec remote = { (void *)(uintptr_t)addr, sizeof *out };
    const ssize_t n = syscall(SYS_process_vm_readv, getpid(), &local, 1, &remote, 1, 0);
    return n == (ssize_t)sizeof *out;
}

/*
 * VMHOST_DIAG: 由 gles2_dec.cpp 提供，打印崩溃前最后 64 条 GLES2 命令。
 * 用弱符号：万一分发库/链接顺序里没有这个符号，也不会导致链接失败。
 */
extern "C" void vmhost_gles2_dump_recent(void) __attribute__((weak));

/*
 * D15: 由 vmhost_gfx_glue.cpp 提供，报告**崩溃线程**的 EGL 状态（权威答案）：
 *   out[0]=eglGetCurrentContext()  [1]=eglGetCurrentSurface(EGL_DRAW)
 *   [2]=eglGetCurrentSurface(EGL_READ)
 * 用弱符号：该文件依赖 libEGL 的运行时解析，允许缺席。
 */
extern "C" int vmhost_gfx_egl_ctx_info(unsigned long long *out) __attribute__((weak));

static void vmhost_crash_handler(int sig, siginfo_t *si, void *ucp) {
    ucontext_t *uc = (ucontext_t *)ucp;
    char buf[256];

    vmhost_crash_w("\n########## VMHOST QEMU CRASH ##########\n");
    snprintf(buf, sizeof buf, "signal=%d si_code=%d addr=%p tid=%ld\n", sig,
             si ? si->si_code : 0, si ? si->si_addr : (void *)0,
             (long)syscall(SYS_gettid));
    vmhost_crash_w(buf);

    uint64_t pc = 0, sp = 0, fp = 0, lr = 0;
#if defined(__aarch64__)
    if (uc) {
        pc = (uint64_t)uc->uc_mcontext.pc;
        sp = (uint64_t)uc->uc_mcontext.sp;
        fp = (uint64_t)uc->uc_mcontext.regs[29];
        lr = (uint64_t)uc->uc_mcontext.regs[30];
    }
#endif
    snprintf(buf, sizeof buf, "pc=0x%llx sp=0x%llx fp=0x%llx lr=0x%llx\n",
             (unsigned long long)pc, (unsigned long long)sp,
             (unsigned long long)fp, (unsigned long long)lr);
    vmhost_crash_w(buf);

    /*
     * 完整寄存器：pc=0 这类"跳到 0"的崩溃，光有 pc/lr 只能定位到调用点，
     * 要靠 x0..x30 才能判断是哪个对象/哪个参数出的问题。
     */
#if defined(__aarch64__)
    if (uc) {
        for (int i = 0; i < 31; i++) {
            snprintf(buf, sizeof buf, "regs x%d=0x%llx\n", i,
                     (unsigned long long)uc->uc_mcontext.regs[i]);
            vmhost_crash_w(buf);
        }
        /*
         * 典型现场：x0 = this，调用其虚函数时 vtable 槽位为 0。
         * 把对象指针、vptr 与前两个槽位一起打出来，离线就能符号化出类名。
         */
        {
            const uint64_t obj = (uint64_t)uc->uc_mcontext.regs[0];
            uint64_t vptr = 0, slot0 = 0, slot1 = 0;
            snprintf(buf, sizeof buf, "x0_obj=0x%llx", (unsigned long long)obj);
            vmhost_crash_w(buf);
            if (vmhost_crash_peek(obj, &vptr) && vmhost_crash_peek(vptr, &slot0) &&
                vmhost_crash_peek(vptr + 8, &slot1)) {
                snprintf(buf, sizeof buf,
                         " vptr=0x%llx slot0=0x%llx slot1=0x%llx\n",
                         (unsigned long long)vptr, (unsigned long long)slot0,
                         (unsigned long long)slot1);
            } else {
                snprintf(buf, sizeof buf, " vptr=<不可读>\n");
            }
            vmhost_crash_w(buf);
        }
    }
#endif

    /*
     * D15：本线程到底有没有 current GL 上下文？
     * 驱动在**固定指令**上 addr=0x38 崩溃，最像"没有 current context 的线程
     * 发了 GL 调用，驱动入口桩解引用 NULL 的线程局部上下文"。
     * 直接问 EGL（权威答案）：eglCtx=0 即本线程根本没绑上下文。
     */
    if (vmhost_gfx_egl_ctx_info != nullptr) {
        unsigned long long info[3] = {0, 0, 0};
        vmhost_gfx_egl_ctx_info(info);
        snprintf(buf, sizeof buf,
                 "gl_ctx: eglGetCurrentContext=0x%llx eglDrawSurface=0x%llx "
                 "eglReadSurface=0x%llx\n",
                 info[0], info[1], info[2]);
        vmhost_crash_w(buf);
    } else {
        vmhost_crash_w("gl_ctx: 探针符号缺失\n");
    }

    vmhost_crash_w("--- backtrace (fp walk) ---\n");
    vmhost_crash_pc(pc);
    if (lr) vmhost_crash_pc(lr);
    {
        uint64_t cur = fp;
        int i;
        for (i = 0; i < 120 && cur; i++) {
            if ((cur & 0xf) != 0) break;
            if (sp && (cur < sp || cur > sp + (1u << 23))) break;
            {
                uint64_t *f = (uint64_t *)cur;
                uint64_t next = f[0];
                uint64_t ret = f[1];
                if (!ret) break;
                vmhost_crash_pc(ret);
                if (next <= cur) break;
                cur = next;
            }
        }
    }
    vmhost_crash_w("--- end backtrace ---\n");

    /* VMHOST_DIAG: 崩溃前最后 64 条 GLES2 命令 —— 就是把这串调用打崩的驱动 */
    if (vmhost_gles2_dump_recent) {
        vmhost_gles2_dump_recent();
    }

    {
        int mf = open("/proc/self/maps", O_RDONLY);
        if (mf >= 0) {
            char b[4096];
            ssize_t n;
            vmhost_crash_w("--- maps ---\n");
            while ((n = read(mf, b, sizeof b)) > 0) {
                if (vmhost_crash_fd >= 0) {
                    ssize_t r = write(vmhost_crash_fd, b, (size_t)n);
                    (void)r;
                }
            }
            close(mf);
            vmhost_crash_w("--- end maps ---\n");
        }
    }

    vmhost_crash_w("########## END ##########\n");
    if (vmhost_crash_fd >= 0) fsync(vmhost_crash_fd);

    signal(sig, SIG_DFL);
    raise(sig);
    _exit(1);
}

static void vmhost_install_crash_handler(void) {
    vmhost_crash_fd =
            open("/data/local/tmp/qemu_crash.log", O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (vmhost_crash_fd < 0) {
        vmhost_crash_fd = 2;
    }
    // 必须给 handler 一个独立的备用栈：如果是栈溢出（深递归）导致的 SIGSEGV，
    // 在已经耗尽的栈上 handler 根本执行不了，内核会强制 SIG_DFL 直接杀掉进程
    // （现象就是：无日志、无 handler、无 tombstone、只有 128+11 的退出码）。
    static char vmhost_altstack[SIGSTKSZ * 8];
    stack_t ss;
    memset(&ss, 0, sizeof ss);
    ss.ss_sp = vmhost_altstack;
    ss.ss_size = sizeof(vmhost_altstack);
    ss.ss_flags = 0;
    sigaltstack(&ss, NULL);

    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = vmhost_crash_handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGFPE, &sa, NULL);
    vmhost_pipe_log("宿主崩溃捕获已安装 -> /data/local/tmp/qemu_crash.log");
}

// ------------------------------------------------------- QEMU/C 侧入口
// vl.c 是 C，所以只暴露一个无参入口：装好 VmLock 并把服务注册进设备。
// 幂等：重复调用只生效一次。
extern "C" int vmhost_pipe_init(void) {
    static bool inited = false;
    if (inited) {
        return 0;
    }
    inited = true;

    // 先装崩溃捕获（越早越好，赶在任何线程创建之前）
    vmhost_install_crash_handler();

    android::VmLock* vmLock = new qemu2::VmLock();
    // set() 返回旧实例（可能为 nullptr，也可能是 get() 懒创建的默认实现）。
    // 与上游一样只是替换，不去 delete——get() 可能已被别处缓存过指针。
    android::VmLock::set(vmLock);

    // DmaMap 必须装：get() 不会懒创建，不装就是 nullptr（见上面注释）。
    android::DmaMap::set(new VmHostQemuDmaMap());

    // 注册 qemud 服务（boot-properties / sensors / fingerprintlisten ...）。
    // 必须在访客连接之前完成。
    android::AndroidPipe::Service::add(std::make_unique<VmHostQemudService>());

    // 注册 QemuMiscPipe（heartbeat / bootcomplete / get_random）
    android::AndroidPipe::Service::add(std::make_unique<VmHostMiscPipeService>());

    // goldfish_sync 宿主侧（等价上游 qemu_android_sync_init）：
    // guest 的 EmuHWC2/gralloc 靠它做 fence，不接会让 HWC ~60s 后 abort。
    vmhost_sync_init(vmLock);

    // 地址空间设备需要的 VM operations（必须，先于 hw funcs / control ops）
    vmhost_vm_ops_init();
    address_space_set_vm_operations(&vmhost_vm_ops);
    vmhost_pipe_log("地址空间设备 vm operations 已接线");

    // 地址空间设备宿主侧 hw funcs（必须：guest 的 gralloc/HostMemoryAllocator 会用到）
    address_space_set_hw_funcs(&vmhost_address_space_hw_funcs);
    vmhost_pipe_log("地址空间设备宿主 hw funcs 已接线");

    // 地址空间设备的 QEMU 侧控制 ops。
    // 不接的话：guest 发 ADDRESS_SPACE_COMMAND_GEN_HANDLE 时，
    // hw/pci/goldfish_address_space.c:681 会解引用空表 → QEMU 直接 SIGSEGV
    // （实测崩在 address_space_run_command，si_addr=0）。
    qemu_set_address_space_device_control_ops(
            (struct qemu_address_space_device_control_ops*)
                    get_address_space_device_control_ops());
    vmhost_pipe_log("地址空间设备 control ops 已接线");

    return qemu_android_pipe_init(vmLock) ? 0 : -1;
}

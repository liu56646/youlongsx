// VMHost: aemu snapshot C ABI bridge.
//
// QEMU's migration/savevm.c is compiled as C, while the useful snapshot path
// lives in android::snapshot::Snapshotter (C++). This file is the narrow C ABI
// between those two worlds.

#include "android/console.h"
#include "android/emulation/control/globals_agent.h"
#include "android/snapshot/PathUtils.h"
#include "android/snapshot/Snapshotter.h"
#include "android/avd/hw-config.h"   // AndroidHwConfig（settings->hw() 必须返回非空）

#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>

#include <dirent.h>
#include <sys/stat.h>

using android::snapshot::OperationStatus;
using android::snapshot::Snapshotter;

// Provided by qemu_patches/vmhost_vm_operations.cpp: registers the QEMU-side
// VM operation table that Snapshotter::save()/load() call through. Without it
// the table is empty and the first save dies on a NULL function pointer.
extern void vmhost_snapshot_initialize_snapshotter(void);

namespace {

const char* vmhost_snapshot_status_name(OperationStatus status) {
    switch (status) {
        case OperationStatus::NotStarted:
            return "not started";
        case OperationStatus::Ok:
            return "ok";
        case OperationStatus::Error:
            return "error";
        case OperationStatus::Canceled:
            return "canceled";
    }
    return "unknown status";
}

void vmhost_snapshot_set_error(char errbuf[512], const char* message) {
    if (!errbuf) {
        return;
    }
    std::snprintf(errbuf, 512, "%s", message ? message : "unknown error");
}

// Snapshotter::save() 在 mSaver == nullptr 时按源码是"trivially succeed"
// （Snapshotter.cpp:783："In unit tests, we don't have a saver, so trivially
// succeed."）：返回 Ok，但磁盘上什么都没有。引擎据此把快照记成可用，坏快照
// 就永远不会回退，所以 C ABI 这一层自己复核落盘结果。
//
// 目录取自 android/snapshot/PathUtils.cpp:46 getSnapshotBaseDir() —— 也就是
// vmhost_avd_shim.cpp 的 avdInfo_getContentPath()（VMHOST_SNAP_DIR）加
// "/snapshots"，再拼快照名：和 Saver 写盘用的是同一个函数（Snapshot.cpp:442
// Snapshot::dataDir()），不会跟实际落点错位。ram.bin 是 RAM 载荷
// （snapshot/common.h:126 kRamFileName），它非空才说明 QEMU 的 RAM 流真的
// 经 QEMUFileHooks 交到了 aemu 的 RamSaver。
bool vmhost_snapshot_check_on_disk(const char* name, char errbuf[512]) {
    const std::string dir = android::snapshot::getSnapshotDir(name);

    DIR* d = opendir(dir.c_str());
    if (!d) {
        char detail[512];
        std::snprintf(detail, sizeof(detail),
                      "snapshot '%s' reported ok but %s is not readable: %s",
                      name, dir.c_str(), std::strerror(errno));
        vmhost_snapshot_set_error(errbuf, detail);
        return false;
    }

    int nonEmptyFiles = 0;
    bool ramFileOk = false;
    struct dirent* entry = nullptr;
    while ((entry = readdir(d)) != nullptr) {
        if (!std::strcmp(entry->d_name, ".") ||
            !std::strcmp(entry->d_name, "..")) {
            continue;
        }
        const std::string file = dir + "/" + entry->d_name;
        struct stat st;
        if (stat(file.c_str(), &st) != 0 || !S_ISREG(st.st_mode) ||
            st.st_size <= 0) {
            continue;
        }
        ++nonEmptyFiles;
        if (!std::strcmp(entry->d_name, "ram.bin")) {
            ramFileOk = true;
        }
    }
    closedir(d);

    char detail[512];
    if (nonEmptyFiles == 0) {
        std::snprintf(detail, sizeof(detail),
                      "snapshot '%s' reported ok but wrote no data to %s",
                      name, dir.c_str());
        vmhost_snapshot_set_error(errbuf, detail);
        return false;
    }
    if (!ramFileOk) {
        std::snprintf(detail, sizeof(detail),
                      "snapshot '%s' wrote %d non-empty file(s) to %s but "
                      "ram.bin is missing or empty: the RAM stream never "
                      "reached aemu",
                      name, nonEmptyFiles, dir.c_str());
        vmhost_snapshot_set_error(errbuf, detail);
        return false;
    }
    return true;
}

// We do not run the emulator frontend, so there is no AvdInfo / hardware
// config / console. But the aemu snapshot path *does* query several of them
// through getConsoleAgents()->settings, and **a null function pointer in that
// table means a call through NULL**: FeatureControlImpl::init() calls
// settings->hw() early during startup, which crashed at pc=0 the first time we
// left the table mostly empty. So every slot below gets a safe implementation.
char s_vmhostDummyAvdInfo;
AndroidHwConfig s_vmhostDummyHwConfig;              // 全零：调用方只读字段
LanguageSettings s_vmhostDummyLanguage = {0, nullptr, nullptr, nullptr};

AvdInfoParams* vmhost_avd_params(void) { return nullptr; }
AndroidHwConfig* vmhost_hw_config(void) { return &s_vmhostDummyHwConfig; }
int vmhost_guest_data_partition_mounted(void) { return 1; }
bool vmhost_guest_boot_completed(void) { return false; }
bool vmhost_arm_snapshot_save_completed(void) { return false; }
bool vmhost_host_emulator_is_headless(void) { return true; }
bool vmhost_android_qemu_mode(void) { return true; }
bool vmhost_min_config_qemu_mode(void) { return true; }
bool vmhost_is_fuchsia(void) { return false; }
int vmhost_snapshot_update_timer(void) { return 0; }
LanguageSettings* vmhost_language(void) { return &s_vmhostDummyLanguage; }
AUserConfig* vmhost_user_config(void) { return nullptr; }
AndroidOptions* vmhost_cmdline_options(void) { return nullptr; }
void vmhost_inject_cmdline_options(AndroidOptions*) {}
bool vmhost_has_cmdline_options(void) { return false; }
const char* vmhost_cmd_line(void) { return ""; }
void vmhost_inject_cmd_line(const char*) {}
void vmhost_inject_language(char*, char*, char*) {}
void vmhost_inject_user_config(AUserConfig*) {}
void vmhost_set_keycode_forwarding(bool) {}
void vmhost_inject_avd_info(AvdInfo*) {}
void vmhost_set_guest_data_partition_mounted(int) {}
void vmhost_set_guest_boot_completed(bool) {}
void vmhost_set_arm_snapshot_save_completed(bool) {}
void vmhost_set_host_emulator_is_headless(bool) {}
void vmhost_set_android_qemu_mode(bool) {}
void vmhost_set_min_config_qemu_mode(bool) {}
void vmhost_set_is_fuchsia(bool) {}
void vmhost_set_snapshot_update_timer(int) {}
int vmhost_android_base_port(void) { return 5554; }
void vmhost_set_android_base_port(int) {}
int vmhost_android_adb_port(void) { return 5037; }
void vmhost_set_android_adb_port(int) {}
int vmhost_android_serial_number_port(void) { return 5554; }
void vmhost_set_android_serial_number_port(int) {}
bool vmhost_has_network_option(void) { return true; }

}  // namespace

extern "C" AvdInfo* vmhost_dummy_avd_info(void) {
    return reinterpret_cast<AvdInfo*>(&s_vmhostDummyAvdInfo);
}

namespace {

const QAndroidGlobalVarsAgent s_vmhostGlobalVarsAgent = [] {
    QAndroidGlobalVarsAgent agent = {};
    agent.avdParams = vmhost_avd_params;
    agent.avdInfo = vmhost_dummy_avd_info;
    agent.hw = vmhost_hw_config;
    agent.guest_data_partition_mounted = vmhost_guest_data_partition_mounted;
    agent.guest_boot_completed = vmhost_guest_boot_completed;
    agent.arm_snapshot_save_completed = vmhost_arm_snapshot_save_completed;
    agent.host_emulator_is_headless = vmhost_host_emulator_is_headless;
    agent.android_qemu_mode = vmhost_android_qemu_mode;
    agent.min_config_qemu_mode = vmhost_min_config_qemu_mode;
    agent.is_fuchsia = vmhost_is_fuchsia;
    agent.android_snapshot_update_timer = vmhost_snapshot_update_timer;
    agent.language = vmhost_language;
    agent.userConfig = vmhost_user_config;
    agent.android_cmdLineOptions = vmhost_cmdline_options;
    agent.inject_cmdLineOptions = vmhost_inject_cmdline_options;
    agent.has_cmdLineOptions = vmhost_has_cmdline_options;
    agent.android_cmdLine = vmhost_cmd_line;
    agent.inject_android_cmdLine = vmhost_inject_cmd_line;
    agent.inject_language = vmhost_inject_language;
    agent.inject_userConfig = vmhost_inject_user_config;
    agent.set_keycode_forwarding = vmhost_set_keycode_forwarding;
    agent.inject_AvdInfo = vmhost_inject_avd_info;
    agent.set_guest_data_partition_mounted = vmhost_set_guest_data_partition_mounted;
    agent.set_guest_boot_completed = vmhost_set_guest_boot_completed;
    agent.set_arm_snapshot_save_completed = vmhost_set_arm_snapshot_save_completed;
    agent.set_host_emulator_is_headless = vmhost_set_host_emulator_is_headless;
    agent.set_android_qemu_mode = vmhost_set_android_qemu_mode;
    agent.set_min_config_qemu_mode = vmhost_set_min_config_qemu_mode;
    agent.set_is_fuchsia = vmhost_set_is_fuchsia;
    agent.set_android_snapshot_update_timer = vmhost_set_snapshot_update_timer;
    agent.android_base_port = vmhost_android_base_port;
    agent.set_android_base_port = vmhost_set_android_base_port;
    agent.android_adb_port = vmhost_android_adb_port;
    agent.set_android_adb_port = vmhost_set_android_adb_port;
    agent.android_serial_number_port = vmhost_android_serial_number_port;
    agent.set_android_serial_number_port = vmhost_set_android_serial_number_port;
    agent.has_network_option = vmhost_has_network_option;
    return agent;
}();

const AndroidConsoleAgents s_vmhostConsoleAgents = [] {
    AndroidConsoleAgents agents = {};
    agents.settings = &s_vmhostGlobalVarsAgent;
    return agents;
}();

}  // namespace

// Snapshotter only reads settings->avdInfo() on this integration path. Keep
// the returned agent table static and non-null; every other field is a null
// pointer and must not be treated as an emulator-frontend implementation.
//
// avdInfo_getContentPath() and the rest of the avdInfo_* set are provided by
// qemu_patches/vmhost_avd_shim.cpp, which reads VMHOST_SNAP_DIR so that
// android/snapshot/PathUtils.cpp resolves to <dataDir>/snapshots/<name>/.
extern "C" const AndroidConsoleAgents* getConsoleAgents(void) {
    return &s_vmhostConsoleAgents;
}

extern "C" int vmhost_snapshot_save(const char* name, char errbuf[512]) {
    if (!name || !name[0]) {
        vmhost_snapshot_set_error(errbuf, "snapshot name is empty");
        return -1;
    }
    if (errbuf) {
        errbuf[0] = '\0';
    }

    vmhost_snapshot_initialize_snapshotter();
    const OperationStatus status =
            Snapshotter::get().save(false /* isOnExit */, name);
    if (status == OperationStatus::Ok) {
        // Snapshotter::save() 对 "没有 Saver" 这种失败也返回 Ok（见上面
        // vmhost_snapshot_check_on_disk 的说明），所以 Ok 之后还得看盘。
        // 失败时把原因交给 errbuf，引擎会据此丢掉这个坏快照。
        return vmhost_snapshot_check_on_disk(name, errbuf) ? 0 : -1;
    }

    char detail[256];
    std::snprintf(detail, sizeof(detail),
                  "Snapshotter::save('%s') failed: %s (%d)", name,
                  vmhost_snapshot_status_name(status),
                  static_cast<int>(status));
    vmhost_snapshot_set_error(errbuf, detail);
    return -1;
}

extern "C" int vmhost_snapshot_load(const char* name, char errbuf[512]) {
    if (!name || !name[0]) {
        vmhost_snapshot_set_error(errbuf, "snapshot name is empty");
        return -1;
    }
    if (errbuf) {
        errbuf[0] = '\0';
    }

    const auto started = std::chrono::steady_clock::now();
    vmhost_snapshot_initialize_snapshotter();
    const OperationStatus status =
            Snapshotter::get().load(false /* isQuickboot */, name);
    if (status == OperationStatus::Ok) {
        const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - started).count();
        const auto stats = Snapshotter::get().getLoadStats(name, elapsed);
        std::fprintf(stderr,
                     "VMHOSTSNAP load_profile total_ms=%lld ram_ms=%lld "
                     "ram_bytes=%lld textures_bytes=%lld compressed=%d ondemand=%d\n",
                     static_cast<long long>(elapsed),
                     static_cast<long long>(stats.ramDurationMs),
                     static_cast<long long>(stats.ramSize),
                     static_cast<long long>(stats.texturesSize),
                     stats.compressedRam, stats.onDemandRamEnabled);
        return 0;
    }

    char detail[256];
    std::snprintf(detail, sizeof(detail),
                  "Snapshotter::load('%s') failed: %s (%d)", name,
                  vmhost_snapshot_status_name(status),
                  static_cast<int>(status));
    vmhost_snapshot_set_error(errbuf, detail);
    return -1;
}

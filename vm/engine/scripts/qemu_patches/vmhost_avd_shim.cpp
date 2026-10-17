// VMHost: minimal AvdInfo for the aemu snapshot path.
//
// The emulator frontend builds a real AvdInfo out of an AVD's .ini files
// (android/emu/avd/src/android/avd/info.c). VMHost never runs that frontend:
// the engine execs QEMU directly and passes the instance data directory in
// VMHOST_SNAP_DIR. We therefore do not compile info.c -- it defines
// avdInfo_getContentPath itself, which has to follow VMHOST_SNAP_DIR here, and
// every path it returns is derived from AVD ini files that do not exist.
//
// Signatures come from android/emu/avd/include/android/avd/info.h; the
// definitions below inherit the C linkage declared there.

#include "android/avd/info.h"

#include <cstdio>
#include <cstdlib>
#include <string>

#include <sys/stat.h>

namespace {

// The engine exports the instance data directory (<dataDir>) before exec.
const char* contentPath() {
    static const std::string sPath = [] {
        const char* dir = std::getenv("VMHOST_SNAP_DIR");
        return std::string((dir && dir[0]) ? dir : "/data/local/tmp");
    }();
    return sPath.c_str();
}

// We are not an AVD, so there is no hardware.ini; the snapshot saves a copy of
// this file and compares it with the live one on load, so we keep a stable,
// empty ini in the instance directory to make both sides read the same values.
const char* coreHwIniPath() {
    static const std::string sPath = [] {
        std::string path(contentPath());
        path += "/vmhost_core_hw.ini";
        struct stat st;
        if (stat(path.c_str(), &st) != 0) {
            if (FILE* f = std::fopen(path.c_str(), "ab")) {
                std::fclose(f);
            }
        }
        return path;
    }();
    return sPath.c_str();
}

// We have no build.prop for a system image; the snapshot only reads a couple of
// keys out of it, and an empty ini yields their default values.
const FileData* emptyBuildProperties() {
    static const char kEmptyData[] = "";
    static FileData sEmpty = {
            reinterpret_cast<uint8_t*>(const_cast<char*>(kEmptyData)), 0, 0};
    return &sEmpty;
}

}  // namespace

// Not an AVD: the content path is the VMHost instance directory, so that
// android/snapshot/PathUtils.cpp lands snapshots in <dataDir>/snapshots.
const char* avdInfo_getContentPath(const AvdInfo*) {
    return contentPath();
}

// Not an AVD: there is no AVD instance name, but the snapshot writes this
// string into an ini file, so it must be a stable non-null label.
const char* avdInfo_getName(const AvdInfo*) {
    return "vmhost";
}

// Not an AVD: no multi-instance id exists; this is the same stable label the
// snapshot fixup writes into hardware.ini.
const char* avdInfo_getId(const AvdInfo*) {
    return "vmhost";
}

// Not an AVD: we are never a build-system launch, so the build-env paths in
// Snapshot.cpp (qcow2 cleanup) stay disabled.
int avdInfo_inAndroidBuild(const AvdInfo*) {
    return 0;
}

// Not an AVD: VMHost guests are arm64, so the x86-only boot timeout is unused.
bool avdInfo_is_x86ish(const AvdInfo*) {
    return false;
}

// Not an AVD: no system image build.prop is available, so expose an empty one
// instead of NULL (the caller dereferences the result without a null check).
const FileData* avdInfo_getBuildProperties(const AvdInfo*) {
    return emptyBuildProperties();
}

// Not an AVD: we hand out the empty ini described in coreHwIniPath() so that
// the snapshot's hardware-config copy/compare step is trivially satisfied.
const char* avdInfo_getCoreHwIniPath(const AvdInfo*) {
    return coreHwIniPath();
}

// Not an AVD: there is no per-system feature control file, and the caller
// already handles NULL (it only uses the path when it is set).
char* avdInfo_getDefaultSystemFeatureControlPath(const AvdInfo*) {
    return nullptr;
}

// Not an AVD: the caller must free() the result, and the snapshot only uses
// these to fingerprint images it did not create (NULL means "no such image").
char* avdInfo_getKernelPath(const AvdInfo*) {
    return nullptr;
}

// Not an AVD: same as avdInfo_getKernelPath -- VMHost's kernel comes from the
// engine's command line, not from an AVD image directory.
char* avdInfo_getRanchuKernelPath(const AvdInfo*) {
    return nullptr;
}

// Not an AVD: same as avdInfo_getKernelPath -- the ramdisk is a command-line
// argument the engine passes to QEMU.
char* avdInfo_getRamdiskPath(const AvdInfo*) {
    return nullptr;
}

// Not an AVD: same as avdInfo_getKernelPath -- there is no separate system.img
// copy, the engine hands QEMU the system image directly.
char* avdInfo_getSystemImagePath(const AvdInfo*) {
    return nullptr;
}

// Not an AVD: same as avdInfo_getKernelPath -- the read-only init image is
// owned by the engine's file list.
char* avdInfo_getSystemInitImagePath(const AvdInfo*) {
    return nullptr;
}

// Not an AVD: same as avdInfo_getKernelPath -- vendor.img is passed straight to
// QEMU by the engine.
char* avdInfo_getVendorImagePath(const AvdInfo*) {
    return nullptr;
}

// Not an AVD: same as avdInfo_getKernelPath -- the data image is the engine's
// userdata.img, whose path we are intentionally not modelling here.
char* avdInfo_getDataImagePath(const AvdInfo*) {
    return nullptr;
}

// Not an AVD: same as avdInfo_getKernelPath -- VMHost never wipes data from
// inside QEMU, so there is no userdata.img to initialise from.
char* avdInfo_getDataInitImagePath(const AvdInfo*) {
    return nullptr;
}

// Not an AVD: same as avdInfo_getKernelPath -- there is no AVD cache.img; the
// engine manages the cache partition if the instance has one.
char* avdInfo_getCachePath(const AvdInfo*) {
    return nullptr;
}

// Not an AVD: same as avdInfo_getKernelPath -- SD cards are not part of the
// VMHost instance layout.
char* avdInfo_getSdCardPath(const AvdInfo*) {
    return nullptr;
}

// Not an AVD: same as avdInfo_getKernelPath -- the encryption key image is
// either passed by the engine or absent, never an AVD-owned file.
char* avdInfo_getEncryptionKeyImagePath(const AvdInfo*) {
    return nullptr;
}

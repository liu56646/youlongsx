// VMHost: no-op stubs for the emulator-frontend subsystems that the aemu
// snapshot objects reference.
//
// The snapshot code is built for the emulator, so it also drags in metrics,
// crash reporting, Android Studio config discovery and the resizable-display
// UI. None of those subsystems exist in the QEMU child process: the engine owns
// the window, the display geometry and the ADB connection, and nothing that
// runs here uploads telemetry. Each definition below states what it returns and
// why that cannot affect snapshot correctness. Signatures are taken from the
// real headers; nothing here is invented.

#include "android/adb-server.h"
#include "android/crashreport/CrashReporter.h"
#include "android/crashreport/HangDetector.h"
#include "android/emulation/resizable_display_config.h"
#include "android/metrics/DependentMetrics.h"
#include "android/metrics/MetricsReporter.h"
#include "android/metrics/StudioConfig.h"

#include "base/logging.h"
#include "host-common/FeatureControl.h"
#include "host-common/logging.h"

#include <cstdarg>
#include <cstdio>
#include <string>
#include <utility>

// ---------------------------------------------------------------- logging
//
// OutputLog is gfxstream's/host-common's printf-style log sink. The real
// implementation lives in aemu's host-common/logging.cpp, which is not part of
// the archives we link, so we print directly instead of dropping the message:
// these lines are the only visibility we have inside the QEMU child.
void OutputLog(FILE* stream,
               char severity,
               const char* file,
               unsigned int line,
               int64_t timestamp_us,
               const char* format,
               ...) {
    if (!stream || !format) {
        return;
    }
    // timestamp_us is a testing hook of the real implementation; we let the
    // stream's own buffering deal with ordering.
    (void)timestamp_us;
    std::fprintf(stream, "%c %s:%u: ", severity, file ? file : "?", line);
    va_list args;
    va_start(args, format);
    std::vfprintf(stream, format, args);
    va_end(args);
    std::fputc('\n', stream);
}

// crashpad's mini_chromium logging backend. The snapshot code only reaches it
// through CHECK/DCHECK in crashpad headers, and VMHost does not link the
// crashpad uploader, so we keep the message and print it on destruction. A
// failing CHECK therefore still shows up in logcat instead of being swallowed.
namespace logging {

LogMessage::LogMessage(const char* function,
                       const char* file_path,
                       int line,
                       LogSeverity severity)
    : file_path_(file_path),
      message_start_(0),
      line_(line),
      severity_(severity) {
    (void)function;
}

LogMessage::~LogMessage() {
    const std::string message = stream_.str();
    if (!message.empty()) {
        std::fprintf(stderr, "%s:%d: %s\n", file_path_ ? file_path_ : "?",
                     line_, message.c_str());
    }
}

}  // namespace logging

// ---------------------------------------------------------------- metrics
namespace android {
namespace metrics {

namespace {

// The real reporter writes protobuf events to a MetricsWriter and only runs the
// callbacks when reporting is enabled. VMHost has no consent flow and no
// writer, so the reporter is permanently disabled: callbacks are never run and
// nothing is ever uploaded. The snapshot path only uses the callbacks to fill
// an AndroidStudioEvent that nothing consumes.
class VmhostNullMetricsReporter final : public MetricsReporter {
public:
    VmhostNullMetricsReporter()
        : MetricsReporter(false /* enabled */, nullptr /* writer */,
                          "vmhost", "vmhost", "qemu") {}

    void reportConditional(ConditionalCallback) override {}
    void finishPendingReports() override {}
};

}  // namespace

// The real constructor/destructor live in the metrics module we do not link;
// they only store the constructor arguments, so we can define them here and
// hand out a properly constructed, permanently disabled reporter.
MetricsReporter::MetricsReporter(bool enabled,
                                 MetricsWriter::Ptr writer,
                                 std::string_view emulatorVersion,
                                 std::string_view emulatorFullVersion,
                                 std::string_view qemuVersion)
    : mWriter(std::move(writer)),
      mEnabled(enabled),
      mStartTimeMs(base::System::get()->getUnixTimeUs()),
      mEmulatorVersion(emulatorVersion),
      mEmulatorFullVersion(emulatorFullVersion),
      mQemuVersion(qemuVersion) {}

MetricsReporter::~MetricsReporter() = default;

MetricsReporter& MetricsReporter::get() {
    static VmhostNullMetricsReporter sReporter;
    return sReporter;
}

// Reporting is disabled (see above), so the callback would never be invoked;
// dropping it keeps the call sites branch-free.
void MetricsReporter::report(Callback callback) {
    (void)callback;
}

// Only used to anonymise a snapshot name inside a metrics event that is never
// uploaded; an empty string keeps the payload free of instance data.
std::string MetricsReporter::anonymize(std::string_view) {
    return std::string();
}

}  // namespace metrics
}  // namespace android

// The C API fills the "common info" fields of an AndroidStudioEvent before it
// is uploaded. Nothing here uploads, and opaque is a protobuf we deliberately do
// not link, so there is nothing to fill in.
void android_metrics_fill_common_info(bool /* openglAlive */,
                                      void* /* opaque */) {}

// ---------------------------------------------------------------- crashreport
namespace android {
namespace crashreport {

namespace {

// Neither CrashReporter nor HangDetector can be constructed here: their
// constructors live in the crashpad-backed crash-reporting module, which VMHost
// does not link (there is no crash server to report to). The snapshot path only
// ever calls CrashReporter::get()->hangDetector().pause(), and both of those
// members are defined below as functions that never touch their object, so an
// inert, properly aligned instance is enough. The storage is static, so the
// reference stays valid for the process lifetime and no destructor ever runs.
alignas(CrashReporter) unsigned char sCrashReporterStorage[sizeof(CrashReporter)];
alignas(HangDetector) unsigned char sHangDetectorStorage[sizeof(HangDetector)];

}  // namespace

// Never dereferenced by the stubs below; it only has to be stable and non-null
// because Snapshotter calls get()->hangDetector() without a null check.
CrashReporter* CrashReporter::get() {
    return reinterpret_cast<CrashReporter*>(sCrashReporterStorage);
}

// Returns the inert detector described above; pause() is the only member the
// snapshot code uses.
HangDetector& CrashReporter::hangDetector() {
    return *reinterpret_cast<HangDetector*>(sHangDetectorStorage);
}

// The emulator pauses its hang detector while a snapshot is being written or
// read, because a hang during a multi-second save is expected. There is no
// watcher thread here and no object state to flip: a no-op is the whole
// behaviour.
void HangDetector::pause(bool /* paused */) {}

}  // namespace crashreport
}  // namespace android

// ---------------------------------------------------------------- studio
namespace android {
namespace studio {

// No Android Studio is installed on the device, so there is no config directory
// to scan for a version; an invalid Version is exactly what the real
// implementation returns on a host without Studio.
base::Version lastestAndroidStudioVersion() {
    return base::Version();
}

// Same reason as the version above: with no Studio config there is no channel
// preference, so the real implementation also reports Unknown.
UpdateChannel updateChannel() {
    return UpdateChannel::Unknown;
}

}  // namespace studio
}  // namespace android

// ---------------------------------------------------------------- feature server
namespace android {
namespace featurecontrol {

// These two drive the emulator's "feature pattern" flow: they hash the host
// hardware info, compare it against patterns cached from the Android Studio
// feature server, and (in the async variant) download a fresh protobuf with
// curl. VMHost runs offline with locally configured feature flags, so there is
// no server response to apply and nothing to fetch. Upstream ships the same
// no-ops in android-emu-base/stubs/gfxstream-stubs.cpp for builds that leave out
// the server path.
void applyCachedServerFeaturePatterns() {}

void asyncUpdateServerFeaturePatterns() {}

}  // namespace featurecontrol
}  // namespace android

// ---------------------------------------------------------------- resizable UI

// The real implementation (android/emulation/resizable_display_config.cpp)
// reads hw_resizable_configs and the HWCMultiConfigs/SupportPixelFold feature
// flags through getConsoleAgents()->settings->hw(). VMHost's console agent table
// has no hw() entry (the engine owns the display geometry), so "not resizable"
// is the honest answer: the snapshot then stores no resizable-display field and
// the display size keeps coming from the engine.
bool resizableEnabled() {
    return false;
}

// Only consulted when resizableEnabled() is true, i.e. never here; the default
// preset is returned so the value is still a valid enum member.
enum PresetEmulatorSizeType getResizableActiveConfigId() {
    return PRESET_SIZE_PHONE;
}

// ---------------------------------------------------------------- adb

// Quickboot calls this after a snapshot load so the guest's adbd reconnects.
// The emulator's adb server lives in its frontend; VMHost's engine owns the ADB
// connection to the guest and re-establishes it itself, so this process has no
// connection list to close.
void android_adb_reset_connection(void) {}

// ------------------------------------------------- legacy feature C API

// host-common/feature_control_base.h 的这套 C API 是给**旧前端**用的，它按外部
// aemu 的旧 Feature 枚举编号传值（那份表比模拟器树的 Features.h 少若干项，
// 直接编 feature_control.cpp 会因枚举对不上而编译失败 —— 见
// build_qemu_aosp.sh 里的注释）。快照路径走的是模拟器树的
// android::featurecontrol::isEnabled(...)（真实现，已编入），这里只负责让
// 旧符号不悬空：没有前端下发 overrides，所以"一律未启用 + override 记下就丢"，
// 与"没有任何 override"的语义一致。
// 这里**不能** include host-common/feature_control_base.h：它用 1 参宏展开
// FeatureControlDef{Host,Guest}.h，而已经被 include 的 host-common/FeatureControl.h
// 用 2 参宏展开同一批头，两者形状不同 → 编译期直接炸。
// 调用方是 C 源码（引用的是**未修饰**的符号名 feature_is_enabled），所以这两个
// 定义按 C 链接给出；类型用同名的全局枚举保持一致。
enum Feature { kFeature_vmhost_placeholder = 0 };

extern "C" bool feature_is_enabled(Feature) {
    return false;
}

extern "C" void feature_set_enabled_override(Feature, bool) {}

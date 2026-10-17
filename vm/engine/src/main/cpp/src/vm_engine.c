/*
 * 引擎对外接口（JNI）+ NativeActivity 生命周期钩子。
 *
 * 骨架阶段只做：配置透传、生命周期日志、输入日志。
 * 真实实现（M0/M1）在这里替换为 QEMU 的
 * qemu_init / vm_start / virtio 注入 / qcow2 打开 等调用。
 */

#include "vm_engine.h"

#include <jni.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <android/log.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>

#ifdef VM_WITH_QEMU
#include "vm_qemu.h"
#include "vm_frame_relay.h"
#endif

#define TAG "VmEngine"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

#define ENGINE_VERSION "stub-0.1.0"

/* 与 VmConfig.EXTRA_CONFIG 保持一致 */
#define EXTRA_CONFIG "com.vm.core.extra.CONFIG"

/* ------------------------------------------------------------------ */
/* 实例配置（从 Intent 里的 VmConfig JSON 取出）                        */
/* ------------------------------------------------------------------ */

#define CONFIG_JSON_CAP 4096
#define PATH_CAP        512

static char s_config_json[CONFIG_JSON_CAP];
static char s_image_dir[PATH_CAP];
static char s_data_dir[PATH_CAP];
static char s_path_kernel[PATH_CAP];
static char s_path_initrd[PATH_CAP];
static char s_path_system[PATH_CAP];
static char s_path_vendor[PATH_CAP];
static char s_path_product[PATH_CAP];
static char s_path_system_ext[PATH_CAP];
static char s_path_metadata[PATH_CAP];
static char s_path_userdata[PATH_CAP];
static char s_path_console[PATH_CAP];

/**
 * 极简 JSON 字符串取值。
 * 只服务于我们自己生成的扁平 VmConfig，且**只用于字符串字段**
 * （数值字段后面没有引号，会被误判，因此不要用它读数值）。
 *
 * 注意会做 JSON 反转义：Android 的 org.json（JSONObject.toString）会把 '/' 写成
 * "\/"，若不还原，取到的路径就带反斜杠，access() 必然失败（表现为"内核不存在
 * 或不可读"，QEMU 起不来）。
 */
static bool json_get_string(const char *json, const char *key, char *out, size_t out_len)
{
    if (json == NULL || key == NULL || out == NULL || out_len == 0) {
        return false;
    }

    char pattern[64];
    snprintf(pattern, sizeof(pattern), "\"%s\"", key);

    const char *p = strstr(json, pattern);
    if (p == NULL) {
        return false;
    }
    p = strchr(p + strlen(pattern), ':');
    if (p == NULL) {
        return false;
    }
    p = strchr(p + 1, '"');
    if (p == NULL) {
        return false;
    }
    p++;

    size_t n = 0;
    while (*p != '\0' && *p != '"' && n + 1 < out_len) {
        char c = *p++;
        if (c == '\\' && *p != '\0') {
            const char e = *p++;
            switch (e) {
                case 'n': c = '\n'; break;
                case 't': c = '\t'; break;
                case 'r': c = '\r'; break;
                case 'b': c = '\b'; break;
                case 'f': c = '\f'; break;
                default:  c = e;    break;   /* \" \\ \/ 等 */
            }
        }
        out[n++] = c;
    }
    out[n] = '\0';
    return true;
}

#ifdef VM_WITH_QEMU
/** 快照恢复失败时是否已经回退过一次（避免无限循环）。 */
static bool s_restore_retried = false;

static void vm_engine_boot_qemu(void);

/**
 * 子进程 QEMU 退出后的收尾。
 *
 * 只有一种情况需要我们补救：这次是按快照恢复起来的，而 QEMU 没接受那份
 * 迁移流就直接退出了（真机实测报 `Unknown ramblock "", cannot accept
 * migration`）。此时快照是坏的：留着它，实例每次进来都是黑屏。所以删档 +
 * 复位引擎状态 + 按冷启动重来一次。
 */
void vm_engine_on_qemu_exit(void)
{
    if (!vm_qemu_restore_failed()) {
        return;
    }

    LOGE("快照恢复失败：QEMU 没接受迁移流，删除快照后回退冷启动");
    char stale[PATH_CAP];
    snprintf(stale, sizeof(stale), "%s/snapshot.bin", s_data_dir);
    unlink(stale);

    if (s_restore_retried) {
        LOGE("已回退过一次，本次不再重试（下次进入实例会走冷启动）");
        vm_qemu_reset();
        return;
    }
    s_restore_retried = true;
    vm_qemu_reset();
    vm_engine_boot_qemu();
}

/** 确保 <dataDir>/logs 存在（已存在则忽略）。 */
static void ensure_log_dir(const char *data_dir)
{
    char dir[PATH_CAP];
    snprintf(dir, sizeof(dir), "%s/logs", data_dir);
    if (mkdir(dir, 0755) == 0 || errno == EEXIST) {
        LOGI("日志目录就绪：%s", dir);
    } else {
        LOGW("创建日志目录 %s 失败（QEMU 可能因写不了 console.log 而直接退出）", dir);
    }
}

/**
 * 极简 JSON 整数取值。
 * 数值字段在 JSON 里没有引号，不能用 json_get_string（会误取后面键的引号），
 * 因此单列一个只认数字的取法；取不到或值非法时返回 fallback。
 */
static int json_get_int(const char *json, const char *key, int fallback)
{
    if (json == NULL || key == NULL) {
        return fallback;
    }

    char pattern[64];
    snprintf(pattern, sizeof(pattern), "\"%s\"", key);

    const char *p = strstr(json, pattern);
    if (p == NULL) {
        return fallback;
    }
    p = strchr(p + strlen(pattern), ':');
    if (p == NULL) {
        return fallback;
    }
    p++;
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') {
        p++;
    }
    if (*p < '0' || *p > '9') {
        return fallback;
    }

    long v = 0;
    while (*p >= '0' && *p <= '9') {
        v = v * 10 + (*p - '0');
        if (v > 1000000) {
            break; /* 防御：异常大的数字不再累加（后续会被 QEMU 侧拒绝） */
        }
        p++;
    }
    return (int) v;
}

/** GPT 头位于 LBA1（偏移 512），签名是 "EFI PART"。 */
static bool file_is_gpt(const char *path)
{
    if (path == NULL) {
        return false;
    }
    FILE *f = fopen(path, "rb");
    if (f == NULL) {
        return false;
    }
    char sig[8];
    const bool gpt = fseek(f, 512, SEEK_SET) == 0 &&
                     fread(sig, 1, sizeof(sig), f) == sizeof(sig) &&
                     memcmp(sig, "EFI PART", sizeof(sig)) == 0;
    fclose(f);
    return gpt;
}

/** 依据实例配置拼出 QEMU 启动参数并拉起 QEMU。 */
static void vm_engine_boot_qemu(void)
{
    if (s_config_json[0] == '\0') {
        LOGW("boot: 没有拿到 VmConfig，跳过 QEMU 启动");
        return;
    }
    if (!json_get_string(s_config_json, "imageDir", s_image_dir, sizeof(s_image_dir)) ||
        !json_get_string(s_config_json, "dataDir", s_data_dir, sizeof(s_data_dir))) {
        LOGW("boot: VmConfig 缺少 imageDir / dataDir");
        return;
    }

    snprintf(s_path_kernel, sizeof(s_path_kernel), "%s/kernel", s_image_dir);
    snprintf(s_path_initrd, sizeof(s_path_initrd), "%s/ramdisk.img", s_image_dir);
    /* system.img 同样支持实例级覆盖：设备身份要同时落在 system 分区（fingerprint 的
       版本段来自这里），详见 docs/方案B排障交接.md。实例目录里有就用它，否则回落 base。
       但 p9 的 base 是 GPT 单分区盘，p11/p13/p71 的 system.img 是纯 ext4；
       旧实例可能遗留不同布局的 system.img，直接复用会让 p9 的 /dev/vda1 消失。
       布局不一致时回退 base。 */
    char base_system[PATH_CAP];
    snprintf(base_system, sizeof(base_system), "%s/system.img", s_image_dir);
    const bool base_system_gpt = file_is_gpt(base_system);
    snprintf(s_path_system, sizeof(s_path_system), "%s/system.img", s_data_dir);
    {
        struct stat sst;
        const bool override_ok =
            stat(s_path_system, &sst) == 0 && S_ISREG(sst.st_mode) &&
            (!base_system_gpt || file_is_gpt(s_path_system));
        if (!override_ok) {
            snprintf(s_path_system, sizeof(s_path_system), "%s", base_system);
        }
    }
    snprintf(s_path_vendor, sizeof(s_path_vendor), "%s/vendor.img", s_image_dir);
    /* 访客 fstab 要求这四块只读盘 + 两块可写盘都在场，缺一块 first-stage init 就会
       "Failed to mount required partitions early"。product/system_ext 与 system/vendor
       同源（只读，随镜像分发）；metadata 必须是可写的，放实例数据目录里。

       product 是个例外：它带 /build.prop 里的设备身份，支持「实例级覆盖」——
       App 侧若为该实例选了机型，会在实例数据目录放一份改写过的 product.img，
       这里优先用它；没有（或不是常规文件）则回落共享 base 镜像那份。 */
    snprintf(s_path_product, sizeof(s_path_product), "%s/product.img", s_data_dir);
    {
        struct stat pst;
        if (stat(s_path_product, &pst) != 0 || !S_ISREG(pst.st_mode)) {
            snprintf(s_path_product, sizeof(s_path_product), "%s/product.img", s_image_dir);
        }
    }
    snprintf(s_path_system_ext, sizeof(s_path_system_ext), "%s/system_ext.img", s_image_dir);
    snprintf(s_path_metadata, sizeof(s_path_metadata), "%s/metadata.img", s_data_dir);
    snprintf(s_path_userdata, sizeof(s_path_userdata), "%s/userdata.img", s_data_dir);
    snprintf(s_path_console, sizeof(s_path_console), "%s/logs/console.log", s_data_dir);

    /* QEMU 的 -serial file:<console> 与 stderr 重定向都落在 <dataDir>/logs/，
       目录不存在时 QEMU 的 file chardev 建文件会失败并直接退出（实例进程随之
       消失），所以启动前先确保它存在。 */
    ensure_log_dir(s_data_dir);

    /* VmConfig 里的 netMode 取值为 NONE / NAT，默认 NAT */
    char net_mode[16] = "NAT";
    json_get_string(s_config_json, "netMode", net_mode, sizeof(net_mode));
    const bool want_network = (strcmp(net_mode, "NONE") != 0);

    /* 内存 / vCPU 数从 VmConfig 取（缺省或非法时回落 2048 MB / 4 核） */
    const int memory_mb = json_get_int(s_config_json, "memoryMb", 2048);
    const int cores = json_get_int(s_config_json, "cores", 4);
    /* 访客显示分辨率（可选）。TCG 下像素量直接决定合成耗时，运行期可调。 */
    const int disp_w = json_get_int(s_config_json, "width", 720);
    const int disp_h = json_get_int(s_config_json, "height", 1280);

    /* 后端名（VmBackend.name，缺省 TCG）。KVM 时 vm_qemu 用 -accel kvm。 */
    char backend[32] = "QEMU_TCG";
    json_get_string(s_config_json, "backend", backend, sizeof(backend));

    VmQemuParams params = {
            .kernel_path = s_path_kernel,
            .initrd_path = s_path_initrd,
            .system_img_path = s_path_system,
            .vendor_img_path = s_path_vendor,
            .product_img_path = s_path_product,
            .system_ext_img_path = s_path_system_ext,
            .metadata_img_path = s_path_metadata,
            .userdata_img_path = s_path_userdata,
            .serial_log_path = s_path_console,
            .memory_mb = memory_mb,
            .cores = cores,
            .display_width = disp_w,
            .display_height = disp_h,
            .enable_network = want_network,
            .backend_name = backend,
    };

    LOGI("boot: kernel=%s", s_path_kernel);
    LOGI("boot: system=%s", s_path_system);

    if (vm_qemu_start(&params) == 0) {
        LOGI("boot: QEMU 已在后台线程启动");
        /*
         * B1 子进程模式：访客帧缓冲留在子进程内存里，本进程的
         * vmhost_display_* 后端永远是空的。必须打开文件握手回传，
         * 目录与子进程的 VMHOST_FRAME_DIR 保持一致（<dataDir>/logs）。
         */
        if (vm_qemu_is_child_process()) {
            char frame_dir[PATH_CAP];
            snprintf(frame_dir, sizeof(frame_dir), "%s/logs", s_data_dir);
            vm_frame_relay_set_dir(frame_dir);
            LOGI("boot: 子进程模式，已启用帧回传（目录 %s）", frame_dir);
        } else {
            LOGI("boot: 进程内嵌 QEMU，使用进程内显示后端");
        }
    } else {
        LOGE("boot: QEMU 启动失败（详见上面的参数与文件检查日志）");
    }
}
#endif /* VM_WITH_QEMU */

typedef struct {
    int            vm_id;
    int            running;
    int            surface_width;
    int            surface_height;
    ANativeWindow* window;
    char           config[8192];
} VmEngineHandle;

static struct android_app* s_app = NULL;
static VmEngineHandle*      s_instance = NULL;

/* ------------------------------------------------------------------ */
/* JNI 实现                                                             */
/* ------------------------------------------------------------------ */

JNIEXPORT jlong JNICALL
Java_com_vm_engine_VmEngine_create(JNIEnv* env, jclass clazz, jstring config_json) {
    VmEngineHandle* handle = (VmEngineHandle*) calloc(1, sizeof(VmEngineHandle));
    if (handle == NULL) {
        return 0;
    }
    handle->vm_id = -1;

    if (config_json != NULL) {
        const char* utf = (*env)->GetStringUTFChars(env, config_json, NULL);
        if (utf != NULL) {
            strncpy(handle->config, utf, sizeof(handle->config) - 1);
            (*env)->ReleaseStringUTFChars(env, config_json, utf);
        }
    }
    LOGI("create, config=%s", handle->config);
    return (jlong) (intptr_t) handle;
}

JNIEXPORT void JNICALL
Java_com_vm_engine_VmEngine_attachSurface(JNIEnv* env, jclass clazz, jlong handle_ptr, jobject surface) {
    VmEngineHandle* handle = (VmEngineHandle*) (intptr_t) handle_ptr;
    if (handle == NULL || surface == NULL) {
        return;
    }
    if (handle->window != NULL) {
        ANativeWindow_release(handle->window);
        handle->window = NULL;
    }
    handle->window = ANativeWindow_fromSurface(env, surface);
    if (handle->window != NULL) {
        handle->surface_width = ANativeWindow_getWidth(handle->window);
        handle->surface_height = ANativeWindow_getHeight(handle->window);
        LOGI("attachSurface %dx%d", handle->surface_width, handle->surface_height);
    }
}

JNIEXPORT void JNICALL
Java_com_vm_engine_VmEngine_start(JNIEnv* env, jclass clazz, jlong handle_ptr) {
    VmEngineHandle* handle = (VmEngineHandle*) (intptr_t) handle_ptr;
    if (handle == NULL) {
        return;
    }
    handle->running = 1;
    /* TODO(M0): 打开 qcow2、加载 kernel、启动 QEMU 主循环 */
    LOGW("start: engine is a stub, QEMU is not wired in yet");
}

JNIEXPORT void JNICALL
Java_com_vm_engine_VmEngine_pause(JNIEnv* env, jclass clazz, jlong handle_ptr) {
    VmEngineHandle* handle = (VmEngineHandle*) (intptr_t) handle_ptr;
    if (handle != NULL) {
        handle->running = 0;
    }
}

JNIEXPORT void JNICALL
Java_com_vm_engine_VmEngine_resume(JNIEnv* env, jclass clazz, jlong handle_ptr) {
    VmEngineHandle* handle = (VmEngineHandle*) (intptr_t) handle_ptr;
    if (handle != NULL) {
        handle->running = 1;
    }
}

JNIEXPORT void JNICALL
Java_com_vm_engine_VmEngine_sendInput(JNIEnv* env, jclass clazz, jlong handle_ptr,
                                      jint type, jfloat x, jfloat y, jint code) {
    (void) handle_ptr;
    /* TODO(M1): 注入 virtio-input */
    LOGI("sendInput type=%d x=%.1f y=%.1f code=%d", type, x, y, code);
}

JNIEXPORT void JNICALL
Java_com_vm_engine_VmEngine_destroy(JNIEnv* env, jclass clazz, jlong handle_ptr) {
    VmEngineHandle* handle = (VmEngineHandle*) (intptr_t) handle_ptr;
    if (handle == NULL) {
        return;
    }
    if (handle->window != NULL) {
        ANativeWindow_release(handle->window);
    }
    free(handle);
}

JNIEXPORT jstring JNICALL
Java_com_vm_engine_VmEngine_nativeVersion(JNIEnv* env, jclass clazz) {
    return (*env)->NewStringUTF(env, ENGINE_VERSION);
}

/* ------------------------------------------------------------------ */
/* NativeActivity 生命周期钩子                                          */
/* ------------------------------------------------------------------ */

/**
 * 从 Activity 的 Intent 中读取配置串（宿主通过 VmConfig.EXTRA_CONFIG 传入）。
 * 注意：ANativeActivity 结构体本身不暴露 intent，需要经 JNI 调 Activity.getIntent()。
 */
static void log_intent_config(JNIEnv* env, jobject activity) {
    if (activity == NULL) {
        LOGW("intent config: <no activity>");
        return;
    }

    jclass activity_class = (*env)->GetObjectClass(env, activity);
    if (activity_class == NULL) {
        return;
    }
    jmethodID get_intent = (*env)->GetMethodID(
            env, activity_class, "getIntent", "()Landroid/content/Intent;");
    if (get_intent == NULL) {
        LOGW("intent config: Activity.getIntent not found");
        (*env)->DeleteLocalRef(env, activity_class);
        return;
    }

    jobject intent = (*env)->CallObjectMethod(env, activity, get_intent);
    if (intent == NULL) {
        LOGW("intent config: <null intent>");
        (*env)->DeleteLocalRef(env, activity_class);
        return;
    }

    jclass intent_class = (*env)->GetObjectClass(env, intent);
    jmethodID get_string_extra = (intent_class != NULL)
            ? (*env)->GetMethodID(env, intent_class,
                                  "getStringExtra", "(Ljava/lang/String;)Ljava/lang/String;")
            : NULL;

    if (get_string_extra != NULL) {
        jstring key = (*env)->NewStringUTF(env, EXTRA_CONFIG);
        jstring value = (jstring) (*env)->CallObjectMethod(env, intent, get_string_extra, key);
        if (value != NULL) {
            const char* utf = (*env)->GetStringUTFChars(env, value, NULL);
            LOGI("intent config: %s", utf != NULL ? utf : "<null>");
            if (utf != NULL) {
                /* 存下来，供 Surface 就绪时拼 QEMU 参数 */
                snprintf(s_config_json, sizeof(s_config_json), "%s", utf);
                (*env)->ReleaseStringUTFChars(env, value, utf);
            }
            (*env)->DeleteLocalRef(env, value);
        } else {
            LOGW("intent config: <missing>");
        }
        (*env)->DeleteLocalRef(env, key);
    }

    if (intent_class != NULL) {
        (*env)->DeleteLocalRef(env, intent_class);
    }
    (*env)->DeleteLocalRef(env, intent);
    (*env)->DeleteLocalRef(env, activity_class);
}

void vm_engine_on_instance_start(struct android_app* app) {
    s_app = app;

    JavaVM* java_vm = app->activity->vm;
    JNIEnv* env = NULL;
    if ((*java_vm)->GetEnv(java_vm, (void**) &env, JNI_VERSION_1_6) != JNI_OK) {
        if ((*java_vm)->AttachCurrentThread(java_vm, &env, NULL) != JNI_OK) {
            LOGW("on_instance_start: cannot attach JNI env");
            return;
        }
    }
    log_intent_config(env, app->activity->clazz);
    LOGI("on_instance_start: engine %s", ENGINE_VERSION);
}

void vm_engine_on_window_ready(struct android_app* app) {
    s_app = app;
    LOGI("on_window_ready: bind guest framebuffer to this surface (TODO M1)");

#ifdef VM_WITH_QEMU
    /* Surface 就绪 = 实例开始运行，此时拉起 QEMU。
       当前 QEMU 以 -display none 运行，画面稍后由渲染后端接管。 */
    s_restore_retried = false;   /* 每次新窗口就绪都允许一次「坏快照回退」 */
    vm_engine_boot_qemu();
#endif
}

void vm_engine_on_window_gone(struct android_app* app) {
    (void) app;
    LOGI("on_window_gone: pause guest rendering");
}

void vm_engine_on_instance_stop(struct android_app* app) {
    (void) app;
    if (s_instance != NULL) {
        free(s_instance);
        s_instance = NULL;
    }
    LOGI("on_instance_stop: flush userdata overlay (TODO M1)");
}

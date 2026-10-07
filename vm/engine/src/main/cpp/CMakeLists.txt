cmake_minimum_required(VERSION 3.22.1)
project(vmengine C)

# NDK 自带的 NativeActivity 胶水层
set(NATIVE_APP_GLUE "${CMAKE_ANDROID_NDK}/sources/android/native_app_glue")

set(ENGINE_SOURCES
        src/vm_engine.c
        src/vm_activity.c
        src/vm_render.c
        src/vm_guest_display.c
        src/vm_input.c
        # NativeActivity 的入口 ANativeActivity_onCreate 由这个胶水层提供，
        # 少了它 NativeActivity 会 dlsym 失败、实例根本起不来。
        "${NATIVE_APP_GLUE}/android_native_app_glue.c")

# ------------------------------------------------------------------
# QEMU 是否可用：由 scripts/package_qemu_static.sh 产出的预编译产物决定。
# 没有产物时退化为纯骨架，保证工程仍可编译。
# ------------------------------------------------------------------
set(QEMU_PREBUILT "${CMAKE_CURRENT_SOURCE_DIR}/prebuilt/qemu/${ANDROID_ABI}")
set(VMLIB_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}")
set(VM_WITH_QEMU FALSE)

if(EXISTS "${QEMU_PREBUILT}/libqemu_objs.a")
    set(VM_WITH_QEMU TRUE)
    list(APPEND ENGINE_SOURCES src/vm_qemu.c)
    message(STATUS "vmengine: 找到 QEMU 预编译产物，将链接进 libvmengine.so (${ANDROID_ABI})")
else()
    message(STATUS "vmengine: 未找到 ${QEMU_PREBUILT}/libqemu_objs.a，构建为纯骨架")
endif()

add_library(vmengine SHARED ${ENGINE_SOURCES})

target_include_directories(vmengine PRIVATE
        "${NATIVE_APP_GLUE}"
        src)

target_link_libraries(vmengine PRIVATE
        android
        log
        EGL
        GLESv2)

if(VM_WITH_QEMU)
    target_compile_definitions(vmengine PRIVATE VM_WITH_QEMU=1)

    # QEMU 的静态库彼此循环依赖，必须用 --start-group/--end-group 包住。
    # glib 系列与 pixman 用同一份 jniLibs 里的 .so，运行时与应用同目录即可命中。
    #
    # --whole-archive 是**必须**的，不是可选优化：
    # QEMU 的 QOM 类型/接口全靠 type_init()/module_init() 的
    # __attribute__((constructor)) 注册，承载它们的对象文件里没有任何被引用的符号，
    # 普通归档链接会把这类对象整片丢掉 —— 类型注册随之消失，qemu_init() 里
    # 枚举机器类型时就会在 qom/object.c 报 "missing interface" 然后 abort()。
    # 真机上表现为启动瞬间 SIGABRT，栈顶是 type_initialize。
    target_link_libraries(vmengine PRIVATE
            -Wl,--start-group
            -Wl,--whole-archive
            "${QEMU_PREBUILT}/libqemu_objs.a"
            -Wl,--no-whole-archive
            "${QEMU_PREBUILT}/libqemuutil.a"
            "${QEMU_PREBUILT}/libfdt.a"
            "${QEMU_PREBUILT}/libvduse.a"
            "${QEMU_PREBUILT}/libz.a"
            "${VMLIB_DIR}/libglib-2.0.so"
            "${VMLIB_DIR}/libgio-2.0.so"
            "${VMLIB_DIR}/libgobject-2.0.so"
            "${VMLIB_DIR}/libgmodule-2.0.so"
            "${VMLIB_DIR}/libpixman-1.so"
            "${VMLIB_DIR}/libslirp.so"
            -Wl,--end-group
            m)
endif()

# NativeActivity 入口由静态胶水层提供，防止被链接器裁掉。
# 链接 QEMU 后入口同样需要保留（QEMU 自带 main，会与之共存）。
set_target_properties(vmengine PROPERTIES
        LINK_FLAGS "-u ANativeActivity_onCreate")

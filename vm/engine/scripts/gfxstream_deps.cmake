# VMHost: 为 gfxstream 的独立（非 AOSP 树）构建预置依赖 target。
#
# 用法：cmake -DCMAKE_PROJECT_INCLUDE=<本文件> \
#            -DVMHOST_AEMU_DIR=... -DVMHOST_AEMU_LIB_DIR=... -DVMHOST_GFXSTREAM_ROOT=...
#
# 作用：gfxstream/third-party/CMakeLists.txt 里 aemu / flatbuffers / libdrm / EGL 头
# 四组依赖都是「三选一」（AOSP 相对路径 / SYSTEM pkg-config / DOWNLOAD FetchContent），
# 我们三者都走不通，所以在它之前把这些 target 直接定义好——那些块都带
# `if(NOT TARGET xxx)` 守卫，于是会被整段跳过。
#
# CMAKE_PROJECT_INCLUDE 在顶层 project() 之后、add_subdirectory() 之前执行，
# 因此这里建的 target 对后续所有子目录可见。

foreach(required VMHOST_AEMU_DIR VMHOST_AEMU_LIB_DIR VMHOST_GFXSTREAM_ROOT)
    if(NOT DEFINED ${required})
        message(FATAL_ERROR "gfxstream_deps.cmake: 缺少必需变量 ${required}")
    endif()
endforeach()

# ------------------------------------------------------------------ aemu 头
add_library(aemu-base.headers INTERFACE)
target_include_directories(
    aemu-base.headers INTERFACE ${VMHOST_AEMU_DIR}/base/include)

add_library(aemu-host-common.headers INTERFACE)
target_include_directories(
    aemu-host-common.headers
    INTERFACE ${VMHOST_AEMU_DIR}/host-common/include
              ${VMHOST_AEMU_DIR}/third-party/cuda/include
              ${VMHOST_AEMU_DIR}/snapshot/include)
target_link_libraries(aemu-host-common.headers INTERFACE aemu-base.headers)

add_library(gfxstream-snapshot.headers INTERFACE)
target_include_directories(
    gfxstream-snapshot.headers INTERFACE ${VMHOST_AEMU_DIR}/snapshot/include)

# ------------------------------------------------------- aemu 静态库（导入）
add_library(logging-base STATIC IMPORTED GLOBAL)
set_target_properties(
    logging-base PROPERTIES IMPORTED_LOCATION
                            ${VMHOST_AEMU_LIB_DIR}/host-common/liblogging-base.a)
target_link_libraries(
    logging-base INTERFACE aemu-base.headers aemu-host-common.headers)

add_library(aemu-base STATIC IMPORTED GLOBAL)
set_target_properties(
    aemu-base PROPERTIES IMPORTED_LOCATION
                         ${VMHOST_AEMU_LIB_DIR}/base/libaemu-base.a)
target_link_libraries(
    aemu-base INTERFACE aemu-base.headers aemu-host-common.headers logging-base)

add_library(gfxstream-snapshot STATIC IMPORTED GLOBAL)
set_target_properties(
    gfxstream-snapshot
    PROPERTIES IMPORTED_LOCATION
               ${VMHOST_AEMU_LIB_DIR}/snapshot/libgfxstream-snapshot.a)
target_link_libraries(
    gfxstream-snapshot INTERFACE aemu-base.headers aemu-host-common.headers)

add_library(aemu-host-common STATIC IMPORTED GLOBAL)
set_target_properties(
    aemu-host-common
    PROPERTIES IMPORTED_LOCATION
               ${VMHOST_AEMU_LIB_DIR}/host-common/libaemu-host-common.a)
target_link_libraries(
    aemu-host-common
    INTERFACE aemu-host-common.headers aemu-base gfxstream-snapshot logging-base)

add_library(aemu_common INTERFACE)
target_link_libraries(aemu_common INTERFACE aemu-base aemu-host-common)

# --------------------------------------------------------------- flatbuffers
# gfxstream 尾部有 `if(NOT TARGET flatbuffers) FATAL_ERROR`，但全树没有任何
# CMakeLists 真正引用它 —— 给个空 INTERFACE 即可。
if(NOT TARGET flatbuffers)
    add_library(flatbuffers INTERFACE)
endif()

# ------------------------------------------------------------------ libdrm 头
# 只有 host/magma 需要（`#include <i915_drm.h>`），仓内自带：
# gfxstream/guest/mesa/include/drm-uapi/i915_drm.h
if(NOT TARGET libdrm_headers)
    add_library(libdrm_headers INTERFACE)
    target_include_directories(
        libdrm_headers INTERFACE ${VMHOST_GFXSTREAM_ROOT}/guest/mesa/include/drm-uapi)
endif()

# ---------------------------------------------------------------- EGL 头（绕开 ANGLE）
# 仓内自带 Khronos EGL/GLES 头。定义了这个 target，third-party 里那段
# 「AOSP 分支找不到 ANGLE 就 FATAL_ERROR」的代码就整段被跳过。
if(NOT TARGET gfxstream_egl_headers)
    add_library(gfxstream_egl_headers INTERFACE)
    target_include_directories(
        gfxstream_egl_headers INTERFACE ${VMHOST_GFXSTREAM_ROOT}/common/opengl/include)
endif()

# ---------------------------------------------------------------- AOSP 头补丁目录
# host 侧（经 vulkan/vk_android_native_buffer_gfxstream.h，在 -DANDROID 下）
# 需要 <cutils/native_handle.h>；仓内自带一份（guest/mesa/include/android_stub），
# 但那个目录同时还有 android/ log/ sync/ system/ 等会和 NDK 冲突的头，
# 所以构建脚本只把 cutils/native_handle.h 单独拷进 shim 目录再挂上来。
if(DEFINED VMHOST_EXTRA_INCLUDE)
    include_directories(${VMHOST_EXTRA_INCLUDE})
endif()


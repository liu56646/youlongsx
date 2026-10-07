package com.vm.core

/** 全局常量。 */
object VmConstants {

    /** 与 AndroidManifest 中声明的实例进程数量保持一致（:vm1 ~ :vm4）。 */
    const val MAX_INSTANCES = 4

    /** 默认访客镜像标签（对应 assets/guest/<tag>.zip 或 files/images/<tag>/）。 */
    const val DEFAULT_IMAGE_TAG = "p11_arm64"

    /** 引擎原生库名（不含 lib 前缀与 .so 后缀，需与 meta-data android.app.lib_name 一致）。 */
    const val ENGINE_LIB_NAME = "vmengine"
}

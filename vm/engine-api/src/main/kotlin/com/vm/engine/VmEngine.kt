package com.vm.engine

import android.view.Surface

/**
 * 虚拟机引擎的 JNI 门面（宿主进程侧）。
 *
 * 原生实现位于 `libvmengine.so`（[engine] 模块），骨架阶段提供：
 * - [android.app.NativeActivity] 入口（实例进程直接渲染上屏）
 * - 下述 JNI 控制接口（宿主侧编排用）
 *
 * 真实实现将把这里的调用转成 QEMU 的生命周期与 virtio 注入操作。
 */
object VmEngine {

    private const val LIB_NAME = "vmengine"

    /** 原生库是否成功加载。加载失败时上层应降级为"引擎未构建"状态。 */
    val isAvailable: Boolean by lazy {
        runCatching { System.loadLibrary(LIB_NAME) }.isSuccess
    }

    /** 引擎版本号；加载失败返回 "unavailable"。 */
    @JvmStatic
    fun version(): String = if (isAvailable) nativeVersion() else "unavailable"

    /** 创建引擎实例，返回句柄（0 表示失败）。 */
    @JvmStatic
    external fun create(configJson: String): Long

    /** 绑定渲染目标 Surface。 */
    @JvmStatic
    external fun attachSurface(handle: Long, surface: Surface)

    /** 启动虚拟机（加载内核、挂载镜像）。 */
    @JvmStatic
    external fun start(handle: Long)

    @JvmStatic
    external fun pause(handle: Long)

    @JvmStatic
    external fun resume(handle: Long)

    /**
     * 注入输入事件。
     * @param type 0=触摸 1=按键
     * @param x/y 触摸坐标（type=0 时有效）
     * @param code 按键码（type=1 时有效）
     */
    @JvmStatic
    external fun sendInput(handle: Long, type: Int, x: Float, y: Float, code: Int)

    /** 销毁实例并释放资源。 */
    @JvmStatic
    external fun destroy(handle: Long)

    @JvmStatic
    private external fun nativeVersion(): String
}

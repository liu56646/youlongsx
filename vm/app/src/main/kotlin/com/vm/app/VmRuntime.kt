package com.vm.app

import com.vm.core.VmInfo

/**
 * 实例运行态（仅进程内、best-effort）。
 *
 * 骨架阶段不跨进程查询真实状态；M4 引入每实例服务后，
 * 这里改为向 IVmInstance 查询。
 */
object VmRuntime {

    private val running = mutableSetOf<Int>()

    @Synchronized
    fun markRunning(vmId: Int) {
        running += vmId
    }

    @Synchronized
    fun markStopped(vmId: Int) {
        running -= vmId
    }

    @Synchronized
    fun isRunning(vmId: Int): Boolean = vmId in running

    @Synchronized
    fun runningIds(): Set<Int> = running.toSet()

    @Synchronized
    fun clear() = running.clear()
}

/** 便捷扩展：该实例当前是否在运行。 */
val VmInfo.isRunning: Boolean get() = VmRuntime.isRunning(vmId)

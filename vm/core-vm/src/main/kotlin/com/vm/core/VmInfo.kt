package com.vm.core

/** 实例的持久化元数据（运行时状态不落盘）。 */
data class VmInfo(
    val vmId: Int,
    val name: String,
    val createdAt: Long,
    val imageTag: String = VmConstants.DEFAULT_IMAGE_TAG
)

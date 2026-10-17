package com.vm.core

/**
 * 访客「设备身份」——决定虚拟出来的手机对外报告的品牌、型号、指纹等。
 *
 * 身份的唯一落点是 guest 各分区 build.prop 里的分区属性：
 *  - product 分区（`ro.product.product.*` / `ro.product.build.*`）
 *  - system  分区（`ro.product.system.*` / `ro.system.build.*` / `ro.build.*`）
 *
 * guest 里 `android.os.Build.*` 的取值，规则是：
 *  - MODEL / BRAND / MANUFACTURER / DEVICE：init 从 `ro.product.<分区>.<名>` 合成；
 *  - FINGERPRINT：**init 合成**出来的——
 *      `${ro.product.brand}/${ro.product.name}/${ro.product.device}:` +
 *      `${ro.build.version.release}/${ro.build.id}/${ro.build.version.incremental}:${ro.build.type}/${ro.build.tags}`
 *    也就是说 fingerprint 的品牌/机型段来自 product 分区，而版本段（release/build.id）
 *    来自 **system** 分区。
 *
 * 由此得到两条硬约束：
 *  1. **机型版本必须与镜像 system 版本一致**。本镜像 system 是 Android 11，故清单里
 *     只放 Android 11 机型；否则会出现"型号说 13、指纹说 11"的矛盾。
 *  2. 让 fingerprint 精确匹配机型，需要同时改 system 的 `ro.build.id`（release/sdk
 *     保持不变，改动它们会让"声明版本"与真实框架版本错乱）。
 */
data class VmDeviceProfile(
    /** 稳定标识，落盘在实例元数据里。 */
    val id: String,
    /** 界面上展示的名字。 */
    val displayName: String,
    val brand: String,
    val device: String,
    val manufacturer: String,
    val model: String,
    val name: String,
    val release: String,
    val sdk: Int,
    val buildId: String
) {
    /**
     * 与 init 的合成规则保持一致：
     * `<brand>/<name>/<device>:<release>/<buildId>:<type>/<tags>`。
     */
    val fingerprint: String
        get() = "$brand/$name/$device:$release/$buildId:userdebug/test-keys"
}

/**
 * 内置机型目录。
 *
 * 值的来源：`pixel_5` / `pixel_4a` 取自本仓既有的 `tools/set_device_profile.sh`；
 * 其余 Pixel 机型取同一批次（2021-08，Android 11）的公开版本号。
 * 新增机型：补进 [ALL] 即可，App 的机型选择框会自动出现。
 *
 * 注意：全部是 **Android 11（API 30）** 机型，与当前 `p11_arm64` 镜像的 system 版本一致。
 */
object VmDeviceCatalog {

    val ALL: List<VmDeviceProfile> = listOf(
        VmDeviceProfile(
            id = "pixel_5", displayName = "Pixel 5",
            brand = "google", device = "redfin", manufacturer = "Google",
            model = "Pixel 5", name = "redfin",
            release = "11", sdk = 30, buildId = "RQ3A.210805.001.A1"
        ),
        VmDeviceProfile(
            id = "pixel_4a_5g", displayName = "Pixel 4a (5G)",
            brand = "google", device = "bramble", manufacturer = "Google",
            model = "Pixel 4a (5G)", name = "bramble",
            release = "11", sdk = 30, buildId = "RQ3A.210805.001.A1"
        ),
        VmDeviceProfile(
            id = "pixel_4a", displayName = "Pixel 4a",
            brand = "google", device = "sunfish", manufacturer = "Google",
            model = "Pixel 4a", name = "sunfish",
            release = "11", sdk = 30, buildId = "RQ3A.210805.001.A1"
        ),
        VmDeviceProfile(
            id = "pixel_4", displayName = "Pixel 4",
            brand = "google", device = "flame", manufacturer = "Google",
            model = "Pixel 4", name = "flame",
            release = "11", sdk = 30, buildId = "RQ3A.210805.001.A1"
        ),
    )

    fun byId(id: String?): VmDeviceProfile? = ALL.firstOrNull { it.id == id }

    /** 默认机型（与镜像出厂身份一致）。 */
    val default: VmDeviceProfile
        get() = ALL.first()
}

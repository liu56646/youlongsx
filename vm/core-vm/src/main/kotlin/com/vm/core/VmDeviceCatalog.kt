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
        VmDeviceProfile(
            id = "pixel_4_xl", displayName = "Pixel 4 XL",
            brand = "google", device = "coral", manufacturer = "Google",
            model = "Pixel 4 XL", name = "coral",
            release = "11", sdk = 30, buildId = "RQ3A.210805.001.A1"
        ),
        VmDeviceProfile(
            id = "pixel_5a", displayName = "Pixel 5a",
            brand = "google", device = "barbet", manufacturer = "Google",
            model = "Pixel 5a", name = "barbet",
            release = "11", sdk = 30, buildId = "RQ3A.210805.001.A1"
        ),
        VmDeviceProfile(
            id = "pixel_3", displayName = "Pixel 3",
            brand = "google", device = "blueline", manufacturer = "Google",
            model = "Pixel 3", name = "blueline",
            release = "11", sdk = 30, buildId = "RQ3A.210805.001.A1"
        ),
        VmDeviceProfile(
            id = "pixel_3_xl", displayName = "Pixel 3 XL",
            brand = "google", device = "crosshatch", manufacturer = "Google",
            model = "Pixel 3 XL", name = "crosshatch",
            release = "11", sdk = 30, buildId = "RQ3A.210805.001.A1"
        ),
        VmDeviceProfile(
            id = "pixel_3a", displayName = "Pixel 3a",
            brand = "google", device = "sargo", manufacturer = "Google",
            model = "Pixel 3a", name = "sargo",
            release = "11", sdk = 30, buildId = "RQ3A.210805.001.A1"
        ),
        VmDeviceProfile(
            id = "pixel_3a_xl", displayName = "Pixel 3a XL",
            brand = "google", device = "bonito", manufacturer = "Google",
            model = "Pixel 3a XL", name = "bonito",
            release = "11", sdk = 30, buildId = "RQ3A.210805.001.A1"
        ),
        VmDeviceProfile(
            id = "samsung_s21", displayName = "Galaxy S21 5G",
            brand = "samsung", device = "o1s", manufacturer = "samsung",
            model = "SM-G991B", name = "o1s",
            release = "11", sdk = 30, buildId = "RP1A.200720.012"
        ),
        VmDeviceProfile(
            id = "samsung_s20", displayName = "Galaxy S20 5G",
            brand = "samsung", device = "y2s", manufacturer = "samsung",
            model = "SM-G986B", name = "y2s",
            release = "11", sdk = 30, buildId = "RP1A.200720.012"
        ),
        VmDeviceProfile(
            id = "samsung_note20", displayName = "Galaxy Note20 Ultra",
            brand = "samsung", device = "c2s", manufacturer = "samsung",
            model = "SM-N986B", name = "c2s",
            release = "11", sdk = 30, buildId = "RP1A.200720.012"
        ),
        VmDeviceProfile(
            id = "samsung_a52", displayName = "Galaxy A52",
            brand = "samsung", device = "a52q", manufacturer = "samsung",
            model = "SM-A525F", name = "a52q",
            release = "11", sdk = 30, buildId = "RP1A.200720.012"
        ),
        VmDeviceProfile(
            id = "oneplus_9", displayName = "OnePlus 9",
            brand = "OnePlus", device = "lemonade", manufacturer = "OnePlus",
            model = "LE2113", name = "lemonade",
            release = "11", sdk = 30, buildId = "RKQ1.201112.002"
        ),
        VmDeviceProfile(
            id = "oneplus_8", displayName = "OnePlus 8",
            brand = "OnePlus", device = "instantnoodle", manufacturer = "OnePlus",
            model = "IN2013", name = "instantnoodle",
            release = "11", sdk = 30, buildId = "RP1A.201005.001"
        ),
        VmDeviceProfile(
            id = "xiaomi_mi11", displayName = "Xiaomi Mi 11",
            brand = "Xiaomi", device = "venus", manufacturer = "Xiaomi",
            model = "M2011K2C", name = "venus",
            release = "11", sdk = 30, buildId = "RKQ1.201112.002"
        ),
        VmDeviceProfile(
            id = "xiaomi_k40", displayName = "Redmi K40",
            brand = "Redmi", device = "alioth", manufacturer = "Xiaomi",
            model = "M2012K11AC", name = "alioth",
            release = "11", sdk = 30, buildId = "RKQ1.201112.002"
        ),
        VmDeviceProfile(
            id = "xiaomi_mi10", displayName = "Xiaomi Mi 10",
            brand = "Xiaomi", device = "umi", manufacturer = "Xiaomi",
            model = "M2001J2C", name = "umi",
            release = "11", sdk = 30, buildId = "RKQ1.200826.002"
        ),
        VmDeviceProfile(
            id = "oppo_findx3", displayName = "OPPO Find X3 Pro",
            brand = "OPPO", device = "findx3", manufacturer = "OPPO",
            model = "PEEM00", name = "findx3",
            release = "11", sdk = 30, buildId = "RKQ1.201112.002"
        ),
        VmDeviceProfile(
            id = "vivo_x60", displayName = "vivo X60 Pro",
            brand = "vivo", device = "v2046", manufacturer = "vivo",
            model = "V2046A", name = "v2046",
            release = "11", sdk = 30, buildId = "RP1A.200720.012"
        ),
        VmDeviceProfile(
            id = "honor_50", displayName = "Honor 50",
            brand = "HONOR", device = "hnb", manufacturer = "HONOR",
            model = "NTH-AN00", name = "hnb",
            release = "11", sdk = 30, buildId = "RP1A.200720.012"
        ),
    )

    fun byId(id: String?): VmDeviceProfile? = ALL.firstOrNull { it.id == id }

    /** 默认机型（与镜像出厂身份一致）。 */
    val default: VmDeviceProfile
        get() = ALL.first()
}

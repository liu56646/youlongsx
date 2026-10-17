package com.vm.core

/**
 * 一个可用的访客系统镜像。
 *
 * @param tag         镜像标识，同时也是压缩包文件名（`<base>/<tag>.zip`）
 * @param displayName 界面上展示的名字
 * @param apiLevel    对应的 Android API 级别
 * @param zipMb       压缩包大小（约），用于提示用户要下多少流量
 * @param supportsDeviceProfile 该镜像是否支持实例级机型身份改写。
 *                     依赖镜像包里有 product.img / system.img 且 build.prop
 *                     带 `# begin` 段标记；缺 product 的镜像直接不支持。
 */
data class VmGuestImage(
    val tag: String,
    val displayName: String,
    val apiLevel: Int,
    val zipMb: Int,
    val supportsDeviceProfile: Boolean = true
)

/**
 * 内置的访客系统版本目录。
 *
 * 只登记「已经用 `tools/make_guest_image.sh` 打包成功、且镜像结构与本引擎兼容」
 * 的版本。加新版本的流程：
 *
 *     cd vm/tools && ./make_guest_image.sh <api-level>
 *     # 产出 dist/<tag>.zip，上传到镜像服务器，再把条目补进下面的 ALL
 *
 * 注意：Android 13+ 的部分镜像改用 `super.img` 动态分区，本引擎目前只支持
 * `system.img + vendor.img` 的经典布局，脚本会在那种情况下直接报错退出。
 */
object VmGuestCatalog {

    /**
     * 可选的访客系统版本 —— **只登记实测能跑起来的**。
     *
     * 各版本的启动差异由引擎按镜像布局自动分流（vm_qemu.c）：
     *   - p11/p13：GPT / 纯 ext4 分区盘 + virtio-gpu + virtio-input；
     *   - p9：system-as-root（root=/dev/vda1，不下发 initrd），强制 virtio-mmio 保盘序；
     *   - p71：Linux 3.18 → legacy virtio-mmio + goldfish-events 输入 + goldfish_fb 帧回传。
     *
     * 机型身份改写对 p11/p13 提供：p71/p9 的包里没有 product 分区，
     * 创建时直接跳过机型选择，使用镜像出厂身份。p13 的 product.img 没有
     * `# begin` 段标记，VmDeviceIdentity 会走同长度无标记 build.prop 改写。
     */
    val ALL: List<VmGuestImage> = listOf(
        VmGuestImage("p11_arm64", "Android 11", 30, 506),
        VmGuestImage("p9_arm64", "Android 9", 28, 396, supportsDeviceProfile = false),
        VmGuestImage("p71_arm64", "Android 7.1", 25, 292, supportsDeviceProfile = false),
        VmGuestImage("p13_arm64", "Android 13", 33, 592),
    )

    /** 规划中的版本（暂不可用），仅用于界面提示，不要放进 [ALL]。 */
    val PLANNED_HINT: String = "更多 Android 版本适配中"

    fun byTag(tag: String): VmGuestImage? = ALL.firstOrNull { it.tag == tag }

    /** 默认版本：新建实例不指定版本时用它。 */
    val default: VmGuestImage
        get() = byTag(VmConstants.DEFAULT_IMAGE_TAG) ?: ALL.last()

    /**
     * 拼出某个版本的下载地址。
     * 约定服务器上按 `<base>/<tag>.zip` 放置，加版本只需要多放一个文件，不用改 App。
     */
    fun downloadUrl(baseUrl: String, tag: String): String =
        baseUrl.trimEnd('/') + "/" + tag + ".zip"

    /** 展示名，找不到时退回 tag。 */
    fun displayNameOf(tag: String): String = byTag(tag)?.displayName ?: tag
}

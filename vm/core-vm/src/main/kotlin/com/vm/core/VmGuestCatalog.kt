package com.vm.core

/**
 * 一个可用的访客系统镜像。
 *
 * @param tag         镜像标识，同时也是压缩包文件名（`<base>/<tag>.zip`）
 * @param displayName 界面上展示的名字
 * @param apiLevel    对应的 Android API 级别
 * @param zipMb       压缩包大小（约），用于提示用户要下多少流量
 */
data class VmGuestImage(
    val tag: String,
    val displayName: String,
    val apiLevel: Int,
    val zipMb: Int
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
     * p71(7.1) / p9(9) / p13(13) 的 SDK 原版镜像与本引擎的 ranchu 适配层不兼容：
     *   - ramdisk 里没有匹配内核版本的 `virtio_blk.ko`（p11 是项目专门配的 40 个 .ko），
     *     内核压根不认 virtio-blk，init 一直报 "partition(s) not found in /sys"；
     *   - p9/p13 还是 GPT + super 动态分区，引擎挂的是整盘，路径也对不上；
     *   - p9 的 first-stage init 只认设备树里的 fstab，p71 连 vendor 分区都没有。
     * 三者实测都在 init 阶段起不来。列出来只会让用户选了就失败，因此暂不登记。
     * 适配路径与阻塞点见 docs/方案B排障交接.md。
     */
    val ALL: List<VmGuestImage> = listOf(
        VmGuestImage("p11_arm64", "Android 11", 30, 506),
    )

    /** 规划中的版本（暂不可用），仅用于界面提示，不要放进 [ALL]。 */
    val PLANNED_HINT: String = "Android 7.1 / 9 / 13 适配中"

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

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

    val ALL: List<VmGuestImage> = listOf(
        VmGuestImage("p71_arm64", "Android 7.1", 25, 292),
        VmGuestImage("p9_arm64", "Android 9", 28, 393),
        VmGuestImage("p11_arm64", "Android 11", 30, 506),
        VmGuestImage("p13_arm64", "Android 13", 33, 622),
    )

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

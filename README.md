# 游龙沙箱（Youlong Sandbox）

> 在 Android 手机上运行**完整的访客 Android 系统**的自研虚拟机 / 沙箱方案（QEMU 型）。
> 支持多实例、可视化交互、免 root 安装运行未安装 APK。

---

## 1. 这是什么

「游龙沙箱」是一套 **Android-in-Android** 的系统级虚拟化方案：
用一个自编译的 QEMU（TCG 软件模拟，ranchu/goldfish 机器）在宿主 Android 手机里
跑起一个**完整的访客 Android 系统**（当前目标为自编译 AOSP，Android 11 / API 30），
并把访客画面回传、宿主触摸注入给访客，做到「像原生 App 一样使用整个访客系统」。

与常见「应用级双开 / Hook 沙箱」不同，本方案是**系统级**隔离：
访客跑自己的内核、SurfaceFlinger、init、HAL，与宿主系统互不干扰。

## 2. 架构分层

| 层 | 名称 | 说明 |
|---|---|---|
| L1 | 宿主 UI | 宿主 App（Kotlin/Gradle），实例列表、创建、启动、镜像管理 |
| L2 | 实例管理 | `core-vm`：实例元数据、磁盘 `data.img`/`meta.img`、镜像目录管理 |
| L3 | 实例运行时 | `engine`（Native C + JNI）：`:vmN` 独立进程，NativeActivity 承载 QEMU，负责显示回传与输入注入 |
| L4 | 访客系统 | 自编译 AOSP 访客镜像（kernel + system/vendor/product 等），授权由访客系统自身持有 |

## 3. 仓库结构

```
.
├─ LICENSE                     # GNU GPL v2.0（GPL-2.0-only）完整文本
├─ docs/                       # 设计与实施方案文档
│  ├─ 技术方案设计.md
│  ├─ 构建指南.md
│  ├─ opengles宿主渲染器实施方案.md
│  └─ 方案B排障交接.md
└─ vm/                         # Android 工程（YoulongSandbox）
   ├─ app/                     # L1 宿主 UI
   ├─ core-vm/                 # L2 实例管理
   ├─ engine-api/              # 引擎对外接口
   ├─ engine/                  # L3 原生引擎（链接 QEMU，见下「授权边界」）
   └─ build-aosp-exp/          # AOSP 访客侧实验脚本与补丁
```

## 4. 授权（License）

本仓库以 **GNU General Public License v2.0（GPL-2.0-only）** 发布，
完整文本见根目录 [LICENSE](./LICENSE)。

**授权边界说明**：

- `engine/` 模块**链接并派生自 QEMU**（QEMU 上游为 GPL-2.0-only），
  因此 `engine/` 及含它的最终可执行体同样为 **GPL-2.0-only**。详见
  [`vm/engine/LICENSE`](./vm/engine/LICENSE)。
- 选择 **GPL-2.0-only**（而非 AGPL-3.0 / GPL-3.0）正是为了与 QEMU 的
  GPL-2.0-only 保持兼容：GPL-2.0-only 不可升级到第 3 代，与 AGPL-3.0 不兼容。

## 5. 构建与使用

见 [`docs/构建指南.md`](docs/构建指南.md)（访客镜像制作 + QEMU 交叉编译，
WSL2 Ubuntu + Android NDK r28 实测通过）与
[`docs/技术方案设计.md`](docs/技术方案设计.md)。

---

*本仓库为独立实现，未复用任何第三方私有产物。*

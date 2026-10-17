# aemu 快照与宿主 GPU 状态可行性报告

## 结论先行

**结论：有条件能，但我们当前构建不能只靠 `virtio-gpu.c` 里的 `virgl_renderer_save_snapshot()` 链完成。**

对 `virtio-gpu + gfxstream(stream_renderer)` 这条路径，已经能确证：

1. `hw/display/virtio-gpu.c` 在 `CONFIG_STREAM_RENDERER` 下明确写成 `// NOT IMPLEMENTED`，不会调用 `g->virgl->virgl_renderer_save_snapshot()`，也不会调用 load。
2. gfxstream 的 `virtio-gpu-gfxstream-renderer` 导出 API 列表里没有 snapshot save/load API。
3. `android-qemu2-glue/emulation/virtio-goldfish-pipe.cpp` 里确实有 `pipe_virgl_renderer_save_snapshot()` / load，但它序列化的是 legacy pipe 渲染器的 contexts、resources、context-resource 关系和 timeline，不是宿主 EGL/GL 纹理、颜色缓冲和 GL 对象状态。
4. `libgfxstream-snapshot.a` 只包含 `TextureSaver.cpp.o`、`TextureLoader.cpp.o`，符号也只覆盖 TextureSaver/TextureLoader。它是纹理 payload/index 的辅助库，不是完整的宿主 GPU 快照实现。
5. 官方 emulator 的宿主 GPU 状态存在另一条路径：Android `opengles` pipe 的 `preSave/preLoad` 调用 `renderer->save/load`，再进入 `RendererImpl` 和 `FrameBuffer::onSave/onLoad`，纹理 payload 通过 `textures.bin` 的外部 TextureSaver/TextureLoader 文件保存。因此“有实现”与“QEMU virtio-gpu stream_renderer 直接 hook 有实现”不是一回事。

对 emu-36-1-release：

**已经看到的关键快照 hook 没有实质变化。** `origin/emu-34-release` 和 `origin/emu-36-1-release` 的 `hw/display/virtio-gpu.c` 在 stream_renderer 快照位置都是同样的 `// NOT IMPLEMENTED`。emu-36 确实包含一些快照、gfxstream、virtio-gpu 相关提交和修复，但没有看到它们把 `CONFIG_STREAM_RENDERER` 下的直接宿主 renderer 快照 hook 补上。

## 证据强度

| 结论 | 强度 |
| --- | --- |
| stream_renderer 下 `virtio-gpu.c` 的 virgl save/load 调用是 `// NOT IMPLEMENTED` | **已看到代码确证** |
| gfxstream glue 的 stream_renderer API 列表没有 snapshot save/load | **已看到代码确证** |
| `libgfxstream-snapshot.a` 只有 TextureSaver/TextureLoader | **已看到 archive 成员和符号确证** |
| 官方宿主 GPU 状态主路径是 `OpenglEsPipe` service -> `RendererImpl::save/load` -> `FrameBuffer::onSave/onLoad` | **已看到代码确证** |
| 纹理像素和纹理元数据会通过 TextureSaver/TextureLoader 与 `textures.bin` 保存 | **已看到代码确证** |
| emu-34 与 emu-36 的直接 virtio-gpu stream_renderer 快照 hook 相同 | **已看到两个分支的 `git show` 代码确证** |
| emu-36 对整体快照/quickboot/图形集成有别的改动 | **已看到部分 commit 和 diff 确证** |
| Vulkan 快照在 emu-34 gfxstream 路径默认是否启用 | **未完成验证，偏推断** |
| goldfish_address_space snapshot device 是否是本路径必需 | **未完成验证** |
| 跨新进程 quickboot 时 EGLImage/宿主对象是否一定能恢复 | **未完成验证，存在高风险** |

## 1. `virgl_renderer_save_snapshot()` 这条链到底是什么

### 1.1 QEMU 的直接调用点

在 `origin/emu-34-release` 和 `origin/emu-36-1-release` 中，`hw/display/virtio-gpu.c` 都是：

```c
#ifdef CONFIG_STREAM_RENDERER
    // NOT IMPLEMENTED
#else
        g->virgl->virgl_renderer_save_snapshot(f);
#endif
```

对应位置：

- `hw/display/virtio-gpu.c:1128-1134`（origin/emu-34-release，save）
- `hw/display/virtio-gpu.c:1171-1175`（origin/emu-34-release，load）
- `hw/display/virtio-gpu.c:1128-1134`（origin/emu-36-1-release，save 位置相同）

所以对 `CONFIG_STREAM_RENDERER` 构建，这一条直接链路不是“实现了但返回空”，而是**调用点本身被预处理器排除，留下 `NOT IMPLEMENTED` 注释**。

### 1.2 gfxstream glue 的导出 API

`android-qemu2-glue/emulation/virtio-gpu-gfxstream-renderer.cpp` 的 `LIST_STREAM_RENDERER_API` 只列出资源、context、fence、resource map、Vulkan info 等 API：

- `virtio-gpu-gfxstream-renderer.cpp:38-68`

列表中没有：

- `virgl_renderer_save_snapshot`
- `virgl_renderer_load_snapshot`
- 对应的 gfxstream snapshot save/load API

因此 gfxstream stream_renderer glue 本身没有提供 QEMU 侧需要的宿主快照入口。

### 1.3 legacy pipe 的 save/load 是真实现，但范围不是宿主 GL 状态

legacy pipe 路径存在实现：

- `android-qemu2-glue/emulation/virtio-goldfish-pipe.cpp:2122-2127`
  - `pipe_virgl_renderer_save_snapshot()`
  - `pipe_virgl_renderer_load_snapshot()`
- `android-qemu2-glue/emulation/virtio-goldfish-pipe.cpp:1508-1543`
  - `PipeVirglRenderer::saveSnapshot()`
  - 保存 `mFlags`、`mContexts`、`mResources`、context/resource 关系、timeline，然后调用 `guest_post_save()`。
- `android-qemu2-glue/emulation/virtio-goldfish-pipe.cpp:1559-1598`
  - `PipeVirglRenderer::loadSnapshot()`
  - 恢复上述结构和 timeline，然后调用 `guest_post_load()`。

这不是 EGL/GL 纹理、颜色缓冲、shader/program/buffer/renderbuffer 等宿主 GPU 状态的完整序列化。它主要是 virtio-gpu pipe 自己的资源与上下文簿记。

### 1.4 `libgfxstream-snapshot.a` 够不够

本机构建产物：

- `/root/vmbuild/aemu-build-arm64-v8a/snapshot/libgfxstream-snapshot.a`
- `/root/vmbuild/aemu-snapshot-build-arm64-v8a/libaemu-snapshot.a`

`ar t` 结果：

- `libgfxstream-snapshot.a` 只有：
  - `TextureLoader.cpp.o`
  - `TextureSaver.cpp.o`
- `libaemu-snapshot.a` 的已定义符号中看到的是 `PathUtils` 相关函数，不是 renderer snapshot 实现。

所以：

**`libgfxstream-snapshot.a` 本身不够。**

它提供的是 TextureSaver/TextureLoader 这层纹理文件读写能力。完整链路还需要：

- Snapshot 框架把 `textures.bin` 作为 payload 文件管理。
- Android `opengles` pipe 的 service 在 save/load 时调用 renderer。
- `RendererImpl::save/load` 调 `FrameBuffer::onSave/onLoad`。
- EGL/GL 对象状态、颜色缓冲、fence/sync 等有对应的序列化和恢复逻辑。
- 如果使用 Vulkan，还需要 Vulkan snapshot feature 和对应实现。

## 2. 官方路径下宿主 GL/纹理状态在哪里序列化

### 2.1 Android pipe 是官方 host renderer 状态的入口

`android/android-emu/android/opengl/OpenglEsPipe.cpp` 的 `EmuglPipe::Service`：

- `preLoad(stream)`：
  - `OpenglEsPipe.cpp:96-110`
  - 读取是否有 renderer。
  - 调用 `renderer->load(stream, Snapshotter::get().loader().textureLoader())`。
- `preSave(stream)`：
  - `OpenglEsPipe.cpp:124-149`
  - 调用 `renderer->pauseAllPreSave()`。
  - 写入 renderer 存在标志和 `OPENGL_SAVE_VERSION`。
  - 调用 `renderer->save(stream, Snapshotter::get().saver().textureSaver())`。
  - 另外保存 screenshot。
- service 注册：
  - `OpenglEsPipe.cpp:594`
  - `android_init_opengles_pipe()`
  - `android/android-emu/android/qemu-setup.cpp:429`

这说明官方 emulator 的宿主 GPU 状态不是通过 `virtio-gpu.c` 的 stream_renderer 分支直接保存，而是通过 Android pipe 的 service save/load 阶段进入 renderer。

### 2.2 QEMU pipe 保存阶段会调用 service 的 preSave/preLoad

`android/emu/hardware/src/android/emulation/AndroidPipe.cpp`：

- `android_pipe_guest_pre_load()`：`AndroidPipe.cpp:771-781`
- `android_pipe_guest_post_load()`：`AndroidPipe.cpp:783-791`
- `android_pipe_guest_pre_save()`：`AndroidPipe.cpp:793-801`
- `android_pipe_guest_post_save()`：`AndroidPipe.cpp:803-811`

`hw/misc/goldfish_pipe.c`：

- save：
  - `goldfish_pipe_save()`：`hw/misc/goldfish_pipe.c:1426-1434`
  - 先 `guest_pre_save()`，再做 device save。
  - 如果 `virtio_gpu_use_virgl_as_proxy()` 为真，跳过 `guest_post_save()`。
- load：
  - `goldfish_pipe_load()`：`hw/misc/goldfish_pipe.c:1805-1817`
  - 先 `guest_pre_load()`，再做 device load。
  - 如果 `virtio_gpu_use_virgl_as_proxy()` 为真，跳过 `guest_post_load()`。

`hw/display/virtio-gpu.c` 在 Android/stream 相关初始化中会设置 proxy 标志：

- `virtio-gpu.c:1350-1360`
- stream renderer 分支在 `virtio-gpu.c:1355-1360` 设置 `g->virgl_as_proxy = true` 和 `virgl_as_proxy = true`。

这里能确证的是代码条件。**未完成验证**：在当前自研构建的实际运行时，`guest_pre_save/pre_load` 是否确实到达 `OpenglEsPipe` 并完成完整的 renderer 恢复，特别是 `guest_post_save/post_load` 被跳过后的线程恢复和后续 repaint 行为。

### 2.3 宿主 renderer 的 serialize/deserialize

gfxstream 侧：

- `host/RendererImpl.cpp:355-394`
  - `RendererImpl::save()` 调 `FrameBuffer::onSave(stream, textureSaver)`。
  - `RendererImpl::load()` 调 `FrameBuffer::onLoad(stream, textureLoader)`，然后 `EmulatedEglFenceSync::onLoad(stream)`。

`host/FrameBuffer.cpp`：

- `FrameBuffer::onSave()`：`host/FrameBuffer.cpp:2937-3057`
- `FrameBuffer::onLoad()`：`host/FrameBuffer.cpp:3060-3304`

保存内容包括：

- EGL/GL 纹理和 EGLImage：
  - `eglPreSaveContext()` 和 `eglSaveAllImages()`。
  - `host/FrameBuffer.cpp:2957-2967`
  - `host/gl/glestranslator/EGL/EglImp.cpp:1659-1725`
- framebuffer 尺寸、DPR、display config：
  - `host/FrameBuffer.cpp:2970-2983`
- GL contexts：
  - `saveCollection(stream, m_contexts, ...)`。
  - `host/FrameBuffer.cpp:2992-3001`
  - `EglContext::onSave()`：`host/gl/glestranslator/EGL/EglContext.cpp:182-198`
  - `GLEScontext::onSave()`：`host/gl/glestranslator/GLcommon/GLEScontext.cpp:645-738`
- color buffers：
  - `host/FrameBuffer.cpp:3007-3018`
  - `ColorBuffer::onSave()`：`host/ColorBuffer.cpp:129-139`
  - `ColorBufferGl::onSave()`：`host/gl/ColorBufferGl.cpp:1020-1030`
- window surfaces：
  - `host/FrameBuffer.cpp:3019-3023`
- process-owned 资源：
  - `host/FrameBuffer.cpp:3025-3036`
- Vulkan 状态（feature gate 下）：
  - `host/FrameBuffer.cpp:3038-3041`
- GL fence/sync：
  - `EmulatedEglFenceSync::onSave()`：`host/gl/EmulatedEglFenceSync.cpp:201-207`

纹理 payload：

- `GlobalNameSpace::onSave()` 通过 `textureSaver->saveTexture(...)` 保存纹理。
  - `host/gl/glestranslator/GLcommon/ObjectNameSpace.cpp:341-373`
- `SaveableTexture::onSave()` 保存 texture target、尺寸、格式、mipmap、pixel data、texParam 等。
  - `host/gl/glestranslator/GLcommon/SaveableTexture.cpp:585-743`

### 2.4 texture 文件和 snapshot 元数据的关系

Snapshotter/Saver/Loader 层：

- `Snapshotter::save()`：`android/android-emu/android/snapshot/Snapshotter.cpp:752-785`
- `Snapshotter::load()`：`Snapshotter.cpp:312-344`
- `Saver` 创建 `textures.bin` 对应的 `TextureSaver`：
  - `android/android-emu/android/snapshot/Saver.cpp:118-128`
- `Loader` 创建 `textures.bin` 对应的 `TextureLoader`：
  - `android/android-emu/android/snapshot/Loader.cpp:67-77`

所以宿主 GPU/GL 状态并不是 Snapshotter 里一个名叫 `gpu` 的独立 section。它主要由：

- Android pipe 数据流中的 renderer metadata。
- `textures.bin` 中的纹理 payload/index。
- RAM/VM snapshot。

共同组成。

## 3. `Icebox` 和 `GapTracker`

### Icebox

`android/android-emu/android/snapshot/Icebox.h:17-25` 的接口注释是：

> Start tracking pid for exceptions. Save a snapshot under snapshot_name if unexpected error happens.

所以 Icebox 是“跟踪进程，在异常时触发快照”的自动化和诊断机制，不是宿主 GPU 状态序列化机制。它本身不解决 renderer/EGL/GL/Vulkan 状态保存。

### GapTracker

`android/android-emu/android/snapshot/GapTracker.h:31-43` 定义的是 snapshot 文件 gap 的 load/save/allocate。它服务于 RAM/incremental snapshot 的空洞跟踪，不是 GPU 对象状态。

## 4. Vulkan 快照的真实状态

gfxstream 的 FrameBuffer 只有在 feature 打开时才保存 Vulkan：

- `host/FrameBuffer.cpp:3030-3041`
- `host/FrameBuffer.cpp:3253-3296`

feature 开关来自：

- `host/virtio-gpu-gfxstream-renderer.cpp:2111`
  - `enableVkSnapshot = (renderer_flags & STREAM_RENDERER_FLAGS_VULKAN_SNAPSHOTS)`
- `host/virtio-gpu-gfxstream-renderer.cpp:2160`
  - `feature_set_enabled_override(kFeature_VulkanSnapshots, enableVkSnapshot)`
- flag 定义：
  - `host/include/gfxstream/virtio-gpu-gfxstream-renderer.h:255`

Vulkan snapshot 的实现是 API trace/reconstruction 路线：

- `host/vulkan/VkDecoderGlobalState.cpp:316`
- `host/vulkan/VkDecoderGlobalState.cpp:368-384`
- `host/vulkan/VkDecoderSnapshot.cpp:55-60`
- `host/vulkan/VkReconstruction.cpp:55-230`

但生成代码中有大量 `// TODO: Implement`，包括 queue submit、memory binding、mapped memory、fence、semaphore、queue wait 等。例如：

- `host/vulkan/VkDecoderSnapshot.cpp:226-238`：`vkQueueSubmit`、`vkQueueWaitIdle`、`vkDeviceWaitIdle`
- `host/vulkan/VkDecoderSnapshot.cpp:239-330`：memory allocate/map/bind、queue bind sparse
- `host/vulkan/VkDecoderSnapshot.cpp:332-372`：fence create/reset/status/wait
- `host/vulkan/VkDecoderSnapshot.cpp:374-399`：semaphore create/destroy

另外，`VkDecoderGlobalState::Impl` 在 Vulkan instance 创建时会在 feature 未开启时设置 skip snapshot：

- `host/vulkan/VkDecoderGlobalState.cpp:511-513`
  - `get_emugl_vm_operations().setSkipSnapshotSave(!feature_is_enabled(kFeature_VulkanSnapshots));`

结论：

**Vulkan 对象有“有条件序列化”的代码路径，但有明显未实现项。当前 emu-34 构建是否传入 `STREAM_RENDERER_FLAGS_VULKAN_SNAPSHOTS` 未完成验证。**

在 QEMU 侧看到的 `GFXSTREAM_RENDERER_FLAGS_*` 定义中没有这个名字；gfxstream 头里使用的是 `STREAM_RENDERER_FLAGS_VULKAN_SNAPSHOTS`。因此不能把“gfxstream 支持 Vulkan snapshot 代码”直接等同于“我们的 virtio-gpu 构建默认会保存 Vulkan 状态”。

## 5. 已知或高风险的 quickboot 图形约束

### 已看到注释确证

`EglContext::onSave()` 明确写了配置 ID 迁移的局限：

- `host/gl/glestranslator/EGL/EglContext.cpp:182-198`

注释含义：

- 保存和加载几乎只在同一系统、同一 GPU 驱动和硬件上可靠。
- 快照里存的是 EGL config ID，不是完整的通用 EGL config 重建语义。

`FrameBuffer::onSave()` 明确写：

> textures created by the host are not saved

对应：

- `host/FrameBuffer.cpp:2957-2960`

也就是说，guest context 关联的纹理有恢复逻辑，但 host 自己创建的纹理不在这一层的保存范围内。

### 已在 emu-36 范围看到相关修复

`c88bb8146d`：

- 标题：`Fix "glTexImage2D got err pre" after snapshot loads`
- 原因：没有保存 multi-sample，导致 `GL_FRAMEBUFFER_INCOMPLETE_MULTISAMPLE`。
- 修改：
  - `Snapshot.cpp` snapshot version base 80 -> 81。
  - `FramebufferData.cpp` 保存/恢复 renderbuffer `samples`。
  - `SaveableTexture.cpp` 增加 `GL_TEXTURE_SAMPLES` 参数。

`68e3ddb599`：

- 标题：`Fix snapshot freeze when save/load for virtio-gpu`
- 修改了 `virtio-goldfish-pipe.cpp`、`virtio-gpu.c`、`goldfish_pipe.c` 的 save/load 和 proxy 条件。

`6b73432a39`：

- 标题：`Fix virtio-gpu hang.`
- 修改了 `OpenglEsPipe.cpp`、`RenderChannelImpl`、`AndroidPipe`、`virtio-gpu.c`、`virtio-gpu-3d.c`。

这些说明 emu-36 范围确实有图形/快照相关的修复。但它们没有改变最关键的 stream_renderer 直接 hook 状态。

### 已看到风险点，但未验证

`ColorBufferGl::onSave()` 把 `m_eglImage` 和 `m_blitEGLImage` 以 `uintptr_t` 转成 32 位写入：

- `host/gl/ColorBufferGl.cpp:1020-1030`

`ColorBufferGl::onLoad()` 再把读出的值转换为 `EGLImageKHR` 并直接赋值：

- `host/gl/ColorBufferGl.cpp:1033-1055`

这说明宿主 EGLImage 句柄/指针的跨进程恢复语义非常关键。**尚未验证**：在官方完整 quickboot 流程中这些值是否通过 gfxstream 的 EGL 层重映射；如果自研 QEMU 节省或绕过了对应恢复步骤，跨新进程加载会出现黑屏、花屏或 GL 错误。这个点应作为移植后的第一批运行时验证项。

`Snapshot.cpp` 只用一个布尔字段记录 snapshot 是否是 gfxstream 生成：

- `Snapshot.cpp:72-77`
- `Snapshot.cpp:597-598`
- `Snapshot.cpp:803-810`

这个检查能防止 virgl snapshot 和 gfxstream snapshot 混用，但不能完整表达：

- gfxstream 后端版本。
- 是否启用 Vulkan snapshot。
- 纹理格式/驱动的更细兼容性。

因此跨 gfxstream 版本的 quickboot 兼容性不能只依赖这个字段。

`goldfish_address_space` 的 snapshot 支持：在 git log 中看到了相关历史提交标题，但没有在时限内完成代码路径核对。**未验证**。不能据此断言它是本路径的必须条件。

## 6. emu-36-1-release 相比 emu-34-release 的实质变化

### 已确证相同

`hw/display/virtio-gpu.c` 的关键位置：

- `origin/emu-34-release:1128-1134`
- `origin/emu-36-1-release:1128-1134`

两边都是：

```c
#ifdef CONFIG_STREAM_RENDERER
    // NOT IMPLEMENTED
#else
        g->virgl->virgl_renderer_save_snapshot(f);
#endif
```

所以直接回答：

**emu-36-1-release 没有把 virtio-gpu + stream_renderer 的 `virgl_renderer_save_snapshot()` 直接 hook 补上。**

### 已确证有别的变化

`git diff --stat origin/emu-34-release..origin/emu-36-1-release` 在相关路径上显示了大量 snapshot/quickboot 变化，包括：

- `android/android-emu/android/snapshot/Quickboot.cpp`
- `android/android-emu/android/snapshot/Snapshotter.cpp`
- `android/android-emu/android/snapshot/Snapshot.cpp`
- `android/android-emu/android/opengl/OpenglEsPipe.cpp`
- `android-qemu2-glue/emulation/virtio-gpu-gfxstream-renderer.cpp`
- `hw/display/virtio-gpu-3d.c`

关键提交存在性检查显示：

- `68e3ddb599` 不在 `origin/emu-34-release`，在 `origin/emu-36-1-release`
- `e513d66d36` 不在 `origin/emu-34-release`，在 `origin/emu-36-1-release`
- `51b96c8a23` 不在 `origin/emu-34-release`，在 `origin/emu-36-1-release`
- `c88bb8146d` 不在 `origin/emu-34-release`，在 `origin/emu-36-1-release`
- `6b73432a39` 不在 `origin/emu-34-release`，在 `origin/emu-36-1-release`

其中 `c88bb8146d` 直接对应“snapshot load 后 glTexImage2D 错误”的图形修复。`6b73432a39` 解决 virtio-gpu hang。`e513d66d36` 是 gfxstream/virtio-gpu-gfxstream-renderer 方向的集成变化。

### 未完成验证

`/root/vmbuild/gfxstream` 只看到：

- `origin/emu-34-release`
- `origin/emu-33-release`

没有 `emu-36` 分支，因此无法对 gfxstream 后端源码做 emu-34 到 emu-36 的同源 diff。**emu-36 的 gfxstream backend 是否还有未包含在 QEMU 树比较里的重大改进，未完成验证。**

## 7. 如果要做，必须满足的条件清单

1. **不要指望 `virtio-gpu.c` 的 stream_renderer 分支。**
   当前代码是 `NOT IMPLEMENTED`。要么实现它，要么明确走官方 `opengles` pipe 的 renderer save/load 路径。

2. **确保 Android `opengles` pipe 在 save/load 时被调用。**
   关键点：
   - `android_init_opengles_pipe()` 已注册。
   - `goldfish_pipe` 的 `guest_pre_save/pre_load` 能到达 service。
   - renderer 非空。
   - `preSave` 能调用 `RendererImpl::save`。
   - `preLoad` 能调用 `RendererImpl::load`。

3. **补齐或确认 TextureSaver/TextureLoader 的文件生命周期。**
   `libgfxstream-snapshot.a` 只提供两个类。Saver/Loader 还必须有正确的 `textures.bin` 初始化、完成、join 和错误处理。

4. **确认 stream renderer 下 `postSave/postLoad` 被跳过的后果。**
   代码会因 `virtio_gpu_use_virgl_as_proxy() == true` 跳过 `guest_post_save/post_load`。必须验证：
   - render thread 是否仍会 resume。
   - 通道是否不会卡在 snapshot 状态。
   - load 后是否执行 repaint。

5. **确认 EGL/GL 对象恢复策略。**
   至少要验证：
   - EGL config ID 兼容。
   - EGLImage handle/指针恢复。
   - GL shader/program/buffer/renderbuffer/framebuffer/VAO 状态恢复。
   - host-created texture 的处理是否符合预期。

6. **明确 Vulkan 是否要支持。**
   如果不传 `STREAM_RENDERER_FLAGS_VULKAN_SNAPSHOTS`，`kFeature_VulkanSnapshots` 可能关闭，Vulkan snapshot 不会走完整路径。即使打开，生成代码中还有 queue submit、memory binding、fence、semaphore 等 `TODO: Implement`。

7. **加入 post-load 图形自检。**
   当前已知过问题包括：
   - snapshot load 后 `glTexImage2D` 错误，来自 multi-sample renderbuffer 未保存，emu-36 范围有 `c88bb8146d` 修复。
   - virtio-gpu save/load freeze，emu-36 范围有 `68e3ddb599` 修复。
   - virtio-gpu hang，emu-36 范围有 `6b73432a39` 修复。

8. **把 goldfish_address_space snapshot 支持列为待验证项。**
   本次没有完成其代码路径核对，不能把它写成必需条件，也不能排除它。

## 8. 最终判断

对当前自研 QEMU 的 `virtio-gpu + gfxstream(stream_renderer)`：

- **只靠 `libgfxstream-snapshot.a`：不够。**
- **只靠 `virtio-gpu.c` 里的 `virgl_renderer_save_snapshot()` 链：不够，且 stream_renderer 分支当前根本没有调用。**
- **有条件可行：需要把官方 emulator 的 `opengles` pipe / renderer save-load 路径完整移植并验证，同时补齐纹理文件和 GL/EGL/Vulkan 的恢复条件。**

emu-36-1-release 相比 emu-34-release：

- **直接 hook 没有实质变化，仍然是 `NOT IMPLEMENTED`。**
- **周边 snapshot、quickboot、gfxstream/virtio-gpu 集成有若干修复和变化。**
- **这些变化不足以从代码上证明“stream_renderer 直接宿主快照已经可用”。**


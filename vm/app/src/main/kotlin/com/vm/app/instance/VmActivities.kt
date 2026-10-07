package com.vm.app.instance

import android.app.NativeActivity
import android.content.Intent
import com.vm.app.VmLauncher

/**
 * 实例 Activity 基类。
 *
 * 渲染、输入、虚拟机循环全部在 native 层（libvmengine.so 的 android_main）完成，
 * Java 侧只负责响应宿主的"停止"指令。
 *
 * 为什么每个实例一个类：Android 以「组件名」唯一标识组件，
 * 同一个类无法同时声明到多个进程，因此按实例数展开为多个子类。
 */
open class VmNativeActivityBase : NativeActivity() {

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.getBooleanExtra(VmLauncher.EXTRA_STOP, false)) {
            finishAndRemoveTask()
        }
    }
}

class VmNativeActivity1 : VmNativeActivityBase()

class VmNativeActivity2 : VmNativeActivityBase()

class VmNativeActivity3 : VmNativeActivityBase()

class VmNativeActivity4 : VmNativeActivityBase()

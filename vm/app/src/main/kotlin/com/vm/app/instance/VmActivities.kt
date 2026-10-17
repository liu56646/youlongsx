package com.vm.app.instance

import android.app.NativeActivity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import com.vm.app.R
import com.vm.app.VmLauncher

/**
 * 实例 Activity 基类。
 *
 * 渲染、输入、虚拟机循环全部在 native 层（libvmengine.so 的 android_main）完成，
 * Java 侧只负责响应宿主的"停止"指令。
 *
 * 为什么每个实例一个类：Android 以「组件名」唯一标识组件，
 * 同一个类无法同时声明到多个进程，因此按实例数展开为多个子类。
 *
 * 关于 WakeLock：访客冷启动在真机上要几分钟，而 TCG 的速度几乎线性跟随宿主 CPU
 * 频率。屏幕一灭，系统会压低频率并让进程进入 doze —— 实测 guest 内核时间的推进
 * 从 ~1:1 掉到 ~1:6（100 秒墙钟只跑出 17 秒 guest 时间）。所以实例运行期间常驻
 * 一个前台服务（[VmInstanceServiceBase]），由它持 PARTIAL_WAKE_LOCK，并把进程
 * 钉在 foreground cpuset 上。
 */
open class VmNativeActivityBase : NativeActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 实例整段生命周期都挂一个前台服务：访客要跑几分钟才起来，这期间用户
        // 很可能会切走或锁屏。没有前台服务时进程会掉进 background cpuset
        // （本机只有 0-3 号核，拿不到大核），启动明显变慢，还可能被冻结回收。
        runCatching { startForegroundService(Intent(this, serviceClass())) }
            .onFailure { Log.w(TAG, "启动前台服务失败，退回普通后台进程", it) }
    }

    override fun onDestroy() {
        runCatching { stopService(Intent(this, serviceClass())) }
        super.onDestroy()
    }

    /** 与本实例同进程的前台服务；四个子类各自覆盖。 */
    protected open fun serviceClass(): Class<out Service> = VmInstanceService1::class.java

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.getBooleanExtra(VmLauncher.EXTRA_STOP, false)) {
            finishAndRemoveTask()
        }
    }

    private companion object {
        const val TAG = "VmInstance"
    }
}

/**
 * 实例前台服务基类。
 *
 * 存在的唯一目的：让实例进程在访客运行期间保持「前台服务」等级。Android 据此把
 * 进程放进 foreground cpuset（本机 0-7 全核）而不是 background cpuset（0-3），
 * 并且不会把进程冻结/回收 —— QEMU 是 fork 出来的子进程，与父进程同 cgroup，
 * 父进程被冻结它就跟着停。
 *
 * 顺带持一把 PARTIAL_WAKE_LOCK：屏幕灭掉时 CPU 仍要跑，访客才不会被挂起。
 */
open class VmInstanceServiceBase : Service() {

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
        val notification = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_launcher)
            .setContentTitle(getString(R.string.vm_service_title))
            .setContentText(getString(R.string.vm_service_text))
            .setOngoing(true)
            .build()
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIFICATION_ID, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        }.onFailure { Log.w(TAG, "startForeground 失败，仅保留 WakeLock", it) }

        wakeLock = (getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG)
            .apply {
                setReferenceCounted(false)
                acquire()
            }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onDestroy() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        runCatching { stopForeground(STOP_FOREGROUND_REMOVE) }
        super.onDestroy()
    }

    private fun ensureChannel() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                getString(R.string.vm_service_channel),
                NotificationManager.IMPORTANCE_LOW
            ).apply { setShowBadge(false) }
        )
    }

    private companion object {
        const val TAG = "VmInstance"
        const val CHANNEL_ID = "vm_running"
        const val NOTIFICATION_ID = 0x564D   // "VM"
        const val WAKE_LOCK_TAG = "youlong:vm-instance"
    }
}

class VmNativeActivity1 : VmNativeActivityBase() {
    override fun serviceClass(): Class<out Service> = VmInstanceService1::class.java
}

class VmNativeActivity2 : VmNativeActivityBase() {
    override fun serviceClass(): Class<out Service> = VmInstanceService2::class.java
}

class VmNativeActivity3 : VmNativeActivityBase() {
    override fun serviceClass(): Class<out Service> = VmInstanceService3::class.java
}

class VmNativeActivity4 : VmNativeActivityBase() {
    override fun serviceClass(): Class<out Service> = VmInstanceService4::class.java
}

class VmInstanceService1 : VmInstanceServiceBase()

class VmInstanceService2 : VmInstanceServiceBase()

class VmInstanceService3 : VmInstanceServiceBase()

class VmInstanceService4 : VmInstanceServiceBase()

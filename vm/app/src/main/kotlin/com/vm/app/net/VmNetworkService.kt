package com.vm.app.net

import android.content.Intent
import android.net.VpnService
import android.os.ParcelFileDescriptor
import android.util.Log

/**
 * 访客网络服务：在宿主侧建立 tun。
 *
 * 数据通路（M3 接通）：
 *   guest 应用 -> virtio-net -> QEMU slirp -> 本 tun -> 宿主网络栈
 *
 * 用户必须先通过 [VpnService.prepare] 授权，才能 establish。
 */
class VmNetworkService : VpnService() {

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureTun()
        return START_STICKY
    }

    override fun onRevoke() {
        closeTun()
        super.onRevoke()
    }

    override fun onDestroy() {
        closeTun()
        super.onDestroy()
    }

    private fun ensureTun() {
        if (tun != null) return
        tun = runCatching {
            Builder()
                .setSession("VMHost")
                .setMtu(1500)
                .addAddress(VPN_ADDRESS, VPN_PREFIX)
                .addRoute(VPN_ADDRESS, VPN_PREFIX)
                .addDnsServer(VPN_DNS)
                .setBlocking(false)
                .establish()
        }.onFailure { Log.e(TAG, "establish tun failed", it) }.getOrNull()
        Log.i(TAG, "tun established = ${tun != null}")
    }

    private fun closeTun() {
        runCatching { tun?.close() }
        tun = null
    }

    companion object {
        private const val TAG = "VmNetworkService"
        private const val VPN_ADDRESS = "10.7.0.1"
        private const val VPN_PREFIX = 24
        private const val VPN_DNS = "10.7.0.2"

        /** 引擎侧通过它把 slirp 桥到宿主网络栈。 */
        @Volatile
        var tun: ParcelFileDescriptor? = null
            private set
    }
}

package com.vm.core;

/**
 * 实例控制接口：由实例进程（:vmN）实现，宿主进程通过 Binder 调用。
 * 说明：显示与触摸走 NativeActivity 的原生回调，不经过这里；
 * 该接口只承载生命周期与少量注入控制。
 */
interface IVmInstance {
    void stop();

    void pause();

    void resume();

    void sendKey(int keyCode, int action);

    boolean isRunning();

    String getLogPath();
}

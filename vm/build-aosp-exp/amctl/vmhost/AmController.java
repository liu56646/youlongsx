/*
 * VMHost · 方案 2：在 guest 内注册 IActivityController，让 system_server 的 Watchdog
 * 在检测到“系统卡死”时只回调、不 SIGKILL。
 *
 * 背景：TCG 全虚拟化下 system_server 主线程偶发 >60s 阻塞；Watchdog.java 的
 * DEFAULT_TIMEOUT 硬编码 60s，一旦判定 OVERDUE 就 Process.killProcess(myPid())。
 * Watchdog.run() 里唯一的“正规”豁免口是 mController：
 *     int res = controller.systemNotResponding(subject);
 *     if (res >= 0) { continue; }   // 继续等待，永不杀
 * 因此只要有人调用 ActivityManagerService.setActivityController(...) 注册一个
 * systemNotResponding 返回 0 的控制器即可。
 *
 * 权限：ActivityTaskManagerService.setActivityController 强制
 * android.Manifest.permission.SET_ACTIVITY_WATCHER（signature 级）；本进程以 root(uid 0)
 * 运行，ActivityManager.checkComponentPermission 对 uid 0 直接 GRANTED。
 *
 * 实现要点：
 *  - 以 app_process 运行（自带 binder 线程池：AppRuntime::onStarted -> startThreadPool，
 *    所以 main 线程 sleep 时仍能收到 systemNotResponding 回调）。
 *  - 隐藏 API 走反射：ServiceManager.getService("activity") / IActivityManager$Stub.asInterface。
 *  - 控制器对象用 java.lang.reflect.Proxy 实现 android.app.IActivityController（框架里的
 *    隐藏接口），asBinder() 返回下面这个 Binder；这样避免把 android.app.* 的重复类打进 dex。
 */

package vmhost;

import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;
import android.os.RemoteException;

import java.io.FileOutputStream;
import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;

public final class AmController {

    private static final String TAG = "vmhost_amctl";
    private static final long REREGISTER_PERIOD_MS = 2000;

    private static FileOutputStream sKmsg;

    /** 日志写 /dev/kmsg（=> 串口）；失败时退回 stderr（init 的 stdio_to_kmsg 会兜住）。 */
    static synchronized void log(String s) {
        String line = TAG + ": " + s + "\n";
        try {
            if (sKmsg == null) {
                sKmsg = new FileOutputStream("/dev/kmsg");
            }
            sKmsg.write(line.getBytes("UTF-8"));
        } catch (Throwable t) {
            System.err.print(line);
        }
    }

    /**
     * 控制器的 binder 实体。只需实现 IActivityController 的 6 个事务。
     * 事务码来自 aidl 对 android-11 的 IActivityController.aidl 的生成结果：
     *   FIRST_CALL_TRANSACTION(+0..+5) = activityStarting / activityResuming /
     *   appCrashed / appEarlyNotResponding / appNotResponding / systemNotResponding
     * 参数我们不关心（不解析即可），只回写约定返回值。
     */
    static final class Ctl extends Binder {
        static final String DESCRIPTOR = "android.app.IActivityController";
        static final int TX_ACTIVITY_STARTING   = FIRST_CALL_TRANSACTION + 0;
        static final int TX_ACTIVITY_RESUMING   = FIRST_CALL_TRANSACTION + 1;
        static final int TX_APP_CRASHED         = FIRST_CALL_TRANSACTION + 2;
        static final int TX_APP_EARLY_ANR       = FIRST_CALL_TRANSACTION + 3;
        static final int TX_APP_ANR             = FIRST_CALL_TRANSACTION + 4;
        static final int TX_SYSTEM_NOT_RESPOND  = FIRST_CALL_TRANSACTION + 5;

        @Override
        protected boolean onTransact(int code, Parcel data, Parcel reply, int flags)
                throws RemoteException {
            switch (code) {
                case TX_ACTIVITY_STARTING:
                case TX_ACTIVITY_RESUMING:
                case TX_APP_CRASHED: {
                    // 一律 true：正常放行（启动/resume/崩溃恢复）
                    data.enforceInterface(DESCRIPTOR);
                    reply.writeNoException();
                    reply.writeInt(1);
                    return true;
                }
                case TX_APP_EARLY_ANR: {
                    // 0 = 继续，不杀应用进程
                    data.enforceInterface(DESCRIPTOR);
                    reply.writeNoException();
                    reply.writeInt(0);
                    return true;
                }
                case TX_APP_ANR: {
                    // 1 = 继续等待（不弹 ANR 弹窗、不杀）
                    data.enforceInterface(DESCRIPTOR);
                    reply.writeNoException();
                    reply.writeInt(1);
                    return true;
                }
                case TX_SYSTEM_NOT_RESPOND: {
                    String msg = null;
                    data.enforceInterface(DESCRIPTOR);
                    try {
                        msg = data.readString();
                    } catch (Throwable ignored) {
                    }
                    reply.writeNoException();
                    // >=0 即“继续等待”，Watchdog 绝不会再 SIGKILL system_server
                    reply.writeInt(0);
                    log("systemNotResponding -> keep waiting: " + msg);
                    return true;
                }
                default:
                    return super.onTransact(code, data, reply, flags);
            }
        }
    }

    /** 用动态代理伪装成 android.app.IActivityController，asBinder 交给我们的 Ctl。 */
    static InvocationHandler handlerFor(final Ctl ctl) {
        return new InvocationHandler() {
            @Override
            public Object invoke(Object proxy, Method m, Object[] a) {
                String n = m.getName();
                if ("asBinder".equals(n)) {
                    return ctl;
                }
                if ("systemNotResponding".equals(n)) {
                    return Integer.valueOf(0);
                }
                if ("appNotResponding".equals(n)) {
                    return Integer.valueOf(1);
                }
                if ("appEarlyNotResponding".equals(n)) {
                    return Integer.valueOf(0);
                }
                if ("equals".equals(n)) {
                    return Boolean.valueOf(a != null && a.length > 0 && a[0] == proxy);
                }
                if ("hashCode".equals(n)) {
                    return Integer.valueOf(System.identityHashCode(proxy));
                }
                if ("toString".equals(n)) {
                    return "VmhostActivityController";
                }
                Class<?> rt = m.getReturnType();
                if (rt == boolean.class) {
                    return Boolean.TRUE;
                }
                if (rt == int.class) {
                    return Integer.valueOf(0);
                }
                return null;
            }
        };
    }

    public static void main(String[] args) {
        log("start (uid=" + android.os.Process.myUid() + ", pid=" + android.os.Process.myPid() + ")");

        Ctl ctl = new Ctl();
        try {
            Class<?> smCls = Class.forName("android.os.ServiceManager");
            Method getService = smCls.getMethod("getService", String.class);

            Class<?> iamStubCls = Class.forName("android.app.IActivityManager$Stub");
            Method asInterface = iamStubCls.getMethod("asInterface", IBinder.class);

            Class<?> iamCls = Class.forName("android.app.IActivityManager");
            Class<?> iacCls = Class.forName("android.app.IActivityController");
            Method setController = iamCls.getMethod("setActivityController", iacCls, boolean.class);

            Object controller = Proxy.newProxyInstance(
                    AmController.class.getClassLoader(),
                    new Class<?>[]{iacCls},
                    handlerFor(ctl));

            // selftest：注册后立刻注销，用来在宿主机上快速验证整条反射/binder 链路。
            if (args != null && args.length > 0 && "selftest".equals(args[0])) {
                try {
                    IBinder activity = (IBinder) getService.invoke(null, "activity");
                    log("selftest: activity binder = " + activity);
                    Object am = asInterface.invoke(null, activity);
                    log("selftest: IActivityManager = " + am);
                    setController.invoke(am, controller, Boolean.FALSE);
                    log("selftest: REGISTER OK");
                    Thread.sleep(500);
                    setController.invoke(am, null, Boolean.FALSE);
                    log("selftest: UNREGISTER OK");
                } catch (Throwable t) {
                    Throwable c = t;
                    if (t instanceof java.lang.reflect.InvocationTargetException
                            && t.getCause() != null) {
                        c = t.getCause();
                    }
                    log("selftest FAILED: " + t + " | cause=" + c);
                    c.printStackTrace();
                }
                return;
            }

            int attempt = 0;
            boolean wasRegistered = false;
            boolean warnedNotReady = false;
            // 初次注册可能早于 system_server 起来；此后 system_server 每次重启
            // 都会丢弃控制器（新 AMS 实例），所以持续轻量地重注册以自愈。
            while (true) {
                attempt++;
                boolean registered = false;
                String why = null;
                String step = "getService";
                try {
                    IBinder activity = (IBinder) getService.invoke(null, "activity");
                    if (activity == null) {
                        why = "getService(activity) == null";
                    } else {
                        step = "asInterface";
                        Object am = asInterface.invoke(null, activity);
                        step = "setActivityController";
                        setController.invoke(am, controller, Boolean.FALSE);
                        registered = true;
                    }
                } catch (Throwable t) {
                    Throwable c = t;
                    if (t instanceof java.lang.reflect.InvocationTargetException
                            && t.getCause() != null) {
                        c = t.getCause();
                    }
                    why = "at " + step + ": " + t.getClass().getName() + ": " + t.getMessage()
                            + " | cause=" + c.getClass().getName() + ": " + c.getMessage();
                }
                if (registered) {
                    if (!wasRegistered) {
                        log("controller registered (attempt#" + attempt + ")");
                        wasRegistered = true;
                        warnedNotReady = false;
                    }
                } else if (wasRegistered) {
                    log("registration lost: " + why);
                    wasRegistered = false;
                } else if (!warnedNotReady) {
                    log("waiting for 'activity' service: " + why);
                    warnedNotReady = true;
                }
                Thread.sleep(REREGISTER_PERIOD_MS);
            }
        } catch (Throwable t) {
            log("fatal: " + t);
            t.printStackTrace();
        }
    }
}

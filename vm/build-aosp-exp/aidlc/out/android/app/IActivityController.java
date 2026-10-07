/*
 * This file is auto-generated.  DO NOT MODIFY.
 */
package android.app;
/**
 * Testing interface to monitor what is happening in the activity manager
 * while tests are running.  Not for normal application development.
 * {@hide}
 */
public interface IActivityController extends android.os.IInterface
{
  /** Default implementation for IActivityController. */
  public static class Default implements android.app.IActivityController
  {
    /**
     * The system is trying to start an activity.  Return true to allow
     * it to be started as normal, or false to cancel/reject this activity.
     */
    @Override public boolean activityStarting(android.content.Intent intent, java.lang.String pkg) throws android.os.RemoteException
    {
      return false;
    }
    /**
     * The system is trying to return to an activity.  Return true to allow
     * it to be resumed as normal, or false to cancel/reject this activity.
     */
    @Override public boolean activityResuming(java.lang.String pkg) throws android.os.RemoteException
    {
      return false;
    }
    /**
     * An application process has crashed (in Java).  Return true for the
     * normal error recovery (app crash dialog) to occur, false to kill
     * it immediately.
     */
    @Override public boolean appCrashed(java.lang.String processName, int pid, java.lang.String shortMsg, java.lang.String longMsg, long timeMillis, java.lang.String stackTrace) throws android.os.RemoteException
    {
      return false;
    }
    /** Early call as soon as an ANR is detected. */
    @Override public int appEarlyNotResponding(java.lang.String processName, int pid, java.lang.String annotation) throws android.os.RemoteException
    {
      return 0;
    }
    /**
     * An application process is not responding.  Return 0 to show the "app
     * not responding" dialog, 1 to continue waiting, or -1 to kill it
     * immediately.
     */
    @Override public int appNotResponding(java.lang.String processName, int pid, java.lang.String processStats) throws android.os.RemoteException
    {
      return 0;
    }
    /**
     * The system process watchdog has detected that the system seems to be
     * hung.  Return 1 to continue waiting, or -1 to let it continue with its
     * normal kill.
     */
    @Override public int systemNotResponding(java.lang.String msg) throws android.os.RemoteException
    {
      return 0;
    }
    @Override
    public android.os.IBinder asBinder() {
      return null;
    }
  }
  /** Local-side IPC implementation stub class. */
  public static abstract class Stub extends android.os.Binder implements android.app.IActivityController
  {
    /** Construct the stub at attach it to the interface. */
    public Stub()
    {
      this.attachInterface(this, DESCRIPTOR);
    }
    /**
     * Cast an IBinder object into an android.app.IActivityController interface,
     * generating a proxy if needed.
     */
    public static android.app.IActivityController asInterface(android.os.IBinder obj)
    {
      if ((obj==null)) {
        return null;
      }
      android.os.IInterface iin = obj.queryLocalInterface(DESCRIPTOR);
      if (((iin!=null)&&(iin instanceof android.app.IActivityController))) {
        return ((android.app.IActivityController)iin);
      }
      return new android.app.IActivityController.Stub.Proxy(obj);
    }
    @Override public android.os.IBinder asBinder()
    {
      return this;
    }
    @Override public boolean onTransact(int code, android.os.Parcel data, android.os.Parcel reply, int flags) throws android.os.RemoteException
    {
      java.lang.String descriptor = DESCRIPTOR;
      if (code >= android.os.IBinder.FIRST_CALL_TRANSACTION && code <= android.os.IBinder.LAST_CALL_TRANSACTION) {
        data.enforceInterface(descriptor);
      }
      switch (code)
      {
        case INTERFACE_TRANSACTION:
        {
          reply.writeString(descriptor);
          return true;
        }
      }
      switch (code)
      {
        case TRANSACTION_activityStarting:
        {
          android.content.Intent _arg0;
          _arg0 = _Parcel.readTypedObject(data, android.content.Intent.CREATOR);
          java.lang.String _arg1;
          _arg1 = data.readString();
          boolean _result = this.activityStarting(_arg0, _arg1);
          reply.writeNoException();
          reply.writeInt(((_result)?(1):(0)));
          break;
        }
        case TRANSACTION_activityResuming:
        {
          java.lang.String _arg0;
          _arg0 = data.readString();
          boolean _result = this.activityResuming(_arg0);
          reply.writeNoException();
          reply.writeInt(((_result)?(1):(0)));
          break;
        }
        case TRANSACTION_appCrashed:
        {
          java.lang.String _arg0;
          _arg0 = data.readString();
          int _arg1;
          _arg1 = data.readInt();
          java.lang.String _arg2;
          _arg2 = data.readString();
          java.lang.String _arg3;
          _arg3 = data.readString();
          long _arg4;
          _arg4 = data.readLong();
          java.lang.String _arg5;
          _arg5 = data.readString();
          boolean _result = this.appCrashed(_arg0, _arg1, _arg2, _arg3, _arg4, _arg5);
          reply.writeNoException();
          reply.writeInt(((_result)?(1):(0)));
          break;
        }
        case TRANSACTION_appEarlyNotResponding:
        {
          java.lang.String _arg0;
          _arg0 = data.readString();
          int _arg1;
          _arg1 = data.readInt();
          java.lang.String _arg2;
          _arg2 = data.readString();
          int _result = this.appEarlyNotResponding(_arg0, _arg1, _arg2);
          reply.writeNoException();
          reply.writeInt(_result);
          break;
        }
        case TRANSACTION_appNotResponding:
        {
          java.lang.String _arg0;
          _arg0 = data.readString();
          int _arg1;
          _arg1 = data.readInt();
          java.lang.String _arg2;
          _arg2 = data.readString();
          int _result = this.appNotResponding(_arg0, _arg1, _arg2);
          reply.writeNoException();
          reply.writeInt(_result);
          break;
        }
        case TRANSACTION_systemNotResponding:
        {
          java.lang.String _arg0;
          _arg0 = data.readString();
          int _result = this.systemNotResponding(_arg0);
          reply.writeNoException();
          reply.writeInt(_result);
          break;
        }
        default:
        {
          return super.onTransact(code, data, reply, flags);
        }
      }
      return true;
    }
    private static class Proxy implements android.app.IActivityController
    {
      private android.os.IBinder mRemote;
      Proxy(android.os.IBinder remote)
      {
        mRemote = remote;
      }
      @Override public android.os.IBinder asBinder()
      {
        return mRemote;
      }
      public java.lang.String getInterfaceDescriptor()
      {
        return DESCRIPTOR;
      }
      /**
       * The system is trying to start an activity.  Return true to allow
       * it to be started as normal, or false to cancel/reject this activity.
       */
      @Override public boolean activityStarting(android.content.Intent intent, java.lang.String pkg) throws android.os.RemoteException
      {
        android.os.Parcel _data = android.os.Parcel.obtain();
        android.os.Parcel _reply = android.os.Parcel.obtain();
        boolean _result;
        try {
          _data.writeInterfaceToken(DESCRIPTOR);
          _Parcel.writeTypedObject(_data, intent, 0);
          _data.writeString(pkg);
          boolean _status = mRemote.transact(Stub.TRANSACTION_activityStarting, _data, _reply, 0);
          _reply.readException();
          _result = (0!=_reply.readInt());
        }
        finally {
          _reply.recycle();
          _data.recycle();
        }
        return _result;
      }
      /**
       * The system is trying to return to an activity.  Return true to allow
       * it to be resumed as normal, or false to cancel/reject this activity.
       */
      @Override public boolean activityResuming(java.lang.String pkg) throws android.os.RemoteException
      {
        android.os.Parcel _data = android.os.Parcel.obtain();
        android.os.Parcel _reply = android.os.Parcel.obtain();
        boolean _result;
        try {
          _data.writeInterfaceToken(DESCRIPTOR);
          _data.writeString(pkg);
          boolean _status = mRemote.transact(Stub.TRANSACTION_activityResuming, _data, _reply, 0);
          _reply.readException();
          _result = (0!=_reply.readInt());
        }
        finally {
          _reply.recycle();
          _data.recycle();
        }
        return _result;
      }
      /**
       * An application process has crashed (in Java).  Return true for the
       * normal error recovery (app crash dialog) to occur, false to kill
       * it immediately.
       */
      @Override public boolean appCrashed(java.lang.String processName, int pid, java.lang.String shortMsg, java.lang.String longMsg, long timeMillis, java.lang.String stackTrace) throws android.os.RemoteException
      {
        android.os.Parcel _data = android.os.Parcel.obtain();
        android.os.Parcel _reply = android.os.Parcel.obtain();
        boolean _result;
        try {
          _data.writeInterfaceToken(DESCRIPTOR);
          _data.writeString(processName);
          _data.writeInt(pid);
          _data.writeString(shortMsg);
          _data.writeString(longMsg);
          _data.writeLong(timeMillis);
          _data.writeString(stackTrace);
          boolean _status = mRemote.transact(Stub.TRANSACTION_appCrashed, _data, _reply, 0);
          _reply.readException();
          _result = (0!=_reply.readInt());
        }
        finally {
          _reply.recycle();
          _data.recycle();
        }
        return _result;
      }
      /** Early call as soon as an ANR is detected. */
      @Override public int appEarlyNotResponding(java.lang.String processName, int pid, java.lang.String annotation) throws android.os.RemoteException
      {
        android.os.Parcel _data = android.os.Parcel.obtain();
        android.os.Parcel _reply = android.os.Parcel.obtain();
        int _result;
        try {
          _data.writeInterfaceToken(DESCRIPTOR);
          _data.writeString(processName);
          _data.writeInt(pid);
          _data.writeString(annotation);
          boolean _status = mRemote.transact(Stub.TRANSACTION_appEarlyNotResponding, _data, _reply, 0);
          _reply.readException();
          _result = _reply.readInt();
        }
        finally {
          _reply.recycle();
          _data.recycle();
        }
        return _result;
      }
      /**
       * An application process is not responding.  Return 0 to show the "app
       * not responding" dialog, 1 to continue waiting, or -1 to kill it
       * immediately.
       */
      @Override public int appNotResponding(java.lang.String processName, int pid, java.lang.String processStats) throws android.os.RemoteException
      {
        android.os.Parcel _data = android.os.Parcel.obtain();
        android.os.Parcel _reply = android.os.Parcel.obtain();
        int _result;
        try {
          _data.writeInterfaceToken(DESCRIPTOR);
          _data.writeString(processName);
          _data.writeInt(pid);
          _data.writeString(processStats);
          boolean _status = mRemote.transact(Stub.TRANSACTION_appNotResponding, _data, _reply, 0);
          _reply.readException();
          _result = _reply.readInt();
        }
        finally {
          _reply.recycle();
          _data.recycle();
        }
        return _result;
      }
      /**
       * The system process watchdog has detected that the system seems to be
       * hung.  Return 1 to continue waiting, or -1 to let it continue with its
       * normal kill.
       */
      @Override public int systemNotResponding(java.lang.String msg) throws android.os.RemoteException
      {
        android.os.Parcel _data = android.os.Parcel.obtain();
        android.os.Parcel _reply = android.os.Parcel.obtain();
        int _result;
        try {
          _data.writeInterfaceToken(DESCRIPTOR);
          _data.writeString(msg);
          boolean _status = mRemote.transact(Stub.TRANSACTION_systemNotResponding, _data, _reply, 0);
          _reply.readException();
          _result = _reply.readInt();
        }
        finally {
          _reply.recycle();
          _data.recycle();
        }
        return _result;
      }
    }
    public static final java.lang.String DESCRIPTOR = "android.app.IActivityController";
    static final int TRANSACTION_activityStarting = (android.os.IBinder.FIRST_CALL_TRANSACTION + 0);
    static final int TRANSACTION_activityResuming = (android.os.IBinder.FIRST_CALL_TRANSACTION + 1);
    static final int TRANSACTION_appCrashed = (android.os.IBinder.FIRST_CALL_TRANSACTION + 2);
    static final int TRANSACTION_appEarlyNotResponding = (android.os.IBinder.FIRST_CALL_TRANSACTION + 3);
    static final int TRANSACTION_appNotResponding = (android.os.IBinder.FIRST_CALL_TRANSACTION + 4);
    static final int TRANSACTION_systemNotResponding = (android.os.IBinder.FIRST_CALL_TRANSACTION + 5);
  }
  /**
   * The system is trying to start an activity.  Return true to allow
   * it to be started as normal, or false to cancel/reject this activity.
   */
  public boolean activityStarting(android.content.Intent intent, java.lang.String pkg) throws android.os.RemoteException;
  /**
   * The system is trying to return to an activity.  Return true to allow
   * it to be resumed as normal, or false to cancel/reject this activity.
   */
  public boolean activityResuming(java.lang.String pkg) throws android.os.RemoteException;
  /**
   * An application process has crashed (in Java).  Return true for the
   * normal error recovery (app crash dialog) to occur, false to kill
   * it immediately.
   */
  public boolean appCrashed(java.lang.String processName, int pid, java.lang.String shortMsg, java.lang.String longMsg, long timeMillis, java.lang.String stackTrace) throws android.os.RemoteException;
  /** Early call as soon as an ANR is detected. */
  public int appEarlyNotResponding(java.lang.String processName, int pid, java.lang.String annotation) throws android.os.RemoteException;
  /**
   * An application process is not responding.  Return 0 to show the "app
   * not responding" dialog, 1 to continue waiting, or -1 to kill it
   * immediately.
   */
  public int appNotResponding(java.lang.String processName, int pid, java.lang.String processStats) throws android.os.RemoteException;
  /**
   * The system process watchdog has detected that the system seems to be
   * hung.  Return 1 to continue waiting, or -1 to let it continue with its
   * normal kill.
   */
  public int systemNotResponding(java.lang.String msg) throws android.os.RemoteException;
  /** @hide */
  static class _Parcel {
    static private <T> T readTypedObject(
        android.os.Parcel parcel,
        android.os.Parcelable.Creator<T> c) {
      if (parcel.readInt() != 0) {
          return c.createFromParcel(parcel);
      } else {
          return null;
      }
    }
    static private <T extends android.os.Parcelable> void writeTypedObject(
        android.os.Parcel parcel, T value, int parcelableFlags) {
      if (value != null) {
        parcel.writeInt(1);
        value.writeToParcel(parcel, parcelableFlags);
      } else {
        parcel.writeInt(0);
      }
    }
  }
}

package io.castleengine;

import android.annotation.TargetApi;
import android.os.Build;
import android.window.OnBackInvokedCallback;
import android.window.OnBackInvokedDispatcher;

/** Back goes through the native UI hierarchy without finishing the Activity. */
public final class ServiceRezvivoNavigation extends ServiceAbstract {
    private Object backCallback;
    public ServiceRezvivoNavigation(MainActivity activity) { super(activity); }
    @Override public String getName() { return "rezvivo-navigation"; }

    @Override public boolean onBackPressed() {
        messageSend(new String[]{"rezvivo-back"});
        return true;
    }

    @Override public void onCreate() {
        if (Build.VERSION.SDK_INT >= 33) backCallback = ModernBack.register(this);
    }
    @Override public void onDestroy() {
        if (Build.VERSION.SDK_INT >= 33 && backCallback != null) {
            ModernBack.unregister(this, backCallback);
            backCallback = null;
        }
    }

    /** Keep newer classes isolated so the service loads on API 23 as well. */
    @TargetApi(33)
    private static final class ModernBack {
        static Object register(ServiceRezvivoNavigation service) {
            OnBackInvokedCallback callback = () -> service.onBackPressed();
            service.getActivity().getOnBackInvokedDispatcher().registerOnBackInvokedCallback(
                OnBackInvokedDispatcher.PRIORITY_DEFAULT, callback);
            return callback;
        }
        static void unregister(ServiceRezvivoNavigation service, Object callback) {
            service.getActivity().getOnBackInvokedDispatcher().unregisterOnBackInvokedCallback(
                (OnBackInvokedCallback) callback);
        }
    }
}

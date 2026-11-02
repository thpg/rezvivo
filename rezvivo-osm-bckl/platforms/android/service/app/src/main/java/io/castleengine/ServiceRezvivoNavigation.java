package io.castleengine;

import android.annotation.TargetApi;
import android.os.Build;
import android.graphics.Rect;
import android.view.View;
import android.view.ViewTreeObserver;
import android.view.WindowInsets;
import android.window.OnBackInvokedCallback;
import android.window.OnBackInvokedDispatcher;

/** Back goes through the native UI hierarchy without finishing the Activity. */
public final class ServiceRezvivoNavigation extends ServiceAbstract {
    private Object backCallback;
    private View content;
    private ViewTreeObserver.OnGlobalLayoutListener keyboardLayout;
    private int lastKeyboardBottom = -1;
    public ServiceRezvivoNavigation(MainActivity activity) { super(activity); }
    @Override public String getName() { return "rezvivo-navigation"; }

    @Override public boolean onBackPressed() {
        messageSend(new String[]{"rezvivo-back"});
        return true;
    }

    @Override public void onCreate() {
        if (Build.VERSION.SDK_INT >= 33) backCallback = ModernBack.register(this);
        content = getActivity().findViewById(android.R.id.content);
        if (content != null) {
            // NativeActivity stays fullscreen. Report the obscured area to the
            // native form instead of resizing/recreating the 3D surface.
            content.setOnApplyWindowInsetsListener((view, insets) -> {
                updateKeyboardInset(insets);
                return insets;
            });
            keyboardLayout = () -> updateKeyboardInset(content.getRootWindowInsets());
            content.getViewTreeObserver().addOnGlobalLayoutListener(keyboardLayout);
            content.requestApplyInsets();
        }
    }
    @Override public void onDestroy() {
        if (content != null) {
            content.setOnApplyWindowInsetsListener(null);
            if (content.getViewTreeObserver().isAlive())
                content.getViewTreeObserver().removeOnGlobalLayoutListener(keyboardLayout);
            content = null;
        }
        if (Build.VERSION.SDK_INT >= 33 && backCallback != null) {
            ModernBack.unregister(this, backCallback);
            backCallback = null;
        }
    }

    private void updateKeyboardInset(WindowInsets insets) {
        if (content == null) return;
        int bottom;
        if (Build.VERSION.SDK_INT >= 30 && insets != null) {
            bottom = ModernInsets.keyboardBottom(insets);
        } else {
            Rect visible = new Rect();
            content.getWindowVisibleDisplayFrame(visible);
            int height = content.getRootView().getHeight();
            bottom = Math.max(0, height - visible.bottom);
            if (bottom < height / 5) bottom = 0; // status/navigation bars only
        }
        if (bottom != lastKeyboardBottom) {
            lastKeyboardBottom = bottom;
            messageSend(new String[]{"rezvivo-keyboard-inset", Integer.toString(bottom)});
        }
    }

    @TargetApi(30)
    private static final class ModernInsets {
        static int keyboardBottom(WindowInsets insets) {
            return insets.isVisible(WindowInsets.Type.ime())
                ? insets.getInsets(WindowInsets.Type.ime()).bottom : 0;
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

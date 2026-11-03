package io.castleengine;

import android.app.Activity;
import android.app.ActivityManager;
import android.app.ApplicationExitInfo;
import android.app.Application;
import android.app.ProgressDialog;
import android.content.Context;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.PopupWindow;
import java.lang.ref.WeakReference;
import org.json.JSONObject;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;

/** Platform I/O shared by all Pascal HTTP/cache clients. TLS uses Android's
 * certificate and hostname verification, without bundled OpenSSL libraries. */
public final class RezvivoPlatform {
    private static final AtomicLong nextRequest = new AtomicLong();
    private static final ConcurrentHashMap<Long, Request> requests = new ConcurrentHashMap<>();
    private static final int MAX_RESPONSE = 256 * 1024 * 1024;
    private static final WeakHashMap<Activity, WeakReference<GraphicsProgress>> graphicsBadges = new WeakHashMap<>();
    private static boolean graphicsLifecycleRegistered;

    /** Native rendering can be busy compiling a shader. This small Android
     * view stays animated on the UI thread and never takes input focus. No
     * percentage is shown: the driver provides no measurable total work. */
    private static final class GraphicsProgress extends LinearLayout {
        private final Activity activity;
        private final TextView label;
        private final PopupWindow popup;
        private final Handler handler = new Handler(Looper.getMainLooper());
        private boolean paused, finished;
        private final Runnable show = this::showWindow;
        private final Runnable hide = this::hideWindow;
        GraphicsProgress(Activity activity) {
            super(activity);
            this.activity = activity;
            setOrientation(HORIZONTAL);
            setGravity(Gravity.CENTER_VERTICAL);
            setFocusable(false);
            setClickable(false);
            float dp = getResources().getDisplayMetrics().density;
            int pad = Math.round(12 * dp);
            setPadding(pad, pad, pad, pad);
            GradientDrawable background = new GradientDrawable();
            background.setColor(Color.argb(242, 20, 36, 44));
            background.setCornerRadius(12 * dp);
            setBackground(background);
            ProgressBar spinner = new ProgressBar(activity, null, android.R.attr.progressBarStyleSmall);
            spinner.setIndeterminateTintList(android.content.res.ColorStateList.valueOf(Color.rgb(81, 204, 221)));
            addView(spinner, new LinearLayout.LayoutParams(Math.round(24 * dp), Math.round(24 * dp)));
            label = new TextView(activity);
            label.setTextColor(Color.WHITE);
            label.setTextSize(15);
            label.setMaxWidth(Math.max(1, getResources().getDisplayMetrics().widthPixels - Math.round(96 * dp)));
            LinearLayout.LayoutParams textParams = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            textParams.leftMargin = pad;
            addView(label, textParams);
            // NativeActivity owns its window's surface: ordinary Android child
            // views have layout but are not painted over that EGL surface.
            // A non-focusable popup has its own surface and takes no input.
            popup = new PopupWindow(this, ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT, false);
            popup.setTouchable(false);
            popup.setOutsideTouchable(false);
            popup.setInputMethodMode(PopupWindow.INPUT_METHOD_NOT_NEEDED);
            popup.setElevation(6 * dp);
            popup.setAnimationStyle(0);
        }
        private void showWindow() {
            if (paused || finished || popup.isShowing() || activity.isFinishing() || activity.isDestroyed()) return;
            if (!activity.hasWindowFocus()) return;
            View decor = activity.getWindow().getDecorView();
            int inset = decor.getRootWindowInsets() == null ? 0 : decor.getRootWindowInsets().getSystemWindowInsetBottom();
            try {
                popup.showAtLocation(decor, Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL,
                    0, Math.round(24 * getResources().getDisplayMetrics().density) + inset);
            } catch (android.view.WindowManager.BadTokenException ignored) {
                // Activity can lose its surface between a posted update and show.
            }
        }
        private void hideWindow() {
            popup.dismiss(); graphicsBadges.remove(activity);
        }
        void update(String caption, long elapsedMs, boolean finished) {
            this.finished = finished;
            handler.removeCallbacks(hide);
            handler.removeCallbacks(show);
            if (finished) {
                // Keep a visible badge across adjacent compile/link jobs.
                handler.postDelayed(hide, 250);
            } else {
                label.setText(caption);
                if (!popup.isShowing()) handler.postDelayed(show, Math.max(0, 350 - elapsedMs));
                else popup.update();
            }
        }
        void pause(boolean value) {
            paused = value;
            if (paused) { handler.removeCallbacks(show); popup.dismiss(); }
        }
        void dispose() {
            handler.removeCallbacks(show); handler.removeCallbacks(hide); popup.dismiss();
        }
    }

    private static GraphicsProgress graphicsBadge(Activity activity) {
        WeakReference<GraphicsProgress> ref = graphicsBadges.get(activity);
        return ref == null ? null : ref.get();
    }

    public static void graphicsProgress(Activity activity, String caption, long elapsedMs, boolean finished) {
        activity.runOnUiThread(() -> {
            if (activity.isFinishing() || activity.isDestroyed()) return;
            if (!graphicsLifecycleRegistered) {
                graphicsLifecycleRegistered = true;
                activity.getApplication().registerActivityLifecycleCallbacks(new Application.ActivityLifecycleCallbacks() {
                    public void onActivityCreated(Activity a, Bundle b) { }
                    public void onActivityStarted(Activity a) { }
                    public void onActivityResumed(Activity a) { GraphicsProgress p=graphicsBadge(a); if(p!=null)p.pause(false); }
                    public void onActivityPaused(Activity a) { GraphicsProgress p=graphicsBadge(a); if(p!=null)p.pause(true); }
                    public void onActivityStopped(Activity a) { }
                    public void onActivitySaveInstanceState(Activity a, Bundle b) { }
                    public void onActivityDestroyed(Activity a) {
                        GraphicsProgress p=graphicsBadge(a); if(p!=null)p.dispose(); graphicsBadges.remove(a);
                    }
                });
            }
            GraphicsProgress progress = graphicsBadge(activity);
            if (progress == null) {
                if (finished) return;
                progress = new GraphicsProgress(activity);
                graphicsBadges.put(activity, new WeakReference<>(progress));
            }
            progress.update(caption, elapsedMs, finished);
        });
    }

    private static String previousAnrTrace(ApplicationExitInfo info) {
        // Native tombstones can be binary protobuf. Only ANR traces are text.
        if (info.getReason() != ApplicationExitInfo.REASON_ANR) return "";
        try (InputStream input = info.getTraceInputStream()) {
            if (input == null) return "";
            ByteArrayOutputStream output = new ByteArrayOutputStream();
            byte[] buffer = new byte[4096];
            int remaining = 24 * 1024, count;
            while (remaining > 0 && (count = input.read(buffer, 0, Math.min(buffer.length, remaining))) > 0) {
                output.write(buffer, 0, count); remaining -= count;
            }
            return new String(output.toByteArray(), StandardCharsets.UTF_8) +
                (remaining == 0 ? "\n[ANR trace truncated at 24 KiB]\n" : "");
        } catch (Exception e) { return ""; }
    }

    /** Diagnostic model metadata, deliberately excluding serials/Android ID. */
    public static String machineInformation(Activity activity) {
        StringBuilder text = new StringBuilder();
        text.append("Device: ").append(Build.MANUFACTURER).append(' ').append(Build.MODEL).append('\n');
        text.append("Android: ").append(Build.VERSION.RELEASE).append("; API ").append(Build.VERSION.SDK_INT).append('\n');
        text.append("ABIs: ").append(Arrays.toString(Build.SUPPORTED_ABIS)).append('\n');
        ActivityManager am = (ActivityManager) activity.getSystemService(Context.ACTIVITY_SERVICE);
        if (am != null) {
            ActivityManager.MemoryInfo info = new ActivityManager.MemoryInfo();
            am.getMemoryInfo(info);
            text.append("RAM bytes: total=").append(info.totalMem).append("; available=").append(info.availMem)
                .append("; low memory=").append(info.lowMemory).append('\n');
            text.append("Java heap limit MiB: ").append(am.getMemoryClass()).append('\n');
        }
        return text.toString();
    }

    /** Match the previous session, not an arbitrary older crash. The OS can
     * kill native code without invoking any Pascal/Java exception handler. */
    public static String previousExitInfo(Activity activity, int pid, long sinceUtcMs) {
        if (Build.VERSION.SDK_INT < 30 || pid <= 0 || sinceUtcMs <= 0) return "";
        try {
            ActivityManager am = (ActivityManager) activity.getSystemService(Context.ACTIVITY_SERVICE);
            if (am == null) return "";
            for (ApplicationExitInfo info : am.getHistoricalProcessExitReasons(null, pid, 8)) {
                if (info.getTimestamp() + 5000 < sinceUtcMs ||
                    !activity.getPackageName().equals(info.getProcessName())) continue;
                String description = info.getDescription();
                if (description != null && description.length() > 2048) description = description.substring(0, 2048);
                return new JSONObject().put("reason", info.getReason()).put("status", info.getStatus())
                    .put("timestamp_utc_ms", info.getTimestamp()).put("description", description)
                    .put("rss_kib", info.getRss()).put("pss_kib", info.getPss())
                    .put("anr_trace", previousAnrTrace(info)).toString();
            }
        } catch (Exception e) {
            android.util.Log.w("REZVIVO", "Cannot query previous process exit: " + e.getClass().getSimpleName());
        }
        return "";
    }
    private static final class Request {
        volatile boolean cancelled;
        volatile HttpURLConnection connection;
        void check() throws IOException { if (cancelled) throw new InterruptedIOException("HTTP request cancelled"); }
    }
    /** Pixels per physical inch, not the framebuffer resolution or CGE's
     *  96-based dp conversion. Bad vendor metadata falls back to Android's
     *  user-selected display density. */
    public static float displayDpi(Activity activity) {
        android.util.DisplayMetrics m = activity.getResources().getDisplayMetrics();
        float dpi = (m.xdpi + m.ydpi) * 0.5f;
        if ((Float.isNaN(dpi) || Float.isInfinite(dpi)) || dpi < 100 || dpi > 1000 ||
                Math.max(m.xdpi,m.ydpi) > 1.25f * Math.min(m.xdpi,m.ydpi))
            dpi = m.densityDpi;
        // Respect accessibility/display zoom when it is larger than physical scale.
        return Math.max(dpi, m.densityDpi);
    }

    public static long newRequest() {
        long id = nextRequest.incrementAndGet();
        requests.put(id, new Request());
        return id;
    }
    public static void cancelRequest(long id) {
        Request r = requests.get(id);
        if (r != null) {
            r.cancelled = true;
            HttpURLConnection c = r.connection;
            if (c != null) c.disconnect();
        }
    }
    public static void finishRequest(long id) { requests.remove(id); }
    public static Object[] http(long id, String method, String address, String headers,
                                byte[] body, int connectMs, int readMs) {
        return http(id, method, address, headers, body, connectMs, readMs, true, MAX_RESPONSE);
    }
    public static Object[] http(long id, String method, String address, String headers,
                                byte[] body, int connectMs, int readMs, boolean followRedirects, int maxBytes) {
        Request request = requests.get(id);
        if (request == null) return new Object[]{"0", "", new byte[0], "Unknown HTTP request"};
        final int limit = maxBytes > 0 ? Math.min(maxBytes, MAX_RESPONSE) : MAX_RESPONSE;
        try {
            if (body != null && body.length > MAX_RESPONSE) throw new IOException("HTTP body exceeds 256 MiB");
            URL url = new URL(address);
            Map<String,String> fields = new LinkedHashMap<>();
            for (String line : headers.split("\\r?\\n")) {
                int colon = line.indexOf(':');
                if (colon > 0) fields.put(line.substring(0, colon).trim(), line.substring(colon + 1).trim());
            }
            for (int redirect = 0; redirect <= 5; redirect++) {
                request.check();
                if (!url.getProtocol().equals("https") && !url.getProtocol().equals("http"))
                    throw new IOException("Unsupported HTTP protocol");
                HttpURLConnection c = (HttpURLConnection) url.openConnection();
                request.connection = c;
                try {
                    request.check();
                    c.setInstanceFollowRedirects(false);
                    c.setConnectTimeout(Math.max(1, connectMs));
                    c.setReadTimeout(Math.max(1, readMs));
                    c.setRequestMethod(method);
                    for (Map.Entry<String,String> h : fields.entrySet()) c.setRequestProperty(h.getKey(), h.getValue());
                    if (body != null && body.length > 0) {
                        c.setDoOutput(true);
                        c.setFixedLengthStreamingMode(body.length);
                        try (OutputStream out = c.getOutputStream()) { out.write(body); }
                    }
                    int status = c.getResponseCode();
                    String location = c.getHeaderField("Location");
                    if (followRedirects && location != null && (status == 301 || status == 302 || status == 303 || status == 307 || status == 308)) {
                        if (redirect == 5) throw new IOException("Too many HTTP redirects");
                        URL target = new URL(url, location);
                        if (url.getProtocol().equals("https") && !target.getProtocol().equals("https"))
                            throw new IOException("HTTPS downgrade refused");
                        if (!url.getHost().equalsIgnoreCase(target.getHost()) || url.getPort() != target.getPort())
                            fields.keySet().removeIf(k -> k.equalsIgnoreCase("Authorization") || k.equalsIgnoreCase("Cookie"));
                        if (status == 303 || ((status == 301 || status == 302) && method.equals("POST"))) {
                            method = "GET"; body = null;
                            fields.keySet().removeIf(k -> k.equalsIgnoreCase("Content-Type") || k.equalsIgnoreCase("Content-Length"));
                        }
                        url = target;
                        continue;
                    }
                    StringBuilder responseHeaders = new StringBuilder();
                    for (Map.Entry<String,List<String>> h : c.getHeaderFields().entrySet())
                        if (h.getKey() != null) for (String v : h.getValue()) responseHeaders.append(h.getKey()).append(": ").append(v).append('\n');
                    if (c.getContentLengthLong() > limit) throw new IOException("HTTP response exceeds byte limit");
                    InputStream source = status >= 400 ? c.getErrorStream() : c.getInputStream();
                    ByteArrayOutputStream bytes = new ByteArrayOutputStream();
                    if (source != null) try (InputStream in = source) {
                        byte[] buffer = new byte[64 * 1024];
                        int count;
                        while ((count = in.read(buffer)) != -1) {
                            request.check();
                            if (bytes.size() > limit - count) throw new IOException("HTTP response exceeds byte limit");
                            bytes.write(buffer, 0, count);
                        }
                    }
                    request.check();
                    return new Object[]{Integer.toString(status), responseHeaders.toString(), bytes.toByteArray(), ""};
                } finally {
                    request.connection = null;
                    c.disconnect();
                }
            }
            throw new IOException("Too many HTTP redirects");
        } catch (Exception e) { return new Object[]{"0", "", new byte[0], e.toString()}; }
    }

    /** Existing geometry and atlas loaders need filenames. Extract only the
     * installer payload indexed at build time; never inspect unrelated assets.
     * Called on the native game thread, not the Android UI thread. */
    @SuppressWarnings("deprecation")
    public static String prepareAssets(Activity activity) throws IOException {
        // Keep the same data/ layout as desktop under the app-private root.
        // Shared filename-based loaders and writable users/log/cache paths
        // can then use their usual relative layout without accessing the APK.
        File root = new File(activity.getFilesDir(), "data");
        ArrayList<String> entries = new ArrayList<>();
        String signature;
        try (BufferedReader in = new BufferedReader(new InputStreamReader(activity.getAssets().open("rezvivo-assets.txt"), StandardCharsets.UTF_8))) {
            signature = in.readLine();
            String line;
            while ((line = in.readLine()) != null) if (!line.isEmpty()) entries.add(line);
        }
        if (signature == null || !signature.matches("[a-f0-9]{64}")) throw new IOException("Invalid asset index");
        File marker = new File(root, ".ready");
        if (marker.isFile()) try (BufferedReader in = new BufferedReader(new FileReader(marker))) {
            if (signature.equals(in.readLine())) return root.getAbsolutePath();
        }
        final ProgressDialog[] progress = new ProgressDialog[1];
        activity.runOnUiThread(() -> {
            if (activity.isFinishing()) return;
            progress[0] = new ProgressDialog(activity);
            progress[0].setTitle("REZVIVO");
            progress[0].setMessage("Preparing game resources");
            progress[0].setProgressStyle(ProgressDialog.STYLE_HORIZONTAL);
            progress[0].setMax(entries.size());
            progress[0].setCancelable(false);
            progress[0].show();
        });
        try {
            byte[] buffer = new byte[128 * 1024];
            String prefix = root.getCanonicalPath() + File.separator;
            int done = 0;
            for (String name : entries) {
                File dest = new File(root, name);
                if (!dest.getCanonicalPath().startsWith(prefix)) throw new IOException("Invalid asset path");
                File parent = dest.getParentFile();
                if (!parent.isDirectory() && !parent.mkdirs()) throw new IOException("Cannot create resource directory");
                File temp = new File(parent, dest.getName() + ".installing");
                try (InputStream in = activity.getAssets().open(name); FileOutputStream out = new FileOutputStream(temp)) {
                    int count;
                    while ((count = in.read(buffer)) != -1) out.write(buffer, 0, count);
                }
                if (!temp.renameTo(dest)) throw new IOException("Cannot install resource: " + name);
                final int count = ++done;
                if (count % 32 == 0 || count == entries.size()) activity.runOnUiThread(() -> {
                    if (progress[0] != null) progress[0].setProgress(count);
                });
            }
            File temp = new File(root, ".ready.installing");
            try (FileWriter out = new FileWriter(temp)) { out.write(signature + "\n"); }
            if (!temp.renameTo(marker)) throw new IOException("Cannot commit resource installation");
            return root.getAbsolutePath();
        } finally { activity.runOnUiThread(() -> { if (progress[0] != null) progress[0].dismiss(); }); }
    }
}

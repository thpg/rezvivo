package io.castleengine;

import android.app.Activity;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.provider.OpenableColumns;
import java.io.*;
import java.security.MessageDigest;
import java.util.*;
import java.util.regex.*;

/** System document picker. Never interprets a content URI as a filesystem path. */
@SuppressWarnings("deprecation")
public final class ServiceRezvivoFiles extends ServiceAbstract {
    private static final int PICK_DOCUMENT = 47231;
    private static final long MAX_BYTES = 32L * 1024 * 1024;
    private String pending;
    private Set<String> extensions;
    private volatile boolean destroyed;

    public ServiceRezvivoFiles(MainActivity activity) { super(activity); }
    @Override public String getName() { return "rezvivo-files"; }

    @Override public boolean messageReceived(String[] parts) {
        if (parts.length != 4 || !parts[0].equals("rezvivo-file-open")) return false;
        if (pending != null) return true;
        pending = parts[1];
        extensions = new HashSet<>();
        Matcher m = Pattern.compile("\\*\\.([a-zA-Z0-9]+)").matcher(parts[3]);
        while (m.find()) extensions.add("." + m.group(1).toLowerCase(Locale.ROOT));
        try {
            Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
            intent.addCategory(Intent.CATEGORY_OPENABLE);
            // FIT has no reliable provider-wide MIME type; extension validation
            // follows selection so Downloads and cloud documents stay selectable.
            intent.setType("*/*");
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            intent.putExtra(Intent.EXTRA_TITLE, parts[2]);
            getActivity().startActivityForResult(intent, PICK_DOCUMENT);
        } catch (Exception e) { finish(pending, "error", e.getLocalizedMessage()); }
        return true;
    }

    private void finish(String request, String status, String value) {
        getActivity().runOnUiThread(() -> {
            if (destroyed || !Objects.equals(pending, request)) return;
            pending = null;
            messageSend(new String[]{"rezvivo-file-result", request, status, value == null ? "" : value});
        });
    }

    @Override public void onActivityResult(int requestCode, int resultCode, Intent data) {
        if (requestCode != PICK_DOCUMENT || pending == null) return;
        final String request = pending;
        if (resultCode != Activity.RESULT_OK || data == null || data.getData() == null) {
            finish(request, "cancel", ""); return;
        }
        final Uri uri = data.getData();
        final Set<String> allowed = new HashSet<>(extensions);
        new Thread(() -> {
            try { finish(request, "ok", importDocument(uri, allowed)); }
            catch (Exception e) { finish(request, "error", e.getLocalizedMessage()); }
        }, "REZVIVO-file-import").start();
    }

    private String importDocument(Uri uri, Set<String> allowed) throws Exception {
        String name = null;
        try (Cursor c = getActivity().getContentResolver().query(uri,
                new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE}, null, null, null)) {
            if (c != null && c.moveToFirst()) {
                int n = c.getColumnIndex(OpenableColumns.DISPLAY_NAME);
                if (n >= 0 && !c.isNull(n)) name = c.getString(n);
                int size = c.getColumnIndex(OpenableColumns.SIZE);
                if (size >= 0 && !c.isNull(size) && c.getLong(size) > MAX_BYTES)
                    throw new IOException("The selected file exceeds 32 MiB.");
            }
        }
        if (name == null || name.isEmpty()) name = uri.getLastPathSegment();
        if (name == null) throw new IOException("The selected document has no filename.");
        int dot = name.lastIndexOf('.');
        String ext = dot < 0 ? "" : name.substring(dot).toLowerCase(Locale.ROOT);
        if (!allowed.isEmpty() && !allowed.contains(ext))
            throw new IOException("This file type is not supported here.");
        name = name.replaceAll("[\\p{Cntrl}\\\\/:*?\"<>|]", "_");
        if (name.length() > 120) name = name.substring(0, 120 - ext.length()) + ext;
        File root = new File(getActivity().getFilesDir(), "imports");
        if (!root.isDirectory() && !root.mkdirs()) throw new IOException("Cannot create the import directory.");
        File temp = File.createTempFile("selected-", ".part", root);
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            try (InputStream in = getActivity().getContentResolver().openInputStream(uri);
                 OutputStream out = new FileOutputStream(temp)) {
                if (in == null) throw new IOException("Cannot read the selected document.");
                byte[] buffer = new byte[64 * 1024];
                long size = 0;
                int count;
                while ((count = in.read(buffer)) != -1) {
                    if (destroyed) throw new IOException("Import cancelled.");
                    size += count;
                    if (size > MAX_BYTES) throw new IOException("The selected file exceeds 32 MiB.");
                    digest.update(buffer, 0, count); out.write(buffer, 0, count);
                }
                if (size == 0) throw new IOException("The selected file is empty.");
            }
            StringBuilder hash = new StringBuilder();
            for (byte b : digest.digest()) hash.append(String.format(Locale.ROOT, "%02x", b & 255));
            File directory = new File(root, hash.toString());
            if (!directory.isDirectory() && !directory.mkdirs()) throw new IOException("Cannot create the import directory.");
            File target = new File(directory, name);
            if (!target.isFile() && !temp.renameTo(target)) throw new IOException("Cannot save the imported file.");
            return target.getAbsolutePath();
        } finally { if (temp.exists()) temp.delete(); }
    }

    @Override public void onDestroy() { destroyed = true; pending = null; }
}

package io.castleengine;

import android.Manifest;
import android.bluetooth.*;
import android.bluetooth.le.*;
import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.ParcelUuid;
import org.json.JSONArray;
import java.util.*;

/** BLE GATT transport only. FTMS/HR/CPS/CSC decoding and trainer control remain
 * in the same Pascal protocol classes used by desktop. All GATT operations
 * are serialized, including CCCD writes before control-point requests. */
@SuppressWarnings("deprecation")
public final class ServiceRezvivo extends ServiceAbstract {
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Map<String,Link> links = new HashMap<>();
    private final Map<String,Long> seen = new HashMap<>();
    private BluetoothLeScanner scanner;
    private boolean scanning;
    private static final UUID CCCD = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb");
    public ServiceRezvivo(MainActivity activity) { super(activity); }
    @Override public String getName() { return "rezvivo"; }

    private BluetoothAdapter adapter() {
        BluetoothManager manager = (BluetoothManager)getActivity().getSystemService(Context.BLUETOOTH_SERVICE);
        return manager == null ? null : manager.getAdapter();
    }
    private boolean permissions() {
        if (Build.VERSION.SDK_INT < 23) return true;
        String[] required = Build.VERSION.SDK_INT >= 31 ? new String[]{Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT}
                                                       : new String[]{Manifest.permission.ACCESS_FINE_LOCATION};
        for (String permission : required) if (getActivity().checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED) {
            getActivity().requestPermission(permission);
            return false;
        }
        return true;
    }
    private void connection(String address, String state, String detail) {
        messageSend(new String[]{"ble-connection", address, state, detail});
    }
    private final ScanCallback scanCallback = new ScanCallback() {
        @Override public void onScanResult(int type, ScanResult result) {
            main.post(() -> {
                if (!scanning) return;
                try {
                    String address = result.getDevice().getAddress();
                    long now = android.os.SystemClock.elapsedRealtime();
                    Long previous = seen.get(address);
                    if (previous != null && now - previous < 3000) return;
                    seen.put(address, now);
                    String name = result.getScanRecord() == null ? null : result.getScanRecord().getDeviceName();
                    if (name == null) name = result.getDevice().getName();
                    if (name == null) name = address;
                    messageSend(new String[]{"ble-device-found", address, name, Integer.toString(result.getRssi())});
                } catch (SecurityException e) { stopScan(); }
            });
        }
        @Override public void onBatchScanResults(List<ScanResult> results) {
            for (ScanResult r : results) onScanResult(0, r);
        }
        @Override public void onScanFailed(int error) {
            main.post(() -> { scanning = false; messageSend(new String[]{"ble-error", "Scan failed: " + error}); });
        }
    };
    private void startScan() {
        if (scanning || !permissions()) return;
        BluetoothAdapter a = adapter();
        if (a == null || !a.isEnabled()) { messageSend(new String[]{"ble-error", "Bluetooth is unavailable or disabled"}); return; }
        scanner = a.getBluetoothLeScanner();
        if (scanner == null) return;
        seen.clear();
        scanning = true;
        // Some older trainers omit service UUIDs in advertisements: filter at
        // discovery/connection in Pascal rather than hiding those devices.
        scanner.startScan(null, new ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_BALANCED).build(), scanCallback);
    }
    private void stopScan() {
        if (scanning && scanner != null) try { scanner.stopScan(scanCallback); } catch (SecurityException ignored) { }
        scanning = false;
    }

    private final class Operation {
        final String service, characteristic;
        final byte[] bytes;
        final boolean subscribe, response;
        Operation(String[] p, boolean s) {
            service = p[2]; characteristic = p[3]; subscribe = s;
            bytes = s ? null : hex(p[4]); response = !s && p[5].equals("1");
        }
    }
    private final class Link {
        final String address;
        final ArrayDeque<Operation> queue = new ArrayDeque<>();
        BluetoothGatt gatt;
        Operation pending;
        boolean ready;
        final Runnable timeout = () -> fail("GATT operation timed out");
        Link(String a) { address = a; }
        void fail(String reason) {
            if (links.get(address) != this) return;
            connection(address, "error", reason);
            close(); links.remove(address);
        }
        void close() {
            main.removeCallbacks(timeout); queue.clear(); pending = null; ready = false;
            if (gatt != null) {
                try { gatt.disconnect(); } catch (SecurityException ignored) { }
                gatt.close(); gatt = null;
            }
        }
        void completed(int status) {
            main.removeCallbacks(timeout);
            if (pending == null) return;
            if (status != BluetoothGatt.GATT_SUCCESS) { fail("GATT error " + status); return; }
            pending = null; next();
        }
        void next() {
            if (!ready || pending != null || queue.isEmpty() || gatt == null) return;
            pending = queue.remove();
            BluetoothGattService service = gatt.getService(UUID.fromString(pending.service));
            BluetoothGattCharacteristic c = service == null ? null : service.getCharacteristic(UUID.fromString(pending.characteristic));
            if (c == null) { fail("GATT characteristic is missing"); return; }
            boolean accepted;
            if (pending.subscribe) {
                BluetoothGattDescriptor d = c.getDescriptor(CCCD);
                if (d == null || !gatt.setCharacteristicNotification(c, true)) { fail("Cannot subscribe to GATT notifications"); return; }
                d.setValue((c.getProperties() & BluetoothGattCharacteristic.PROPERTY_INDICATE) != 0 ?
                    BluetoothGattDescriptor.ENABLE_INDICATION_VALUE : BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE);
                accepted = gatt.writeDescriptor(d);
            } else {
                c.setWriteType(pending.response ? BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT : BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE);
                c.setValue(pending.bytes);
                accepted = gatt.writeCharacteristic(c);
            }
            if (!accepted) { fail("GATT operation was rejected"); return; }
            main.postDelayed(timeout, 10000);
        }
        final BluetoothGattCallback callback = new BluetoothGattCallback() {
            @Override public void onConnectionStateChange(BluetoothGatt g, int status, int state) {
                main.post(() -> {
                    if (g != gatt) return;
                    if (status != BluetoothGatt.GATT_SUCCESS) { fail("Bluetooth error " + status); return; }
                    if (state == BluetoothProfile.STATE_CONNECTED) {
                        if (!g.discoverServices()) fail("Cannot discover GATT services");
                    } else if (state == BluetoothProfile.STATE_DISCONNECTED) {
                        connection(address, "disconnected", "Bluetooth disconnected"); close(); links.remove(address);
                    }
                });
            }
            @Override public void onServicesDiscovered(BluetoothGatt g, int status) {
                main.post(() -> {
                    if (g != gatt) return;
                    if (status != BluetoothGatt.GATT_SUCCESS) { fail("GATT discovery failed"); return; }
                    main.removeCallbacks(timeout);
                    JSONArray services = new JSONArray();
                    for (BluetoothGattService s : g.getServices()) {
                        services.put(s.getUuid().toString());
                        for (BluetoothGattCharacteristic c : s.getCharacteristics()) services.put(c.getUuid().toString());
                    }
                    ready = true;
                    messageSend(new String[]{"ble-services", address, services.toString()});
                    connection(address, "connected", "Bluetooth connected");
                    next();
                });
            }
            private void notify(BluetoothGatt g, BluetoothGattCharacteristic c, byte[] bytes) {
                final byte[] copy = bytes.clone();
                main.post(() -> {
                    if (g != gatt) return;
                    messageSend(new String[]{"ble-notification", address, c.getService().getUuid().toString(), c.getUuid().toString(), hex(copy)});
                });
            }
            @Override public void onCharacteristicChanged(BluetoothGatt g, BluetoothGattCharacteristic c) { notify(g, c, c.getValue()); }
            @Override public void onCharacteristicChanged(BluetoothGatt g, BluetoothGattCharacteristic c, byte[] value) { notify(g, c, value); }
            @Override public void onDescriptorWrite(BluetoothGatt g, BluetoothGattDescriptor d, int status) {
                main.post(() -> { if (g == gatt) completed(status); });
            }
            @Override public void onCharacteristicWrite(BluetoothGatt g, BluetoothGattCharacteristic c, int status) {
                main.post(() -> { if (g == gatt) completed(status); });
            }
        };
    }
    private static byte[] hex(String text) {
        if ((text.length() & 1) != 0) throw new IllegalArgumentException("Invalid BLE hex data");
        byte[] bytes = new byte[text.length()/2];
        for (int i = 0; i < bytes.length; i++) bytes[i] = (byte)Integer.parseInt(text.substring(2*i, 2*i+2), 16);
        return bytes;
    }
    private static String hex(byte[] bytes) {
        char[] chars = new char[bytes.length*2];
        final char[] digits = "0123456789abcdef".toCharArray();
        for (int i = 0; i < bytes.length; i++) { chars[2*i] = digits[(bytes[i] & 255) >>> 4]; chars[2*i+1] = digits[bytes[i] & 15]; }
        return new String(chars);
    }
    @Override public boolean messageReceived(String[] p) {
        if (p.length == 0 || !p[0].startsWith("ble-")) return false;
        try {
            switch (p[0]) {
                case "ble-scan-start": startScan(); break;
                case "ble-scan-stop": stopScan(); break;
                case "ble-connect": {
                    if (p.length < 2 || !permissions()) break;
                    Link old = links.remove(p[1]); if (old != null) old.close();
                    BluetoothAdapter a = adapter();
                    if (a == null) { connection(p[1], "error", "Bluetooth unavailable"); break; }
                    Link link = new Link(p[1]); links.put(p[1], link);
                    link.gatt = a.getRemoteDevice(p[1]).connectGatt(getActivity(), false, link.callback, BluetoothDevice.TRANSPORT_LE);
                    if (link.gatt == null) link.fail("Cannot connect Bluetooth device");
                    else main.postDelayed(link.timeout, 20000);
                    break;
                }
                case "ble-disconnect": {
                    if (p.length < 2) break;
                    Link link = links.remove(p[1]); if (link != null) link.close();
                    connection(p[1], "disconnected", "Bluetooth disconnected"); break;
                }
                case "ble-subscribe": case "ble-write": {
                    boolean subscribe = p[0].equals("ble-subscribe");
                    if (p.length < (subscribe ? 4 : 6)) break;
                    Link link = links.get(p[1]);
                    if (link == null) break;
                    if (link.queue.size() >= 32) { link.fail("GATT queue overflow"); break; }
                    link.queue.add(new Operation(p, subscribe)); link.next(); break;
                }
                default: return false;
            }
        } catch (Exception e) {
            if (p.length > 1) { Link l = links.get(p[1]); if (l != null) l.fail(e.toString()); }
            messageSend(new String[]{"ble-error", e.toString()});
        }
        return true;
    }
    @Override public void onDestroy() {
        stopScan();
        for (Link l : links.values()) l.close();
        links.clear();
    }
}

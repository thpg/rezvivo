package io.castleengine;

import android.content.Context;
import android.hardware.input.InputManager;
import android.util.SparseArray;
import android.view.InputDevice;
import android.view.KeyEvent;
import android.view.MotionEvent;

/** Left stick and D-pad steering for USB/Bluetooth game controllers. */
public final class ServiceRezvivoControllers extends ServiceAbstract implements InputManager.InputDeviceListener {
    private static final class State { float x, hat; boolean left, right; }
    private final SparseArray<State> states = new SparseArray<>();
    private InputManager inputs;
    private String lastMessage = "";
    public ServiceRezvivoControllers(MainActivity activity) { super(activity); }
    @Override public String getName() { return "rezvivo-controllers"; }
    @Override public void onCreate() {
        inputs = (InputManager)getActivity().getSystemService(Context.INPUT_SERVICE);
        if (inputs != null) inputs.registerInputDeviceListener(this, null);
    }
    private static boolean controller(InputDevice device) {
        if (device == null) return false;
        int sources = device.getSources();
        return (sources & InputDevice.SOURCE_JOYSTICK) == InputDevice.SOURCE_JOYSTICK ||
            (sources & InputDevice.SOURCE_GAMEPAD) == InputDevice.SOURCE_GAMEPAD;
    }
    private State state(int id) {
        State s = states.get(id);
        if (s == null) { s = new State(); states.put(id, s); }
        return s;
    }
    private void publish() {
        State selected = null;
        float largest = -1;
        for (int i = 0; i < states.size(); i++) {
            State s = states.valueAt(i);
            float magnitude = (s.left || s.right || Math.abs(s.hat) > 0.5f) ? 1 : Math.abs(s.x);
            if (magnitude > largest) { selected = s; largest = magnitude; }
        }
        String available = selected == null ? "0" : "1";
        int x = selected == null ? 0 : Math.round(Math.max(-1, Math.min(1, selected.x)) * 10000);
        String left = selected != null && (selected.left || selected.hat < -0.5f) ? "1" : "0";
        String right = selected != null && (selected.right || selected.hat > 0.5f) ? "1" : "0";
        String signature = available + ":" + x + ":" + left + ":" + right;
        if (!signature.equals(lastMessage)) {
            lastMessage = signature;
            messageSend(new String[]{"rezvivo-gamepad", available, Integer.toString(x), left, right});
        }
    }
    @Override public boolean onControllerMotionEvent(MotionEvent event) {
        if (!controller(event.getDevice()) || event.getActionMasked() != MotionEvent.ACTION_MOVE) return false;
        State s = state(event.getDeviceId());
        s.x = event.getAxisValue(MotionEvent.AXIS_X);
        s.hat = event.getAxisValue(MotionEvent.AXIS_HAT_X);
        publish();
        return true;
    }
    @Override public boolean onControllerKeyEvent(KeyEvent event) {
        if (!controller(event.getDevice())) return false;
        int key = event.getKeyCode();
        if (key != KeyEvent.KEYCODE_DPAD_LEFT && key != KeyEvent.KEYCODE_DPAD_RIGHT) return false;
        if (event.getAction() != KeyEvent.ACTION_DOWN && event.getAction() != KeyEvent.ACTION_UP) return false;
        State s = state(event.getDeviceId());
        boolean down = event.getAction() == KeyEvent.ACTION_DOWN;
        if (key == KeyEvent.KEYCODE_DPAD_LEFT) s.left = down; else s.right = down;
        publish();
        return true;
    }
    @Override public void onInputDeviceAdded(int id) { }
    @Override public void onInputDeviceChanged(int id) { states.remove(id); publish(); }
    @Override public void onInputDeviceRemoved(int id) { states.remove(id); publish(); }
    @Override public void onPause() { states.clear(); publish(); }
    @Override public void onDestroy() {
        if (inputs != null) inputs.unregisterInputDeviceListener(this);
        states.clear(); publish();
    }
}

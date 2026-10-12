"""Native vector-map zoom, cache and label smoke test (isolated hidden game)."""
import ctypes
import json
import sys
import time
from pathlib import Path

from McpHarness import GameSession, GPULock
from RideRecoveryFocusMcpTest import NativeUI


def run():
    game = Path(__file__).resolve().parents[1]
    out = game / 'tests/artifacts/vector-map-20261012/zoom'
    out.mkdir(parents=True, exist_ok=True)
    exe = sys.argv[1] if len(sys.argv) > 1 else 'third_person_navigation.exe'
    with GPULock():
        session = GameSession(game, out, executable=exe,
                              graphics={'fps_limit': 60, 'msaa': 0})
        session.env['REZVIVO_TEST_HIDDEN'] = '1'
        session.env['REZVIVO_OFFLINE'] = '1'
        with session as app:
            app.call('app.switch_view', view='routes')
            app.call('menu.inspect', lat=55.761, lon=37.610, zoom=16)
            ui = NativeUI(app)
            rows = []
            def read():
                state = app.call('menu.inspect')
                rows.append(state)
                return state['globe']
            until = time.monotonic() + 40
            while time.monotonic() < until:
                state = read()
                v = state['vector']
                if v['enabled'] and v['ready'] > 0 and v['ready'] >= v['wanted'] and not v['pending']:
                    break
                time.sleep(.3)
            assert v['ready'] > 0 and v['labels'] > 0, v
            time.sleep(1)
            app.call('app.screenshot', path=str(out/'moscow-z16.png'), inline=False)
            before = read()['vector']
            time.sleep(1)
            after = read()['vector']
            assert before['geometry_builds'] == after['geometry_builds'], (before, after)
            assert before['gpu_uploads'] == after['gpu_uploads'], (before, after)
            # Real native wheel event: zoom advances by a quarter level.
            width, height = ui.size()
            x, y = width * 3 // 4, height // 2
            ui.user.SendMessageW(ui.hwnd, 0x0200, 0, x | (y << 16))
            class Point(ctypes.Structure):
                _fields_ = [('x', ctypes.c_long), ('y', ctypes.c_long)]
            pt = Point(x, y)
            ui.user.ClientToScreen(ctypes.c_void_p(ui.hwnd), ctypes.byref(pt))
            ui.user.SendMessageW(ui.hwnd, 0x020A, 120 << 16,
                                 (pt.x & 65535) | ((pt.y & 65535) << 16))
            time.sleep(1)
            fractional = read()
            assert abs(fractional['fractional_zoom'] - 16.25) < .02, fractional
            app.call('app.screenshot', path=str(out/'moscow-z16-quarter.png'), inline=False)
            for zoom in (18, 14, 12, 10, 16):
                app.call('menu.inspect', lat=55.761, lon=37.610, zoom=zoom)
                time.sleep(2)
                state = read()
                assert state['vector']['enabled'] == (zoom >= 12), state
                if zoom >= 14:
                    assert state['vector']['labels'] > 0, state
                app.call('app.screenshot', path=str(out/f'moscow-z{zoom}-return.png'), inline=False)
                print(json.dumps({'zoom': zoom, 'vector': state['vector']}), flush=True)
            # Resize the actual window, then change view and return to the map.
            ui.user.SetWindowPos(ctypes.c_void_p(ui.hwnd), None, 0, 0, 1280, 800, 0x0016)
            time.sleep(1)
            app.call('app.screenshot', path=str(out/'moscow-resized.png'), inline=False)
            app.call('app.switch_view', view='devices')
            app.call('app.switch_view', view='routes')
            time.sleep(.4)
            assert read()['vector']['enabled']
            (out/'stats.json').write_text(json.dumps(rows, indent=2), encoding='utf-8')
    print('PASS: vector labels, fractional native zoom, overview, resize, stable cache and clean shutdown')


if __name__ == '__main__':
    run()

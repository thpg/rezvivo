"""Real-window regression: map teleport, session teardown, then another ride.

Hidden Windows client, disposable account and no uploads/devices. Map requests
use the normal guest API. An old client fails in RegisterContainer on re-entry.
"""
import argparse
import json
from pathlib import Path
import time

from McpHarness import GameSession, GPULock
from RideRecoveryFocusMcpTest import NativeUI, wait_for


def run(args):
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    app = GameSession(args.game.resolve(), out/'profile',
                      dict(fps_limit=30, msaa=0), executable=args.exe, native_api=True)
    app.env.update(REZVIVO_TEST_HIDDEN='1', REZVIVO_TEST_TRACE_EXCEPTIONS='1')
    result = {'passed': False, 'cycles': []}
    logs_before = set((app.game/'log').glob('*.log'))

    def state():
        return app.call('explore.state')['travel']

    def ready():
        return wait_for(state, lambda s: not s['preparing'], 360, 'world ready')

    try:
        with GPULock(), app:
            ui = NativeUI(app)
            app.setting('AudioMaster', 0)
            for cycle in range(args.cycles):
                print('Start cycle', cycle+1, flush=True)
                app.call('explore.start', lat=args.lat, lon=args.lon, mode='bicycle')
                ready()
                app.call('bots.local', limit=0, render=False)
                for number in range(args.teleports):
                    controls = wait_for(ui.controls,
                        lambda cs: any(c['name']=='RideMapToggle' for c in cs),
                        description='ride map header')
                    header = next(c for c in controls if c['name']=='RideMapToggle')
                    grow = next(c for c in controls if c['name']=='RideMapSize')
                    # ui.inspect exposes buttons, not map canvases. Locate the
                    # canvas from its header and published panel dimensions.
                    x, y, _, height = header['rect']
                    scale = height/26
                    width = grow['rect'][0]+grow['rect'][2]-x
                    map_height = (state()['ride_map']['height']-53)*scale
                    y += height-28*scale-map_height
                    _, window_height = ui.size()
                    pos = (int(window_height-y-map_height*.53)<<16) | int(x+width*.57)
                    ui.user.SendMessageW(ui.hwnd, 0x0200, 0, pos)
                    ui.user.SendMessageW(ui.hwnd, 0x0201, 1, pos)
                    ui.user.SendMessageW(ui.hwnd, 0x0202, 0, pos)
                    ui.click('RideMapTeleport')
                    settled = ready()
                    assert settled['point_start'] and settled['free']
                    assert settled['loading']['scene_ready']
                    time.sleep(1)
                    print('Teleport', number+1, 'ready', flush=True)
                app.call('ride.stop_full')
                views = app.call('app.views_list')
                assert not views['ride_alive'] and views['active']=='menu', views
                result['cycles'].append(dict(cycle=cycle+1, teleports=args.teleports,
                                             teardown=True))
        # Removing only one duplicate UI entry can let teardown appear to
        # succeed. Require clean re-entry AND no duplicate-parent warnings.
        for log in set((app.game/'log').glob('*.log'))-logs_before:
            text = log.read_text(encoding='utf-8-sig', errors='replace')
            assert 'already a part of other UI list' not in text, log
            assert 'EAccessViolation' not in text, log
        assert app.process.returncode == 0
        result['passed'] = True
    finally:
        (out/'result.json').write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
    print('Warmup re-entry: PASS', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--exe', default='third_person_navigation.exe')
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--cycles', type=int, default=3)
    parser.add_argument('--teleports', type=int, default=2)
    parser.add_argument('--lat', type=float, default=55.7615)
    parser.add_argument('--lon', type=float, default=37.4302)
    run(parser.parse_args())

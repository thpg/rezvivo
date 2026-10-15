"""Real keyboard start with a waiting companion, including an irregular loop seam."""
import argparse
import json
import math
import time
from pathlib import Path

from McpHarness import GameSession, GPULock
from RideRecoveryFocusMcpTest import NativeUI, wait_for


def run(route, out, loop_seam=False):
    game = Path(__file__).resolve().parents[1]
    app = GameSession(game, out/'profile', graphics={'fps_limit': 30, 'msaa': 0}, native_api=True)
    app.env['REZVIVO_TEST_HIDDEN'] = '1'
    with GPULock(), app:
        app.setting('AudioMaster', 0)
        app.setting('SimulationEnabled', False)
        app.call('ride.load_fit', path=str(route))
        wait_for(lambda: app.call('perf.state'),
                 lambda p: p.get('active') and p.get('prep_done'), 240, 'route ready')
        wait_for(lambda: app.call('bots.local'), lambda p: p.get('ready'), 90, 'bots ready')
        ui = NativeUI(app)
        rows = [app.call('path.follow_state', traffic=True, wheels=True)]
        ui.user.SendMessageW(ui.hwnd, 6, 1, 0)
        ui.user.SendMessageW(ui.hwnd, 0x100, ord('W'), 1)
        try:
            time.sleep(1.8)
        finally:
            ui.user.SendMessageW(ui.hwnd, 0x101, ord('W'), 1 | (3 << 30))
        began = time.monotonic()
        while time.monotonic()-began < 35:
            p = app.call('path.follow_state', traffic=True, wheels=True)
            rows.append(p)
            (out/'movement.json').write_text(json.dumps(rows, indent=2), encoding='utf-8')
            print(round(time.monotonic()-began, 1), 'sec:', round(p['distance'], 1),
                  'm;', round(p['power']), 'W;', round(p['speed']*3.6, 1), 'km/h', flush=True)
            if p['distance'] > 70:
                break
            time.sleep(2)
        app.call('app.screenshot', path=str(out/'riding.png'), inline=False)
        assert p['power'] > 100 and p['auto_move'], 'keyboard failed to power the rider'
        assert p['distance'] > 50 and p['speed'] > 1, 'blocked by companion at the start'
        assert p['traffic'][0]['ground_lease_rejected_m'] < .2
        assert p['traffic'][0]['front_ground_valid'] and p['traffic'][0]['rear_ground_valid']
        assert not list((app.out/'sessions').glob('*.fit')), 'keyboard watts recorded as exercise'
        if loop_seam:
            app.call('path.dump', file=str(out/'path.json'))
            points = json.loads((out/'path.json').read_text(encoding='utf-8'))['points']
            centers = [v[4:7] for v in points]
            length = sum(math.dist(a, b) for a, b in zip(centers, centers[1:]+centers[:1]))
            app.call('path.seek_m', dist_m=length-25)
            before = app.call('path.follow_state')['distance']
            seam = []
            began = time.monotonic()
            while time.monotonic()-began < 40:
                p = app.call('path.follow_state', traffic=True)
                seam.append(p)
                (out/'seam.json').write_text(json.dumps(seam, indent=2), encoding='utf-8')
                if p['distance']-before > 70 and p['segment'] < 40:
                    break
                time.sleep(1)
            assert p['distance']-before > 60 and p['segment'] < 40, 'cannot cross finish into next lap'
            app.call('app.screenshot', path=str(out/'next-lap.png'), inline=False)
            print('PASS finish -> next lap', round(p['distance']-before, 1), 'm', flush=True)
        app.call('ride.stop_full')
    print('PASS keyboard route start:', route.name, flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--route', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--loop-seam', action='store_true')
    args = parser.parse_args()
    run(args.route.resolve(), args.out.resolve(), args.loop_seam)

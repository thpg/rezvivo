"""Exercise shared generated billboards after a procedural forest was mounted."""
import argparse
import hashlib
import json
import re
from pathlib import Path
import time

from McpHarness import GameSession, GPULock, write_sim_fit
from McpRuntimeOptions import add_runtime_arguments
from RidePerformanceMcp import SCENARIOS


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    add_runtime_arguments(parser)
    parser.add_argument('--game', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--out', '--output', type=Path, required=True)
    parser.add_argument('--route', type=Path,
                        help='Existing forest route fixture; default is the historical Akhun case')
    parser.add_argument('--distance', type=float, default=5000,
                        help='Forest position along the route in metres')
    args = parser.parse_args()
    game, out = args.game.resolve(), args.out.resolve()
    route = args.route.resolve() if args.route else game/SCENARIOS['forest']['route']
    runtime = args.runtime.resolve() if args.runtime else game
    out.mkdir(parents=True, exist_ok=False)
    fit = out / 'steady.fit'
    write_sim_fit(fit, watts=190)
    graphics = dict(fps_limit=30, msaa=0, shadow_size=2048, shadow_filter=1,
                    shadow_distance=100, grass=0, vegetation_quality=2,
                    textures=2, vegetation_cache=1, vegetation_adaptive=0)
    result = dict(exe_sha256=hashlib.sha256((runtime/'third_person_navigation.exe').read_bytes()).hexdigest(),
                  route=str(route), distance=args.distance,
                  phases=[], scope='Functional mode switch, not an FPS benchmark or GL context recreation')
    session = GameSession(runtime, out/'profile', graphics)
    session.env.update(args.env)
    with GPULock(), session as app:
        app.setting('AudioMaster', 0)
        app.setting('SimulationFitPath', str(fit))
        app.setting('SimulationUseRoute', False)
        app.setting('SimulationEnabled', True)
        app.call('ride.load_fit', path=str(route))
        deadline = time.monotonic()+180
        while time.monotonic() < deadline:
            state = app.call('perf.state')
            if state.get('active') and state.get('prep_done'):
                break
            time.sleep(.5)
        else:
            raise AssertionError(('Route did not prepare', state))
        app.call('camera.chase', distance=6, height=3, aim_height=1)
        # Put visible trees in the camera as well as in the shadow frustum.
        # Settle the ordinary ground probes while moving after the seek.
        app.call('path.seek_m', dist_m=args.distance)
        app.call('sim.play')
        app.call('ride.start')
        time.sleep(3)
        app.call('sim.pause')
        app.call('ride.stop')
        for name, procedural in [('procedural', True), ('billboards-first', False),
                                  ('procedural-again', True), ('billboards-again', False)]:
            app.call('perf.set', procedural_trees=procedural, vegetation=True)
            before = app.call('perf.state')
            time.sleep(2)
            after = app.call('perf.state')
            app.call('app.screenshot', path=str(out/(name+'.png')), inline=False)
            assert after['procedural_trees'] == procedural, after
            assert after['active'] and after['viewport_visible'], after
            shadow_delta = after['vegetation_shadow_draws']-before['vegetation_shadow_draws']
            color_delta = after.get('vegetation_color_draws', 0)-before.get('vegetation_color_draws', 0)
            if not procedural:
                detail = dict(re.findall(r'(\w+)=([^ ]*)', after['procedural_vegetation']))
                assert detail['near'] == '0' and detail['cache_bytes'] == '0', detail
                assert int(detail['far']) > 0 and int(detail['atlases']) > 0, detail
                assert detail['error'] == '', detail
            assert color_delta == 0 and shadow_delta == 0, ('Obsolete renderer used', after)
            result['phases'].append(dict(name=name, state=after, legacy_shadow_draw_delta=shadow_delta,
                                        legacy_color_draw_delta=color_delta))
        app.call('ride.stop_full')
    result['passed'] = True
    (out/'result.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    print('PASS detailed/billboard switches, no legacy draws and normal shutdown', flush=True)


if __name__ == '__main__':
    main()

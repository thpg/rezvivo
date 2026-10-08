"""Hidden, isolated game regression for free walking, cycling and flight."""
import argparse
import json
import math
import time
from pathlib import Path
from McpHarness import GameSession, GPULock, write_sim_fit
from RideRecoveryFocusMcpTest import NativeUI, wait_for


def run(game, out, executable):
    app = GameSession(game, out/'profile', dict(fps_limit=30, msaa=0), executable=executable)
    app.env['REZVIVO_TEST_HIDDEN'] = '1'
    results = {}
    with GPULock(), app:
        ui = NativeUI(app)
        app.setting('AudioMaster', 0)

        def state():
            return app.call('explore.state')['travel']

        def screenshot(name):
            app.call('app.screenshot', path=str(out/(name+'.png')), inline=False)

        def hold(key, seconds):
            ui.user.SendMessageW(ui.hwnd, 6, 1, 0)  # activate only the hidden test window
            ui.user.SendMessageW(ui.hwnd, 0x0100, key, 1)
            time.sleep(seconds)
            ui.user.SendMessageW(ui.hwnd, 0x0101, key, 1 | (3 << 30))

        def dream(mode):
            app.call('travel.select', mode=mode)
            app.call('dream.inspect', open=True, select=0)
            wait_for(lambda: app.call('dream.inspect'), lambda x: x.get('page', {}).get('ready'), 180)
            app.call('dream.start')
            wait_for(state, lambda x: not x['preparing'], 180)

        app.call('app.switch_view', view='home')
        controls = ui.controls()
        for mode in ('walk', 'bicycle', 'boat', 'car', 'motorcycle', 'flight'):
            button = next(c for c in controls if c['name'] == 'Transport_'+mode)
            assert button.get('enabled', True) == (mode in ('walk', 'bicycle', 'flight')), button
            assert not button.get('caption', ''), button
        screenshot('transport')
        ui.click('Transport_walk')
        app.call('app.switch_view', view='bikefit')
        time.sleep(4)
        screenshot('walk-editor')
        results['editor'] = ui.controls()
        app.call('app.switch_view', view='routes')
        screenshot('start-map')
        assert next(c for c in ui.controls() if c['name'] == 'WorldFollowTrack')['enabled'] is False

        width, height = ui.size()
        px, py = int(width*.64), int(height*.56)
        pos = (int(height-py) << 16) | px
        ui.user.SendMessageW(ui.hwnd, 0x0200, 0, pos)
        ui.user.SendMessageW(ui.hwnd, 0x0201, 1, pos)
        ui.user.SendMessageW(ui.hwnd, 0x0202, 0, pos)
        chosen = app.call('explore.state')['selection']
        assert chosen['point_set'], ('map click did not pick', chosen)
        assert next(c for c in ui.controls() if c['name'] == 'ExploreStart')['enabled']
        end = (int(height-py-30) << 16) | (px+40)
        ui.user.SendMessageW(ui.hwnd, 0x0201, 1, pos)
        ui.user.SendMessageW(ui.hwnd, 0x0200, 1, end)
        ui.user.SendMessageW(ui.hwnd, 0x0202, 0, end)
        assert app.call('explore.state')['selection'] == chosen, 'Dragging incorrectly selected a new start'
        print('Map: click selects, drag preserves start PASS', flush=True)

        dream('walk')
        before = state()
        hold(ord('W'), 3)
        after = state()
        assert after['distance']-before['distance'] > 2, ('native walking input', before, after)
        assert 2.5 < after['speed'] < 4, after
        screenshot('walking')
        results['walking'] = dict(before=before, after=after)
        app.call('explore.input', walk_axis=-1)
        time.sleep(3)
        backward = state()
        assert backward['speed'] < -0.5, ('backwards walking', backward)
        assert backward['distance'] > after['distance'], 'Distance must increase while backing up'
        app.call('explore.input', steer=1, walk_axis=1)
        time.sleep(1)
        turned = state()
        assert (turned['forward_x']-backward['forward_x'])**2+(turned['forward_z']-backward['forward_z'])**2 > .05
        app.call('explore.input', enabled=False)
        time.sleep(2)
        assert abs(state()['speed']) < .05
        print('Walking: keyboard, backwards, turning, stop PASS', flush=True)

        old = state()
        app.call('travel.select', mode='bicycle')
        changed = state()
        assert changed['mode'] == 'bicycle' and changed['free'] and changed['avatar_visible'], changed
        assert abs(changed['distance']-old['distance']) < .1, 'Vehicle switch rebuilt the world'
        app.call('app.switch_view', view='play')
        time.sleep(.4)
        screenshot('live-bicycle')
        app.call('travel.select', mode='walk')
        app.call('app.switch_view', view='bikefit')
        time.sleep(.5)
        screenshot('live-walk-editor')
        app.call('travel.select', mode='flight')
        app.call('app.switch_view', view='play')
        time.sleep(1)  # finish scene/shader setup before timing a 0.2 s key tap
        before = state()
        assert not before['avatar_visible'] and before['mode'] == 'flight', before
        hold(ord('E'), .2)
        after = state()
        assert .2 < after['camera_y'] - before['camera_y'] < 1.2, ('fine initial flight speed', before, after)
        ui.key(ord('C'))
        assert not state()['avatar_visible'], 'Camera switch resurrected hidden avatar'
        screenshot('flight')
        results['flight'] = dict(before=before, after=after)
        print('Flight: live switch, hidden avatar, keyboard PASS', flush=True)

        app.call('explore.start', lat=55.7505, lon=37.6132, mode='bicycle')
        ready = wait_for(state, lambda x: not x['preparing'], 240)
        assert ready['avatar_visible'] and ready['point_start'] and ready['free'], ready
        hold(ord('W'), 1.05)
        time.sleep(2)
        before = state()
        assert 240 < before['keyboard_power'] < 330 and before['distance'] > 2, before
        hold(ord('A'), 1.0)
        turned = state()
        assert (turned['forward_x']-before['forward_x'])**2+(turned['forward_z']-before['forward_z'])**2 > .01
        hold(ord('S'), 1.5)
        time.sleep(3)
        stopped = state()
        assert stopped['keyboard_power'] == 0 and stopped['speed'] < .1, stopped
        screenshot('cycling')
        results['cycling'] = dict(ready=ready, before=before, turn=turned, stopped=stopped)
        print('Cycling: point start, keyboard power, steering, braking PASS', flush=True)

        # A paused FIT must not freeze keyboard cycling or let CGE navigation
        # move the render transform independently of wheel-contact physics.
        fit = out/'power-reference.fit'
        write_sim_fit(fit, seconds=120, watts=200)
        app.setting('SimulationFitPath', str(fit))
        app.setting('SimulationUseRoute', False)
        app.setting('SimulationEnabled', True)
        wait_for(lambda: app.call('sim.info'), lambda x: x['active'], 20, 'simulation connected')
        app.call('sim.pause')
        time.sleep(4)  # also cover stale last telemetry from a paused player
        paused = app.call('path.follow_state', traffic=True, wheels=True)
        hold(ord('W'), 2)
        manual = app.call('path.follow_state', traffic=True, wheels=True)
        assert manual['physics_time_sec'] > paused['physics_time_sec'] + 1.5
        assert manual['distance'] > paused['distance'] + 2
        assert 300 < manual['power'] < 355
        wheel_samples = []
        for _ in range(10):
            time.sleep(.1)
            actor = app.call('path.follow_state', traffic=True, wheels=True)['traffic'][0]
            wheel_samples.append(actor)
            assert math.dist(actor['world_position'], actor['visual_position']) < .18, actor
            assert actor['front_ground_valid'] and actor['rear_ground_valid'], actor
        results['paused_fit_keyboard'] = dict(before=paused, after=manual, wheels=wheel_samples)
        hold(ord('S'), 2)
        time.sleep(3)
        manual_stop = app.call('path.follow_state')
        assert manual_stop['power'] == 0 and manual_stop['speed'] < .1
        app.call('sim.play')
        time.sleep(2)
        resumed = app.call('path.follow_state')
        assert resumed['power'] == 200 and resumed['sim_position_sec'] > manual['sim_position_sec'] + 1
        results['fit_resumed'] = resumed
        app.call('sim.pause')
        # Orbit camera must not re-enable CGE's direct avatar controls.
        app.call('camera.chase', active=False)
        pose = app.call('camera.sample')
        hold(ord('A'), .4)
        still = app.call('camera.sample')
        assert math.dist(pose['avatar_pos'], still['avatar_pos']) < .05
        assert math.dist(pose['avatar_dir'], still['avatar_dir']) < .01
        print('Paused FIT: keyboard physics, wheel probes, braking, FIT resume PASS', flush=True)

        dream('bicycle')
        route = state()
        assert not route['free'] and not route['point_start'] and route['avatar_visible'], route
        screenshot('route-restored')
        results['route_restored'] = route
        wait_for(lambda: app.call('sim.info'), lambda x: x['active'], 20, 'simulation connected')
        app.call('sim.play')
        app.call('ride.start')
        time.sleep(4)
        moving = state()
        assert moving['distance'] > route['distance'] + 2 and moving['speed'] > 1, ('normal ride after travel switching', moving)
        results['route_moving'] = moving
        print('Normal route: sensor simulation drives cycling after mode switches PASS', flush=True)
        app.call('ride.stop_full')
        app.call('app.switch_view', view='routes')
        assert next(c for c in ui.controls() if c['name'] == 'ExploreStart')['enabled'], 'Saved start point lost'
        screenshot('saved-start')
    (out/'results.json').write_text(json.dumps(results, indent=2), encoding='utf-8')
    print('Free exploration integration: PASS', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--exe', default='third_person_navigation.exe')
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    run(Path(__file__).resolve().parents[1], args.out.resolve(), args.exe)

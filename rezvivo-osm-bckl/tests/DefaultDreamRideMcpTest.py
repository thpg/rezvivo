"""Packaged first ride and remembered map choices, using disposable profiles."""
import argparse
import json
import time
from pathlib import Path
from McpHarness import GameSession, GPULock, write_sim_fit
from RideRecoveryFocusMcpTest import NativeUI, wait_for

WORLD = 'krylatskoye-island'


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding='utf-8')


def session(game, out, executable):
    app = GameSession(game, out, graphics={'fps_limit': 30, 'msaa': 0},
                      cache_root=out/'empty-cache', executable=executable)
    app.env.update(REZVIVO_TEST_HIDDEN='1', REZVIVO_TEST_EMPTY_AUTH='1')
    (app.out/'accounts/0/experience.json').unlink()
    return app


def quick_ride(app):
    app.call('app.switch_view', view='home')
    ui = NativeUI(app)
    ui.user.SendMessageW(ui.hwnd, 6, 1, 0)
    ui.click('QuickRide')


def main(game, out, executable):
    assert not out.exists(), 'Choose a new test directory'
    out.mkdir(parents=True)
    app = session(game, out/'пустой профиль', executable)
    result = {'passed': False}
    with GPULock():
        with app:
            app.setting('AudioMaster', 0)
            page = app.call('dream.inspect', open=True)['page']
            assert page['catalog'][page['selected']] == WORLD, page
            assert page['titles'][page['selected']] == 'Krylatskoye Island', page
            app.call('app.switch_view', view='home')
            assert not Path(app.env['REZVIVO_TEST_AUTH_FILE']).exists()
            assert not (app.out/'accounts/0/experience.json').exists()
            fit = out/'steady.fit'
            write_sim_fit(fit, seconds=300, watts=200, cadence=80)
            app.setting('SimulationFitPath', str(fit))
            app.setting('SimulationUseRoute', False)
            app.setting('SimulationEnabled', True)
            began = time.monotonic()
            quick_ride(app)
            world = wait_for(lambda: app.call('dream.inspect'),
                             lambda r: r.get('ride', {}).get('id') == WORLD, 180, 'default island')
            wait_for(lambda: app.call('perf.state'), lambda s: s.get('active') and s.get('prep_done'), 180, 'ride ready')
            result['ready_seconds'] = round(time.monotonic()-began, 2)
            assert not world['osm_streaming']
            app.call('app.screenshot', path=str(out/'first-ride.png'), inline=False)
            app.call('sim.play'); app.call('ride.start')
            moving = wait_for(lambda: app.call('path.follow_state', traffic=True, wheels=True),
                              lambda s: s.get('distance', 0) > 20 and s.get('speed', 0) > 1, 80, 'island movement')
            assert moving['traffic'][0]['front_ground_valid'] and moving['traffic'][0]['rear_ground_valid'], moving
            app.call('app.screenshot', path=str(out/'moving.png'), inline=False)
            preferences = json.loads((app.out/'accounts/0/experience.json').read_text(encoding='utf-8'))
            assert preferences['last_world'] == WORLD and preferences['last_map_kind'] == 'dream'
            settings = json.loads((app.out/'settings.json').read_text(encoding='utf-8'))
            assert settings['graphics']['renderer'] == 0, settings['graphics']
            result.update(world=world, moving=moving, pc_full_renderer=True)
            app.call('sim.pause'); app.call('ride.stop_full')
        assert app.process.returncode == 0

        # Existing modern and legacy Dream choices must override the new default.
        for label, preferences in [('saved-dream', {'last_map_kind': 'dream', 'last_world': 'lighthouse-island'}),
                                   ('legacy-dream', {'last_world': 'lighthouse-island'})]:
            app = session(game, out/label, executable)
            save(app.out/'accounts/0/experience.json', preferences)
            with app:
                app.setting('AudioMaster', 0)
                page = app.call('dream.inspect', open=True)['page']
                assert page['catalog'][page['selected']] == 'lighthouse-island'
                quick_ride(app)
                world = wait_for(lambda: app.call('dream.inspect'),
                                 lambda r: r.get('ride', {}).get('id') == 'lighthouse-island', 180, label)
                app.call('ride.stop_full')
                result[label] = world['ride']['id']
        # Route selection must remain available for modern and older profiles.
        route = game/'data/ready-routes/krylatskoye-small-circuit.gpx'
        for label, preferences in [('saved-real', {'last_map_kind': 'real', 'last_route': str(route)}),
                                   ('legacy-real', {'last_route': str(route)})]:
            app = session(game, out/label, executable)
            save(app.out/'accounts/0/experience.json', preferences)
            with app:
                app.call('app.switch_view', view='routes')
                routes = wait_for(lambda: app.call('menu.inspect')['routes'], lambda r: r['ready_to_ride'], 15, label)
                assert Path(routes['selected']) == route
                result[label] = True
    result.update(passed=True, installed_launch_verified=True, unicode_install_and_profile=True,
                  empty_auth_and_cache=True, offline_bundled_world=True)
    save(out/'result.json', result)
    print('PASS: bundled first ride, ground contact, saved Dream/real choices, clean shutdown', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--game', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--executable', default='REZVIVO.exe')
    args = parser.parse_args()
    main(args.game.resolve(), args.out.resolve(), args.executable)

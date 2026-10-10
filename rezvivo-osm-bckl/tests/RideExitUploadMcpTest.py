"""Normal free-ride exit releases its journal; interrupted exit preserves it.

Uses isolated accounts, generated FIT telemetry and a loopback upload server.
No physical devices or real athlete uploads are involved.
"""
import json
from pathlib import Path
import sys
import time

from McpHarness import GameSession, GPULock, write_sim_fit
from IntervalsUploadMcpTest import API
from RideRoomsMcpTest import account
from RideRecoveryFocusMcpTest import wait_for


def run(out, executable='third_person_navigation.exe', game=None):
    game = Path(game).resolve() if game else Path(__file__).resolve().parents[1]
    out = Path(out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    fit = out/'source.fit'
    write_sim_fit(fit, seconds=120)
    cases = []
    with GPULock():
        for interrupted in (False, True):
            case = out/('interrupted' if interrupted else 'normal')
            app = GameSession(game, case, dict(renderer=1, fps_limit=30, msaa=0,
                              shadow_size=0, grass=0, vegetation_quality=0),
                              executable=executable, api_handler=API)
            app.env['REZVIVO_TEST_HIDDEN'] = '1'
            account(app, 901)
            with app:
                app.setting('AudioMaster', 0)
                app.setting('SimulationFitPath', str(fit))
                app.setting('SimulationUseRoute', False)
                app.setting('SimulationEnabled', True)
                # Enter an existing baked world in free exploration, then use
                # the bicycle. This covers a ride with no FIT route/checkpoint.
                app.call('travel.select', mode='walk')
                app.call('dream.inspect', open=True, select=0)
                wait_for(lambda: app.call('dream.inspect'),
                         lambda x: x.get('page', {}).get('ready'), 150)
                app.call('dream.start')
                wait_for(lambda: app.call('explore.state')['travel'],
                         lambda x: not x['preparing'], 180)
                app.call('travel.select', mode='bicycle')
                app.call('app.switch_view', view='play')
                app.call('sim.play')
                state = wait_for(lambda: app.call('explore.state')['travel'],
                                 lambda x: x['speed'] > 1, 45)
                assert state['free'] and state['simulation_active'], state
                time.sleep(3)
                journals = list((case/'sessions').glob('*.csv'))
                assert len(journals) == 1, journals
                journal = journals[0]
                assert Path(str(journal)+'.active').exists()
                if interrupted:
                    app.kill_for_test()
            marker = Path(str(journal)+'.active')
            assert marker.exists() == interrupted, (interrupted, marker)
            if not interrupted:
                activities = list((case/'accounts/901/activities').glob('*.json'))
                assert len(activities) == 1, activities
                history = json.loads(activities[0].read_text(encoding='utf-8'))
                assert history['complete'] and history['seconds'] > 0, history
                assert Path(history['journal']) == journal, history
                assert history['journal_elapsed'] > 0, history
                # The queue must find a cleanly closed recording on restart.
                app.env['REZVIVO_TEST_NO_UPLOAD'] = '0'
                with app:
                    name = journal.with_suffix('.fit').name
                    wait_for(lambda: API.uploads.get(name), bool, 20,
                             'completed free ride upload after restart')
                    wait_for(lambda: journal.exists(), lambda x: not x, 10,
                             'acknowledged CSV retirement')
                    assert not API.uploads[name][0]['meta']['upload_intervals']
            cases.append(dict(interrupted=interrupted, passed=True))
            print('PASS', 'interrupted journal retained' if interrupted else
                  'normal free ride linked, released and uploaded on restart', flush=True)
    (out/'result.json').write_text(json.dumps(cases, indent=2), encoding='utf-8')


if __name__ == '__main__':
    run(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else 'third_person_navigation.exe')

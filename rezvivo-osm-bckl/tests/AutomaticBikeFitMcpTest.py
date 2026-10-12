"""Exercise the actual fit button, persistence and the shared live-ride bike."""
from pathlib import Path
import argparse
import ctypes
from ctypes import wintypes
import json
import time
from McpHarness import GameSession, GPULock, write_sim_fit
from RideRecoveryFocusMcpTest import NativeUI, wait_for, assert_layout

GAME = Path(__file__).resolve().parents[1]
KEYS = ('bike_path', 'bike_size', 'seat_mm', 'offset_mm', 'stem_mm', 'spacers_mm')


def ready(app):
    return wait_for(lambda: app.call('bikefit.status'),
                    lambda s: s.get('rider_loaded') and not s.get('preview_loading'),
                    90, 'rider preview')


def fitted(app):
    return wait_for(lambda: app.call('bikefit.status'),
                    lambda s: not s['auto_fit_pending'] and s['auto_fit_status'] in (1, 2),
                    30, 'automatic fit saved')


def same_fit(a, b):
    for key in KEYS:
        if isinstance(a[key], (int, float)):
            assert abs(a[key]-b[key]) < .5, (key, a[key], b[key])
        else:
            assert a[key] == b[key], (key, a[key], b[key])


def resize(ui, width, height):
    rect = wintypes.RECT()
    ui.user.GetWindowRect(ctypes.c_void_p(ui.hwnd), ctypes.byref(rect))
    cw, ch = ui.size()
    ui.user.SetWindowPos.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
        ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_uint]
    assert ui.user.SetWindowPos(ui.hwnd, None, 0, 0,
        width+rect.right-rect.left-cw, height+rect.bottom-rect.top-ch, 0x0016)
    time.sleep(.3)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path,
        default=GAME/'tests/artifacts/bike-autofit-20261006/ui')
    args = parser.parse_args()
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=True)
    report = {}

    def save():
        (out/'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')

    session = GameSession(GAME, out/'profile', dict(fps_limit=60, msaa=0),
        executable='castle-engine-output/performance-release/third_person_navigation.exe')
    with GPULock():
        with session as app:
            app.setting('AudioMaster', 0)
            before = ready(app); ui = NativeUI(app)
            ui.click('BikeFitAutoFit'); first = fitted(app)
            assert first['body'] == before['body'], 'automatic fit changed the avatar'
            assert first['bike_path'] == before['bike_path'], 'automatic fit changed bike model'
            ui.click('BikeFitAutoFit'); again = fitted(app); same_fit(first, again)
            report['first'] = first
            for width, height in ((1440, 900), (1000, 700)):
                resize(ui, width, height); cs = ui.controls()
                assert_layout(cs, ['BikeFitAutoFit']+['FitValue'+str(i) for i in range(4)], ui.size())
                report['layout_'+str(width)] = cs; save()
                app.call('app.screenshot', path=str(out/f'fit-{width}.png'), inline=False)
            for height, weight, sex in ((150, 44, 1), (202, 87, 0)):
                app.call('bikefit.body', heightCm=height, weightKg=weight, sex=sex,
                         inseamCm=0, armLengthCm=0)
                ready(app); ui.click('BikeFitAutoFit'); s = fitted(app)
                assert abs(s['body']['heightCm']-height) < .01, s['body']
                report['body_'+str(height)] = s; save()
            assert report['body_150']['bike_size'] != report['body_202']['bike_size']
            # Manual adjustment must remain usable after fitting and survive restart.
            app.call('bikefit.nudge', param='seat', steps=1)
            saved = ready(app); assert saved['auto_fit_status'] == 0
            assert saved['seat_mm'] > s['seat_mm']
            time.sleep(2)
            report['manual_saved'] = saved; save()

        settings_path = session.out/'settings.json'
        settings = json.loads(settings_path.read_text(encoding='utf-8-sig'))
        settings['ui']['language'] = 'ru'
        settings_path.write_text(json.dumps(settings), encoding='utf-8')
        with session as app:
            after = ready(app); same_fit(saved, after)
            ui = NativeUI(app); resize(ui, 1280, 800)
            assert next(c['caption'] for c in ui.controls() if c['name'] == 'BikeFitAutoFit') == 'Сделать байкфит'
            ui.click('BikeFitAutoFit'); fitted(app)
            app.call('app.screenshot', path=str(out/'fit-ru.png'), inline=False)
            fit = out/'simulation.fit'; write_sim_fit(fit, 300, 210)
            app.setting('SimulationFitPath', str(fit)); app.setting('SimulationUseRoute', False)
            app.setting('SimulationEnabled', True)
            app.call('dream.inspect', open=True, select=0)
            wait_for(lambda: app.call('dream.inspect'), lambda s: s['page']['ready'], 120, 'dream world')
            app.call('dream.start')
            wait_for(lambda: app.call('bots.local'), lambda s: s.get('ready'), 180, 'live bike')
            app.call('ride.start'); app.call('sim.play'); time.sleep(2); app.call('sim.pause')
            live_before = ready(app)
            assert live_before['live_ride'] and live_before['same_bike'] and live_before['same_world']
            ui.click('BikeFitAutoFit'); live = fitted(app)
            assert live['same_bike'] and live['same_world'] and live['gpu_animation']
            same_fit(live_before, live)
            report['live'] = live; save()
            app.call('app.screenshot', path=str(out/'fit-live.png'), inline=False)
    print('AUTOMATIC_BIKE_FIT_UI_OK', flush=True)


if __name__ == '__main__':
    main()

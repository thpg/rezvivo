"""Default-on setting, persistence and unobstructed HUD in the actual PC UI."""
import argparse
import json
import time
from pathlib import Path
from McpHarness import GameSession, GPULock
from RideRecoveryFocusMcpTest import NativeUI, wait_for, assert_layout
from AutomaticBikeFitMcpTest import resize

GAME = Path(__file__).resolve().parents[1]
OUT = GAME / 'tests/artifacts/zwift-shifting-implementation-20261024/ui'


def main(executable='third_person_navigation.exe'):
    OUT.mkdir(parents=True, exist_ok=True)
    report = {}
    app = GameSession(GAME, OUT/'profile', executable=executable,
                      graphics={'fps_limit': 30, 'msaa': 0})
    app.env.update(REZVIVO_TEST_HIDDEN='1', REZVIVO_READY_TILES='0')
    with GPULock(), app:
        app.setting('AudioMaster', 0)
        ui = NativeUI(app)
        resize(ui, 1600, 900)
        app.call('app.switch_view', view='devices')
        wait_for(ui.controls, lambda cs: any(c['name'] == 'VirtualGearingEnabled' for c in cs))
        data = app.call('property_get', object='settings', path='VirtualGearingEnabled')
        report['default'] = data
        assert data is True, data
        for expected in (False, True):
            ui.click('VirtualGearingEnabled')
            data = json.loads((app.out/'settings.json').read_text(encoding='utf-8-sig'))
            assert data['virtual_gearing_enabled'] is expected
        app.setting('Language', 'ru')
        time.sleep(.6)
        app.call('app.screenshot', path=str(OUT/'devices-ru.png'), inline=False)
        report['devices'] = ui.controls()
        assert_layout(report['devices'], ['VirtualGearingEnabled'], ui.size())
        app.call('dream.inspect', open=True, select=0)
        wait_for(lambda: app.call('dream.inspect'), lambda r: r.get('page', {}).get('ready'),
                 120, 'dream ready')
        app.call('dream.start')
        wait_for(lambda: app.call('bots.local'), lambda r: r.get('ready'), 240, 'ride ready')
        names = ('LabelSpeed','LabelWork','LabelWorkTSS','LabelSlope',
                 'LabelTransmission','GearDown','GearUp')
        for width, height in ((1600,900), (960,720)):
            resize(ui, width, height)
            time.sleep(.8)
            controls = ui.controls()
            assert_layout(controls, names, ui.size())
            transmission = next(c for c in controls if c['name'] == 'LabelTransmission')
            report[str(width)] = controls
            report['transmission'] = transmission
            app.call('app.screenshot', path=str(OUT/f'ride-{width}.png'), inline=False)
        (OUT/'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print('PASS: default, saved toggle, Russian UI and two HUD widths')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--game', type=Path, default=GAME)
    parser.add_argument('--out', type=Path, default=OUT)
    parser.add_argument('--executable', default='third_person_navigation.exe')
    args = parser.parse_args()
    GAME, OUT = args.game.resolve(), args.out.resolve()
    main(args.executable)

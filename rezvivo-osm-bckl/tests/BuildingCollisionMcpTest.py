"""Repeatable unlimited-FPS city baseline for building contact changes."""
import argparse
import json
from pathlib import Path
import time
from McpHarness import GameSession, GPULock

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--executable', default='third_person_navigation.exe')
    parser.add_argument('--drive', action='store_true', help='Ride towards the building after timing')
    args = parser.parse_args()
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=True)
    cache = ROOT/'tests/artifacts/feedback-333/zurich/cache'
    session = GameSession(ROOT, out/'profile', {'fps_limit':0, 'msaa':0},
                          cache_root=cache, executable=args.executable)
    session.env['REZVIVO_TEST_HIDDEN'] = '1'
    result = {'executable':args.executable, 'windows':[]}
    with GPULock(), session as app:
        app.setting('AudioMaster', 0)
        app.call('app.fps_mode', mode='max')
        app.call('explore.start', lat=47.3740667, lon=8.5403374, mode='bicycle')
        end = time.monotonic() + 240
        while True:
            state = app.call('explore.state')['travel']
            if not state['preparing'] and not state['loading']['pending']:
                break
            assert time.monotonic() < end, state
            time.sleep(2)
        time.sleep(10)
        result['start'] = state
        for i in range(3):
            app.call('perf.capture', action='start')
            time.sleep(8)
            data = app.call('perf.capture', action='stop')
            result['windows'].append(data)
            (out/'report.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
            print(json.dumps({'window':i, 'capture':data}), flush=True)
        app.call('app.screenshot', path=str(out/'city.png'), inline=False)
        if args.drive:
            result['drive'] = []
            app.call('explore.input', power_axis=1)
            for i in range(20):
                time.sleep(1)
                result['drive'].append(app.call('explore.state')['travel'])
            app.call('explore.input', power_axis=0)
            app.call('app.screenshot', path=str(out/'contact.png'), inline=False)
            (out/'report.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
        app.call('ride.stop_full')
    print('BUILDING_CITY_PERF_OK', flush=True)

if __name__ == '__main__':
    main()

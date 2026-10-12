"""Public ready tiles through the real game; isolated cache, then offline restart."""
import argparse
import json
import time
from pathlib import Path
from McpHarness import GameSession, GPULock


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--game', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--exe', default='third_person_navigation.exe')
    parser.add_argument('--timeout', type=float, default=180)
    parser.add_argument('--offline-only', action='store_true', help='Use prepared cache/o3dt and cache/atlas only')
    args = parser.parse_args()
    args.out = args.out.resolve()
    args.out.mkdir(parents=True, exist_ok=True)
    cache = args.out / 'cache'
    report = {}

    def save():
        (args.out / 'result.json').write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding='utf-8')

    with GPULock():
        for offline in ((True,) if args.offline_only else (False, True)):
            name = 'offline' if offline else 'download'
            app = GameSession(args.game, args.out / name, {'fps_limit': 30, 'msaa': 0},
                              cache_root=cache, executable=args.exe)
            app.env['REZVIVO_TEST_HIDDEN'] = '1'
            app.env['REZVIVO_OFFLINE'] = '1' if offline else '0'
            app.env['REZVIVO_READY_TILES_URL'] = 'https://rezvivo.com/api/ready-tiles/v1'
            stage = report[name] = {'samples': []}
            with app:
                app.setting('AudioMaster', 0)
                started = time.monotonic()
                app.call('explore.start', lat=55.7674477, lon=37.4275646, mode='walk')
                while True:
                    state = app.call('explore.state')['travel']
                    stage['samples'].append({'seconds': round(time.monotonic() - started, 2), 'state': state})
                    save()
                    if 'x' in state and not state.get('preparing'):
                        break
                    if time.monotonic() - started > args.timeout:
                        raise AssertionError(('point warmup did not finish', name, state))
                    time.sleep(1)
                stage['startup_seconds'] = round(time.monotonic() - started, 2)
                stage['ready_files'] = [str(p.relative_to(cache)) for p in cache.rglob('*.ready')]
                assert stage['ready_files'], ('server geometry was not installed', name)
                app.call('app.screenshot', path=str(args.out / (name + '.png')), inline=False)
                app.call('explore.input', walk_axis=1)
                time.sleep(3)
                stage['moving'] = app.call('explore.state')['travel']
                assert stage['moving']['distance'] > state['distance'] + 1, stage
                save()
                print(name + ': ready, moving; %.2fs' % stage['startup_seconds'], flush=True)
    report['pass'] = True
    save()


if __name__ == '__main__':
    main()

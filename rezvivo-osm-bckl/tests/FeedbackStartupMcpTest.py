"""Clean-profile startup checks for geographic exploration and Dream cycling."""
import argparse
import ctypes
import json
from pathlib import Path
import time
from McpHarness import GameSession, GPULock

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--lat', type=float, default=52.517)
    parser.add_argument('--lon', type=float, default=13.388)
    parser.add_argument('--dream', action='store_true')
    parser.add_argument('--load-timeout', type=float, default=300,
                        help='Seconds allowed for cold external OSM downloads and generation')
    parser.add_argument('--network-diagnostic', action='store_true')
    parser.add_argument('--check-menu', action='store_true',
                        help='Press Esc in the hidden window while the start tile loads')
    parser.add_argument('--swiss-server', action='store_true',
                        help='Use the public Swiss service, only within its coverage')
    parser.add_argument('--executable', default='third_person_navigation.exe')
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    report = []
    session = GameSession(ROOT, out/'profile', {'fps_limit':30, 'msaa':0},
                          cache_root=out/'cache', executable=args.executable)
    session.env['REZVIVO_TEST_HIDDEN'] = '1'
    if args.swiss_server:
        assert 45.8 < args.lat < 47.8 and 5.9 < args.lon < 10.5
        cache = out/'cache'
        cache.mkdir(exist_ok=True)
        (cache/'osm-servers.json').write_text(json.dumps({
            'version':1,'ttl_seconds':3600,'servers':[{
                'url':'https://overpass.osm.ch/api/interpreter', 'kind':'public',
                'region':'bbox','bbox':'45.8,5.9,47.8,10.5',
                'limits':{'min_interval_ms':2000,'max_concurrent':1}}]}))
    def record(value):
        report.append(value)
        (out/'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
        print(json.dumps(value), flush=True)
    with GPULock(), session as app:
        app.setting('AudioMaster', 0)
        if args.dream:
            app.call('dream.inspect', open=True, select=0)
            until = time.monotonic()+180
            while not app.call('dream.inspect').get('page', {}).get('ready'):
                if time.monotonic()>until:
                    raise AssertionError('Dream preview timed out')
                time.sleep(.5)
            app.call('dream.start')
        else:
            app.call('explore.start', lat=args.lat, lon=args.lon, mode='bicycle')
        started = time.monotonic()
        saw_start_map = False
        while True:
            state = app.call('explore.state')['travel']
            record(dict(elapsed=round(time.monotonic()-started,1), travel=state))
            if not args.dream and state.get('preparing') and 'x' in state:
                loading = state['loading']
                assert loading['flat_map_visible'], state
                assert loading['warmup_tiles'] == 1, state
                if not saw_start_map:
                    app.call('app.screenshot', path=str(out/'waiting.png'), inline=False)
                    saw_start_map = True
                    if args.check_menu:
                        windows = []
                        user32 = ctypes.windll.user32
                        callback = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p,
                                                     ctypes.c_void_p)
                        def collect(hwnd, _):
                            pid = ctypes.c_ulong()
                            user32.GetWindowThreadProcessId(ctypes.c_void_p(hwnd),
                                                           ctypes.byref(pid))
                            title = ctypes.create_unicode_buffer(256)
                            user32.GetWindowTextW(ctypes.c_void_p(hwnd), title, 256)
                            if pid.value == app.process.pid and 'REZVIVO' in title.value:
                                windows.append(hwnd)
                            return True
                        user32.EnumWindows(callback(collect), 0)
                        assert len(windows) == 1, windows
                        hwnd = ctypes.c_void_p(windows[0])
                        user32.PostMessageW(hwnd, 0x100, 0x1B, 0x00010001)
                        user32.PostMessageW(hwnd, 0x101, 0x1B, 0xC0010001)
                        until = time.monotonic() + 5
                        while True:
                            views = app.call('app.views_list')
                            if views.get('menu_overlay') or time.monotonic() > until:
                                break
                            time.sleep(.1)
                        assert views['menu_overlay'] and views['ride_alive'], views
                        app.call('app.switch_view', view='play')
                        record(dict(escape_menu_and_resume=True))
            if args.network_diagnostic and state.get('loading_error'):
                break
            if ('x' in state and not state['preparing']) or time.monotonic()-started>args.load_timeout:
                break
            time.sleep(5)
        app.call('app.screenshot', path=str(out/'start.png'), inline=False)
        if args.network_diagnostic and state.get('loading_error'):
            controls = app.call('ui.inspect', labels=True)['controls']
            hint = next(c for c in controls if c['name']=='ExploreControls')
            assert 'Retrying automatically' in hint['caption'], hint
            record(dict(visible_error=hint['caption']))
            app.call('ride.stop_full')
            print('PUBLIC_OSM_FAILURE_REPORTED', flush=True)
            return
        assert 'x' in state and not state['preparing'], state
        if not args.dream:
            assert state['loading']['scene_ready'], state
            assert not state['loading']['flat_map_visible'], state
        app.call('explore.input', power_axis=1)
        time.sleep(3)
        state = app.call('explore.state')['travel']
        record(dict(moving=state))
        assert state['speed']>0.5, state
        app.call('explore.input', power_axis=0)
        app.call('app.screenshot', path=str(out/'moving.png'), inline=False)
        app.call('ride.stop_full')
    assert not list((out/'profile/sessions').glob('*.fit')), 'keyboard ride exported a FIT'
    for p in (out/'profile/accounts').rglob('activities/*.json'):
        a = json.loads(p.read_text(encoding='utf-8'))
        assert a.get('seconds',0)==0 and a.get('distance_m',0)==0, a
    print('FEEDBACK_STARTUP_OK', flush=True)

if __name__ == '__main__':
    main()

"""First ride from a packaged client, empty profile, no authorization or map cache.

Uses the real Home button and public production map/route APIs. Optional recovery
temporarily removes just the bundled GPX from the disposable package, proving the
download is followed by the originally requested start. Never uses a user profile.
"""
import argparse
from contextlib import contextmanager
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import threading
import time
import xml.etree.ElementTree as ET
from urllib.parse import urlsplit, parse_qs

from McpHarness import GameSession, GPULock, write_sim_fit
from RideRecoveryFocusMcpTest import NativeUI, wait_for

ROUTE_ID = 'krylatskoye-small-circuit'


def save(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')


def session(game, out, cache, **kwargs):
    app = GameSession(game, out, graphics={'fps_limit': 30, 'msaa': 0},
                      cache_root=cache, executable='REZVIVO.exe', **kwargs)
    app.env.update(REZVIVO_TEST_HIDDEN='1', REZVIVO_TEST_EMPTY_AUTH='1')
    # GameSession supplies a benchmark rider. This test requires a truly empty user.
    (app.out/'accounts/0/experience.json').unlink()
    return app


def quick_ride(app):
    ui = NativeUI(app)
    ui.user.SendMessageW(ui.hwnd, 6, 1, 0)
    ui.click('QuickRide')


def stop(app):
    app.call('ride.stop_full')
    app.call('app.switch_view', view='home')
    app.call('app.views_list')


@contextmanager
def ready_map_server(directory):
    """Validate a concrete owner tile publication locally before deploying it."""
    if directory is None:
        yield
        return
    catalog = json.loads((directory/'catalog.json').read_text(encoding='utf-8'))
    objects = {t['sha256']+'.o3dt' for t in catalog['tiles']}
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            path = urlsplit(self.path)
            requests.append(path.path)
            if path.path == '/catalog':
                q = parse_qs(path.query)
                gen, zoom, edge = q['generator'][0], int(q['zoom'][0]), int(q['edge_px'][0])
                data = json.dumps(dict(version=1, format='O3DTBIN1', generator=gen,
                    zoom=zoom, edge_px=edge, tiles=[t for t in catalog['tiles']
                        if t['generator'] == gen and t['zoom'] == zoom and t['edge_px'] == edge])).encode()
            elif path.path.startswith('/objects/') and path.path[9:] in objects:
                data = (directory/path.path[1:]).read_bytes()
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    key = 'REZVIVO_READY_TILES_URL'
    old = os.environ.get(key)
    os.environ[key] = 'http://127.0.0.1:'+str(server.server_port)
    try:
        yield
    finally:
        server.shutdown()
        server.server_close()
        if old is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = old
        save(directory/'test-requests.json', requests)


@contextmanager
def missing_gpx(game):
    # Deliberately incomplete disposable package. Restore even if a test fails.
    assert (game/'installed-files.json').is_file(), 'requires an installer payload'
    assert game != Path(__file__).resolve().parents[1], 'never edit development data'
    file = game/'data/ready-routes'/f'{ROUTE_ID}.gpx'
    raw = file.read_bytes()
    file.unlink()
    try:
        yield
    finally:
        file.write_bytes(raw)


def public_first_ride(game, out, cache, expect_download=False):
    out.mkdir(parents=True, exist_ok=True)
    app = session(game, out/'пустой профиль', cache, native_api=True)
    result = {'passed': False, 'recovered_missing_gpx': expect_download,
              'tile_service': app.env.get('REZVIVO_READY_TILES_URL', 'production')}
    began = time.monotonic()
    with app:
        app.setting('AudioMaster', 0)
        assert not Path(app.env['REZVIVO_TEST_AUTH_FILE']).exists()
        assert not (app.out/'accounts/0/experience.json').exists()
        # A power source is connected before the user starts their first ride,
        # just as with a trainer. Keep the map choice and account completely empty.
        fit = out/'test-power.fit'
        write_sim_fit(fit, seconds=900, watts=190, cadence=80)
        app.setting('SimulationFitPath', str(fit))
        app.setting('SimulationUseRoute', False)
        app.setting('SimulationEnabled', True)
        quick_ride(app)
        wait_for(lambda: app.call('app.views_list'),
                 lambda x: x.get('active') == 'play', 120, 'default route starts')
        prefs = json.loads((app.out/'accounts/0/experience.json').read_text(encoding='utf-8'))
        save(out/'selected.json', prefs)
        selected_path = Path(prefs['last_route'])
        meta = json.loads(Path(str(selected_path)+'.json').read_text(encoding='utf-8'))
        assert meta['id'] == ROUTE_ID, meta
        assert hashlib.sha256(selected_path.read_bytes()).hexdigest() == meta['sha256']
        assert len(ET.parse(selected_path).findall('.//{*}trkpt')) > 800
        print('Krylatskoye selected; preparing empty map cache', flush=True)
        last_log = 0

        def preparation():
            nonlocal last_log
            state = app.call('perf.state')
            if time.monotonic()-last_log > 20:
                print('Preparing:', round(time.monotonic()-began, 1),
                      state.get('active'), state.get('prep_done'), flush=True)
                last_log = time.monotonic()
                save(out/'preparing.json', state)
                if state.get('active') and time.monotonic()-began > 60:
                    app.call('app.screenshot', path=str(out/'preparing.png'), inline=False)
            return state

        ready = wait_for(preparation, lambda x: x.get('active') and x.get('prep_done'),
                         600, 'download/generate default route ground')
        result['ready_seconds'] = round(time.monotonic()-began, 2)
        assert app.call('dream.inspect')['osm_streaming'], 'Dream World started instead'
        app.call('app.screenshot', path=str(out/'start.png'), inline=False)
        save(out/'ready.json', ready)
        app.call('sim.play')
        app.call('ride.start')
        def movement():
            state = app.call('path.follow_state', traffic=True, wheels=True)
            save(out/'movement-latest.json', state)
            return state

        moving = wait_for(movement,
                          lambda x: x.get('distance', 0) > 50 and x.get('speed', 0) > 1,
                          80, 'rider moves on default route')
        assert moving['traffic'][0]['front_ground_valid'], moving
        assert moving['traffic'][0]['rear_ground_valid'], moving
        assert not app.call('explore.state')['travel']['preparing']
        app.call('app.screenshot', path=str(out/'moving.png'), inline=False)
        prefs = json.loads((app.out/'accounts/0/experience.json').read_text(encoding='utf-8'))
        assert prefs['last_map_kind'] == 'real'
        assert Path(prefs['last_route']) == selected_path
        assert not Path(app.env['REZVIVO_TEST_AUTH_FILE']).exists()
        assert not list((app.out/'accounts/0/routes').glob('*.gpx')), 'copied public GPX into private routes'
        assert any((cache/'o3dt').rglob('*.o3dt')), 'no generated tile'
        catalogue = json.loads((app.out/'accounts/ready-routes/catalog.json').read_text(encoding='utf-8'))
        result.update(passed=True, route=meta, moving=moving, catalogue=catalogue)
        if expect_download:
            assert result['catalogue']['revision'], 'missing GPX was not synchronized'
        stop(app)
    save(out/'result.json', result)
    print('PASS: public first ride', out.name, result['ready_seconds'], flush=True)


def regressions(game, out, cache):
    out.mkdir(parents=True, exist_ok=True)
    cat = json.loads((game/'data/ready-routes/catalog.json').read_text(encoding='utf-8'))
    raw = (game/'data/ready-routes'/f'{ROUTE_ID}.gpx').read_bytes()
    cat['revision'] = hashlib.sha256(b'default-ready-route-pending').hexdigest()
    release = threading.Event()
    requests = []

    class API(BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append(self.path)
            if self.path == '/api/v1/ready-routes':
                release.wait(8)
                data = json.dumps(cat).encode()
            elif '/ready-routes/' in self.path and '/file' in self.path:
                data = raw
            else:
                data = b'{"allowed":true,"update_available":false}'
            self.send_response(200)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *args):
            pass

    with missing_gpx(game):
        app = session(game, out/'cancel-download', cache, api_handler=API)
        with app:
            quick_ride(app)
            pending = app.call('menu.inspect')['routes']
            assert pending['pending_ready_route'] == 'ready-route:'+ROUTE_ID, pending
            assert not pending['ready_to_ride'], pending
            app.call('app.switch_view', view='home')
            release.set()
            wait_for(lambda: app.call('menu.inspect')['routes']['ready_routes'],
                     lambda r: not r['busy'], 20, 'cancelled launch finishes download')
            time.sleep(1)
            assert app.call('app.views_list')['active'] != 'play', 'cancelled start resumed'
            state = app.call('menu.inspect')['routes']
            assert state['pending_ready_route'] == '', state
            app.call('app.switch_view', view='routes')
            wait_for(lambda: app.call('menu.inspect')['routes'],
                     lambda r: r['ready_to_ride'], 10)
            assert app.call('app.views_list')['active'] != 'play'
            save(out/'cancelled.json', state)
        assert sum('/file' in path for path in requests) == 1, requests

    # Existing Dream World and real-route preferences must win over the new default.
    other = out/'previous-route.gpx'
    other.write_bytes(raw)
    for label, prefs in [('dream', {'last_map_kind': 'dream', 'last_world': 'castle-island'}),
                         ('real', {'last_map_kind': 'real', 'last_route': str(other)}),
                         ('legacy-real', {'last_route': str(other)})]:
        app = session(game, out/label, cache, api_handler=API)
        save(app.out/'accounts/0/experience.json', prefs)
        with app:
            app.call('app.switch_view', view='routes')
            if label == 'dream':
                assert app.call('menu.inspect')['routes']['selected'] == ''
                app.call('app.switch_view', view='home')
                quick_ride(app)
                world = wait_for(lambda: app.call('dream.inspect'),
                                 lambda r: r.get('ride', {}).get('id') == 'castle-island', 90)
                save(out/'preserved-dream.json', world)
                stop(app)
            else:
                selected = wait_for(lambda: app.call('menu.inspect')['routes'],
                                    lambda r: r['ready_to_ride'], 10)
                assert Path(selected['selected']) == other, selected
    save(out/'result.json', {'passed': True, 'requests': requests,
                            'checks': ['delayed download', 'cancel pending start',
                                       'saved Dream World', 'saved real route', 'legacy real route']})
    print('PASS: cancellation and saved choices', flush=True)


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--game', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--case', choices=['fresh', 'recovery', 'regressions', 'all'], default='all')
    p.add_argument('--ready-map', type=Path, help='serve prepared owner geometry locally before publication')
    a = p.parse_args()
    game, out = a.game.resolve(), a.out.resolve()
    cache = out/'empty-cache'
    with GPULock(), ready_map_server(a.ready_map.resolve() if a.ready_map else None):
        if a.case in ('fresh', 'all'):
            assert not cache.exists(), 'fresh-install test must not reuse map cache'
            public_first_ride(game, out/'fresh', cache)
        if a.case in ('recovery', 'all'):
            with missing_gpx(game):
                public_first_ride(game, out/'download-recovery', cache, expect_download=True)
        if a.case in ('regressions', 'all'):
            regressions(game, out/'regressions', cache)

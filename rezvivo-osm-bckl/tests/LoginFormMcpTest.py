"""Exercise the real login UI in a hidden game with disposable accounts.

All authentication requests go to a loopback fixture. Window messages follow
the same click path as a user; screenshots and shader sources stay in --out.
"""
import argparse
import ctypes
from http.server import BaseHTTPRequestHandler
import json
from pathlib import Path
import time

from McpHarness import GameSession, GPULock
from RideRecoveryFocusMcpTest import NativeUI, assert_layout, wait_for

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--game', type=Path, default=ROOT,
                        help='Game directory, including an extracted installer')
    parser.add_argument('--executable', default='third_person_navigation.exe')
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    requests = []
    checks = []

    class API(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            self.reply(200, {'current_build': release['build'], 'allowed': True,
                             'update_available': False})

        def do_POST(self):
            # Consume without recording even the fixture's password.
            self.rfile.read(int(self.headers.get('Content-Length', 0)))
            requests.append(self.path)
            self.reply(401, {'error': 'Login regression fixture: invalid credentials'})

        def reply(self, status, body):
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    game = args.game.resolve()
    release = json.loads((game/'release.json').read_text(encoding='utf-8'))
    session = GameSession(game, out/'profile', {'fps_limit': 30, 'msaa': 0},
                          api_handler=API, executable=args.executable)
    session.env['REZVIVO_TEST_HIDDEN'] = '1'
    session.env['REZVIVO_SHADER_DUMP'] = str(out/'shaders')
    session.env['REZVIVO_TEST_SHADER_CACHE_DIR'] = str(out/'shader-cache')

    def record(name):
        checks.append(name)
        (out/'result.json').write_text(json.dumps(
            {'checks': checks, 'auth_requests': requests}, indent=2), encoding='utf-8')
        print(name, flush=True)

    with GPULock(), session as app:
        app.setting('AudioMaster', 0)
        app.call('app.switch_view', view='login')
        ui = NativeUI(app)
        ui.user.SetWindowPos.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
                                         ctypes.c_int, ctypes.c_int, ctypes.c_int,
                                         ctypes.c_int, ctypes.c_uint]
        ui.user.SetWindowPos.restype = ctypes.c_bool

        def form(password):
            names = ['LoginTabDevice', 'LoginTabPassword'] + (
                ['LoginEmail', 'LoginPassword', 'LoginSubmit'] if password
                else ['LoginContinueBrowser'])
            controls = wait_for(ui.controls, lambda cs: all(
                sum(c['name'] == name for c in cs) == 1 for name in names),
                description='complete login form')
            absent = 'LoginContinueBrowser' if password else 'LoginEmail'
            assert not any(c['name'] == absent for c in controls), controls
            assert_layout(controls, names, ui.size())
            assert app.process.poll() is None
            return controls

        form(False)
        ui.click('LoginTabPassword')
        form(True)
        record('first native password-tab click succeeds')
        ui.click('LoginSubmit')
        wait_for(ui.controls, lambda cs: any(
            c['caption'] == 'Fill in email and password' for c in cs))
        assert not requests, requests
        app.call('app.screenshot', path=str(out/'password-validation.png'), inline=False)
        record('empty submission stays on the form without HTTP')

        # Type disposable values through the native input path, never MCP.
        for name, value in [('LoginEmail', 'fixture@example.invalid'),
                            ('LoginPassword', 'fixture-only')]:
            ui.click(name)
            for char in value:
                ui.user.SendMessageW(ui.hwnd, 0x0102, ord(char), 1)
        ui.click('LoginSubmit')
        wait_for(ui.controls, lambda cs: any(
            c['name'] == 'LabelStatus' and 'Sign in failed' in c['caption'] for c in cs))
        assert requests == ['/api/v1/auth/login'], requests
        form(True)
        record('asynchronous rejected login updates a live form')

        # Rebuild repeatedly, including a click on the already selected tab.
        for cycle in range(12):
            ui.click('LoginTabDevice')
            form(False)
            ui.click('LoginTabDevice')
            form(False)
            ui.click('LoginTabPassword')
            form(True)
        record('12 bidirectional tab cycles without stale or duplicate controls')

        for width, height in [(1280, 800), (800, 900), (960, 600)]:
            assert ui.user.SetWindowPos(ui.hwnd, None, 0, 0, width, height, 0x0016)
            time.sleep(.2)
            form(True)
            ui.click('LoginTabDevice')
            form(False)
            ui.click('LoginTabPassword')
            form(True)
            app.call('app.screenshot', path=str(out/f'password-{width}x{height}.png'),
                     inline=False)
            record(f'both forms fit after resizing to {width}x{height}')

        for mode in ['LoginTabPassword', 'LoginTabDevice', 'LoginTabPassword']:
            ui.click(mode)
            form(mode == 'LoginTabPassword')
            ui.click('ButtonBack')
            wait_for(lambda: app.call('app.views_list'), lambda s: s['active'] != 'login')
            app.call('app.switch_view', view='login')
            form(mode == 'LoginTabPassword')
        record('close and reopen from both modes, including password first')
        ui.click('ButtonBack')
        app.call('app.switch_view', view='bikefit')
        # Drawing the actual editor compiles the skin shader used by the game.
        app.call('app.screenshot', path=str(out/'rider-skin.png'), inline=False)
        wait_for(lambda: list((out/'shaders').glob('*.glsl')), lambda ps: any(
            'limbDetailFade' in p.read_text(encoding='utf-8-sig') for p in ps),
            seconds=60, description='actual generated skin shader')
        record('game renders rider and dumps the corrected skin shader')

    assert not list((out/'profile/sessions').rglob('*.running.json'))
    record('clean process shutdown')
    print('LOGIN_FORM_OK', flush=True)


if __name__ == '__main__':
    main()

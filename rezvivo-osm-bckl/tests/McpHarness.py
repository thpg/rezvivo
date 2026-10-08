"""Disposable game profile and a synchronous stdio MCP client for integration tests."""
import ctypes
import json
import os
from pathlib import Path
import queue
import struct
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def write_sim_fit(path, seconds=7200, watts=190):
    fields = [(253, 4, 0x86), (5, 4, 0x86), (6, 2, 0x84), (7, 2, 0x84),
              (3, 1, 2), (4, 1, 2), (0, 4, 0x85), (1, 4, 0x85), (2, 2, 0x84)]
    body = bytearray([0x40, 0, 0, 20, 0, len(fields)])
    for field in fields:
        body.extend(field)
    for i in range(seconds):
        body.extend(bytes([0]) + struct.pack('<IIHHBBiiH', 1100000000+i,
                    i*800, 8000, watts, 125, 85, round(55.75*2**31/180),
                    round((37.62+i*.00001)*2**31/180), 3200))
    data = struct.pack('<BBHI4s', 12, 0x20, 2100, len(body), b'.FIT') + body
    crc = 0
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ (0xA001 if crc & 1 else 0)
    path.write_bytes(data + struct.pack('<H', crc))


class GameSession:
    def __init__(self, game, out=None, graphics=None, cache_root=None, api_handler=None,
                 executable='third_person_navigation.exe', native_api=False,
                 launch_args=None, initialize=True):
        self.executable = executable
        self.game = Path(game)
        # These paths are passed to children with a different cwd (Studio lives
        # beside the game). Relative overrides silently miss the isolated profile.
        self.out = Path(out or tempfile.mkdtemp(prefix='rezvivo-mcp-')).resolve()
        self.out.mkdir(parents=True, exist_ok=True)
        self.process = None
        self.expect_crash = False
        self.reader = self.stderr = self.server = None
        self.api_handler = api_handler
        self.native_api = native_api
        self.launch_args = ['--mcp-stdio'] if launch_args is None else list(launch_args)
        self.initialize = initialize
        self.serial = 0
        self.incoming = queue.Queue()
        self.env = os.environ.copy()
        self.env.update(REZVIVO_TEST_AUTH_FILE=str(self.out/'no-auth.json'),
                        REZVIVO_TEST_SETTINGS_FILE=str(self.out/'settings.json'),
                        REZVIVO_TEST_ACCOUNT_DIR=str(self.out/'accounts'),
                        REZVIVO_TEST_SESSION_DIR=str(self.out/'sessions'),
                        REZVIVO_TEST_NO_UPLOAD='1', REZVIVO_TEST_NO_HARDWARE='1')
        if self.executable == 'bikeeditor.exe':
            editor_config = self.out/'bikeeditor.ini'
            self.env['REZVIVO_TEST_EDITOR_CONFIG'] = str(editor_config)
            if not editor_config.exists():
                source = self.game/'bikeeditor.ini'
                editor_config.write_bytes(source.read_bytes() if source.exists() else b'')
        elif self.executable == 'avatareditor.exe':
            self.env['REZVIVO_TEST_AVATAR_RECENT'] = str(self.out/'avatar-recent.txt')
        elif self.executable == 'osm3d_studio_gui.exe':
            self.env['REZVIVO_STUDIO_STATE_FILE'] = str(self.out/'studio-view.json')
            self.env['REZVIVO_TEST_HIDDEN'] = '1'
        if cache_root:
            self.env['REZVIVO_TEST_CACHE_ROOT'] = str(cache_root)
        (self.out/'accounts/0').mkdir(parents=True, exist_ok=True)
        (self.out/'accounts/0/experience.json').write_text(json.dumps({
            'rider': {'nickname': 'Performance test', 'weight': 75, 'ftp': 210}}))
        (self.out/'settings.json').write_text(json.dumps({
            'ui': {'language': 'en'},
            'adapters': {'BLE:Bluetooth': False, 'ANT+:ANT+': False},
            'graphics': graphics or {'fps_limit': 0, 'msaa': 0}}))

    def __enter__(self):
        # Re-entry preserves account/settings but must never inherit a previous
        # intentional kill or a previous process' EOF.
        self.incoming = queue.Queue()
        self.expect_crash = False
        self.process = self.reader = self.stderr = self.server = None
        try:
            class API(BaseHTTPRequestHandler):
                def do_GET(self):
                    data = ({'current_build': 1, 'allowed': True, 'update_available': False}
                            if '/client/version?' in self.path else {'status': 'ok'})
                    raw = json.dumps(data).encode()
                    self.send_response(200)
                    self.send_header('Content-Length', str(len(raw)))
                    self.send_header('Content-Type', 'application/json')
                    self.end_headers()
                    self.wfile.write(raw)
                def do_POST(self):
                    self.rfile.read(int(self.headers.get('Content-Length', 0)))
                    self.do_GET()
                def log_message(self, *args):
                    pass
            self.server = ThreadingHTTPServer(('127.0.0.1', 0), self.api_handler or API)
            threading.Thread(target=self.server.serve_forever, daemon=True).start()
            # Optional real authenticated map access. Credentials remain in the
            # application's normal credential store and go only to its normal
            # HTTPS API; never copy them into fixtures or send them to localhost.
            # Isolated settings/accounts and NO_UPLOAD still apply.
            self.env['REZVIVO_TEST_API'] = ('' if self.native_api else
                'http://127.0.0.1:'+str(self.server.server_port))
            startup = subprocess.STARTUPINFO()
            startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            startup.wShowWindow = 0
            self.stderr = (self.out/'stderr.log').open('wb')
            self.process = subprocess.Popen([str(self.game/self.executable), *self.launch_args],
                cwd=self.game, env=self.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=self.stderr, startupinfo=startup, creationflags=subprocess.CREATE_NO_WINDOW)
            process, incoming = self.process, self.incoming
            def read():
                for line in process.stdout:
                    try:
                        incoming.put(json.loads(line))
                    except ValueError:
                        # FPC prints unhandled exceptions to stdout in GUI builds.
                        # Preserve them in explicit probes instead of dropping the
                        # only crash stack together with non-JSON diagnostics.
                        with (self.out/'process-output.log').open('ab') as raw:
                            raw.write(line)
                incoming.put({'eof': True})
            self.reader = threading.Thread(target=read, daemon=True)
            self.reader.start()
            if self.initialize:
                self.rpc('initialize', dict(protocolVersion='2024-11-05', capabilities={},
                         clientInfo={'name': 'rezvivo-regression', 'version': '1'}))
        except BaseException:
            self.__exit__(*sys.exc_info())
            raise
        return self

    def rpc(self, method, params, timeout=240):
        self.serial += 1
        self.process.stdin.write((json.dumps(dict(jsonrpc='2.0', id=self.serial,
                                    method=method, params=params))+'\n').encode())
        self.process.stdin.flush()
        until = time.monotonic()+timeout
        while time.monotonic() < until:
            msg = self.incoming.get(timeout=max(.1, until-time.monotonic()))
            if msg.get('eof'):
                raise RuntimeError('Game exited; inspect '+str(self.out))
            if msg.get('id') != self.serial:
                continue
            if 'error' in msg:
                raise RuntimeError(msg['error'])
            result = msg.get('result', {})
            if result.get('isError'):
                raise RuntimeError(result)
            return result
        raise TimeoutError(method)

    def call(self, tool, **args):
        result = self.rpc('tools/call', dict(name=tool, arguments=args))
        for item in result.get('content', []):
            if item.get('type') == 'text':
                return json.loads(item['text'])
        return result

    def setting(self, key, value):
        return self.call('property_set', object='settings', path=key, value=value)

    def kill_for_test(self):
        """Declare an intentional crash BEFORE killing a still-running game.

        An executable that already crashed cannot accidentally be reclassified
        as an expected test crash. __enter__ resets this permission on restart.
        """
        if self.process is None or self.process.poll() is not None:
            raise RuntimeError('Cannot deliberately kill a game that already exited')
        self.expect_crash = True
        self.process.kill()
        self.process.wait(timeout=10)

    def __exit__(self, exc_type, exc_value, traceback):
        issues = []

        def cleanup(label, action):
            try:
                action()
            except Exception as error:
                issues.append(label + ': ' + str(error))

        process = self.process
        if process is not None:
            if process.poll() is None:
                if process.stdin is not None and not process.stdin.closed:
                    cleanup('closing game input', process.stdin.close)
                try:
                    process.wait(timeout=25)
                except subprocess.TimeoutExpired:
                    # A timeout is always a test failure, even if an earlier
                    # intentional crash was requested but never actually ended.
                    issues.append('game shutdown timed out after 25 seconds; forced kill')
                    cleanup('killing timed-out game', process.kill)
                    cleanup('waiting for killed game', lambda: process.wait(timeout=10))
                except Exception as error:
                    issues.append('waiting for game exit: ' + str(error))
                    cleanup('killing game after wait failure', process.kill)
                    cleanup('waiting for killed game', lambda: process.wait(timeout=10))
            returncode = process.poll()
            if returncode is None:
                issues.append('game process is still running')
            elif returncode != 0 and not self.expect_crash:
                issues.append('game exited with code %d (0x%08X)' %
                              (returncode, returncode & 0xffffffff))
        if self.reader is not None:
            cleanup('joining MCP reader', lambda: self.reader.join(timeout=5))
        if process is not None:
            # A reader may hold the stream lock if TerminateProcess itself
            # failed. Do not turn an already failed test into an infinite wait.
            if process.poll() is not None and process.stdout is not None:
                cleanup('closing game output', process.stdout.close)
            if process.stdin is not None and not process.stdin.closed:
                cleanup('closing game input', process.stdin.close)
        if self.stderr is not None:
            cleanup('closing game error log', self.stderr.close)
        if self.server is not None:
            cleanup('stopping API fixture', self.server.shutdown)
            cleanup('closing API fixture', self.server.server_close)
        if issues:
            detail = 'Game session did not finish cleanly: ' + '; '.join(issues)
            detail += '; inspect ' + str(self.out)
            if exc_type is None:
                raise RuntimeError(detail)
            # Preserve the original assertion/RPC error and still make an AV
            # during cleanup visible. Python 3.9 has no Exception.add_note.
            print(detail, file=sys.stderr)
        return False


class GPULock:
    def __enter__(self):
        self.kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        self.kernel.CreateMutexW.restype = ctypes.c_void_p
        self.kernel.CreateMutexW.argtypes = [ctypes.c_void_p, ctypes.c_bool, ctypes.c_wchar_p]
        self.kernel.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_uint]
        self.kernel.ReleaseMutex.argtypes = [ctypes.c_void_p]
        self.kernel.CloseHandle.argtypes = [ctypes.c_void_p]
        self.handle = self.kernel.CreateMutexW(None, False, 'Local\\REZVIVO_GPU_BENCHMARK')
        if not self.handle or self.kernel.WaitForSingleObject(self.handle, 0) not in (0, 0x80):
            if self.handle:
                self.kernel.CloseHandle(self.handle)
            raise RuntimeError('Another GPU benchmark is running')
        return self
    def __exit__(self, *exc):
        self.kernel.ReleaseMutex(self.handle)
        self.kernel.CloseHandle(self.handle)

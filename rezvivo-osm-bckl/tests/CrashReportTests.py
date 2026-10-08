"""Exercise the native crash pipeline without a renderer or production uploads.

Compile CrashReportProbe.pas with the game's Pascal unit paths, then run:
  python tests/CrashReportTests.py PATH_TO_PROBE_EXE [ARTIFACT_DIRECTORY]
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROBE = Path(sys.argv[1]).resolve()
OUT = Path(sys.argv[2] if len(sys.argv) > 2 else
           tempfile.mkdtemp(prefix='rezvivo-crash-test-')).resolve()
sys.argv[1:] = []


class CrashReportTests(unittest.TestCase):
    def setUp(self):
        self.root = OUT / self._testMethodName
        self.root.mkdir(parents=True, exist_ok=False)
        self.diag = self.root / 'diagnostics'
        self.diag.mkdir()
        self.env = os.environ.copy()
        self.env.update(REZVIVO_TEST_AUTH_FILE=str(self.root / 'no-auth.json'),
                        REZVIVO_TEST_SESSION_DIR=str(self.root),
                        REZVIVO_TEST_NO_UPLOAD='1')

    def run_probe(self, mode='clean', *args):
        result = subprocess.run([str(PROBE), mode, str(self.root / 'current.log'), *args],
                                env=self.env, cwd=PROBE.parent, capture_output=True,
                                timeout=25, creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        (self.root / (mode + '.stdout')).write_bytes(result.stdout)
        (self.root / (mode + '.stderr')).write_bytes(result.stderr)
        self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', 'replace'))
        return result.stdout.decode('utf-8', 'replace')

    def report(self, report_id=None):
        files = list(self.diag.glob((report_id or '*') + '.report.json'))
        self.assertEqual(len(files), 1)
        value = json.loads(files[0].read_bytes())
        self.assertLess(len(value['log'].encode('utf-8')), 1024 * 1024)
        self.assertNotIn('synthetic-private-value', value['log'])
        return value

    def previous(self, text, machine='CPU name: PREVIOUS MACHINE\nGPU: previous adapter'):
        report_id = str(uuid.uuid4())
        log = self.root / (report_id + '.log')
        if text is not None:
            log.write_bytes(text.encode('utf-8'))
        marker = dict(report_id=report_id, pid=2147483647, log=str(log),
                      build=1, version='regression previous version')
        if machine is not None:
            marker['machine'] = machine
        (self.diag / (report_id + '.running.json')).write_text(json.dumps(marker), encoding='utf-8')
        return report_id

    def test_capture_keeps_hardware_and_tail(self):
        output = self.run_probe('capture')
        text = self.report()['log']
        self.assertIn('CPU name:', text)
        self.assertIn('Present display adapters:', text)
        self.assertIn('Hardware ID:', text)
        self.assertIn('Driver:', text)
        self.assertIn('RAM total:', text)
        self.assertIn('Renderer: regression current GPU', text)
        self.assertIn('regression captured exception', text)
        self.assertIn('final safe line', text)
        self.assertGreater((self.root / 'current.log').stat().st_size, 1024 * 1024)
        self.assertFalse(list(self.diag.glob('*.running.json')))
        self.assertIn('Cached inventory calls (10000), ms:', output)

    def test_marker_refresh_and_recovery(self):
        self.run_probe('mark')
        markers = list(self.diag.glob('*.running.json'))
        self.assertEqual(len(markers), 1)
        marker = json.loads(markers[0].read_bytes())
        self.assertIn('CPU name:', marker['machine'])
        self.assertIn('Renderer: regression current GPU', marker['machine'])
        self.assertNotIn('synthetic-private-value', marker['machine'])
        self.assertFalse(list(self.diag.glob('*.tmp')))
        self.run_probe()
        self.assertIn(marker['machine'].strip(), self.report(marker['report_id'])['log'])
        self.assertFalse(list(self.diag.glob('*.running.json')))

    def test_before_gl_initialization(self):
        self.run_probe('early')
        marker = json.loads(next(self.diag.glob('*.running.json')).read_bytes())
        self.assertIn('CPU name:', marker['machine'])
        self.assertIn('Active OpenGL context: not initialized', marker['machine'])
        self.run_probe()
        self.assertIn('Active OpenGL context: not initialized', self.report()['log'])

    def test_recovery_uses_previous_machine(self):
        report_id = self.previous('Old log start\n' + 'x' * 1200000 + '\nold final line')
        self.run_probe()
        text = self.report(report_id)['log']
        self.assertIn('PREVIOUS MACHINE', text)
        self.assertIn('previous adapter', text)
        self.assertNotIn('regression current GPU', text)
        self.assertNotIn('Old log start', text)
        self.assertIn('old final line', text)

    def test_legacy_report_keeps_original_startup(self):
        report_id = self.previous('CPU name: LEGACY MACHINE\nGPU: original adapter\n' +
                                 'Authorization: Bearer synthetic-private-value\n' +
                                 'x' * 1200000 + '\nlegacy final line', machine=None)
        self.run_probe()
        text = self.report(report_id)['log']
        self.assertIn('LEGACY MACHINE', text)
        self.assertIn('original adapter', text)
        self.assertIn('legacy final line', text)
        self.assertNotIn('regression current GPU', text)

    def test_missing_log_keeps_hardware(self):
        report_id = self.previous(None)
        self.run_probe()
        self.assertIn('PREVIOUS MACHINE', self.report(report_id)['log'])

    def test_loopback_upload_preserves_diagnostics(self):
        received = []
        class Fixture(BaseHTTPRequestHandler):
            def do_POST(self):
                received.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
                raw = json.dumps(dict(accepted=True, report_id=received[-1]['report_id'])).encode()
                self.send_response(200)
                self.send_header('Content-Length', str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)
            def log_message(self, *args):
                pass
        report_id = self.previous('last safe line\nAuthorization: Bearer synthetic-private-value')
        server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.env['REZVIVO_TEST_NO_UPLOAD'] = '0'
        try:
            self.run_probe('upload', 'http://127.0.0.1:' + str(server.server_port))
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
        self.assertEqual(len(received), 1)
        self.assertEqual(received[0]['report_id'], report_id)
        self.assertIn('PREVIOUS MACHINE', received[0]['log'])
        self.assertIn('last safe line', received[0]['log'])
        self.assertNotIn('synthetic-private-value', received[0]['log'])
        self.assertFalse(list(self.diag.glob('*.report.json')))


if __name__ == '__main__':
    unittest.main(verbosity=2)

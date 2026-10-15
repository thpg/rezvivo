"""Real hidden ride: virtual-time capture, Esc, H.264 output and safe cleanup.

An isolated profile and generated power FIT are used; no user activity uploads.
"""
import argparse
import ctypes
import json
from pathlib import Path
import shutil
import subprocess
import time
from http.server import BaseHTTPRequestHandler

from McpHarness import GameSession, GPULock, write_sim_fit
from RideRecoveryFocusMcpTest import NativeUI, wait_for


def save(path, doc):
    path.write_text(json.dumps(doc, ensure_ascii=False, indent=2), encoding='utf-8')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--game', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--executable', default='third_person_navigation.exe')
    parser.add_argument('--ffprobe', type=Path, required=True)
    parser.add_argument('--edge-cases', action='store_true')
    args = parser.parse_args()
    game, out = args.game.resolve(), args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    fit = out/'power.fit'
    write_sim_fit(fit, seconds=600, watts=210, cadence=85)
    class API(BaseHTTPRequestHandler):
        def do_GET(self):
            obj = (dict(id=73, nickname='Video fixture', weight_g=75000, ftp_w=210,
                        is_admin=True, locale='en') if self.path == '/api/v1/me' else
                   dict(has_access=True, status='ok', allowed=True, update_available=False))
            raw = json.dumps(obj).encode()
            self.send_response(200)
            self.send_header('Content-Length', str(len(raw)))
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(raw)
        def do_POST(self):
            self.rfile.read(int(self.headers.get('Content-Length', 0)))
            self.do_GET()
        def log_message(self, *args): pass
    app = GameSession(game, out/'профиль теста', graphics={
        'fps_limit': 30, 'msaa': 0, 'shadow_size': 1024, 'shadow_distance': 100},
        executable=args.executable, api_handler=API)
    save(app.out/'no-auth.json', dict(access_token='test-only', refresh_token='test-only',
                                    expires_at=int(time.time())+3600))
    app.env['REZVIVO_TEST_HIDDEN'] = '1'
    result = {'passed': False, 'captures': []}
    with GPULock(), app:
        app.setting('AudioMaster', 0)
        app.setting('SimulationFitPath', str(fit))
        app.setting('SimulationUseRoute', False)
        app.setting('SimulationEnabled', True)
        app.call('dream.inspect', open=True, select=0)
        wait_for(lambda: app.call('dream.inspect'), lambda r: r.get('page', {}).get('ready'), 120)
        app.call('dream.start')
        wait_for(lambda: app.call('perf.state'), lambda r: r.get('active') and r.get('prep_done'), 240)
        wait_for(lambda: app.call('bots.local'), lambda r: r.get('ready'), 180)
        ui = NativeUI(app)
        ui.user.SendMessageW(ui.hwnd, 6, 1, 0)
        app.call('camera.set_mode', mode='thirdperson')
        app.call('camera.chase', distance=7, height=3, aim_height=1)
        app.call('sim.speed', mul=1)
        app.call('sim.play')
        app.call('ride.start')
        time.sleep(2)
        # Both normal playback and extreme slow motion must use virtual time.
        for index, rate in enumerate((1, 1/60)):
            app.call('sim.speed', mul=rate)
            wall = time.monotonic()
            before_files = set((game/'videos').glob('*'))
            if index == 0:
                ui.click('RecordVideo')
                initial = app.call('app.video')
            else:
                initial = app.call('app.video', action='start')
            start = initial['video']
            assert start['state'] == 'recording', start
            frames = wait_for(lambda: app.call('app.video')['video'],
                              lambda s: s['frames'] >= (90 if index == 0 else 30) or s['state'] == 'error',
                              180, 'frames captured')
            assert frames['state'] == 'recording', frames
            # A nested MCP screenshot must not count as a movie frame.
            app.call('app.screenshot', path=str(out/f'during-{index}.png'), inline=False)
            controls = ui.controls()
            assert not any(c['name'] in ('SimPlayer', 'SimPause', 'RecordVideo', 'LabelFps') for c in controls), controls
            snapshot = app.call('app.video')
            progress = snapshot['video']
            elapsed = snapshot['sim_time_sec'] - initial['sim_time_sec']
            expected = (progress['frames']-start['frames'])/30*rate
            # RPCs between snapshots can allow a few frames, but never wall time.
            assert abs(elapsed-expected) < .07*rate, (elapsed, expected)
            assert progress['frame_files'] == 0 and progress['max_buffered_frames'] == 1
            assert all(f.suffix == '.mp4' for f in set((game/'videos').glob('*'))-before_files)
            # Actual key input, not the stop RPC: it must not open the menu.
            ui.user.PostMessageW(ui.hwnd, 0x0100, 0x1B, 1 | (1 << 16))
            finished = wait_for(lambda: app.call('app.video')['video'],
                                lambda s: s['state'] in ('done', 'error'), 120, 'encoding')
            assert finished['state'] == 'done', finished
            # Keep Esc held past finalization: auto-repeat must not open Menu.
            ui.user.PostMessageW(ui.hwnd, 0x0100, 0x1B, 1 | (1 << 16) | (1 << 30))
            time.sleep(.1)
            assert app.call('app.views_list')['active'] == 'play'
            ui.user.PostMessageW(ui.hwnd, 0x0101, 0x1B, 1 | (1 << 16) | (3 << 30))
            assert not Path(finished['partial_file']).exists(), 'partial file must be renamed after finalization'
            video = Path(finished['file'])
            probe = json.loads(subprocess.check_output([str(args.ffprobe), '-v', 'error',
                '-count_frames', '-show_streams', '-show_format', '-of', 'json', str(video)]))
            stream = next(s for s in probe['streams'] if s['codec_type'] == 'video')
            assert stream['codec_name'] == 'h264' and stream['avg_frame_rate'] == '30/1', stream
            assert int(stream['nb_read_frames']) == finished['frames'], (stream, finished)
            assert abs(float(stream['duration'])-finished['frames']/30) < .001
            assert stream['width'] == (finished['width']+1)//2*2
            assert stream['height'] == (finished['height']+1)//2*2
            assert any(c['name'] == 'SimPause' for c in ui.controls()), 'simulation panel was not restored'
            shutil.copy2(video, out/f'recording-{index}.mp4')
            result['captures'].append(dict(status=finished, probe=probe, rate=rate,
                wall_seconds=time.monotonic()-wall, sim_elapsed=elapsed, expected=expected))
            print('CAPTURE', index, finished['frames'], 'frames', finished['duration'], 'video seconds', flush=True)
        if args.edge_cases:
            app.call('sim.speed', mul=1)
            app.call('app.video', action='start')
            failing = wait_for(lambda: app.call('app.video')['video'],
                              lambda s: s['encoded_frames'] >= 65, 120)
            # Terminate only the FFmpeg child returned by this isolated capture.
            import psutil
            child = psutil.Process(failing['encoder_pid'])
            assert child.ppid() == app.process.pid and child.name().lower() == 'ffmpeg.exe'
            child.kill()
            failed = wait_for(lambda: app.call('app.video')['video'], lambda s: s['state'] == 'error', 20)
            assert Path(failed['partial_file']).stat().st_size > 128
            assert not Path(failed['file']).exists()
            assert any(c['name'] == 'RecordVideo' for c in ui.controls())
            # The app must continue, and another recording must work after failure.
            app.call('app.video', action='start')
            wait_for(lambda: app.call('app.video')['video'], lambda s: s['frames'] >= 15, 60)
            ui.key(0x1B)
            recovered = wait_for(lambda: app.call('app.video')['video'],
                                 lambda s: s['state'] in ('done', 'error'), 30)
            assert recovered['state'] == 'done', recovered
            result['encoder_failure'] = failed
            result['recovery'] = recovered
            print('PASS: encoder failure preserves partial movie, restores UI and permits restart', flush=True)
        app.call('ride.stop_full')
    result['passed'] = True
    save(out/'result.json', result)
    print('PASS: offline streaming, virtual FIT time, Esc, panel restore, H.264/30 fps, no frame files, clean exit', flush=True)


if __name__ == '__main__':
    main()

"""Actual-game crash recovery, workout picker, keyboard and Focus regression.

Requires the newly built client. Owns REZVIVO_GPU_BENCHMARK for both launches;
uses one disposable LOCAL profile and a generated FIT/ZWO, never user rides.
python tests/RideRecoveryFocusMcpTest.py --out tests/artifacts/recovery-focus
python tests/RideRecoveryFocusMcpTest.py --active-kill --out tests/artifacts/recovery-active
python tests/RideRecoveryFocusMcpTest.py --self-test  # CPU only, no game/GPU
"""
import argparse
import csv
import ctypes
import hashlib
from datetime import datetime, timedelta
import io
import json
import math
from pathlib import Path
import shutil
import tempfile
import time
from McpHarness import GameSession, GPULock, write_sim_fit

WATTS = 190
WORKOUT_NAME = 'Recovery integration fixture'
WORKOUT = '''<?xml version="1.0" encoding="UTF-8"?>
<workout_file><author>REZVIVO regression</author>
<name>Recovery integration fixture</name><description>Disposable test only</description>
<sportType>bike</sportType><workout>
<Warmup Duration="120" PowerLow="0.45" PowerHigh="0.65"/>
<IntervalsT Repeat="4" OnDuration="60" OffDuration="60" OnPower="0.9" OffPower="0.5"/>
<Cooldown Duration="120" PowerLow="0.65" PowerHigh="0.4"/>
</workout></workout_file>'''


def wait_for(read, accept, seconds=15, description='condition'):
    deadline, last = time.monotonic() + seconds, None
    while time.monotonic() < deadline:
        last = read()
        if accept(last):
            return last
        time.sleep(.2)
    raise AssertionError((description, last))


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding='utf-8')


def journal_records(raw):
    # A concurrent writer may have an unfinished final line. Never accept that
    # line as evidence that a complete telemetry/event record reached disk.
    text = raw.decode('utf-8-sig')
    text = text[:text.rfind('\n') + 1]
    rows = list(csv.DictReader(io.StringIO(text)))
    assert rows, 'journal contains no complete records'
    for row in rows:
        assert None not in row and all(value is not None for value in row.values()), row
        assert math.isfinite(float(row['ElapsedSec'])), row
    elapsed = [float(row['ElapsedSec']) for row in rows]
    assert elapsed == sorted(elapsed), 'journal elapsed time went backwards'
    return rows


def assert_unchanged_counters(before, after, tolerance=1):
    for key in ('work_j', 'seconds', 'distance_m', 'tss'):
        assert abs(after[key] - before[key]) <= tolerance, (key, before[key], after[key])
    for key in ('work', 'tss', 'revision'):
        old = before['resume']['daily'][key]
        new = after['resume']['daily'][key]
        assert abs(new-old) <= tolerance, ('daily '+key, old, new)


def assert_layout(controls, names, size):
    chosen = []
    for name in names:
        control = next(c for c in controls if c['name'] == name)
        x, y, w, h = control['rect']
        assert w > 0 and h > 0 and x >= -1 and y >= -1, control
        assert x+w <= size[0]+1 and y+h <= size[1]+1, control
        chosen.append(control)
    for i, first in enumerate(chosen):
        x, y, w, h = first['rect']
        for second in chosen[i+1:]:
            a, b, c, d = second['rect']
            overlap = max(0, min(x+w, a+c)-max(x, a)) * max(0, min(y+h, b+d)-max(y, b))
            assert overlap < 1, ('overlapping controls', first, second)


class NativeUI:
    """Use the real Win32 -> CGE input path, not direct OnClick invocation."""
    def __init__(self, app):
        self.app = app
        self.user = ctypes.WinDLL('user32', use_last_error=True)
        self.user.SendMessageW.argtypes = [ctypes.c_void_p, ctypes.c_uint,
                                           ctypes.c_size_t, ctypes.c_ssize_t]
        self.user.SendMessageW.restype = ctypes.c_ssize_t
        self.user.PostMessageW.argtypes = self.user.SendMessageW.argtypes
        self.user.PostMessageW.restype = ctypes.c_bool
        self.user.LoadKeyboardLayoutW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint]
        self.user.LoadKeyboardLayoutW.restype = ctypes.c_void_p
        self.user.MapVirtualKeyW.argtypes = [ctypes.c_uint, ctypes.c_uint]
        self.user.GetWindowThreadProcessId.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint)]
        self.user.GetClassNameW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_int]
        self.hwnd = None
        callback_type = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)
        @callback_type
        def window(hwnd, _):
            pid, name = ctypes.c_uint(), ctypes.create_unicode_buffer(256)
            self.user.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
            self.user.GetClassNameW(hwnd, name, 256)
            if pid.value == app.process.pid and name.value == 'CastleWindow':
                self.hwnd = hwnd
            return True
        self.user.EnumWindows(window, 0)
        assert self.hwnd, 'CastleWindow not found'
        # Only this disposable game thread uses the fixture's US key layout.
        # CGE resolves OEM keys from WM_CHAR produced by TranslateMessage,
        # so direct SendMessage(WM_KEYDOWN) cannot represent '[' or ']'.
        layout = self.user.LoadKeyboardLayoutW('00000409', 0)
        assert layout, 'US keyboard layout unavailable'
        self.user.SendMessageW(self.hwnd, 0x0050, 0, layout)

    def size(self):
        class Rect(ctypes.Structure):
            _fields_ = [('left', ctypes.c_long), ('top', ctypes.c_long),
                        ('right', ctypes.c_long), ('bottom', ctypes.c_long)]
        rect = Rect()
        self.user.GetClientRect(ctypes.c_void_p(self.hwnd), ctypes.byref(rect))
        return rect.right, rect.bottom

    def controls(self):
        return self.app.call('ui.inspect', **{'global': True, 'labels': True})['controls']

    def click(self, name):
        control = wait_for(self.controls, lambda cs: any(c['name'] == name for c in cs),
                           description='visible '+name)
        control = next(c for c in control if c['name'] == name)
        x, y, w, h = control['rect']
        width, height = self.size()
        assert control.get('enabled', True), control
        assert 0 <= x+w/2 < width and 0 <= y+h/2 < height, ('off-screen click', control)
        pos = (int(height-y-h/2) << 16) | int(x+w/2)
        self.user.SendMessageW(self.hwnd, 0x0200, 0, pos)
        self.user.SendMessageW(self.hwnd, 0x0201, 1, pos)
        self.user.SendMessageW(self.hwnd, 0x0202, 0, pos)
        time.sleep(.15)

    def key(self, vk):
        scan = self.user.MapVirtualKeyW(vk, 0)
        flags = 1 | (scan << 16)
        if vk in (0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28):
            flags |= 1 << 24
        assert self.user.PostMessageW(self.hwnd, 0x0100, vk, flags)
        assert self.user.PostMessageW(self.hwnd, 0x0101, vk, flags | (3 << 30))
        time.sleep(.15)


class Check:
    def __init__(self, out, app):
        self.out, self.app = out, app
        self.activities = app.out/'accounts/0/activities'

    def activity(self):
        files = list(self.activities.glob('*.json'))
        assert len(files) == 1, ('expected one activity across restart', files)
        return json.loads(files[0].read_text(encoding='utf-8-sig'))

    def ready(self, timeout):
        return wait_for(lambda: self.app.call('perf.state'),
                        lambda s: s.get('active') and s.get('prep_done'), timeout, 'ride ready')

    def snapshot(self, name):
        data = dict(perf=self.app.call('perf.state'), sim=self.app.call('sim.info'),
                    workout=self.app.call('workout.inspect'))
        if list(self.activities.glob('*.json')):
            data['activity'] = self.activity()
        write_json(self.out/(name+'.json'), data)
        self.app.call('app.screenshot', path=str(self.out/(name+'.png')), inline=False)
        return data


def exercise_picker(app, ui, out):
    app.call('app.switch_view', view='training')
    ui.click('SuggestWorkout')
    ui.click('SuggestMinutes20')
    ui.click('SuggestGoal2')
    def suggestions(cs):
        return [c for c in cs if c['name'].startswith('WorkoutDetails')]
    controls = wait_for(ui.controls, lambda cs: 1 <= len(suggestions(cs)) <= 3,
                        description='up to three recommended workouts')
    assert_layout(controls, ['SuggestMinutes20', 'SuggestMinutes30', 'SuggestMinutes45',
                            'SuggestMinutes60', 'SuggestGoal0', 'SuggestGoal1', 'SuggestGoal2'], ui.size())
    write_json(out/'picker-controls.json', controls)
    app.call('app.screenshot', path=str(out/'picker.png'), inline=False)
    ui.click(suggestions(controls)[0]['name'])
    wait_for(ui.controls, lambda cs: any(c['name'] == 'WorkoutDetailsBack' for c in cs))
    # Modal keyboard scope: the first Tab must choose its Back button, and
    # Enter must close the detail view without activating a menu item behind it.
    ui.key(0x09)
    app.call('app.screenshot', path=str(out/'keyboard-focus.png'), inline=False)
    ui.key(0x0D)
    wait_for(ui.controls, lambda cs: not any(c['name'] == 'WorkoutDetailsBack' for c in cs),
             description='Tab + Enter closes workout details')
    ui.click('WorkoutFilter3')  # My workouts contains only the fixture.
    controls = wait_for(ui.controls, lambda cs: any(c['caption'] == WORKOUT_NAME for c in cs))
    fixture = next(c for c in controls if c['caption'] == WORKOUT_NAME)
    ui.click(fixture['name'])
    # A paused FIT is deliberately allowed to become a stale sensor. Refresh
    # actual simulation data before the normal workout launch availability check.
    app.call('sim.play')
    time.sleep(1)
    ui.click('StartDetailedWorkout')


def start_fixture_ride(app, check, out, fit, prepare_timeout):
    ui = NativeUI(app)
    app.setting('AudioMaster', 0)
    app.setting('SimulationFitPath', str(fit))
    app.setting('SimulationUseRoute', False)
    app.setting('SimulationEnabled', True)
    # Establish a deterministic Dream ride before starting the workout.
    app.call('dream.inspect', open=True, select=0)
    wait_for(lambda: app.call('dream.inspect'), lambda s: s.get('page', {}).get('ready'),
             prepare_timeout, 'Dream preview ready')
    app.call('dream.start')
    check.ready(prepare_timeout)
    app.call('sim.pause')
    exercise_picker(app, ui, out)
    wait_for(lambda: app.call('app.views_list'), lambda s: s['active'] == 'play')
    app.call('sim.play')
    app.call('ride.start')
    wait_for(lambda: app.call('workout.inspect'), lambda s: s['state'] == 2,
             description='workout running')
    return ui


def journal_wall_time(value, reference):
    """New CSV stores ISO local wall time; legacy rows store hh:mm:ss.mmm.

    Looking at adjacent dates also handles a crash immediately after midnight.
    ElapsedSec is deliberately not substituted for this wall-clock measurement.
    """
    if 'T' in value:
        return datetime.fromisoformat(value).timestamp()
    local = datetime.fromtimestamp(reference)
    stamp = datetime.strptime(value, '%H:%M:%S.%f').time()
    candidates = [datetime.combine(local.date()+timedelta(days=offset), stamp).timestamp()
                  for offset in (-1, 0, 1)]
    return min(candidates, key=lambda candidate: abs(reference-candidate))


def active_loss_measurements(rows, checkpoint, checkpoint_mtime, killed_at):
    latest = rows[-1]
    journal_age = killed_at-journal_wall_time(latest['Timestamp'], killed_at)
    checkpoint_age = killed_at-checkpoint_mtime
    assert -.1 <= journal_age <= 2, ('journal loss exceeds 2 seconds', journal_age)
    assert -.1 <= checkpoint_age <= 5, ('checkpoint age exceeds 5 seconds', checkpoint_age)
    assert latest['TimerActive'] == '1' and latest['IsMoving'] == '1', latest
    assert float(latest['Speed_kmh']) > 0, ('not moving at kill', latest)
    gap = float(latest['ElapsedSec'])-checkpoint['journal_elapsed']
    # Legacy CSV had one decimal; a checkpoint may be between durable samples.
    assert -.25 <= gap <= 5, ('checkpoint and durable journal disagree', gap)
    assert checkpoint['resume']['workout']['state'] == 2, 'kill was not in an active interval'
    return dict(journal_last_age_seconds=journal_age,
                checkpoint_age_seconds=checkpoint_age,
                journal_ahead_of_checkpoint_seconds=gap,
                journal_last_wall_time=journal_wall_time(latest['Timestamp'], killed_at),
                checkpoint_mtime=checkpoint_mtime, killed_at=killed_at)


def expected_active_resume(checkpoint, daily_file, rows=None):
    """The independent daily file may be newer than the activity checkpoint.

    Resume must preserve the greatest durable revision, not roll back an already
    committed daily total or apply that revision twice.
    """
    expected = json.loads(json.dumps(checkpoint))
    saved = expected['resume']['daily']
    if rows is not None:
        # Independent integral of the actual durable tail. This runtime fixture
        # supplies constant 190 W for over 30 s, so its NP is known analytically.
        cutoff = checkpoint['journal_elapsed']
        seconds = work = distance = power_seconds = 0.0
        for first, last in zip(rows, rows[1:]):
            a, b = float(first['ElapsedSec']), float(last['ElapsedSec'])
            dt = max(0.0, b-max(a, cutoff))
            if dt <= 0 or first['TimerActive'] != '1':
                continue
            seconds += dt
            distance += max(0, int(last['Distance_m'])-int(first['Distance_m'])) * dt/(b-a)
            if int(first['Power_W']) != 65535:
                assert int(first['Power_W']) == WATTS, 'constant-power recovery oracle needs 190 W'
                work += WATTS*dt
                power_seconds += dt
        tss = power_seconds*(WATTS/saved['ftp'])**2/36
        expected['work_j'] += work
        expected['seconds'] += seconds
        expected['distance_m'] += distance
        expected['tss'] += tss
        saved['work'] += work
        saved['tss'] += tss
        expected['tail_integral'] = dict(work_j=work, seconds=seconds, distance_m=distance, tss=tss)
    for day in daily_file.get('days', []):
        if day['day'] == saved['day'] and day['source'] == saved['source']:
            saved.update(revision=max(day['revision'], saved['revision']),
                         work=max(day['work_j'], saved['work']), tss=max(day['tss'], saved['tss']))
    return expected


def assert_active_resume(expected, actual):
    for key in ('work_j', 'seconds', 'tss'):
        assert abs(actual[key]-expected[key]) < .02, (key, expected[key], actual[key])
    # CSV distance uses integer metres; the live checkpoint uses floats.
    assert abs(actual['distance_m']-expected['distance_m']) <= 1
    before, after = expected['resume']['daily'], actual['resume']['daily']
    for key in ('work', 'tss'):
        assert abs(after[key]-before[key]) < .02, ('daily '+key, before[key], after[key])
    assert after['revision'] >= before['revision'], 'durable daily revision rolled back'


def run_active_kill(app, check, out, fit, prepare_timeout, active_seconds):
    with GPULock():
        with app:
            ui = start_fixture_ride(app, check, out, fit, prepare_timeout)
            ui.key(0x22)  # Actual work interval, rather than the opening warmup.
            wait_for(lambda: app.call('workout.inspect'),
                     lambda state: state['state'] == 2 and state['index'] == 1)
            initial_sim = app.call('sim.info')['position_sec']
            print('Active interval: riding before unsynchronised kill', flush=True)
            time.sleep(active_seconds)
            live = dict(workout=app.call('workout.inspect'), sim=app.call('sim.info'))
            assert live['workout']['state'] == 2 and live['workout']['index'] == 1
            assert not live['sim']['paused']
            assert live['sim']['position_sec'] > initial_sim+active_seconds-2
            # No screenshot, pause, stop, checkpoint request or flush wait here.
            kill_requested = time.time()
            app.kill_for_test()
            killed_at = time.time()
            activity_files = list(check.activities.glob('*.json'))
            assert len(activity_files) == 1, activity_files
            checkpoint_file = activity_files[0]
            checkpoint_raw = checkpoint_file.read_bytes()
            checkpoint = json.loads(checkpoint_raw.decode('utf-8-sig'))
            assert not checkpoint['complete']
            assert checkpoint['account'].rstrip('\\/') == str(app.out/'accounts/0')
            journal = Path(checkpoint['journal'])
            raw_before = journal.read_bytes()
            rows_before = journal_records(raw_before)
            measurements = active_loss_measurements(rows_before, checkpoint,
                                                   checkpoint_file.stat().st_mtime, killed_at)
            measurements.update(kill_requested_at=kill_requested,
                                kill_latency_seconds=killed_at-kill_requested)
            assert checkpoint['work_j'] > WATTS*30
            assert checkpoint['tss'] > 0 and checkpoint['resume']['daily']['tss'] > 0
            daily_path = app.out/'accounts/0/daily-training.json'
            daily = json.loads(daily_path.read_text(encoding='utf-8-sig')) if daily_path.exists() else {}
            expected = expected_active_resume(checkpoint, daily, rows_before)
            assert Path(str(journal)+'.active').exists()
            write_json(out/'active-kill-live.json', live)
            write_json(out/'active-kill-measurements.json', measurements)
            write_json(out/'active-kill-expected.json', expected)
            (out/'checkpoint-at-kill.json').write_bytes(checkpoint_raw)
            (out/'journal-at-kill.csv').write_bytes(raw_before)
            write_json(out/'daily-at-kill.json', daily)
        shutil.copy2(app.out/'stderr.log', out/'first-stderr.log')
        time.sleep(2)
        with app:
            ui = NativeUI(app)
            app.call('app.switch_view', view='home')
            wait_for(ui.controls, lambda cs: any(c['name'] == 'ContinueSavedRide' for c in cs))
            assert not check.activity()['complete']
            ui.click('ContinueSavedRide')
            check.ready(prepare_timeout)
            wait_for(lambda: app.call('workout.inspect'), lambda state: state.get('name') == WORKOUT_NAME)
            time.sleep(2)
            restored = check.snapshot('active-restored')
            activity = restored['activity']
            assert activity['id'] == checkpoint['id']
            assert activity['account'] == checkpoint['account']
            assert Path(activity['journal']) == journal
            assert restored['sim']['paused']
            assert journal.read_bytes().startswith(raw_before[:raw_before.rfind(b'\n')+1])
            assert_active_resume(expected, activity)
            assert abs(restored['workout']['elapsed']-checkpoint['resume']['workout']['elapsed']) < .1
            assert restored['workout']['index'] == checkpoint['resume']['workout']['index']
            saved_rider = checkpoint['resume']['rider']
            rider = activity['resume']['rider']
            assert math.dist([saved_rider[a] for a in ('x', 'y', 'z')],
                             [rider[a] for a in ('x', 'y', 'z')]) < 1
            time.sleep(3)
            assert_unchanged_counters(activity, check.activity(), tolerance=.01)
            if app.call('workout.inspect')['state'] == 3:
                ui.key(0x20)
            app.call('sim.play')
            app.call('ride.start')
            wait_for(lambda: app.call('workout.inspect'), lambda state: state['state'] == 2)
            start_position = app.call('sim.info')['position_sec']
            time.sleep(6)
            app.call('sim.pause')
            app.call('ride.stop')
            time.sleep(2)
            progressed = check.snapshot('active-resumed-progress')
            elapsed = progressed['sim']['position_sec']-start_position
            added = progressed['activity']['resume']['daily']['work']-activity['resume']['daily']['work']
            assert WATTS*max(1, elapsed-2) < added < WATTS*(elapsed+3), ('double credit', added, elapsed)
            assert progressed['activity']['tss'] >= checkpoint['tss']
            app.call('ride.stop_full')
            wait_for(check.activity, lambda value: value['complete'])
            wait_for(lambda: Path(str(journal)+'.active').exists(), lambda value: not value)
            assert len(list((app.out/'sessions').glob('session_*.csv'))) == 1
            final = check.activity()
            result = dict(passed=True, scenario='active-kill', measurements=measurements,
                          checkpoint_tss=checkpoint['tss'], activity=final,
                          daily_added_after_resume=added,
                          original_rows=len(rows_before), rows=len(journal_records(journal.read_bytes())))
        shutil.copy2(app.out/'stderr.log', out/'second-stderr.log')
        write_json(out/'result.json', result)
    print('PASS: active kill <=2s journal / <=5s checkpoint, nonzero TSS, one-activity resume', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--out', type=Path)
    parser.add_argument('--prepare-timeout', type=float, default=180)
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--active-kill', action='store_true',
                        help='crash while moving; measure journal/checkpoint loss bounds')
    parser.add_argument('--active-seconds', type=float, default=37.37,
                        help='moving time before active kill, at least 35 seconds for nonzero TSS')
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if args.active_kill and not 35 <= args.active_seconds <= 50:
        parser.error('--active-seconds must be between 35 and 50 to stay within the interval')
    out = (args.out or Path(tempfile.mkdtemp(prefix='rezvivo-recovery-focus-'))).resolve()
    out.mkdir(parents=True, exist_ok=True)
    assert not (out/'profile').exists(), 'Use a fresh output directory; existing fixtures are never erased'
    write_json(out/'build.json', dict(exe_sha256=hashlib.sha256(
        (args.game/'third_person_navigation.exe').read_bytes()).hexdigest()))
    app = GameSession(args.game.resolve(), out/'profile', dict(fps_limit=30, msaa=0))
    workouts = app.out/'accounts/0/workouts'
    workouts.mkdir()
    (workouts/'recovery-fixture.zwo').write_text(WORKOUT, encoding='utf-8')
    fit = out/'steady.fit'
    write_sim_fit(fit, watts=WATTS)
    check = Check(out, app)
    print('Artifacts:', out, flush=True)
    if args.active_kill:
        run_active_kill(app, check, out, fit, args.prepare_timeout, args.active_seconds)
        return
    with GPULock():
        with app:
            ui = start_fixture_ride(app, check, out, fit, args.prepare_timeout)
            app.call('perf.capture', action='start')
            time.sleep(5)
            write_json(out/'world-timings.json', app.call('perf.capture', action='stop'))
            before = check.snapshot('01-world')
            assert before['perf']['viewport_visible'] and not before['perf']['focus']
            assert before['perf']['draw_calls'] > 0
            ui.key(0x73)  # F4, shared command service.
            wait_for(lambda: app.call('perf.state'), lambda s: s.get('focus'))
            time.sleep(1)
            focused = check.snapshot('02-focus')
            app.call('perf.capture', action='start')
            time.sleep(5)
            write_json(out/'focus-timings.json', app.call('perf.capture', action='stop'))
            after = check.snapshot('03-focus-progress')
            assert not after['perf']['viewport_visible'], after['perf']
            for key in ('branch_draws', 'branch_shadow_draws', 'vegetation_shadow_draws'):
                assert after['perf'][key] == focused['perf'][key], ('world draw during Focus', key)
            assert after['sim']['position_sec'] > focused['sim']['position_sec']+3
            assert after['workout']['elapsed'] > focused['workout']['elapsed']+3
            assert after['activity']['work_j'] > focused['activity']['work_j']
            assert after['activity']['resume']['daily']['work'] > focused['activity']['resume']['daily']['work']
            journal = Path(after['activity']['journal'])
            focus_rows = journal_records(journal.read_bytes())
            assert float(focus_rows[-1]['ElapsedSec']) > float(focus_rows[0]['ElapsedSec'])+5
            ui.key(0x73)
            wait_for(lambda: app.call('perf.state'), lambda s: s.get('viewport_visible') and not s.get('focus'))
            check.snapshot('04-world-restored')
            # Keyboard commands reach exactly the same live workout as its buttons.
            reference = app.call('workout.inspect')['reference_watts']
            ui.key(0xDD)  # ] = +5 W
            assert app.call('workout.inspect')['reference_watts'] == reference+5
            ui.key(0xDB)  # [ = -5 W
            assert app.call('workout.inspect')['reference_watts'] == reference
            index = app.call('workout.inspect')['index']
            ui.key(0x22)  # PageDown = skip.
            assert app.call('workout.inspect')['index'] > index
            ui.key(0x20)  # Space = pause workout.
            assert app.call('workout.inspect')['state'] == 3
            app.call('sim.pause')
            app.call('ride.stop')
            ui.key(0x73)  # Also verify Focus is restored from the checkpoint.
            time.sleep(3)  # Worker flush + atomic checkpoint, without advancing metrics.
            saved = check.snapshot('05-before-crash')
            before_crash = saved['activity']
            assert before_crash['resume']['workout']['state'] == 3
            assert before_crash['work_j'] > 0 and before_crash['resume']['daily']['work'] > 0
            raw_before = journal.read_bytes()
            rows_before = journal_records(raw_before)
            assert rows_before[-1]['TimerActive'] == '0'
            assert Path(str(journal)+'.active').exists()
            # TerminateProcess deliberately bypasses normal stop and ExitProc.
            app.kill_for_test()
        shutil.copy2(app.out/'stderr.log', out/'first-stderr.log')
        time.sleep(2)  # Real downtime must not turn into power/timer accumulation.
        with app:  # Same instance preserves settings/account, including chosen world.
            ui = NativeUI(app)
            app.call('app.switch_view', view='home')
            wait_for(ui.controls, lambda cs: any(c['name'] == 'ContinueSavedRide' for c in cs))
            assert Path(str(journal)+'.active').exists(), 'startup finalized unfinished ride'
            assert not check.activity()['complete']
            ui.click('ContinueSavedRide')
            check.ready(args.prepare_timeout)
            wait_for(lambda: app.call('workout.inspect'), lambda s: s.get('name') == WORKOUT_NAME and s['state'] == 3,
                     description='paused workout restored')
            time.sleep(3)
            restored = check.snapshot('06-after-resume')
            restored_activity = restored['activity']
            assert restored_activity['id'] == before_crash['id']
            assert Path(restored_activity['journal']) == journal
            assert restored['sim']['paused'] and restored['perf']['focus']
            assert not restored['perf']['viewport_visible']
            assert journal.read_bytes().startswith(raw_before), 'resume rewrote prior records'
            assert_unchanged_counters(before_crash, restored_activity)
            assert abs(restored['workout']['elapsed']-saved['workout']['elapsed']) < .1
            assert restored['workout']['index'] == saved['workout']['index']
            p0, p1 = before_crash['resume']['rider'], restored_activity['resume']['rider']
            assert math.dist([p0[a] for a in ('x', 'y', 'z')], [p1[a] for a in ('x', 'y', 'z')]) < 1
            # A second checkpoint while paused may persist state; never credit it twice.
            time.sleep(3)
            assert_unchanged_counters(restored_activity, check.activity())
            ui.key(0x20)
            app.call('sim.play')
            app.call('ride.start')
            wait_for(lambda: app.call('workout.inspect'), lambda s: s['state'] == 2)
            started = app.call('sim.info')['position_sec']
            time.sleep(6)
            app.call('sim.pause')
            app.call('ride.stop')
            time.sleep(2)
            progressed = check.snapshot('07-resumed-progress')
            elapsed = progressed['sim']['position_sec']-started
            delta = progressed['activity']['resume']['daily']['work']-restored_activity['resume']['daily']['work']
            assert WATTS*max(1, elapsed-2) < delta < WATTS*(elapsed+3), ('power credited once', delta, elapsed)
            assert progressed['activity']['work_j'] > restored_activity['work_j']
            app.call('ride.stop_full')
            wait_for(check.activity, lambda a: a['complete'], description='activity finalized')
            wait_for(lambda: Path(str(journal)+'.active').exists(), lambda active: not active,
                     description='journal released on normal finish')
            final = check.activity()
            rows = journal_records(journal.read_bytes())
            assert len(rows) > len(rows_before)
            assert len(list((app.out/'sessions').glob('session_*.csv'))) == 1
            assert 'resume' not in final
            result_summary = dict(passed=True, activity=final, rows=len(rows),
                       original_rows=len(rows_before), daily_added_after_resume=delta)
        shutil.copy2(app.out/'stderr.log', out/'second-stderr.log')
        # Publish success only after GameSession verified a normal exit code.
        write_json(out/'result.json', result_summary)
    print('PASS: picker, keyboard, Focus, durable journal and one-activity crash resume', flush=True)


def self_test():
    raw = b'Timestamp,ElapsedSec,TimerActive\n2026,0.0,1\n2026,1.0,0\npartial'
    assert len(journal_records(raw)) == 2
    try:
        journal_records(b'ElapsedSec\n2\n1\n')
    except AssertionError:
        pass
    else:
        raise AssertionError('nonmonotonic journal accepted')
    state = dict(work_j=100, seconds=5, distance_m=20, tss=.1,
                 resume=dict(daily=dict(work=100, tss=.1, revision=50)))
    assert_unchanged_counters(state, json.loads(json.dumps(state)))
    doubled = json.loads(json.dumps(state)); doubled['resume']['daily']['work'] = 200
    try:
        assert_unchanged_counters(state, doubled)
    except AssertionError:
        pass
    else:
        raise AssertionError('double daily credit accepted')
    controls = [dict(name='a', rect=[1, 1, 10, 10]), dict(name='b', rect=[20, 1, 10, 10])]
    assert_layout(controls, ['a', 'b'], (100, 100))
    controls[1]['rect'] = [5, 1, 10, 10]
    try:
        assert_layout(controls, ['a', 'b'], (100, 100))
    except AssertionError:
        pass
    else:
        raise AssertionError('overlapping controls accepted')
    killed = datetime(2026, 9, 28, 0, 0, 0, 250000).timestamp()
    assert abs(killed-journal_wall_time('23:59:59.750', killed)-.5) < .001
    assert abs(killed-journal_wall_time('2026-09-27T23:59:59.750', killed)-.5) < .001
    record = dict(Timestamp='23:59:59.750', ElapsedSec='42.3', TimerActive='1',
                  IsMoving='1', Speed_kmh='28.8')
    checkpoint = dict(journal_elapsed=42.0, resume=dict(workout=dict(state=2),
                      daily=dict(day=46292, source='fixture', revision=10, work=100, tss=.25)))
    measured = active_loss_measurements([record], checkpoint, killed-.7, killed)
    assert abs(measured['journal_last_age_seconds']-.5) < .001
    for bad_record, bad_mtime in ((dict(record, Timestamp='23:59:57.000'), killed-.7),
                                  (record, killed-5.01),
                                  (dict(record, TimerActive='0'), killed-.7)):
        try:
            active_loss_measurements([bad_record], checkpoint, bad_mtime, killed)
        except AssertionError:
            pass
        else:
            raise AssertionError('stale/stopped active-kill fixture accepted')
    daily = dict(days=[dict(day=46292, source='fixture', revision=12, work_j=120, tss=.3),
                       dict(day=46292, source='another-source', revision=99, work_j=999, tss=9)])
    expected = expected_active_resume(checkpoint, daily)
    assert expected['resume']['daily']['revision'] == 12
    assert expected['resume']['daily']['work'] == 120
    assert checkpoint['resume']['daily']['work'] == 100, 'mutated original checkpoint'
    assert expected_active_resume(expected, dict(days=[])) == expected
    tail_checkpoint = dict(journal_elapsed=41, seconds=40, work_j=7600,
        distance_m=100, tss=.9, resume=dict(daily=dict(day=46292, source='fixture',
            revision=10, work=8000, tss=1, ftp=210)))
    tail_rows = [dict(ElapsedSec='40', TimerActive='1', Power_W='190', Distance_m='100'),
                 dict(ElapsedSec='42', TimerActive='1', Power_W='190', Distance_m='108')]
    ahead_daily = dict(days=[dict(day=46292, source='fixture', revision=50, work_j=8100, tss=1)])
    recovered = expected_active_resume(tail_checkpoint, ahead_daily, tail_rows)
    assert recovered['work_j'] == 7790 and recovered['seconds'] == 41
    assert recovered['distance_m'] == 104 and recovered['resume']['daily']['work'] == 8190
    assert recovered['resume']['daily']['revision'] == 50
    assert_active_resume(recovered, json.loads(json.dumps(recovered)))
    doubled_tail = json.loads(json.dumps(recovered)); doubled_tail['work_j'] += 190
    try:
        assert_active_resume(recovered, doubled_tail)
    except AssertionError:
        pass
    else:
        raise AssertionError('replayed tail credited twice')
    print('PASS CPU: journal/counter/layout oracles, active-loss bounds, midnight and durable revisions')


if __name__ == '__main__':
    main()

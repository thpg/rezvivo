"""Opt-in exact-phase checks of the real, GPU-animated companion riders."""
import argparse
import json
import math
import time
from pathlib import Path
from McpHarness import GameSession, GPULock, write_sim_fit
from RideRecoveryFocusMcpTest import wait_for


def flexion(joints, a, b, c):
    u = [x-y for x, y in zip(joints[a], joints[b])]
    v = [x-y for x, y in zip(joints[c], joints[b])]
    dot = sum(x*y for x, y in zip(u, v))
    lengths = math.sqrt(sum(x*x for x in u)*sum(x*x for x in v))
    return 180-math.degrees(math.acos(max(-1, min(1, dot/lengths))))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--exe', default='castle-engine-output/performance-release/third_person_navigation.exe')
    parser.add_argument('--out', default='tests/artifacts/bot-fit-20261006/live')
    parser.add_argument('--smoke', action='store_true', help='Only live movement/replay and screenshots')
    args = parser.parse_args()
    game = Path(__file__).resolve().parents[1]
    out = game/args.out
    out.mkdir(parents=True, exist_ok=True)
    fit = out/'steady.fit'
    write_sim_fit(fit, 1800, 210)
    report = {}

    def save():
        (out/'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')

    with GPULock(), GameSession(game, out/'profile',
            dict(fps_limit=60, msaa=0, grass=1, vegetation_quality=1),
            executable=args.exe) as app:
        app.setting('AudioMaster', 0)
        app.setting('SimulationFitPath', str(fit))
        app.setting('SimulationUseRoute', False)
        app.setting('SimulationEnabled', True)
        app.call('dream.inspect', open=True, select=0)
        wait_for(lambda: app.call('dream.inspect'), lambda s: s.get('page', {}).get('ready'), 180)
        start = time.monotonic()
        app.call('dream.start')
        roster = wait_for(lambda: app.call('bots.local'), lambda s: s.get('ready'), 240)
        report['prepare_seconds'] = time.monotonic()-start
        report['roster'] = roster
        save()
        assert all(b['model_loaded'] for b in roster['bots']), 'Missing bot models'
        app.call('sim.play')
        app.call('ride.start')
        time.sleep(4)
        app.call('sim.pause')
        samples = []
        report['samples'] = samples
        for bot in ([] if args.smoke else roster['bots']):
            for pose in (0, 3, 4, 1):
                row = dict(index=bot['index'], name=bot['name'], pose=pose,
                           body=bot['body'], fit=bot['fit'], phases=[])
                samples.append(row)
                for phase in range(24):
                    s = app.call('bike.motion_sample', bot_index=bot['index'], pose_index=pose,
                                 phase=phase/24, cadence=85, effort=.7, body_dynamics=False)['sample']
                    j = s['joints']
                    knees = [flexion(j, side+'Thigh', side+'Calf', side+'Foot') for side in ('R_', 'L_')]
                    elbows = [flexion(j, side+'Upperarm', side+'Forearm', side+'Hand') for side in ('R_', 'L_')]
                    row['phases'].append(dict(phase=phase/24, knees=knees, elbows=elbows, sample=s))
                row['min_knee'] = min(min(p['knees']) for p in row['phases'])
                row['max_knee'] = max(max(p['knees']) for p in row['phases'])
                row['max_contact_error'] = max(max(p['sample']['contact_error_m']) for p in row['phases'])
                print('FIT', row['name'], pose, row['body']['heightCm'], round(row['min_knee'], 2),
                      round(row['max_knee'], 2), round(row['max_contact_error'], 5), flush=True)
                save()
                if pose == 0:
                    assert 33 <= row['min_knee'] <= 37, row['min_knee']
                    assert row['max_contact_error'] < .002, row['max_contact_error']
                elif pose in (3, 4):
                    assert 25 <= row['min_knee'] <= 42, row['min_knee']

        current = app.call('bots.local')
        visible = next(b for b in current['bots'] if b['visible'])
        p = visible['visibility_position']
        app.call('camera.chase', active=False)
        heading = visible['heading']
        side = [heading[2], 0, -heading[0]]
        for label, offsets in [('side', (0, 1.4, 3.6)), ('rear', (-3.5, 1.5, .2)), ('oblique', (-2.6, 2.3, 2.6))]:
            along, height, across = offsets
            off = [heading[i]*along+side[i]*across for i in range(3)]
            off[1] = height
            target = [p[0], p[1]+.9, p[2]]
            camera = [p[i]+off[i] for i in range(3)]
            direction = [target[i]-camera[i] for i in range(3)]
            app.call('camera.set_view', x=camera[0], y=camera[1], z=camera[2],
                     dx=direction[0], dy=direction[1], dz=direction[2])
            app.call('bike.motion_sample', bot_index=visible['index'], pose_index=0,
                     phase=.25, cadence=85, effort=.7, body_dynamics=False)
            time.sleep(.15)
            app.call('app.screenshot', path=str(out/(label+'.png')))
        report['visible'] = visible
        save()
        app.call('sim.seek', sec=1)
        before = app.call('bots.local')
        app.call('camera.chase', active=True, distance=6, height=2, aim_height=1)
        app.call('sim.play')
        time.sleep(6)
        after = app.call('bots.local')
        report['resumed'] = after
        for b, a in zip(before['bots'], after['bots']):
            assert b['fit'] == a['fit'], 'Replay changed the physical fit'
            if a['visible']:
                assert a['distance'] > b['distance']+1, 'Visible bot did not resume riding'
                assert a['ground_valid'], 'Visible bot lost wheel support'
        app.call('app.screenshot', path=str(out/'resumed.png'))
        save()
        app.call('ride.stop_full')
    print('BOT_BIKE_FIT_CAPTURED', flush=True)


if __name__ == '__main__':
    main()

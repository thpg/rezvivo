"""Fit and first companion in a real ride, including detached/culled models."""
import argparse
import json
import time
from pathlib import Path
from McpHarness import GameSession, GPULock, write_sim_fit
from RideRecoveryFocusMcpTest import wait_for
from BotBikeFitMcpTest import flexion


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--sex', type=int, choices=(0, 1), default=0)
    args = parser.parse_args()
    game = Path(__file__).resolve().parents[1]
    out = args.out.resolve(); out.mkdir(parents=True, exist_ok=True)
    fit = out/'steady.fit'; write_sim_fit(fit, 600, 210, 85)
    report = {'sex': args.sex, 'samples': []}

    def save():
        (out/'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')

    session = GameSession(game, out/'profile', dict(fps_limit=60, msaa=0,
        grass=1, vegetation_quality=1))
    session.env['REZVIVO_TEST_HIDDEN'] = '1'
    profile = session.out/'accounts/0/experience.json'
    account = json.loads(profile.read_text())
    account['avatar_body'] = dict(version=1, sex=args.sex,
        heightCm=170 if args.sex else 186, weightKg=75, composition=.65,
        inseamCm=0, armLengthCm=0, headShape=args.sex)
    profile.write_text(json.dumps(account), encoding='utf-8')
    with GPULock(), session as app:
        app.setting('AudioMaster', 0)
        app.setting('SimulationFitPath', str(fit))
        app.setting('SimulationUseRoute', False); app.setting('SimulationEnabled', True)
        app.call('dream.inspect', open=True, select=0)
        wait_for(lambda: app.call('dream.inspect'), lambda s: s.get('page', {}).get('ready'), 180)
        app.call('dream.start')
        roster = wait_for(lambda: app.call('bots.local'), lambda s: s.get('ready'), 240)
        report['roster'] = roster; save()
        first = roster['bots'][0]
        assert (first['body']['sex'] >= .5) != bool(args.sex), first
        assert len({b['catalog_index'] for b in roster['bots']}) == 7
        assert all(b['model_loaded'] and b['fit']['seatpost_mm'] > 20 for b in roster['bots'])
        app.call('sim.play'); app.call('ride.start'); time.sleep(4); app.call('sim.pause')
        # Includes all six detached models. MCP must explicitly evaluate their
        # current pose rather than returning a cached rest skeleton.
        for bot in range(-1, 7):
            row = dict(bot=bot, phases=[]); report['samples'].append(row)
            for phase in range(32):
                s = app.call('bike.motion_sample', bot_index=bot, pose_index=0,
                    phase=phase/32, cadence=85, effort=.7, body_dynamics=False)['sample']
                assert not s['last_error'], s['last_error']
                j = s['joints']
                knees = [flexion(j, side+'Thigh', side+'Calf', side+'Foot')
                         for side in ('R_', 'L_')]
                row['phases'].append(dict(knees=knees, sample=s))
            row['min_knee'] = min(min(p['knees']) for p in row['phases'])
            row['max_knee'] = max(max(p['knees']) for p in row['phases'])
            row['cleat_error_m'] = max(max(p['sample']['contact_error_m'][:2])
                                      for p in row['phases'])
            print('FIT', bot, round(row['min_knee'], 3), round(row['max_knee'], 3),
                  round(row['cleat_error_m'], 6), flush=True)
            save()
            assert 33 <= row['min_knee'] <= 37, row['min_knee']
            assert row['max_knee'] < 132, row['max_knee']
            assert row['cleat_error_m'] < .002, row['cleat_error_m']

        current = app.call('bots.local')
        assert current['bots'][0]['visible'], 'first companion is the start rider'
        report['current'] = current
        first = current['bots'][0]; p = first['visibility_position']; h = first['heading']
        side = [h[2], 0, -h[0]]
        app.call('camera.chase', active=False)
        for label, phase in [('bottom', min(range(32),
                key=lambda i: report['samples'][1]['phases'][i]['knees'][0])/32),
                ('top', min(range(32),
                key=lambda i: -report['samples'][1]['phases'][i]['knees'][0])/32)]:
            camera = [p[i]+side[i]*3.4 for i in range(3)]; camera[1] = p[1]+1.3
            d = [p[i]-camera[i] for i in range(3)]; d[1] += .95
            app.call('camera.set_view', x=camera[0], y=camera[1], z=camera[2],
                     dx=d[0], dy=d[1], dz=d[2])
            app.call('bike.motion_sample', bot_index=0, pose_index=0, phase=phase,
                     cadence=85, effort=.7, body_dynamics=False)
            time.sleep(.2); app.call('app.screenshot', path=str(out/(label+'.png')))
        app.call('sim.seek', sec=1); app.call('sim.play'); time.sleep(3)
        resumed = app.call('bots.local'); report['resumed'] = resumed
        for b, a in zip(current['bots'], resumed['bots']):
            assert b['fit'] == a['fit'], 'replay changed the fit'
        assert resumed['bots'][0]['ground_valid'], 'resumed companion lost wheel support'
        save(); app.call('ride.stop_full')
    settings = json.loads((session.out/'settings.json').read_text(encoding='utf-8-sig'))
    report['saved_fit'] = {k: v for k, v in settings['ui'].items() if k.startswith('fit_')}
    assert report['saved_fit']['fit_params'], 'initial player fit was not saved'
    save()
    print('BIKE_FIT_VISIBILITY_OK', flush=True)


if __name__ == '__main__':
    main()

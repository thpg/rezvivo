"""Stationary bicycle turn: isolated hidden game, real physics and GPU pose."""
import json
import math
import time
from pathlib import Path
from McpHarness import GameSession, GPULock
from RideRecoveryFocusMcpTest import wait_for

GAME=Path(__file__).resolve().parents[1]
OUT=GAME/'tests/artifacts/ground-turn'
EXE='castle-engine-output/performance-release/third_person_navigation.exe'

def run():
    OUT.mkdir(parents=True,exist_ok=True)
    app=GameSession(GAME,OUT/'profile',dict(fps_limit=60,msaa=2),executable=EXE)
    app.env['REZVIVO_TEST_HIDDEN']='1'
    samples=[]
    with GPULock(),app:
        app.setting('AudioMaster',0)
        app.call('travel.select',mode='walk')
        app.call('dream.inspect',open=True,select=0)
        wait_for(lambda:app.call('dream.inspect'),lambda x:x.get('page',{}).get('ready'),180)
        app.call('dream.start')
        def state():return app.call('explore.state')['travel']
        wait_for(state,lambda x:not x['preparing'],180)
        app.call('travel.select',mode='bicycle')
        app.call('app.switch_view',view='play')
        app.call('camera.chase',distance=2.8,height=1.7,side=2.5,aim_height=.95)
        time.sleep(1.5)
        before=state()
        app.call('explore.input',steer=1)
        for i in range(20):
            time.sleep(.16)
            s=state();m=app.call('bike.anim_debug')['anim']['motion']
            samples.append(dict(state=s,motion=m))
            assert s['speed']<.03 and abs(s['distance']-before['distance'])<.01,s
            assert m['pedal_rpm']==0,m
            assert not m['last_error'],m['last_error']
            if i in (1,4,8,11,14,17):
                app.call('app.screenshot',path=str(OUT/f'turn-{i:02}.png'),inline=False)
        (OUT/'samples.json').write_text(json.dumps(samples,indent=2),encoding='utf-8')
        turned=state()
        assert math.hypot(turned['forward_x']-before['forward_x'],turned['forward_z']-before['forward_z'])>.5
        active=[s['motion'] for s in samples if s['state']['ground_turn_stage']==2]
        assert active and any(max(m['step_lift'])>.03 for m in active),'No stepping'
        assert all(m['bike_lift']>.06 and m['gpu'] for m in active),active
        assert max(max(m['contact_error_m']) for m in active)<.015,'Hand or foot misses its support'
        assert min(m['joints']['R_Forearm'][2] for m in active)>.20,'Lifting elbow enters the torso'
        app.call('camera.chase',distance=2,height=1.5,side=-2.8,aim_height=.9)
        time.sleep(.25)
        app.call('app.screenshot',path=str(OUT/'opposite-side.png'),inline=False)
        app.call('camera.chase',distance=.2,height=1.3,side=2.8,aim_height=.9)
        time.sleep(.2)
        app.call('app.screenshot',path=str(OUT/'frame-grip-side.png'),inline=False)
        app.call('bike.set_gpu_anim',enabled=False)
        time.sleep(.4)
        cpu=app.call('bike.anim_debug')['anim']['motion']
        assert not cpu['gpu'] and not cpu['last_error'],cpu
        assert max(cpu['contact_error_m'])<.015,cpu['contact_error_m']
        app.call('app.screenshot',path=str(OUT/'cpu-turn.png'),inline=False)
        app.call('bike.set_gpu_anim',enabled=True)
        app.call('camera.chase',distance=2.8,height=1.7,side=2.5,aim_height=.95)
        app.call('explore.input',steer=-1)
        time.sleep(1.5)
        app.call('app.screenshot',path=str(OUT/'reversal.png'),inline=False)
        app.call('explore.input')
        wait_for(state,lambda s:s['ground_turn_stage']==0,8,'set down bicycle')
        app.call('app.screenshot',path=str(OUT/'stopped.png'),inline=False)
        for sex,height in ((1,160),(0,190)):
            app.call('bikefit.body',sex=sex,heightCm=height,inseamCm=0)
            app.call('bikefit.auto_fit')
            app.call('app.switch_view',view='play')
            app.call('explore.input',steer=1)
            wait_for(state,lambda s:s['ground_turn_stage']==2,5,'body variant turn')
            time.sleep(.4)
            m=app.call('bike.anim_debug')['anim']['motion']
            samples.append(dict(body_height=height,motion=m))
            (OUT/'variants.json').write_text(json.dumps(samples[-1],indent=2),encoding='utf-8')
            app.call('app.screenshot',path=str(OUT/f'body-{height}.png'),inline=False)
            assert max(m['contact_error_m'])<.02,(height,m['contact_error_m'])
            app.call('explore.input')
            wait_for(state,lambda s:s['ground_turn_stage']==0,8,'variant set down')
        app.call('explore.input',steer=1)
        wait_for(state,lambda s:s['ground_turn_stage']==2,4,'second turn')
        app.call('explore.input',power_axis=1)
        time.sleep(.4)
        assert state()['speed']<.03,'Started riding before putting the bike down'
        app.call('explore.input')
        departed=wait_for(state,lambda s:s['speed']>.5,12,'departure')
        assert departed['ground_turn_stage']==0 and departed['bike_lift']==0,departed
        time.sleep(1)
        app.call('app.screenshot',path=str(OUT/'riding.png'),inline=False)
        samples.append(dict(departure=departed,motion=app.call('bike.anim_debug')['anim']['motion']))
    (OUT/'samples.json').write_text(json.dumps(samples,indent=2),encoding='utf-8')
    print('PASS: left/right pivot, GPU stepping, no translation or pedal motion, release and departure')

if __name__=='__main__':run()

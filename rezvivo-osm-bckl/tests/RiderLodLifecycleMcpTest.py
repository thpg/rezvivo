"""LOD integration: native/GPU poses, live body/clothes, shadows, ride restart."""
import json,time
from pathlib import Path
from McpHarness import GameSession,GPULock,write_sim_fit
from RideRecoveryFocusMcpTest import wait_for
from TravelWardrobeMcpTest import ready

GAME=Path(__file__).resolve().parents[1]
OUT=GAME/'tests/artifacts/rider-lod-20261012/lifecycle'

def main():
    OUT.mkdir(parents=True,exist_ok=True);fit=OUT/'steady.fit';write_sim_fit(fit,300,180)
    s=GameSession(GAME,OUT/'profile',dict(fps_limit=60,msaa=4,cinematic_softening=0),
        executable='castle-engine-output/performance-release/third_person_navigation.exe')
    s.env['REZVIVO_TEST_HIDDEN']='1';s.env['REZVIVO_TEST_TRACE_EXCEPTIONS']='1';rows=[]
    def save(): (OUT/'report.json').write_text(json.dumps(rows,indent=2),encoding='utf-8')
    def capture(app,name):
        time.sleep(.4);state=app.call('bike.anim_debug')['anim']
        assert state['motion']['lod']['parts']>0,state
        rows.append(dict(name=name,state=state));save()
        app.call('app.screenshot',path=str(OUT/(name+'.png')),inline=False)
    with GPULock(),s as app:
        app.setting('AudioMaster',0);app.setting('SimulationFitPath',str(fit))
        app.setting('SimulationUseRoute',False);app.setting('SimulationEnabled',True)
        for cycle in range(2):
            app.call('dream.inspect',open=True,select=0)
            wait_for(lambda:app.call('dream.inspect'),lambda x:x.get('page',{}).get('ready'),180)
            app.call('dream.start');wait_for(lambda:app.call('bots.local'),lambda x:x.get('ready'),240)
            app.call('bots.local',limit=0,render=False)
            app.call('sim.play');time.sleep(1);app.call('sim.pause')
            app.call('perf.set',terrain=False,shadows=False,anim=True)
            if cycle==0:
                for native in [True,False]:
                    app.call('bike.set_gpu_anim',enabled=not native)
                    app.call('bike.motion_sample',pose_index=4,phase=.25,look_yaw=0,
                        cadence=80,time=1.25,effort=.6)
                    app.call('camera.chase',distance=.5,side=14,height=2.3,aim_height=1)
                    for lod in [0,1,2]:
                        app.call('bike.anim_debug',lod=lod);capture(app,f'native-{native}-lod{lod}')
                        assert rows[-1]['state']['gpu_anim']==(not native),rows[-1]
                app.call('bikefit.body',sex=.4,heightCm=195,weightKg=95,composition=.7);ready(app)
                app.call('app.switch_view',view='play')
                app.call('bike.motion_sample',pose_index=0,phase=.25,look_yaw=0,cadence=80,time=1.25)
                for lod in [0,1,2]:
                    app.call('bike.anim_debug',lod=lod);capture(app,f'body-edited-lod{lod}')
                app.call('bikefit.clothing',top='tshirt',bottom='jeans',outer='jacket',feet='sneakers');ready(app)
                app.call('app.switch_view',view='play');capture(app,'clothing-reloaded')
                app.call('bikefit.clothing',top='',bottom='',outer='',feet='');ready(app)
                app.call('app.switch_view',view='play');capture(app,'clothing-restored')
            app.call('bike.anim_debug',lod=-1);app.call('perf.set',terrain=True,shadows=True)
            for distance,level in [(5,0),(14,1),(32,2),(14,1),(5,0)]:
                app.call('camera.chase',distance=distance,side=0,height=2.3,aim_height=1)
                capture(app,f'cycle{cycle}-world-d{distance}-{len(rows)}')
                assert rows[-1]['state']['motion']['lod']['auto_level']==level,rows[-1]
            app.call('ride.stop_full');print('RIDER_LOD_LIFECYCLE',cycle,'OK',flush=True)
    print('RIDER_LOD_LIFECYCLE_OK',flush=True)

if __name__=='__main__':main()

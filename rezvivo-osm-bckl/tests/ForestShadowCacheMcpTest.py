"""Standing Krylatskoye riders: live near shadows and one distant forest cache."""
import json,time,sys
from pathlib import Path
from McpHarness import GameSession,GPULock
from GpuLoad import GpuLoad
from RideRecoveryFocusMcpTest import wait_for

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'tests/artifacts/forest-shadow-20261012'
if '--movement-only' in sys.argv:OUT=OUT/'movement'
OUT.mkdir(parents=True,exist_ok=True)
rows=[]
app=GameSession(ROOT,OUT/'profile',native_api=True,
    executable='castle-engine-output/performance-release/third_person_navigation.exe',
    graphics=dict(fps_limit=0,msaa=0,shadow_size=2048,shadow_filter=4,
        shadow_distance=100,vegetation_quality=4,vegetation_adaptive=0,
        cinematic_softening=0,world_shadow_backend=1,rtx_reflections=1))
app.env.update(REZVIVO_TEST_HIDDEN='1',REZVIVO_OFFLINE='1')
with GPULock(),app:
    gpu=GpuLoad()
    try:
        app.setting('AudioMaster',0)
        app.call('app.switch_view',view='routes')
        state=app.call('menu.inspect')['routes']
        item=next(i for i in state['ready_routes']['items'] if 'krylatsk' in i['id'])
        path=app.out/'accounts/ready-routes/objects'/(item['sha256']+'.gpx')
        app.call('ride.load_fit',path=str(path))
        wait_for(lambda:app.call('perf.state'),lambda s:s.get('prep_done'),240,'route ready')
        app.call('sim.pause');app.call('camera.chase',distance=5,height=2.4,aim_height=1)
        app.call('app.fps_mode',mode='max')
        time.sleep(12)
        for mode in ((2,) if '--movement-only' in sys.argv else (1,2,0)):
            app.setting('GraphicsWorldShadows',mode)
            if mode==2:
                wait_for(lambda:app.call('perf.state'),lambda s:s['rtx'].get('used_this_frame'),180,'RTX ready')
            for age in ((0,) if '--movement-only' in sys.argv else (0,6,16)):
                if age:time.sleep(6 if age==6 else 10)
                s=app.call('perf.state')
                assert not s['rtx'].get('failed') and not s['rtx'].get('error'),s['rtx']
                if mode:assert s['rtx']['far_forest_ready'] and s['rtx']['live_tree_cascades']==3,s['rtx']
                app.call('app.screenshot',path=str(OUT/f'{mode}-{age}.png'),inline=False)
                row=dict(mode=mode,age=age,state=s,camera=app.call('camera.sample'),gpu=gpu.sample(app.process.pid))
                if age==16 and mode:
                    app.call('perf.render_stability',frames=45,x=450,y=120,width=300,height=240)
                    probe=wait_for(lambda:app.call('perf.render_stability'),lambda r:r['remaining']==0,30,'shadow motion')
                    row['near_shadow_motion']=probe
                    assert any(x['changed_fraction']>.0001 for x in probe['samples'][1:]),'near shadows froze'
                    assert s['rtx']['far_forest_reuses']>s['rtx']['far_forest_captures']*5,s['rtx']
                    assert s['rtx'].get('individual_tree_bakes',0)==0,s['rtx']
                rows.append(row)
                (OUT/'result.json').write_text(json.dumps(rows,indent=2),encoding='utf-8')
                print('CAPTURE',mode,age,json.dumps(s['rtx']),flush=True)
            app.call('perf.capture',action='start',reset=True);time.sleep(4)
            rows[-1]['performance']=app.call('perf.capture',action='stop')
        # Resizing shadows invalidates storage safely; near trees remain live.
        app.setting('GraphicsWorldShadows',1);app.setting('GraphicsShadowSize',4096)
        time.sleep(3)
        s=app.call('perf.state');assert s['rtx']['far_forest_size']==2048,s['rtx']
        rows.append(dict(resized=s))
        app.call('camera.chase',active=False)
        pose=app.call('camera.sample')
        (OUT/'movement-camera.json').write_text(json.dumps(pose,indent=2))
        p=pose['viewport_pos'];d=pose['viewport_dir']
        if p and d:
            for shift in (2,35,-35,0):
                app.call('camera.set_view',x=p[0]+shift,y=p[1],z=p[2],dx=d[0],dy=d[1],dz=d[2])
                time.sleep(1)
                app.call('app.screenshot',path=str(OUT/f'move-{shift}.png'),inline=False)
                rows.append(dict(shift=shift,state=app.call('perf.state')))
        app.call('app.switch_view',view='settings');time.sleep(2)
        app.call('app.switch_view',view='play');time.sleep(2)
        app.call('app.screenshot',path=str(OUT/'menu-return.png'),inline=False)
        (OUT/'result.json').write_text(json.dumps(rows,indent=2),encoding='utf-8')
        app.call('ride.stop_full')
    finally:gpu.close()
print('PASS forest shadow cache',flush=True)

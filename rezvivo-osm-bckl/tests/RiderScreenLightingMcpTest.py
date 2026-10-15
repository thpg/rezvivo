"""RTX visibility must remove sunlight, without darkening sky or retaining sun gloss.

Compare against a zero-intensity sun, not a subjective screenshot threshold.
Controlled visibility is substituted only in this disposable process. Also
exercise real visibility, world-cache reuse, post-processing and render cost.
"""
import argparse
import json
from pathlib import Path
import time

import numpy as np
from PIL import Image, ImageFilter
from McpHarness import GameSession, GPULock, write_sim_fit
from RtxScreenRideMcpTest import wait
from GpuLoad import GpuLoad
from RideRecoveryFocusMcpTest import NativeUI, wait_for

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--performance', action='store_true')
    parser.add_argument('--gate', action='store_true')
    parser.add_argument('--gate-only', action='store_true')
    args = parser.parse_args()
    args.gate = args.gate or args.gate_only
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=True)
    rows = []
    session = GameSession(ROOT, out/'profile', dict(fps_limit=60, msaa=0,
        shadow_size=2048, shadow_filter=4, grass=0, vegetation_quality=0,
        world_shadow_backend=3, rtx_reflections=0, cinematic_softening=0))
    session.env['REZVIVO_TEST_HIDDEN'] = '1'
    if args.gate:
        workouts=session.out/'accounts/0/workouts'; workouts.mkdir(exist_ok=True)
        (workouts/'lighting-gate.zwo').write_text('''<workout_file><author>REZVIVO test</author>
<name>Screen lighting gate</name><sportType>bike</sportType><workout>
<SteadyState Duration="24" Power="0.7"/><SteadyState Duration="120" Power="1.0"/>
</workout></workout_file>''', encoding='utf-8')
    with GPULock(), session as app:
        fit = out/'steady.fit'; write_sim_fit(fit, 900, 210, 85)
        app.setting('AudioMaster', 0)
        app.setting('SimulationFitPath', str(fit)); app.setting('SimulationUseRoute', False)
        app.setting('SimulationEnabled', True)
        app.call('dream.inspect', open=True, select=0)
        wait(app, 'dream.inspect', lambda r: r.get('page', {}).get('ready'))
        app.call('dream.start')
        wait(app, 'perf.state', lambda r: r.get('active') and r.get('prep_done'))
        app.call('sim.play'); app.call('ride.start')
        wait(app, 'bots.local', lambda r: r.get('ready'))
        app.call('bots.local', limit=0, render=False)
        wait(app, 'perf.state', lambda r: r.get('rtx', {}).get('screen_frames', 0)>10)
        app.call('sim.pause'); app.call('bike.anim_debug', lod=0)
        anchor = np.array([-204.83638, 1., -42.504169])
        facing = np.array([1., 0., 0.])
        pos = anchor + np.array([-1.8, 1.65, -1.4])
        target = anchor + np.array([0., 1.1, 0.])
        app.call('camera.set_view', **dict(zip(['x','y','z','dx','dy','dz'], [*pos, *(target-pos)])))

        def pose():
            app.call('bike.motion_sample', pose_index=0, phase=.35, breath=.25,
                breath_load=1., effort=1., cadence=85., time=10.,
                anchor=anchor.tolist(), facing=facing.tolist())

        def capture(label):
            pose(); time.sleep(.35); pose(); time.sleep(.15)
            path = out/(label+'.png')
            app.call('app.screenshot', path=str(path), inline=False)
            return np.asarray(Image.open(path).convert('RGB'), dtype=float)

        def install(effect, source, label):
            path=out/(label+'-'+effect+'.fs'); path.write_text(source, encoding='utf-8')
            app.call('perf.rider_render', shader_effect=effect, shader_stage='fragment', shader_file=str(path))

        def save():
            (out/'results.json').write_text(json.dumps(rows, indent=2))

        sources = {}
        for effect in ['RiderGroundShade', 'RiderSkinSurface', 'RiderProceduralFabric']:
            path=out/(effect+'.fs')
            app.call('perf.rider_render', shader_effect=effect, shader_stage='fragment', save_shader_file=str(path))
            sources[effect]=path.read_text(encoding='utf-8-sig')
        sun = sources['RiderGroundShade']
        sample = 'texture2D(riderScreenShadow,uv).r'
        assert sample in sun
        app.call('perf.set', shadows=False)
        masks = {}
        for effect in ['RiderSkinSurface', 'RiderProceduralFabric']:
            install(effect, sources[effect]+'\nvoid PLUG_fragment_end(inout vec4 c){c=vec4(1,0,1,1);}\n', 'mask')
            image=capture('mask-'+effect)
            mask=(image[:,:,0]>245)&(image[:,:,1]<5)&(image[:,:,2]>245)
            mask=np.asarray(Image.fromarray(mask.astype('uint8')*255).filter(ImageFilter.MinFilter(7)))>0
            assert 1500<mask.sum()<image.shape[0]*image.shape[1]*.3, (effect,int(mask.sum()))
            masks[effect]=mask
            install(effect, sources[effect], 'restored')

        for tone in ([] if args.gate_only else [False, True]):
            app.call('fx.configure', enabled=True, tone=tone, bloom=False, fog=False, softening=0)
            for visibility in [0, .5, 1]:
                app.call('perf.set', shadows=False)
                install('RiderGroundShade', 'void PLUG_light_scale(inout float scale,const vec3 N,const vec3 L){scale*='+f'{visibility:.2f}'+';}\n', 'sun-reference')
                reference=capture(f'reference-tone{int(tone)}-sun{visibility}')
                install('RiderGroundShade', sun.replace(sample, f'{1-visibility:.2f}'), 'controlled-visibility')
                app.call('perf.set', shadows=True)
                for cache in [0, 1]:
                    app.setting('GraphicsWorldCache', cache)
                    if cache:
                        wait(app, 'perf.state', lambda r:r.get('world_cache',{}).get('used_this_frame'))
                    image=capture(f'controlled-tone{int(tone)}-sun{visibility}-cache{cache}')
                    state=app.call('perf.state')
                    assert state['world_cache']['screen_material_riders']==1, state['world_cache']
                    assert state['rtx']['raster_passes']==0 and not state['rtx']['failed'], state['rtx']
                    for effect, mask in masks.items():
                        delta=np.abs(reference[mask]-image[mask])
                        row=dict(test='sun-reference',tone=tone,sun=visibility,cache=cache,
                            material=effect,pixels=int(mask.sum()),mean_rgb=float(delta.mean()),
                            p99_rgb=float(np.quantile(delta,.99)),max_rgb=float(delta.max()))
                        rows.append(row); save()
                        assert row['mean_rgb']<.35 and row['p99_rgb']<=2, row
            app.setting('GraphicsWorldCache', 0)

        install('RiderGroundShade', sun, 'sun-restored')
        app.call('fx.configure', tone=False)
        app.call('perf.set', shadows=False)
        unshadowed=capture('unshadowed')
        app.call('perf.set', shadows=True)
        for cache in ([] if args.gate_only else [0, 1]):
            app.setting('GraphicsWorldCache', cache)
            if cache:
                wait(app, 'perf.state', lambda r:r.get('world_cache',{}).get('used_this_frame'))
            for physical in [False, True]:
                app.call('perf.set', rtx_rider_lighting=physical)
                image=capture(f'real-cache{cache}-physical{int(physical)}')
                mask=masks['RiderSkinSurface']
                darker=unshadowed[mask].mean(axis=1)-image[mask].mean(axis=1)
                row=dict(test='real-shadow',cache=cache,physical=physical,
                    shadowed_skin_pixels=int((darker>5).sum()),max_darkening=float(darker.max()),
                    state=app.call('perf.state'))
                rows.append(row); save()
                assert row['shadowed_skin_pixels']>100, row
        if args.performance:
            # Same paused camera and poses, three extra riders.
            # ABBA order plus per-process GPU counters exposes outside load.
            app.call('perf.shadow_test_riders', count=3, zones=False)
            app.call('camera.chase', distance=8, height=3, aim_height=1.1)
            app.call('app.fps_mode', mode='max')
            gpu=GpuLoad()
            try:
                for cache in [0, 1]:
                    app.setting('GraphicsWorldCache', cache)
                    for physical in [False, True, True, False]:
                        app.call('perf.set', rtx_rider_lighting=physical)
                        time.sleep(2)
                        app.call('perf.capture', action='start'); loads=[]
                        for _ in range(4):
                            time.sleep(.75); loads.append(gpu.sample(app.process.pid))
                        row=dict(test='performance',cache=cache,physical=physical,gpu_load=loads,
                            perf=app.call('perf.capture',action='stop'),state=app.call('perf.state'))
                        rows.append(row); save()
                        print('PERF',cache,physical,flush=True)
            finally:
                gpu.close()
        app.call('perf.set', rtx_rider_lighting=True)
        app.setting('GraphicsMSAA', 4)
        app.setting('GraphicsRtxReflections', 1)
        app.call('app.fps_mode', mode='settings')
        app.call('sim.play'); app.call('ride.start'); time.sleep(2)
        app.call('app.screenshot',path=str(out/'ride.png'),inline=False)
        assert not app.call('perf.state')['rtx']['failed']
        if args.gate:
            ui=NativeUI(app)
            ui.key(0x1B); app.call('app.switch_view',view='training'); ui.click('WorkoutFilter3')
            controls=wait_for(ui.controls,lambda cs:any(c['caption']=='Screen lighting gate' for c in cs))
            card=next(c for c in controls if c['caption']=='Screen lighting gate' and c['name'].startswith('WorkoutDetails'))
            ui.click(card['name']); ui.click('StartDetailedWorkout')
            state=wait_for(lambda:app.call('workout.inspect'),
                lambda r:r['gates']['upcoming']['visible'] and
                    r['gates']['upcoming']['opacity']>.95 and
                    .2<r['gates']['upcoming']['remaining']<.7,
                30,'nearby gate')
            app.call('sim.pause')
            # Keep the rider at its real route position. Moving its transform
            # also relocates the predictive gate on the next update.
            camera=app.call('camera.sample')
            anchor=np.array(camera['avatar_pos']); facing=np.array(camera['avatar_dir'])
            gate=state['gates']['upcoming']; forward=np.array(gate['forward'])
            forward[1]=0; forward/=np.linalg.norm(forward)
            gate_pos=np.array(gate['position'])
            pos=gate_pos+forward*1.5+np.array([0,1.5,0])
            target=anchor+np.array([0,1.1,0])
            app.call('camera.set_view',**dict(zip(['x','y','z','dx','dy','dz'],[*pos,*(target-pos)])))
            for effect in masks:
                install(effect,sources[effect]+'\nvoid PLUG_fragment_end(inout vec4 c){c=vec4(1,0,1,1);}\n','gate-mask')
            for physical in [False,True]:
                app.call('perf.set',rtx_rider_lighting=physical)
                image=capture('gate-physical'+str(int(physical)))
                # A green/yellow translucent film must tint magenta skin and
                # cloth. If it is drawn before the late opaque rider pass,
                # those pixels incorrectly remain pure magenta (green=0).
                tinted=(image[:,:,0]>190)&(image[:,:,2]>190)&(image[:,:,1]>2)&(image[:,:,1]<60)
                count=int(tinted.sum())
                rows.append(dict(test='transparent-gate',physical=physical,tinted_pixels=count,gate=gate));save()
                assert count>1000,(physical,count)
            for effect in masks: install(effect,sources[effect],'gate-restored')
            app.call('perf.set',rtx_rider_lighting=True)
            capture('gate-rider')
    print('PASS transparent gate' if args.gate_only else
        'PASS linear sun visibility, preserved sky, cache and post tone', flush=True)


if __name__=='__main__':
    main()

"""Render-only probe: skin has no specular contribution but still receives shadows.

Diagnostic shader substitutions exist only in the isolated MCP process. A glossy
positive control checks that the specular-only view can actually detect reflection.
"""
import argparse
import json
from pathlib import Path
import re
import time

import numpy as np
from PIL import Image, ImageFilter
from McpHarness import GameSession, GPULock, write_sim_fit
from RtxScreenRideMcpTest import wait

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--executable', default='third_person_navigation.exe')
    args = parser.parse_args()
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=True)
    results = {}
    session=GameSession(ROOT, out/'profile', dict(fps_limit=60, msaa=0,
            shadow_size=2048, shadow_filter=4, grass=0, vegetation_quality=0,
            world_shadow_backend=3, rtx_reflections=1, cinematic_softening=0), executable=args.executable)
    session.env['REZVIVO_TEST_HIDDEN']='1'
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
        wait(app, 'perf.state', lambda r: r.get('rtx', {}).get('reflection_frames', 0)>5)
        app.call('sim.pause'); app.call('bike.anim_debug', lod=0)
        app.call('perf.set', shadows=False)
        anchor=np.array([-204.83638,1.,-42.504169]); facing=np.array([0.,0.,1.])
        pos=anchor+np.array([-.85,1.65,1.25]); target=anchor+np.array([0.,1.15,.35])
        app.call('camera.set_view', **dict(zip(['x','y','z','dx','dy','dz'], [*pos,*(target-pos)])))

        def pose():
            app.call('bike.motion_sample', pose_index=0,phase=.35,breath=.25,
                     breath_load=1.,effort=1.,cadence=85.,time=10.,
                     anchor=anchor.tolist(),facing=facing.tolist())

        def capture(name):
            pose(); time.sleep(.25); pose(); time.sleep(.25)
            path=out/(name+'.png')
            app.call('app.screenshot',path=str(path),inline=False)
            return np.asarray(Image.open(path).convert('RGB'),dtype=float)

        def install(effect, source, name):
            path=out/(name+'.fs'); path.write_text(source,encoding='utf-8')
            app.call('perf.rider_render',shader_effect=effect,shader_stage='fragment',shader_file=str(path))

        sources={}
        for effect in ['RiderSkinSurface','RiderSkyIrradiance']:
            path=out/(effect+'.fs')
            app.call('perf.rider_render',shader_effect=effect,shader_stage='fragment',save_shader_file=str(path))
            sources[effect]=path.read_text(encoding='utf-8-sig')
        skin=sources['RiderSkinSurface']; sky=sources['RiderSkyIrradiance']
        before=capture('matte-no-shadows')
        install('RiderSkinSurface',skin+'\nvoid PLUG_fragment_end(inout vec4 c){c=vec4(1,0,1,1);}\n','skin-mask')
        image=capture('skin-mask')
        mask=(image[:,:,0]>245)&(image[:,:,1]<5)&(image[:,:,2]>245)
        mask=np.asarray(Image.fromarray(mask.astype('uint8')*255).filter(ImageFilter.MinFilter(7)))>0
        assert mask.sum()>3000, ('Skin mask too small',int(mask.sum()))
        # Remove diffuse irradiance and skin diffusion; retain actual specular
        # code and material filtering. No final-colour override in this pass.
        probe=skin.replace('{spec*=rsEye;}', '{diff=vec3(0.0);spec*=rsEye;}',1)
        probe=re.sub(r'^.*light\+=rsAlbedo.*$', '',probe,flags=re.MULTILINE)
        assert probe!=skin
        sky_probe=sky.replace('vec3 diff=diffuseColor*irradiance/3.14159265;',
                              'vec3 diff=vec3(0.0);')
        assert sky_probe!=sky
        install('RiderSkyIrradiance',sky_probe,'sky-specular-only')
        install('RiderSkinSurface',probe,'skin-specular-only')
        matte=capture('matte-specular-only')
        control=probe.replace('spec*=rsEye;', 'spec*=1.0;').replace('r=mix(1.0,0.22,rsEye)','r=0.54')
        install('RiderSkinSurface',control,'glossy-control')
        glossy=capture('glossy-specular-control')
        results.update(skin_pixels=int(mask.sum()),matte_specular_mean=float(matte[mask].mean()),
                       matte_specular_max=float(matte[mask].max()),glossy_control_mean=float(glossy[mask].mean()))
        (out/'results.json').write_text(json.dumps(results,indent=2))
        assert results['matte_specular_max']<=1,results
        assert results['glossy_control_mean']>3,results
        install('RiderSkyIrradiance',sky,'sky-restored')
        install('RiderSkinSurface',skin,'skin-restored')
        app.call('perf.set',shadows=True,world_shadows=True)
        state=wait(app,'perf.state',lambda r:r.get('rtx',{}).get('active') and r['rtx'].get('screen_ready'))
        shadowed=capture('matte-rtx-reflections')
        darker=before[mask].mean(axis=1)-shadowed[mask].mean(axis=1)
        results.update(shadow_darkened_pixels=int((darker>5).sum()),shadow_max_darkening=float(darker.max()),rtx=state['rtx'])
        app.setting('GraphicsRtxReflections',0)
        without_reflection=capture('matte-rtx-no-reflections')
        delta=np.abs(shadowed[mask]-without_reflection[mask])
        results.update(reflection_toggle_mean_rgb=float(delta.mean()),reflection_toggle_p99_rgb=float(np.quantile(delta,.99)))
        (out/'results.json').write_text(json.dumps(results,indent=2))
        assert results['shadow_darkened_pixels']>100,results
        assert results['reflection_toggle_mean_rgb']<1,results
        app.setting('GraphicsRtxReflections',1)
        app.call('perf.shadow_test_riders',count=3,zones=False)
        app.call('camera.chase',distance=9,height=3.2,aim_height=1.1)
        app.call('sim.play');app.call('ride.start');time.sleep(2)
        app.call('app.screenshot',path=str(out/'riders.png'),inline=False)
    print('PASS matte skin, positive specular control, shadows and RTX reflection toggle',flush=True)


if __name__=='__main__':
    main()

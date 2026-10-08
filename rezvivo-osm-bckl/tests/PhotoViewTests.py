"""Known-camera recovery, held-out geometry, and persistence of photo views."""
import argparse
import copy
import json
import math
from pathlib import Path
import subprocess


def fixture():
    camera = dict(latitude=55.74324, longitude=37.58548, elevation_m=152,
                  scale_latitude_deg=55.7, heading_deg=25, pitch_deg=4,
                  roll_deg=1.2, vertical_fov_deg=58, aspect_ratio=4/3)
    view = dict(id='garden-reference', source_id='photo:reference', label='Calibration fixture',
                status='draft', confidence=.3, camera=camera,
                image=dict(width_px=1280, height_px=960, projection='perspective', crop=[0,0,1,1]),
                anchors=[], regions=[], known_parameters=[])
    h, p, r = (math.radians(camera[k]) for k in ('heading_deg','pitch_deg','roll_deg'))
    direction = [-math.sin(h)*math.cos(p), math.sin(p), math.cos(h)*math.cos(p)]
    right = [-math.cos(h), 0, -math.sin(h)]
    up = [math.sin(h)*math.sin(p), math.cos(p), -math.cos(h)*math.sin(p)]
    roll_up = [a*math.cos(r)+b*math.sin(r) for a,b in zip(up,right)]
    roll_right = [a*math.cos(r)-b*math.sin(r) for a,b in zip(right,up)]
    mpd = 6371000*math.pi/180
    for i, (x,y,z) in enumerate([(-12,-8,40),(12,-6,42),(-10,10,46),(16,11,50),
                                (-6,-4,65),(19,-8,70),(-22,8,85),(0,16,90)]):
        q = [roll_right[j]*x+roll_up[j]*y+direction[j]*z for j in range(3)]
        view['anchors'].append(dict(id=f'anchor-{i}', description='Surveyed calibration point',
            osm_ref=dict(type='node', id=str(9007199254741000+i)),
            latitude=camera['latitude']+q[2]/mpd,
            longitude=camera['longitude']-q[0]/(mpd*math.cos(math.radians(camera['scale_latitude_deg']))),
            elevation_m=camera['elevation_m']+q[1],
            image_uv=[.5+x/(2*z*math.tan(math.radians(58)/2)*(4/3)), .5-y/(2*z*math.tan(math.radians(58)/2))],
            role='fit' if i<7 else 'check', basis='surveyed'))
    return view


def main():
    ap=argparse.ArgumentParser(); ap.add_argument('probe',type=Path); ap.add_argument('out',type=Path)
    args=ap.parse_args(); out=args.out.resolve(); out.mkdir(parents=True,exist_ok=True)
    tests=[]
    def call(name, action, view, error=False, **kw):
        request=dict(action=action,view=view,**kw); f=out/(name+'-request.json')
        f.write_text(json.dumps(request),encoding='utf-8')
        p=subprocess.run([str(args.probe.resolve()),str(f)],capture_output=True,timeout=25)
        response=json.loads(p.stdout.decode('utf-8-sig'))
        (out/(name+'.json')).write_text(json.dumps(response,indent=2),encoding='utf-8')
        assert (p.returncode!=0)==error,(name,p.returncode,response)
        return response
    view=fixture(); p=call('ground-truth','project',view)
    assert p['rms_px']<.003,p
    tests.append('Independent pinhole projection including roll and geographic longitude convention')
    noisy=copy.deepcopy(view)
    noisy['camera'].update(latitude=view['camera']['latitude']+.00002,longitude=view['camera']['longitude']-.00002,
        elevation_m=153,heading_deg=29,pitch_deg=6,roll_deg=-.4,vertical_fov_deg=62)
    solved=call('recover','solve',noisy)
    assert solved['solved'] and solved['projection']['rms_px']<.1,solved
    assert abs(solved['view']['camera']['elevation_m']-152)<.05
    assert len(solved['candidates'])==3
    tests.append('Recovery of seven perturbed camera parameters from several starting hypotheses')
    changed=copy.deepcopy(noisy); changed['anchors'][-1]['elevation_m']+=8
    bad=call('held-out-roof','solve',changed)
    a=solved['view']['camera']; b=bad['view']['camera']
    assert a==b and bad['projection']['points'][-1]['error_px']>30
    tests.append('Wrong check-only roof elevation remains visible and cannot move the fitted camera')
    fixed=copy.deepcopy(noisy); fixed['camera']['elevation_m']=152
    fixed['known_parameters']=['elevation_m','roll_deg']
    s=call('locked','solve',fixed)
    for field in fixed['known_parameters']: assert s['view']['camera'][field]==fixed['camera'][field]
    tests.append('Known camera parameters stay exactly fixed')
    for name,mutate in [
        ('aspect',lambda v:v['camera'].update(aspect_ratio=2)),
        ('spherical',lambda v:v['image'].update(projection='equirectangular')),
        ('height',lambda v:v['camera'].update(ground_elevation_m=140,height_above_ground_m=2)),
        ('fake-fit',lambda v:v['anchors'][0].update(basis='assumed_geometry')),
        ('id',lambda v:v['anchors'][0]['osm_ref'].update(id=9007199254741001)),
        ('duplicate',lambda v:v['anchors'].append(copy.deepcopy(v['anchors'][0]))),
        ('crop',lambda v:v['image'].update(crop=[1,0,0,1])),
        ('unknown',lambda v:v['camera'].update(zoom_magic=4)),
    ]:
        invalid=copy.deepcopy(view); mutate(invalid); call('invalid-'+name,'project',invalid,error=True)
    tests.append('Malformed images, cameras, IDs and untrusted geometry are rejected')
    line=copy.deepcopy(view)
    for i,a in enumerate(line['anchors']): a['image_uv']=[.1+i*.1,.5]
    call('collinear','solve',line,error=True)
    tests.append('Degenerate landmark configuration rejected')
    for name, value in [('position_radius_m','30'),('angle_radius_deg',181),
                        ('fov_radius_deg',0),('max_iterations',1.5)]:
        call('invalid-bound-'+name,'solve',view,error=True,**{name:value})
    tests.append('Search budgets reject invalid types, ranges and fractional iteration counts')
    crop=copy.deepcopy(view); crop['image'].update(width_px=1600,height_px=1200,crop=[.1,.1,.9,.9])
    assert call('crop','project',crop)['rms_px']<.003
    tests.append('Image crop retains the correct normalized image coordinates')
    report=dict(passed=True,checks=tests,recovered_camera=solved['view']['camera'],rms_px=solved['projection']['rms_px'])
    (out/'report.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print(json.dumps(report,indent=2))


if __name__=='__main__': main()

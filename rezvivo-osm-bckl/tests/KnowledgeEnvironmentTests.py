"""Real recipe compiler -> road/plant builders -> binary cache and lane offsets."""
import copy
import json
from pathlib import Path
import subprocess
import sys


def main():
    probe, geometry, out = map(Path, sys.argv[1:4])
    out.mkdir(parents=True, exist_ok=True)
    base = dict(latitude=59.77, longitude=60.21, zoom=13, edge_px=256)
    cache = out/'cache'

    def call(label, geom=False, error=False, **kw):
        q=out/(label+'-request.json');q.write_text(json.dumps(dict(base, **kw)),encoding='utf-8')
        p=subprocess.run([str((geometry if geom else probe).resolve()),str(q.resolve()),str(cache.resolve())],capture_output=True,timeout=120)
        result=json.loads(p.stdout.decode('utf-8-sig').strip().splitlines()[-1])
        (out/(label+'.json')).write_text(json.dumps(result,indent=2),encoding='utf-8')
        assert bool(p.returncode)==error,(label,result,p.stderr.decode(errors='replace'))
        return result

    state=call('initial');tile=state['document']['tile'];west,south,east,north=tile['bbox']
    lat=(south+north)/2;lon=east-.0001
    # All dimensions here are synthetic, and deliberately straddle a tile seam.
    elements=[dict(type='node',id=i+1,lon=x,lat=y) for i,(x,y) in enumerate([
        (lon-.001,lat),(lon+.001,lat),
        (lon-.001,lat+.00015),(lon+.001,lat+.00015),
        (lon-.0012,lat+.00035),(lon+.0012,lat+.00035),
        (lon+.0012,lat+.0007),(lon-.0012,lat+.0007)])]
    elements += [dict(type='way',id=100,nodes=[1,2],tags=dict(highway='residential')),
                 dict(type='way',id=101,nodes=[3,4],tags=dict(highway='footway',footway='sidewalk')),
                 dict(type='way',id=102,nodes=[5,6,7,8,5],tags=dict(landuse='forest')),
                 dict(type='node',id=200,lon=lon,lat=lat+.0005,tags=dict(natural='tree'))]
    osm=dict(elements=elements);call('fixture',action='fixture',osm=osm)
    objects={o['id']:o for o in call('context',action='context')['objects']}
    doc=copy.deepcopy(state['document'])
    layout=dict(version=1,mode='replace_scatter',plants=[
        dict(id='left',position=[lon-.0006,lat+.0006],kind='tree',genus='betula',height_m=10),
        dict(id='existing-osm',position=[lon,lat+.0005],kind='tree',genus='pinus',height_m=12),
        dict(id='right',position=[lon+.0006,lat+.0006],kind='tree',genus='picea',height_m=8)])
    specs=[('way/100','road',[('road.width_m',10,'m'),('road.lanes',3,''),('road.lanes_forward',2,''),
          ('road.lanes_backward',1,''),('road.surface','concrete',''),('road.smoothness','good','')]),
          ('way/101','sidewalk',[('sidewalk.width_m',3.5,'m'),('sidewalk.surface','paving_stones','')]),
          ('way/102','vegetation',[('vegetation.layout',layout,'')]),
          ('node/200','vegetation',[('vegetation.genus','pinus',''),('vegetation.height_m',12,'m')])]
    doc['objects']=[]
    for ident,category,values in specs:
        typ,oid=ident.split('/');src=objects[ident]
        doc['objects'].append(dict(id=ident,category=category,description='Synthetic integration fixture.',
            osm_refs=[dict(type=typ,id=oid,fingerprint=src['fingerprint'])],mapping_status='confirmed',match_confidence=1,
            observations=[dict(id=ident+':'+p,property=p,value=v,**({'unit':unit} if unit else {}),
                text='Synthetic fixture, not a photo claim.',origin='manual_override',source_ids=[],confidence=1,
                visibility='visible',decision='accepted') for p,v,unit in values]))

    def save(label,d):
        nonlocal state
        d=copy.deepcopy(d);d['revision']=state['document']['revision']
        call(label,action='write',document=d,expected_revision=d['revision'],expected_hash=state['content_hash'],author='environment-test',change_note=label)
        state=call(label+'-read')

    def compile(label,error=False,**kw):
        return call(label,error=error,action='compile',expected_revision=state['document']['revision'],expected_hash=state['content_hash'],**kw)

    save('authored',doc);compiled=compile('activated',activate=True)
    assert compiled['target_count']==4
    assert all(o['used'] for o in compiled['evidence_report']['observations'])
    generated=call('geometry',geom=True,osm=osm)
    assert not generated['apply_error'],generated
    road=next(r for r in generated['after']['roads'] if r['way_id']=='100')
    walk=next(r for r in generated['after']['roads'] if r['way_id']=='101')
    assert road['width_m']==10 and road['lanes']==3 and road['forward']==2 and road['backward']==1
    assert road['surface']==3 and road['condition']==2 and abs(road['lane_offset_m'])<=4.6
    assert walk['width_m']==3.5
    assert generated['after']==generated['cached'],'Geometry/snap/trees changed in binary roundtrip'
    trees=generated['after']['trees'];assert len(trees)==3,(len(trees),trees)
    assert len({(t['lat_e7'],t['lon_e7']) for t in trees})==3
    assert all(t['type'] for t in trees)
    assert generated['neighbor_hashes'][1] and generated['neighbor_hashes'][2]
    good=copy.deepcopy(state['document'])
    reverse=copy.deepcopy(good)
    reverse['objects'][0]['observations'][2]['value']=0
    reverse['objects'][0]['observations'][3]['value']=3
    reverse['objects'][0]['observations'].append(dict(id='road-direction',property='road.oneway',value='-1',
        text='Synthetic reverse-way fixture.',origin='manual_override',source_ids=[],confidence=1,visibility='visible',decision='accepted'))
    save('reverse-way',reverse);compile('reverse-activated',activate=True)
    reversed_geometry=call('reverse-geometry',geom=True,osm=osm)
    reverse_road=next(r for r in reversed_geometry['after']['roads'] if r['way_id']=='100')
    assert reverse_road['forward']==0 and reverse_road['backward']==3
    assert reversed_geometry['after']==reversed_geometry['cached']
    wrong=copy.deepcopy(reverse);wrong['objects'][0]['observations'][-1]['value']='yes'
    save('contradictory-direction',wrong);compile('direction-rejected',True,activate=True)
    save('direction-restored',good);compile('direction-restored-active',activate=True)
    invalid=[('lane-total',0,1,'value',4),('wrong-category',1,0,'property','road.width_m'),
             ('unknown-genus',3,0,'value','nonesuch'),('fractional-lanes',0,1,'value',2.5),
             ('bad-width',0,0,'value',100)]
    for name,obj,obs,key,val in invalid:
        bad=copy.deepcopy(good);bad['objects'][obj]['observations'][obs][key]=val
        save(name,bad);compile(name+'-rejected',True,activate=True)
    bad=copy.deepcopy(good);bad['objects'][2]['observations'][0]['value']['plants'][0]['position']=[lon,lat]
    save('outside-host',bad);compile('outside-rejected',True,activate=True)
    save('restore',good)
    # A photographed planting strip can be absent from OSM. Its road anchor
    # stays untouched; generated IDs and the replacement mask must be stable.
    local_doc=copy.deepcopy(good)
    local=local_doc['objects'][2]
    local['id']='local:fixture:planting'
    local['osm_refs']=[dict(type='way',id='100',fingerprint=objects['way/100']['fingerprint'])]
    local['observations'][0]['value']['boundary']=[
        [lon-.0012,lat+.00035],[lon+.0012,lat+.00035],
        [lon+.0012,lat+.0007],[lon-.0012,lat+.0007]]
    save('local-area',local_doc);local_compiled=compile('local-activated',activate=True)
    # Reject ambiguous masks instead of silently removing unrelated vegetation.
    bad=copy.deepcopy(local_doc)
    ring=bad['objects'][2]['observations'][0]['value']['boundary']
    ring.insert(2,[lon-.0002,lat+.0009])
    ring[0],ring[3]=ring[3],ring[0]
    save('crossed-boundary',bad);compile('crossed-boundary-rejected',True,activate=True)
    bad=copy.deepcopy(good)
    bad['objects'][2]['observations'][0]['value']['boundary']=copy.deepcopy(local['observations'][0]['value']['boundary'])
    save('ignored-boundary',bad);compile('ignored-boundary-rejected',True,activate=True)
    save('local-valid',local_doc);compile('local-valid-activated',activate=True)
    local_geometry=call('local-geometry',geom=True,osm=osm)
    assert not local_geometry['apply_error'] and len(local_geometry['after']['trees'])==3,local_geometry
    assert local_geometry['after']==local_geometry['cached']
    repeat=call('local-repeat',geom=True,osm=osm)
    assert repeat['after']==local_geometry['after']
    # Anchor staleness also leaves both the original road and local plants intact.
    bad_osm=copy.deepcopy(osm);bad_osm['elements'][0]['lon']+=.00001
    rejected=call('local-anchor-stale',geom=True,osm=bad_osm)
    assert rejected['apply_error'] and rejected['before']==rejected['after']
    save('local-restored',good);compile('normal-restored',activate=True)
    reordered=copy.deepcopy(good);reordered['objects'][2]['observations'][0]['value']['plants'].reverse()
    save('reordered',reordered);same=compile('same')
    assert same['geometry_hash']==compiled['geometry_hash']
    stale=copy.deepcopy(osm);stale['elements'][-1]['lat']+=.00001
    rejected=call('stale-atomic',geom=True,osm=stale)
    assert rejected['apply_error'] and rejected['before']==rejected['after']
    result=dict(passed=True,checks=['native road width, lane directions, surface, wear and sidewalk width',
        'lane offset fits refined carriageway','binary geometry and movement profile roundtrip',
        'reverse oneway reaches native lanes and cache; contradictory lane directions reject',
        'explicit photo plants replace random scatter and retain tagged OSM plants without duplication',
        'node/way properties update both tile dependencies at a seam',
        'category, units, ranges, lane consistency, supported genera and footprint validation',
        'plant list ordering has no geometric effect','stale node rejects the whole block atomically'],
        local_area=dict(stable=True,trees=len(local_geometry['after']['trees']),
                        road_anchor_unchanged=True,random_forest_in_local_area_replaced=True),
        road=road,sidewalk=walk,before_tree_count=len(generated['before']['trees']),after_tree_count=len(trees))
    (out/'result.json').write_text(json.dumps(result,indent=2),encoding='utf-8');print(json.dumps(result,indent=2))

if __name__=='__main__':main()

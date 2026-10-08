"""Native end-to-end fixtures: parts, furniture, local footprints and analogies.
No live knowledge, network or graphics context is used.
"""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

probe, geometry, dest=map(Path,sys.argv[1:4])
dest.mkdir(parents=True,exist_ok=True)
out=Path(tempfile.mkdtemp(prefix='native-',dir=dest.resolve()))
env=dict(os.environ,REZVIVO_TILE_KNOWLEDGE_ROOT=str(out/'knowledge'))
base=dict(latitude=59.77,longitude=60.21,zoom=13,edge_px=256)
checks=[]

def call(label,geom=False,fail=False,**kw):
    q=out/(label+'-request.json');q.write_text(json.dumps(dict(base,**kw)),encoding='utf-8')
    p=subprocess.run([str((geometry if geom else probe).resolve()),str(q),str(out/'cache')],env=env,capture_output=True,timeout=90)
    d=json.loads(p.stdout.decode('utf-8-sig').strip().splitlines()[-1])
    (out/(label+'.json')).write_text(json.dumps(d,indent=2),encoding='utf-8')
    assert bool(p.returncode)==fail,(label,d,p.stderr)
    return d

def check(value,label):
    assert value,label
    checks.append(label)

state=call('initial');osm=dict(elements=[])
def house(ident,x,y,tags=None,w=.00016,h=.00012):
    refs=[]
    for xx,yy in [(x,y),(x+w,y),(x+w,y+h),(x,y+h)]:
        n=10000+len(osm['elements']);refs.append(n)
        osm['elements'].append(dict(type='node',id=n,lon=xx,lat=yy))
    osm['elements'].append(dict(type='way',id=ident,nodes=refs+[refs[0]],tags=tags or {}))

for i in range(6):house(100+i,60.2100+i*.00035,59.7700,dict(building='yes',**({'building:material':'brick'} if i==3 else {})))
house(106,60.2110,59.7705,dict(building='warehouse'))
house(107,60.2100,59.7720,dict(building='yes'))
house(201,60.2100,59.7692,w=.0005,h=.00025)
house(202,60.2107,59.7692)
house(203,60.21015,59.76928,w=.00015,h=.00008)
osm['elements'].append(dict(type='relation',id=200,members=[
    dict(type='way',ref=201,role='outer'),dict(type='way',ref=202,role='outer'),dict(type='way',ref=203,role='inner')],
    tags={'type':'multipolygon','building':'yes','height':'9','roof:shape':'flat'}))
osm['elements'] += [dict(type='node',id=9001,lat=59.7696,lon=60.2095),dict(type='node',id=9002,lat=59.7696,lon=60.212),
    dict(type='way',id=900,nodes=[9001,9002],tags=dict(highway='residential'))]
call('fixture',action='fixture',osm=osm)
context=call('context',action='context',object_ids=['way/201','way/202'])
ctx={o['id']:o for o in context['objects']}
allctx=call('all-context',action='context');ctx.update({o['id']:o for o in allctx['objects']})
check(ctx['way/201']['category']=='building' and ctx['way/202']['category']=='building','independent outer-ring context')
doc=copy.deepcopy(state['document'])
doc['sources']=[dict(id='photo:'+s,kind='photo',provider='fixture',media_id=s,source_url='https://example.org/'+s,
    review_status='accepted',review_origin='manual',review_note='Synthetic fixture.') for s in ['a','b']]
def object_(ident,category,properties,anchor=None):
    target=ctx[anchor or ident];typ,oid=target['id'].split('/')
    return dict(id=ident,category=category,description='Synthetic test, not real imagery.',mapping_status='confirmed',match_confidence=1,
        osm_refs=[dict(type=typ,id=oid,fingerprint=target['fingerprint'])],observations=[dict(id=ident+':'+key,property=key,value=value,
            text='Fixture.',origin='manual_override',source_ids=[],confidence=1,visibility='visible',decision='accepted',
            **({'unit':'m'} if key.endswith('_m') else {})) for key,value in properties])

doc['objects']=[object_('way/201','building',[('building.height_m',5.5),('roof.height_m',0),('roof.shape','flat')]),
    object_('way/202','building',[('building.height_m',12),('roof.height_m',0),('roof.shape','flat')])]
for n,s in [(100,'a'),(101,'b')]:
    obj=object_('way/'+str(n),'building',[('facade.material','plaster'),('roof.shape','hipped')])
    for o in obj['observations']:o.update(origin='photo_observed',source_ids=['photo:'+s])
    doc['objects'].append(obj)
boundary=[[60.2095,59.7696],[60.212,59.7696],[60.212,59.7699],[60.2095,59.7699]]
furniture=dict(version=1,boundary=boundary,features=[
    dict(id='seat',kind='bench',points=[[60.2105,59.7697]],heading_deg=90),
    dict(id='bin',kind='bin',points=[[60.2106,59.7697]])])
doc['objects'].append(object_('local:test:furniture','street_furniture',[('street_furniture.layout',furniture)],'way/900'))
building=dict(version=1,boundary=boundary,features=[dict(id='shed',kind='building',height_m=4,levels=1,
    points=[[60.211,59.7697],[60.2112,59.7697],[60.2112,59.76985],[60.211,59.76985]])])
doc['objects'].append(object_('local:test:building','building',[('building.local',building)],'way/900'))
doc['local_styles']=[dict(id='type:homes',description='Two photo examples.',example_objects=['way/100','way/101'],source_ids=['photo:a','photo:b'],
    applicability='Same local footprint size.',exceptions='Special buildings excluded.',confidence=.6,
    match=dict(building='yes',within_m=100,min_bbox_area_m2=50,max_bbox_area_m2=250),fill_properties=['facade.material','roof.shape'])]

def write(label,d):
    global state
    d=copy.deepcopy(d);d['revision']=state['document']['revision']
    call(label,action='write',document=d,expected_revision=d['revision'],expected_hash=state['content_hash'],author='CPU fixture',change_note=label)
    state=call(label+'-read')

def compile_(label):
    return call(label,action='compile',activate=True,expected_revision=state['document']['revision'],expected_hash=state['content_hash'])

write('authored',doc);compile_('compiled')
g=call('generated',geom=True,extended=True,osm=osm)
check(not g['apply_error'],'atomic native apply')
b={r['id']:r for r in g['after']['buildings']}
check(abs(b['201']['max_y']-5.55)<.001 and abs(b['202']['max_y']-12.05)<.001,'independent relation heights in real geometry (5cm roof offset)')
check('200' not in b and len([r for r in b if r.startswith('-')])==1,'no duplicate relation or local building')
check(set(b)=={str(i) for i in range(100,108)}|{'201','202'}|{i for i in b if i.startswith('-')},'roof vertices carry their owning object identity')
check(len(g['after']['pois'])==2,'native bench and bin instantiated')
check(g['after']==g['cached'],'new geometry and POIs survive binary cache')
def almost(a,b):
    if isinstance(a,float):return abs(a-b)<.0002
    if isinstance(a,list):return len(a)==len(b) and all(almost(x,y) for x,y in zip(a,b))
    if isinstance(a,dict):return a.keys()==b.keys() and all(almost(a[k],b[k]) for k in a)
    return a==b
check(almost(g['after'],g['text_cached']),'new geometry and POIs survive text cache within 0.2mm')
proposal=call('styles',action='infer_styles');rows=proposal['proposals']
check(any(r['object_id']=='way/102' for r in rows),'nearby ordinary missing appearance inferred')
check(not any(r['object_id']=='way/103' and r['property']=='facade.material' for r in rows),'explicit OSM wins')
check(not any(r['object_id'] in ['way/106','way/107','way/201','way/202'] for r in rows),'class radius and size safeguards')
check(not proposal['saved'] and not proposal['activated'],'inference remains a reviewable draft')
write('proposed',proposal['document']);c=compile_('proposed-compiled')
check(c['target_count']>6,'native compiler accepts labeled local inference')
wrong=copy.deepcopy(doc);wrong['local_styles'][0]['example_objects']=['way/100','way/106']
extra=copy.deepcopy(doc['objects'][3]);extra.update(id='way/106',osm_refs=[dict(type='way',id='106',fingerprint=ctx['way/106']['fingerprint'])])
for observation in extra['observations']:observation['id']=observation['id'].replace('way/101','way/106')
wrong['objects'].append(extra)
write('wrong-type',wrong);r=call('wrong-type-proposal',action='infer_styles')
check(not r['proposals'],'incompatible example cannot supply a local rule')
wrong=copy.deepcopy(doc);wrong['objects'][2]['observations'][0]['source_ids']=['photo:b']
write('same-photo',wrong);r=call('same-photo-proposal',action='infer_styles')
check(not any(x['property']=='facade.material' for x in r['proposals']),'one photograph is not two independent examples')
write('restored',doc);compile_('restored-compile')
catalog=out/'knowledge/active-recipes-v1.json'
before_catalog=catalog.read_bytes()
overlap=copy.deepcopy(doc)
local=next(o for o in overlap['objects'] if o['id']=='local:test:building')['observations'][0]['value']
local['boundary']=[[60.2098,59.7695],[60.211,59.7695],[60.211,59.7703],[60.2098,59.7703]]
local['features'][0]['points']=[[60.21,59.77],[60.21016,59.77],[60.21016,59.77012],[60.21,59.77012]]
write('overlapping-footprint',overlap)
failure=call('overlap-compile',fail=True,action='compile',activate=True,
             expected_revision=state['document']['revision'],expected_hash=state['content_hash'])
check('overlap' in failure['error'].lower(),'local footprint overlap rejected during compile, before a ride')
check(catalog.read_bytes()==before_catalog,'failed compile preserves active catalog atomically')
write('restore-after-overlap',doc);compile_('restored-after-overlap')
stale=copy.deepcopy(osm);stale['elements'][-1]['tags']['lanes']='4'
g=call('stale-anchor',geom=True,extended=True,osm=stale)
check(bool(g['apply_error']) and g['before']==g['after'],'failed anchor leaves all layers unchanged')
(dest/'result.json').write_text(json.dumps(dict(passed=True,checks=checks,artifacts=str(out)),indent=2),encoding='utf-8')
print('PASS',len(checks),'native completion checks')

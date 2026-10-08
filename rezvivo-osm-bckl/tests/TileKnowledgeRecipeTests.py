"""Exercise the actual Pascal compiler, generator and binary cache with isolated OSM fixtures."""
import argparse
import copy
import json
from pathlib import Path
import subprocess


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('probe', type=Path)
    ap.add_argument('geometry_probe', type=Path)
    ap.add_argument('out', type=Path)
    args = ap.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    cache = out / 'cache'
    base = dict(latitude=55.73819, longitude=37.58695, zoom=13, edge_px=256)
    checks = []

    def call(label, geom=False, error=False, location=None, **kw):
        request = dict(base if location is None else location, **kw)
        path = out / (label + '-request.json')
        path.write_text(json.dumps(request, ensure_ascii=False), encoding='utf-8')
        exe = args.geometry_probe if geom else args.probe
        p = subprocess.run([str(exe.resolve()), str(path), str(cache)], capture_output=True, timeout=60)
        # Geometry builders may print diagnostics; the final line is the result.
        data = json.loads(p.stdout.decode('utf-8-sig').strip().splitlines()[-1])
        (out / (label + '.json')).write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')
        assert bool(p.returncode) == error, (label, data, p.stderr.decode(errors='replace'))
        return data

    state = call('empty')
    tile = state['document']['tile']
    east = tile['bbox'][2]
    north = tile['bbox'][3] - .0004
    way_id = 9007199254740993
    osm = dict(elements=[dict(type='node', id=i+1, lat=lat, lon=lon) for i, (lat, lon) in enumerate([
        (north, east-.00015), (north, east+.00015), (north+.0002, east+.00015), (north+.0002, east-.00015)])] + [
        dict(type='way', id=way_id, nodes=[1, 2, 3, 4, 1], tags={
            'building': 'yes', 'height': '12', 'building:levels': '4', 'roof:shape': 'flat', 'roof:height': '0',
            'addr:street': 'Садовое кольцо', 'name': '東京 test fixture'})])
    call('fixture', action='fixture', osm=osm)
    ctx = call('context', action='context')
    source = next(o for o in ctx['objects'] if o['id'] == f'way/{way_id}')
    doc = copy.deepcopy(state['document'])
    obs = [dict(id=f'obs:{i}', text='Synthetic test override; not a photo claim.', origin='manual_override',
                source_ids=[], confidence=1, visibility='visible', decision='accepted', property=p, value=v,
                **({'unit': unit} if unit else {})) for i, (p, v, unit) in enumerate([
                    ('building.height_m', 21, 'm'), ('building.levels', 6, 'storeys'),
                    ('roof.shape', 'hipped', ''), ('roof.height_m', 3, 'm'), ('facade.material', 'brick', '')])]
    doc['objects'] = [dict(id=source['id'], category='building', description='Synthetic building straddling two tiles.',
        osm_refs=[dict(type='way', id=str(way_id), fingerprint=source['fingerprint'])], mapping_status='confirmed',
        match_confidence=1, observations=obs)]

    def save(label, document):
        nonlocal state
        document = copy.deepcopy(document)
        document['revision'] = state['document']['revision']
        call(label, action='write', document=document, expected_revision=state['document']['revision'],
             expected_hash=state['content_hash'], author='recipe-test', change_note=label)
        state = call(label + '-read')

    def compile_args(**kw):
        return dict(action='compile', expected_revision=state['document']['revision'],
                    expected_hash=state['content_hash'], **kw)

    save('authored', doc)
    plain = call('baseline-cache', geom=True, save=True, osm=osm, object_id=str(way_id), geometry=True)
    preview = call('preview', **compile_args())
    assert preview['target_count'] == 1 and len(preview['changes']) == 5 and not preview['activated']
    assert call('preview-no-effects', geom=True)['path'] == plain['path']
    checks.append('preview reports exact typed changes without changing geometry or cache')

    scoped_doc=copy.deepcopy(state['document'])
    scoped_doc['processing_scope']=dict(points=[[0,0],[.01,.01]],radius_m=150)
    save('scope-only',scoped_doc)
    scoped_preview=call('scope-still-compiles',**compile_args())
    assert scoped_preview['geometry_hash']==preview['geometry_hash'] and scoped_preview['target_count']==1
    save('scope-remove',doc)
    checks.append('discovery corridor never invalidates accepted buildings outside it or changes their geometry hash')

    published = call('publish-with-live-snapshot', geom=True, compile_request=dict(base, **compile_args(activate=True)))
    assert published['old_snapshot_stable'] and published['new_snapshot_path'] != plain['path']
    applied = call('generated', geom=True, save=True, osm=osm, object_id=str(way_id), geometry=True)
    assert not applied['apply_error'], applied
    assert applied['after']['top_m'] - applied['before']['top_m'] > 8.5, applied
    assert applied['after']['top_m'] - applied['after']['roof_bottom_m'] > 2.8, applied
    assert applied['after']['palettes'] == [4] and applied['after']['triangles'] > 0, applied
    assert applied['loaded_hash'].endswith(applied['tile_hash'])
    assert applied['neighbor_hashes'][1]['hash'] and applied['neighbor_hashes'][2]['hash']
    far = dict(base, tile_x=tile['x']+10, tile_y=tile['y']+10)
    assert call('unaffected-tile', geom=True, location=far)['tile_hash'] == ''
    assert call('raw-osm-untouched', action='context')['objects'][0]['tags']['height'] == '12'
    checks.append('real building generator changes height, pitched roof and facade palette; raw OSM remains unchanged')
    checks.append('both sides of a tile boundary invalidate, unrelated tiles retain old paths; binary round trip validates recipe hash')
    checks.append('active scene keeps its old snapshot; a newly loaded scene sees the published recipe')

    noisy = copy.deepcopy(osm)
    noisy['elements'].append(dict(type='node', id=77, lat=55.73819, lon=37.58695, tags={'natural': 'tree'}))
    call('noisy-fixture', action='fixture', osm=noisy)
    assert call('limited-context', action='context', max_objects=1)['truncated']
    assert call('filtered-compile', **compile_args(max_objects=1))['target_count'] == 1
    call('noisy-fixture-restored', action='fixture', osm=osm)
    checks.append('compiler filters bound OSM IDs before the result limit; unrelated city objects do not block it')

    good = copy.deepcopy(state['document'])
    notes = copy.deepcopy(good)
    notes['summary'] = 'Only author notes changed.'
    notes['objects'][0]['observations'].reverse()
    save('notes-only', notes)
    same = call('publish-notes', **compile_args(activate=True))
    assert same['geometry_hash'] == preview['geometry_hash']
    assert call('notes-cache', geom=True)['path'] == applied['path']
    checks.append('notes, revision and observation ordering do not invalidate geometry')

    inferred = copy.deepcopy(good)
    inferred['sources'] = [dict(id='photo:style',kind='photo',provider='fixture',media_id='style',
        source_url='https://example.org/test-style',note='Synthetic source for policy regression, not real evidence.')]
    style = dict(id='obs:inferred-color',text='Same local building class; unknown exact colour.',
        origin='local_inferred',source_ids=['photo:style'],confidence=.5,visibility='not_visible',
        decision='accepted',property='facade.color',value='#c7b899',
        note='Narrowly scoped local style from a reviewed neighboring example; no geometry inference.')
    inferred['objects'][0]['observations'].append(style)
    save('inferred-style',inferred)
    inferred_result = call('inferred-preview', **compile_args())
    assert inferred_result['geometry_hash'] != preview['geometry_hash']
    for key,value in [('source_ids',[]),('note',''),('confidence',.9),('visibility','ambiguous')]:
        bad=copy.deepcopy(inferred);bad['objects'][0]['observations'][-1][key]=value
        save('inferred-invalid-'+key,bad)
        call('inferred-rejected-'+key,error=True,**compile_args())
    save('inferred-restored',good)
    checks.append('unseen local style requires explicit inference, cited examples, rationale and bounded confidence; ambiguous evidence stays rejected')

    invalid_cases = [
        ('unsupported', lambda d: d['objects'][0]['observations'][0].update(property='building.magic')),
        ('units', lambda d: d['objects'][0]['observations'][0].update(unit='cm')),
        ('range', lambda d: d['objects'][0]['observations'][0].update(value=-1)),
        ('conflict-osm', lambda d: d['objects'][0]['observations'][0].update(origin='local_inferred')),
        ('ambiguous', lambda d: d['objects'][0].update(mapping_status='ambiguous')),
        ('invisible', lambda d: d['objects'][0]['observations'][0].update(visibility='not_visible')),
        ('stale-binding', lambda d: d['objects'][0]['osm_refs'][0].update(fingerprint='0'*32)),
    ]
    for label, mutate in invalid_cases:
        bad = copy.deepcopy(good)
        mutate(bad)
        save(label, bad)
        call(label + '-compile', error=True, **compile_args(activate=True))
        assert call(label + '-preserved', geom=True)['path'] == applied['path']
    checks.append('unsupported properties, wrong units/ranges, OSM conflicts, uncertain bindings and stale references cannot replace a valid recipe')

    changed_osm = copy.deepcopy(osm)
    changed_osm['elements'][1]['lat'] += .00003
    stale = call('stale-runtime', geom=True, osm=changed_osm, object_id=str(way_id), geometry=True)
    assert 'knowledge_recipe_stale' in stale['apply_error']
    assert stale['before'] == stale['after'] and stale['applied_object']['tags']['height'] == '12'
    checks.append('runtime detects changed source geometry and leaves the working dataset unmodified')

    # A complete set of cache files can still contain a truncated building.
    partial = copy.deepcopy(osm)
    partial['elements'] = [e for e in partial['elements'] if not (e['type'] == 'node' and e['id'] == 2)]
    call('partial-fixture', action='fixture', osm=partial)
    partial_ctx = call('partial-context', action='context')
    partial_obj = next(o for o in partial_ctx['objects'] if o['id'] == source['id'])
    assert partial_ctx['complete'] and not partial_obj['geometry_complete']
    partial_doc = copy.deepcopy(good)
    partial_doc['objects'][0]['osm_refs'][0]['fingerprint'] = partial_obj['fingerprint']
    save('partial-knowledge', partial_doc)
    assert 'Incomplete OSM geometry' in call('partial-compile', error=True, **compile_args(activate=True))['error']
    call('restore-fixture', action='fixture', osm=osm)
    checks.append('missing nodes in a cached response cannot become an accepted building recipe')

    second = copy.deepcopy(osm)
    for node in osm['elements'][:4]:
        n = copy.deepcopy(node)
        n['id'] += 10
        n['lon'] -= .001
        second['elements'].append(n)
    w = copy.deepcopy(osm['elements'][-1])
    w['id'] += 1
    w['nodes'] = [n+10 for n in w['nodes']]
    second['elements'].append(w)
    call('two-buildings-fixture', action='fixture', osm=second)
    second_ctx = call('two-buildings-context', action='context')
    second_obj = next(o for o in second_ctx['objects'] if o['osm_id'] == str(w['id']))
    two_doc = copy.deepcopy(good)
    obj2 = copy.deepcopy(two_doc['objects'][0])
    obj2['id'] = second_obj['id']
    obj2['osm_refs'] = [dict(type='way', id=second_obj['osm_id'], fingerprint=second_obj['fingerprint'])]
    for o in obj2['observations']:
        o['id'] += '-second'
    two_doc['objects'].append(obj2)
    save('two-buildings-knowledge', two_doc)
    call('two-buildings-activate', **compile_args(activate=True))
    second['elements'][-3]['lat'] += .00003
    preflight = call('second-building-stale', geom=True, osm=second, object_id=str(way_id), geometry=True)
    assert 'knowledge_recipe_stale' in preflight['apply_error']
    assert preflight['applied_object']['tags']['height'] == '12' and preflight['before'] == preflight['after']
    checks.append('a stale second building prevents all mutations, including the already validated first building')
    call('restore-one-building-fixture', action='fixture', osm=osm)
    save('restore-one-building-knowledge', good)
    call('restore-one-building-activate', **compile_args(activate=True))

    neighbor = dict(base, tile_x=tile['x']+1, tile_y=tile['y'])
    nstate = call('neighbor-read', location=neighbor)
    ndoc = copy.deepcopy(good)
    ndoc['tile'] = nstate['document']['tile']
    ndoc['revision'] = 0
    ndoc['objects'][0]['observations'][0]['value'] = 24
    call('neighbor-fixture', action='fixture', location=neighbor, osm=osm)
    nsave = call('neighbor-write', action='write', location=neighbor, document=ndoc, expected_revision=0,
                 expected_hash='', author='recipe-test', change_note='Conflicting test')
    conflict = call('neighbor-conflict', action='compile', location=neighbor, error=True, activate=True,
                    expected_revision=nsave['revision'], expected_hash=nsave['content_hash'])
    assert 'Conflicting recipes' in conflict['error'], conflict
    checks.append('contradictory recipes from neighboring authoring tiles cannot silently overwrite each other')

    save('restore-valid', good)
    altered = copy.deepcopy(good)
    altered['objects'][0]['observations'][0]['value'] = 24
    save('change-height', altered)
    call('activate-height', **compile_args(activate=True))
    updated = call('new-cache-variant', geom=True, osm=osm, object_id=str(way_id), geometry=True)
    assert updated['path'] != applied['path'] and not updated['has']
    assert abs(updated['after']['top_m'] - applied['after']['top_m'] - 3) < .02
    checks.append('a semantic change gets a fresh cache variant and changes generated height by the requested amount')

    # Removal works even without complete cached OSM; authored notes are retained.
    # Use changed geometry to prove deactivation does not insist on rebinding it.
    call('changed-fixture', action='fixture', osm=changed_osm)
    removed = call('deactivate', **compile_args(activate=True, deactivate=True))
    assert removed['activated'] and removed['target_count'] == 0
    restored = call('original-cache-restored', geom=True)
    assert restored['path'] == plain['path'] and restored['has']
    checks.append('deactivation restores the original cache without deleting knowledge or old variants')

    relation_osm = copy.deepcopy(osm)
    relation_tags = relation_osm['elements'][-1].pop('tags')
    relation_tags['type'] = 'multipolygon'
    relation_osm['elements'].append(dict(type='relation', id=321, tags=relation_tags,
        members=[dict(type='way', ref=way_id, role='outer')]))
    call('relation-fixture', action='fixture', osm=relation_osm)
    rctx = call('relation-context', action='context')
    robj = next(o for o in rctx['objects'] if o['id'] == 'relation/321')
    rdoc = copy.deepcopy(good)
    rdoc['objects'][0]['id'] = 'relation/321'
    rdoc['objects'][0]['osm_refs'] = [dict(type='relation', id='321', fingerprint=robj['fingerprint'])]
    save('relation-knowledge', rdoc)
    call('relation-activate', **compile_args(activate=True))
    rgeom = call('relation-geometry', geom=True, osm=relation_osm, object_type='relation', object_id='321', geometry=True)
    assert not rgeom['apply_error'] and abs(rgeom['after']['top_m']-rgeom['before']['top_m']-9)<.02, rgeom
    relation_osm['elements'][-2]['tags'] = {'building': 'yes'}
    rchanged = call('relation-member-tags', geom=True, osm=relation_osm, object_type='relation', object_id='321')
    assert 'knowledge_recipe_stale' in rchanged['apply_error']
    call('relation-deactivate', **compile_args(activate=True, deactivate=True))
    checks.append('multipolygon geometry uses relation properties; changes to member tags invalidate its recipe')

    # Exact facade/component grammar travels through the same compiler and
    # immutable recipe snapshot as simple height/paint facts.
    call('architecture-fixture', action='fixture', osm=osm)
    architecture = dict(version=1, facades=[dict(
        start=[east-.00015,north], end=[east+.00015,north],
        wall_color='#9abdaf', inset_m=1,
        rows=[dict(x_m=3,bottom_m=1,width_m=1.8,height_m=3,
                   shape='round_arch',count=3,step_m=5)],
        components=[dict(kind='cornice',x_m=8,bottom_m=10,width_m=16,
                         height_m=.5,depth_m=.4,
                         profile=[[0,.2],[.4,.2],[.7,.8],[1,1]])])])
    adoc=copy.deepcopy(doc)
    adoc['objects'][0]['observations']=[dict(id='obs:architecture',
        text='Synthetic exact facade fixture',origin='manual_override',
        source_ids=[],confidence=1,visibility='visible',decision='accepted',
        property='building.architecture',value=architecture)]
    save('architecture-knowledge',adoc)
    caps=call('architecture-capabilities',action='capabilities')
    library=next(p['library'] for p in caps['properties'] if p['property']=='building.architecture')
    assert len(library['components'])>=13 and 'cornices' in library
    call('architecture-activate',**compile_args(activate=True))
    ageom=call('architecture-geometry',geom=True,osm=osm,object_id=str(way_id),geometry=True)
    assert not ageom['apply_error'] and ageom['after']['triangles']>ageom['before']['triangles']+100,ageom
    assert ageom['after']['triangles']<2500
    checks.append('architectural recipe creates recessed arched openings and custom cornice profile through the real building generator')
    for label,modify in [
        ('bad-architecture-overlap',lambda a:a['facades'][0]['rows'][0].update(step_m=.5)),
        ('bad-architecture-component',lambda a:a['facades'][0]['components'][0].update(kind='arbitrary_mesh')),
        ('bad-architecture-profile',lambda a:a['facades'][0]['components'][0].update(profile=[[0,0],[.7,1],[.4,.5],[1,1]])),
    ]:
        bad=copy.deepcopy(adoc);modify(bad['objects'][0]['observations'][0]['value']);save(label,bad)
        call(label+'-reject',error=True,**compile_args(activate=True))
        retained=call(label+'-retained',geom=True)
        assert retained['path']==ageom['path']
    save('architecture-width-change',adoc)
    adoc['objects'][0]['observations'][0]['value']['facades'][0]['rows'][0]['width_m']=2.0
    save('architecture-width-change-2',adoc)
    call('architecture-width-activate',**compile_args(activate=True))
    wider=call('architecture-width-geometry',geom=True,osm=osm,object_id=str(way_id),geometry=True)
    assert wider['path']!=ageom['path'] and not wider['apply_error']
    call('architecture-deactivate',**compile_args(activate=True,deactivate=True))
    checks.append('window dimensions invalidate the geometry cache; overlapping windows, malformed profiles and unknown components cannot replace a working recipe')
    report = dict(passed=True, checks=checks, baseline=plain['before'], improved=applied['after'])
    (out/'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(report, ensure_ascii=True, indent=2))


if __name__ == '__main__':
    main()

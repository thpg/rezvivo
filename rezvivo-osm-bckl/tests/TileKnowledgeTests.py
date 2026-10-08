"""Persistent authoring tests against the Pascal implementation, not a mock store."""
import argparse
import concurrent.futures
import copy
import json
from pathlib import Path
import shutil
import subprocess


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('probe', type=Path)
    ap.add_argument('out', type=Path)
    args = ap.parse_args()
    args.out = args.out.resolve()
    args.out.mkdir(parents=True, exist_ok=True)
    cache = args.out / 'cache'
    probe = args.probe.resolve()
    checks = []
    base = dict(latitude=55.73819, longitude=37.58695, zoom=13, edge_px=256)

    def call(label, expect_error=False, **kw):
        request = dict(base, **kw)
        path = args.out / (label + '-request.json')
        path.write_text(json.dumps(request, ensure_ascii=False), encoding='utf-8')
        p = subprocess.run([str(probe), str(path), str(cache)], capture_output=True, timeout=45)
        result = json.loads(p.stdout.decode('utf-8-sig'))
        (args.out / (label + '.json')).write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
        assert bool(p.returncode) == expect_error, (label, p.returncode, result, p.stderr)
        return result

    empty = call('empty')
    assert not empty['exists'] and empty['document']['revision'] == 0
    assert not Path(empty['path']).exists() and cache not in Path(empty['path']).parents
    checks.append('empty read has no writes; authoring is outside disposable cache')
    missing = call('missing-context', action='context')
    assert not missing['complete'] and missing['missing_source_tiles'] and missing['network_requests'] == 0
    checks.append('missing cached OSM is reported incomplete, with no network access')

    nodes = [dict(type='node', id=i+1, lat=lat, lon=lon) for i, (lat, lon) in enumerate([
        (55.7381, 37.5868), (55.7381, 37.5871), (55.7383, 37.5871), (55.7383, 37.5868)])]
    way_id = 9007199254740993  # identity must not go through a double
    way = dict(type='way', id=way_id, nodes=[1, 2, 3, 4, 1], tags={
        'building': 'yes', 'addr:street': 'Садовое кольцо', 'addr:housenumber': '12А', 'name': '東京 テスト'})
    osm = dict(elements=nodes + [way,
        dict(type='node', id=5, lat=55.7382, lon=37.5869, tags={'natural': 'tree'}),
        dict(type='node', id=6, lat=37.725, lon=-122.472, tags={'natural': 'tree'}),
        dict(type='relation', id=7, members=[{'type': 'way', 'ref': way_id, 'role': 'outer'}],
             tags={'type': 'multipolygon', 'building': 'yes'})])
    call('fixture', action='fixture', osm=osm)
    ctx = call('context', action='context')
    objs = {o['id']: o for o in ctx['objects']}
    assert ctx['complete'] and ctx['network_requests'] == 0 and len(objs) == 3, ctx
    assert ctx['cached_source_tiles'] == 4, ctx
    obj = objs[f'way/{way_id}']
    assert obj['address']['addr:housenumber'] == '12А' and obj['tags']['name'] == '東京 テスト'
    assert obj['osm_id'] == str(way_id) and 'node/6' not in objs
    checks.append('cached node/way/relation IDs, Unicode addresses, exact 64-bit IDs and tile geography')

    document = empty['document']
    document['summary'] = 'Наблюдения для тайла: фасад и местный тип. 東京.'
    document['osm_basis'] = ctx['osm_basis']
    document['sources'] = [dict(id='photo:test', kind='photo', provider='fixture', media_id='test',
        source_url='https://example.org/photo/test', author='Fixture author', license='CC-BY-4.0')]
    document['sources'].append(dict(document['sources'][0], id='photo:Test', media_id='Test'))
    document['objects'] = [dict(id=obj['id'], category='building', description='Кирпичный фасад, виден только с улицы.',
        osm_refs=[dict(type='way', id=obj['osm_id'], tags=obj['tags'], address=obj['address'], fingerprint=obj['fingerprint'])],
        address=obj['address'], mapping_status='confirmed', match_confidence=.9,
        observations=[dict(id='facade:1', text='Виден красный кирпич.', origin='photo_observed',
            source_ids=['photo:test'], confidence=.85, visibility='visible', decision='unreviewed',
            property='facade.material', value='brick')])]
    document['local_styles'] = [dict(id='brick', description='Небольшие кирпичные дома.',
        applicability='Только схожие жилые дома, заполнять неизвестные свойства.',
        example_objects=[obj['id']], source_ids=['photo:test'], confidence=.5)]
    document['unresolved'] = [dict(text='Двор не виден.', object_ids=[obj['id']], source_ids=['photo:test'])]
    write_args = dict(action='write', document=document, expected_revision=0, expected_hash='',
                      author='test-agent', change_note='First observed facade')
    written = call('write', **write_args)
    saved = call('restart-read')
    path = Path(written['path'])
    assert saved['document']['summary'] == document['summary'] and written['revision'] == 1
    assert 'Кирпичный' in path.read_text(encoding='utf-8') and not written['geometry_applied']
    assert written['content_hash'] == saved['content_hash']
    checks.append('readable UTF-8 observations, source provenance and addresses survive process restart')

    unchanged = call('unchanged', action='context')
    assert unchanged['binding_checks'][0]['status'] == 'unchanged'
    # Move an interior coordinate without changing the bounding box.
    osm['elements'][1]['lat'] = 55.73815
    call('fixture-changed', action='fixture', osm=osm)
    changed = call('changed', action='context')
    assert changed['binding_checks'][0]['status'] == 'osm_changed'
    assert call('read-after-context')['content_hash'] == saved['content_hash']
    checks.append('OSM geometry changes are detected without rewriting knowledge or auto-remapping IDs')

    rejected = call('stale', expect_error=True, **write_args)
    assert 'knowledge_revision_conflict' in rejected['error']
    valid = dict(action='write', document=saved['document'], expected_revision=1, expected_hash=saved['content_hash'],
                 author='test-agent', change_note='Further analysis')
    for label, mutate in [
        ('wrong-tile', lambda d: d['tile'].update(x=d['tile']['x'] + 1)),
        ('missing-source', lambda d: d['sources'].clear()),
        ('wrong-source-case', lambda d: d['objects'][0]['observations'][0].update(source_ids=['photo:TEST'])),
        ('duplicate-object', lambda d: d['objects'].append(copy.deepcopy(d['objects'][0]))),
        ('imprecise-id', lambda d: d['objects'][0]['osm_refs'][0].update(id=9007199254740993)),
        ('unsupported-field', lambda d: d.update(guess_geometry='automatic')),
    ]:
        bad = copy.deepcopy(valid)
        mutate(bad['document'])
        call(label, expect_error=True, **bad)
        assert call(label + '-preserved')['content_hash'] == saved['content_hash']
    checks.append('stale revisions, wrong tiles, dangling evidence and invalid OSM IDs cannot overwrite valid data')

    written2 = call('write-2', **valid)
    saved2 = call('read-2')
    history = list(Path(written2['history_path']).glob('*.json'))
    assert len(history) == 1 and json.loads(history[0].read_text(encoding='utf-8')) == saved['document']
    checks.append('atomic replacement preserves previous knowledge revision')

    # A text editor can change the file without changing its revision number.
    manual = copy.deepcopy(saved2['document'])
    manual['summary'] += ' Правка вручную.'
    path.write_text(json.dumps(manual, ensure_ascii=False, indent=2), encoding='utf-8')
    old_token = dict(valid, document=saved2['document'], expected_revision=2, expected_hash=saved2['content_hash'])
    assert 'knowledge_revision_conflict' in call('manual-conflict', expect_error=True, **old_token)['error']
    fresh = call('manual-read')
    concurrent_request = dict(valid, document=fresh['document'], expected_revision=2, expected_hash=fresh['content_hash'])
    requests = []
    for i in range(8):
        request_path = args.out / f'concurrent-{i}.json'
        request_path.write_text(json.dumps(dict(base, **concurrent_request)), encoding='utf-8')
        requests.append(request_path)
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda p: subprocess.run([str(probe), str(p), str(cache)], capture_output=True, timeout=30), requests))
    assert sum(p.returncode == 0 for p in results) == 1
    assert call('after-concurrent')['document']['revision'] == 3
    checks.append('manual edits are protected by content hash; concurrent writers commit exactly once')

    assert cache.resolve().is_relative_to(args.out) and cache.name == 'cache'
    shutil.rmtree(cache)
    assert call('after-cache-reset')['document']['revision'] == 3
    assert call('after-cache-reset-context', action='context')['binding_checks'][0]['status'] == 'context_incomplete'
    checks.append('clearing all map-cache files preserves authored knowledge; absent OSM does not mean deletion')

    before = path.read_bytes()
    path.write_text('{broken', encoding='utf-8')
    call('corrupt-read', expect_error=True)
    call('corrupt-write', expect_error=True, **old_token)
    assert path.read_text(encoding='utf-8') == '{broken'
    path.write_bytes(before)
    assert not list(path.parent.glob('*.tmp'))
    checks.append('corrupt authored files are reported, never replaced with an empty document')

    call('scope-fixture',action='fixture',osm=osm)
    state=call('scope-read'); scoped=copy.deepcopy(state['document'])
    scoped['processing_scope']=dict(enabled=True,route_id='remote-test',radius_m=150,points=[[0,0],[.01,.01]])
    call('scope-save',action='write',document=scoped,expected_revision=state['document']['revision'],
         expected_hash=state['content_hash'],author='test-agent',change_note='Optional corridor')
    ctx=call('scope-default',action='context')
    assert ctx['route_scope']['enabled'] and ctx['object_count']==0 and ctx['source_bytes']==0
    whole=call('scope-disabled',action='context',route_scope=dict(enabled=False))
    assert whole['object_count']==3 and not whole['route_scope']['enabled']
    restored=call('scope-restored')
    assert restored['document']['processing_scope']==scoped['processing_scope']
    assert restored['document']['objects']==state['document']['objects']
    checks.append('saved route scope is reused, can be overridden, skips irrelevant sources and preserves observations')

    report = dict(passed=len(checks), checks=checks, example_path=str(path))
    (args.out/'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()

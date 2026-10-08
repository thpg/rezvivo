"""CPU-only provenance/review -> actual recipe compiler regression.

Uses disposable authored knowledge and cached OSM, never production/network.
"""
import argparse
import copy
import json
import os
from pathlib import Path
import subprocess


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('probe', type=Path)
    ap.add_argument('output', type=Path)
    args = ap.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    cache = out / 'cache'
    env = os.environ.copy()
    env['REZVIVO_TILE_KNOWLEDGE_ROOT'] = str(out / 'knowledge')
    base = dict(latitude=55.73819, longitude=37.58695, zoom=13, edge_px=256)
    checks = []

    def call(label, error=False, **kw):
        request = dict(base, **kw)
        path = out / (label + '-request.json')
        path.write_text(json.dumps(request), encoding='utf8')
        proc = subprocess.run([str(args.probe.resolve()), str(path), str(cache)],
                              capture_output=True, timeout=40, env=env)
        data = json.loads(proc.stdout.decode('utf-8-sig').strip().splitlines()[-1])
        (out / (label + '.json')).write_text(json.dumps(data, indent=2), encoding='utf8')
        assert bool(proc.returncode) == error, (label, data)
        return data

    def check(value, label):
        assert value, label
        checks.append(label)

    state = call('empty')
    osm = dict(elements=[
        dict(type='node', id=i + 1, lat=a, lon=b) for i, (a, b) in enumerate([
            (55.7381, 37.5868), (55.7381, 37.5870),
            (55.7383, 37.5870), (55.7383, 37.5868)])] + [
        dict(type='way', id=91, nodes=[1, 2, 3, 4, 1],
             tags={'building': 'yes', 'height': '12', 'roof:shape': 'flat'})])
    call('fixture', action='fixture', osm=osm)
    target = next(x for x in call('context', action='context')['objects'] if x['id'] == 'way/91')
    doc = copy.deepcopy(state['document'])
    doc['sources'] = [dict(id='photo:' + n, kind='photo', provider='fixture', media_id=n,
                           source_url='https://example.org/' + n,
                           review_status=s, review_origin=o, review_note='Fixture review.',
                           review_reason='manual_review' if o == 'manual' else 'preserved_specimen')
                      for n, s, o in [('one', 'accepted', 'manual'),
                                      ('herbarium', 'rejected', 'automatic'),
                                      ('unknown', 'unreviewed', 'manual')]]

    def obs(name, prop, value, sources, decision='accepted', **kw):
        return dict(id=name, text='Synthetic fixture.', origin='manual_override',
                    source_ids=sources, confidence=1, visibility='visible',
                    decision=decision, property=prop, value=value, **kw)

    doc['objects'] = [dict(id='way/91', category='building', description='Fixture building.',
        mapping_status='confirmed', match_confidence=1,
        osm_refs=[dict(type='way', id='91', fingerprint=target['fingerprint'])], observations=[
            obs('obs:height', 'building.height_m', 16, ['photo:one'], unit='m'),
            obs('obs:confirm', 'roof.shape', 'flat', ['photo:one']),
            obs('obs:mixed', 'facade.color', '#112233', ['photo:one', 'photo:herbarium']),
            obs('obs:unknown', 'facade.material', 'brick', ['photo:unknown'], 'unreviewed')])]

    def save(label, document):
        nonlocal state
        document = copy.deepcopy(document)
        document['revision'] = state['document']['revision']
        call(label, action='write', document=document, expected_revision=document['revision'],
             expected_hash=state['content_hash'], author='CPU fixture', change_note=label)
        state = call(label + '-read')

    def compile(label):
        return call(label, action='compile', activate=True,
                    expected_revision=state['document']['revision'], expected_hash=state['content_hash'])

    def review(label, **kw):
        nonlocal state
        result = call(label, action='review', expected_revision=state['document']['revision'],
                      expected_hash=state['content_hash'], **kw)
        state = call(label + '-read')
        return result

    save('authored', doc)
    raw = call('before-compile', action='audit')
    check(raw['counts']['discovered'] == 3 and raw['counts']['used'] == 0,
          'authored/download metadata alone never counts as generated evidence')
    compiled = compile('compile')
    recipe = compiled['recipe']
    check(recipe['targets'][0]['set_tags'] == {'height': '16'},
          'multi-source observation with any rejected source contributes no facade trait')
    check({x['observation_id']: x['effect'] for x in recipe['evidence']} ==
          {'obs:height': 'changed', 'obs:confirm': 'confirmed_osm'},
          'compiled journal links only effective accepted observations and distinguishes OSM confirmation')
    audit = call('audit-current', action='audit')
    check(audit['recipe_current'] and audit['counts']['used'] == 1 and
          audit['counts']['confirmed_osm'] == 1 and audit['counts']['rejected'] == 1 and
          audit['counts']['unreviewed'] == 1, 'per-source current recipe counters are honest')
    check(next(x for x in audit['observations'] if x['observation_id'] == 'obs:mixed')['reason'] == 'rejected_source',
          'excluded observation reports its actual rejected support')
    graph = next(x for x in audit['sources'] if x['id'] == 'photo:one')
    check(any(x['object_id'] == 'way/91' and x['observation_id'] == 'obs:height' for x in graph['links']),
          'per-source evidence-to-object linkage is inspectable')
    active_path = out / 'knowledge' / 'active-recipes-v1.json'
    active_bytes = active_path.read_bytes()
    legacy = json.loads(active_bytes)
    for entry in legacy['tiles'].values():
        entry.pop('evidence')
    active_path.write_text(json.dumps(legacy), encoding='utf8')
    legacy_audit = call('legacy-audit', action='audit')
    check(not legacy_audit['recipe_evidence_available'] and legacy_audit['counts']['used'] == 0,
          'legacy recipe with no evidence journal does not falsely claim source usage')
    active_path.write_bytes(active_bytes)

    metadata_doc = copy.deepcopy(state['document'])
    metadata_doc['objects'][0]['observations'][-1]['decision'] = 'accepted'
    save('metadata-authored', metadata_doc)
    compile('metadata-before-discovery')
    call('metadata-catalog', action='photo_fixture', catalog=dict(photos=[dict(
        id='fixture:unknown', provider='fixture', image_id='unknown', subject_type='herbarium_sheet')]))
    cached_rejection_audit = call('cached-rejection-audit', action='audit')
    check(not cached_rejection_audit['recipe_current'] and cached_rejection_audit['requires_recompile'] and
          cached_rejection_audit['recipe_rejected_support_count'] == 1,
          'new cached rejection marks existing compiled provenance stale without claiming geometry changed')
    metadata_compile = compile('metadata-compile')
    check(metadata_compile['recipe']['targets'][0]['set_tags'] == {'height': '16'},
          'new cached automatic rejection excludes an older unreviewed authored source in actual compiler')
    source_unknown = copy.deepcopy(state['document']['sources'][-1])
    override = review('metadata-manual-override', source=source_unknown, review_status='accepted',
                      review_note='Explicit visual review found useful outdoor context.')
    check(override['recipe_result']['recipe']['targets'][0]['set_tags']['building:material'] == 'brick',
          'explicit visual acceptance overrides conservative metadata rejection')
    call('metadata-catalog-clear', action='photo_fixture', catalog=dict(photos=[]))
    save('metadata-reset', doc)
    compile('metadata-reset-compile')

    source = copy.deepcopy(state['document']['sources'][0])
    source['untrusted_provider_payload'] = 'must not be copied'
    rejected = review('reject-used', source=source, review_status='rejected', review_note='Not this place.')
    check(rejected['recipe_current'] and rejected['recipe_result']['target_count'] == 0,
          'review rejection republishes recipe without rejected geometry')
    check(call('after-reject', action='audit')['counts']['used'] == 0,
          'rejected source remains inspectable but is not used')
    check('untrusted_provider_payload' not in state['document']['sources'][0],
          'review writes one sanitized source, not runtime gallery/provider payload')
    restored = review('restore', source=source, review_status='accepted', review_note='Scene confirmed.')
    check(restored['recipe_result']['geometry_hash'] == compiled['geometry_hash'],
          'manual restoration reuses identical geometry semantics')

    original = copy.deepcopy(state['document']['sources'][0])
    view = dict(id='view:one', source_id='photo:one', label='Fixture view', status='draft', confidence=.5,
        camera=dict(latitude=55.73819, longitude=37.58695, elevation_m=150, scale_latitude_deg=55.73,
                    heading_deg=35, pitch_deg=0, roll_deg=0, vertical_fov_deg=60, aspect_ratio=1.5),
        image=dict(width_px=1200, height_px=800, projection='perspective', crop=[0, 0, 1, 1]),
        anchors=[], regions=[], known_parameters=[])
    saved_view = review('view-only', source=source, view=view)
    check(state['document']['sources'][0] == original and len(state['document']['sources']) == 3 and
          state['document']['photo_views'][0]['camera'] == view['camera'] and 'recipe_result' not in saved_view,
          'view-only save preserves review and saves only the requested view/source')
    stale = call('stale-report', action='audit')
    check(not stale['recipe_current'] and stale['counts']['used'] == 0,
          'stale knowledge hash cannot claim currently verified compiled provenance')
    no_review_doc = copy.deepcopy(state['document'])
    for field in ['review_status', 'review_origin', 'review_reason', 'review_note']:
        no_review_doc['sources'][0].pop(field, None)
    save('absent-review', no_review_doc)
    incoming_auto = copy.deepcopy(source)
    incoming_auto.update(review_status='rejected', review_origin='automatic',
                         review_reason='portrait', review_note='Cached classification.')
    review('view-preserves-absent-review', source=incoming_auto, view=view)
    check('review_status' not in state['document']['sources'][0],
          'view-only save cannot silently import a new review for an existing source')
    old_token = copy.deepcopy(state)
    newcomer = dict(id='photo:new', kind='photo', provider='fixture', media_id='new',
                    source_url='https://example.org/new', title='Runtime-only metadata',
                    review_origin='automatic', cache_key='photo-api/v1/fixture/missing')
    review('new-single-source', source=newcomer, review_status='rejected', review_note='Portrait only.')
    check(len(state['document']['sources']) == 4 and 'title' not in state['document']['sources'][-1] and
          state['document']['sources'][-1]['review_origin'] == 'manual',
          'a new review imports exactly one sanitized source and records manual origin')
    failed_stale = call('stale-review', error=True, action='review', source=newcomer,
                        review_status='accepted', expected_revision=old_token['document']['revision'],
                        expected_hash=old_token['content_hash'])
    check('knowledge_revision_conflict' in failed_stale['error'] and
          call('stale-review-check')['content_hash'] == state['content_hash'],
          'optimistic review conflict preserves the latest authored knowledge')

    unsupported = copy.deepcopy(state['document'])
    unsupported['objects'][0]['observations'].append(obs('obs:unsupported', 'vegetation.magic', 10, ['photo:one']))
    save('unsupported', unsupported)
    audit = call('unsupported-audit', action='audit')
    check(next(x for x in audit['observations'] if x['observation_id'] == 'obs:unsupported')['reason'] ==
          'unsupported_property', 'unsupported accepted properties have an explicit non-used reason')
    failure = review('review-deactivate-on-failure', source=source, review_status='accepted', review_note='Reviewed.')
    check('compile_error' in failure and failure['recipe_deactivated'] and not failure['recipe_current'],
          'compile failure after a review explicitly deactivates old recipe and reports the error')
    check(not call('after-failed-review', action='audit')['recipe_present'],
          'failed recompile cannot keep superseded active geometry')
    check(all(x.get('network_requests', 0) == 0 for x in [compiled, audit, failure]),
          'review/audit/compile use only cached inputs')
    (out / 'summary.json').write_text(json.dumps(dict(passed=True, checks=checks), indent=2), encoding='utf8')
    print('PASS', len(checks))


if __name__ == '__main__':
    main()

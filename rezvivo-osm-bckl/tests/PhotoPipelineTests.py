"""Restart every request: durable workflow, ownership, budgets and usage isolation."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

probe = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
out.mkdir(parents=True, exist_ok=True)
root = Path(tempfile.mkdtemp(prefix='workflow-',dir=out))
env = dict(os.environ,REZVIVO_TILE_KNOWLEDGE_ROOT=str(root/'knowledge'))
revision = 0
checks = []

def call(action, fail=False, **kw):
    global revision
    q = dict(action=action,job_id='route',agent='photo-test',expected_revision=revision,**kw)
    request = root/'request.json'
    request.write_text(json.dumps(dict(action='pipeline',request=q)))
    run = subprocess.run([str(probe),str(request),str(root/'cache')],env=env,capture_output=True)
    result = json.loads(run.stdout.decode('utf-8-sig').strip().splitlines()[-1])
    assert bool(run.returncode)==fail,(q,result,run.stderr)
    if not fail: revision = result.get('revision',revision)
    checks.append(action+(' rejected' if fail else ''))
    return result

call('create',tiles=[dict(tile_x=5465,tile_y=2389),dict(tile_x=5466,tile_y=2389)],budgets=dict(images=5))
call('claim',tile_index=0,stage='acquire',fail=True)
call('claim',tile_index=0,stage='discover')
assert call('tile_status')['5465/2389']['state']=='running'
call('claim',tile_index=0,stage='discover',fail=True)
call('finish',tile_index=0,stage='discover',receipt=dict(report='result.json'),fail=True)
call('cancel')
call('claim',tile_index=0,stage='acquire',fail=True)
call('resume')
call('claim',tile_index=0,stage='discover')
call('finish',tile_index=0,stage='discover',receipt=dict(report='result.json',verified=True))
usage = dict(images=2,input_tokens=100,cached_input_tokens=40,output_tokens=12,api_s=.4)
first=call('usage',request_id='request-1',usage=usage)
second=call('usage',request_id='request-1',usage=usage)
assert first['cost']==second['cost'] and first['revision']==second['revision']
call('usage',request_id='request-1',usage=dict(images=3),fail=True)
call('usage',request_id='request-2',usage=dict(images=3,unmetered_calls=1))
call('claim',tile_index=0,stage='acquire',fail=True)
assert call('next')['state']=='budget_exhausted'
doc=call('read');assert doc['tiles'][0]['stages'][0]['state']=='done'
assert doc['cost']['cached_input_tokens']==40 and doc['cost']['input_tokens']==100
call('invalidate',tile_index=0,stage='discover',reason='New imagery')
assert call('read')['tiles'][0]['stages'][0]['state']=='pending'
call('budgets',budgets=dict(images=20))
assert call('next')['state']=='ready'
call('claim',tile_index=0,stage='discover')
call('heartbeat',tile_index=0,stage='discover')
call('finish',tile_index=0,stage='discover',receipt=dict(report='bounded-review.json',reason='No located imagery'),deferred=True)
assert call('next')['deferred_steps']==1
status=call('tile_status')['5465/2389']
assert status['deferred_steps']==1 and status['reason']=='No located imagery'
assert call('tile_status',zoom=12)=={},'Different tile lattice must not inherit this status'
(out/'result.json').write_text(json.dumps(dict(passed=True,checks=checks,restart_per_request=True),indent=2))
print('PASS',len(checks),'durable workflow checks')

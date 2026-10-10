"""Exercise production Overpass code against a local HTTP fault fixture.

Only the shared 30-second cooldown constant is shortened in an isolated
source copy. No test timing option is added to the shipped application.
"""
from collections import defaultdict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import os
import subprocess
import shutil
import threading
import time

APP=Path(__file__).resolve().parents[1]
PROJECT=APP.parent
OUT=APP/'tests/artifacts/overpass-retry'
OUT.mkdir(parents=True,exist_ok=True)
UNITS=OUT/'units'
UNITS.mkdir(exist_ok=True)
SOURCE=OUT/'source'
SOURCE.mkdir(exist_ok=True)
COOLDOWN=150
directory=(PROJECT/'Osm3d/Osm3dOsmDirectory.pas').read_text(encoding='utf-8-sig')
assert directory.count('OSM_ENDPOINT_FAILURE_COOLDOWN_MS = 30000;')==1
(SOURCE/'Osm3dOsmDirectory.pas').write_text(directory.replace(
    'OSM_ENDPOINT_FAILURE_COOLDOWN_MS = 30000;',f'OSM_ENDPOINT_FAILURE_COOLDOWN_MS = {COOLDOWN};'),encoding='utf-8')
for name in ('Osm3dOsmOverpass.pas','Osm3dCacheHTTPFetcher.pas'):
    (SOURCE/name).write_bytes((PROJECT/'Osm3d'/name).read_bytes())

counts=defaultdict(int)
events=[]
lock=threading.Lock()
GOOD=b'{"version":0.6,"elements":[{"type":"node","id":42,"lat":0,"lon":0}]}'
class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def do_POST(self):
        body=self.rfile.read(int(self.headers.get('Content-Length','0'))).decode()
        name=self.path.strip('/')
        key=(name,body)
        with lock:
            counts[key]+=1;n=counts[key]
            events.append({'path':name,'query':body,'attempt':n,'at':time.monotonic()})
        status=200;data=GOOD
        if name=='transient' and n<3:status=504
        if name=='persistent' or name.startswith('cancel-'):status=503
        if name.startswith('bad'):status=int(name[3:])
        if name=='rate' and n==1:status=429
        if name=='truncated' and n==1:data=b'{"elements":['
        if name=='runtime' and n==1:data=b'{"remark":"runtime error: busy","elements":[]}'
        if name=='empty':data=b'{"version":0.6,"elements":[]}'
        if name=='disconnect' and n==1:
            self.close_connection=True
            return
        if name=='auto-first':status=200 if 'auto-recover' in body and n>1 else 503
        if name=='auto-second' and 'auto-recover' in body:status=503
        if name=='shared':time.sleep(.1)
        if status!=200:data=b'temporary fixture error'
        self.send_response(status)
        self.send_header('Content-Type','application/json')
        self.send_header('Content-Length',str(len(data)))
        self.end_headers();self.wfile.write(data)

server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
threading.Thread(target=server.serve_forever,daemon=True).start()
base=f'http://127.0.0.1:{server.server_port}'
names=['transient','persistent','bad400','bad401','bad403','bad404','rate',
       'truncated','runtime','disconnect','empty','shared']+[f'cancel-{v}' for v in range(4)]
servers=[{'url':base+'/'+name,'kind':'public','region':'bbox','bbox':'80,170,81,171',
          'limits':{'min_interval_ms':0,'max_concurrent':1}} for name in names]
servers += [{'url':base+'/'+name,'kind':'public','region':'world',
             'limits':{'min_interval_ms':0,'max_concurrent':1}} for name in ('auto-first','auto-second')]
(OUT/'osm-servers.json').write_text(json.dumps({'version':1,'ttl_seconds':3600,'servers':servers}),encoding='utf-8')
env=os.environ.copy()
env['REZVIVO_TEST_AUTH_FILE']=str(OUT/'isolated-auth.json')
env['REZVIVO_TEST_CACHE_ROOT']=str(OUT)
compiler=Path(os.environ.get('FPC',shutil.which('fpc') or 'fpc'))
args=[str(compiler),'-O2','-gl','-dRELEASE','-FU'+str(UNITS),'-FE'+str(OUT),'-Fu'+str(SOURCE)]
for path in (APP/'castle-engine-output/performance-release/units',PROJECT/'Osm3d'):
    args.append('-Fu'+str(path))
try:
    for name in ('OverpassRetryTests','OverpassRegionCompletenessTests'):
        result=subprocess.run(args+[str(APP/'tests'/(name+'.pas'))],cwd=OUT,capture_output=True)
        (OUT/(name+'-build.log')).write_bytes(result.stdout+result.stderr)
        if result.returncode:
            print((result.stdout+result.stderr).decode(errors='replace'))
            raise SystemExit(result.returncode)
        run=subprocess.run([str(OUT/(name+'.exe')),base],cwd=OUT,env=env,capture_output=True,timeout=45)
        print(run.stdout.decode(errors='replace'),end='')
        if run.returncode:
            print(run.stderr.decode(errors='replace'));raise SystemExit(run.returncode)
    for name in ('transient','persistent'):
        times=[v['at'] for v in events if v['path']==name]
        assert len(times)==3,(name,times)
        assert times[1]-times[0]>=COOLDOWN/1000*.9,(name,times)
        assert times[2]-times[1]>=2*COOLDOWN/1000*.9,(name,times)
    (OUT/'requests.json').write_text(json.dumps(events,indent=2),encoding='utf-8')
    print('PASS: actual HTTP requests respect first and second backoff delays')
finally:
    server.shutdown();server.server_close()

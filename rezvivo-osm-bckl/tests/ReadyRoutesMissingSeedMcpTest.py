"""Real World remains usable with a missing/corrupt installer seed.
Use an isolated app directory and profiles; packaged media are read-only links.
"""
import hashlib,json,os,shutil,sys,time
from pathlib import Path
from http.server import BaseHTTPRequestHandler
from McpHarness import GameSession,GPULock
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from installer_assets import runtime_assets,validate_asset_links
OUT=ROOT/'tests/artifacts/clean-real-world-20261012'/('regression-'+str(time.time_ns()))
APP=OUT/'Чистая установка';APP.mkdir(parents=True)
for src,rel in [(ROOT/'third_person_navigation.exe',Path('REZVIVO.exe'))]+[(p,Path(p.name))for p in ROOT.glob('*.dll')]+list(runtime_assets(ROOT)):
 if rel.parts[:2]==('data','ready-routes'):continue
 dst=APP/rel;dst.parent.mkdir(parents=True,exist_ok=True);os.link(src,dst)
CAT=json.loads((ROOT/'data/ready-routes/catalog.json').read_text(encoding='utf-8'))
CAT['revision']=hashlib.sha256(b'missing-seed-recovery').hexdigest()
GPX=(ROOT/'data/ready-routes/krylatskoye-small-circuit.gpx').read_bytes()
REQUESTS=[]
class API(BaseHTTPRequestHandler):
 def do_GET(self):
  REQUESTS.append(self.path)
  raw=json.dumps(CAT).encode() if self.path=='/api/v1/ready-routes' else (GPX if '/file' in self.path else b'{"allowed":true,"update_available":false}')
  self.send_response(200);self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw)
 def log_message(self,*args):pass
def run(label,offline,expected,out=None):
 app=GameSession(APP,out or OUT/label,executable='REZVIVO.exe',api_handler=API,graphics={'fps_limit':30,'msaa':0})
 app.env['REZVIVO_TEST_HIDDEN']='1'
 if offline:app.env['REZVIVO_OFFLINE']='1'
 with app:
  app.call('app.switch_view',view='routes')
  for _ in range(60):
   state=app.call('menu.inspect')['routes']
   if offline or not state['ready_routes']['busy']:break
   time.sleep(.1)
  assert len(state['ready_routes']['items'])==expected,state
  # Re-enter the page; the singleton must not throw/reinitialize every frame.
  app.call('app.switch_view',view='home');app.call('app.switch_view',view='routes')
  again=app.call('menu.inspect')['routes']
  assert again['ready_routes']['generation']==state['ready_routes']['generation']
  (OUT/(label+'.json')).write_text(json.dumps(state,indent=2),encoding='utf-8')
 return state
with GPULock():
 run('no-seed-offline',True,0)
 run('no-seed-download',False,1,out=OUT/'recovered')
 run('cached-without-seed',True,1,out=OUT/'recovered')
 seed=APP/'data/ready-routes';seed.mkdir(exist_ok=True)
 (seed/'catalog.json').write_text('{broken',encoding='utf-8')
 run('corrupt-seed-offline',True,0)
 (seed/'catalog.json').write_text(json.dumps(CAT),encoding='utf-8')
 # Catalog metadata without the GPX must not prevent remote file recovery.
 run('missing-gpx-download',False,1)
rejected=False
try:validate_asset_links(APP,[p.relative_to(APP)for p in APP.rglob('*')if p.is_file()])
except ValueError:rejected=True
assert rejected,'incomplete installer accepted'
result=dict(passed=True,checks=['no seed offline','remote recovery','cached routes without seed','corrupt seed offline','missing GPX recovery','reenter Real World','Unicode installation path','incomplete package rejected'],requests=REQUESTS)
(OUT/'result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
print(json.dumps(result),flush=True)

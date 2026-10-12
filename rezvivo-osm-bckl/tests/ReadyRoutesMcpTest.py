"""Fresh install, conditional sync, offline restart, no private route copying."""
import json,hashlib,time
from pathlib import Path
from http.server import BaseHTTPRequestHandler
from McpHarness import GameSession,GPULock

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'tests/artifacts/ready-routes-20261011'
RUN=OUT/('client-run-'+str(time.time_ns()))
CAT=json.loads((ROOT/'data/ready-routes/catalog.json').read_text(encoding='utf-8'))
CAT['revision']=hashlib.sha256(b'fixture-revision-1').hexdigest()
REQUESTS=[]
FILE_BYTES=(ROOT/'data/ready-routes/krylatskoye-small-circuit.gpx').read_bytes()
class API(BaseHTTPRequestHandler):
 def do_GET(self):
  REQUESTS.append((self.path,self.headers.get('If-None-Match')))
  status=200
  if self.path=='/api/v1/ready-routes':
   if self.headers.get('If-None-Match')=='"'+CAT['revision']+'"':status=304;raw=b''
   else:raw=json.dumps(CAT,ensure_ascii=False).encode()
  elif self.path.startswith('/api/v1/ready-routes/') and '/file' in self.path:
   raw=FILE_BYTES
  elif '/client/version?' in self.path:raw=b'{"allowed":true,"update_available":false}'
  else:raw=b'{"status":"ok"}'
  self.send_response(status);self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw)
 def log_message(self,*args):pass

def menu(app):
 app.call('app.switch_view',view='routes')
 for i in range(30):
  r=app.call('menu.inspect')
  if 'routes' in r:return r['routes']
  time.sleep(.1)
 raise AssertionError(r)

with GPULock():
 # A brand-new local profile; startup seeds must work without any server.
 app=GameSession(ROOT,RUN/'fresh-offline',api_handler=API,graphics={'fps_limit':30,'msaa':0})
 app.env.update(REZVIVO_TEST_HIDDEN='1',REZVIVO_OFFLINE='1')
 with app:
  r=menu(app);(OUT/'fresh-offline.json').write_text(json.dumps(r,indent=2),encoding='utf-8')
  assert len(r['ready_routes']['items'])==1
  item=r['ready_routes']['items'][0]
  assert item['loop'] and 4200<item['distance_m']<4400
  file=app.out/'accounts/ready-routes/objects'/(item['sha256']+'.gpx')
  assert hashlib.sha256(file.read_bytes()).hexdigest()==item['sha256']
  assert not list((app.out/'accounts/routes').glob('*.gpx'))
  app.call('menu.inspect',route_path=str(file))
  for _ in range(40):
   r=app.call('menu.inspect')['routes']
   if r['points']>800 and not r['pending']:break
   time.sleep(.1)
  assert r['points']>800,r
  app.call('app.screenshot',path=str(OUT/'ready-route-carousel.png'),inline=False)
  (OUT/'selected.json').write_text(json.dumps(r,indent=2),encoding='utf-8')
 # Sync does not copy routes into the personal upload queue or repeat bytes.
 for pass_no in range(2):
  app=GameSession(ROOT,RUN/'sync',api_handler=API,graphics={'fps_limit':30,'msaa':0})
  app.env['REZVIVO_TEST_HIDDEN']='1'
  with app:
   r=menu(app)
   for _ in range(60):
    r=app.call('menu.inspect')['routes']
    if not r['ready_routes']['busy']:break
    time.sleep(.1)
   assert r['ready_routes']['revision']==CAT['revision'],r['ready_routes']
 assert any(tag=='"'+CAT['revision']+'"' for path,tag in REQUESTS if path=='/api/v1/ready-routes'),REQUESTS
 assert not any('/file' in path for path,tag in REQUESTS),REQUESTS
 # Changed GPX is fetched once; an old saved selection resolves by stable ID.
 old_file=RUN/'sync/accounts/ready-routes/objects'/(CAT['items'][0]['sha256']+'.gpx')
 FILE_BYTES=FILE_BYTES.replace(b'creator="REZVIVO"',b'creator="REZVIVO updated"')
 CAT['revision']=hashlib.sha256(b'fixture-revision-2').hexdigest();CAT['items'][0]['title_en']='Updated Krylatskoye'
 CAT['items'][0]['sha256']=hashlib.sha256(FILE_BYTES).hexdigest();CAT['items'][0]['size_bytes']=len(FILE_BYTES)
 app=GameSession(ROOT,RUN/'sync',api_handler=API,graphics={'fps_limit':30,'msaa':0});app.env['REZVIVO_TEST_HIDDEN']='1'
 with app:
  menu(app)
  for _ in range(60):
   r=app.call('menu.inspect')['routes']
   if not r['ready_routes']['busy'] and r['ready_routes']['revision']==CAT['revision']:break
   time.sleep(.1)
  assert r['ready_routes']['items'][0]['title_en']=='Updated Krylatskoye'
  r=app.call('menu.inspect',route_path=str(old_file))['routes']
  assert Path(r['selected']).stem==CAT['items'][0]['sha256'],r['selected']
  assert sum('/file' in path for path,tag in REQUESTS)==1,REQUESTS
 CAT['revision']=hashlib.sha256(b'fixture-revision-3').hexdigest();CAT['items']=[]
 for offline in [False,True]:
  app=GameSession(ROOT,RUN/'sync',api_handler=API,graphics={'fps_limit':30,'msaa':0});app.env['REZVIVO_TEST_HIDDEN']='1'
  if offline:app.env['REZVIVO_OFFLINE']='1'
  with app:
   menu(app)
   for _ in range(60):
    r=app.call('menu.inspect')['routes']
    # The catalog completes in the global update; the carousel consumes its
    # generation on the next UI frame. Wait for both rather than racing it.
    if not r['ready_routes']['busy'] and not r['ready_routes']['items'] and r['carousel']['count']==0:break
    time.sleep(.1)
   assert not r['ready_routes']['items'] and r['carousel']['count']==0,r
 (OUT/'client-verification.json').write_text(json.dumps({'passed':True,'requests':REQUESTS,'checks':['fresh offline carousel','889-point closed route','conditional 304 restart','no redundant GPX download','no private profile import','updated GPX fetched once','old selection resolves to updated route','withdrawal preserved offline']},indent=2))
print('Ready routes client checks passed')

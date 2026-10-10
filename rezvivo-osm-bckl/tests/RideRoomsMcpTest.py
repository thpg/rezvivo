"""Two actual clients, disposable signed-in accounts and loopback private rooms.
Requires the newly built game. Owns the GPU mutex; no public server/deployment.
CPU-only protocol assertions: python tests/RideRoomsMcpTest.py --self-test
"""
import argparse
from http.server import BaseHTTPRequestHandler
import json
from pathlib import Path
import tempfile
import threading
import time
from McpHarness import GameSession, GPULock
from RideRecoveryFocusMcpTest import NativeUI, wait_for


class Rooms:
    def __init__(self):
        self.lock = threading.RLock()
        self.room = None
        self.offline = False
        self.bad_hash = False
        self.calls = []

    def request(self, method, path, body, account):
        with self.lock:
            self.calls.append((method, path, account))
            if '/client/version?' in path:
                return 200, dict(current_build=1, allowed=True, update_available=False)
            if path == '/api/v1/me':
                return 200, dict(id=account, nickname=f'Room fixture {account}', locale='en', ftp_w=210, weight_g=75000)
            if path.endswith('/entitlements'):
                return 200, dict(has_access=True)
            prefix = '/api/v1/relay/rooms'
            if not path.startswith(prefix): return 200, {}
            if account <= 0: return 401, {}
            if self.offline: return 503, {}
            if path == prefix:
                self.room = dict(code='ABCDEF2345',world=body['world'],members={account:0},states={},configs={})
                return 200, self.info(account)
            if not self.room: return 404, {}
            if path == prefix+'/join':
                if body.get('code') != self.room['code']: return 404, {}
                if account not in self.room['members']:
                    used=set(self.room['members'].values())
                    if len(used) >= 8: return 409, {}
                    self.room['members'][account]=next(i for i in range(8) if i not in used)
                return 200, self.info(account)
            if not path.startswith(prefix+'/'+self.room['code']+'/'): return 404, {}
            if account not in self.room['members']: return 403, {}
            if path.endswith('/leave'):
                self.room['members'].pop(account, None)
                self.room['states'].pop(account, None)
                self.room['configs'].pop(account, None)
                return 200, {}
            if path.endswith('/push'):
                value=dict(body,rider_id=account,updated_at=int(time.time()*1000))
                self.room['states'][account]=value
                return 200, {}
            if path.endswith('/pull'): return 200, list(self.room['states'].values())
            if path.endswith('/config') and method=='POST':
                self.room['configs'][account]=body['config']
                return 200, {}
            if '/config?rider_id=' in path:
                peer=int(path.split('rider_id=')[1])
                if peer not in self.room['members']: return 403, {}
                return 200, dict(rider_id=peer,config=self.room['configs'].get(peer,''))
            if path.endswith('/info'): return 200, self.info(account)
            raise AssertionError(('unexpected private endpoint',path))

    def info(self, account):
        world=dict(self.room['world'])
        if self.bad_hash: world['content_hash']='0'*64
        return dict(code=self.room['code'], world=world, members=len(self.room['members']),
                    rider_id=account, start_slot=self.room['members'][account],
                    route_size=0, route_format='', relay_path='/ignored')


def handler(store):
    class API(BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def do_GET(self): self.reply()
        def do_POST(self): self.reply()
        def reply(self):
            token=self.headers.get('Authorization','')
            account=int(token.split('-')[-1]) if token.startswith('Bearer fixture-') else 0
            raw=self.rfile.read(int(self.headers.get('Content-Length',0)))
            body=json.loads(raw) if raw else {}
            status,value=store.request(self.command,self.path,body,account)
            raw=json.dumps(value).encode()
            try:
                self.send_response(status);self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw)
            except (OSError,BrokenPipeError): pass
    return API


def account(app, user):
    (app.out/'no-auth.json').write_text(json.dumps(dict(access_token=f'fixture-{user}',
        refresh_token=f'fixture-{user}',expires_at=int(time.time())+3600,
        profile=dict(id=user,nickname=f'Room fixture {user}',locale='en'))),encoding='utf8')


def state(app): return app.call('perf.state')['room']


def activity(app, user):
    files=list((app.out/f'accounts/{user}/activities').glob('*.json'))
    assert len(files)==1, ('expected one local activity',files)
    record=json.loads(files[0].read_text(encoding='utf-8-sig'))
    return dict(file=files[0].name,record=record)


def snapshot(app, path):
    data=app.call('perf.state')
    path.with_suffix('.json').write_text(json.dumps(data,indent=2),encoding='utf8')
    app.call('app.screenshot',path=str(path.with_suffix('.png')),inline=False)
    return data


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--self-test',action='store_true');parser.add_argument('--out');args=parser.parse_args()
    if args.self_test:
        store=Rooms();world=dict(kind='dream',id='castle-island',title='Island',content_hash='a'*64)
        assert store.request('POST','/api/v1/relay/rooms',dict(world=world),0)[0]==401
        assert store.request('POST','/api/v1/relay/rooms',dict(world=world),42)[1]['start_slot']==0
        for _ in range(3): assert store.request('POST','/api/v1/relay/rooms/join',dict(code='ABCDEF2345'),43)[1]['start_slot']==1
        assert len(store.room['members'])==2
        base='/api/v1/relay/rooms/ABCDEF2345'
        assert store.request('GET',base+'/pull',{},99)[0]==403
        assert store.request('GET','/api/v1/relay/rooms/ZZZZZZ2345/pull',{},42)[0]==404
        store.request('POST',base+'/push',dict(rider_id=99,distance=12,speed=0),42)
        assert store.request('GET',base+'/pull',{},43)[1][0]['rider_id']==42
        for user in range(44,50): assert store.request('POST','/api/v1/relay/rooms/join',dict(code='ABCDEF2345'),user)[0]==200
        assert store.request('POST','/api/v1/relay/rooms/join',dict(code='ABCDEF2345'),50)[0]==409
        store.bad_hash=True;assert store.info(43)['world']['content_hash']!=world['content_hash']
        print('PASS fixture auth, isolation, stable slots, identity, capacity, mismatch');return
    game=Path(__file__).resolve().parents[1]
    out=Path(args.out or tempfile.mkdtemp(prefix='rezvivo-two-room-clients-'));out.mkdir(parents=True,exist_ok=True)
    print('Artifacts:',out,flush=True)
    store=Rooms();api=handler(store)
    a=GameSession(game,out/'host',graphics={'fps_limit':30,'msaa':0},api_handler=api)
    b=GameSession(game,out/'guest',graphics={'fps_limit':30,'msaa':0},api_handler=api)
    account(a,42);account(b,43)
    with GPULock(), a:
        ui_a=NativeUI(a)
        a.call('dream.inspect',open=True,select=0)
        wait_for(lambda:a.call('dream.inspect'),lambda d:d.get('page',{}).get('ready'),seconds=120,description='Dream ready')
        ui_a.click('RideWithFriend');ui_a.click('RoomCreate')
        host=wait_for(lambda:state(a),lambda s:s['active'] and not s['busy'],seconds=30,description='host create')
        snapshot(a,out/'host-room')
        assert any(c['name']=='RoomCopy' and c.get('enabled') for c in ui_a.controls())
        print('PASS host created private room',flush=True)
        ui_a.click('RoomRide')
        wait_for(lambda:a.call('perf.state'),lambda s:s.get('active') and s.get('prep_done'),seconds=120,description='host ride')
        a.call('ride.start')
        with b:
            ui_b=NativeUI(b);ui_b.click('RideWithFriend')
            b.rpc('tools/call', {'name':'ui.edit','arguments':{'name':'RoomCode','text':host['code']}});ui_b.click('RoomJoin')
            guest=wait_for(lambda:state(b),lambda s:s['active'] and not s['busy'],seconds=30,description='guest join')
            assert guest['content_hash']==host['content_hash'] and guest['start_slot']==1
            ui_b.click('RoomRide')
            wait_for(lambda:b.call('perf.state'),lambda s:s.get('active') and s.get('prep_done'),seconds=120,description='guest ride')
            wait_for(lambda:state(a),lambda s:s.get('peers')==[43] and s.get('visual_count')==1,seconds=60,description='host sees guest')
            wait_for(lambda:state(b),lambda s:s.get('peers')==[42] and s.get('visual_count')==1,seconds=60,description='guest sees host')
            before_a,before_b=state(a),state(b)
            log_a,log_b=activity(a,42),activity(b,43)
            snapshot(a,out/'host-connected');snapshot(b,out/'guest-connected')
            print('PASS two clients share one world and see one peer each',flush=True)
            store.offline=True;time.sleep(4);store.offline=False
            for _ in range(20):
                sa,sb=state(a),state(b)
                assert len(sa.get('peers',[]))<=1 and len(sb.get('peers',[]))<=1
                assert sa.get('visual_count',0)<=1 and sb.get('visual_count',0)<=1
                time.sleep(.3)
            wait_for(lambda:state(a),lambda s:s.get('peers')==[43] and not s['relay_error'],seconds=20,description='host reconnected')
            wait_for(lambda:state(b),lambda s:s.get('peers')==[42] and not s['relay_error'],seconds=20,description='guest reconnected')
            assert activity(a,42)['file']==log_a['file'] and activity(b,43)['file']==log_b['file'],'network loss restarted local activity'
            assert a.call('perf.state')['active'] and b.call('perf.state')['active']
            print('PASS reconnect preserves local activities and rider identities',flush=True)
            ui_b.key(0x1B);ui_b.click('RideWithFriend');ui_b.click('RoomLeave')
            wait_for(lambda:state(b),lambda s:not s['active'] and not s['busy'],description='leave')
            store.bad_hash=True;b.rpc('tools/call', {'name':'ui.edit','arguments':{'name':'RoomCode','text':host['code']}});ui_b.click('RoomJoin')
            mismatch=wait_for(lambda:state(b),lambda s:bool(s['error']) and not s['busy'],seconds=30,description='mismatch rejected')
            assert not mismatch['active'] and 'different Dream world version' in mismatch['error']
            snapshot(b,out/'guest-version-mismatch')
            (out/'result.json').write_text(json.dumps(dict(host=before_a,guest=before_b,mismatch=mismatch,
                host_activity=activity(a,42),guest_activity=activity(b,43),calls=store.calls),indent=2),encoding='utf8')
            assert all('/guest_sync' not in path for _,path,_ in store.calls)
            print('PASS two real clients: private Dream, late join, reconnect, stable identity, leave, content mismatch',flush=True)


if __name__=='__main__':main()

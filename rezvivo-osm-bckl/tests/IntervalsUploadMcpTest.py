"""Upload only to a loopback server; never sends fixtures to a real athlete."""
import hashlib
import json
from email.parser import BytesParser
from email.policy import default
from pathlib import Path
import sys
import time

from McpHarness import GameSession, GPULock
from TrainingScheduleMcpTest import API as ScheduleAPI
from RideRoomsMcpTest import account
from RideRecoveryFocusMcpTest import wait_for

class API(ScheduleAPI):
    uploads = {}
    def do_GET(self):
        if self.path.endswith('/connectors'):
            raw=json.dumps(dict(items=[dict(provider='intervals',connected=True,name='Fixture',
                can_upload=True,upload_job=dict(status='done',processed=1))])).encode()
            self.send_response(200);self.send_header('Content-Length',str(len(raw)))
            self.end_headers();self.wfile.write(raw)
        else: super().do_GET()
    def do_POST(self):
        if self.path != '/api/v1/rides': return super().do_POST()
        raw=self.rfile.read(int(self.headers['Content-Length']))
        msg=BytesParser(policy=default).parsebytes(
            ('Content-Type: '+self.headers['Content-Type']+'\r\nMIME-Version: 1.0\r\n\r\n').encode()+raw)
        parts={p.get_param('name',header='content-disposition'):p for p in msg.iter_parts()}
        meta=json.loads(parts['metadata'].get_payload(decode=True))
        file=parts['file'];name=file.get_filename();digest=hashlib.sha256(file.get_payload(decode=True)).hexdigest()
        history=API.uploads.setdefault(name,[])
        history.append(dict(meta=meta,sha=digest,key=self.headers['Idempotency-Key']))
        # First real-trainer request simulates an old server: the ride is saved
        # but the export intent was not acknowledged. CSV must survive/retry.
        response=dict(ride_id=42,idempotent=len(history)>1)
        if not meta.get('upload_intervals') or len(history)>1:
            response['intervals_upload']='pending' if meta.get('upload_intervals') else 'not_requested'
        body=json.dumps(response).encode()
        self.send_response(200);self.send_header('Content-Length',str(len(body)))
        self.end_headers();self.wfile.write(body)

def main():
    game=Path(__file__).resolve().parents[1]
    out=Path(sys.argv[1]).resolve()
    app=GameSession(game,out,{'fps_limit':30,'msaa':0},api_handler=API)
    app.env['REZVIVO_TEST_NO_UPLOAD']='0';account(app,901)
    folder=out/'sessions';folder.mkdir(parents=True,exist_ok=True)
    header='Timestamp,ElapsedSec,Power_W,AvgPower_W,Cadence_rpm,AvgCadence_rpm,Speed_kmh,HeartRate_bpm,Distance_m,Slope_pct,Calories,ResistanceLevel,ElapsedTime_s,IsMoving,TimerActive,Lap,TargetWatts'
    cases={'real':1,'simulation':2,'mixed':3,'unknown':4,'power_meter':8,'legacy':None}
    names={}
    for i,(kind,flags) in enumerate(cases.items()):
        name=f'session_2026-09-28_10-00-{i:02d}.csv';names[kind]=name
        rows=[header+(',SourceFlags' if flags is not None else '')]
        for second in (0,1,2):
            row=f'2026-09-28T10:00:{second:02d},'+f'{second},200,200,85,85,25,125,{second*7},0,0,0,{second},1,1,1,200'
            rows.append(row+(f',{flags}' if flags is not None else ''))
        (folder/name).write_text('\n'.join(rows)+'\n',encoding='utf-8')
    with GPULock(),app:
        wait_for(lambda:API.uploads,lambda data:all(Path(n).with_suffix('.fit').name in data for n in names.values()),25,'all local uploads')
        assert (folder/names['real']).exists(),'CSV discarded before export acknowledgement'
        wait_for(lambda:API.uploads.get(Path(names['real']).with_suffix('.fit').name,[]),lambda h:len(h)>1,30,'durable export retry')
        wait_for(lambda:list(folder.glob('*.csv')),lambda a:not a,5,'successful journals retired')
        for kind,name in names.items():
            history=API.uploads[Path(name).with_suffix('.fit').name]
            assert all(h['meta']['upload_intervals']==(kind=='real') for h in history),(kind,history)
            assert len({h['sha'] for h in history})==1,'FIT changed on retry'
            assert len({h['key'] for h in history})==1,'idempotency changed on retry'
        app.call('app.switch_view',view='connectors')
        labels=wait_for(lambda:app.call('ui.inspect',labels=True)['controls'],
            lambda cs:any('Last ride uploaded' in c.get('caption','') for c in cs),10,'export status')
        app.call('app.screenshot',path=str(out/'connectors.png'),inline=False)
    # GameSession.__exit__ raises on a crash or shutdown timeout.
    result=dict(cases=list(cases),real_retries=len(API.uploads[Path(names['real']).with_suffix('.fit').name]),
                stable_fit=True,export_ack_required=True,clean_exit=True)
    (out/'result.json').write_text(json.dumps(result,indent=2))
    print(json.dumps(result))

if __name__=='__main__':main()

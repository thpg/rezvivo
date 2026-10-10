"""Calendar sync, launch and offline/account isolation using loopback fixtures."""
from datetime import date, timedelta
from http.server import BaseHTTPRequestHandler
import ctypes
import json
from pathlib import Path
import sys
import time
from McpHarness import GameSession, GPULock, write_sim_fit
from RideRecoveryFocusMcpTest import NativeUI, wait_for
from RideRoomsMcpTest import account

game = Path(__file__).resolve().parents[1]
today = date.today().isoformat()
zwo = '''<workout_file><name>Calendar tempo</name><sportType>bike</sportType><workout>
<SteadyState Duration="10" PowerLow="0.55" PowerHigh="0.75"/>
<Cooldown Duration="3" PowerLow="0.65" PowerHigh="0.4"/>
</workout></workout_file>'''

def event(id, name, day=today, **kw):
    return dict(id=id, name=name, date=day, start_date_local=day+'T07:00:00',
                description='Calendar fixture', duration=13, load=1, **kw)

class API(BaseHTTPRequestHandler):
    events = [event(1, 'Calendar tempo', zwo=zwo, completed=False),
              event(2, 'Tomorrow workout', (date.today()+timedelta(days=1)).isoformat(), zwo=zwo),
              event(3, 'Already done', completed=True, zwo=zwo),
              event(4, 'Description only', reason='no_timed_workout')]
    failure = False
    requests = 0
    def do_GET(self):
        code = 200
        if '/training-schedule?' in self.path:
            API.requests += 1
            if API.failure: code, data = 503, {'error':'fixture offline'}
            else: data = dict(connected=True,athlete='fixture-athlete',status='ok',items=API.events)
        elif '/client/version?' in self.path:
            data = dict(current_build=2,allowed=True,update_available=False)
        elif self.path == '/api/v1/me':
            user=int(self.headers.get('Authorization','fixture-901').split('-')[-1])
            data = dict(id=user,nickname='Calendar tester',ftp_w=220,weight_g=75000,locale='en')
        elif self.path.endswith('/connectors'):
            data = dict(items=[dict(provider='intervals',connected=True,name='Fixture')])
        else: data = {'items':[]}
        raw = json.dumps(data).encode()
        self.send_response(code)
        self.send_header('Content-Length',str(len(raw)))
        self.send_header('Content-Type','application/json')
        self.end_headers(); self.wfile.write(raw)
    def log_message(self,*args): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length',0)))
        self.do_GET()

def main():
    out = Path(sys.argv[1]).resolve()
    out.mkdir(parents=True, exist_ok=True)
    session = GameSession(game,out/'profile',{'fps_limit':30,'msaa':0},api_handler=API)
    account(session,901)
    userdir=out/'profile/accounts/901';userdir.mkdir(parents=True,exist_ok=True)
    (userdir/'experience.json').write_text(json.dumps(dict(last_map_kind='dream',last_world='castle-island',
        rider=dict(nickname='Calendar tester',weight=75,ftp=220))))
    fit=out/'sim.fit';write_sim_fit(fit,120,190)
    with GPULock(), session as app:
        app.setting('AudioMaster',0)
        ui=NativeUI(app)
        app.call('app.switch_view',view='home')
        wait_for(ui.controls,lambda cs:any(c['name']=='TodayWorkoutOnly' for c in cs),20,'today suggestion')
        app.call('app.screenshot',path=str(out/'home.png'),inline=False)
        assert API.requests==1, API.requests
        print('PASS today suggestion and one background request',flush=True)
        app.call('app.switch_view',view='schedule')
        wait_for(ui.controls,lambda cs:any(c['name']=='ScheduleEvent1' for c in cs),15,'calendar')
        app.call('app.screenshot',path=str(out/'calendar.png'),inline=False)
        ui.click('ScheduleEvent1')
        wait_for(ui.controls,lambda cs:any(c['name']=='ScheduleStartOnly' for c in cs),10,'detail')
        app.call('app.screenshot',path=str(out/'detail.png'),inline=False)
        app.setting('SimulationEnabled',True)
        app.setting('SimulationUseRoute',False)
        app.setting('SimulationFitPath',str(fit))
        wait_for(lambda:app.call('sim.info'),lambda s:s['active'],15,'simulation')
        ui.click('ScheduleStartOnly')
        state=wait_for(lambda:app.call('workout.inspect'),lambda s:s.get('name')=='Calendar tempo',20,'workout launch')
        assert state['duration']==13 and state['stages']==2,state
        assert abs(state['watts']-143)<.1,state
        app.call('sim.play')
        wait_for(lambda:app.call('workout.inspect'),lambda s:s['state']==4,35,'completion')
        completed=out/'profile/accounts/901/training-schedule-completed.json'
        assert completed.exists(), 'completion not persisted'
        app.call('app.screenshot',path=str(out/'completed.png'),inline=False)
        print('PASS workout-only launch, FTP range target, actual completion',flush=True)
        ui.click('TrainingOnlyFinish')
        app.call('app.switch_view',view='home')
        time.sleep(.6)
        assert not any(c['name']=='TodayWorkoutOnly' for c in ui.controls()), 'completed workout suggested again'
        app.call('app.switch_view',view='schedule')
        API.failure=True;ui.click('ScheduleRefresh');time.sleep(1)
        assert any(c['name']=='ScheduleEvent1' for c in ui.controls()),'offline cache lost'
        print('PASS completed suggestion hidden and offline calendar retained',flush=True)
        API.failure=False;API.events=[];ui.click('ScheduleRefresh');time.sleep(1)
        assert not any(c['name'].startswith('ScheduleEvent') for c in ui.controls()),'deleted events retained'
        print('PASS deleted calendar entries removed',flush=True)
        API.events=[event(11,'Rescheduled workout',zwo=zwo,completed=False),event(12,'Description only',reason='no_timed_workout')]
        ui.click('ScheduleRefresh');time.sleep(1)
        ui.click('ScheduleEvent12')
        assert not any(c['name']=='ScheduleStartOnly' for c in ui.controls()),'description-only workout is playable'
        ui.click('ScheduleBack')
        API.events[0]['date']=(date.today()+timedelta(days=1)).isoformat()
        ui.click('ScheduleRefresh');time.sleep(1)
        app.call('app.switch_view',view='home');time.sleep(.6)
        assert not any(c['name']=='TodayWorkoutOnly' for c in ui.controls()),'tomorrow workout offered today'
        API.events[0]['date']=today
        API.events[0]['zwo']=zwo.replace('Duration="10"','Duration="600"')
        app.call('app.switch_view',view='schedule');ui.click('ScheduleRefresh');time.sleep(1)
        ui.click('ScheduleEvent11');ui.click('ScheduleStartRide')
        time.sleep(.5)
        if any(c['name']=='StartWithoutPower' for c in ui.controls()): ui.click('StartWithoutPower')
        ready=wait_for(lambda:app.call('perf.state'),lambda s:s.get('active') and s.get('prep_done'),120,'3D scheduled ride')
        # Startup pumps MCP while CGE is inside Start. Let that view transition
        # finish before requesting a recursive render (screenshot) or stopping it.
        time.sleep(3)
        plan=app.call('workout.inspect')
        assert plan.get('duration')==603 and plan.get('name')=='Calendar tempo',plan
        app.call('app.screenshot',path=str(out/'ride.png'),inline=False)
        app.call('ride.stop_full')
        app.call('app.switch_view',view='home');time.sleep(.5)
        assert any(c['name']=='TodayWorkoutOnly' for c in ui.controls()),'aborted workout counted as completed'
        print('PASS rescheduling, description-only entry, 3D launch and aborted workout',flush=True)
        # Offline restart must retain both the schedule and the local completion journal.
        API.failure=True
        (out/'result.json').write_text(json.dumps(dict(requests=API.requests,workout=state,completed=json.loads(completed.read_text())),indent=2))
        settings=json.loads((app.out/'settings.json').read_text())
        settings['ui']['language']='ru'
        (app.out/'settings.json').write_text(json.dumps(settings))
    with GPULock(),session as app:
        ui=NativeUI(app);app.call('app.switch_view',view='home')
        ui.user.SetWindowPos(ctypes.c_void_p(ui.hwnd),None,60,60,1280,720,0x0040)
        app.setting('Language','ru')
        wait_for(ui.controls,lambda cs:any(c['name']=='TodayWorkoutOnly' for c in cs),15,'offline suggestion')
        app.call('app.screenshot',path=str(out/'offline-home.png'),inline=False)
        app.call('app.switch_view',view='schedule')
        wait_for(ui.controls,lambda cs:any(c['name']=='ScheduleEvent11' for c in cs),15,'offline calendar')
        app.call('app.screenshot',path=str(out/'offline-calendar.png'),inline=False)
        print('PASS offline restart cache',flush=True)
    # A different signed-in account must never receive the first account\'s cache.
    account(session,902)
    with GPULock(),session as app:
        ui=NativeUI(app);app.call('app.switch_view',view='schedule');time.sleep(1)
        assert not any(c['name'].startswith('ScheduleEvent') for c in ui.controls()),'another account cache exposed'
        print('PASS account cache isolation',flush=True)
    print('PASS clean shutdown',flush=True)

if __name__ == '__main__':
    main()

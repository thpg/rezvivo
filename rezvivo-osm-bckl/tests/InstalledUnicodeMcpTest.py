"""Start a packaged client in a Unicode path with an isolated empty profile."""
import argparse,json,time
from pathlib import Path
from McpHarness import GameSession,GPULock,write_sim_fit
from RideRecoveryFocusMcpTest import NativeUI,wait_for

def run(game,out):
    out.mkdir(parents=True,exist_ok=True)
    # The corrupt optional photo catalog previously aborted ALL OSM routes.
    cache=out/'cache'
    knowledge=out/'cache-knowledge';knowledge.mkdir(exist_ok=True)
    (knowledge/'active-recipes-v1.json').write_text('{broken',encoding='utf-8')
    fit=out/'маршрут проверки.fit';write_sim_fit(fit,seconds=45,watts=200)
    app=GameSession(game,out/'пустой профиль',dict(fps_limit=30,msaa=0),cache_root=cache,
        executable='REZVIVO.exe',native_api=True)
    app.env['REZVIVO_TEST_HIDDEN']='1'
    app.env['REZVIVO_TEST_EMPTY_AUTH']='1'
    with GPULock(),app:
        app.setting('AudioMaster',0)
        ui=NativeUI(app);ui.user.SendMessageW(ui.hwnd,6,1,0)
        time.sleep(1)
        controls=ui.controls()
        captions=[c.get('caption','') for c in controls]
        assert not any(c=='Admin' or c.startswith('Admin\n') for c in captions),captions
        assert not Path(app.env['REZVIVO_TEST_AUTH_FILE']).exists(),'fresh install created authorization'
        (out/'initial-ui.json').write_text(json.dumps(controls,ensure_ascii=False,indent=2),encoding='utf-8')
        app.call('ride.load_fit',path=str(fit))
        wait_for(lambda:app.call('app.views_list'),lambda x:x.get('active')=='play',30)
        # The render world must exist AND ground preparation must finish.
        # Merely seeing preparing=false also happens before an asynchronous start.
        time.sleep(1)
        ready=wait_for(lambda:app.call('path.follow_state',traffic=True,wheels=True),
            lambda x:bool(x.get('traffic')) and x['traffic'][0].get('front_ground_valid') and
                x['traffic'][0].get('rear_ground_valid') and not app.call('explore.state')['travel']['preparing'],240)
        app.call('app.screenshot',path=str(out/'installed-ride.png'),inline=False)
        (out/'result.json').write_text(json.dumps(ready,indent=2),encoding='utf-8')
        assert any((cache/'o3dt').rglob('*.o3dt')) or any((cache/'o3dt').rglob('*.x3d')),'empty generated geometry cache'
        # Drain/cancel neighbouring city generation through the normal ride exit
        # before testing application shutdown (the latter has a 25 s deadline).
        app.call('ride.stop_full')
        app.call('app.switch_view',view='home')
        app.call('app.views_list')
    print('PASS: Unicode executable/settings/FIT paths, empty authorization, OSM ground despite bad optional photo catalog, clean shutdown',flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--game',type=Path,required=True);p.add_argument('--out',type=Path,required=True)
    a=p.parse_args();run(a.game.resolve(),a.out.resolve())

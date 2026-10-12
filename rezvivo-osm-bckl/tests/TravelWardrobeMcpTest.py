"""Transport captions and shared editor garments in the real game."""
import json
from pathlib import Path
import time
from McpHarness import GameSession, GPULock
from RideRecoveryFocusMcpTest import NativeUI, wait_for

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT/'tests/artifacts/travel-wardrobe-20261009/runtime'


def ready(app):
    return wait_for(lambda: app.call('bikefit.status'),
                    lambda s: s.get('rider_loaded') and not s.get('preview_loading'),
                    120, 'clothing preview ready')


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    session = GameSession(ROOT, OUT/'profile', dict(fps_limit=60, msaa=4, grass=1),
                          executable='castle-engine-output/performance-release/third_person_navigation.exe')
    session.env['REZVIVO_TEST_HIDDEN'] = '1'
    session.env['REZVIVO_TEST_TRACE_EXCEPTIONS'] = '1'
    report = {}

    def save():
        (OUT/'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')

    with GPULock():
        try:
            with session as app:
                app.setting('AudioMaster', 0)
                for mode, caption in [('walk', 'Just run'), ('flight', 'Just fly'), ('bicycle', 'Just ride')]:
                    app.call('travel.select', mode=mode)
                    app.call('app.switch_view', view='home')
                    controls = app.call('ui.inspect', labels=True)['controls']
                    button = next(c for c in controls if c['name'] == 'QuickRide')
                    assert button['caption'] == caption, button
                    report[mode+'_ui'] = controls
                print('PASS transport captions switch both ways', flush=True)

                app.call('travel.select', mode='walk')
                ready(app)
                app.call('bikefit.clothing', top='tshirt', bottom='trousers', outer='', feet='sneakers', head='')
                s = ready(app);report['casual_walk'] = s;save()
                assert s['clothing']['surfaces'] > 0, s
                app.call('bikefit.set_color',slot='jersey',r=40,g=180,b=180)
                app.call('bikefit.nudge', param='cadence', steps=3)
                time.sleep(.5)
                app.call('app.screenshot', path=str(OUT/'casual-walk.png'), inline=False)
                print('PASS T-shirt, trousers and sneakers in walking preview', flush=True)

                app.call('bikefit.clothing', top='sweatshirt', bottom='jeans', outer='loose_jacket', feet='boots', head='beanie')
                s = ready(app);report['loose_walk'] = s;save()
                assert s['clothing']['surfaces'] > 0 and s['clothing']['animation']=='gpu_skin_hem_physics', s
                time.sleep(1)
                app.call('app.screenshot', path=str(OUT/'loose-walk.png'), inline=False)
                app.call('bikefit.select_rider', index=1)
                ready(app)
                s=app.call('bikefit.body',sex=0,heightCm=167,weightKg=62,composition=.35)
                report['female'] = s;save()
                assert s['body']['sex']==0 and s['body']['heightCm']==167, s
                assert s['clothing']['bottom'] == 'jeans', s
                time.sleep(.2)
                app.call('app.screenshot',path=str(OUT/'female-loose.png'),inline=False)
                print('PASS loose garments and shared female body', flush=True)

                app.call('travel.select', mode='bicycle')
                s=ready(app);assert s['clothing']['outer']=='loose_jacket', s
                app.call('bikefit.clothing', top='tshirt', bottom='trousers', outer='', feet='sneakers', head='')
                s=ready(app);report['casual_bicycle'] = s;save()
                # The bike-fit preview intentionally uses the shared native
                # skin path; the actual ride uses the procedural GPU pose.
                assert s['rider_loaded'] and s['cadence'] > 0, s
                time.sleep(.5)
                app.call('app.screenshot', path=str(OUT/'casual-bicycle.png'), inline=False)
                print('PASS clothing persists across travel modes and cycling preview', flush=True)

                # Restore head-editor selection without retaining a second hat.
                app.call('bikefit.clothing', head='bucket');ready(app)
                app.call('bikefit.head', headwear='helmet', open=False)
                assert ready(app)['clothing']['head']=='', 'hat remains under helmet'
                ui=NativeUI(app)
                app.call('bikefit.clothing')
                ui.click('ClothingNext_top')
                assert ready(app)['clothing']['top']=='sweatshirt'
                print('PASS actual clothing button and exclusive headwear', flush=True)

                for outer,head,feet in [('jacket','cap','loafers'),('coat','beanie','boots'),('raincoat','bucket','sneakers')]:
                    app.call('bikefit.clothing',outer=outer,head=head,feet=feet)
                    s=ready(app);assert s['clothing']['surfaces']>0,s
                    app.call('app.screenshot',path=str(OUT/(outer+'-bicycle.png')),inline=False)
                app.call('bikefit.clothing',outer='',head='',feet='sneakers');ready(app)
                print('PASS all garment, shoe and hat presets',flush=True)

            with session as app:
                s=ready(app);report['reopened'] = s;save()
                assert s['clothing']['top']=='sweatshirt' and s['clothing']['feet']=='sneakers', s
                top=next(c for c in s['clothing']['colors'] if c['slot']=='top')
                assert top['enabled'] and abs(top['color'][1]-180/255)<1e-5,top
                print('PASS clothing saved across restart', flush=True)
                app.call('travel.select', mode='walk')
                app.call('dream.inspect', open=True, select=0)
                wait_for(lambda: app.call('dream.inspect'),lambda d:d.get('page',{}).get('ready'),180)
                app.call('dream.start')
                wait_for(lambda:app.call('explore.state')['travel'],lambda d:not d['preparing'],180)
                app.call('explore.input',walk_axis=.25,enabled=True)
                time.sleep(.5)
                app.call('app.screenshot',path=str(OUT/'world-walk.png'),inline=False)
                app.call('explore.input',enabled=False)
                live=ready(app);report['live'] = live;save()
                assert live['same_bike'] and live['same_world'],live
                app.call('bikefit.clothing',top='tshirt');live=ready(app)
                assert live['same_bike'] and live['same_world'],live
                app.call('app.screenshot',path=str(OUT/'live-clothing.png'),inline=False)
                app.call('travel.select',mode='bicycle')
                live=ready(app);report['live_bicycle']=live;save()
                assert live['gpu_animation'] and live['same_bike'],live
                top=next(c for c in live['clothing']['colors'] if c['slot']=='top')
                assert top['enabled'] and abs(top['color'][1]-180/255)<1e-5,top
                app.call('app.switch_view',view='play')
                app.call('explore.input',power_axis=1,enabled=True)
                time.sleep(1)
                app.call('app.screenshot',path=str(OUT/'world-bicycle.png'),inline=False)
                app.call('explore.input',enabled=False)
                app.call('ride.stop_full')
                print('PASS same clothing in world and live preview replacement',flush=True)

            settings_path=session.out/'settings.json'
            settings=json.loads(settings_path.read_text(encoding='utf-8-sig'))
            settings.setdefault('ui',{})['language']='ru'
            settings_path.write_text(json.dumps(settings,ensure_ascii=False),encoding='utf-8')
            ru=json.loads((ROOT/'data/translations/ru.json').read_text(encoding='utf-8'))
            with session as app:
                app.call('travel.select',mode='walk')
                app.call('app.switch_view',view='home')
                controls=app.call('ui.inspect',labels=True)['controls']
                assert next(c for c in controls if c['name']=='QuickRide')['caption']==ru['Just run']
                ready(app);app.call('bikefit.clothing')
                app.call('app.screenshot',path=str(OUT/'wardrobe-ru.png'),inline=False)
                app.call('bikefit.clothing',top='',bottom='',outer='',feet='',head='')
                s=ready(app);assert 'surfaces' not in s['clothing'],s
                report['default_restored']=s;save()
                print('PASS Russian captions and original cycling kit restoration',flush=True)
        finally:
            save()
    print('TRAVEL_WARDROBE_OK', flush=True)


if __name__ == '__main__':
    main()

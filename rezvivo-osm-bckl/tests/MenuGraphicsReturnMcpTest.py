"""Ride -> graphics preview/preset -> same ride, isolated hidden profile."""
import json,time,sys
from pathlib import Path
from PIL import Image
from McpHarness import GameSession,GPULock
from RideRecoveryFocusMcpTest import NativeUI,wait_for
from AutomaticBikeFitMcpTest import resize
GAME=Path(__file__).resolve().parents[1]
EXTENDED='--extended'in sys.argv
RTX='--rtx'in sys.argv
FINAL='--final'in sys.argv
OUT=GAME/'tests/artifacts/menu-graphics-20261012'/('final'if FINAL else 'rtx'if RTX else 'extended'if EXTENDED else 'after'if '--after'in sys.argv else 'before')
HUD_NAMES=('RideMenu','RideAssistant','RideTrainingFocus','LabelPower','LabelHeart',
           'LabelCadence','LabelSpeed','LabelWork','LabelWorkTSS','LabelSlope')

def verify_captures(report):
 baseline={c['name']:c['rect'] for c in report['ride-before']['ui'] if c.get('name')in HUD_NAMES}
 assert len(baseline)==len(HUD_NAMES),baseline
 for name,entry in report.items():
  if 'ui'not in entry or not (name.endswith('-ride')or name.startswith('ride-')):continue
  controls={c['name']:c['rect'] for c in entry['ui'] if c.get('name')in HUD_NAMES}
  assert controls==baseline,(name,controls,baseline)
  # The regression is bright magenta speckles on the otherwise tan skin.
  # Keep this check in the fixed close camera; resized samples are separate.
  with Image.open(OUT/(name+'.png'))as shot:
   bad=sum(r>100 and b>80 and r>1.4*g and b>1.4*g
           for r,g,b in shot.convert('RGB').crop((760,200,950,730)).getdata())
  entry['skin_magenta_pixels']=bad
  assert bad<10,(name,'skin texture corrupted',bad)
def main():
 OUT.mkdir(parents=True,exist_ok=True);report={}
 graphics=dict(fps_limit=60,msaa=4,cinematic_softening=0)
 if FINAL:graphics['cinematic_softening']=1
 if RTX:graphics.update(msaa=0,shadow_size=4096,shadow_distance=100,
                        world_shadow_backend=2,rtx_reflections=1,cinematic_softening=1,
                        vegetation_quality=4,vegetation_cache=0)
 app=GameSession(GAME,OUT/'profile',graphics=graphics)
 app.env['REZVIVO_TEST_HIDDEN']='1';app.env['REZVIVO_READY_TILES']='0'
 with GPULock(),app:
  app.setting('AudioMaster',0);ui=NativeUI(app);resize(ui,1600,900)
  app.call('dream.inspect',open=True,select=0)
  wait_for(lambda:app.call('dream.inspect'),lambda r:r.get('page',{}).get('ready'),120,'dream ready')
  app.call('dream.start')
  wait_for(lambda:app.call('bots.local'),lambda r:r.get('ready'),240,'ride ready')
  app.call('camera.chase',distance=2.2,height=1.6,side=1.7,aim_height=1.0)
  def capture(label):
   time.sleep(2)
   report[label]=dict(ui=ui.controls(),camera=app.call('camera.sample'),views=app.call('app.views_list'))
   app.call('app.screenshot',path=str(OUT/(label+'.png')),inline=False)
   (OUT/'report.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
   print('CAPTURE',label,flush=True)
  capture('ride-before')
  app.call('app.switch_view',view='menu');time.sleep(2)
  ui.click('ResumeRideButton');capture('ride-menu-only')
  stages=[('preview-only',None),('preset-low','GraphicsPreset_1'),('preset-high','GraphicsPreset_3')]
  if EXTENDED:stages=[('softening',None),('no-effects',None)]
  if RTX:stages=[('rtx-preview',None),('raster-preview',None)]
  if FINAL:stages=[('preview-only',None)]
  for label,preset in stages:
   app.call('app.switch_view',view='settings')
   if preset:ui.click(preset)
   state=wait_for(lambda:app.call('graphics.preview'),lambda r:r.get('scene',{}).get('ready')or r.get('scene',{}).get('error'),180,'graphics preview')
   assert not state['scene'].get('error'),state
   if label=='softening':app.setting('GraphicsSoftening',2)
   if label=='no-effects':app.setting('GraphicsSoftening',0)
   if label=='raster-preview':app.setting('GraphicsWorldShadows',1)
   report[label+'-preview']=state;capture(label+'-menu')
   if RTX:
    ui.key(0x1B);time.sleep(.5);ui.key(0x1B)
   else:ui.click('ResumeRideButton')
   capture(label+'-ride')
  if EXTENDED:
   app.call('app.switch_view',view='settings');time.sleep(1)
   resize(ui,1000,720);time.sleep(2)
   ui.click('ResumeRideButton');capture('small-window')
   app.call('app.switch_view',view='settings');time.sleep(1)
   resize(ui,1600,900);time.sleep(2)
   ui.click('ResumeRideButton');capture('resize-ride')
   app.call('app.switch_view',view='settings');time.sleep(1)
   ui.click('GraphicsAuto')
   wait_for(ui.controls,lambda cs:any(c.get('name')=='GraphicsAutoCancel'for c in cs),30,'Auto started')
   wait_for(ui.controls,lambda cs:not any(c.get('name')=='GraphicsAutoCancel'for c in cs),260,'Auto finished')
   capture('auto-menu');ui.click('ResumeRideButton');capture('auto-ride')
  verify_captures(report)
  (OUT/'report.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
  print('REPRO_COMPLETE',flush=True)
if __name__=='__main__':main()

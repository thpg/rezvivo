"""Screen shadow mode in a real ride, menus and a resized viewport."""
import ctypes
from ctypes import wintypes
import argparse
import json
from pathlib import Path
import time

from PIL import Image
from McpHarness import GPULock, GameSession, write_sim_fit
from GpuLoad import GpuLoad

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'tests/artifacts/rtx-unified-20261014/ride'
OUT.mkdir(parents=True, exist_ok=True)


def wait(app, command, predicate, timeout=240):
    deadline = time.monotonic()+timeout
    while time.monotonic()<deadline:
        try:
            result = app.call(command)
        except RuntimeError as e:
            if 'main thread did not respond' not in str(e):
                raise
            time.sleep(1)
            continue
        if predicate(result):
            return result
        time.sleep(.5)
    raise AssertionError(result)


def screenshot(app, name):
    path = OUT / (name+'.png')
    app.call('app.screenshot', path=str(path), inline=False)
    image = Image.open(path).convert('RGB')
    assert sum(r>245 and g<10 and b>245 for r, g, b in image.getdata())/image.width/image.height<.0001


def resize(app, width, height):
    user32=ctypes.windll.user32
    windows=[]
    callback=ctypes.WINFUNCTYPE(wintypes.BOOL,wintypes.HWND,wintypes.LPARAM)
    @callback
    def enum(hwnd, unused):
        pid=wintypes.DWORD();rect=wintypes.RECT()
        user32.GetWindowThreadProcessId(hwnd,ctypes.byref(pid))
        user32.GetClientRect(hwnd,ctypes.byref(rect))
        if pid.value==app.process.pid and rect.right>800:
            windows.append(hwnd)
        return True
    user32.EnumWindows(enum,0)
    assert windows
    user32.SetWindowPos.argtypes=[wintypes.HWND,wintypes.HWND,ctypes.c_int,ctypes.c_int,ctypes.c_int,ctypes.c_int,wintypes.UINT]
    assert user32.SetWindowPos(windows[0],None,0,0,width,height,0x16) # no activation, move or z-order


def main():
    global OUT
    parser=argparse.ArgumentParser()
    parser.add_argument('--output',type=Path,default=OUT)
    parser.add_argument('--check-penumbra',action='store_true')
    args=parser.parse_args()
    OUT=args.output.resolve();OUT.mkdir(parents=True,exist_ok=True)
    rows=[]
    def save():
        (OUT/'results.json').write_text(json.dumps(rows,indent=2))
    with GPULock(), GameSession(ROOT, OUT/'profile', dict(fps_limit=0, msaa=4,
            shadow_size=2048, shadow_filter=4, grass=1, vegetation_quality=2,
            world_shadow_backend=1, rtx_reflections=0)) as app:
        fit=OUT/'steady.fit';write_sim_fit(fit,900,210,85)
        app.setting('AudioMaster',0)
        app.setting('SimulationFitPath',str(fit));app.setting('SimulationUseRoute',False)
        app.setting('SimulationEnabled',True)
        app.call('dream.inspect',open=True,select=0)
        wait(app,'dream.inspect',lambda r:r.get('page',{}).get('ready'))
        app.call('dream.start')
        wait(app,'perf.state',lambda r:r.get('active') and r.get('prep_done'))
        app.call('sim.play');app.call('ride.start')
        app.call('camera.chase',distance=5,height=2.4,aim_height=1)
        wait(app,'perf.state',lambda r:r.get('active'))
        time.sleep(8)
        gpu=GpuLoad()
        try:
            for backend,reflection in [(2,0),(3,0),(3,1),(0,0),(3,0)]:
                app.setting('GraphicsWorldShadows',backend)
                app.setting('GraphicsRtxReflections',reflection)
                if backend:
                    state=wait(app,'perf.state',lambda r:r.get('rtx',{}).get('used_this_frame') and
                        (backend!=3 or r['rtx'].get('screen_frames',0)>10) and
                        (not reflection or r['rtx'].get('reflection_frames',0)>5))
                    assert not state['rtx'].get('failed'),state
                time.sleep(3)
                app.call('perf.capture',action='start');loads=[]
                for _ in range(8):
                    time.sleep(.625);loads.append(gpu.sample(app.process.pid))
                row=dict(backend=backend,reflections=reflection,perf=app.call('perf.capture',action='stop'),
                         state=app.call('perf.state'),gpu=loads)
                rows.append(row);save()
                screenshot(app,f'ride-{len(rows)}-{backend}')
                print('Ride',backend,reflection,row['state'].get('rtx',{}).get('screen_ms'),flush=True)
                assert not row['state'].get('rtx',{}).get('screen_error')
                if backend == 3:
                    rtx = row['state']['rtx']
                    assert rtx['raster_depth_bytes'] == 0 and rtx['raster_passes'] == 0, rtx
                    assert rtx['dynamic_triangles'] > 1000 and rtx['dynamic_posed_shapes'] > 0, rtx
                    assert rtx['dynamic_refits'] > 0 and rtx['screen_receiver_limit_m'] == 0, rtx
                    if args.check_penumbra:
                        assert rtx['screen_sun_radius_deg']>0 and rtx['screen_rays']==2,rtx
            if args.check_penumbra:
                for filtering,radius in [(1,0),(16,.7),(4,.35)]:
                    app.setting('GraphicsShadowFilter',filtering)
                    time.sleep(2)
                    state=app.call('perf.state')['rtx']
                    assert abs(state['screen_sun_radius_deg']-radius)<.001,state
                    assert state['raster_passes']==0 and not state['screen_error'],state
                    screenshot(app,f'filter-{filtering}')
                    rows.append(dict(filter=filtering,rtx=state));save()
            before=app.call('perf.state')['rtx']
            resize(app,1150,800);time.sleep(3)
            after=app.call('perf.state')['rtx']
            assert (before['screen_width'],before['screen_height'])!=(after['screen_width'],after['screen_height'])
            assert not after['screen_error']
            screenshot(app,'resized')
            rows.append(dict(resize_before=before,resize_after=after));save()
            app.call('app.switch_view',view='settings');time.sleep(2)
            ui=app.call('ui.inspect',labels=True)
            button=next(c for c in ui['controls'] if c['name']=='Graphics_world_shadow_backend_3')
            assert button
            rows.append(dict(screen_option=button));save()
            screenshot(app,'settings')
            app.call('app.switch_view',view='play');time.sleep(3)
            screenshot(app,'menu-return')
            final=app.call('perf.state');rows.append(dict(final=final));save()
            assert not final.get('rtx',{}).get('failed')
        finally:
            gpu.close()
    print('PASS ride, dynamic riders, reflections, resize and menu',flush=True)


if __name__=='__main__':
    main()

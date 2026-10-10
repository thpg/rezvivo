"""Build an isolated Android ARM64 APK using the CGE/FPC toolchain.

Requires a working FPC aarch64-android cross compiler on PATH, Android SDK/NDK,
JDK 17 and the project's CGE patches. Mobile-specific patches are checked
and applied when needed before compiling or packaging.
Never modifies release metadata, user settings or the Windows executable.
"""
from pathlib import Path
import argparse,hashlib,json,os,shutil,subprocess,xml.etree.ElementTree as ET
from installer_assets import runtime_assets,validate_asset_links

ROOT=Path(__file__).resolve().parents[1]

def run(args,cwd):
    subprocess.run([str(x) for x in args],cwd=cwd,check=True)

def ensure_mobile_patches(engine):
    for name in ('cge-opengles3.patch','cge-android-permissions.patch'):
        patch=ROOT.parent/'Osm3d'/name
        command=['git','apply','--ignore-space-change']
        applied=subprocess.run(command+['--reverse','--check',str(patch)],cwd=engine,capture_output=True)
        if applied.returncode==0:continue
        check=subprocess.run(command+['--check',str(patch)],cwd=engine,capture_output=True)
        if check.returncode!=0:
            raise RuntimeError('CGE patch needs review: '+name+'\n'+check.stderr.decode(errors='replace'))
        run(command+[str(patch)],engine)

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--engine',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    ap.add_argument('--native-library',type=Path,help='Package an already compiled ARM64 library; optional')
    ap.add_argument('--compiler-option',action='append',default=[])
    ap.add_argument('--stage-only',action='store_true')
    args=ap.parse_args()
    stage=args.out.resolve();stage.mkdir(parents=True,exist_ok=True)
    marker=stage/'.rezvivo-android-stage'
    if not marker.exists() and any(stage.iterdir()):
        raise ValueError('Choose an empty Android output directory')
    marker.write_text(str(ROOT),encoding='utf-8')
    engine=args.engine.resolve()
    ensure_mobile_patches(engine)
    service=engine/'tools/build-tool/data/android/services/rezvivo'
    # This is a project-owned CGE Java service, with no edits to engine Java.
    shutil.copytree(ROOT/'platforms/android/service',service,dirs_exist_ok=True)
    files=[];digest=hashlib.sha256()
    for source,relative in runtime_assets(ROOT):
        # Offline Windows speech recognition cannot run on Android. Do not
        # ship its DLLs or a 200 MiB unused language model in the mobile APK.
        if relative.parts[1]=='speech':continue
        target=stage/relative;target.parent.mkdir(parents=True,exist_ok=True)
        if not target.exists() or target.stat().st_mtime_ns!=source.stat().st_mtime_ns or target.stat().st_size!=source.stat().st_size:
            shutil.copy2(source,target)
        name=relative.relative_to('data').as_posix()
        digest.update(name.encode('utf-8'));digest.update(b'\0')
        with source.open('rb') as stream:
            for chunk in iter(lambda:stream.read(1024*1024),b''):digest.update(chunk)
        files.append(relative)
    # Refuse a stale extra asset instead of silently putting obsolete/private
    # files into a subsequent package. Output directories are disposable.
    allowed={p.as_posix() for p in files}|{'data/rezvivo-assets.txt'}
    extra=[p for p in (stage/'data').rglob('*') if p.is_file() and p.relative_to(stage).as_posix() not in allowed]
    if extra:raise ValueError('Stale staged assets; use a fresh output directory: '+str(extra[0]))
    validate_asset_links(stage,[p.as_posix() for p in files])
    (stage/'data/rezvivo-assets.txt').write_text(digest.hexdigest()+'\n'+'\n'.join(p.relative_to('data').as_posix() for p in files)+'\n',encoding='utf-8')
    tree=ET.parse(ROOT/'CastleEngineManifest.xml');project=tree.getroot()
    release=json.loads((ROOT/'release.json').read_text(encoding='utf-8'))
    project.find('version').set('value',release['version'])
    project.find('version').set('code',str(release['build']))
    project.set('standalone_source',str(ROOT/project.get('standalone_source')))
    for path in project.findall('compiler_options/search_paths/path'):
        path.set('value',str((ROOT/path.get('value')).resolve()))
    # Last -Fu takes precedence. Both editor and game contain AvatarGait;
    # always choose the shared current game gait, as the desktop DPR does.
    paths=project.find('compiler_options/search_paths')
    for value in ('../avatareditor-avatar','../Bikeparametric'):
        ET.SubElement(paths,'path',value=str((ROOT/value).resolve()))
    tree.write(stage/'CastleEngineManifest.xml',encoding='utf-8',xml_declaration=True)
    print('Android resources:',len(files),'MiB:',round(sum((stage/p).stat().st_size for p in files)/2**20,1),flush=True)
    if args.stage_only:return
    binary=engine/'bin'/('castle-engine.exe' if os.name=='nt' else 'castle-engine')
    command=[binary,'--project='+str(stage),'--os=android','--cpu=aarch64','--compiler=fpc']
    command+=['--compiler-option='+value for value in args.compiler_option]
    if args.native_library:
        native=stage/'castle-engine-output/android/libthird_person_navigation_android_aarch64.so'
        native.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(args.native_library,native)
    else:run(command+['compile'],stage)
    run(command+['--assume-compiled','--mode=debug','package'],stage)

if __name__=='__main__':main()

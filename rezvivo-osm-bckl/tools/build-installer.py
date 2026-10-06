"""Create a per-user Windows installer with an explicit runtime file manifest.

python tools/build-installer.py --nsis C:/tools/nsis/makensis.exe
--stage-only prepares the same payload for a standalone smoke test.
--stage PATH reuses a tested payload without reading additional project files.
"""
import argparse,hashlib,json,os,shutil,subprocess,tempfile
from pathlib import Path
import xml.etree.ElementTree as ET
from installer_assets import redundant_assets, validate_asset_links
from installer_update import select_delta, components, validate_manifest, installer_guards
ROOT=Path(__file__).resolve().parents[1]
DLLS=('fmt.dll','freetype.dll','libcrypto-1_1-x64.dll','libogg.dll','libvorbis.dll','libpng14-14.dll',
      'libssl-1_1-x64.dll','OpenAL32.dll','simplecble.dll','libusb0.dll','sqlite3.dll',
      'vcruntime140.dll','msvcr120.dll','vorbisfile.dll','zlib1.dll','rezvivo_rtx.dll')

def digest(path):
    sha=hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda:f.read(1024*1024),b''):sha.update(chunk)
    return sha.hexdigest()
def payload(out):
    stage=Path(tempfile.mkdtemp(prefix='payload-',dir=out))
    excluded=redundant_assets(ROOT)
    audit=[dict(path=p,bytes=(ROOT/p).stat().st_size,reason=reason) for p,reason in sorted(excluded.items())]
    (out/'excluded-assets.json').write_text(json.dumps(audit,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print('Excluded unused assets:',len(audit),'MiB:',round(sum(x['bytes'] for x in audit)/2**20,1),flush=True)
    files=[(ROOT/'third_person_navigation.exe',Path('REZVIVO.exe'))]
    files += [(ROOT/x,Path(x)) for x in DLLS]
    for p in sorted((ROOT/'data').rglob('*')):
        if not p.is_file():continue
        rel=p.relative_to(ROOT)
        if rel.as_posix() in excluded:continue
        if any(part.lower() in ('backup','__pycache__','.git') for part in rel.parts):continue
        if p.suffix.lower() in ('.py','.pyc','.md','.log','.bak','.dbg','.blend'):continue
        if rel.parts[1]=='workouts':
            if len(rel.parts)<5 or rel.parts[2]!='rezvivo' or p.suffix!='.zwo':continue
            tree=ET.parse(p)
            if tree.findtext('author')!='REZVIVO':raise ValueError(f'Non-original workout: {p}')
        if p.is_symlink():raise ValueError(f'Unexpected asset symlink: {p}')
        files.append((p,rel))
    for src,rel in files:
        dest=stage/rel;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(src,dest)
    shutil.copy2(ROOT/'release.json',stage/'release.json')
    files.append((ROOT/'release.json',Path('release.json')))
    manifest=[dict(path=rel.as_posix(),bytes=(stage/rel).stat().st_size,sha256=digest(stage/rel)) for _,rel in files]
    (stage/'installed-files.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    workouts=[r for r in manifest if r['path'].endswith('.zwo')]
    if len(workouts)!=7:raise ValueError('Installer must contain exactly the seven original workouts')
    return stage
def q(value):return str(value).replace('$','$$').replace('"','$\\"')
def main():
    ap=argparse.ArgumentParser();ap.add_argument('--nsis');ap.add_argument('--out',type=Path,default=ROOT.parent.parent/'REZVIVO-release');ap.add_argument('--stage',type=Path);ap.add_argument('--stage-only',action='store_true');ap.add_argument('--baseline',type=Path,help='installed-files.json from the exact previous package');a=ap.parse_args()
    a.out.mkdir(parents=True,exist_ok=True)
    stage=a.stage.resolve() if a.stage else payload(a.out)
    release=json.loads((stage/'release.json').read_text(encoding='utf-8'))
    manifest=json.loads((stage/'installed-files.json').read_text(encoding='utf-8'))
    validate_manifest(manifest)
    selected=manifest;removed=[];baseline_sha=''
    if a.baseline:
        baseline=a.baseline.resolve()
        selected,removed=select_delta(manifest,json.loads(baseline.read_text(encoding='utf-8')))
        baseline_sha=digest(baseline)
        print('Changed components:',components(selected),'Removed:',len(removed),flush=True)
    for item in manifest:
        if digest(stage/item['path'])!=item['sha256']:raise ValueError('Staged payload changed: '+item['path'])
    links=validate_asset_links(stage,[item['path'] for item in manifest])
    print('Validated packaged resource links:',links,flush=True)
    print('Stage:',stage,flush=True);print('Files:',len(manifest),'MiB:',round(sum(x['bytes'] for x in manifest)/2**20,1),flush=True)
    if a.stage_only:return
    if not a.nsis:raise ValueError('--nsis is required to compile the installer')
    version=release['version'];full_name=f'REZVIVO-Setup-{version}.exe'
    installer=a.out/(f'REZVIVO-Update-{version}-{baseline_sha[:12]}.exe' if a.baseline else full_name)
    lines=[
      'Unicode true','!include "MUI2.nsh"','!include "LogicLib.nsh"',
      f'Name "REZVIVO {q(version)}"',f'OutFile "{q(installer)}"','RequestExecutionLevel user',
      'InstallDir "$LOCALAPPDATA\\Programs\\REZVIVO"','InstallDirRegKey HKCU "Software\\REZVIVO\\Installer" "InstallDir"',
      'SetCompressor /SOLID lzma','SetCompressorDictSize 32','SetDatablockOptimize on','CRCCheck force',
      f'VIProductVersion "{release["file_version"]}"',f'VIAddVersionKey "ProductName" "REZVIVO {q(version)}"',
      'VIAddVersionKey "FileDescription" "REZVIVO installer"',f'VIAddVersionKey "FileVersion" "{q(version)}"','VIAddVersionKey "LegalCopyright" "REZVIVO"',
      f'!define MUI_ICON "{q(stage/"data/branding/rezvivo.ico")}"',
      f'!define MUI_UNICON "{q(stage/"data/branding/rezvivo.ico")}"',
      '!define MUI_ABORTWARNING','!define MUI_FINISHPAGE_RUN "$INSTDIR\\REZVIVO.exe"','!define MUI_FINISHPAGE_RUN_NOTCHECKED',
      '!insertmacro MUI_PAGE_WELCOME','!insertmacro MUI_PAGE_DIRECTORY','!insertmacro MUI_PAGE_INSTFILES','!insertmacro MUI_PAGE_FINISH',
      '!insertmacro MUI_UNPAGE_CONFIRM','!insertmacro MUI_UNPAGE_INSTFILES','!insertmacro MUI_LANGUAGE "Russian"','!insertmacro MUI_LANGUAGE "English"',
      *installer_guards(a.baseline.resolve() if a.baseline else None),
      'Section "REZVIVO" SEC_CLIENT','SetShellVarContext current','Call CheckInstallation','SetOverwrite on'
    ]
    installed=[Path(x['path']) for x in manifest]+[Path('installed-files.json')]
    packaged=[Path(x['path']) for x in selected]+[Path('installed-files.json')]
    last=None
    for rel in sorted(packaged):
        parent=str(rel.parent)
        if parent!=last:
            lines.append('SetOutPath "$INSTDIR'+('' if parent=='.' else '\\'+q(parent))+'"');last=parent
        lines.append(f'File "{q(stage/rel)}"')
    for rel in removed:lines.append(f'Delete "$INSTDIR\\{q(Path(rel))}"')
    lines += ['SetOutPath "$INSTDIR"','WriteUninstaller "$INSTDIR\\Uninstall.exe"',
      'CreateDirectory "$SMPROGRAMS\\REZVIVO"','CreateShortcut "$SMPROGRAMS\\REZVIVO\\REZVIVO.lnk" "$INSTDIR\\REZVIVO.exe"',
      'CreateShortcut "$DESKTOP\\REZVIVO.lnk" "$INSTDIR\\REZVIVO.exe"',
      'WriteRegStr HKCU "Software\\REZVIVO\\Installer" "InstallDir" "$INSTDIR"',
      'WriteRegStr HKCU "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\REZVIVO" "DisplayName" "REZVIVO"',
      f'WriteRegStr HKCU "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\REZVIVO" "DisplayVersion" "{q(version)}"',
      'WriteRegStr HKCU "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\REZVIVO" "Publisher" "REZVIVO"',
      'WriteRegStr HKCU "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\REZVIVO" "DisplayIcon" "$INSTDIR\\REZVIVO.exe"',
      'WriteRegStr HKCU "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\REZVIVO" "UninstallString" \'$\\"$INSTDIR\\Uninstall.exe$\\"\'',
      'WriteRegDWORD HKCU "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\REZVIVO" "NoModify" 1',
      'WriteRegDWORD HKCU "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\REZVIVO" "NoRepair" 1',
      'SectionEnd','Section "Uninstall"','SetShellVarContext current']
    for rel in installed:lines.append(f'Delete "$INSTDIR\\{q(rel)}"')
    dirs={parent for rel in installed for parent in rel.parents if str(parent)!='.'}
    for directory in sorted(dirs,key=lambda p:len(p.parts),reverse=True):lines.append(f'RMDir "$INSTDIR\\{q(directory)}"')
    lines += ['Delete "$INSTDIR\\Uninstall.exe"','RMDir "$INSTDIR"',
      'Delete "$SMPROGRAMS\\REZVIVO\\REZVIVO.lnk"','RMDir "$SMPROGRAMS\\REZVIVO"','Delete "$DESKTOP\\REZVIVO.lnk"',
      'DeleteRegKey HKCU "Software\\REZVIVO\\Installer"','DeleteRegKey HKCU "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\REZVIVO"','SectionEnd']
    script=a.out/('client-update.nsi' if a.baseline else 'client-installer.nsi');script.write_text('\n'.join(lines)+'\n',encoding='utf-8-sig')
    subprocess.run([str(Path(a.nsis).resolve()),'/V3',str(script)],check=True)
    metadata=dict(build=release['build'],version=version,filename=installer.name,sha256=digest(installer),size_bytes=installer.stat().st_size,allowed=True,published=False,
      notes=release.get('notes', 'REZVIVO '+version+'.'))
    package=dict(metadata,kind='delta' if a.baseline else 'full',installer_protocol=1,**components(selected))
    if a.baseline:package['from_manifest_sha256']=baseline_sha
    sidecar=a.out/(full_name+'.packages.json')
    variants=json.loads(sidecar.read_text(encoding='utf-8')) if sidecar.exists() else dict(packages=[])
    variants['packages']=[p for p in variants['packages'] if p.get('from_manifest_sha256','')!=baseline_sha]+[package]
    sidecar.write_text(json.dumps(variants,indent=2)+'\n',encoding='utf-8')
    if not a.baseline:(a.out/'release-publication.json').write_text(json.dumps(metadata,indent=2)+'\n',encoding='utf-8')
    print('Installer:',installer,'MiB:',round(installer.stat().st_size/2**20,1),flush=True)
if __name__=='__main__':main()

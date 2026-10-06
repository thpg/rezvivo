unit GameShaderCache;

{$mode objfpc}{$H+}

interface

{ Call before opening the first GL context. These are process-local hints;
  driver control-panel settings and other applications are not changed. }
procedure ConfigureDriverShaderCache;
{ Call once with the first GL context current, before preparing game scenes. }
procedure ConfigureProgramShaderCache;

implementation

uses SysUtils {$ifdef MSWINDOWS}, Windows, CastleGLVersion {$endif};

procedure ConfigureDriverShaderCache;
{$ifdef MSWINDOWS}
var
  Directory, ShortDirectory: string;
  WideDirectory: UnicodeString;
{$endif}
begin
  {$ifdef MSWINDOWS}
  { Loading our glProgramBinary files does not populate NVIDIA's native
    shader cache. ConfigureProgramShaderCache selects source compilation,
    so the native variants survive process exit instead of stalling again
    when a rider/material first enters the view. Isolate the game's entries
    from browsers/editors filling the driver's shared cache budget. }
  if SysUtils.GetEnvironmentVariable('__GL_SHADER_DISK_CACHE_PATH') <> '' then Exit;
  if SysUtils.GetEnvironmentVariable('__GL_SHADER_DISK_CACHE') = '0' then Exit;
  Directory := SysUtils.GetEnvironmentVariable('REZVIVO_TEST_SHADER_CACHE_DIR');
  if Directory = '' then
    Directory := IncludeTrailingPathDelimiter(GetAppConfigDir(False)) + 'shader-cache';
  Directory := IncludeTrailingPathDelimiter(Directory) + 'driver';
  try
    if not ForceDirectories(Directory) then Exit;
    { Some driver versions read this variable through an ANSI API. Keep
      Cyrillic Windows account names usable without relocating user data. }
    ShortDirectory := ExtractShortPathName(Directory);
    if ShortDirectory <> '' then Directory := ShortDirectory;
    WideDirectory := UTF8Decode(Directory);
    if not Windows.SetEnvironmentVariableW('__GL_SHADER_DISK_CACHE_PATH',
      PWideChar(WideDirectory)) then Exit;
    Windows.SetEnvironmentVariableW('__GL_SHADER_DISK_CACHE', '1');
    { Keep the driver's normal bounded eviction policy; no skip-cleanup. }
  except
    { A disposable cache must never prevent the application from opening. }
  end;
  {$endif}
end;

procedure ConfigureProgramShaderCache;
begin
  {$ifdef MSWINDOWS}
  { Keep the existing binary cache on other drivers and in the editors.
    Respect explicit diagnostic overrides. Source linking is necessary to
    populate the NVIDIA disk cache; loading an application binary only
    reuses native entries that have already been compiled in an earlier run. }
  if (GLVersion <> nil) and (GLVersion.VendorType = gvNvidia) and
     (SysUtils.GetEnvironmentVariable('REZVIVO_SHADER_CACHE') = '') and
     (SysUtils.GetEnvironmentVariable('__GL_SHADER_DISK_CACHE_PATH') <> '') and
     (SysUtils.GetEnvironmentVariable('__GL_SHADER_DISK_CACHE') <> '0') then
    Windows.SetEnvironmentVariableW('REZVIVO_SHADER_CACHE', '0');
  {$endif}
end;

end.

unit AppRuntimePaths;
{$mode objfpc}{$H+}

interface

{ Android loads the game as a library, with no command line. In FPC 3.2.2
  the reconstructed argc/argv may contain invalid pointers. Never read them. }
function AppParamCount: Integer;
function AppParamStr(Index: Integer): String;
{ Writable application root on Android, executable directory on desktop.
  Mobile callers must wait for Application.OnInitialize before accessing it. }
function AppDirectory: String;

implementation
uses SysUtils
  {$ifdef ANDROID}, CastleApplicationProperties, CastleFilesUtils, CastleURIUtils{$endif};

function AppParamCount: Integer;
begin
  {$ifdef ANDROID}Result:=0;{$else}Result:=ParamCount;{$endif}
end;

function AppParamStr(Index: Integer): String;
begin
  {$ifdef ANDROID}
  if Index=0 then Result:=ApplicationProperties.ApplicationName else Result:='';
  {$else}Result:=ParamStr(Index);{$endif}
end;

function AppDirectory: String;
begin
  {$ifdef ANDROID}
  if ApplicationConfigOverride='' then
    raise Exception.Create('Application paths accessed before Android initialization');
  Result:=IncludeTrailingPathDelimiter(URIToFilenameSafe('castle-config:/'));
  {$else}
  Result:=ExtractFilePath(ParamStr(0));
  {$endif}
end;

end.

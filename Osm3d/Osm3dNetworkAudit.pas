unit Osm3dNetworkAudit;
{$mode objfpc}{$H+}
interface
procedure AuditMapRequest(const URL, Method: string; Status, Bytes: Integer;
  ElapsedMs: QWord);
implementation
uses Classes, SysUtils, DateUtils, fpjson, URIParser;
var AuditPath: string; AuditLock: TRTLCriticalSection;
procedure AuditMapRequest(const URL, Method: string; Status, Bytes: Integer;
  ElapsedMs: QWord);
var J:TJSONObject; S:RawByteString; F:TFileStream; U:TURI; Stamp:TDateTime;
begin
  if AuditPath='' then Exit;
  try
    U:=ParseURI(URL,False);
    J:=TJSONObject.Create;
    try
      Stamp:=Now;
      J.Add('time',DateTimeToUnix(Stamp,False));
      J.Add('time_ms',DateTimeToUnix(Stamp,False)*Int64(1000)+MilliSecondOfTheSecond(Stamp));
      { Intentionally no query, userinfo, headers, body or account details. }
      J.Add('url',U.Protocol+'://'+U.Host+U.Path+U.Document);
      J.Add('method',Method);J.Add('status',Status);J.Add('bytes',Bytes);
      J.Add('ms',Int64(ElapsedMs));S:=J.AsJSON+LineEnding;
    finally J.Free;end;
    EnterCriticalSection(AuditLock);
    try
      if FileExists(AuditPath) then F:=TFileStream.Create(AuditPath,fmOpenWrite or fmShareDenyNone)
      else F:=TFileStream.Create(AuditPath,fmCreate);
      try F.Seek(0,soEnd);F.WriteBuffer(S[1],Length(S));finally F.Free;end;
    finally LeaveCriticalSection(AuditLock);end;
  except on E:Exception do ;end;
end;
initialization
  InitCriticalSection(AuditLock);
  AuditPath:=GetEnvironmentVariable('REZVIVO_MAP_REQUEST_LOG');
{ Optional network-only diagnostics. No normal log traffic; keep teardown lock alive. }
end.

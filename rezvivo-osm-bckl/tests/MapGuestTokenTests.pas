program MapGuestTokenTests;
{$mode objfpc}{$H+}
uses Classes,SysUtils,Osm3dOsmAccess,Osm3dPlatformHttp,Osm3dCache,Osm3dCacheHTTPFetcher;
const MapURL='https://rezvivo.com/osm/api/interpreter';
type
  TRequest=class(TOsmPlatformHttpRequest)
    procedure Execute(const Method,Url:string;Headers:TStrings;Body:TStream;
      ConnectMs,ReadMs:Integer;Response:TStream;out Status:Integer;ResponseHeaders:TStrings);override;
    procedure Cancel;override;
  end;
  TWorker=class(TThread)
    Token,ErrorText:string;
    procedure Execute;override;
  end;
var Issues,Reads,RejectReads:LongInt; Account:string; RejectAlways:Boolean;
function Provider:string;begin Result:=Account end;
procedure Check(OK:Boolean;const Msg:string);begin if not OK then raise Exception.Create(Msg) end;
function Header(H:TStrings;const Name:string):string;
var I,P:Integer;
begin
  Result:='';
  for I:=0 to H.Count-1 do begin
    P:=Pos(':',H[I]);
    if (P>0) and SameText(Copy(H[I],1,P-1),Name) then begin
      Check(Result='','Duplicate '+Name);Result:=Trim(Copy(H[I],P+1,MaxInt));
    end;
  end;
end;
function Factory:TOsmPlatformHttpRequest;begin Result:=TRequest.Create end;
procedure TRequest.Cancel;begin end;
procedure TRequest.Execute(const Method,Url:string;Headers:TStrings;Body:TStream;
  ConnectMs,ReadMs:Integer;Response:TStream;out Status:Integer;ResponseHeaders:TStrings);
var Data,Credential:string;N:Integer;
begin
  Status:=200;Credential:=Header(Headers,'Authorization');
  if Pos('/osm/guest-token',Url)>0 then begin
    N:=InterlockedIncrement(Issues);
    Check((Credential='') and NoRedirects and (MaxResponseBytes=8192),'unsafe token request');
    Check(Method='POST','wrong issuance method');
    Sleep(75);
    Data:='{"access_token":"guest-fixture-token-'+IntToStr(N)+'","token_type":"Bearer","scope":"map:read","expires_in":3600}';
  end else begin
    InterlockedIncrement(Reads);
    if Pos('fixture.invalid',Url)>0 then Check(Credential='','credential leaked to a mirror')
    else begin
      Check((Credential<>'') and NoRedirects,'missing map credential or redirects allowed');
      if RejectAlways or (RejectReads>0) then begin
        Status:=401;if RejectReads>0 then Dec(RejectReads);
      end;
    end;
    Data:='{"elements":[{"id":1}]}';
  end;
  ResponseHeaders.Add('Content-Type: application/json');
  Response.WriteBuffer(Data[1],Length(Data));
end;
procedure TWorker.Execute;
var Guest:Boolean;
begin
  try Token:=MapAccessToken(MapURL,nil,Guest);Check(Guest,'worker not guest');
  except on E:Exception do ErrorText:=E.Message end;
end;
var Token,OldToken:string;Guest:Boolean;I,Before:Integer;
    Workers:array[0..15]of TWorker;F:THTTPFetcherWithCache;R:TFetchResult;
begin
  OsmPlatformHttpFactory:=@Factory;OsmAccessTokenProvider:=@Provider;
  Token:=MapAccessToken(MapURL,nil,Guest);Check(Guest and (Issues=1),'first issue');
  Check(MapAccessToken('https://rezvivo.ru/height/mapzen-geotiff-v1/12/1/1.png',nil,Guest)=Token,'tile workers failed to share token');
  OldToken:=Token;InvalidateMapGuestToken(Token);
  for I:=0 to High(Workers) do begin Workers[I]:=TWorker.Create(True);Workers[I].Start end;
  for I:=0 to High(Workers) do Workers[I].WaitFor;
  Token:=Workers[0].Token;
  for I:=0 to High(Workers) do begin
    Check((Workers[I].ErrorText='') and (Workers[I].Token=Token),'worker failure');Workers[I].Free;
  end;
  Check(Issues=2,'concurrent workers issued duplicate tokens');
  InvalidateMapGuestToken(OldToken);
  Check(MapAccessToken(MapURL,nil,Guest)=Token,'late 401 erased refreshed token');
  Check(Issues=2,'late 401 caused another issue');
  F:=THTTPFetcherWithCache.Create(TMemoryCache.Create,True);
  try
    F.MaxRetries:=1;RejectReads:=1;
    R:=F.PostString(MapURL,'query');
    Check(R.Success and (Reads=2) and (Issues=3),'401 did not renew guest and retry once');
    Before:=Reads;R:=F.PostString(MapURL,'query');
    Check(R.Success and R.FromCache and (Reads=Before),'token changed cache behavior');
    RejectAlways:=True;Before:=Issues;
    R:=F.PostString(MapURL,'rejected');
    Check(not R.Success and (R.StatusCode=401) and (Issues=Before+1),'unbounded or missing refresh');
    Account:='fixture-account-token';Before:=Issues;
    R:=F.PostString(MapURL,'revoked-account');
    Check(not R.Success and (R.StatusCode=401) and (Issues=Before),'account rejection downgraded to guest');
    RejectAlways:=False;
    Token:=MapAccessToken(MapURL,nil,Guest);Check(not Guest and (Token=Account),'account not preferred');
    Account:='';R:=F.PostString('https://fixture.invalid/api/interpreter','public');
    Check(R.Success,'public mirror failed');
    F.AbortAllRequests;Before:=Issues;
    R:=F.PostString(MapURL,'after-abort');Check(not R.Success and (Issues=Before),'aborted request obtained credential');
  finally F.Free;OsmAccessTokenProvider:=nil;OsmPlatformHttpFactory:=nil end;
  Writeln('PASS guest tokens: issue, shared cache, 16 workers, late 401, refresh, retry bound, account isolation, mirror isolation, abort');
end.

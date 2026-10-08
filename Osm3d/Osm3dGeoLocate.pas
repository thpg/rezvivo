unit Osm3dGeoLocate;

{ Osm3d-юниты отлаживались с выключенными overflow/range проверками. }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage UTF8}

{ Best-effort user location (no GPS): geolocate by public IP via the project's caching
  HTTP fetcher, used to open the flat map near the user when no FIT/GPX route is loaded.
  TryLocateByIp is synchronous; TIpLocateThread runs it off-thread and exposes the result
  via a lock-guarded Poll — no Synchronize, so no teardown deadlock. }

interface

uses
  Classes,
  SysUtils,
  SyncObjs;

type
  { Background IP-geolocation: Create, then Poll() from the main thread. Owner frees it;
    WaitFor is deadlock-free because Execute never calls Synchronize. }
  TIpLocateThread = class(TThread)
  private
    FLock: TCriticalSection;
    FDone: Boolean;
    FOk:   Boolean;
    FLat:  Double;
    FLon:  Double;
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor  Destroy; override;

    { Main-thread snapshot of the current state. Returns True once the lookup
      has finished (then AOk says whether it succeeded and ALat/ALon hold the
      result). }
    function Poll(out ADone, AOk: Boolean; out ALat, ALon: Double): Boolean;
  end;

{ Synchronous lookup. Returns False if every service failed or the IP could
  not be resolved to a plausible coordinate. }
function TryLocateByIp(out ALat, ALon: Double): Boolean;

implementation

uses
  fphttpclient,
  opensslsockets,
  fpjson,
  jsonparser,
  Osm3dCache,
  Osm3dCacheHTTPFetcher;

{ Pull a plausible lat/lon from the JSON. Handles both namings: latitude/longitude and lat/lon. }
function ParseLatLon(const ABody: TBytes; out ALat, ALon: Double): Boolean;
var
  J:  TJSONData;
  O:  TJSONObject;
  S:  string;

  function Num(const AKey: string; out AValue: Double): Boolean;
  var
    D: TJSONData;
  begin
    D := O.Find(AKey);
    Result := (D <> nil) and (D.JSONType = jtNumber);
    if Result then
      AValue := D.AsFloat;
  end;

begin
  Result := False;
  ALat := 0; ALon := 0;
  if Length(ABody) = 0 then Exit;

  SetLength(S, Length(ABody));
  System.Move(ABody[0], S[1], Length(ABody));

  J := nil;
  try
    J := GetJSON(S);
  except
    on E: Exception do
      J := nil;
  end;
  if J = nil then Exit;

  try
    if not (J is TJSONObject) then Exit;
    O := TJSONObject(J);

    if (Num('latitude', ALat) and Num('longitude', ALon)) or
       (Num('lat', ALat) and Num('lon', ALon)) then
      Result := (ALat >= -90.0)  and (ALat <= 90.0) and
                (ALon >= -180.0) and (ALon <= 180.0) and
                { (0,0) is the classic "couldn't resolve" sentinel }
                not ((Abs(ALat) < 1.0e-9) and (Abs(ALon) < 1.0e-9));
  finally
    J.Free;
  end;
end;

function FetchAndParse(AFetcher: THTTPFetcherWithCache; const AUrl: string;
  out ALat, ALon: Double): Boolean;
var
  R: TFetchResult;
begin
  Result := False;
  try
    R := AFetcher.GetUrl(AUrl);
  except
    on E: Exception do
      Exit;
  end;
  if R.Success and (Length(R.Data) > 0) then
    Result := ParseLatLon(R.Data, ALat, ALon);
end;

function TryLocateByIp(out ALat, ALon: Double): Boolean;
var
  F: THTTPFetcherWithCache;
begin
  Result := False;
  ALat := 0; ALon := 0;

  { Own short-timeout fetcher with a tiny cache (this call doesn't belong in the tile cache). }
  F := THTTPFetcherWithCache.Create(TMemoryCache.Create(256 * 1024), True);
  try
    F.UserAgent  := 'osm3d-geolocate/1.0 (+https://github.com/local/osm3d)';
    F.TimeoutMs  := 4000;   { bound app-close WaitFor: GET can't be aborted }
    F.MaxRetries := 1;

    { HTTPS services first, plaintext fallback last. First plausible hit wins. }
    if FetchAndParse(F, 'https://ipapi.co/json/',  ALat, ALon) then Exit(True);
    if FetchAndParse(F, 'https://ipwho.is/',        ALat, ALon) then Exit(True);
  finally
    F.Free;
  end;
end;

{ ── TIpLocateThread ─────────────────────────────────────────────────── }

constructor TIpLocateThread.Create;
begin
  FLock := TCriticalSection.Create;
  FDone := False;
  FOk   := False;
  FLat  := 0;
  FLon  := 0;
  inherited Create(False);   { start at once; NOT FreeOnTerminate }
end;

destructor TIpLocateThread.Destroy;
begin
  inherited Destroy;         { TThread.Destroy terminates + WaitFor (safe: no Synchronize) }
  FLock.Free;
end;

procedure TIpLocateThread.Execute;
var
  L, Lo: Double;
  Ok:    Boolean;
begin
  Ok := TryLocateByIp(L, Lo);
  FLock.Enter;
  try
    FOk  := Ok;
    FLat := L;
    FLon := Lo;
    FDone := True;
  finally
    FLock.Leave;
  end;
end;

function TIpLocateThread.Poll(out ADone, AOk: Boolean;
  out ALat, ALon: Double): Boolean;
begin
  FLock.Enter;
  try
    ADone := FDone;
    AOk   := FOk;
    ALat  := FLat;
    ALon  := FLon;
  finally
    FLock.Leave;
  end;
  Result := ADone;
end;

end.

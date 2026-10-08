unit Osm3dStudioUtils;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$codepage UTF8}

{$DEFINE OSM3D_WITH_FITFILE}
{$IFNDEF OSM3D_WITH_FITFILE}
{$ERROR This unit requires OSM3D_WITH_FITFILE and RouteWorkoutFile/FitFile in the search path}
{$ENDIF}

interface

uses
  Classes,
  SysUtils,
  Osm3dOsmData,
  Osm3dOsmTagUtils,   { InvariantFmt }
  Osm3dGeoMath,
  Osm3dMapUtils,
  DebugLog in '..\rezvivo-osm-bckl\code\DebugLog.pas',
  TrainerData in '..\rezvivo-osm-bckl\code\TrainerData.pas',
  GameSensorLog in '..\rezvivo-osm-bckl\code\GameSensorLog.pas',
  FitFile in '..\rezvivo-osm-bckl\code\FitFile.pas',
  GpxFile in '..\rezvivo-osm-bckl\code\GpxFile.pas',
  RouteWorkoutFile in '..\rezvivo-osm-bckl\code\RouteWorkoutFile.pas'
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

type
  TCsvRouteLoader = class
  public
    { Raises Exception on I/O error or empty file. }
    class function Load(const FileName: string): TRouteLatLonArray;

    { For tests / clipboard input. }
    class function Parse(const Content: string): TRouteLatLonArray;
  end;

type
  TFitAdapter = class
  public
    { Loads a .fit file in one pass: points + origin + start UTC.

      Coordinate parity with FitFile.ConvertGpsToRoutePoints:
        forward:  East  = (lon-orig)·(π/180)·R·cos(originLat·π/180);
                  North = (lat-orig)·(π/180)·R;
                  Position.X := -East;  Position.Z := North
        inverse:  East  := -Position.X;  North := Position.Z;
                  lat   := orig + North / (R·π/180);
                  lon   := orig + East  / (R·π/180·cos(orig·π/180))
      Uses EARTH_RADIUS_M from Osm3dGeoMath — same constant as
      TLocalProjection — so forward+inverse round-trips to Double precision.

      Returns nil if file unreadable, no origin, or < 2 points;
      out params then undefined. StartUTC = 0 if no timestamps in file. }
    class function LoadAsLatLonArray(const FileName: string;
      out OriginLat, OriginLon: Double;
      out StartUTC: TDateTime): TRouteLatLonArray; overload;

    { As above, plus the per-point original FIT altitude (absolute metres),
      parallel to the returned lat/lon array. AAlt is empty if the file
      carried no altitude. Used to draw the blue "original height" spheres. }
    class function LoadAsLatLonArray(const FileName: string;
      out OriginLat, OriginLon: Double; out StartUTC: TDateTime;
      out AAlt: TRouteAltArray): TRouteLatLonArray; overload;

    class function LoadAsLatLonArray(const FileName: string): TRouteLatLonArray; overload;

    { Caller manages TFitFile lifecycle. }
    class function FromFitFile(Fit: TFitFile): TRouteLatLonArray;
  end;

{ Truncate long URLs (e.g. Overpass queries) for display. }
function ShortenUrl(const URL: string; MaxLen: Integer = 100): string;

{ < 1024 → "N B"; < 1 MiB → "%.1f KB"; else "%.1f MB". }
function FormatBytes(N: Int64): string;

{ 'https://overpass.kumi.systems/api/...' → 'overpass.kumi.systems'. }
function HostFromUrl(const URL: string): string;

implementation

uses
  StrUtils;

function TryParseFloat(const S: string; out V: Double): Boolean;
var T: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(945);{$ENDIF}
  T := StringReplace(Trim(S), ',', '.', [rfReplaceAll]);
  Result := TryStrToFloat(T, V, InvariantFmt);
end;

class function TCsvRouteLoader.Parse(const Content: string): TRouteLatLonArray;
var
  Lines: TStringList;
  I, CommaCount, FirstComma, P: Integer;
  Line, LatStr, LonStr: string;
  Lat, Lon: Double;
  Count: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1281);{$ENDIF}
  Result := nil;
  Lines := TStringList.Create;
  try
    Lines.Text := Content;
    SetLength(Result, Lines.Count);
    Count := 0;

    for I := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[I]);
      if (Line = '') or (Line[1] = '#') then Continue;

      CommaCount := 0;
      for P := 1 to Length(Line) do
        if Line[P] = ',' then Inc(CommaCount);

      if CommaCount = 0 then Continue;

      FirstComma := Pos(',', Line);
      LatStr := Copy(Line, 1, FirstComma - 1);
      LonStr := Copy(Line, FirstComma + 1, MaxInt);
      P := Pos(',', LonStr);
      if P > 0 then LonStr := Copy(LonStr, 1, P - 1);

      if not TryParseFloat(LatStr, Lat) then Continue;
      if not TryParseFloat(LonStr, Lon) then Continue;

      Result[Count] := TLatLon.Make(Lat, Lon);
      Inc(Count);
    end;

    SetLength(Result, Count);
  finally
    Lines.Free;
  end;
end;

class function TCsvRouteLoader.Load(const FileName: string): TRouteLatLonArray;
var
  Lines: TStringList;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1282);{$ENDIF}
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(FileName);
    Result := Parse(Lines.Text);
    if Length(Result) = 0 then
      raise Exception.CreateFmt(
        'CSV "%s" contains no valid lat,lon points', [FileName]);
  finally
    Lines.Free;
  end;
end;

class function TFitAdapter.FromFitFile(Fit: TFitFile): TRouteLatLonArray;
var
  I: Integer;
  CosLat, MetersPerDegLat, MetersPerDegLon: Double;
  EastM, NorthM, LatDeg, LonDeg: Double;
  P: TRoutePoint;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1283);{$ENDIF}
  Result := nil;
  if Fit = nil then Exit;
  if not Fit.HasOrigin then Exit;
  if Length(Fit.RoutePoints) < 2 then Exit;

  CosLat := Cos(Fit.OriginLatDeg * DEG_TO_RAD);
  if Abs(CosLat) < 1.0e-9 then CosLat := 1.0e-9;     { near the pole }

  MetersPerDegLat := EARTH_RADIUS_M * DEG_TO_RAD;        { ≈ 111195 m/° }
  MetersPerDegLon := MetersPerDegLat * CosLat;

  SetLength(Result, Length(Fit.RoutePoints));
  for I := 0 to High(Fit.RoutePoints) do
  begin
    P := Fit.RoutePoints[I];
    EastM   := -P.Position.X;
    NorthM  :=  P.Position.Z;

    LatDeg := Fit.OriginLatDeg + NorthM / MetersPerDegLat;
    LonDeg := Fit.OriginLonDeg + EastM  / MetersPerDegLon;

    Result[I] := TLatLon.Make(LatDeg, LonDeg);
  end;
end;

class function TFitAdapter.LoadAsLatLonArray(const FileName: string;
  out OriginLat, OriginLon: Double;
  out StartUTC: TDateTime): TRouteLatLonArray;
var
  Fit: TFitFile;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1284);{$ENDIF}
  Result    := nil;
  OriginLat := 0;
  OriginLon := 0;
  StartUTC  := 0;

  Fit := NewRouteParserForFile(FileName);   { .fit → TFitFile, .gpx → TGpxFile }
  try
    if not Fit.LoadFromFile(FileName) then Exit;
    OriginLat := Fit.OriginLatDeg;
    OriginLon := Fit.OriginLonDeg;
    StartUTC  := FitTimestampToUTC(Fit.StartTimestampSec);
    Result    := FromFitFile(Fit);
  finally
    Fit.Free;
  end;
end;

class function TFitAdapter.LoadAsLatLonArray(
  const FileName: string): TRouteLatLonArray;
var
  Lat, Lon: Double;
  UTC: TDateTime;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1285);{$ENDIF}
  Result := LoadAsLatLonArray(FileName, Lat, Lon, UTC);
end;

class function TFitAdapter.LoadAsLatLonArray(const FileName: string;
  out OriginLat, OriginLon: Double; out StartUTC: TDateTime;
  out AAlt: TRouteAltArray): TRouteLatLonArray;
var
  Fit: TFitFile;
  I:   Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1764);{$ENDIF}
  Result    := nil;
  AAlt      := nil;
  OriginLat := 0;
  OriginLon := 0;
  StartUTC  := 0;

  Fit := NewRouteParserForFile(FileName);   { .fit → TFitFile, .gpx → TGpxFile }
  try
    if not Fit.LoadFromFile(FileName) then Exit;
    OriginLat := Fit.OriginLatDeg;
    OriginLon := Fit.OriginLonDeg;
    StartUTC  := FitTimestampToUTC(Fit.StartTimestampSec);
    Result    := FromFitFile(Fit);
    { Copy the altitude track by value — Fit is freed below. Only kept when
      it is parallel to the returned points (defensive: same length). }
    if Length(Fit.RouteAltM) = Length(Result) then
    begin
      SetLength(AAlt, Length(Fit.RouteAltM));
      for I := 0 to High(Fit.RouteAltM) do
        AAlt[I] := Fit.RouteAltM[I];
    end;
  finally
    Fit.Free;
  end;
end;

function ShortenUrl(const URL: string; MaxLen: Integer): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(946);{$ENDIF}
  if Length(URL) <= MaxLen then
    Result := URL
  else
    Result := Copy(URL, 1, MaxLen - 3) + '...';
end;

function FormatBytes(N: Int64): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(947);{$ENDIF}
  if N < 1024 then
    Result := IntToStr(N) + ' B'
  else if N < 1024 * 1024 then
    Result := Format('%.1f KB', [N / 1024])
  else
    Result := Format('%.1f MB', [N / (1024 * 1024)]);
end;

function HostFromUrl(const URL: string): string;
var
  P, Q: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(948);{$ENDIF}
  P := Pos('://', URL);
  if P = 0 then Exit(URL);
  P := P + 3;
  Q := PosEx('/', URL, P);
  if Q = 0 then
    Result := Copy(URL, P, MaxInt)
  else
    Result := Copy(URL, P, Q - P);
end;

end.

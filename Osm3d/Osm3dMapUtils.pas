unit Osm3dMapUtils;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$codepage UTF8}

{$WARN 5093 OFF}  { FPC false-positives on dynamic-array initialisation }

interface

uses
  Classes,
  SysUtils,
  Math,
  CastleVectors,
  Osm3dGeoMath,
  Osm3dHeightmap,
  Osm3dGeomMesh,
  Osm3dGlslLib           { DEFAULT_SUN_RAY_DIR — единый дефолт солнца }
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

type
  TRouteLatLonArray  = array of TLatLon;
  TRouteVector3Array = array of TVector3;
  { Per-route-point road width in metres: width of the road the point
    was snapped onto, or 0 when the point is off-road (not snapped). }
  TRouteWidthArray   = array of Single;
  { Per-route-point original altitude (m), decoded straight from the FIT track (absolute, before
    terrain sampling). Drives the blue "original height" markers. Parallel to the lat/lon array;
    empty when the source carried no altitude. }
  TRouteAltArray     = array of Single;
  { Per-route-point OSM way id the point was snapped onto; 0 = off-road /
    not snapped. Parallel to the snapped route. Composite road vertices
    carry the same ids (bridge decks — the bridge way id), so a consumer
    can take marker/path height from the surface of exactly the road the
    point snapped to: on a bridge that is the DECK, not the terrain (or
    river) underneath it. }
  TRouteWayIdArray   = array of Int64;
  PRouteWayIdArray   = ^TRouteWayIdArray;

  TRouteSrc = class
  public
    { Empty box for an empty array. }
    class function BboxFromPoints(const Points: array of TLatLon): TLatLonBox;

    { Pad bbox by N metres in all directions using lat/lon scale at the
      bbox centre. Accurate for bbox < 50 km. }
    class function PadBboxMeters(const Box: TLatLonBox;
      PaddingMeters: Single): TLatLonBox;

    { Arithmetic mean of all points — good for closed/loop routes. }
    class function OriginCentroid(const Points: array of TLatLon): TLatLon;

    { Lat/lon → (X, 0, Z). Caller fills Y later, or uses ProjectPolylineOnTerrain. }
    class function ProjectPolyline(const Points: array of TLatLon;
      Projection: TLocalProjection): TRouteVector3Array;

    { Sum of haversine distances between consecutive points. }
    class function TotalLengthMeters(const Points: array of TLatLon): Double;
  end;

  TSunPos = record
    AzimuthDeg:  Double;  { 0=N, 90=E, 180=S, 270=W (clockwise) }
    AltitudeDeg: Double;  { >0 above horizon }
  end;

  TSunCalc = class
  public
    { LatDeg/LonDeg positive N/E; UTC is UTC TDateTime (not local). }
    class function CalcPosition(LatDeg, LonDeg: Double;
                                UTC: TDateTime): TSunPos; static;

    { Unit direction the light travels (= -sunVector). When sun is below
      horizon, returns a safe daytime fallback so scenes are never unlit. }
    class function ToLightDir(const Pos: TSunPos): TVector3; static;

    { Resolve the existing world-lighting convention once per route. Missing
      UTC uses the canonical daytime direction and enables shadows. A real
      timestamp retains its solar shadow eligibility even when ToLightDir
      uses the legacy daytime material lighting below the horizon. }
    class function ResolveRouteSun(LatDeg, LonDeg: Double; UTC: TDateTime;
      out LightDir: TVector3): Boolean; static;
  end;

implementation

function JulianDay(Y, M, D: Integer; HourFrac: Double): Double;
var
  A, B: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(586);{$ENDIF}
  if M <= 2 then begin Dec(Y); Inc(M, 12); end;
  A := Y div 100;
  B := 2 - A + A div 4;
  Result := Trunc(365.25  * (Y + 4716)) +
            Trunc(30.6001 * (M + 1))    +
            D + HourFrac / 24.0 + B - 1524.5;
end;

function FMod360(X: Double): Double; inline;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(587);{$ENDIF}
  Result := X - 360.0 * Floor(X / 360.0);
end;

class function TSunCalc.CalcPosition(LatDeg, LonDeg: Double;
  UTC: TDateTime): TSunPos;
var
  Yr, Mo, Dy, H, Mi, S, Ms: Word;
  HourFrac, JD, JC: Double;
  L0, MAnom, Eccen, C, Theta, Omega, Lambda: Double;
  Eps0, Eps, SinEps, SinLam: Double;
  Decl, Y, EqT, SolTime, HA: Double;
  LatR, DeclR, HAR, SinAlt, CosZen, Zenith: Double;
  SinZen, AzDenom, CosAz, AzDeg: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1182);{$ENDIF}
  DecodeDate(UTC, Yr, Mo, Dy);
  DecodeTime(UTC, H, Mi, S, Ms);
  HourFrac := H + Mi / 60.0 + S / 3600.0 + Ms / 3600000.0;

  JD := JulianDay(Yr, Mo, Dy, HourFrac);
  JC := (JD - 2451545.0) / 36525.0;  { Julian Century from J2000.0 }

  L0    := FMod360(280.46646 + JC * (36000.76983 + JC * 0.0003032));
  MAnom := FMod360(357.52911 + JC * (35999.05029 - JC * 0.0001537));
  Eccen := 0.016708634 - JC * (0.000042037 + JC * 0.0000001267);

  { Equation of center }
  C := Sin(DegToRad(MAnom))   * (1.914602 - JC * (0.004817 + JC * 0.000014))
     + Sin(DegToRad(2*MAnom)) * (0.019993 - JC * 0.000101)
     + Sin(DegToRad(3*MAnom)) * 0.000289;

  Theta  := L0 + C;
  Omega  := FMod360(125.04 - 1934.136 * JC);
  Lambda := Theta - 0.00569 - 0.00478 * Sin(DegToRad(Omega));

  Eps0 := 23.0 + (26.0 + (21.448 - JC * (46.815 + JC * (0.00059 - JC * 0.001813))) / 60.0) / 60.0;
  Eps  := Eps0 + 0.00256 * Cos(DegToRad(Omega));

  SinEps := Sin(DegToRad(Eps));
  SinLam := Sin(DegToRad(Lambda));

  Decl := RadToDeg(ArcSin(SinEps * SinLam));

  Y    := Sqr(Tan(DegToRad(Eps / 2.0)));
  EqT  := 4.0 * RadToDeg(
      Y    * Sin(DegToRad(2.0 * L0))
    - 2.0 * Eccen * Sin(DegToRad(MAnom))
    + 4.0 * Eccen * Y * Sin(DegToRad(MAnom)) * Cos(DegToRad(2.0 * L0))
    - 0.5 * Y * Y * Sin(DegToRad(4.0 * L0))
    - 1.25 * Eccen * Eccen * Sin(DegToRad(2.0 * MAnom)));

  SolTime := HourFrac * 60.0 + EqT + 4.0 * LonDeg;
  SolTime := SolTime - 1440.0 * Floor(SolTime / 1440.0);   { normalise to [0,1440) }
  HA := SolTime / 4.0 - 180.0;   { −180..+180; 0 = solar noon }

  LatR  := DegToRad(LatDeg);
  DeclR := DegToRad(Decl);
  HAR   := DegToRad(HA);

  SinAlt  := Sin(LatR) * Sin(DeclR) + Cos(LatR) * Cos(DeclR) * Cos(HAR);
  SinAlt  := Max(-1.0, Min(1.0, SinAlt));
  CosZen  := SinAlt;
  Zenith  := RadToDeg(ArcCos(Max(-1.0, Min(1.0, CosZen))));
  Result.AltitudeDeg := 90.0 - Zenith;

  SinZen  := Sin(DegToRad(Zenith));
  AzDenom := Cos(LatR) * SinZen;
  if Abs(AzDenom) > 0.001 then
  begin
    CosAz := (Sin(LatR) * CosZen - Sin(DeclR)) / AzDenom;
    CosAz := Max(-1.0, Min(1.0, CosAz));
    AzDeg := 180.0 - RadToDeg(ArcCos(CosAz));
    if HA > 0.0 then AzDeg := -AzDeg;
    if AzDeg < 0.0 then AzDeg := AzDeg + 360.0;
    Result.AzimuthDeg := AzDeg;
  end
  else
  begin
    { Pole / exact zenith fallback. }
    if LatDeg > 0.0 then Result.AzimuthDeg := 180.0
    else                 Result.AzimuthDeg := 0.0;
  end;
end;

class function TSunCalc.ToLightDir(const Pos: TSunPos): TVector3;
var
  AzR, AltR: Single;
  SunVec: TVector3;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1183);{$ENDIF}
  { Existing material-lighting fallback, not proof of actual sunlight.
    ResolveRouteSun keeps genuine nighttime shadows disabled separately. }
  if Pos.AltitudeDeg <= 0.0 then
  begin
    Result := DEFAULT_SUN_RAY_DIR;
    Exit;
  end;

  AzR  := DegToRad(Pos.AzimuthDeg);
  AltR := DegToRad(Pos.AltitudeDeg);

  { Unit vector FROM scene TO sun (Z=N, −X=E, Y=up). }
  SunVec := Vector3(
    Single(-Sin(AzR) * Cos(AltR)),
    Single( Sin(AltR)),
    Single( Cos(AzR) * Cos(AltR))
  );

  Result := -SunVec;
end;

class function TSunCalc.ResolveRouteSun(LatDeg, LonDeg: Double;
  UTC: TDateTime; out LightDir: TVector3): Boolean;
var Pos: TSunPos;
begin
  if UTC <= 0 then
  begin
    LightDir := DEFAULT_SUN_RAY_DIR;
    Exit(True);
  end;
  Pos := CalcPosition(LatDeg, LonDeg, UTC);
  LightDir := ToLightDir(Pos);
  { Preserve the existing game cutoff for dawn/night. This flag must not be
    inferred from a material fallback direction, which is intentionally lit. }
  Result := Pos.AltitudeDeg >= 2.0;
end;

class function TRouteSrc.BboxFromPoints(
  const Points: array of TLatLon): TLatLonBox;
var
  I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1185);{$ENDIF}
  Result := TLatLonBox.Empty;
  for I := 0 to High(Points) do
    Result := Result.Include(Points[I]);
end;

class function TRouteSrc.PadBboxMeters(const Box: TLatLonBox;
  PaddingMeters: Single): TLatLonBox;
var
  CenterLat: Double;
  MetersPerDegLat, MetersPerDegLon: Double;
  PadLat, PadLon: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1186);{$ENDIF}
  if Box.IsEmpty or (PaddingMeters <= 0) then Exit(Box);

  CenterLat := (Box.MinLat + Box.MaxLat) * 0.5;
  MetersPerDegLat := EARTH_RADIUS_M * DEG_TO_RAD;
  MetersPerDegLon := MetersPerDegLat * Cos(CenterLat * DEG_TO_RAD);
  if MetersPerDegLon < 1 then MetersPerDegLon := 1;

  PadLat := PaddingMeters / MetersPerDegLat;
  PadLon := PaddingMeters / MetersPerDegLon;

  Result := TLatLonBox.Make(
    Box.MinLat - PadLat, Box.MinLon - PadLon,
    Box.MaxLat + PadLat, Box.MaxLon + PadLon);
end;

class function TRouteSrc.OriginCentroid(
  const Points: array of TLatLon): TLatLon;
var
  I: Integer;
  SumLat, SumLon: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1187);{$ENDIF}
  if Length(Points) = 0 then
    Exit(TLatLon.Make(0, 0));
  SumLat := 0;
  SumLon := 0;
  for I := 0 to High(Points) do
  begin
    SumLat := SumLat + Points[I].Lat;
    SumLon := SumLon + Points[I].Lon;
  end;
  Result := TLatLon.Make(SumLat / Length(Points), SumLon / Length(Points));
end;

class function TRouteSrc.ProjectPolyline(const Points: array of TLatLon;
  Projection: TLocalProjection): TRouteVector3Array;
var
  I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1189);{$ENDIF}
  if Projection = nil then
    raise Exception.Create('ProjectPolyline: Projection = nil');
  SetLength(Result, Length(Points));
  for I := 0 to High(Points) do
    Result[I] := Projection.Project(Points[I], 0);
end;

class function TRouteSrc.TotalLengthMeters(
  const Points: array of TLatLon): Double;
var
  I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1191);{$ENDIF}
  Result := 0;
  for I := 0 to High(Points) - 1 do
    Result := Result + Points[I].DistanceTo(Points[I + 1]);
end;

end.

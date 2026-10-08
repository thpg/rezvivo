unit Osm3dRoadSurface;

{$mode objfpc}{$H+}

interface

const ROAD_MAX_LANES = 32;
  ROAD_SURFACE_UNKNOWN = 0;
  ROAD_SURFACE_ASPHALT = 1;
  ROAD_SURFACE_OTHER = 2;
  ROAD_SURFACE_CONCRETE = 3;
  ROAD_STYLE_CONCRETE = 128;

type
  TRoadLaneLayout = record
    Count, BothWays, Custom: LongInt;
    Edge: Single;
    Widths: array[0..ROAD_MAX_LANES-1] of Single;
  end;

  { Optional cached profile. UVScale=0 identifies tiles written before this
    extension. Width remains in the containing centerline segment. }
  TRoadSurfaceProfile = record
    ForwardLanes, BackwardLanes: LongInt;
    UVMin, UVMax, UVScale: Single;
    Marked: LongInt;
    { Historical field name / serialized slot. ROAD_SURFACE_* values;
      3 distinguishes concrete from the old catch-all value 2. }
    Asphalt: LongInt;
    { 0: unspecified/old cache; 1: new, 2: good, 3: worn, 4: bad, 5: broken. }
    Condition: LongInt;
    Layout: TRoadLaneLayout;
    { Optional linear width at the centreline endpoints. Zero = legacy constant.
      The containing segment Width is the conservative maximum for spatial grids. }
    WidthStart, WidthEnd: Single;
  end;

function RoadConditionFromSmoothness(const Value: string): LongInt;
function RoadWidthAt(const Surface: TRoadSurfaceProfile; DefaultWidth, T: Single): Single; inline;
function RoadWidthAtPoint(const Surface: TRoadSurfaceProfile;
  DefaultWidth, X0,Z0,X1,Z1,X,Z: Single): Single; inline;

implementation
uses SysUtils, Math;

function RoadWidthAt(const Surface: TRoadSurfaceProfile; DefaultWidth, T: Single): Single;
begin
  if (Surface.WidthStart>0) and (Surface.WidthEnd>0) then
    Result:=Surface.WidthStart+(Surface.WidthEnd-Surface.WidthStart)*EnsureRange(T,0,1)
  else Result:=DefaultWidth;
end;

function RoadWidthAtPoint(const Surface: TRoadSurfaceProfile;
  DefaultWidth, X0,Z0,X1,Z1,X,Z: Single): Single;
var DX,DZ,L: Single;
begin
  if Surface.WidthStart<=0 then Exit(DefaultWidth);
  DX:=X1-X0;DZ:=Z1-Z0;L:=DX*DX+DZ*DZ;
  if L>1e-8 then L:=((X-X0)*DX+(Z-Z0)*DZ)/L else L:=0;
  Result:=RoadWidthAt(Surface,DefaultWidth,L);
end;

function RoadConditionFromSmoothness(const Value: string): LongInt;
var S: string;
begin
  S:=LowerCase(Trim(Value));
  if S='excellent' then Exit(1);
  if S='good' then Exit(2);
  if S='intermediate' then Exit(3);
  if S='bad' then Exit(4);
  { Severe smoothness values mostly describe unpaved roads. This visual
    profile never changes the surface type or claims to simulate passability. }
  if (S='very_bad') or (S='horrible') or (S='very_horrible') or
     (S='impassable') then Exit(5);
  Result:=0;
end;

end.

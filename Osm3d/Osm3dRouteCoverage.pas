unit Osm3dRouteCoverage;
{$mode objfpc}{$H+}
interface
uses Classes, SysUtils, Osm3dGeoMath, Osm3dGeoTileGrid, Osm3dMapUtils;
const ROUTE_SNAP_MARGIN_M = 60.0;
function RouteCoverageTiles(Grid:TGeoTileGrid;const Route:TRouteLatLonArray;
  MarginM:Double;Cancel:TThread=nil):TGeoTileIdArray;
implementation
uses Generics.Collections;
type TThreadAccess=class(TThread);
function SegmentHitsBox(const P0, P1: TLatLon; const B: TLatLonBox): Boolean;
var
  T0, T1, DLat, DLon: Double;

  function Clip(P, Q: Double): Boolean;
  var
    R: Double;
  begin
    Result := True;
    if P = 0 then Exit(Q >= 0);        { параллелен границе: внутри/снаружи }
    R := Q / P;
    if P < 0 then
    begin
      if R > T1 then Exit(False);
      if R > T0 then T0 := R;
    end
    else
    begin
      if R < T0 then Exit(False);
      if R < T1 then T1 := R;
    end;
  end;

begin
  T0 := 0.0;  T1 := 1.0;
  DLat := P1.Lat - P0.Lat;
  DLon := P1.Lon - P0.Lon;
  Result :=
        Clip(-DLon, P0.Lon - B.MinLon)
    and Clip( DLon, B.MaxLon - P0.Lon)
    and Clip(-DLat, P0.Lat - B.MinLat)
    and Clip( DLat, B.MaxLat - P0.Lat)
    and (T0 <= T1);
end;


function RouteCoverageTiles(Grid:TGeoTileGrid;const Route:TRouteLatLonArray;
  MarginM:Double;Cancel:TThread):TGeoTileIdArray;
var Seen:specialize TDictionary<Int64,TGeoTileId>;A:TGeoTileIdArray;
    B:TLatLonBox;T:TGeoTileId;Lo,Hi:TGeoTileId;I,J,N:Integer;K:Int64;
  procedure Check;
  begin if(Cancel<>nil)and TThreadAccess(Cancel).Terminated then raise EAbort.Create('Route check cancelled');end;
  procedure Sort(L,R:Integer);
  var X,Y:Integer;Pivot:QWord;Swap:TGeoTileId;
  begin
    X:=L;Y:=R;Pivot:=QWord(Result[(L+R) div 2].ToKey);
    repeat
      while QWord(Result[X].ToKey)<Pivot do Inc(X);
      while QWord(Result[Y].ToKey)>Pivot do Dec(Y);
      if X<=Y then begin Swap:=Result[X];Result[X]:=Result[Y];Result[Y]:=Swap;Inc(X);Dec(Y) end;
    until X>Y;
    if L<Y then Sort(L,Y);if X<R then Sort(X,R);
  end;
begin
  Result:=nil;if Length(Route)<2 then Exit;
  Seen:=specialize TDictionary<Int64,TGeoTileId>.Create;
  try
    { Enumerate each segment's corridor, not the entire route bounding box.
      A winding or diagonal route must not allocate all tiles in its interior. }
    for I:=0 to High(Route)-1 do begin
      Check;
      B:=TLatLonBox.Empty.Include(Route[I]).Include(Route[I+1]).ExpandMeters(MarginM);
      Lo:=Grid.TileAt(TLatLon.Make(B.MaxLat,B.MinLon));
      Hi:=Grid.TileAt(TLatLon.Make(B.MinLat,B.MaxLon));
      if(Hi.TX<Lo.TX)or(Hi.TY<Lo.TY)or
        ((QWord(Hi.TX)-Lo.TX+1)*(QWord(Hi.TY)-Lo.TY+1)>250000)then
        raise Exception.Create('Route segment covers too many tiles; check GPS gaps');
      A:=Grid.TilesCovering(B);
      for J:=0 to High(A)do begin
        T:=A[J];K:=T.ToKey;
        if not Seen.ContainsKey(K)and SegmentHitsBox(Route[I],Route[I+1],Grid.TileBox(T).ExpandMeters(MarginM))then Seen.Add(K,T);
      end;
    end;
    SetLength(Result,Seen.Count);N:=0;
    for T in Seen.Values do begin Result[N]:=T;Inc(N) end;
    if N>1 then Sort(0,N-1);
  finally Seen.Free end;
end;
end.

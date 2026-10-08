unit Osm3dGroundOpenings;
{$mode objfpc}{$H+}
{ Generation-only building ground cuts. No new runtime scene nodes/materials. }
interface
uses CastleVectors;
type
  TBuildingGroundOpening = array of TVector3;
  TBuildingGroundOpenings = array of TBuildingGroundOpening;
function InBuildingGroundOpening(const P:TVector3;
  const Openings:TBuildingGroundOpenings):Boolean;
{ Returns solid pieces with original footprint minus convex opening rings.
  Works with either winding and concave footprints. No caller-owned arrays
  are modified. All output Y=0; ordinary buildings should use the no-cut path. }
function SubtractBuildingGroundOpenings(const Footprint:array of TVector3;
  const Openings:TBuildingGroundOpenings):TBuildingGroundOpenings;
implementation
uses SysUtils, Math, Osm3dGeomUtils, Osm3dPolygonClipXZ;
function InBuildingGroundOpening(const P:TVector3;
  const Openings:TBuildingGroundOpenings):Boolean;
var I:Integer;
begin
  for I:=0 to High(Openings) do
    if TPolygonTriangulator.PointInPolygonXZ(P,Openings[I]) then Exit(True);
  Result:=False;
end;
function SubtractBuildingGroundOpenings(const Footprint:array of TVector3;
  const Openings:TBuildingGroundOpenings):TBuildingGroundOpenings;
const MaxPieces=8192;
var Work,Next:TXZClipPolygons;P,Cut:TXZClipPolygon;
  Tri:TIndexArray;I,J,K:Integer;Origin:TVector3;Convex:Boolean;Cross:Double;
  procedure Normalize(var Poly:TXZClipPolygon);
  var A,B:Integer;V:TVector2;
  begin
    if XZPolygonArea(Poly)>=0 then Exit;
    A:=0;B:=High(Poly);while A<B do begin V:=Poly[A];Poly[A]:=Poly[B];Poly[B]:=V;Inc(A);Dec(B) end;
  end;
begin
  Result:=nil;if Length(Footprint)<3 then Exit;
  if Length(Openings)=0 then begin
    SetLength(Result,1);SetLength(Result[0],Length(Footprint));
    for I:=0 to High(Footprint) do Result[0][I]:=Vector3(Footprint[I].X,0,Footprint[I].Z);
    Exit;
  end;
  { Subtract in a building-local frame: large projected world coordinates
    otherwise lose centimetres in repeated float32 intersections. }
  Origin:=Footprint[0];SetLength(P,Length(Footprint));
  for I:=0 to High(P) do P[I]:=Vector2(Footprint[I].X-Origin.X,Footprint[I].Z-Origin.Z);
  Normalize(P);Convex:=True;
  for I:=0 to High(P) do begin
    Cross:=XZCross(P[(I+1) mod Length(P)]-P[I],P[(I+2) mod Length(P)]-P[(I+1) mod Length(P)]);
    if Cross<-POLYGON_CLIP_EPS then begin Convex:=False;Break end;
  end;
  Work:=nil;
  if Convex then XZAppendPolygon(Work,P,MaxPieces)
  else begin
    Tri:=TPolygonTriangulator.TriangulateXZ(Footprint);
    if Length(Tri)<3 then raise EConvertError.Create('ground opening footprint cannot be triangulated');
    SetLength(P,3);I:=0;
    while I+2<Length(Tri) do begin
      for J:=0 to 2 do P[J]:=Vector2(Footprint[Tri[I+J]].X-Origin.X,Footprint[Tri[I+J]].Z-Origin.Z);
      Normalize(P);XZAppendPolygon(Work,Copy(P),MaxPieces);Inc(I,3);
    end;
  end;
  for I:=0 to High(Openings) do begin
    if Length(Openings[I])<3 then Continue;
    SetLength(Cut,Length(Openings[I]));
    for J:=0 to High(Cut) do Cut[J]:=Vector2(Openings[I][J].X-Origin.X,Openings[I][J].Z-Origin.Z);
    if Abs(XZPolygonArea(Cut))<POLYGON_CLIP_EPS then Continue;
    Normalize(Cut);Next:=nil;
    for K:=0 to High(Work) do XZSubtractConvex(Work[K],Cut,Next,MaxPieces);
    Work:=Next;if Length(Work)=0 then Break;
  end;
  SetLength(Result,Length(Work));
  for I:=0 to High(Work) do begin
    SetLength(Result[I],Length(Work[I]));
    for J:=0 to High(Work[I]) do Result[I][J]:=Vector3(Work[I][J].X+Origin.X,0,Work[I][J].Y+Origin.Z);
  end;
end;
end.

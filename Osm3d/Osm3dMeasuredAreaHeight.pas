unit Osm3dMeasuredAreaHeight;
{$mode objfpc}{$H+}
{ Build-time surveyed/estimated level pads. A bounded correction to the common
  terrain sampler, never a second surface hiding the uncorrected DEM. }
interface
uses SysUtils, fpjson, Osm3dGeoMath;
const MEASURED_AREA_HEIGHT_TAG='rezvivo:elevation_area';
type
  TMeasuredArea=record
    Boundary:array of TLatLon;
    Height,Feather,CosLat:Double;
    Box:TLatLonBox;
  end;
function ReadMeasuredArea(Value:TJSONData):TMeasuredArea;
function ReadMeasuredAreaText(const Text:string):TMeasuredArea;
function CanonicalMeasuredArea(Value:TJSONData):string;
function MeasuredAreaBox(const Text:string; WithFeather:Boolean=True):TLatLonBox;
function MeasuredAreaWeight(const A:TMeasuredArea;const P:TLatLon):Double;
implementation
uses Math,jsonparser,Osm3dTileKnowledge;
const DEG_M=111195.080233533;
procedure Need(B:Boolean;const S:string);
begin if not B then raise ETileKnowledge.Create('terrain.elevation_area: '+S) end;
function Number(J:TJSONData;Lo,Hi:Double):Double;
begin
  Need((J<>nil) and (J.JSONType=jtNumber),'finite number required');
  Result:=J.AsFloat;
  Need(not IsNan(Result) and not IsInfinite(Result) and (Result>=Lo) and (Result<=Hi),'number out of range');
end;
function ReadMeasuredArea(Value:TJSONData):TMeasuredArea;
var O:TJSONObject;Points,XY:TJSONArray;I,J,K,Sign:Integer;AX,AY,BX,BY,Cross,Area:Double;
begin
  Result:=Default(TMeasuredArea);Need(Value is TJSONObject,'object required');O:=TJSONObject(Value);
  for I:=0 to O.Count-1 do
    Need(Pos('|'+O.Names[I]+'|','|version|datum|elevation_m|feather_m|boundary|')>0,'unknown field '+O.Names[I]);
  Need(Number(O.Find('version'),1,1)=1,'version 1 required');
  Need(O.Get('datum','')='dem_aligned','align the vertical datum first');
  Result.Height:=Round(Number(O.Find('elevation_m'),-500,9000)*1000)*0.001;
  Result.Feather:=Round(Number(O.Find('feather_m'),10,80)*1000)*0.001;
  Need(O.Find('boundary') is TJSONArray,'boundary required');Points:=TJSONArray(O.Find('boundary'));
  Need((Points.Count>=3) and (Points.Count<=96),'3..96 boundary points required; do not repeat closure');
  SetLength(Result.Boundary,Points.Count);Result.Box:=TLatLonBox.Empty;
  for I:=0 to Points.Count-1 do begin
    Need((Points[I] is TJSONArray) and (Points[I].Count=2),'[longitude,latitude] required');XY:=TJSONArray(Points[I]);
    Result.Boundary[I]:=TLatLon.Make(Number(XY[1],-85,85),Number(XY[0],-180,180));
    Result.Box:=Result.Box.Include(Result.Boundary[I]);
  end;
  Result.CosLat:=Cos(Result.Box.Center.Lat*Pi/180);
  Need((Result.Box.Width*DEG_M*Result.CosLat<=2000) and (Result.Box.Height*DEG_M<=2000),'pad exceeds 2 km');
  Sign:=0;Area:=0;
  { Every other vertex must lie on the same side of every edge. This also
    rejects self-intersecting stars, repeated closure and concave outlines. }
  for I:=0 to High(Result.Boundary) do begin
    J:=(I+1) mod Length(Result.Boundary);
    AX:=(Result.Boundary[J].Lon-Result.Boundary[I].Lon)*DEG_M*Result.CosLat;
    AY:=(Result.Boundary[J].Lat-Result.Boundary[I].Lat)*DEG_M;
    Need(Hypot(AX,AY)>=0.1,'boundary edge shorter than 10 cm');
    for K:=0 to High(Result.Boundary) do begin
      BX:=(Result.Boundary[K].Lon-Result.Boundary[I].Lon)*DEG_M*Result.CosLat;
      BY:=(Result.Boundary[K].Lat-Result.Boundary[I].Lat)*DEG_M;
      Cross:=AX*BY-AY*BX;
      if Abs(Cross)>0.001 then begin
        if Sign=0 then if Cross>0 then Sign:=1 else Sign:=-1;
        Need(Cross*Sign>=-0.001,'boundary must be a simple convex polygon');
      end;
    end;
    BX:=(Result.Boundary[I].Lon-Result.Boundary[0].Lon)*DEG_M*Result.CosLat;
    BY:=(Result.Boundary[I].Lat-Result.Boundary[0].Lat)*DEG_M;
    Area+=BX*AY-BY*AX;
  end;
  Need(Abs(Area)>=8,'pad area smaller than 4 square metres');
end;
function ReadMeasuredAreaText(const Text:string):TMeasuredArea;
var J:TJSONData;
begin J:=GetJSON(Text);try Result:=ReadMeasuredArea(J) finally J.Free end end;
function CanonicalMeasuredArea(Value:TJSONData):string;
var A:TMeasuredArea;O:TJSONObject;B:TJSONArray;I:Integer;
begin
  A:=ReadMeasuredArea(Value);B:=TJSONArray.Create;
  O:=TJSONObject.Create(['version',1,'datum','dem_aligned','elevation_m',A.Height,'feather_m',A.Feather,'boundary',B]);
  try
    for I:=0 to High(A.Boundary) do B.Add(TJSONArray.Create([A.Boundary[I].Lon,A.Boundary[I].Lat]));
    Result:=O.AsJSON;
  finally O.Free end;
end;
function MeasuredAreaBox(const Text:string;WithFeather:Boolean):TLatLonBox;
var A:TMeasuredArea;
begin A:=ReadMeasuredAreaText(Text);Result:=A.Box;if WithFeather then Result:=Result.ExpandMeters(A.Feather+1) end;
function MeasuredAreaWeight(const A:TMeasuredArea;const P:TLatLon):Double;
var I,J,Sign:Integer;AX,AY,BX,BY,Cross,T,D,U:Double;Inside:Boolean;
begin
  D:=1e100;Sign:=0;Inside:=True;
  for I:=0 to High(A.Boundary) do begin
    J:=(I+1) mod Length(A.Boundary);
    AX:=(P.Lon-A.Boundary[I].Lon)*DEG_M*A.CosLat;AY:=(P.Lat-A.Boundary[I].Lat)*DEG_M;
    BX:=(A.Boundary[J].Lon-A.Boundary[I].Lon)*DEG_M*A.CosLat;
    BY:=(A.Boundary[J].Lat-A.Boundary[I].Lat)*DEG_M;
    Cross:=BX*AY-BY*AX;
    if Abs(Cross)>1e-8 then begin
      if Sign=0 then if Cross>0 then Sign:=1 else Sign:=-1;
      if Cross*Sign<0 then Inside:=False;
    end;
    T:=EnsureRange((AX*BX+AY*BY)/(BX*BX+BY*BY),0,1);D:=Min(D,Hypot(AX-BX*T,AY-BY*T));
  end;
  if Inside then Exit(1);
  U:=EnsureRange(1-D/A.Feather,0,1);Result:=U*U*(3-2*U);
end;
end.

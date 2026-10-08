unit Osm3dVegetationLayout;
{$mode objfpc}{$H+}
interface
uses SysUtils, Classes, fpjson, Osm3dGeoMath;
const
  VEGETATION_LAYOUT_TAG = 'rezvivo:vegetation_layout';
  VEGETATION_LAYOUT_GENERATOR = 1;
type
  TPhotoPlant = record
    Id, Kind, Genus, LeafType: string;
    Position: TLatLon;
    Height: Double;
  end;
  TPhotoPlants = array of TPhotoPlant;
  TPhotoPlantBoundary = array of TLatLon;
function CanonicalVegetationLayout(Value:TJSONData):string;
function ReadVegetationLayout(const Text:string):TPhotoPlants;
function VegetationLayoutBoundary(const Text:string):TPhotoPlantBoundary;
function PhotoPlantSeed(const Id:string; const Position:TLatLon):Int64;
function VegetationLayoutCapabilities:TJSONObject;
implementation
uses Math, MD5, Osm3dTileKnowledge, Osm3dPhotoSources, Osm3dKnowledgeProperties;

procedure Require(B:Boolean; const Msg:string);
begin if not B then raise ETileKnowledge.Create('vegetation.layout: '+Msg) end;
procedure Keys(O:TJSONObject; const Allowed:string);
var I:Integer;
begin
  for I:=0 to O.Count-1 do Require(Pos('|'+O.Names[I]+'|',Allowed)>0,'unknown field '+O.Names[I]);
end;
function DecodeBoundary(O:TJSONObject):TPhotoPlantBoundary;
var A,LL:TJSONArray;I,J,K,L:Integer;V:Double; B:TLatLonBox; Ring:TPolygonRing;
  Area:Double;
  function Cross(AIndex,BIndex,CIndex:Integer):Double;
  begin
    Result:=(Ring[BIndex].X-Ring[AIndex].X)*(Ring[CIndex].Z-Ring[AIndex].Z)-
      (Ring[BIndex].Z-Ring[AIndex].Z)*(Ring[CIndex].X-Ring[AIndex].X);
  end;
  function OnEdge(AIndex,BIndex,CIndex:Integer):Boolean;
  begin
    Result:=(Abs(Cross(AIndex,BIndex,CIndex))<1e-8) and
      (Ring[CIndex].X>=Min(Ring[AIndex].X,Ring[BIndex].X)-1e-8) and
      (Ring[CIndex].X<=Max(Ring[AIndex].X,Ring[BIndex].X)+1e-8) and
      (Ring[CIndex].Z>=Min(Ring[AIndex].Z,Ring[BIndex].Z)-1e-8) and
      (Ring[CIndex].Z<=Max(Ring[AIndex].Z,Ring[BIndex].Z)+1e-8);
  end;
begin
  Result:=nil;if O.Find('boundary')=nil then Exit;
  Require(O.Find('boundary') is TJSONArray,'boundary ring required');A:=TJSONArray(O.Find('boundary'));
  Require((A.Count>=3) and (A.Count<=64),'boundary must have 3..64 coordinates');
  SetLength(Result,A.Count);B:=TLatLonBox.Empty;
  for I:=0 to A.Count-1 do begin
    Require(A[I] is TJSONArray,'boundary coordinate required');LL:=TJSONArray(A[I]);
    Require(LL.Count=2,'boundary coordinate [longitude,latitude] required');
    for J:=0 to 1 do begin
      Require(LL[J].JSONType=jtNumber,'numeric boundary coordinate required');V:=LL[J].AsFloat;
      Require(not IsNan(V) and not IsInfinite(V),'finite boundary coordinate required');
    end;
    Require((Abs(LL[0].AsFloat)<=180) and (Abs(LL[1].AsFloat)<=85.051128),'boundary out of geographic range');
    Result[I]:=TLatLon.Make(Round(LL[1].AsFloat*1e7)*1e-7,Round(LL[0].AsFloat*1e7)*1e-7);
    B:=B.Include(Result[I]);
  end;
  { Accept a conventional closed ring, but canonicalize away its repeated end. }
  if (Result[0].Lat=Result[High(Result)].Lat) and
    (Result[0].Lon=Result[High(Result)].Lon) then SetLength(Result,Length(Result)-1);
  Require(Length(Result)>=3,'boundary needs three distinct vertices');
  for I:=0 to High(Result) do
    for J:=0 to I-1 do Require((Result[I].Lat<>Result[J].Lat) or
      (Result[I].Lon<>Result[J].Lon),'repeated boundary vertex');
  Require((B.Width*111320*Cos(B.Center.Lat*Pi/180)<=250) and (B.Height*111320<=250),'local planting boundary exceeds 250 m');
  SetLength(Ring,Length(Result));Area:=0;
  for I:=0 to High(Result) do begin
    Ring[I].X:=(Result[I].Lon-B.MinLon)*111320*Cos(B.Center.Lat*Pi/180);
    Ring[I].Z:=(Result[I].Lat-B.MinLat)*111320;
  end;
  for I:=0 to High(Result) do begin J:=(I+1) mod Length(Result);Area+=Ring[I].X*Ring[J].Z-Ring[J].X*Ring[I].Z end;
  Require(Abs(Area)>1,'degenerate planting boundary');
  for I:=0 to High(Result) do begin
    J:=(I+1) mod Length(Result);
    for K:=I+1 to High(Result) do begin
      L:=(K+1) mod Length(Result);
      if (J=K) or (L=I) then Continue;
      Require(not (((Cross(I,J,K)*Cross(I,J,L)<0) and
        (Cross(K,L,I)*Cross(K,L,J)<0)) or OnEdge(I,J,K) or
        OnEdge(I,J,L) or OnEdge(K,L,I) or OnEdge(K,L,J)),
        'self-intersecting planting boundary');
    end;
  end;
end;
function Decode(Value:TJSONData):TPhotoPlants;
var O,P:TJSONObject; A,LL:TJSONArray; I,J:Integer; V:Double; Genus:TJSONData;
  Boundary:TPhotoPlantBoundary; Ring:TPolygonRing;
begin
  Result:=nil; Require(Value is TJSONObject,'object required');O:=TJSONObject(Value);
  Keys(O,'|version|mode|plants|boundary|');
  Boundary:=DecodeBoundary(O);SetLength(Ring,Length(Boundary));
  for I:=0 to High(Boundary) do begin Ring[I].X:=Boundary[I].Lon;Ring[I].Z:=Boundary[I].Lat end;
  Require((O.Find('version')<>nil) and (O.Find('version').JSONType=jtNumber) and
    (O.Find('version').AsFloat=1),'version must be 1');
  Require(O.Get('mode','')='replace_scatter','mode must be replace_scatter; explicit OSM nodes are preserved');
  Require(O.Find('plants') is TJSONArray,'plants array required');A:=TJSONArray(O.Find('plants'));
  Require(A.Count<=512,'at most 512 plants per bounded OSM polygon');SetLength(Result,A.Count);
  for I:=0 to A.Count-1 do begin
    Require(A[I] is TJSONObject,'plant object required');P:=TJSONObject(A[I]);
    Keys(P,'|id|position|kind|genus|leaf_type|height_m|');
    Result[I].Id:=P.Get('id','');Require((Length(Result[I].Id)>0) and (Length(Result[I].Id)<=64),'bounded stable plant id required');
    for J:=1 to Length(Result[I].Id) do Require(Result[I].Id[J] in ['a'..'z','A'..'Z','0'..'9','-',':','_'],'invalid plant id');
    for J:=0 to I-1 do Require(Result[J].Id<>Result[I].Id,'duplicate plant id');
    Result[I].Kind:=P.Get('kind','');Require((Result[I].Kind='tree') or (Result[I].Kind='shrub'),'kind must be tree or shrub');
    Require(P.Find('position') is TJSONArray,'position [longitude,latitude] required');LL:=TJSONArray(P.Find('position'));
    Require(LL.Count=2,'position must contain two coordinates');
    for J:=0 to 1 do begin
      Require(LL[J].JSONType=jtNumber,'numeric coordinate required');V:=LL[J].AsFloat;
      Require(not IsNan(V) and not IsInfinite(V),'finite coordinate required');
    end;
    Require((Abs(LL[0].AsFloat)<=180) and (Abs(LL[1].AsFloat)<=85.051128),'coordinate out of range');
    Result[I].Position:=TLatLon.Make(Round(LL[1].AsFloat*1e7)*1e-7,Round(LL[0].AsFloat*1e7)*1e-7);
    if Length(Ring)>0 then Require(PointInRingXZ(Result[I].Position.Lon,Result[I].Position.Lat,Ring),'plant outside local boundary');
    for J:=0 to I-1 do Require((Abs(Result[J].Position.Lat-Result[I].Position.Lat)>1e-8) or
      (Abs(Result[J].Position.Lon-Result[I].Position.Lon)>1e-8),'duplicate plant position');
    Require((P.Find('height_m')<>nil) and (P.Find('height_m').JSONType=jtNumber),'height_m required');
    V:=P.Find('height_m').AsFloat;Require(not IsNan(V) and not IsInfinite(V) and (V>=0.2) and (V<=80),'height out of range');
    Result[I].Height:=V;Genus:=P.Find('genus');
    if Genus<>nil then Result[I].Genus:=CanonicalKnowledgeScalar(19,Genus,'');
    if P.Find('leaf_type')<>nil then Result[I].LeafType:=CanonicalKnowledgeScalar(21,P.Find('leaf_type'),'');
    Require((Result[I].Genus<>'') or (Result[I].LeafType<>''),'genus or leaf_type required; do not invent unknown species');
  end;
end;
function CanonicalVegetationLayout(Value:TJSONData):string;
var Plants:TPhotoPlants; Order:TStringList; I,K:Integer; O,P:TJSONObject; A,Ring:TJSONArray;
  Boundary:TPhotoPlantBoundary;
begin
  Plants:=Decode(Value);Order:=TStringList.Create;Order.Sorted:=True;
  A:=TJSONArray.Create;O:=TJSONObject.Create(['version',1,'mode','replace_scatter','plants',A]);
  try
    Boundary:=DecodeBoundary(TJSONObject(Value));
    if Length(Boundary)>0 then begin
      Ring:=TJSONArray.Create;O.Add('boundary',Ring);
      for I:=0 to High(Boundary) do Ring.Add(TJSONArray.Create([Boundary[I].Lon,Boundary[I].Lat]));
    end;
    for I:=0 to High(Plants) do Order.AddObject(Plants[I].Id,TObject(PtrInt(I)));
    for I:=0 to Order.Count-1 do begin
      K:=PtrInt(Order.Objects[I]);
      P:=TJSONObject.Create(['id',Plants[K].Id,'position',TJSONArray.Create([Plants[K].Position.Lon,Plants[K].Position.Lat]),
        'kind',Plants[K].Kind]);
      if Plants[K].Genus<>'' then P.Add('genus',Plants[K].Genus);
      if Plants[K].LeafType<>'' then P.Add('leaf_type',Plants[K].LeafType);
      P.Add('height_m',Plants[K].Height);A.Add(P);
    end;
    Result:=O.AsJSON;
  finally O.Free;Order.Free end;
end;
function VegetationLayoutBoundary(const Text:string):TPhotoPlantBoundary;
var J:TJSONData;
begin
  J:=ParsePhotoJson(Text);
  try Require(J is TJSONObject,'object required');Result:=DecodeBoundary(TJSONObject(J)) finally J.Free end;
end;
function ReadVegetationLayout(const Text:string):TPhotoPlants;
var J:TJSONData;
begin
  J:=ParsePhotoJson(Text);try Result:=Decode(J) finally J.Free end;
end;
function PhotoPlantSeed(const Id:string; const Position:TLatLon):Int64;
var S:string;
begin
  S:=MD5Print(MD5String(Id+':'+IntToStr(Round(Position.Lat*1e7))+':'+IntToStr(Round(Position.Lon*1e7))));
  Result:=-StrToInt64('$'+Copy(S,1,15));
end;
function VegetationLayoutCapabilities:TJSONObject;
begin
  Result:=TJSONObject.Create(['version',1,'mode','replace_scatter',
    'target','one existing closed forest/scrub/grass/meadow way, or local: object with explicit boundary and nearby OSM anchor; entire area must be reviewed',
    'plants','0..512 stable id, position [longitude,latitude] at OSM precision, kind tree/shrub, supported Latin genus or leaf_type, height_m .2..80',
    'policy','replaces generated scatter only; retains explicit OSM trees and suppresses duplicate photo plants within 1 m; no tile-local random positions']);
  Result.Add('boundary','local: objects require a geographic polygon, 3..64 [lon,lat] points, maximum 250 m per side, within 80 m of the OSM anchor bounds');
end;
end.

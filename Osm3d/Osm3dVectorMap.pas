unit Osm3dVectorMap;
{$mode objfpc}{$H+}{$codepage UTF8}

{ Immutable cartographic features. Built on a worker from the SAME full OSM
  sources as 3D, independent of viewport zoom. No GL, fonts or raster labels. }
interface
uses Classes, SysUtils, Osm3dGeoMath, Osm3dOsmData, Osm3dGeomUtils;
type
  TMapFeatureKind = (mfResidential, mfIndustrial, mfFarmland, mfGrass,
    mfForest, mfSand, mfWater, mfBuilding, mfWaterway, mfRail,
    mfPath, mfService, mfStreet, mfTertiary, mfSecondary, mfPrimary,
    mfTrunk, mfMotorway, mfPlace, mfPoi, mfHouseNumber);
  TMapGeoPoints = array of TLatLon;
  TMapVectorFeature = class
    Key, Caption: string;
    Kind: TMapFeatureKind;
    Points: TMapGeoPoints;
    Triangles: TIntArray;
    Bounds: TLatLonBox;
    MinZoom, LabelZoom, LabelPriority, Population, Layer: Integer;
    procedure SetBounds;
  end;
  TMapVectorData = class
    Tile: TTileXY;
    MaxZoom: Integer;
    Features: TList;
    Bytes: Int64;
    constructor Create(const ATile: TTileXY);
    destructor Destroy; override;
  end;
function BuildMapVectors(Data: TOSMDataset; const Tile: TTileXY;
  Cancel: TThread = nil; MaxZoom: Integer = 18): TMapVectorData;

implementation
uses Math, Generics.Collections;
type TThreadAccess = class(TThread);

procedure TMapVectorFeature.SetBounds;
var P: TLatLon;
begin
  Bounds.MinLat:=90; Bounds.MaxLat:=-90; Bounds.MinLon:=180; Bounds.MaxLon:=-180;
  for P in Points do begin
    Bounds.MinLat:=Min(Bounds.MinLat,P.Lat); Bounds.MaxLat:=Max(Bounds.MaxLat,P.Lat);
    Bounds.MinLon:=Min(Bounds.MinLon,P.Lon); Bounds.MaxLon:=Max(Bounds.MaxLon,P.Lon);
  end;
end;

constructor TMapVectorData.Create(const ATile: TTileXY);
begin inherited Create; Tile:=ATile; Features:=TList.Create; end;
destructor TMapVectorData.Destroy;
var I: Integer;
begin for I:=0 to Features.Count-1 do TObject(Features[I]).Free; Features.Free; inherited; end;

function AreaKind(T: TOSMTags; out Kind: TMapFeatureKind): Boolean;
var N,L,S: string;
begin
  N:=T.GetLower('natural'); L:=T.GetLower('landuse'); S:=T.GetLower('leisure');
  Result:=True;
  if T.HasKey('building') or T.HasKey('building:part') then Kind:=mfBuilding
  else if (N='water') or (L='reservoir') or (T.GetLower('waterway')='riverbank') then Kind:=mfWater
  else if (N='wood') or (N='scrub') or (L='forest') then Kind:=mfForest
  else if (L='grass') or (L='meadow') or (N='grassland') or (S='park') or (S='garden') or (S='pitch') then Kind:=mfGrass
  else if (L='farmland') or (L='orchard') or (L='allotments') then Kind:=mfFarmland
  else if L='residential' then Kind:=mfResidential
  else if (L='industrial') or (L='commercial') or (L='retail') then Kind:=mfIndustrial
  else if (N='sand') or (N='beach') then Kind:=mfSand
  else Result:=False;
end;

function BuildMapVectors(Data: TOSMDataset; const Tile: TTileXY; Cancel: TThread; MaxZoom: Integer): TMapVectorData;
var
  Members: specialize TDictionary<Int64,Boolean>;
  Projection: TLocalProjection;
  W: TOSMWay; Rel: TOSMRelation; N: TOSMNode;
  F: TMapVectorFeature; K: TMapFeatureKind;
  I,J,Z,Priority: Integer; S,Name: string;
  Polys: TMultipolygonArray;
  function Stopped: Boolean;
  begin Result:=(Cancel<>nil) and TThreadAccess(Cancel).Terminated; end;
  procedure Add(A: TMapVectorFeature);
  begin
    A.SetBounds; Result.Features.Add(A);
    Inc(Result.Bytes,A.InstanceSize+Length(A.Points)*SizeOf(TLatLon)+
      Length(A.Triangles)*SizeOf(Integer)+Length(A.Caption)+Length(A.Key)+96);
  end;
  procedure PointLabel(const P: TLatLon; const Text,Id: string;
    Kind: TMapFeatureKind; Zoom,Rank,Population: Integer);
  var A: TMapVectorFeature;
  begin
    if (Text='') or (Zoom>MaxZoom) then Exit;
    A:=TMapVectorFeature.Create; A.Key:=Id; A.Caption:=Text; A.Kind:=Kind;
    A.MinZoom:=Zoom; A.LabelZoom:=Zoom; A.LabelPriority:=Rank; A.Population:=Population;
    SetLength(A.Points,1); A.Points[0]:=P; Add(A);
  end;
  procedure Polygon(const MP: TPolygonMultipolygon; const Id,Title: string;
    Kind: TMapFeatureKind);
  var A: TMapVectorFeature; Coords: TDoubleArray; Holes: TIntArray;
      C,R,H: Integer;
    procedure Ring(const Points: TPolygonRing);
    var V: TScatterPoint;
    begin
      for V in Points do begin
        Coords[C*2]:=V.X; Coords[C*2+1]:=V.Z;
        A.Points[C]:=Projection.Unproject(V.X,V.Z); Inc(C);
      end;
    end;
  begin
    if (Length(MP.Outer)<3) or ((Kind=mfBuilding) and (MaxZoom<15)) then Exit;
    A:=TMapVectorFeature.Create;
    try
      C:=Length(MP.Outer); for R:=0 to High(MP.Inners) do Inc(C,Length(MP.Inners[R]));
      SetLength(Coords,C*2); SetLength(A.Points,C); SetLength(Holes,Length(MP.Inners));
      C:=0; H:=0; Ring(MP.Outer);
      for R:=0 to High(MP.Inners) do if Length(MP.Inners[R])>=3 then begin
        Holes[H]:=C; Inc(H); Ring(MP.Inners[R]);
      end;
      SetLength(A.Points,C); SetLength(Coords,C*2); SetLength(Holes,H);
      A.Triangles:=TEarcutTriangulator.Triangulate(Coords,Holes,2);
      if Length(A.Triangles)=0 then Exit;
      A.Key:=Id; A.Caption:=Title; A.Kind:=Kind; A.MinZoom:=11;
      if Kind=mfBuilding then A.MinZoom:=15;
      A.LabelZoom:=14; A.LabelPriority:=30;
      if Kind=mfWater then begin A.LabelZoom:=12; A.LabelPriority:=48; end;
      Add(A); A:=nil;
    finally A.Free; end;
  end;
begin
  Result:=TMapVectorData.Create(Tile);
  Result.MaxZoom:=MaxZoom;
  try
  Members:=specialize TDictionary<Int64,Boolean>.Create;
  Projection:=TLocalProjection.Create(TTileMath.TileToLatLonBox(Tile).Center);
  try
    for Rel in Data.Relations.Values do begin
      if Stopped then Exit;
      if not AreaKind(Rel.Tags,K) then Continue;
      if (K=mfBuilding) and (MaxZoom<15) then Continue;
      Polys:=BuildMultipolygonsFromRelation(Rel,Data,Projection);
      if Length(Polys)=0 then Continue;
      for I:=0 to High(Polys) do Polygon(Polys[I],'r'+IntToStr(Rel.Id)+':'+IntToStr(I),Rel.Tags.Get('name'),K);
      for I:=0 to High(Rel.Members) do if Rel.Members[I].Kind=omkWay then
        Members.AddOrSetValue(Rel.Members[I].Ref,True);
    end;
    for W in Data.Ways.Values do begin
      if Stopped then Exit;
      if W.IsClosed and AreaKind(W.Tags,K) and
        ((K<>mfBuilding) or (MaxZoom>=15)) and not Members.ContainsKey(W.Id) then
        Polygon(BuildMultipolygonFromWay(W,Data,Projection),'w'+IntToStr(W.Id),W.Tags.Get('name'),K);
      S:=W.Tags.GetLower('highway'); Z:=13; Priority:=60;
      if S<>'' then begin
        if Pos('motorway',S)=1 then begin K:=mfMotorway; Z:=11; Priority:=78; end
        else if Pos('trunk',S)=1 then begin K:=mfTrunk; Z:=11; Priority:=76; end
        else if Pos('primary',S)=1 then begin K:=mfPrimary; Z:=11; Priority:=74; end
        else if Pos('secondary',S)=1 then begin K:=mfSecondary; Z:=11; Priority:=72; end
        else if Pos('tertiary',S)=1 then begin K:=mfTertiary; Z:=12; Priority:=68; end
        else if (S='residential') or (S='unclassified') or (S='living_street') or (S='pedestrian') then K:=mfStreet
        else if S='service' then begin K:=mfService; Z:=15; Priority:=44; end
        else if (S='path') or (S='footway') or (S='cycleway') or (S='track') or (S='steps') then begin K:=mfPath; Z:=15; Priority:=40; end
        else Continue;
      end else if W.Tags.HasKey('waterway') then begin
        K:=mfWaterway; Z:=13; Priority:=35;
        if W.Tags.GetLower('waterway')='river' then Z:=11;
      end else if W.Tags.GetLower('railway')='rail' then begin K:=mfRail; Z:=12; Priority:=0; end
      else Continue;
      if Z>MaxZoom then Continue;
      F:=TMapVectorFeature.Create;
      F.Key:='l'+IntToStr(W.Id); F.Kind:=K; F.Caption:=W.Tags.Get('name');
      F.MinZoom:=Z; F.LabelZoom:=Max(13,Z); F.LabelPriority:=Priority;
      F.Layer:=EnsureRange(StrToIntDef(W.Tags.Get('layer'),0),-3,3);
      if (F.Layer=0) and (W.Tags.GetLower('bridge')='yes') then F.Layer:=1;
      SetLength(F.Points,Length(W.NodeRefs)); J:=0;
      for I:=0 to High(W.NodeRefs) do begin
        N:=Data.FindNode(W.NodeRefs[I]); if N=nil then begin J:=0; Break; end;
        F.Points[J]:=N.Position; Inc(J);
      end;
      if J<2 then F.Free else begin SetLength(F.Points,J); Add(F); end;
    end;
    for N in Data.Nodes.Values do begin
      if Stopped then Exit;
      S:=N.Tags.GetLower('place'); Name:=N.Tags.Get('name'); K:=mfPlace;
      Z:=16; Priority:=20;
      if S='city' then begin Z:=6; Priority:=120; end
      else if S='town' then begin Z:=9; Priority:=110; end
      else if S='village' then begin Z:=11; Priority:=100; end
      else if (S='suburb') or (S='quarter') then begin Z:=13; Priority:=90; end
      else if (S='hamlet') or (S='neighbourhood') then begin Z:=14; Priority:=85; end
      else if (N.Tags.GetLower('railway')='station') or (N.Tags.GetLower('natural')='peak') then begin K:=mfPoi; Z:=13; Priority:=55; end
      else if N.Tags.HasKey('amenity') or N.Tags.HasKey('tourism') then begin K:=mfPoi; Z:=16; Priority:=25; end
      else if N.Tags.HasKey('addr:housenumber') then begin
        K:=mfHouseNumber; Z:=18; Priority:=5; Name:=N.Tags.Get('addr:housenumber');
      end else Continue;
      PointLabel(N.Position,Name,'n'+IntToStr(N.Id),K,Z,Priority,StrToIntDef(N.Tags.Get('population'),0));
    end;
  finally Projection.Free; Members.Free; end;
  except Result.Free; raise; end;
end;
end.

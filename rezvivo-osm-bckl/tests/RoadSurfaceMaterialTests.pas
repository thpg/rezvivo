program RoadSurfaceMaterialTests;
{$mode objfpc}{$H+}

uses Classes, SysUtils, CastleVectors, X3DNodes,
  Osm3dOsmData, Osm3dGeomRoads, Osm3dGeomMesh, Osm3dGroundComposite,
  Osm3dRoadSurface, Osm3dRoadSurfaceBinding, Osm3dRoadMaterial, Osm3dTileX3D;

procedure Check(OK: Boolean; const Msg: string);
begin
  if not OK then raise Exception.Create(Msg);
end;

procedure CheckTag(const Surface: string; Material: TPathMaterial);
var Tags: TOSMTags;
begin
  Tags:=TOSMTags.Create;
  try
    Tags.Add('highway','unclassified'); Tags.Add('surface',Surface);
    Check(TRoadBuilder.ParseRoadParams(Tags).Material=Material,
      'OSM surface: '+Surface);
  finally Tags.Free end;
end;

function Attribute(Geo: TIndexedFaceSetNode; const Name: string): TFloatVertexAttributeNode;
var I: Integer;
begin
  for I:=0 to Geo.FdAttrib.Count-1 do
    if (Geo.FdAttrib[I] is TFloatVertexAttributeNode) and
       (TFloatVertexAttributeNode(Geo.FdAttrib[I]).NameField=Name) then
      Exit(TFloatVertexAttributeNode(Geo.FdAttrib[I]));
  raise Exception.Create('Missing road attribute: '+Name);
end;

procedure CheckCachedSurface(const Name: string; Surface: Integer; UVScale: Single;
  Mat: TGroundMaterialId; Procedural, Concrete: Boolean);
var Model, Loaded: TTileModel; Stream: TMemoryStream; Seg: TTileRoadSeg;
  Comp: TGroundCompositeMesh; Geo: TIndexedFaceSetNode; V: TMeshVertex;
  Coord, Style: TFloatVertexAttributeNode; I, Bits: Integer;
begin
  Model:=TTileModel.Create; Loaded:=nil; Stream:=TMemoryStream.Create;
  Comp:=TGroundCompositeMesh.Create; Geo:=TIndexedFaceSetNode.Create;
  try
    Seg:=Default(TTileRoadSeg);
    Seg.WayId:=990147197; Seg.Z1:=12; Seg.Width:=6;
    Seg.Surface.UVScale:=UVScale; Seg.Surface.UVMax:=1;
    Seg.Surface.Asphalt:=Surface; Seg.Surface.Condition:=3;
    Seg.Surface.ForwardLanes:=1; Seg.Surface.BackwardLanes:=1;
    Seg.Surface.Marked:=1;
    Model.AddRoadSeg(Seg);
    TTileX3D.SaveStream(Stream,Model); Stream.Position:=0;
    Loaded:=TTileX3D.LoadStream(Stream);
    Check(Loaded.RoadSegCount=1,Name+': centerline survives cache');
    Check(Loaded.RoadSegs[0].Surface.Asphalt=Surface,Name+': material survives cache');

    Comp.ReserveForSlice(3,1);
    V:=Default(TMeshVertex); V.Normal:=Vector3(0,1,0); V.OsmId:=Seg.WayId;
    V.Position:=Vector3(-3,0,0); V.UV:=Vector2(0,0); Comp.AppendVertex(V,Mat);
    V.Position:=Vector3(3,0,0); V.UV:=Vector2(1,0); Comp.AppendVertex(V,Mat);
    V.Position:=Vector3(-3,0,12); V.UV:=Vector2(0,12/UVScale); Comp.AppendVertex(V,Mat);
    Comp.AppendTriangle(0,2,1); Comp.TrimArrays;
    AttachRoadSurface(Geo,Comp,Loaded,Vector3(0,0,0),1);
    Coord:=Attribute(Geo,'roadCoord'); Style:=Attribute(Geo,'roadStyle');
    for I:=0 to 2 do
    begin
      Check((Coord.FdValue.Items[I*4+2]>0)=Procedural,Name+': procedural surface');
      Bits:=Round(Style.FdValue.Items[I*4+2]);
      Check(((Bits and ROAD_STYLE_CONCRETE)<>0)=Concrete,Name+': concrete material');
      if Procedural then
      begin
        Check(((Bits mod ROAD_STYLE_CONCRETE) div 16)=3,Name+': wear is preserved');
        Check(Coord.FdValue.Items[I*4+3]>0,Name+': cached profile');
      end;
      if Mat=GROUND_MAT_ROAD_FOOTWAY then
        Check((Bits and 1)=0,Name+': no car markings on footway');
    end;
    Check(Loaded.RoadSegs[0].Surface.Asphalt=Surface,Name+': legacy data unchanged');
    Check((Comp.VertexCount=3) and (Comp.TriangleCount=1),Name+': no extra geometry');
    Writeln('PASS ',Name);
  finally Geo.Free; Comp.Free; Loaded.Free; Model.Free; Stream.Free end;
end;

procedure CheckMaterialCache;
var L: TRoadLaneLayout; S: Single; Asphalt, Concrete: Integer;
begin
  L:=Default(TRoadLaneLayout);
  Asphalt:=RoadMaterialRegister(739571415,6,2,L,S,3,False);
  Concrete:=RoadMaterialRegister(739571415,6,2,L,S,3,True);
  Check(Asphalt<>Concrete,'Different surfaces must not share cached pages');
  Check(Concrete=RoadMaterialRegister(739571415,6,2,L,S,3,True),
    'Same concrete road must reuse cached pages');
  Writeln('PASS separate material profiles, reuse within material');
end;

begin
  CheckTag('concrete',pmConcrete);
  CheckTag('concrete:plates',pmConcrete);
  CheckTag('concrete:lanes',pmConcrete);
  CheckTag('asphalt',pmAsphalt);
  CheckTag('paving_stones',pmCobblestone);
  CheckCachedSurface('Ahun legacy concrete',ROAD_SURFACE_OTHER,12,GROUND_MAT_ROAD_MINOR,True,True);
  CheckCachedSurface('new concrete',ROAD_SURFACE_CONCRETE,12,GROUND_MAT_ROAD_MINOR,True,True);
  CheckCachedSurface('asphalt',ROAD_SURFACE_ASPHALT,12,GROUND_MAT_ROAD_MINOR,True,False);
  CheckCachedSurface('legacy paving',ROAD_SURFACE_OTHER,6,GROUND_MAT_ROAD_MINOR,False,False);
  CheckCachedSurface('legacy wood',ROAD_SURFACE_OTHER,4,GROUND_MAT_ROAD_SERVICE,False,False);
  CheckCachedSurface('concrete footway',ROAD_SURFACE_CONCRETE,10,GROUND_MAT_ROAD_FOOTWAY,True,True);
  CheckCachedSurface('legacy footway',ROAD_SURFACE_OTHER,10,GROUND_MAT_ROAD_FOOTWAY,True,False);
  CheckCachedSurface('legacy cycleway',ROAD_SURFACE_OTHER,8,GROUND_MAT_ROAD_CYCLEWAY,False,False);
  CheckCachedSurface('concrete cycleway',ROAD_SURFACE_CONCRETE,8,GROUND_MAT_ROAD_CYCLEWAY,True,True);
  CheckMaterialCache;
  Writeln('All road surface tests passed');
end.

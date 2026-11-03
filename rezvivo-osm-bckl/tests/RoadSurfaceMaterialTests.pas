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
  Mat: TGroundMaterialId; Procedural, Concrete: Boolean; EdgeOnly:Boolean=False; Junction:Boolean=False);
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
    if EdgeOnly then Seg.Surface.Marked:=1+ROAD_STYLE_EDGE_ONLY;
    Model.AddRoadSeg(Seg);
    TTileX3D.SaveStream(Stream,Model); Stream.Position:=0;
    Loaded:=TTileX3D.LoadStream(Stream);
    Check(Loaded.RoadSegCount=1,Name+': centerline survives cache');
    Check(Loaded.RoadSegs[0].Surface.Asphalt=Surface,Name+': material survives cache');

    Comp.ReserveForSlice(3,1);
    V:=Default(TMeshVertex); V.Normal:=Vector3(0,1,0); V.OsmId:=Seg.WayId;
    V.Position:=Vector3(-3,0,0); V.UV:=Vector2(Ord(Junction)*ROAD_JUNCTION_UV_SHIFT,0); Comp.AppendVertex(V,Mat);
    V.Position:=Vector3(3,0,0); V.UV:=Vector2(1+Ord(Junction)*ROAD_JUNCTION_UV_SHIFT,0); Comp.AppendVertex(V,Mat);
    V.Position:=Vector3(-3,0,12); V.UV:=Vector2(Ord(Junction)*ROAD_JUNCTION_UV_SHIFT,12/UVScale); Comp.AppendVertex(V,Mat);
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
        Check(((Bits and ROAD_STYLE_EDGE_ONLY)<>0)=(EdgeOnly and not Junction),Name+': edge paint is suppressed only in common junction');
        if Junction then begin
          Check((Bits and 1)=0,Name+': no interior stripe');
          Check(Abs(Abs(Coord.FdValue.Items[I*4+1])-3)<0.001,Name+': junction retains metric surface coordinates');
        end;
        Check(((Bits mod ROAD_STYLE_CONCRETE) div 16)=3,Name+': wear is preserved');
        Check(Coord.FdValue.Items[I*4+3]>0,Name+': cached profile');
      end;
      if (Mat=GROUND_MAT_ROAD_FOOTWAY) and not EdgeOnly then
        Check((Bits and 1)=0,Name+': no car markings on footway');
    end;
    Check(Loaded.RoadSegs[0].Surface.Asphalt=Surface,Name+': legacy data unchanged');
    Check((Comp.VertexCount=3) and (Comp.TriangleCount=1),Name+': no extra geometry');
    Writeln('PASS ',Name);
  finally Geo.Free; Comp.Free; Loaded.Free; Model.Free; Stream.Free end;
end;

procedure CheckMaterialCache;
var L: TRoadLaneLayout; S: Single; Asphalt, Concrete, Dirt, Gravel: Integer;
begin
  L:=Default(TRoadLaneLayout);
  Asphalt:=RoadMaterialRegister(739571415,6,2,L,S,3,False);
  Concrete:=RoadMaterialRegister(739571415,6,2,L,S,3,True);
  Check(Asphalt<>Concrete,'Different surfaces must not share cached pages');
  Check(Concrete=RoadMaterialRegister(739571415,6,2,L,S,3,True),
    'Same concrete road must reuse cached pages');
  Dirt:=RoadMaterialRegister(739571415,6,0,L,S,3,False,1);
  Gravel:=RoadMaterialRegister(739571415,6,0,L,S,3,False,2);
  Check((Dirt<>Gravel) and (Dirt<>Asphalt) and (Gravel<>Concrete),
    'Soil, aggregate and pavement must not alias in the cache');
  Check(Gravel=RoadMaterialRegister(739571415,6,0,L,S,3,False,2),'Gravel cache reuse');
  Writeln('PASS separate material profiles, reuse within material');
end;

procedure CheckUnpavedTags;
const Values:array[0..5] of string=('dirt','earth','gravel','compacted','fine_gravel','sand');
  Kinds:array[0..5] of Integer=(4,4,5,6,7,8);
var Tags:TOSMTags;P:TRoadParams;I:Integer;
begin
  for I:=0 to High(Values) do begin
    Tags:=TOSMTags.Create;
    try
      Tags.Add('highway','path');Tags.Add('surface',Values[I]);
      P:=TRoadBuilder.ParseRoadParams(Tags);
      Check(P.SurfaceKind=Kinds[I],Values[I]+': distinct material');
      Check(not P.IsMarked,Values[I]+': no lane paint');
    finally Tags.Free end;
  end;
  Tags:=TOSMTags.Create;
  try
    Tags.Add('highway','track');Tags.Add('tracktype','grade2');
    Check(TRoadBuilder.ParseRoadParams(Tags).SurfaceKind=ROAD_SURFACE_COMPACTED,'grade2 fallback');
    Tags.Add('surface','dirt');
    Check(TRoadBuilder.ParseRoadParams(Tags).SurfaceKind=ROAD_SURFACE_DIRT,'explicit surface beats grade');
  finally Tags.Free end;
  Writeln('PASS unpaved OSM tags and grade fallback');
end;

procedure CheckAdjacentLand;
var Comp:TGroundCompositeMesh;Model:TTileModel;Geo:TIndexedFaceSetNode;
  V:TMeshVertex;Seg:TTileRoadSeg;Style:TFloatVertexAttributeNode;I:Integer;
begin
  Comp:=TGroundCompositeMesh.Create;Model:=TTileModel.Create;Geo:=TIndexedFaceSetNode.Create;
  try
    Seg:=Default(TTileRoadSeg);Seg.WayId:=91;Seg.Width:=4;Seg.Z1:=20;
    Seg.Surface.Asphalt:=ROAD_SURFACE_DIRT;Seg.Surface.UVMax:=1;Seg.Surface.UVScale:=6;
    Model.AddRoadSeg(Seg);
    V:=Default(TMeshVertex);V.Normal:=Vector3(0,1,0);V.OsmId:=91;
    for I:=0 to 3 do begin
      V.Position:=Vector3(-2+4*(I mod 2),0.005,20*(I div 2));V.UV:=Vector2(I mod 2,V.Position.Z/6);
      Comp.AppendVertex(V,GROUND_MAT_ROAD_DIRT);
    end;
    Comp.AppendTriangle(0,2,1);Comp.AppendTriangle(1,2,3);
    V.OsmId:=0;
    for I:=0 to 3 do begin
      V.Position:=Vector3(-2+4*(I mod 2),0,20*(I div 2));
      Comp.AppendVertex(V,2+I mod 2); { forest left, sand right; different layer bias }
    end;
    Comp.TrimArrays;AttachRoadSurface(Geo,Comp,Model,Vector3(0,0,0),1);
    Style:=Attribute(Geo,'roadStyle');
    for I:=0 to 3 do begin
      Check(Round(Style.FdValue.Items[I*4])=2,'left shoulder follows forest');
      Check(Round(Style.FdValue.Items[I*4+1])=3,'right shoulder follows sand');
      Check(Round(Style.FdValue.Items[I*4+2]) div ROAD_STYLE_UNPAVED=1,'unpaved kind in shader');
      Check((Round(Style.FdValue.Items[I*4+2]) and 1)=0,'no paint on dirt');
    end;
    Check(Comp.VertexCount=8,'shoulder does not add geometry');
    Writeln('PASS adjacent land, independent sides, layer offset, no extra geometry');
  finally Geo.Free;Model.Free;Comp.Free end;
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
  CheckCachedSurface('edge-only cycling track',ROAD_SURFACE_ASPHALT,8,GROUND_MAT_ROAD_CYCLEWAY,True,False,True);
  CheckCachedSurface('edge-only footway sports track',ROAD_SURFACE_ASPHALT,10,GROUND_MAT_ROAD_FOOTWAY,True,False,True);
  CheckCachedSurface('asphalt junction',ROAD_SURFACE_ASPHALT,10,GROUND_MAT_ROAD_FOOTWAY,True,False,True,True);
  CheckCachedSurface('concrete junction',ROAD_SURFACE_CONCRETE,12,GROUND_MAT_ROAD_MINOR,True,True,True,True);
  CheckMaterialCache;
  CheckUnpavedTags;
  CheckAdjacentLand;
  CheckCachedSurface('soil',ROAD_SURFACE_DIRT,6,GROUND_MAT_ROAD_DIRT,True,False);
  CheckCachedSurface('gravel',ROAD_SURFACE_GRAVEL,6,GROUND_MAT_ROAD_DIRT,True,False);
  CheckCachedSurface('compacted',ROAD_SURFACE_COMPACTED,6,GROUND_MAT_ROAD_DIRT,True,False);
  CheckCachedSurface('fine gravel',ROAD_SURFACE_FINE_GRAVEL,6,GROUND_MAT_ROAD_DIRT,True,False);
  CheckCachedSurface('sand',ROAD_SURFACE_SAND,6,GROUND_MAT_ROAD_SAND,True,False);
  CheckCachedSurface('legacy dirt',ROAD_SURFACE_OTHER,6,GROUND_MAT_ROAD_DIRT,True,False);
  CheckCachedSurface('explicit dirt footpath',ROAD_SURFACE_DIRT,10,GROUND_MAT_ROAD_FOOTWAY,True,False);
  Writeln('All road surface tests passed');
end.

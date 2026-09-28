unit Osm3dVegetationBranchMesh;
{$mode objfpc}{$H+}
interface
const
  VEGETATION_BRANCH_FULL_METERS = 60;
  VEGETATION_BRANCH_FAR_METERS = 80;
  VEGETATION_TREE_LAYERS = 8;
  VEGETATION_SHRUB_LAYERS = 4;
type
  { ORIGINAL position, normal, UV; pivot/phase/angle; layer/right-X/right-Z. }
  TBranchVertex = packed array[0..15] of Single;
  TBranchVertices = array of TBranchVertex;
  TBranchIndices = array of Word;
procedure BuildVegetationLayerMesh(const Data:array of Single;const Indices:array of Word;
  LayerCount:Integer;AngleScale:Single;out Vertices:TBranchVertices;out NewIndices:TBranchIndices);
implementation
uses Math,SysUtils;

procedure BuildVegetationLayerMesh(const Data:array of Single;const Indices:array of Word;
  LayerCount:Integer;AngleScale:Single;out Vertices:TBranchVertices;out NewIndices:TBranchIndices);
var Corners:array[0..3,0..7]of Single;Found:array[0..3]of Boolean;
    Card,I,J,C,Base,Q,Layer:Integer;MinU,MinV,MaxU,MaxV,U,V,Sign:Single;
begin
  if(LayerCount<1)or(Length(Indices)mod 6<>0)or(Length(Data)mod 8<>0)then
    raise Exception.Create('Invalid vegetation layer cards');
  if Int64(Length(Indices)div 6)*LayerCount*4>65536 then raise Exception.Create('Too many vegetation layers');
  SetLength(Vertices,Length(Indices)div 6*LayerCount*4);
  SetLength(NewIndices,Length(Indices)div 6*LayerCount*6);Q:=0;
  for Card:=0 to Length(Indices)div 6-1 do begin
    MinU:=Infinity;MinV:=Infinity;MaxU:=-Infinity;MaxV:=-Infinity;
    for I:=0 to 5 do begin
      Base:=Indices[Card*6+I]*8;
      if Base+7>=Length(Data)then raise Exception.Create('Invalid vegetation index');
      MinU:=Min(MinU,Data[Base+6]);MaxU:=Max(MaxU,Data[Base+6]);
      MinV:=Min(MinV,Data[Base+7]);MaxV:=Max(MaxV,Data[Base+7]);
    end;
    if(MaxU-MinU<0.00001)or(MaxV-MinV<0.00001)then raise Exception.Create('Degenerate vegetation UV');
    FillChar(Found,SizeOf(Found),0);
    for I:=0 to 5 do begin
      Base:=Indices[Card*6+I]*8;
      U:=(Data[Base+6]-MinU)/(MaxU-MinU);V:=(Data[Base+7]-MinV)/(MaxV-MinV);
      if(Min(Abs(U),Abs(U-1))>0.0001)or(Min(Abs(V),Abs(V-1))>0.0001)then
        raise Exception.Create('Vegetation layer needs a rectangular source card');
      C:=Ord(U>0.5)+2*Ord(V>0.5);Found[C]:=True;
      for J:=0 to 7 do Corners[C,J]:=Data[Base+J];
    end;
    for C:=0 to 3 do if not Found[C]then raise Exception.Create('Incomplete vegetation card');
    Base:=Indices[Card*6]*8;I:=Indices[Card*6+1]*8;J:=Indices[Card*6+2]*8;
    Sign:=(Data[I+6]-Data[Base+6])*(Data[J+7]-Data[Base+7])-
      (Data[I+7]-Data[Base+7])*(Data[J+6]-Data[Base+6]);
    { Original shrubs duplicate backfaces. Rendering already disables culling. }
    if Sign>0 then Continue;
    for Layer:=0 to LayerCount-1 do begin
      for C:=0 to 3 do begin
        { Every layer is an EXACT full-sized copy. Never crop, scale, move,
          remap UVs or assemble a new silhouette from smaller bough quads. }
        for J:=0 to 7 do Vertices[Q*4+C,J]:=Corners[C,J];
        Vertices[Q*4+C,8]:=(Corners[0,0]+Corners[1,0])*0.5;
        Vertices[Q*4+C,9]:=(Corners[0,2]+Corners[1,2])*0.5;
        Vertices[Q*4+C,10]:=Layer*2.399963+Abs(Corners[0,3])*2.1+Abs(Corners[0,5])*4.7;
        if Layer<>0 then Vertices[Q*4+C,11]:=AngleScale;
        if Layer=LayerCount-1 then Vertices[Q*4+C,11]:=AngleScale*0.5;
        Vertices[Q*4+C,12]:=Layer;
        Vertices[Q*4+C,13]:=Corners[1,0]-Corners[0,0];
        Vertices[Q*4+C,14]:=Corners[1,2]-Corners[0,2];
      end;
      { Preserve the original triangle diagonal and winding as well. }
      for I:=0 to 5 do begin
        Base:=Indices[Card*6+I]*8;
        C:=Ord(Data[Base+6]>(MinU+MaxU)*0.5)+2*Ord(Data[Base+7]>(MinV+MaxV)*0.5);
        NewIndices[Q*6+I]:=Q*4+C;
      end;
      Inc(Q);
    end;
  end;
  SetLength(Vertices,Q*4);SetLength(NewIndices,Q*6);
end;
end.

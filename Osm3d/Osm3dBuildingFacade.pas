unit Osm3dBuildingFacade;

{$mode objfpc}{$H+}{$modeswitch advancedrecords}
{$Q-}{$R-}

interface

uses SysUtils, Math, FGL, CastleVectors, X3DNodes,
  Osm3dGroundComposite, Osm3dStaticGeometry, Osm3dGpuGround, Osm3dFacadeLayout, Osm3dArchitecture;

const
  BUILDING_DETAIL_MAX_TRIANGLES = 65536;
  BUILDING_DETAIL_PER_HOUSE = 960;
  { Distance fading remains per component at 45..70 m. Coarser static buckets
    limit CGE LOD traversal, including the four world-shadow passes. }
  BUILDING_DETAIL_CELL = 512.0;
  BUILDING_DETAIL_NEAR = 45.0;
  BUILDING_DETAIL_FAR = 70.0;

type
  TBuildingFloats = array of Single;
  TBuildingDetailVertex = record
    Position, Normal, Anchor: TVector3;
    Color: TVector3;
    Roughness: Single;
  end;
  TBuildingDetailVertices = array of TBuildingDetailVertex;
  TBuildingDetailIndices = array of LongInt;
  TBuildingFacadeFrame = record
    Origin, U, V, Normal: TVector3;
    MinUV, MaxUV: TVector2;
    Area: Double;
    House, Material: Integer;
    Authored:Integer; { layout index, -1 = automatic }
    Seed: Single;
    Entrance: Boolean;
    function Rectangular: Boolean;
    function DoorBounds(out Lo, Hi: TVector2): Boolean;
  end;
  TBuildingFacadeFrames = array of TBuildingFacadeFrame;
  TBuildingDetailGeometryArray = array of TIndexedFaceSetNode;
  TBuildingFacadeData = class
  public
    { Wall: metres above footing / below eaves, house seed, facade seed.
      Roof: building-local X/Z, house seed, zero. No world-coordinate hash. }
    Info: TBuildingFloats;
    Frames: TBuildingFacadeFrames;
    DetailVertices: TBuildingDetailVertices;
    DetailIndices: TBuildingDetailIndices;
    HouseCount: Integer;
    AuthoredBalconies, AuthoredCornices:Integer;
    PhotoTintColors:array of TVector3;
    constructor Create(Mesh: TGroundCompositeMesh; BuildDetails: Boolean;
      Ground:TGpuGroundTile=nil; GroundX:Single=0; GroundZ:Single=0;
      const Layouts:TFacadeLayouts=nil; const Tints:TBuildingTints=nil);
    procedure AttachInfo(Geometry: TIndexedFaceSetNode);
    function DetailGeometry: TIndexedFaceSetNode;
    function DetailGeometries: TBuildingDetailGeometryArray;
  end;

function BuildingStableSeed(Id: Int64): Single;
function BuildingFrameColor(Seed: Single): TVector3;

implementation

type
  TIdMap = specialize TFPGMap<Int64, Integer>;
  TFaceMap = specialize TFPGMap<string, Integer>;
  THouse = record
    MinP, MaxP: TVector3;
    Seed: Single;
    DetailTriangles: Integer;
    DetailBudget, PrimaryFace: Integer;
    Entrance: Boolean;
    EntranceFace: Integer;
    EntranceRise: Single;
    FacadeCount: Integer;
    BaseY, EaveY: Single;
    Authored:Boolean;
    TintSlot:Integer;
  end;
  THouses = array of THouse;

function BuildingStableSeed(Id: Int64): Single;
var H: QWord;
begin
  H := QWord(Id);
  H := (H xor (H shr 30)) * QWord($BF58476D1CE4E5B9);
  H := (H xor (H shr 27)) * QWord($94D049BB133111EB);
  H := H xor (H shr 31);
  Result := 1 + (H mod 65521);
end;

function BuildingFrameColor(Seed: Single): TVector3;
begin
  { Keep identical to bldFrameColor in building_material.glsl. }
  case Trunc(Seed) mod 5 of
    0: Result := Vector3(0.22, 0.19, 0.16);
    1: Result := Vector3(0.34, 0.36, 0.36);
    else Result := Vector3(0.76, 0.75, 0.70);
  end;
end;

function TBuildingFacadeFrame.Rectangular: Boolean;
var A: Double;
begin
  A := (MaxUV.X-MinUV.X) * (MaxUV.Y-MinUV.Y);
  Result := (A > 0.5) and (MaxUV.Y-MinUV.Y >= 0.9) and
    (Abs(Area-A) < Max(0.005, A*0.002)) and ((Authored>=0) or (MinUV.Y >= -0.02));
end;

procedure WindowPaneBounds(Material: Integer; out Lo, Hi: TVector2);
begin
  if (Material=1) or (Material=4) then
  begin Lo:=Vector2(0.3203125,0.2109375); Hi:=Vector2(0.6796875,0.787109375) end
  else
  begin Lo:=Vector2(0.30859375,0.224609375); Hi:=Vector2(0.693359375,0.77734375) end;
end;

function TBuildingFacadeFrame.DoorBounds(out Lo, Hi: TVector2): Boolean;
var PaneLo, PaneHi: TVector2; W, Center, HalfWidth: Single;
begin
  Result:=Entrance;
  Lo:=TVector2.Zero; Hi:=TVector2.Zero;
  if not Result then Exit;
  WindowPaneBounds(Material,PaneLo,PaneHi);
  W:=U.Length;
  { Replace the first whole ground-floor window, including its painted frame.
    Keep these dimensions identical to the material's doorway mask. }
  Center:=(PaneLo.X+PaneHi.X)*0.5*W;
  HalfWidth:=Max(1.10,(PaneHi.X-PaneLo.X+0.07)*W)*0.5;
  Lo:=Vector2(Center-HalfWidth,0);
  Hi:=Vector2(Center+HalfWidth,
    Min(MaxUV.Y*V.Y-0.30,Max(2.30,(PaneHi.Y+0.025)*V.Y)));
end;

function IsWall(M: Integer): Boolean; inline;
begin
  Result := (M < 6) or (M >= 12);
end;

constructor TBuildingFacadeData.Create(Mesh: TGroundCompositeMesh; BuildDetails: Boolean;
  Ground:TGpuGroundTile; GroundX:Single; GroundZ:Single; const Layouts:TFacadeLayouts; const Tints:TBuildingTints);
var
  Houses: THouses;
  FacadeScale: array of Single;
  Ids: TIdMap;
  Faces: TFaceMap;
  VertexHouse, VertexFace: array of Integer;
  I, J, K, H, F, M, A, B, C, N, UCell, VCell, AddedWindows, WindowLimit: Integer;
  Eligible, RemainingBoxes, RemainingHouses, Pass, AuthoredHouses: Integer;
  Id: Int64;
  P, P0, E1, E2, TU, TV, O, NN, Rel: TVector3;
  UV0, UV1, UV2, D1, D2: TVector2;
  DoorLo, DoorHi: TVector2;
  Det, Width, Height, FloorHeight, MinX, MaxX, MinY, MaxY, GroundY, EntryScore: Single;
  Key: string;
  Frame: TBuildingFacadeFrame;
  DV, DI, DVCapacity, DICapacity: Integer;
  HouseLimit, HasDoor: Boolean;
  TintCount:Integer;

  function TintSlotFor(AnId:Int64):Integer;
  var I,J:Integer; C:TVector3; D,Best:Single;
  begin
    Result:=0;
    for I:=0 to High(Tints) do if Tints[I].OsmId=AnId then begin
      C:=Vector3(((Tints[I].Color shr 16) and 255)/255.0,
        ((Tints[I].Color shr 8) and 255)/255.0,(Tints[I].Color and 255)/255.0);
      Best:=1e30;
      for J:=1 to TintCount-1 do begin
        D:=(C-PhotoTintColors[J]).LengthSqr;
        if D<Best then begin Best:=D; Result:=J end;
      end;
      if (Best>0.000001) and (TintCount<32) then begin
        Result:=TintCount; PhotoTintColors[Result]:=C; Inc(TintCount);
      end;
      Exit;
    end;
  end;

  procedure Box(const Facade:TBuildingFacadeFrame; X0,Y0,X1,Y1,Z0,Z1:Single;
    const Col:TVector3; Rough:Single; Permanent:Boolean=False); forward;

  procedure AuthoredDetails(LayoutIndex:Integer);
  var L:TFacadeLayout; Face:TBuildingFacadeFrame;
      I,J,Bay,FloorIndex:Integer; LeftU,RightU,StartU,EndU,Cursor,FH,Base,Top,Y,X,HalfW,Depth,PostX:Single;
      Found:Boolean; Pos,Ax,Low,High:TVector3;
  begin
    L:=Layouts[LayoutIndex]; Ax:=L.Axis; Found:=False; LeftU:=1e30; RightU:=-1e30;
    Base:=1e30; Top:=-1e30; FH:=4;
    Pos:=Vector3(L.A.X+GroundX,0,L.A.Y+GroundZ);
    for I:=0 to Length(Frames)-1 do if Frames[I].Authored=LayoutIndex then begin
      Face:=Frames[I]; H:=Face.House; FH:=Face.V.Y;
      Low:=Face.Origin+Face.U*Face.MinUV.X+Face.V*Face.MinUV.Y;
      High:=Face.Origin+Face.U*Face.MaxUV.X+Face.V*Face.MaxUV.Y;
      LeftU:=Min(LeftU,TVector3.DotProduct(Low-Pos,Ax));
      RightU:=Max(RightU,TVector3.DotProduct(High-Pos,Ax));
      Base:=Min(Base,Low.Y); Top:=Max(Top,High.Y); Found:=True;
    end;
    if not Found then Exit;
    Face.Origin:=Vector3(Pos.X,Base,Pos.Z); Face.U:=Ax; Face.V:=Vector3(0,FH,0); Face.Normal:=L.Normal;
    { Long cornices use one closed box, not a box at every window. }
    for I:=0 to Length(L.Cornices)-1 do begin
      Y:=L.Cornices[I]*FH;
      if (Y<0.20) or (Base+Y>Top+0.02) then Continue;
      if (Houses[H].DetailTriangles+12>Houses[H].DetailBudget) or (DI div 4+12>BUILDING_DETAIL_MAX_TRIANGLES) then Break;
      Depth:=0.22; if Abs(Base+Y-Top)<0.1 then Depth:=0.38;
      Box(Face,LeftU,Y-0.20,RightU,Min(Y,Top-Base),0.006,Depth,Vector3(0.66,0.61,0.52),0.87,True);
      Inc(AuthoredCornices);
    end;
    Cursor:=LeftU;
    while Cursor<RightU-0.001 do begin
      L.BayAt(Cursor+0.00002,Bay,StartU,EndU);
      X:=(StartU+EndU)*0.5; HalfW:=(EndU-StartU)*L.BalconyWidth*0.5; Depth:=L.BalconyDepth;
      { The tile owning the bay centre emits the complete balcony. No torn
        railings at a clipped tile edge, and no duplicate neighbour geometry. }
      if (X>=LeftU-0.00001) and (X<RightU-0.00001) then
        for FloorIndex:=1 to 23 do if (L.Bays[Bay].BalconyFloors and (LongWord(1) shl FloorIndex))<>0 then begin
          Y:=(FloorIndex-L.Bays[Bay].FloorShift+0.224609375)*FH-0.08;
          if (Base+Y+0.85>=Top) then Continue;
          if (Houses[H].DetailTriangles+120>Houses[H].DetailBudget) or (DI div 4+120>BUILDING_DETAIL_MAX_TRIANGLES) then Exit;
          Box(Face,X-HalfW,Y-0.14,X+HalfW,Y,0.006,Depth,Vector3(0.57,0.54,0.47),0.9,True);
          Box(Face,X-HalfW-0.025,Y+0.78,X+HalfW+0.025,Y+0.84,Depth-0.11,Depth+0.025,Vector3(0.63,0.60,0.53),0.7,True);
          Box(Face,X-HalfW-0.025,Y+0.78,X-HalfW+0.11,Y+0.84,0.006,Depth,Vector3(0.63,0.60,0.53),0.7,True);
          Box(Face,X+HalfW-0.11,Y+0.78,X+HalfW+0.025,Y+0.84,0.006,Depth,Vector3(0.63,0.60,0.53),0.7,True);
          for J:=0 to 5 do begin
            PostX:=X-HalfW+0.055+(2*HalfW-0.11)*J/5;
            Box(Face,PostX-0.055,Y,PostX+0.055,Y+0.78,Depth-0.10,Depth,Vector3(0.52,0.49,0.43),0.85,True);
          end;
          Inc(AuthoredBalconies);
        end;
      Cursor:=EndU;
    end;
  end;

  procedure SetInfo(Index: Integer; X, Y, Seed, FaceSeed: Single);
  begin
    Info[Index*4] := X;
    Info[Index*4+1] := Y;
    { Keep the 16-bit identity intact; the high bits select a small uniform
      palette. No extra attribute or per-vertex memory for authored colours. }
    Info[Index*4+2] := Seed+Houses[VertexHouse[Index]].TintSlot*65536;
    Info[Index*4+3] := FaceSeed;
  end;

  procedure Box(const Facade: TBuildingFacadeFrame;
    X0, Y0, X1, Y1, Z0, Z1: Single; const Col: TVector3; Rough: Single;
    Permanent:Boolean);
  var
    Points: array[0..7] of TVector3;
    NX, NY, NZ, Anchor, Axis: TVector3;
    L: Integer;
    procedure Quad(Q0, Q1, Q2, Q3: Integer; const Normal: TVector3);
    var Q: array[0..3] of Integer; T: Integer;
    begin
      Q[0] := Q0; Q[1] := Q1; Q[2] := Q2; Q[3] := Q3;
      for T := 0 to 3 do
      begin
        DetailVertices[DV+T].Position := Points[Q[T]];
        DetailVertices[DV+T].Normal := Normal;
        { Collapse the short axes, preserving a cornice's length or a jamb's
          height. Its ends must not slide inward as the camera moves away. }
        DetailVertices[DV+T].Anchor := Anchor + Axis *
          TVector3.DotProduct(Points[Q[T]]-Anchor,Axis);
        if Permanent then DetailVertices[DV+T].Anchor:=Points[Q[T]];
        DetailVertices[DV+T].Color := Col;
        DetailVertices[DV+T].Roughness := Rough;
      end;
      DetailIndices[DI] := DV; DetailIndices[DI+1] := DV+1;
      DetailIndices[DI+2] := DV+2; DetailIndices[DI+3] := -1;
      DetailIndices[DI+4] := DV; DetailIndices[DI+5] := DV+2;
      DetailIndices[DI+6] := DV+3; DetailIndices[DI+7] := -1;
      Inc(DV, 4); Inc(DI, 8);
    end;
  begin
    if (X1 <= X0) or (Y1 <= Y0) or (Z1 <= Z0) then Exit;
    H := Facade.House;
    if (DI div 4 + 12 > BUILDING_DETAIL_MAX_TRIANGLES) or
       (Houses[H].DetailTriangles+12 > Houses[H].DetailBudget) then Exit;
    if DV+24 > DVCapacity then
    begin
      DVCapacity := Max(DV+24, Max(256, DVCapacity*2));
      SetLength(DetailVertices, DVCapacity);
    end;
    if DI+48 > DICapacity then
    begin
      DICapacity := Max(DI+48, Max(512, DICapacity*2));
      SetLength(DetailIndices, DICapacity);
    end;
    NX := Facade.U.Normalize; NY := Vector3(0,1,0); NZ := Facade.Normal;
    for L := 0 to 7 do
      Points[L] := Facade.Origin + NX * (X0+(X1-X0)*(L and 1)) +
        NY*(Y0+(Y1-Y0)*((L shr 1) and 1)) +
        NZ*(Z0+(Z1-Z0)*((L shr 2) and 1));
    Anchor := Facade.Origin + NX*((X0+X1)*0.5) + NY*((Y0+Y1)*0.5);
    Axis:=NX;
    if (Y1-Y0>X1-X0) and (Y1-Y0>Z1-Z0) then Axis:=NY
    else if Z1-Z0>X1-X0 then Axis:=NZ;
    { U x up points out of the facade. Six consistently outward faces. }
    Quad(4,5,7,6,NZ); Quad(1,0,2,3,-NZ);
    Quad(0,4,6,2,-NX); Quad(5,1,3,7,NX);
    Quad(2,6,7,3,NY); Quad(0,1,5,4,-NY);
    Inc(Houses[H].DetailTriangles,12);
  end;

  procedure EntranceSteps(const Facade:TBuildingFacadeFrame);
  var Lo,Hi:TVector2; Sample,Front:TVector3; GroundY,FrontY,Rise,Run,StepH:Single;
    Steps,S,Need:Integer;
  begin
    if (Ground=nil) or not Facade.DoorBounds(Lo,Hi) then Exit;
    Sample:=Facade.Origin+Facade.U.Normalize*((Lo.X+Hi.X)*0.5)+Facade.Normal*0.45;
    if not Ground.SampleGeometry(Sample.X-GroundX,Sample.Z-GroundZ,Facade.Origin.Y,False,GroundY) then Exit;
    Rise:=Facade.Origin.Y-GroundY;
    if (Rise<0.03) or (Rise>2.4) then Exit;
    Steps:=Max(1,Ceil(Rise/0.18));Run:=0.65+Steps*0.30;
    Front:=Sample+Facade.Normal*(Run-0.45);
    if not Ground.SampleGeometry(Front.X-GroundX,Front.Z-GroundZ,Facade.Origin.Y,False,FrontY) then Exit;
    Rise:=Facade.Origin.Y-FrontY;
    if (Rise<0.03) or (Rise>2.4) then Exit;
    Steps:=Max(1,Ceil(Rise/0.18));StepH:=Rise/Steps;
    Need:=(Steps+1)*12;
    if (Houses[Facade.House].DetailTriangles+Need>Houses[Facade.House].DetailBudget) or
       (DI div 4+Need>BUILDING_DETAIL_MAX_TRIANGLES) then Exit;
    { Closed concrete solids embed below the sampled surface. Threshold and
      stair treads remain connected at every distance; no per-frame raycasts. }
    Box(Facade,Lo.X-0.20,-Rise-0.08,Hi.X+0.20,0,0.006,0.65,
      Vector3(0.43,0.42,0.39),0.93,True);
    for S:=0 to Steps-1 do
      Box(Facade,Lo.X-0.20,-Rise-0.08,Hi.X+0.20,-StepH*S,
        0.65+S*0.30,0.65+(S+1)*0.30,Vector3(0.43,0.42,0.39),0.93,True);
  end;

  procedure WindowDetail(const Facade: TBuildingFacadeFrame; UIndex, VIndex: Integer);
  var L, R, Bottom, Top, W, FH: Single;
      PaneLo, PaneHi: TVector2;
      Col: TVector3;
  begin
    W := Facade.U.Length; FH := Facade.V.Y;
    WindowPaneBounds(Facade.Material,PaneLo,PaneHi);
    L := (UIndex+PaneLo.X)*W; R := (UIndex+PaneHi.X)*W;
    Bottom := (VIndex+PaneLo.Y)*FH; Top := (VIndex+PaneHi.Y)*FH;
    Col := BuildingFrameColor(Houses[Facade.House].Seed);
    { The window atlas stays in the wall plane; 6 cm projecting jambs give
      the opening a real reveal without a second coplanar pane. }
    Box(Facade,L-0.07,Bottom-0.06,L,Top+0.06,0.006,0.065,Col,0.58);
    Box(Facade,R,Bottom-0.06,R+0.07,Top+0.06,0.006,0.065,Col,0.58);
    Box(Facade,L,Top,R,Top+0.07,0.006,0.065,Col,0.58);
    Box(Facade,L-0.14,Bottom-0.10,R+0.14,Bottom,0.006,0.16,
      Vector3(0.51,0.50,0.46),0.85);
  end;

begin
  inherited Create;
  SetLength(PhotoTintColors,32); TintCount:=1;
  if Mesh=nil then Exit;
  Houses:=nil;
  Ids:=TIdMap.Create; Faces:=TFaceMap.Create;
  Ids.Sorted:=True; Faces.Sorted:=True;
  try
    SetLength(VertexHouse,Mesh.VertexCount);
    SetLength(VertexFace,Mesh.VertexCount);
    SetLength(Info,Mesh.VertexCount*4);
    for I:=0 to Mesh.VertexCount-1 do
    begin
      VertexFace[I]:=-1; Id:=Mesh.OsmIdOf(I);
      J:=Ids.IndexOf(Id);
      if J<0 then
      begin
        H:=Length(Houses); SetLength(Houses,H+1);
        Houses[H].MinP:=Mesh.PositionOf(I); Houses[H].MaxP:=Houses[H].MinP;
        Houses[H].BaseY:=1e30; Houses[H].EaveY:=-1e30;
        Houses[H].PrimaryFace:=-1;
        Houses[H].EntranceFace:=-1; Houses[H].EntranceRise:=1e30;
        Houses[H].Seed:=BuildingStableSeed(Id);
        Houses[H].TintSlot:=TintSlotFor(Id);
        { Zero identifies generated/non-building geometry: no invented houses. }
        if Id=0 then Houses[H].Seed:=0;
        Ids.Add(Id,H);
      end else H:=Ids.Data[J];
      VertexHouse[I]:=H; P:=Mesh.PositionOf(I);
      for K:=0 to 2 do
      begin
        Houses[H].MinP.Data[K]:=Min(Houses[H].MinP.Data[K],P.Data[K]);
        Houses[H].MaxP.Data[K]:=Max(Houses[H].MaxP.Data[K],P.Data[K]);
      end;
    end;
    HouseCount:=Length(Houses);
    for I:=0 to Mesh.TriangleCount-1 do
    begin
      A:=Mesh.Indices[I*3]; B:=Mesh.Indices[I*3+1]; C:=Mesh.Indices[I*3+2];
      M:=Mesh.MatIdOf(A); H:=VertexHouse[A];
      if IsArchitectureUV(Mesh.UVOf(A)) then Continue;
      if not IsWall(M) or (Houses[H].Seed=0) or
        (VertexHouse[B]<>H) or (VertexHouse[C]<>H) or
        (Mesh.MatIdOf(B)<>M) or (Mesh.MatIdOf(C)<>M) then Continue;
      P0:=Mesh.PositionOf(A); E1:=Mesh.PositionOf(B)-P0; E2:=Mesh.PositionOf(C)-P0;
      NN:=TVector3.CrossProduct(E1,E2);
      if NN.Length<0.0001 then Continue;
      NN:=NN.Normalize;
      if Abs(NN.Y)>0.02 then Continue;
      UV0:=Mesh.UVOf(A); UV1:=Mesh.UVOf(B); UV2:=Mesh.UVOf(C);
      D1:=UV1-UV0; D2:=UV2-UV0; Det:=D1.X*D2.Y-D2.X*D1.Y;
      if Abs(Det)<0.00001 then Continue;
      TU:=(E1*D2.Y-E2*D1.Y)/Det; TV:=(E2*D1.X-E1*D2.X)/Det;
      if (TV.Y<2.0) or (TV.Y>6.5) or (Abs(TU.Y)>0.01) or
        (Abs(TV.X)+Abs(TV.Z)>0.01) or (TU.Length<0.8) or (TU.Length>8) then Continue;
      { Frame axes must be right handed, otherwise details would face indoors. }
      if TVector3.DotProduct(TVector3.CrossProduct(TU,TV),NN)<=0 then Continue;
      O:=P0-TU*UV0.X-TV*UV0.Y; Rel:=O-Houses[H].MinP;
      Key:=Format('%d/%d/%d/%d/%d/%d/%d/%d', [H,M,Round(Rel.X*8),
        Round(Rel.Y*8),Round(Rel.Z*8),Round(TU.X*32),Round(TU.Z*32),Round(TV.Y*32)]);
      J:=Faces.IndexOf(Key);
      if J<0 then
      begin
        F:=Length(Frames); SetLength(Frames,F+1); Faces.Add(Key,F);
        Frames[F].Origin:=O; Frames[F].U:=TU; Frames[F].V:=TV; Frames[F].Normal:=NN;
        Frames[F].MinUV:=UV0; Frames[F].MaxUV:=UV0;
        Frames[F].House:=H; Frames[F].Material:=M;
        Frames[F].Authored:=-1;
        for J:=0 to High(Layouts) do
          if (Layouts[J].OsmId=Mesh.OsmIdOf(A)) and
            Layouts[J].Matches(P0+E1*0.333333+E2*0.333333,NN,GroundX,GroundZ) then begin
            Frames[F].Authored:=J; Houses[H].Authored:=True; Break;
          end;
        { Stable under scene-origin translation. Orientation and origin both
          participate, so parallel facades do not repeat the same rooms. }
        Frames[F].Seed:=BuildingStableSeed(Trunc(Houses[H].Seed)*Int64(104729)+
          Round(Rel.X*4)*Int64(8191)+Round(Rel.Z*4)*Int64(131)+
          Round(NN.X*64)*Int64(17)+Round(NN.Z*64));
      end else F:=Faces.Data[J];
      Frames[F].Area:=Frames[F].Area+Abs(Det)*0.5;
      for K:=0 to 2 do
      begin
        N:=Mesh.Indices[I*3+K]; VertexFace[N]:=F; UV0:=Mesh.UVOf(N);
        Frames[F].MinUV.X:=Min(Frames[F].MinUV.X,UV0.X);
        Frames[F].MinUV.Y:=Min(Frames[F].MinUV.Y,UV0.Y);
        Frames[F].MaxUV.X:=Max(Frames[F].MaxUV.X,UV0.X);
        Frames[F].MaxUV.Y:=Max(Frames[F].MaxUV.Y,UV0.Y);
      end;
    end;
    { One architectural rhythm per house. Quantize to complete windows on a
      complete facade; leave clipped walls, gables and skirts alone. Both the
      material and the trim below consume these same adjusted coordinates. }
    SetLength(FacadeScale,Length(Frames));
    for F:=0 to High(Frames) do begin
      FacadeScale[F]:=1; Frame:=Frames[F]; H:=Frame.House;
      if Frame.Authored>=0 then Continue;
      if not Frame.Rectangular or (Abs(Frame.MinUV.X)>0.001) or
        (Abs(Frame.MaxUV.X-Round(Frame.MaxUV.X))>0.001) or (Frame.MaxUV.X<1) then Continue;
      Height:=Houses[H].MaxP.Y-Houses[H].MinP.Y;
      Width:=3.10+0.35*(Trunc(Houses[H].Seed) mod 4);
      if Height>25 then Width:=Width-0.35;
      N:=Max(1,Round(Frame.MaxUV.X*Frame.U.Length/Width));
      FacadeScale[F]:=N/Frame.MaxUV.X;
      Frames[F].U:=Frame.U/FacadeScale[F];
      Frames[F].MaxUV.X:=N; Frames[F].Area:=Frame.Area*FacadeScale[F];
    end;
    for I:=0 to Mesh.VertexCount-1 do begin
      F:=VertexFace[I];
      if F>=0 then Mesh.Verts[I].UV.X:=Mesh.Verts[I].UV.X*FacadeScale[F];
    end;
    { Select one entrance per house independently of the near-detail budget.
      Bit 16 of the facade attribute also tells the material where its door is. }
    Eligible:=0;
    for F:=0 to High(Frames) do
    begin
      H:=Frames[F].House;
      Width:=(Frames[F].MaxUV.X-Frames[F].MinUV.X)*Frames[F].U.Length;
      Height:=(Frames[F].MaxUV.Y-Frames[F].MinUV.Y)*Frames[F].V.Y;
      if Frames[F].Rectangular and ((Frames[F].Authored>=0) or (Frames[F].MinUV.Y<0.02)) then
      begin
        Inc(Houses[H].FacadeCount);
        Houses[H].BaseY:=Min(Houses[H].BaseY,Frames[F].Origin.Y+Frames[F].MinUV.Y*Frames[F].V.Y);
        Houses[H].EaveY:=Max(Houses[H].EaveY,Frames[F].Origin.Y+Frames[F].MaxUV.Y*Frames[F].V.Y);
        if (Width>=2) and (Height>=2.3) then
        begin
          J:=Houses[H].PrimaryFace;
          if J<0 then begin Houses[H].PrimaryFace:=F; Inc(Eligible) end
          else if Width>(Frames[J].MaxUV.X-Frames[J].MinUV.X)*Frames[J].U.Length then
            Houses[H].PrimaryFace:=F;
        end;
      end;
      if (Frames[F].Authored<0) and Frames[F].Rectangular and (Frames[F].MinUV.Y<0.02) and
        (Frames[F].MinUV.X<0.02) and (Width>5) and (Height>2.3) and (Height<25) and
        (Frames[F].U.Length>=1.35) and (Frames[F].MaxUV.X>=1.0) and
        ((Ground<>nil) or not Houses[H].Entrance) then
      begin
        EntryScore:=1000;
        P:=Frames[F].Origin+Frames[F].U*0.5+Frames[F].Normal*0.45;
        if (Ground<>nil) and Ground.SampleGeometry(P.X-GroundX,P.Z-GroundZ,P.Y,False,GroundY) then
          EntryScore:=Abs(P.Y-GroundY);
        if EntryScore<Houses[H].EntranceRise then begin
          J:=Houses[H].EntranceFace;
          if J>=0 then Frames[J].Entrance:=False;
          Frames[F].Entrance:=True; Houses[H].Entrance:=True;
          Houses[H].EntranceFace:=F;Houses[H].EntranceRise:=EntryScore;
        end;
      end;
    end;
    for H:=0 to High(Houses) do
      if Houses[H].FacadeCount=0 then
      begin Houses[H].BaseY:=Houses[H].MinP.Y; Houses[H].EaveY:=Houses[H].MaxP.Y end;
    for I:=0 to Mesh.VertexCount-1 do
    begin
      H:=VertexHouse[I]; P:=Mesh.PositionOf(I); F:=VertexFace[I];
      if IsArchitectureUV(Mesh.UVOf(I)) then begin
        { Stable local metric coordinates for architectural paint/stone.
          Payload is forwarded directly by the vertex shader. No automatic
          windows, invented entrance or duplicate near-detail geometry. }
        NN:=Mesh.NormalOf(I);Rel:=P-Houses[H].MinP;
        SetInfo(I,Rel.X*NN.Z-Rel.Z*NN.X,Rel.Y,Houses[H].Seed,0);
      end else if not IsWall(Mesh.MatIdOf(I)) then
        SetInfo(I,P.X-Houses[H].MinP.X,P.Z-Houses[H].MinP.Z,Houses[H].Seed,0)
      else if F>=0 then
      begin
        { Foundation and wall share a physical datum: no new horizontal seam.
          Bits 16/17 select entrance/window facade; the low 16 bits stay stable. }
        if Frames[F].Rectangular then
          SetInfo(I,P.Y-(Frames[F].Origin.Y+Frames[F].MinUV.Y*Frames[F].V.Y),
            Frames[F].Origin.Y+Frames[F].MaxUV.Y*Frames[F].V.Y-P.Y,
            Houses[H].Seed,Frames[F].Seed+Ord(Frames[F].Entrance)*65536+131072+
              Ord(Frames[F].Authored>=0)*FACADE_AUTHORED_BIT)
        else
          SetInfo(I,P.Y-Houses[H].BaseY,Houses[H].EaveY-P.Y,Houses[H].Seed,Frames[F].Seed);
      end
      else
        SetInfo(I,P.Y-Houses[H].BaseY,Houses[H].EaveY-P.Y,Houses[H].Seed,0);
    end;
    if not BuildDetails then Exit;
    { Dense city tiles can contain thousands of houses. Allocate before emitting
      anything: the first few houses must not exhaust the entire tile budget.
      Small tiles keep full trim; dense ones retain a few larger silhouette cues. }
    RemainingBoxes:=BUILDING_DETAIL_MAX_TRIANGLES div 12;
    RemainingHouses:=Eligible;
    AuthoredHouses:=0;
    for H:=0 to High(Houses) do
      if (Houses[H].PrimaryFace>=0) and Houses[H].Authored then Inc(AuthoredHouses);
    for H:=0 to High(Houses) do
      if (Houses[H].PrimaryFace>=0) and Houses[H].Authored then begin
        { A dense Moscow tile can have thousands of houses. Reserving even
          three boxes for each would starve every accepted landmark. Reserve
          at least half for automatic houses while prioritising authored work. }
        N:=Min(8192 div 12,RemainingBoxes div Max(2,AuthoredHouses+1));
        Houses[H].DetailBudget:=N*12;
        Dec(RemainingBoxes,N); Dec(RemainingHouses); Dec(AuthoredHouses);
      end;
    for H:=0 to High(Houses) do
      if (Houses[H].PrimaryFace>=0) and not Houses[H].Authored then
      begin
        N:=BUILDING_DETAIL_PER_HOUSE div 12;
        N:=Min(N,RemainingBoxes div Max(1,RemainingHouses));
        Houses[H].DetailBudget:=N*12;
        Dec(RemainingBoxes,N); Dec(RemainingHouses);
      end;
    DV:=0; DI:=0; DVCapacity:=0; DICapacity:=0;
    for I:=0 to High(Layouts) do AuthoredDetails(I);
    { A shorter entrance wall must get its ground contact BEFORE trim on the
      primary facade consumes the house budget. }
    for F:=0 to High(Frames) do if Frames[F].Entrance then EntranceSteps(Frames[F]);
    for Pass:=0 to 1 do
    for F:=0 to High(Frames) do
    begin
      Frame:=Frames[F]; H:=Frame.House;
      if Frame.Authored>=0 then Continue;
      if (Pass=0)<>(Houses[H].PrimaryFace=F) then Continue;
      if Houses[H].DetailTriangles>=Houses[H].DetailBudget then Continue;
      if not Frame.Rectangular then Continue;
      Width:=Frame.U.Length; FloorHeight:=Frame.V.Y;
      MinX:=Frame.MinUV.X*Width; MaxX:=Frame.MaxUV.X*Width;
      MinY:=Frame.MinUV.Y*FloorHeight; MaxY:=Frame.MaxUV.Y*FloorHeight;
      Height:=MaxY-MinY;
      if (MaxX-MinX<2) or (Height<2.3) or (Frame.MinUV.Y>0.02) then Continue;
      HasDoor:=Frame.DoorBounds(DoorLo,DoorHi);
      { Foundation ledge and eaves follow this wall, never bridge a courtyard. }
      Box(Frame,MinX,MaxY-0.13,MaxX,MaxY,0.006,0.14,Vector3(0.65,0.64,0.59),0.87);
      if HasDoor then
      begin
        Box(Frame,MinX,MinY+0.06,DoorLo.X-0.07,MinY+0.26,0.006,0.075,Vector3(0.40,0.39,0.36),0.93);
        Box(Frame,DoorHi.X+0.07,MinY+0.06,MaxX,MinY+0.26,0.006,0.075,Vector3(0.40,0.39,0.36),0.93);
      end else
        Box(Frame,MinX,MinY+0.06,MaxX,MinY+0.26,0.006,0.075,Vector3(0.40,0.39,0.36),0.93);
      { One narrow square downpipe near each facade edge. No per-frame simulation. }
      if MaxX-MinX>4 then
        Box(Frame,MinX+0.10,MinY+0.16,MinX+0.18,MaxY-0.12,0.03,0.11,Vector3(0.31,0.32,0.31),0.56);
      { No sill across the entrance. Reserve both jambs, lintel and canopy
        together; dense tiles can use just the material's complete doorway. }
      if HasDoor and (Houses[H].DetailTriangles+48<=Houses[H].DetailBudget) and
        (DI div 4+48<=BUILDING_DETAIL_MAX_TRIANGLES) then
      begin
        P:=BuildingFrameColor(Houses[H].Seed);
        Box(Frame,DoorLo.X-0.07,0,DoorLo.X,DoorHi.Y+0.07,0.006,0.09,P,0.58);
        Box(Frame,DoorHi.X,0,DoorHi.X+0.07,DoorHi.Y+0.07,0.006,0.09,P,0.58);
        Box(Frame,DoorLo.X,DoorHi.Y,DoorHi.X,DoorHi.Y+0.07,0.006,0.09,P,0.58);
        Box(Frame,DoorLo.X-0.18,DoorHi.Y+0.08,DoorHi.X+0.18,DoorHi.Y+0.18,
          0.008,0.62,Vector3(0.34,0.35,0.34),0.65);
      end;
      AddedWindows:=0;
      { Reserve cornices/pipes for every facade before distributing window trim.
        A long first facade must not consume every detail on the visible side. }
      WindowLimit:=Max(0,Min(12,(Houses[Frame.House].DetailBudget-
        Houses[Frame.House].FacadeCount*36-72) div (48*Max(1,Houses[Frame.House].FacadeCount))));
      for VCell:=Max(0,Ceil(Frame.MinUV.Y)) to Min(1,Floor(Frame.MaxUV.Y+0.001)-1) do
        for UCell:=Ceil(Frame.MinUV.X) to Floor(Frame.MaxUV.X+0.001)-1 do
        begin
          if HasDoor and (UCell=0) and (VCell=0) then Continue;
          HouseLimit:=Houses[Frame.House].DetailTriangles+48>Houses[Frame.House].DetailBudget;
          if (AddedWindows>=WindowLimit) or HouseLimit or (DI div 4+48>BUILDING_DETAIL_MAX_TRIANGLES) then Break;
          WindowDetail(Frame,UCell,VCell); Inc(AddedWindows);
        end;
      { Occasional small first-floor balconies, restricted to masonry houses.
        Reserve all 5 boxes together: a budget limit cannot leave half a railing. }
      if (Frame.Material<>1) and (Height>7) and (Height<22) and (MaxX-MinX>7) and
        ((Trunc(Frame.Seed) mod 9)=0) and
        (Houses[Frame.House].DetailTriangles+60<=Houses[Frame.House].DetailBudget) and
        (DI div 4+60<=BUILDING_DETAIL_MAX_TRIANGLES) then
      begin
        P:=Vector3((Ceil(Frame.MinUV.X)+1.5)*Width,FloorHeight+0.18*FloorHeight,0);
        Box(Frame,P.X-0.85,P.Y-0.12,P.X+0.85,P.Y,0.006,0.78,Vector3(0.48,0.47,0.44),0.9);
        Box(Frame,P.X-0.85,P.Y,P.X+0.85,P.Y+0.74,0.70,0.78,Vector3(0.38,0.39,0.37),0.8);
        Box(Frame,P.X-0.85,P.Y,P.X-0.78,P.Y+0.74,0.006,0.70,Vector3(0.38,0.39,0.37),0.8);
        Box(Frame,P.X+0.78,P.Y,P.X+0.85,P.Y+0.74,0.006,0.70,Vector3(0.38,0.39,0.37),0.8);
        Box(Frame,P.X-0.88,P.Y+0.74,P.X+0.88,P.Y+0.78,0.68,0.80,Vector3(0.26,0.27,0.26),0.5);
      end;
      if DI div 4+12>BUILDING_DETAIL_MAX_TRIANGLES then Break;
    end;
    SetLength(DetailVertices,DV); SetLength(DetailIndices,DI);
  finally
    Ids.Free; Faces.Free;
  end;
end;

procedure TBuildingFacadeData.AttachInfo(Geometry: TIndexedFaceSetNode);
var A: TFloatVertexAttributeNode;
begin
  A:=TFloatVertexAttributeNode.Create;
  A.NameField:='bldInfo'; A.NumComponents:=4;
  AssignStaticField(A.FdValue,Info); Geometry.FdAttrib.Add(A);
end;

function MakeDetailGeometry(const Vertices: TBuildingDetailVertices;
  const Indices: TBuildingDetailIndices): TIndexedFaceSetNode;
var
  P,N: array of TVector3;
  Colors,Normals,Anchors: TBuildingFloats;
  Coord: TCoordinateNode;
  Norm: TNormalNode;
  CA, NA, AA: TFloatVertexAttributeNode;
  I,J: Integer;
begin
  Result:=nil;
  if Length(Vertices)=0 then Exit;
  SetLength(P,Length(Vertices)); SetLength(N,Length(P));
  SetLength(Colors,Length(P)*4);
  SetLength(Normals,Length(P)*3); SetLength(Anchors,Length(P)*3);
  for I:=0 to High(P) do
  begin
    P[I]:=Vertices[I].Position; N[I]:=Vertices[I].Normal;
    for J:=0 to 2 do
    begin
      Colors[I*4+J]:=Vertices[I].Color.Data[J];
      Normals[I*3+J]:=N[I].Data[J];
      Anchors[I*3+J]:=Vertices[I].Anchor.Data[J];
    end;
    Colors[I*4+3]:=Vertices[I].Roughness;
  end;
  Coord:=TCoordinateNode.Create; AssignStaticField(Coord.FdPoint,P);
  Norm:=TNormalNode.Create; AssignStaticField(Norm.FdVector,N);
  CA:=TFloatVertexAttributeNode.Create; CA.NameField:='bldDetailColor'; CA.NumComponents:=4;
  AssignStaticField(CA.FdValue,Colors);
  NA:=TFloatVertexAttributeNode.Create; NA.NameField:='bldDetailNormal'; NA.NumComponents:=3;
  AssignStaticField(NA.FdValue,Normals);
  AA:=TFloatVertexAttributeNode.Create; AA.NameField:='bldDetailAnchor'; AA.NumComponents:=3;
  AssignStaticField(AA.FdValue,Anchors);
  Result:=TIndexedFaceSetNode.Create; Result.Coord:=Coord; Result.Normal:=Norm;
  Result.Solid:=True; Result.NormalPerVertex:=True;
  AssignStaticField(Result.FdCoordIndex,Indices); Result.SetAttrib([CA,NA,AA]);
end;

function TBuildingFacadeData.DetailGeometry: TIndexedFaceSetNode;
begin
  Result:=MakeDetailGeometry(DetailVertices,DetailIndices);
end;

function TBuildingFacadeData.DetailGeometries: TBuildingDetailGeometryArray;
var Cells:TIdMap; Heads,Next,Counts:array of Integer;
    V:TBuildingDetailVertices; IX:TBuildingDetailIndices;
    I,J,C,N,B,AtV,AtI,CX,CZ:Integer; Key:Int64; Center:TVector3; Permanent:Boolean;
begin
  Result:=nil;
  Heads:=nil; Counts:=nil;
  N:=Length(DetailVertices) div 24;
  if N=0 then Exit;
  Cells:=TIdMap.Create; Cells.Sorted:=True;
  try
    SetLength(Next,N);
    for B:=0 to N-1 do
    begin
      Center:=Vector3(0,0,0);
      for I:=0 to 23 do Center:=Center+DetailVertices[B*24+I].Anchor;
      Center:=Center/24;
      CX:=Floor(Center.X/BUILDING_DETAIL_CELL);
      CZ:=Floor(Center.Z/BUILDING_DETAIL_CELL);
      Key:=(Int64(CX) shl 32) or Int64(LongWord(CZ));
      Permanent:=TVector3.Equals(DetailVertices[B*24].Position,DetailVertices[B*24].Anchor);
      Key:=Key*2+Ord(Permanent);
      J:=Cells.IndexOf(Key);
      if J<0 then
      begin
        C:=Length(Heads); SetLength(Heads,C+1); SetLength(Counts,C+1);
        Heads[C]:=-1; Cells.Add(Key,C);
      end else C:=Cells.Data[J];
      Next[B]:=Heads[C]; Heads[C]:=B; Inc(Counts[C]);
    end;
    SetLength(Result,Length(Heads));
    for C:=0 to High(Heads) do
    begin
      SetLength(V,Counts[C]*24); SetLength(IX,Counts[C]*48);
      AtV:=0; AtI:=0; B:=Heads[C];
      while B>=0 do
      begin
        for I:=0 to 23 do V[AtV+I]:=DetailVertices[B*24+I];
        for I:=0 to 47 do
        begin
          J:=DetailIndices[B*48+I];
          if J<0 then IX[AtI+I]:=-1 else IX[AtI+I]:=J-B*24+AtV;
        end;
        Inc(AtV,24); Inc(AtI,48); B:=Next[B];
      end;
      Result[C]:=MakeDetailGeometry(V,IX);
      if TVector3.Equals(V[0].Position,V[0].Anchor) then Result[C].X3DName:='BuildingStructure';
    end;
  finally Cells.Free end;
end;

end.

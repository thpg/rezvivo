unit BikeParametric_DropBar;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, CastleUtils, CastleVectors, X3DNodes, X3DLoad,
  BikeParametric, BikeParametric_Fork, BikeLog, BikeGfxUtil;

type
  TBarPlaceArray = array of TVector3;   { hand-grip positions read from the bar glb }

  { TDropBarComponent }

  TDropBarComponent = class(TBikeComponent)
  private
    FBarWidth:   Single;
    FBarDrop:    Single;
    FBarReach:   Single;
    FHoodLength: Single;
    FHoodAngle:  Single;
    FTapeColor:  Integer;   { packed $RRGGBB; -1 = inherit Ctx.Colors.Tape }
    { external handlebar model (glb in data/) }
    FUseModel:     Boolean;
    FModelURL:     string;
    FModelScale:   Single;
    FModelOffX, FModelOffY, FModelOffZ: Single;   { mm, fine offset from the steerer anchor }
    FModelRotX, FModelRotY, FModelRotZ: Single;   { degrees }
    FModelHasStem:    Boolean;                     { glb already contains the stem }
    FSteererBoneName: string;  { armature bone at steerer centre; aligned to stem_base }
    FModelStemShift, FModelStemReference: TVector3;
    { drop-curve bend: horizontal tops end at FXt; ellipse semi-axes FAell/FBell }
    FXt, FAell, FBell, FHkX, FHkY: Single;
    procedure ComputeArc(M: Single);
    function  ArcOffset(U: Single): TVector3;
    procedure BuildSteererStem(Ctx: TBikeBuildContext; const StemE: TVector3; StemDia, M: Single);
    function  TryLoadModel: TX3DRootNode;
    function  ReadModelBones(out AForkStock, APlaceR, APlaceL: TVector3): Boolean;
    { Read every PlaceR1..N / PlaceL1..N transform from the bar glb (until the first
      gap). Returns the count of complete R+L pairs found. }
    function  ReadModelPlaces(out PR, PL: TBarPlaceArray): Integer;
    { sculpted STI shifter (Body + BrakeLever + ShiftLever) at HBase, object space }
    procedure BuildHood(Ctx: TBikeBuildContext; const HBase: TVector3; HL: Single; DL: Integer);
  public
    constructor Create; override;
    destructor Destroy; override;
    class function ComponentName: string; override;
    procedure ApplyPreset(const APreset: string); override;
    procedure ComputeBones(Skel: TBikeSkeleton); override;
    procedure BuildGeometry(Ctx: TBikeBuildContext); override;
  published
    property BarWidth:   Single  read FBarWidth   write FBarWidth;    { mm, C-C at hoods }
    property BarDrop:    Single  read FBarDrop    write FBarDrop;     { mm, top to hook bottom }
    property BarReach:   Single  read FBarReach   write FBarReach;    { mm, center to forward-most }
    property HoodLength: Single  read FHoodLength write FHoodLength;  { mm, shifter body length (scales whole shifter) }
    property HoodAngle:  Single  read FHoodAngle  write FHoodAngle;   { degrees, shifter tilt (45 = neutral) }
    { Bar-tape colour as packed $RRGGBB. -1 (default) = global Ctx.Colors.Tape. }
    property TapeColor:  Integer read FTapeColor  write FTapeColor;
    { External handlebar model (glb under data/). When UseModel is true and the
      file loads, its geometry is added to the bike's node tree and the
      parametric bar is skipped; otherwise it falls back to the parametric
      build. The model is anchored on the steerer (stem_base); offsets fine-tune
      in mm, rotations in degrees, scale uniform. }
    property UseModel:     Boolean read FUseModel     write FUseModel;
    property ModelURL:     string  read FModelURL     write FModelURL;
    property ModelScale:   Single  read FModelScale   write FModelScale;
    property ModelOffsetX: Single  read FModelOffX    write FModelOffX;
    property ModelOffsetY: Single  read FModelOffY    write FModelOffY;
    property ModelOffsetZ: Single  read FModelOffZ    write FModelOffZ;
    property ModelRotX:    Single  read FModelRotX    write FModelRotX;
    property ModelRotY:    Single  read FModelRotY    write FModelRotY;
    property ModelRotZ:    Single  read FModelRotZ    write FModelRotZ;
    property ModelHasStem: Boolean read FModelHasStem write FModelHasStem;
    { Name of the glb armature bone at the steerer centre. When set and found,
      the model is shifted so that bone lands on the bike's steerer (stem_base).
      Leave empty to anchor the model origin at the steerer instead. }
    property ModelSteererBone: string read FSteererBoneName write FSteererBoneName;
  end;

implementation

uses
  CastleURIUtils, SyncObjs, X3DFields;

const
  { defaults — единый источник для Create и fallback'ов ComputeBones }
  DEF_BAR_WIDTH   = 420;    { mm, C-C at hoods }
  DEF_BAR_DROP    = 130;    { mm }
  DEF_BAR_REACH   = 80;     { mm }
  DEF_HOOD_LENGTH = 102;    { mm — shifter body length, scale reference for BuildHood }
  DEF_HOOD_ANGLE  = 45;     { degrees }
  { bare (unwrapped) bar + end-plug plastic }
  BARE_BAR_COL: TVector3 = (X: 0.02; Y: 0.02; Z: 0.022);
  BARE_BAR_SPEC: TVector3 = (X: 0.16; Y: 0.16; Z: 0.17);

{ Кэш РАСПАРСЕННЫХ данных руля (steerer-боун + пары PlaceR/L), ключ —
  resolved URL + mtime файла + имя steerer-боуна. Раньше ComputeBones грузил
  glb дважды за билд (ReadModelBones + ReadModelPlaces — каждый полный
  парсинг), а TryLoadModel — третий раз. Узлы между билдами кэшировать нельзя
  (владение/родители), поэтому TryLoadModel по-прежнему грузит узел на каждый
  билд, а данные костей/placer'ов читаются из кэша: 3 загрузки -> 1. }
type
  TDropBarModelData = record
    URL: string;
    MTime: Int64;
    SteererBone: string;
    Loaded: Boolean;      { glb распарсился (иначе вход не кэшируем — retry) }
    BonesOK: Boolean;     { нашлись оба placer'а PlaceR1/PlaceL1 }
    ForkStock, PlaceR, PlaceL, BarClamp: TVector3;
    PRs, PLs: TBarPlaceArray;
  end;

var
  DropBarModelCache: TDropBarModelData;
  DropBarModelCacheLock: TCriticalSection;

function DropBarFileMTime(const URL: string): Int64;
var F: string;
begin
  F := URIToFilenameSafe(URL);
  if (F <> '') and FileExists(F) then
    Result := FileAge(F)
  else
    Result := -1;
end;

{ Разобрать glb один раз: steerer + PlaceR1/PlaceL1 (бывший ReadModelBones)
  и все пары PlaceR1..N / PlaceL1..N до первого разрыва (бывший
  ReadModelPlaces). Логи «bone not found» — только здесь, т.е. при реальной
  загрузке, а не на каждом чтении из кэша. }
procedure ParseDropBarModelData(var Data: TDropBarModelData);
var Root: TX3DRootNode; NF, NR, NL: TTransformNode; n: Integer;
begin
  Data.Loaded := False;
  Data.BonesOK := False;
  Data.ForkStock := TVector3.Zero; Data.PlaceR := TVector3.Zero; Data.PlaceL := TVector3.Zero;
  SetLength(Data.PRs, 0); SetLength(Data.PLs, 0);
  Root := nil;
  try Root := LoadNode(Data.URL); except on E: Exception do Root := nil; end;
  if Root = nil then Exit;
  try
    Data.Loaded := True;
    NF := Root.FindNode(TTransformNode, Data.SteererBone, [fnNilOnMissing]) as TTransformNode;
    NR := Root.FindNode(TTransformNode, 'PlaceR1', [fnNilOnMissing]) as TTransformNode;
    NL := Root.FindNode(TTransformNode, 'PlaceL1', [fnNilOnMissing]) as TTransformNode;
    if NF <> nil then Data.ForkStock := NF.Translation;
    if NR <> nil then Data.PlaceR := NR.Translation;
    if NL <> nil then Data.PlaceL := NL.Translation;
    if NR = nil then StartupLog('[DropBar] hand bone not found: PlaceR1');
    if NL = nil then StartupLog('[DropBar] hand bone not found: PlaceL1');
    Data.BonesOK := (NR <> nil) and (NL <> nil);
    { PlaceL7 marks the centre top of the integrated bar. Older models can
      use the midpoint of the two narrow-top grips. The clamp axis is one
      tape radius below the contact surface. }
    NF:=Root.FindNode(TTransformNode,'PlaceL7',[fnNilOnMissing]) as TTransformNode;
    if NF<>nil then Data.BarClamp:=NF.Translation else begin
      NR:=Root.FindNode(TTransformNode,'PlaceR5',[fnNilOnMissing]) as TTransformNode;
      NL:=Root.FindNode(TTransformNode,'PlaceL5',[fnNilOnMissing]) as TTransformNode;
      if(NR<>nil)and(NL<>nil)then Data.BarClamp:=(NR.Translation+NL.Translation)*0.5
      else Data.BarClamp:=Data.ForkStock+Vector3(0.1,0.014,0);
    end;
    Data.BarClamp.Y:=Data.BarClamp.Y-0.014;

    n := 1;
    while n <= 32 do
    begin
      NR := Root.FindNode(TTransformNode, 'PlaceR' + IntToStr(n), [fnNilOnMissing]) as TTransformNode;
      NL := Root.FindNode(TTransformNode, 'PlaceL' + IntToStr(n), [fnNilOnMissing]) as TTransformNode;
      if (NR = nil) or (NL = nil) then Break;   { stop at the first missing pair }
      SetLength(Data.PRs, n); SetLength(Data.PLs, n);
      Data.PRs[n - 1] := NR.Translation;
      Data.PLs[n - 1] := NL.Translation;
      Inc(n);
    end;
  finally
    Root.Free;
  end;
end;

{ Вернуть распарсенные данные glb — из кэша, либо распарсив и закэшировав.
  False = модель не резолвится / не грузится (как и раньше, без кэша). }
function GetDropBarModelData(const APath, ASteererBone: string;
  out Data: TDropBarModelData): Boolean;
var URL: string; MT: Int64;
begin
  Result := False;
  URL := ResolveModelURL(APath);
  if URL = '' then Exit;
  MT := DropBarFileMTime(URL);
  if MT < 0 then Exit;
  DropBarModelCacheLock.Enter;
  try
    if (DropBarModelCache.URL = URL) and (DropBarModelCache.MTime = MT)
       and (DropBarModelCache.SteererBone = ASteererBone) then
    begin
      Data := DropBarModelCache;
      Result := True;
      Exit;
    end;
    DropBarModelCache.URL := URL;
    DropBarModelCache.MTime := MT;
    DropBarModelCache.SteererBone := ASteererBone;
    ParseDropBarModelData(DropBarModelCache);
    if not DropBarModelCache.Loaded then
    begin
      DropBarModelCache.URL := '';   { не кэшируем неудачу — retry на след. раз }
      Exit;
    end;
    Data := DropBarModelCache;
    Result := True;
  finally
    DropBarModelCacheLock.Leave;
  end;
end;

{ PackRGB, RotateXYZ and ResolveModelURL now live in the shared BikeGfxUtil unit. }

type
  { Fit only the integrated stem. The steerer stays fixed and the complete
    bar/shifters translate rigidly, preserving their dimensions. This is a
    one-time build operation on an instance copy, never the cached model. }
  TModelStemFit=class
    ModelMatrix, InverseModelMatrix:TMatrix4;
    Origin, Delta:TVector3;
    StemX:Single;
    Seen:TList;
    function Visit(Node:TX3DNode;Stack:TX3DGraphTraverseStateStack;
      ParentInfo:PTraversingInfo;var IntoChildren:Boolean):Pointer;
  end;

function TModelStemFit.Visit(Node:TX3DNode;Stack:TX3DGraphTraverseStateStack;
  ParentInfo:PTraversingInfo;var IntoChildren:Boolean):Pointer;
var G:TAbstractGeometryNode;C:TMFVec3f;Normals:TVector3List;
  M,Inv,NM,BackNM:TMatrix4;I:Integer;P,N,Gradient:TVector3;
  X,Z,DX,DZ,T,Span:Single;
begin
  Result:=nil;G:=TAbstractGeometryNode(Node);
  if not G.InternalCoord(Stack.Top,C)or(C=nil)or(Seen.IndexOf(C)>=0)then Exit;
  Seen.Add(C);Normals:=G.InternalNormal;
  M:=ModelMatrix*Stack.Top.Transformation.Transform;
  Inv:=Stack.Top.Transformation.InverseTransform*InverseModelMatrix;
  NM:=Inv.Transpose;BackNM:=M.Transpose;
  Span:=Max(0.025,StemX-0.04);
  for I:=0 to C.Items.Count-1 do begin
    P:=M.MultPoint(C.Items[I])-Origin;
    X:=EnsureRange((P.X-0.02)/Span,0,1);
    Z:=EnsureRange((Abs(P.Z)-0.025)/0.035,0,1);
    DX:=0;if(X>0)and(X<1)then DX:=1/Span;
    DZ:=0;if(Z>0)and(Z<1)then DZ:=6*Z*(1-Z)/0.035*Sign(P.Z);
    Z:=Z*Z*(3-2*Z);
    T:=1-(1-X)*(1-Z);Gradient:=Vector3(DX*(1-Z),0,DZ*(1-X));
    if(Normals<>nil)and(Normals.Count=C.Items.Count)then begin
      N:=NM.MultDirection(Normals[I]);
      N:=N-Gradient*(TVector3.DotProduct(Delta,N)/
        Max(0.05,1+TVector3.DotProduct(Gradient,Delta)));
      Normals[I]:=BackNM.MultDirection(N).Normalize;
    end;
    C.Items[I]:=Inv.MultPoint(P+Origin+Delta*T);
  end;
end;

{ -- Generic swept-section mesh ------------------------------------------
  Sweeps a K-vertex cross-section along a planar (XY) spine. At each
  station the section sits in the plane perpendicular to the spine
  tangent: Hax = perpendicular-in-XY (height), Sax = world Z (width).
  CsU/CsV are unit section coords (height frac / width frac); HalfH/HalfW
  scale them per station so the section can taper along the length.
  Builds an IndexedFaceSet with side quads + two end caps. }
function MakeSweep(Ctx: TBikeBuildContext;
  const Spine: array of TVector3;
  const HalfH, HalfW: array of Single;
  const CsU, CsV: array of Single;
  const Color, Spec: TVector3; Shininess, CreaseAng: Single): TTransformNode;
var
  Coord: TCoordinateNode;
  IFS: TIndexedFaceSetNode;
  Shape: TShapeNode;
  N, K, I, J, IA, IB, IC, ID: Integer;
  T, Hax, Sax, V: TVector3;
  Len: Single;
begin
  N := High(Spine);          { last station index ; stations = N+1 }
  K := High(CsU) + 1;        { section vertex count }
  Coord := TCoordinateNode.Create;
  for I := 0 to N do begin
    if I = 0 then T := Spine[1] - Spine[0]
    else if I = N then T := Spine[N] - Spine[N-1]
    else T := Spine[I+1] - Spine[I-1];
    T.Z := 0; Len := T.Length;
    if Len < 1e-9 then T := Vector3(1, 0, 0) else T := T / Len;
    Hax := Vector3(-T.Y, T.X, 0);   { height axis (perp to tangent, in XY) }
    Sax := Vector3(0, 0, 1);        { width axis (lateral) }
    for J := 0 to K - 1 do begin
      V := Spine[I] + Hax * (CsU[J] * HalfH[I]) + Sax * (CsV[J] * HalfW[I]);
      Coord.FdPoint.Items.Add(V);
    end;
  end;

  IFS := TIndexedFaceSetNode.Create;
  IFS.Coord := Coord; IFS.Solid := false; IFS.CreaseAngle := CreaseAng;
  for I := 0 to N - 1 do
    for J := 0 to K - 1 do begin
      IA := I*K + J;
      IB := I*K + ((J + 1) mod K);
      IC := (I+1)*K + ((J + 1) mod K);
      ID := (I+1)*K + J;
      IFS.FdCoordIndex.Items.Add(IA);  IFS.FdCoordIndex.Items.Add(ID);
      IFS.FdCoordIndex.Items.Add(IC);  IFS.FdCoordIndex.Items.Add(IB);
      IFS.FdCoordIndex.Items.Add(-1);
    end;
  for J := 0 to K - 1 do IFS.FdCoordIndex.Items.Add(J);             { front cap }
  IFS.FdCoordIndex.Items.Add(-1);
  for J := K - 1 downto 0 do IFS.FdCoordIndex.Items.Add(N*K + J);   { back cap }
  IFS.FdCoordIndex.Items.Add(-1);

  if Ctx.AccumActive then
  begin
    { батч: swept-меш в аккумулятор (координаты уже object-space) }
    Ctx.EmitBatched(IFS, Coord, Color, Spec, Shininess, CreaseAng,
      TMatrix4.Identity);
    Exit(nil);
  end;

  Shape := TShapeNode.Create;
  Shape.Geometry := IFS; Shape.Appearance := Ctx.MakeMaterial(Color, Spec, Shininess);
  Result := TTransformNode.Create;   { identity: coords are already object-space }
  Result.AddChildren(Shape);
end;

{ Helper: rotate spec offset (mm) about HBase by tilt, scale by Sc, -> object pt }
function HoodPt(const HBase: TVector3; ca, sa, Sc, FwdMM, UpMM: Single): TVector3;
var rx, ry: Single;
begin
  rx := FwdMM * Sc; ry := UpMM * Sc;
  Result := Vector3(HBase.X + (rx*ca - ry*sa), HBase.Y + (rx*sa + ry*ca), HBase.Z);
end;

{ -- Body: wedge with rounded top, rounded-trapezoid section tapering to nose -- }
procedure SweepBody(Ctx: TBikeBuildContext; const HBase: TVector3;
  ca, sa, Sc: Single; const Col, Spec: TVector3);
const
  BX:  array[0..6] of Single = (0, 22, 42, 63, 82, 97, 102);    { fwd, mm }
  BCY: array[0..6] of Single = (-13, -12.5, -9, -2.5, 1.5, 0, -5.5); { section centre, mm }
  BHH: array[0..6] of Single = (13, 14.5, 17, 20.5, 20.5, 17, 10.5); { half-height, mm }
  BHW: array[0..6] of Single = (19.5, 19.5, 19, 18.5, 17.5, 16, 14.5); { half-width, mm }
  { rounded-trapezoid section: 6 verts (u=height, v=width); top wider than bottom }
  CU: array[0..5] of Single = ( 1.0,  1.0,  0.1, -1.0, -1.0,  0.1);
  CV: array[0..5] of Single = (-0.78, 0.78, 0.92, 0.6, -0.6, -0.92);
var Sp: array[0..6] of TVector3; HH, HW: array[0..6] of Single; I: Integer;
begin
  for I := 0 to 6 do begin
    Sp[I] := HoodPt(HBase, ca, sa, Sc, BX[I], BCY[I]);
    HH[I] := BHH[I] * Sc; HW[I] := BHW[I] * Sc;
  end;
  Ctx.Add(MakeSweep(Ctx, Sp, HH, HW, CU, CV, Col, Spec, 0.55, 0.9));
end;

{ -- Brake lever: thin hexagonal-section wedge, last segment turns back -- }
procedure SweepBrakeLever(Ctx: TBikeBuildContext; const HBase: TVector3;
  ca, sa, Sc: Single; const Col, Spec: TVector3);
const
  LX:  array[0..5] of Single = (100, 101, 98, 92, 84, 74);   { fwd, mm }
  LY:  array[0..5] of Single = (-5, -28, -52, -72, -86, -94);{ up, mm }
  LHH: array[0..5] of Single = (6.5, 6.25, 5.5, 5.0, 4.75, 4.5); { half-thickness 13->9 }
  LHW: array[0..5] of Single = (11, 10.5, 10, 9.5, 9, 8.5);      { half-width }
  HU: array[0..5] of Single = ( 1.0, 1.0, 0.0, -1.0, -1.0, 0.0); { hexagon }
  HV: array[0..5] of Single = (-0.5, 0.5, 1.0, 0.5, -0.5, -1.0);
var Sp: array[0..5] of TVector3; HH, HW: array[0..5] of Single; I: Integer;
begin
  for I := 0 to 5 do begin
    Sp[I] := HoodPt(HBase, ca, sa, Sc, LX[I], LY[I]);
    HH[I] := LHH[I] * Sc; HW[I] := LHW[I] * Sc;
  end;
  Ctx.Add(MakeSweep(Ctx, Sp, HH, HW, HU, HV, Col, Spec, 0.8, 0.7));
end;

{ -- Shift lever: 75% of brake lever, offset back 8 mm, thinner/narrower -- }
procedure SweepShiftLever(Ctx: TBikeBuildContext; const HBase: TVector3;
  ca, sa, Sc: Single; const Col, Spec: TVector3);
const
  SX:  array[0..5] of Single = (92, 92.75, 90.5, 86, 80, 72.5);
  SY:  array[0..5] of Single = (-5, -22.25, -40.25, -55.25, -65.75, -71.75);
  SHH: array[0..5] of Single = (4.0, 3.9, 3.6, 3.4, 3.2, 3.0);  { thickness ~8 }
  SHW: array[0..5] of Single = (8.5, 8.3, 8.0, 7.7, 7.3, 7.0);  { width ~17 }
  HU: array[0..5] of Single = ( 1.0, 1.0, 0.0, -1.0, -1.0, 0.0);
  HV: array[0..5] of Single = (-0.5, 0.5, 1.0, 0.5, -0.5, -1.0);
var Sp: array[0..5] of TVector3; HH, HW: array[0..5] of Single; I: Integer;
begin
  for I := 0 to 5 do begin
    Sp[I] := HoodPt(HBase, ca, sa, Sc, SX[I], SY[I]);
    HH[I] := SHH[I] * Sc; HW[I] := SHW[I] * Sc;
  end;
  Ctx.Add(MakeSweep(Ctx, Sp, HH, HW, HU, HV, Col, Spec, 0.8, 0.7));
end;

constructor TDropBarComponent.Create;
begin
  inherited Create;
  FBarWidth   := DEF_BAR_WIDTH;
  FBarDrop    := DEF_BAR_DROP;
  FBarReach   := DEF_BAR_REACH;
  FHoodLength := DEF_HOOD_LENGTH;
  FHoodAngle  := DEF_HOOD_ANGLE;
  FTapeColor  := -1;
  FUseModel     := True;
  FModelURL     := 'bike/dropbar.glb';
  FModelScale   := 1.0;
  FModelOffX    := 0;  FModelOffY := 0;  FModelOffZ := 0;
  FModelRotX    := 0;  FModelRotY := 0;  FModelRotZ := 0;
  FModelHasStem    := True;        { the supplied dropbar.glb includes the stem }
  FSteererBoneName := 'fork_stock'; { armature bone at the steerer centre (шток вилки) }
end;

destructor TDropBarComponent.Destroy;
begin
  inherited Destroy;
end;

class function TDropBarComponent.ComponentName: string; begin Result := 'DropBar'; end;

procedure TDropBarComponent.ApplyPreset(const APreset: string);
begin
  if SameText(APreset, 'gravel') then
    FBarWidth := 440;
end;

{ -- Drop-curve bend: horizontal tops, elliptical radius down, horizontal hook --
  Tops are horizontal (y=0) from the stem out to FXt (where the bend starts and
  the shifter mounts). The bend is the front half of an ellipse, tangent to
  horizontal at the top (heading +X) and at the bottom (heading -X). The hook
  end is horizontal (y=-Drop) pointing back toward the rider -- no upward flick. }
procedure TDropBarComponent.ComputeArc(M: Single);
var Rh, Dp: Single;
begin
  Rh := FBarReach * M;  Dp := FBarDrop * M;
  FXt   := Rh * 0.5;     { tops end / bend start / hood mount }
  FAell := Rh - FXt;     { ellipse horizontal semi-axis (forward bulge) }
  FBell := Dp * 0.5;     { ellipse vertical semi-axis }
  FHkX  := FXt - Dp * 0.35;  { hook end x }
  FHkY  := -Dp;              { hook end y = bend bottom (horizontal) }
end;

function TDropBarComponent.ArcOffset(U: Single): TVector3;
var Phi: Single;
begin
  Phi := Pi/2 - U * Pi;   { 90deg (top, +X) -> -90deg (bottom, -X) }
  Result := Vector3(FXt + FAell * Cos(Phi), -FBell + FBell * Sin(Phi), 0);
end;

procedure TDropBarComponent.ComputeBones(Skel: TBikeSkeleton);
var M, HW, BZ, HoodC, HoodS: Single;
    StemEnd, HB, Off: TVector3;
    StemBase, FS, PR, PL, OffMM, RFork, PlaceLocal: TVector3;
    HandsOK: Boolean;
    Signs: array[0..1] of Single;
    Names: array[0..1] of string; I: Integer;
    PRs, PLs: TBarPlaceArray; J, NP: Integer;Data:TDropBarModelData;
begin
  M := Skel.MM;

  if BarWidth   < 300 then BarWidth   := DEF_BAR_WIDTH;
  if BarDrop    < 50  then BarDrop    := DEF_BAR_DROP;
  if BarReach   < 30  then BarReach   := DEF_BAR_REACH;
  if HoodLength < 40  then HoodLength := DEF_HOOD_LENGTH;
  if HoodAngle  < 10  then HoodAngle  := DEF_HOOD_ANGLE;

  StemEnd := Skel['stem_end'];
  Signs[0] := -1; Signs[1] := 1; Names[0] := 'l'; Names[1] := 'r';
  HW := BarWidth * M / 2;
  ComputeArc(M);
  HoodC := HoodLength * M * Cos(DegToRad(HoodAngle));
  HoodS := HoodLength * M * Sin(DegToRad(HoodAngle));

  { hand grips from the glb (PlaceR1/PlaceL1), mapped through the same placement
    as the model geometry so the rider's hands land on the loaded bar }
  HandsOK := FUseModel and Skel.HasBone('stem_base')
             and ReadModelBones(FS, PR, PL);
  FModelStemShift:=TVector3.Zero;FModelStemReference:=TVector3.Zero;
  if HandsOK then begin
    StemBase := Skel['stem_base'];
    OffMM    := Vector3(FModelOffX * M, FModelOffY * M, FModelOffZ * M);
    RFork    := RotateXYZ(FS, FModelRotX, FModelRotY, FModelRotZ);
    if FModelHasStem and GetDropBarModelData(FModelURL,FSteererBoneName,Data)then
      FModelStemReference:=(RotateXYZ(Data.BarClamp,FModelRotX,FModelRotY,FModelRotZ)-RFork)*FModelScale;
    FModelStemShift:=StemEnd-StemBase-FModelStemReference;
    OffMM:=OffMM+FModelStemShift;
  end;

  Skel.AddBone('bar_left',  Vector3(StemEnd.X, StemEnd.Y, -HW));
  Skel.AddBone('bar_right', Vector3(StemEnd.X, StemEnd.Y,  HW));
  for I := 0 to 1 do begin
    BZ := Signs[I] * HW;
    { horizontal tops: ramp point sits on the y=0 line }
    Skel.AddBone('ramp_start_' + Names[I],
      Vector3(StemEnd.X + FXt * 0.45, StemEnd.Y, BZ));

    { shifter mounts at the bend start (arc u=0 = (FXt,0)) }
    Off := ArcOffset(0.0);
    HB := Vector3(StemEnd.X + Off.X, StemEnd.Y + Off.Y, BZ);
    if HandsOK then begin
      if Names[I] = 'r' then PlaceLocal := PR else PlaceLocal := PL;
      HB := StemBase + OffMM
            + (RotateXYZ(PlaceLocal, FModelRotX, FModelRotY, FModelRotZ) - RFork) * FModelScale;
    end;
    Skel.AddBone('hood_base_' + Names[I], HB);
    Skel.AddBone('hood_tip_'  + Names[I], Vector3(HB.X + HoodC, HB.Y + HoodS, BZ));

    Off := ArcOffset(0.10); Skel.AddBone('curve_top_'  + Names[I], Vector3(StemEnd.X + Off.X, StemEnd.Y + Off.Y, BZ));
    Off := ArcOffset(0.40); Skel.AddBone('curve_mid_'  + Names[I], Vector3(StemEnd.X + Off.X, StemEnd.Y + Off.Y, BZ));
    Off := ArcOffset(0.65); Skel.AddBone('drop_upper_' + Names[I], Vector3(StemEnd.X + Off.X, StemEnd.Y + Off.Y, BZ));
    Off := ArcOffset(0.85); Skel.AddBone('drop_lower_' + Names[I], Vector3(StemEnd.X + Off.X, StemEnd.Y + Off.Y, BZ));
    Off := ArcOffset(1.00); Skel.AddBone('hook_start_' + Names[I], Vector3(StemEnd.X + Off.X, StemEnd.Y + Off.Y, BZ));
    Skel.AddBone('hook_end_' + Names[I], Vector3(StemEnd.X + FHkX, StemEnd.Y + FHkY, BZ));
    if not HandsOK then begin
      Skel.AddBone('place_'+Names[I]+'_1',HB+Vector3(HoodC*0.25,HoodS*0.25,0));
      Skel.AddBone('place_'+Names[I]+'_2',Skel['ramp_start_'+Names[I]]+Vector3(0,0.014,0));
      Off:=ArcOffset(0.65);
      Skel.AddBone('place_'+Names[I]+'_3',Vector3(StemEnd.X+Off.X,StemEnd.Y+Off.Y,BZ+Signs[I]*0.014));
      Off:=ArcOffset(0.45);
      Skel.AddBone('place_'+Names[I]+'_4',Vector3(StemEnd.X+Off.X,StemEnd.Y+Off.Y,BZ+Signs[I]*0.014));
      Skel.AddBone('place_'+Names[I]+'_5',Vector3(StemEnd.X,StemEnd.Y+0.014,BZ*0.50));
      Skel.AddBone('place_'+Names[I]+'_6',Vector3(StemEnd.X,StemEnd.Y+0.014,BZ*0.31));
    end;
  end;

  { every hand-grip position from the glb (PlaceR1..N / PlaceL1..N) -> place_r_n /
    place_l_n, so a pose can say which grip each hand uses. place_*_1 coincides with
    hood_base_* (same PlaceR1/PlaceL1 and the same model placement). }
  if HandsOK then
  begin
    NP := ReadModelPlaces(PRs, PLs);
    if NP>=4 then begin
      PRs[2]:=PRs[3]+Vector3(-0.012,-0.018,0);
      PLs[2]:=PLs[3]+Vector3(-0.012,-0.018,0);
    end;
    { The authored Place6 points float in front of a bar with no extensions.
      Keep the selectable slot, but use a real narrow-top contact. }
    if NP>=6 then begin
      PRs[5]:=PRs[4];PLs[5]:=PLs[4];
      PRs[5].Z:=FS.Z+(PRs[4].Z-FS.Z)*0.62;
      PLs[5].Z:=FS.Z+(PLs[4].Z-FS.Z)*0.62;
    end;
    for J := 0 to NP - 1 do
    begin
      Skel.AddBone('place_r_' + IntToStr(J + 1),
        StemBase + OffMM + (RotateXYZ(PRs[J], FModelRotX, FModelRotY, FModelRotZ) - RFork) * FModelScale);
      Skel.AddBone('place_l_' + IntToStr(J + 1),
        StemBase + OffMM + (RotateXYZ(PLs[J], FModelRotX, FModelRotY, FModelRotZ) - RFork) * FModelScale);
    end;
  end;
end;

procedure TDropBarComponent.BuildHood(Ctx: TBikeBuildContext;
  const HBase: TVector3; HL: Single; DL: Integer);
var Sc, ca, sa: Single;
    BodyCol, BodySpec, LevCol, LevSpec: TVector3;
begin
  Sc := HL / DEF_HOOD_LENGTH;   { HL = HoodLength*M ; spec body length 102 units -> metres/unit }
  ca := Cos(DegToRad(HoodAngle - 45.0));
  sa := Sin(DegToRad(HoodAngle - 45.0));
  BodyCol := Ctx.Colors.Dark;           BodySpec := Vector3(0.22, 0.22, 0.27);
  LevCol  := Vector3(0.06, 0.06, 0.07); LevSpec  := Vector3(0.50, 0.50, 0.55);

  SweepBody(Ctx, HBase, ca, sa, Sc, BodyCol, BodySpec);
  SweepBrakeLever(Ctx, HBase, ca, sa, Sc, LevCol, LevSpec);
  if DL >= 1 then
    SweepShiftLever(Ctx, HBase, ca, sa, Sc, LevCol, LevSpec);
end;

type
  TXfNameLogger = class
    procedure OnNode(N: TX3DNode);
  end;

procedure TXfNameLogger.OnNode(N: TX3DNode);
begin
  if (N is TTransformNode) and (TTransformNode(N).X3DName <> '') then
    StartupLog('[DropBar]   bone/xf: ' + TTransformNode(N).X3DName);
end;

{ Log every named Transform/bone in a loaded model -- helps identify the
  steerer bone name to put in ModelSteererBone. }
procedure LogTransformNames(Root: TX3DRootNode; const Tag: string);
var L: TXfNameLogger;
begin
  L := TXfNameLogger.Create;
  try
    StartupLog('[DropBar] named transforms in ' + Tag + ':');
    Root.EnumerateNodes(TTransformNode, @L.OnNode, False);
  finally
    L.Free;
  end;
end;

function TDropBarComponent.TryLoadModel: TX3DRootNode;
var URL: string;
begin
  Result := LoadModelNode(FModelURL, '[DropBar] ', 'handlebar model', URL);
  if Result <> nil then
    LogTransformNames(Result, URL);
end;

{ Load the glb just to read bone positions (steerer + hand placers), then free
  it. Returns True only if both hand placers were found. Translations are the
  bones' LOCAL values -- correct for a flat armature (placers directly under the
  armature root); for a nested bone chain they are approximate. }
function TDropBarComponent.ReadModelPlaces(out PR, PL: TBarPlaceArray): Integer;
var Data: TDropBarModelData;
begin
  Result := 0; SetLength(PR, 0); SetLength(PL, 0);
  if not GetDropBarModelData(FModelURL, FSteererBoneName, Data) then Exit;
  PR := Copy(Data.PRs);
  PL := Copy(Data.PLs);
  Result := Length(PR);
end;

function TDropBarComponent.ReadModelBones(out AForkStock, APlaceR, APlaceL: TVector3): Boolean;
var Data: TDropBarModelData;
begin
  Result := False;
  AForkStock := TVector3.Zero; APlaceR := TVector3.Zero; APlaceL := TVector3.Zero;
  if not GetDropBarModelData(FModelURL, FSteererBoneName, Data) then Exit;
  AForkStock := Data.ForkStock;
  APlaceR := Data.PlaceR;
  APlaceL := Data.PlaceL;
  Result := Data.BonesOK;
end;

procedure TDropBarComponent.BuildSteererStem(Ctx: TBikeBuildContext;
  const StemE: TVector3; StemDia, M: Single);
var S: TBikeSkeleton;
begin
  S := Ctx.Skeleton;
  Ctx.Add(Ctx.MakeCylinder(Ctx.O(S['head_tube_top']), Ctx.O(S['stem_base']), 0.014, Ctx.Colors.Chrome, Ctx.Colors.ChromeSpec, 1.0));
  Ctx.Add(Ctx.MakeCylinder(Ctx.O(S['stem_base']), StemE, StemDia / 2 * M, Ctx.Colors.Chrome, Ctx.Colors.ChromeSpec, 1.0));
  Ctx.Add(Ctx.MakeBox(StemE, 0.014, 0.032, 0.035, Ctx.Colors.Dark, Vector3(0.3, 0.3, 0.35), 0.7));
end;

procedure TDropBarComponent.BuildGeometry(Ctx: TBikeBuildContext);
var S: TBikeSkeleton; M: Single; DL, NArc, I, Si: Integer;
    Side: string; SideSign, U1: Single;
    StemE, BarEnd, Ramp, HBase, sk_bar, Off, PA, PB: TVector3;
    HW, ClampHalf, BarR, TapeR, LocalStemDia: Single;
    Fk: TForkComponent;
    TapeCol, TapeSpec: TVector3;
    ModelRoot: TX3DRootNode;
    BoneNode: TTransformNode;
    BoneLocal: TVector3;
    TPos, RxNode, RyNode, RzNode: TTransformNode;
    Fit:TModelStemFit;
begin
  S := Ctx.Skeleton; M := S.MM; DL := Ctx.DetailLevel;
  BarR := 0.0105; TapeR := 0.012;
  StemE := Ctx.O(S['stem_end']);

  if FTapeColor < 0 then TapeCol := Ctx.Colors.Tape else TapeCol := PackRGB(FTapeColor);
  TapeSpec := Vector3(0.12, 0.12, 0.14);

  Fk := TForkComponent(FindComponent(TForkComponent));
  if Fk <> nil then LocalStemDia := Fk.StemDia else LocalStemDia := 24;

  { -- external handlebar model: load glb and add its nodes into the bike -- }
  if FUseModel then begin
    ModelRoot := TryLoadModel;
    if ModelRoot <> nil then begin
      if not FModelHasStem then
      begin
        Ctx.BeginAccum(Ctx.SteerRoot);
        BuildSteererStem(Ctx, StemE, LocalStemDia, M);
        Ctx.EndAccum;
      end;
      { locate the steerer bone (if named) so we can align it to the bike }
      BoneLocal := TVector3.Zero;
      if FSteererBoneName <> '' then begin
        BoneNode := ModelRoot.FindNode(TTransformNode, FSteererBoneName,
                      [fnNilOnMissing]) as TTransformNode;
        if BoneNode <> nil then BoneLocal := BoneNode.Translation
        else StartupLog('[DropBar] steerer bone not found: ' + FSteererBoneName);
      end;
      if FModelHasStem and(FModelStemReference.X>0.04)and(FModelScale>0)then begin
        Fit:=TModelStemFit.Create;Fit.Seen:=TList.Create;
        try
          Fit.ModelMatrix:=RotationMatrixRad(DegToRad(FModelRotZ),0,0,1)*
            RotationMatrixRad(DegToRad(FModelRotY),0,1,0)*
            RotationMatrixRad(DegToRad(FModelRotX),1,0,0)*
            ScalingMatrix(Vector3(FModelScale,FModelScale,FModelScale));
          Fit.InverseModelMatrix:=ScalingMatrix(Vector3(1/FModelScale,1/FModelScale,1/FModelScale))*
            RotationMatrixRad(-DegToRad(FModelRotX),1,0,0)*
            RotationMatrixRad(-DegToRad(FModelRotY),0,1,0)*RotationMatrixRad(-DegToRad(FModelRotZ),0,0,1);
          Fit.Origin:=RotateXYZ(BoneLocal,FModelRotX,FModelRotY,FModelRotZ)*FModelScale;
          Fit.StemX:=FModelStemReference.X;Fit.Delta:=FModelStemShift;
          ModelRoot.Traverse(TAbstractGeometryNode,@Fit.Visit);
        finally Fit.Seen.Free;Fit.Free end;
      end;
      { orient (X then Y then Z) via nested transforms }
      RxNode := TTransformNode.Create; RxNode.Rotation := Vector4(1, 0, 0, DegToRad(FModelRotX));
      RyNode := TTransformNode.Create; RyNode.Rotation := Vector4(0, 1, 0, DegToRad(FModelRotY));
      RzNode := TTransformNode.Create; RzNode.Rotation := Vector4(0, 0, 1, DegToRad(FModelRotZ));
      RxNode.AddChildren(ModelRoot); RyNode.AddChildren(RxNode); RzNode.AddChildren(RyNode);
      { anchor: put the steerer bone (or, if unnamed, the model origin) onto the
        bike's steerer at stem_base; uniform scale; mm fine-offset }
      TPos := TTransformNode.Create;
      TPos.Scale := Vector3(FModelScale, FModelScale, FModelScale);
      TPos.Translation := Ctx.O(S['stem_base'])
        + Vector3(FModelOffX * M, FModelOffY * M, FModelOffZ * M)
        - RotateXYZ(BoneLocal, FModelRotX, FModelRotY, FModelRotZ) * FModelScale;
      if not FModelHasStem then TPos.Translation:=TPos.Translation+FModelStemShift;
      TPos.AddChildren(RzNode);
      Ctx.AddSteered(TPos);
      Exit;   { glb geometry used; skip the parametric bar }
    end;
    { load failed -> fall through to parametric bar }
  end;

  { батч: вся параметрическая часть руля (стем/топ/дуга/хуки/обмотка) —
    несколько мешей по материалам вместо ~100 Shape-нод на Ultra.
    Parent = SteerRoot when steer enabled. }
  Ctx.BeginAccum(Ctx.SteerRoot);

  BuildSteererStem(Ctx, StemE, LocalStemDia, M);

  { centre cross-bar: bare (black) clamp section + wrapped tops either side }
  HW := BarWidth * M / 2;
  ClampHalf := Min(0.045, HW * 0.6);
  sk_bar := S['bar_left'];
  Ctx.Add(Ctx.MakeCylinder(
    Ctx.O(Vector3(sk_bar.X, sk_bar.Y, -ClampHalf)),
    Ctx.O(Vector3(sk_bar.X, sk_bar.Y,  ClampHalf)),
    BarR, BARE_BAR_COL, BARE_BAR_SPEC, 0.4));
  Ctx.Add(Ctx.MakeCylinder(Ctx.O(S['bar_left']),
    Ctx.O(Vector3(sk_bar.X, sk_bar.Y, -ClampHalf)), TapeR, TapeCol, TapeSpec, 0.35));
  Ctx.Add(Ctx.MakeCylinder(Ctx.O(Vector3(sk_bar.X, sk_bar.Y, ClampHalf)),
    Ctx.O(S['bar_right']), TapeR, TapeCol, TapeSpec, 0.35));

  case DL of
    0: NArc := 5;
    1: NArc := 9;
    2: NArc := 16;
  else NArc := 24;
  end;
  ComputeArc(M);

  for Si := 0 to 1 do begin
    if Si = 0 then begin Side := 'l'; SideSign := -1.0; BarEnd := Ctx.O(S['bar_left']);  end
              else begin Side := 'r'; SideSign :=  1.0; BarEnd := Ctx.O(S['bar_right']); end;

    Ramp  := Ctx.O(S['ramp_start_' + Side]);
    HBase := Ctx.O(S['hood_base_'  + Side]);

    { horizontal tops: bar end -> ramp -> hood base }
    Ctx.Add(Ctx.MakeCylinder(BarEnd, Ramp,  TapeR, TapeCol, TapeSpec, 0.35));
    Ctx.Add(Ctx.MakeCylinder(Ramp,   HBase, TapeR, TapeCol, TapeSpec, 0.35));
    if DL >= 2 then
      Ctx.Add(Ctx.MakeSphere(BarEnd, TapeR, TapeCol, TapeSpec, 0.35));

    { STI shifter (body + levers) }
    BuildHood(Ctx, HBase, HoodLength * M, DL);

    { bend: front half-ellipse, hood_base (u=0) -> drops bottom (u=1) }
    Off := ArcOffset(0.0);
    PB := Ctx.O(Vector3(S['stem_end'].X + Off.X, S['stem_end'].Y + Off.Y, SideSign * HW));
    if DL >= 2 then
      Ctx.Add(Ctx.MakeSphere(PB, TapeR, TapeCol, TapeSpec, 0.35));
    for I := 1 to NArc do begin
      U1 := I / NArc;
      PA := PB;
      Off := ArcOffset(U1);
      PB := Ctx.O(Vector3(S['stem_end'].X + Off.X, S['stem_end'].Y + Off.Y, SideSign * HW));
      Ctx.Add(Ctx.MakeCylinder(PA, PB, TapeR, TapeCol, TapeSpec, 0.35));
      if DL >= 2 then
        Ctx.Add(Ctx.MakeSphere(PB, TapeR, TapeCol, TapeSpec, 0.35));
    end;

    { horizontal hook end (parallel to ground, no flick) }
    PA := PB;
    PB := Ctx.O(Vector3(S['stem_end'].X + FHkX, S['stem_end'].Y + FHkY, SideSign * HW));
    Ctx.Add(Ctx.MakeCylinder(PA, PB, TapeR, TapeCol, TapeSpec, 0.35));

    Ctx.Add(Ctx.MakeSphere(PB, 0.013, BARE_BAR_COL, Vector3(0.18, 0.18, 0.2), 0.4));
  end;
  Ctx.EndAccum;
end;

initialization
  DropBarModelCacheLock := TCriticalSection.Create;

finalization
  FreeAndNil(DropBarModelCacheLock);

end.

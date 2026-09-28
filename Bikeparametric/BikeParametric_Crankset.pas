unit BikeParametric_Crankset;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, CastleUtils, CastleVectors, CastleURIUtils,
  X3DNodes,
  BikeParametric;

const
  { Half the distance between the outer pedal mounting faces, not BB shell width. }
  ROAD_QFACTOR_HALF = 74; { FC-R9200: 148 mm }
  MTB_QFACTOR_HALF = 86;  { FC-M8100: 172 mm }
  DEFAULT_PEDAL_CENTER_OFFSET = 52; { mm from crank mounting face to cleat centre }

type
  TCranksetComponent = class(TBikeComponent)
  private
    FCrankLength:       Single;
    FChainringRadius:   Single;
    FChainringTeeth:    Integer;
    FQFactorHalf:       Single;
    FPedalCenterOffset: Single;
    FCrankTexturePathR: string;
    FCrankTexturePathL: string;
    FUseModels: Boolean;
    FModelPathR, FModelPathL: string;
  public
    constructor Create; override;
    class function ComponentName: string; override;
    procedure ApplyPreset(const APreset: string); override;
    procedure ComputeBones(Skel: TBikeSkeleton); override;
    procedure BuildGeometry(Ctx: TBikeBuildContext); override;
    function ChainringPitchRadius: Single; { mm, matches the displayed asset }
    function ChainringPlaneOffset: Single; { mm inward from the crank outer face }
    function PedalStanceHalf: Single; { mm from bicycle centre to cleat centre }
  published
    property UseModels: Boolean read FUseModels write FUseModels;
    property ModelPathR: string read FModelPathR write FModelPathR;
    property ModelPathL: string read FModelPathL write FModelPathL;
    property CrankLength:       Single  read FCrankLength       write FCrankLength;
    property ChainringRadius:   Single  read FChainringRadius   write FChainringRadius;
    property ChainringTeeth:    Integer read FChainringTeeth    write FChainringTeeth;
    property QFactorHalf:       Single  read FQFactorHalf       write FQFactorHalf;
    property PedalCenterOffset: Single read FPedalCenterOffset write FPedalCenterOffset;
    property CrankTexturePathR: string  read FCrankTexturePathR write FCrankTexturePathR;
    property CrankTexturePathL: string  read FCrankTexturePathL write FCrankTexturePathL;
  end;

implementation

uses
  DebugLog, BikeGfxUtil;

const
  { Road defaults — единый источник для Create и fallback'ов ComputeBones. }
  DEF_CRANK_LENGTH     = 172.5;   { mm }
  DEF_CHAINRING_RADIUS = 100;     { mm }
  DEF_CHAINRING_TEETH  = 50;
  MODEL_REFERENCE_CRANK = 172.5;
  MODEL_CHAINRING_PITCH = 100.422792;
  MODEL_CHAINRING_OFFSET = -11.354839;
  { pedal body plastic (spec + shininess), repeated per part }
  PEDAL_BODY_SPEC: TVector3 = (X: 0.25; Y: 0.25; Z: 0.3);
  PEDAL_BODY_SHININESS = 0.6;
  { Photographed black finish: retain scene lighting without overexposing
    the highlights already present in the image. }
  CRANK_PHOTO_DIFFUSE: TVector3 = (X: 0.6; Y: 0.6; Z: 0.6);

constructor TCranksetComponent.Create;
begin
  inherited Create;
  FCrankLength       := DEF_CRANK_LENGTH;
  FChainringRadius   := DEF_CHAINRING_RADIUS;
  FChainringTeeth    := DEF_CHAINRING_TEETH;
  FQFactorHalf       := ROAD_QFACTOR_HALF;
  FPedalCenterOffset := DEFAULT_PEDAL_CENTER_OFFSET;
  FCrankTexturePathR := 'Crank-Shimano-FC-R9200-R.png';
  FCrankTexturePathL := 'Crank-Shimano-FC-R9200-L.png';
  FUseModels := True;
  FModelPathR := 'bike/cranks/crank_r.glb';
  FModelPathL := 'bike/cranks/crank_l.glb';
end;

class function TCranksetComponent.ComponentName: string; begin Result := 'Crankset'; end;

procedure TCranksetComponent.ApplyPreset(const APreset: string);
begin
  if SameText(APreset, 'mtb') then begin
    FCrankLength      := 170;
    FChainringRadius  := 65;
    FChainringTeeth   := 32;
    FQFactorHalf      := MTB_QFACTOR_HALF;
  end;
end;

{ ResolveTexURL now lives in the shared BikeGfxUtil unit (tag-parameterized). }

procedure TCranksetComponent.ComputeBones(Skel: TBikeSkeleton);
var M, BBX, BBY, CL, QZ: Single;
begin
  M := Skel.MM;

  if CrankLength < 100 then CrankLength := DEF_CRANK_LENGTH;
  if ChainringRadius < 20 then ChainringRadius := DEF_CHAINRING_RADIUS;
  if ChainringTeeth < 10 then ChainringTeeth := DEF_CHAINRING_TEETH;
  if IsNan(QFactorHalf) or IsInfinite(QFactorHalf) or (QFactorHalf < 20) then
    QFactorHalf := ROAD_QFACTOR_HALF;
  if IsNan(PedalCenterOffset) or IsInfinite(PedalCenterOffset) or (PedalCenterOffset < 20) then
    PedalCenterOffset := DEFAULT_PEDAL_CENTER_OFFSET;

  BBX := Skel['bb'].X; BBY := Skel['bb'].Y;
  CL := CrankLength*M; QZ := QFactorHalf*M;
  Skel.AddBone('crank_right', Vector3(BBX+Cos(-Pi/4)*CL, BBY+Sin(-Pi/4)*CL, QZ));
  Skel.AddBone('crank_left', Vector3(BBX+Cos(-Pi/4+Pi)*CL, BBY+Sin(-Pi/4+Pi)*CL, -QZ));
  Skel.AddBone('crank_spindle_r', Vector3(BBX, BBY, QZ));
  Skel.AddBone('crank_spindle_l', Vector3(BBX, BBY, -QZ));
end;

function TCranksetComponent.PedalStanceHalf: Single;
begin
  Result := QFactorHalf + PedalCenterOffset;
end;

function TCranksetComponent.ChainringPitchRadius: Single;
begin
  if UseModels and (ResolveModelURL(ModelPathR) <> '') then
    Result := CrankLength * MODEL_CHAINRING_PITCH / MODEL_REFERENCE_CRANK
  else if ResolveTexURL(CrankTexturePathR, '[Crankset] ') <> '' then
    Result := CrankLength * (103 / Sqrt(2*Sqr(126)))
  else Result := ChainringRadius;
end;

function TCranksetComponent.ChainringPlaneOffset: Single;
begin
  if UseModels and (ResolveModelURL(ModelPathR) <> '') then
    Result := CrankLength * MODEL_CHAINRING_OFFSET / MODEL_REFERENCE_CRANK
  else Result := 0;
end;

type
  TCrankModelPlacer = class
    Scale, Z: Single;
    Visited: TList;
    NamePrefix: string;
    procedure Bake(Node: TX3DNode);
  end;

procedure TCrankModelPlacer.Bake(Node: TX3DNode);
var Coord: TCoordinateNode; I: Integer; P: TVector3;
begin
  if Visited.IndexOf(Node) >= 0 then Exit;
  Visited.Add(Node);
  if Node.X3DName <> '' then
    Node.X3DName := NamePrefix + IntToStr(Visited.Count);
  if not (Node is TCoordinateNode) then Exit;
  Coord := TCoordinateNode(Node);
  for I := 0 to Coord.FdPoint.Items.Count - 1 do
  begin
    P := Coord.FdPoint.Items[I] * Scale;
    P.Z := P.Z + Z;
    Coord.FdPoint.Items[I] := P;
  end;
end;

function BuildCrankModel(Parent: TTransformNode; const Path: string;
  Scale, Z: Single): Boolean;
var ModelRoot: TX3DRootNode; URL: string; Placer: TCrankModelPlacer;
begin
  Result := False;
  ModelRoot := LoadModelNode(Path, '[Crankset] ', 'crank model', URL);
  if ModelRoot = nil then Exit;
  Placer := TCrankModelPlacer.Create;
  Placer.Visited := TList.Create;
  try
    { Assets are pre-normalized to BB=(0,0,0), a 172.5 mm crank and the rest
      angle of each side, with an identity node hierarchy. Bake placement into
      the copied vertices so CPU transforms and GPU object-space spin agree.
      The cached source mesh stays unchanged; no vertex edits during a frame. }
    Placer.Scale := Scale; Placer.Z := Z;
    if Z >= 0 then Placer.NamePrefix := 'CrankR_' else Placer.NamePrefix := 'CrankL_';
    ModelRoot.EnumerateNodes(@Placer.Bake, False);
    Parent.AddChildren(ModelRoot);
    ModelRoot := nil;
    Result := True;
  finally
    Placer.Visited.Free;
    Placer.Free;
    ModelRoot.Free;
  end;
end;

procedure TCranksetComponent.BuildGeometry(Ctx: TBikeBuildContext);

  procedure BuildPedal(RotGroup: TTransformNode; const CrankEnd: TVector3;
    const RotName, BodyName: string; ZSign: Single; DL: Integer);
  var PM, PCR, PB, PFoot: TTransformNode; PedalZ: Single;
  begin
    PM := TTransformNode.Create; PM.Translation := CrankEnd;
    PCR := TTransformNode.Create; PCR.X3DName := RotName;
    PB := TTransformNode.Create; PB.X3DName := BodyName;
    PedalZ := PedalCenterOffset * Ctx.Skeleton.MM * ZSign;
    { батч: листовая геометрия педали — 1-2 меша вместо 7 Shape-нод;
      цепочка PM/PCR/PFoot/PB и имена сохраняются (цели роутов/FootPitch) }
    { Only the spindle enters the crank: keep the platform outside its face. }
    Ctx.BeginAccum(PB);
    Ctx.AddTo(PB, Ctx.MakeCylinder(Vector3(0,0,-0.012*ZSign), Vector3(0,0,PedalZ+0.009*ZSign), 0.0035, Ctx.Colors.Chrome, Ctx.Colors.ChromeSpec, 1.0));
    Ctx.AddTo(PB, Ctx.MakeBox(Vector3(0,-0.007,PedalZ), 0.055, 0.006, 0.038, Ctx.Colors.Dark, PEDAL_BODY_SPEC, PEDAL_BODY_SHININESS));
    if DL >= 1 then begin
      Ctx.AddTo(PB, Ctx.MakeBox(Vector3(0,-0.003,PedalZ), 0.052, 0.002, 0.035, Vector3(0.15,0.15,0.17), Vector3(0.3,0.3,0.35), 0.5));
      Ctx.AddTo(PB, Ctx.MakeBox(Vector3(0,-0.007,PedalZ+0.020*ZSign), 0.055, 0.008, 0.002, Ctx.Colors.Dark, PEDAL_BODY_SPEC, PEDAL_BODY_SHININESS));
      Ctx.AddTo(PB, Ctx.MakeBox(Vector3(0,-0.007,PedalZ-0.020*ZSign), 0.055, 0.008, 0.002, Ctx.Colors.Dark, PEDAL_BODY_SPEC, PEDAL_BODY_SHININESS));
    end;
    if DL >= 2 then begin
      Ctx.AddTo(PB, Ctx.MakeBox(Vector3(0.029,-0.007,PedalZ), 0.003, 0.006, 0.018, Vector3(0.85,0.65,0.05), Vector3(0.95,0.80,0.20), 0.7));
      Ctx.AddTo(PB, Ctx.MakeBox(Vector3(-0.029,-0.007,PedalZ), 0.003, 0.006, 0.018, Vector3(0.80,0.10,0.05), Vector3(0.95,0.30,0.20), 0.7));
    end;
    Ctx.EndAccum;
    { PFoot carries the rider's ankling pitch ON TOP of the route-driven level-
      keeping (PCR). With a Tripo rider, UpdateTripoRider sends FootPitch into this
      node each frame so the pedal platform follows the foot sole; with no rider it
      stays identity and the route keeps the pedal level. }
    PFoot := TTransformNode.Create;
    PFoot.X3DName := Copy(RotName, 1, Length(RotName) - 3) + 'Foot';   { 'PedalRightRot'->'PedalRightFoot' }
    PFoot.AddChildren(PB);
    PCR.AddChildren(PFoot); PM.AddChildren(PCR); RotGroup.AddChildren(PM);
  end;

  { Textured quad for crank arm (+ chainring on right side).
    TexW x TexH image, BB axis at pixel (AxisPX, AxisPY),
    pedal axle at pixel (PedalPX, PedalPY).
    Quad placed in XY plane at given Z inside RotGroup.
    XfM — запечённая матрица родительского трансформа (для батча;
    вне BeginAccum игнорируется). }
  function BuildCrankTexQuad(const TexPath: string;
    CrankLen, ZPos: Single;
    TexW, TexH, AxisPX, AxisPY, PedalPX, PedalPY: Integer;
    const XfM: TMatrix4): TTransformNode;
  var
    PixDist, Scl, MinX, MaxX, MinY, MaxY: Single;
    IFS: TIndexedFaceSetNode;
    Coord: TCoordinateNode;
    TC: TTextureCoordinateNode;
    ImgTex: TImageTextureNode;
    Mat: TMaterialNode;
    App: TAppearanceNode;
    Shape: TShapeNode;
  begin
    PixDist := Sqrt(Sqr(Single(PedalPX - AxisPX)) + Sqr(Single(PedalPY - AxisPY)));
    if PixDist < 1 then PixDist := 1;
    Scl := CrankLen / PixDist;

    { Image X -> 3D X,  Image Y (down) -> 3D -Y }
    MinX := -AxisPX * Scl;
    MaxX :=  (TexW - AxisPX) * Scl;
    MaxY :=  AxisPY * Scl;
    MinY := -(TexH - AxisPY) * Scl;

    Coord := TCoordinateNode.Create;
    Coord.FdPoint.Items.Add(Vector3(MinX, MinY, ZPos));  { 0 = BL }
    Coord.FdPoint.Items.Add(Vector3(MaxX, MinY, ZPos));  { 1 = BR }
    Coord.FdPoint.Items.Add(Vector3(MaxX, MaxY, ZPos));  { 2 = TR }
    Coord.FdPoint.Items.Add(Vector3(MinX, MaxY, ZPos));  { 3 = TL }

    TC := TTextureCoordinateNode.Create;
    TC.FdPoint.Items.Add(Vector2(0, 0));
    TC.FdPoint.Items.Add(Vector2(1, 0));
    TC.FdPoint.Items.Add(Vector2(1, 1));
    TC.FdPoint.Items.Add(Vector2(0, 1));

    IFS := TIndexedFaceSetNode.Create;
    IFS.Coord := Coord;
    IFS.TexCoord := TC;
    IFS.Solid := False;
    { одна сторона: Solid=False уже отключает backface culling, развёрнутая
      копия — мёртвый дубль геометрии }
    IFS.FdCoordIndex.Items.Add(0); IFS.FdCoordIndex.Items.Add(1);
    IFS.FdCoordIndex.Items.Add(2); IFS.FdCoordIndex.Items.Add(3);
    IFS.FdCoordIndex.Items.Add(-1);
    IFS.FdTexCoordIndex.Items.Add(0); IFS.FdTexCoordIndex.Items.Add(1);
    IFS.FdTexCoordIndex.Items.Add(2); IFS.FdTexCoordIndex.Items.Add(3);
    IFS.FdTexCoordIndex.Items.Add(-1);

    ImgTex := TImageTextureNode.Create;
    ImgTex.SetUrl([TexPath]);
    ImgTex.RepeatS := False;
    ImgTex.RepeatT := False;

    { Highlights are already in the photo. Additive white specular lighting
      washes the black crank faces grey, independently of the texture color. }
    if Ctx.AccumActive then
    begin
      { батч: текстурированный квад шатуна — в текстурный бакет (свой на
        каждую текстуру: R и L раздельно), XfM запечён в вершины }
      Ctx.EmitBatchedTex(IFS, Coord, TC, ImgTex,
        CRANK_PHOTO_DIFFUSE, Vector3(0, 0, 0), 0.0, 0.0, XfM);
      Exit(nil);
    end;

    Mat := TMaterialNode.Create;
    Mat.DiffuseColor := CRANK_PHOTO_DIFFUSE;
    Mat.SpecularColor := Vector3(0, 0, 0);
    Mat.Shininess := 0;

    App := TAppearanceNode.Create;
    App.Material := Mat;
    App.Texture := ImgTex;

    Shape := TShapeNode.Create;
    Shape.Geometry := IFS;
    Shape.Appearance := App;

    Result := TTransformNode.Create;
    Result.AddChildren(Shape);
  end;

var S: TBikeSkeleton; BB, RC, LC: TVector3;
    QZ, CL: Single; CrankGroup, RotGroup, LeftFlip: TTransformNode;
    DL: Integer;
    UseTexR, UseTexL, ModelR, ModelL: Boolean;
    TexURLR, TexURLL: string;
begin
  S := Ctx.Skeleton; DL := Ctx.DetailLevel;
  BB := Ctx.O(S['bb']); QZ := QFactorHalf*S.MM;
  CL := CrankLength * S.MM;
  CrankGroup := TTransformNode.Create; CrankGroup.Translation := BB;
  RotGroup := TTransformNode.Create; RotGroup.X3DName := 'CranksRot';

  { Join the crank hubs through the unchanged BB shell. The imported models
    contain arms and rings but no axle; wider spacing exposes that gap. }
  Ctx.BeginAccum(RotGroup);
  Ctx.AddTo(RotGroup, Ctx.MakeCylinder(Vector3(0,0,-QZ+0.004),
    Vector3(0,0,QZ-0.004), 0.012, Ctx.Colors.Dark, Ctx.Colors.ChromeSpec, 0.8));
  Ctx.EndAccum;

  ModelR := False; ModelL := False;
  if UseModels then
  begin
    ModelR := BuildCrankModel(RotGroup, ModelPathR, CrankLength/MODEL_REFERENCE_CRANK, QZ);
    ModelL := BuildCrankModel(RotGroup, ModelPathL, CrankLength/MODEL_REFERENCE_CRANK, -QZ);
  end;
  TexURLR := ResolveTexURL(CrankTexturePathR, '[Crankset] ');
  TexURLL := ResolveTexURL(CrankTexturePathL, '[Crankset] ');
  UseTexR := (not ModelR) and (TexURLR <> '');
  UseTexL := (not ModelL) and (TexURLL <> '');

  { ── Right side: chainring + crank arm ── }
  if UseTexR then
  begin
    Ctx.BeginAccum(RotGroup);
    Ctx.AddTo(RotGroup, BuildCrankTexQuad(TexURLR, CL, QZ,
      256, 256, 112, 112, 238, 238, TMatrix4.Identity));
    Ctx.EndAccum;
  end;
  RC := S['crank_right']-S['bb'];
  BuildPedal(RotGroup, RC, 'PedalRightRot', 'PedalRightBody', 1.0, DL);

  { ── Left side: crank arm only, rotated 180° from right ── }
  if UseTexL then
  begin
    { батч: flip запечён в вершины через XfM — LeftFlip остаётся пустым
      обёрточным трансформом (не именован, кодом не используется) }
    Ctx.BeginAccum(RotGroup);
    LeftFlip := TTransformNode.Create;
    LeftFlip.Rotation := Vector4(0, 0, 1, Pi);
    Ctx.AddTo(LeftFlip, BuildCrankTexQuad(TexURLL, CL, -QZ,
      256, 256, 42, 40, 230, 228, RotationMatrixRad(Pi, 0, 0, 1)));
    RotGroup.AddChildren(LeftFlip);
    Ctx.EndAccum;
  end;
  LC := S['crank_left']-S['bb'];
  BuildPedal(RotGroup, LC, 'PedalLeftRot', 'PedalLeftBody', -1.0, DL);

  CrankGroup.AddChildren(RotGroup); Ctx.Root.AddChildren(CrankGroup);
end;

end.

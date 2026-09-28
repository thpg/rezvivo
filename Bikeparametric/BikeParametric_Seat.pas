unit BikeParametric_Seat;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, CastleUtils, CastleVectors,
  X3DNodes, BikeParametric, BikeLog, BikeGfxUtil;

type
  TSeatComponent = class(TBikeComponent)
  private
    FSeatpostExtension: Single;
    FSaddleOffset:      Single;   { mm, + = вперёд вдоль +X рамы }
    FSaddleLength:      Single;
    FSaddleWidth:       Single;
    FSeatpostDia:       Single;
    { external saddle model (glb in data/), mounted on the seatpost }
    FUseModel:     Boolean;
    FModelURL:     string;
    FModelScale:   Single;
    FModelOffX, FModelOffY, FModelOffZ: Single;   { mm, fine offset from the rod anchor }
    FModelRotX, FModelRotY, FModelRotZ: Single;   { degrees, manual fine-tune }
    FModelHasPost: Boolean;                        { glb already contains the seatpost }
    FUseBoneAngle: Boolean;                        { align the rod to the seatpost via the bone's own angle }
    FRodBoneName:  string;                         { armature bone at the seatpost junction }
    FContactModelKey: string;
    FContactModelReady: Boolean;
    FModelRodPoint, FModelSeatPoint: TVector3;
    FModelRodAngle: Single;
    function TryLoadModel: TX3DRootNode;
    function ReadModelContact: Boolean;
    function ModelRotationZ(Skel: TBikeSkeleton; BoneAngZ: Single): Single;
  public
    constructor Create; override;
    class function ComponentName: string; override;
    procedure ApplyPreset(const APreset: string); override;
    procedure ComputeBones(Skel: TBikeSkeleton); override;
    procedure BuildGeometry(Ctx: TBikeBuildContext); override;
  published
    property SeatpostExtension: Single read FSeatpostExtension write FSeatpostExtension;
    property SaddleOffset:      Single read FSaddleOffset      write FSaddleOffset;
    property SaddleLength:      Single read FSaddleLength      write FSaddleLength;
    property SaddleWidth:       Single read FSaddleWidth       write FSaddleWidth;
    property SeatpostDia:       Single read FSeatpostDia       write FSeatpostDia;
    { External saddle model (glb under data/). When UseModel is true and the model
      loads, its RodBone (default 'seat_rod') is anchored onto the bike's seatpost
      top. With UseBoneAngle, the rod's sagittal tilt is matched to the bike's
      seatpost using the bone's OWN angle as the reference, then ModelRot* fine-tune
      the rest. Falls back to the parametric saddle if the model is absent. }
    property UseModel:     Boolean read FUseModel     write FUseModel;
    property ModelURL:     string  read FModelURL     write FModelURL;
    property ModelScale:   Single  read FModelScale   write FModelScale;
    property ModelOffsetX: Single  read FModelOffX    write FModelOffX;
    property ModelOffsetY: Single  read FModelOffY    write FModelOffY;
    property ModelOffsetZ: Single  read FModelOffZ    write FModelOffZ;
    property ModelRotX:    Single  read FModelRotX    write FModelRotX;
    property ModelRotY:    Single  read FModelRotY    write FModelRotY;
    property ModelRotZ:    Single  read FModelRotZ    write FModelRotZ;
    property ModelHasPost: Boolean read FModelHasPost write FModelHasPost;
    property UseBoneAngle: Boolean read FUseBoneAngle write FUseBoneAngle;
    property RodBone:      string  read FRodBoneName  write FRodBoneName;
  end;

implementation

uses CastleScene, CastleTransform, CastleBoxes;

const
  { Road defaults — единый источник для Create и fallback'ов ComputeBones. }
  DEF_SEATPOST_EXTENSION = 150;   { mm }
  DEF_SADDLE_LENGTH      = 270;   { mm }
  DEF_SADDLE_WIDTH       = 140;   { mm }
  DEF_SEATPOST_DIA       = 24;    { mm }
  { parametric saddle body material (spec + shininess), repeated per part }
  SADDLE_BODY_SPEC: TVector3 = (X: 0.2; Y: 0.2; Z: 0.22);
  SADDLE_BODY_SHININESS = 0.45;

{ ResolveModelURL and RotateXYZ now live in the shared BikeGfxUtil unit. }

{ rotation about Z (radians) contained in an X3D axis-angle = twist about Z }
function ZTwist(const AxisAngle: TVector4): Single;
var s, c: Single;
begin
  s := Sin(AxisAngle.W / 2);
  c := Cos(AxisAngle.W / 2);
  Result := 2 * ArcTan2(AxisAngle.Z * s, c);
end;

constructor TSeatComponent.Create;
begin
  inherited Create;
  FSeatpostExtension := DEF_SEATPOST_EXTENSION;
  FSaddleOffset      := 0;
  FSaddleLength      := DEF_SADDLE_LENGTH;
  FSaddleWidth       := DEF_SADDLE_WIDTH;
  FSeatpostDia       := DEF_SEATPOST_DIA;
  { saddle model defaults }
  FUseModel     := True;
  FModelURL     := 'bike/seat.glb';
  FModelScale   := 1.0;
  FModelOffX := 0; FModelOffY := 0; FModelOffZ := 0;
  FModelRotX := 0; FModelRotY := 0; FModelRotZ := 0;
  FModelHasPost := False;        { glb is the saddle; the bike draws the seatpost }
  FUseBoneAngle := True;         { match the rod to the seatpost via its own angle }
  FRodBoneName  := 'seat_rod';
end;

class function TSeatComponent.ComponentName: string; begin Result := 'Seat'; end;

procedure TSeatComponent.ApplyPreset(const APreset: string);
begin
  if SameText(APreset, 'mtb') then begin
    FSeatpostExtension := 120;
    FSaddleLength      := 260;
    FSeatpostDia       := 31.6;
  end;
end;

procedure TSeatComponent.ComputeBones(Skel: TBikeSkeleton);
var SA, SPLen: Single; STTop, Clamp, Contact: TVector3;
begin
  if SeatpostExtension < 10 then SeatpostExtension := DEF_SEATPOST_EXTENSION;
  if SeatpostDia < 10 then SeatpostDia := DEF_SEATPOST_DIA;
  if SaddleLength < 100 then SaddleLength := DEF_SADDLE_LENGTH;
  if SaddleWidth < 80 then SaddleWidth := DEF_SADDLE_WIDTH;

  SA := Skel.SeatAngleRad; SPLen := SeatpostExtension*Skel.MM;
  STTop := Skel['seat_tube_top'];
  Clamp := Vector3(STTop.X-Cos(SA)*SPLen, STTop.Y+Sin(SA)*SPLen, 0);
  Skel.AddBone('seatpost_clamp', Clamp);
  { Mounting point of the saddle rails, not the rider's sitting surface. }
  Skel.AddBone('seatpost_top', Vector3(Clamp.X + SaddleOffset*Skel.MM, Clamp.Y, Clamp.Z));
  Contact := Skel['seatpost_top'] + Vector3(0, 0.027, 0); { parametric top cushion }
  if FUseModel and ReadModelContact then
    Contact := Skel['seatpost_top']
      + Vector3(FModelOffX, FModelOffY, FModelOffZ) * Skel.MM
      + RotateXYZ(FModelSeatPoint - FModelRodPoint, FModelRotX, FModelRotY,
          ModelRotationZ(Skel, FModelRodAngle)) * FModelScale;
  Skel.AddBone('saddle_contact', Contact);
end;

function TSeatComponent.ModelRotationZ(Skel: TBikeSkeleton; BoneAngZ: Single): Single;
var Dir: TVector3;
begin
  Result := FModelRotZ;
  if FUseBoneAngle then begin
    { Sliding the saddle on its rails must not change the post angle. }
    Dir := Skel['seatpost_clamp'] - Skel['seat_tube_top'];
    Result := Result + RadToDeg(ArcTan2(-Dir.X, Dir.Y) - BoneAngZ);
  end;
end;

function TSeatComponent.ReadModelContact: Boolean;
var Root: TX3DRootNode; Node: TTransformNode; Scene: TCastleScene;
    Hit: TRayCollision; Box: TBox3D; Key: string; I: Integer;
    Width, Top: Single; Origin: TVector3; Found: Boolean;
begin
  Key := ResolveModelURL(FModelURL) + '|' + FRodBoneName;
  if FContactModelReady and (Key = FContactModelKey) then Exit(True);
  FContactModelReady := False;
  Result := False;
  Root := TryLoadModel;
  if Root = nil then Exit;
  try
    FModelRodPoint := TVector3.Zero; FModelRodAngle := 0;
    Node := nil;
    if FRodBoneName <> '' then
      Node := Root.FindNode(TTransformNode, FRodBoneName, [fnNilOnMissing]) as TTransformNode;
    if Node <> nil then begin
      FModelRodPoint := Node.Translation;
      FModelRodAngle := ZTwist(Node.Rotation);
    end;
    Node := Root.FindNode(TTransformNode, 'saddle_contact', [fnNilOnMissing]) as TTransformNode;
    if Node <> nil then
      FModelSeatPoint := Node.Translation
    else begin
      { Older saddle assets only contain seat_rod. Measure the cushion once in
        model space. The centre may be a relief hole: probe both supporting
        sides too, then use their top surface at the centre of the saddle.
        This scene never renders and is freed before the bike build continues. }
      Scene := TCastleScene.Create(nil);
      try
        Scene.PreciseCollisions := True;
        Scene.Load(Root, False);
        Box := Scene.BoundingBox;
        if Box.IsEmpty then Exit;
        Width := (Box.Data[1].Z - Box.Data[0].Z) * 0.2;
        Found := False; Top := -Infinity;
        for I := -1 to 1 do begin
          Origin := Vector3(FModelRodPoint.X, Box.Data[1].Y + 0.01,
            FModelRodPoint.Z + I * Width);
          Hit := Scene.InternalRayCollision(Origin, Vector3(0, -1, 0));
          try
            if (Hit <> nil) and (Hit.Count > 0) and (Hit.First.Triangle <> nil) then begin
              Top := Max(Top, Hit.First.Point.Y); Found := True;
            end;
          finally Hit.Free; end;
        end;
        if not Found then Exit;
        FModelSeatPoint := Vector3(FModelRodPoint.X, Top, FModelRodPoint.Z);
      finally Scene.Free; end;
    end;
    FContactModelKey := Key; FContactModelReady := True; Result := True;
  finally Root.Free; end;
end;

function TSeatComponent.TryLoadModel: TX3DRootNode;
var URL: string;
begin
  Result := LoadModelNode(FModelURL, '[Seat] ', 'saddle model', URL);
end;

procedure TSeatComponent.BuildGeometry(Ctx: TBikeBuildContext);
var S: TBikeSkeleton; M: Single; SP: TVector3;
    SL, SW, RailZ, RailFront, RailRear, RailClampF, RailClampR: Single;
    NoseW, RearW, MidOff: Single; DL: Integer;
    ModelRoot: TX3DRootNode;
    BoneNode: TTransformNode;
    BoneLocal: TVector3;
    BoneAngZ, TotRotZ: Single;
    RxNode, RyNode, RzNode, TPos: TTransformNode;
begin
  S := Ctx.Skeleton; M := S.MM; DL := Ctx.DetailLevel;

  { Seatpost — drawn unless the glb already includes it (сессия только когда
    цилиндр реально эмитится) }
  if not (FUseModel and FModelHasPost) then
  begin
    Ctx.BeginAccum(Ctx.Root);
    if S.HasBone('seatpost_clamp') then
      Ctx.Add(Ctx.MakeCylinder(Ctx.O(S['seat_tube_top']), Ctx.O(S['seatpost_clamp']),
        SeatpostDia/2*M, Ctx.Colors.Chrome, Ctx.Colors.ChromeSpec, 1.0))
    else
      Ctx.Add(Ctx.MakeCylinder(Ctx.O(S['seat_tube_top']), Ctx.O(S['seatpost_top']),
        SeatpostDia/2*M, Ctx.Colors.Chrome, Ctx.Colors.ChromeSpec, 1.0));
    Ctx.EndAccum;
  end;

  { -- external saddle model: anchor its seat_rod bone onto the seatpost top, and
       (UseBoneAngle) match the rod's sagittal tilt to the bike's seatpost using the
       bone's own angle as the reference -- }
  if FUseModel then begin
    ModelRoot := TryLoadModel;
    if ModelRoot <> nil then begin
      BoneLocal := TVector3.Zero; BoneAngZ := 0;
      if FRodBoneName <> '' then begin
        BoneNode := ModelRoot.FindNode(TTransformNode, FRodBoneName, [fnNilOnMissing]) as TTransformNode;
        if BoneNode <> nil then begin
          BoneLocal := BoneNode.Translation;
          if FUseBoneAngle then BoneAngZ := ZTwist(BoneNode.Rotation);  { bone's tilt about Z (rad) }
        end else
          StartupLog('[Seat] rod bone not found: ' + FRodBoneName);
      end;

      { auto Z so the rod's tilt = the bike's seatpost tilt; the bone's own angle is
        the reference, so a rod authored already-tilted is not double-counted. The
        seatpost direction makes angle atan2(-dx,dy) with vertical +Y. }
      TotRotZ := ModelRotationZ(S, BoneAngZ);

      { orient (X then Y then Z) via nested transforms }
      RxNode := TTransformNode.Create; RxNode.Rotation := Vector4(1, 0, 0, DegToRad(FModelRotX));
      RyNode := TTransformNode.Create; RyNode.Rotation := Vector4(0, 1, 0, DegToRad(FModelRotY));
      RzNode := TTransformNode.Create; RzNode.Rotation := Vector4(0, 0, 1, DegToRad(TotRotZ));
      RxNode.AddChildren(ModelRoot); RyNode.AddChildren(RxNode); RzNode.AddChildren(RyNode);

      { anchor: put the rod bone onto the bike's seatpost top; uniform scale; mm offset }
      TPos := TTransformNode.Create;
      TPos.Scale := Vector3(FModelScale, FModelScale, FModelScale);
      TPos.Translation := Ctx.O(S['seatpost_top'])
        + Vector3(FModelOffX * M, FModelOffY * M, FModelOffZ * M)
        - RotateXYZ(BoneLocal, FModelRotX, FModelRotY, TotRotZ) * FModelScale;
      TPos.AddChildren(RzNode);
      Ctx.Add(TPos);
      Exit;   { glb saddle used; skip the parametric saddle }
    end;
    { load failed -> fall through to the parametric saddle }
  end;

  { ---- parametric saddle (fallback / when UseModel is off) ----
    батч: вся параметрическая часть — 2-3 меша по материалам вместо
    ~15 Shape-нод (сюда попадаем только если внешней модели нет) }
  Ctx.BeginAccum(Ctx.Root);
  SP := Ctx.O(S['seatpost_top']); SL := SaddleLength*M; SW := SaddleWidth*M;
  RailZ := 0.022; RailFront := SL*0.42; RailRear := SL*0.38;
  RailClampF := 0.015; RailClampR := 0.015;
  NoseW := SW*0.20; RearW := SW*0.52; MidOff := SL*0.05;
  { Clamp — Med+ }
  if DL >= 1 then
    Ctx.Add(Ctx.MakeBox(SP+Vector3(0,0.005,0), 0.035, 0.014, 0.035, Ctx.Colors.Dark, Vector3(0.3,0.3,0.35), 0.7));
  { Rails — High+ }
  if DL >= 2 then begin
    Ctx.Add(Ctx.MakeCylinder(SP+Vector3(-RailClampR,0.003,RailZ), SP+Vector3(-RailRear,0.008,RailZ), 0.003, Ctx.Colors.Chrome, Ctx.Colors.ChromeSpec, 1.0));
    Ctx.Add(Ctx.MakeCylinder(SP+Vector3(-RailClampR,0.003,-RailZ), SP+Vector3(-RailRear,0.008,-RailZ), 0.003, Ctx.Colors.Chrome, Ctx.Colors.ChromeSpec, 1.0));
    Ctx.Add(Ctx.MakeCylinder(SP+Vector3(RailClampF,0.003,RailZ), SP+Vector3(RailFront,0.006,RailZ*0.4), 0.003, Ctx.Colors.Chrome, Ctx.Colors.ChromeSpec, 1.0));
    Ctx.Add(Ctx.MakeCylinder(SP+Vector3(RailClampF,0.003,-RailZ), SP+Vector3(RailFront,0.006,-RailZ*0.4), 0.003, Ctx.Colors.Chrome, Ctx.Colors.ChromeSpec, 1.0));
    Ctx.Add(Ctx.MakeCylinder(SP+Vector3(-RailClampR,0.003,RailZ), SP+Vector3(RailClampF,0.003,RailZ), 0.003, Ctx.Colors.Chrome, Ctx.Colors.ChromeSpec, 1.0));
    Ctx.Add(Ctx.MakeCylinder(SP+Vector3(-RailClampR,0.003,-RailZ), SP+Vector3(RailClampF,0.003,-RailZ), 0.003, Ctx.Colors.Chrome, Ctx.Colors.ChromeSpec, 1.0));
  end;
  { Base shell — Med+ }
  if DL >= 1 then
    Ctx.Add(Ctx.MakeBox(SP+Vector3(MidOff,0.010,0), SL*0.55, 0.004, SW*0.40, Ctx.Colors.Dark, Vector3(0.15,0.15,0.18), 0.4));
  { Main saddle body — always (simplified at Low to single box) }
  Ctx.Add(Ctx.MakeBox(SP+Vector3(-SL*0.12,0.016,0), SL*0.30, 0.014, RearW*2, Ctx.Colors.Seat, SADDLE_BODY_SPEC, SADDLE_BODY_SHININESS));
  if DL >= 1 then begin
    Ctx.Add(Ctx.MakeCylinder(SP+Vector3(-SL*0.27,0.016,-RearW), SP+Vector3(-SL*0.27,0.016,RearW), 0.007, Ctx.Colors.Seat, SADDLE_BODY_SPEC, SADDLE_BODY_SHININESS));
    Ctx.Add(Ctx.MakeBox(SP+Vector3(SL*0.10,0.015,0), SL*0.22, 0.013, SW*0.35, Ctx.Colors.Seat, SADDLE_BODY_SPEC, SADDLE_BODY_SHININESS));
    Ctx.Add(Ctx.MakeBox(SP+Vector3(SL*0.28,0.013,0), SL*0.18, 0.011, NoseW*2, Ctx.Colors.Seat, SADDLE_BODY_SPEC, SADDLE_BODY_SHININESS));
  end;
  if DL >= 2 then
    Ctx.Add(Ctx.MakeSphere(SP+Vector3(SL*0.38,0.012,0), 0.008, Ctx.Colors.Seat, SADDLE_BODY_SPEC, SADDLE_BODY_SHININESS));
  { Top cushion layers — High+ }
  if DL >= 2 then begin
    Ctx.Add(Ctx.MakeBox(SP+Vector3(-SL*0.10,0.024,0), SL*0.25, 0.006, RearW*1.85, Ctx.Colors.Seat, Vector3(0.25,0.25,0.27), 0.5));
    Ctx.Add(Ctx.MakeBox(SP+Vector3(SL*0.08,0.022,0), SL*0.18, 0.005, SW*0.30, Ctx.Colors.Seat, Vector3(0.25,0.25,0.27), 0.5));
  end;
  { Rear reflector mount — Ultra }
  if DL >= 3 then
    Ctx.Add(Ctx.MakeBox(SP+Vector3(-SL*0.30,0.012,0), 0.008, 0.012, 0.025, Ctx.Colors.Dark, Vector3(0.25,0.25,0.3), 0.6));
  Ctx.EndAccum;
end;

end.

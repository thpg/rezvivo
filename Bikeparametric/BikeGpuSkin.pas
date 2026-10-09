unit BikeGpuSkin;

{$mode objfpc}{$H+}

{ ── GPU-скин Tripo-райдера (GPU_ANIM_DESIGN.md, этап 2) ────────────────────

  TEffectNode с PLUG_vertex_object_space навешивается на шейпы Tripo-скина.
  Вершинный шейдер сам считает процедурную позу из uPhase:
    - педальный круг (те же формулы, что UpdateTripoRider на CPU);
    - анклинг — порт BicycleAnkleFlexCurve;
    - ноги — closed-form two-bone IK (порт SolveJoint/SolveTwoBone из
      TripoRig) с 4 фиксированными проходами уточнения контакта (клеят на
      педали), как CPU-SolveLimb, но без бисекции toe-down и без
      PinBlendedContact (см. ограничения ниже);
    - движение таза — scene-level трансформом вокруг контакта с седлом;
      спина — порт PoseSpine, кватернионы наклона/поворота/крена
      приходят как uSpineQ0..6;
    - руки — two-bone IK к resolved-хватам + пронация с фейдом у вертикали
      + wrist-leveling (uHandLevel) + shoulder-twist из асимметрии хватов
      (этап 3-хвост);
    - free-ноги: uLegFreeR/L блендят цель ноги педаль↔uLegFreePosR/L и
      гасят анклинг (этап 3-хвост); free-руки работают с этапа 2 — хваты
      резолвятся на CPU и приходят в uGripR/uGripL;
    - суставы вне процедурного набора (пальцы, дополнительные twist-кости)
      жёстко следуют ближайшему процедурному предку: их дельта-матрица
      равна дельте предка (D_j = D_anc — следует из rigid-follow).

  Скиннинг — LBS по 4 влияниям из castle_SkinJoints0/castle_SkinWeights0
  (атрибуты объявляет движковый skin-шейдер, который работает первым; его
  joint-матрицы тождественны, т.к. Rotation суставов больше не пишется,
  или содержат константный stretch S_j = W_bind*IBM при limb-scaling —
  в обоих случаях наш plug домножает вершину на D_j = W_proc * W_bind^-1,
  что в сумме даёт корректный M_j = W_proc * IBM).

  CPU на кадр: SendFrame — ~40 float (этап 3 переведёт позу на событийные
  пакеты uPoseA/uPoseB + GPU-лерп). Bind-статика запекается в GLSL
  константами при Build (эффект пересоздаётся при смене райдера).

  ОГРАНИЧЕНИЯ этапа 2+3 (GpuAnim=False по умолчанию не затронут):
    - нет toe-down свипа/бисекции (нога в пределах досягаемости — норма);
    - нет PinBlendedContact (клеят садится на педаль по жёсткой кости,
      не по блендированной поверхности);
    - нет hand-freeze: шейдер stateless, ориентация кисти на неподвижном
      хвате пересчитывается каждый кадр и может чуть дышать в такт бобу
      (на CPU FHandFreeze* держит её зафиксированной);
    - нет пакетов поз uPoseA/uPoseB (покадровая отправка ~50 float). }

  { Этап 5: капсульная тень райдера под GpuAnim. SendFrame попутно считает
    позиции 21 сустава ТОЙ ЖЕ математикой, что шейдер (closed-form IK ног/рук,
    FK спины и шеи из uSpineQ*), и отдаёт их в кадре
    байка через ShadowJoint — UpdateShadowDynamic строит капсулы без posed-рига. }

interface

uses
  RiderShaderSharing, Classes, SysUtils, Math,
  CastleUtils, CastleVectors, CastleScene, X3DNodes, X3DFields,
  TripoRig, RiderTripo, RiderHandGrip, RiderMotion;

type
  { ── этап 5: захваченные bind-константы для аналитической тени ── }
  TGpuShLeg = record
    Ok: Boolean;
    HP, AXM, AXE, CT: TTripoVec3;
    UR, MR, ER: TTripoVec4;
    L1, L2: Single;
  end;
  TGpuShArm = record
    Ok, ClavInSpine: Boolean;
    ParentSpine: Integer;
    CP, CO, AO, AXM, AXE, CT, HandForward, HandPalm: TTripoVec3;
    CR, PR, UR, MR, ER: TTripoVec4;
    L1, L2: Single;
  end;
  TGpuShSpine = record
    Ex, ParentInChain: Boolean;
    ParentSpine: Integer;
    PP, PO: TTripoVec3;
    PR: TTripoVec4;
  end;

const
  GPU_SHJ_COUNT = 21;   { суставов в капсульной тени райдера }

type
  TGpuRiderSkin = class
  private
    FRider: TTripoRiderScene;
    FEffect: TEffectNode;
    FReady: Boolean;
    { per-frame / per-pose uniforms: упакованы в 2 MF-массива + mat4 —
      3 Send'а на байк на кадр вместо 21 (каждый Send = X3D-event +
      glUseProgram + glUniform) }
    FUInvP: TSFMatrix4f;
    FUScalars: TMFFloat;   { 18: phase stanceZ dir kneeF elbowF ankleFlex pronR pronL shRound handLevel freeR freeL spine0..4 footYawW }
    FUVecs: TMFVec3f;      { 8: BB crankR crankL gripR gripL freePosR freePosL footYawXYZ }
    FURest: TMFMatrix4f;   { NJ: gskRest = BindWorld × NativeIBM; live after HeightK }
    FUBindT: TMFVec3f;     { NJ: BindWorld translations; live after HeightK }
    FUHandRest: TMFMatrix4f;
    FUHandForward: array[0..1] of TSFVec3f;
    FHandJointIndices: array of Integer;
    FScalarsList: TSingleList;
    FVecsList: TVector3List;
    FRestList: TMatrix4List;
    FBindTList: TVector3List;
    FRestCount: Integer;
    { какие суставы позвоночника реально есть в риге (для весов PoseSpine) }
    FSpineEx: array[0..RiderSpineChainCount-1] of Boolean;
    FSpineIdx: array[0..RiderSpineChainCount-1] of Integer;
    FDiagDumps: Integer;   { TEMP-DIAG: счётчик одноразовых дампов SendFrame }
    { ── этап 5: аналитические суставы капсульной тени ── }
    FShLegs: array[0..1] of TGpuShLeg;
    FShArms: array[0..1] of TGpuShArm;
    FShSpine: array[0..RiderSpineChainCount-1] of TGpuShSpine;
    FShLegHint, FShArmHint, FShLean, FShFlare: TTripoVec3;
    FShBind: array[0..GPU_SHJ_COUNT-1] of TTripoVec3;  { bind-позиции (rig frame) }
    FShEx: array[0..GPU_SHJ_COUNT-1] of Boolean;       { сустав есть в риге }
    FShHeadAnc: Integer;                               { spine-индекс головы или её ближайшего предка, -1 }
    FShPts: array[0..GPU_SHJ_COUNT-1] of TVector3;     { кадр байка, за SendFrame }
    FShValid: Boolean;
    FShNameIdx: TStringList;                           { кэш имя→индекс для ShadowJoint (SHJ_NAMES фиксирована) }
    { этап 5 (ленивый): тяжёлый IK конечностей + перенос в кадр байка считаются
      не в SendFrame, а по первому ShadowJoint кадра (тень нужна не всегда).
      Спина/голова считаются каждый SendFrame — от них зависит шлем
      (ApplyHelmetSkinMatrix), который обязан следовать за головой всегда. }
    FShRigPts: array[0..GPU_SHJ_COUNT-1] of TTripoVec3; { rig frame: спина — каждый SendFrame, конечности — по запросу }
    FShRS: array[0..RiderSpineChainCount-1] of TTripoVec4;                  { FK спины текущего кадра (ротации) }
    FShPS: array[0..RiderSpineChainCount-1] of TTripoVec3;                  { FK спины текущего кадра (позиции) }
    FShDelta: array[0..RiderSpineChainCount-1] of TTripoVec4;               { локальные дельты; uScalars получает готовые FShRS }
    FShClavicleDelta: array[0..1] of TTripoVec4;
    FShContacts: array[0..3] of TVector3;
    FShHandQ,FShGripTarget:array[0..1] of TTripoVec4;
    FShHandTwist:array[0..1] of Single;
    FShDirty: Boolean;                                 { конечности/перенос устарели — пересчитать в ShadowJoint }
    FShInPhase, FShInStanceZ, FShInPedalDir: Single;   { входы SendFrame для ленивого пересчёта }
    FShInInvP: TMatrix4;
    FShInOBB, FShInCrankR, FShInCrankL: TVector3;
    FShInGripR, FShInGripL, FShInFreeR, FShInFreeL: TVector3;
    FShInPose: TRiderPose;
    FShInFootYaw: TTripoVec4;                          { right-foot yaw; conjugate for left }
    { кэш последних отправленных uniform'ов — Send только при изменении;
      первый кадр после Build/включения эффекта шлёт всё }
    FLastScalars: array[0..52] of Single;
    FLastVecs: array[0..7] of TVector3;
    FLastInvP: TMatrix4;
    FLastValid: Boolean;
    procedure UploadBindUniforms;  { fill uGskRest / uBindT + FSh* from current Rig }
    { FK спины + голова + шлем (по FShDelta); зовётся каждый SendFrame }
    procedure UpdateShadowSpine;
    { IK конечностей + перенос rig->байк (по FShIn*/FShRS/FShPS); зовётся
      лениво из ShadowJoint при FShDirty }
    procedure UpdateShadowLimbs;
  public
    constructor Create(ARider: TTripoRiderScene);
    { Сгенерировать GLSL из рига, создать эффект и навесить на шейпы скина. }
    function Build(ALog: TStrings): Boolean;
    { After ApplyLimbLengths / HeightK: upload new bind translations + rest
      stretch. Does NOT recompile the shader (that froze the UI on height). }
    function RefreshBind: Boolean;
    { Покадровая отправка: фаза, обратный трансформ сцены райдера
      (bike->rig), посадочные параметры байка (O-центрированные), хваты
      (bike-фрейм, resolved), free-позиции ног (O-центрированные) и поза. }
    procedure SendFrame(const Phase: Single; const InvP: TMatrix4;
      const OBB, CrankR, CrankL: TVector3; StanceZ, PedalDir: Single;
      const GripR, GripL: TVector3; const FreePosR, FreePosL: TVector3;
      const Pose: TRiderPose);
    { Вкл/выкл эффект на шейпах (GpuAnim=False → старый CPU-путь: эффект
      обязан быть выключен, иначе дельта-домножение поверх живого скиннинга
      исказит райдера). Юниформы сохраняются, при включении досылаются. }
    procedure SetActive(AOn: Boolean);
    { Снять PLUG с appearance'ов. Нужно перед повторным Build после
      ApplyBodyShape/ApplyLimbLengths: иначе inverse(skinMatrix) копится
      и меш взрывается. }
    procedure Detach;
    destructor Destroy; override;
    property Ready: Boolean read FReady;
    function Active: Boolean;
    { TEMP-DIAG: проставлена ли Scene у эффекта (корень «uniform не доходит») }
    function EffectSceneAssigned: Boolean;
    { Этап 5: позиция сустава в кадре байка для капсульной тени. False —
      сустава нет в риге или SendFrame ещё не считал позиции. }
    function ShadowContact(Index: Integer; out P: TVector3): Boolean;
    function ShadowJoint(const AName: string; out P: TVector3): Boolean;
    function SpineSkin(const Name:string;out M:TMatrix4):Boolean;
    function ShadowHandFrame(Side:Integer;out Forward,Palm:TVector3;out Twist:Single):Boolean;
  end;

implementation

uses RiderRuntimeAudit,
  BikeLog,       { StartupLog — итог Build и путь к дампу GLSL }
  BikeGfxUtil;   { GNum — GLSL-литералы }

const
  { этап 5: суставы, нужные капсульной тени (SHADOW_RIDER_BONES в
    BikeParametric); порядок = индексы FSh* }
  SHJ_NAMES: array[0..GPU_SHJ_COUNT-1] of string = (
    'Pelvis', 'Waist', 'Spine', 'Spine01', 'Spine02', 'NeckTwist01', 'Head',
    'R_Thigh', 'L_Thigh', 'R_Clavicle', 'L_Clavicle',
    'R_Upperarm', 'L_Upperarm', 'R_Calf', 'L_Calf',
    'R_Foot', 'L_Foot', 'R_Forearm', 'L_Forearm', 'R_Hand', 'L_Hand');
  SHJ_WAIST   = 1;   { первый сустав цепи спины (Waist..NeckTwist01 = 1..5) }
  SHJ_HEAD    = 6;
  SHJ_THIGH_R = 7;   { +Side }
  SHJ_CLAV_R  = 9;
  SHJ_UPARM_R = 11;
  SHJ_CALF_R  = 13;
  SHJ_FOOT_R  = 15;
  SHJ_FORE_R  = 17;
  SHJ_HAND_R  = 19;

{ ── этап 5: порты GLSL-хелперов (зеркалят gskSolveJoint / gskAnkleCurve) ── }

function ShSolveJoint(const Root, Target: TTripoVec3; L1, L2: Single;
  const Hint: TTripoVec3; SoftReach: Single = 0): TTripoVec3;
var
  Rt, Dir, Perp: TTripoVec3;
  D, A, H, Over: Single;
begin
  Rt := V3Sub(Target, Root);
  D := V3Len(Rt);
  if D < 1e-6 then Exit(V3Add(Root, V3(0, L1, 0)));
  Dir := V3Scale(Rt, 1 / D);
  if (SoftReach > 0) and (D > L1 + L2 - SoftReach) then
  begin
    Over := D - (L1 + L2 - SoftReach);
    D := L1 + L2 - SoftReach + Over / (1 + Over / SoftReach);
  end;
  if D > L1 + L2 - 1e-5 then D := L1 + L2 - 1e-5;
  if D < Abs(L1 - L2) + 1e-5 then D := Abs(L1 - L2) + 1e-5;
  A := (D * D + L1 * L1 - L2 * L2) / (2 * D);
  H := Sqrt(Max(L1 * L1 - A * A, 0));
  Perp := V3Sub(Hint, V3Scale(Dir, V3Dot(Dir, Hint)));
  if V3Len(Perp) < 1e-6 then
  begin
    Perp := V3Cross(Dir, V3(0, 0, 1));
    if V3Len(Perp) < 1e-6 then Perp := V3Cross(Dir, V3(0, 1, 0));
  end;
  Result := V3Add(V3Add(Root, V3Scale(Dir, A)), V3Scale(V3Norm(Perp), H));
end;

{ ShAnkleCurve удалена: анклинг — BicycleAnkleFlexCurve из BikeGfxUtil. }

{ ── GLSL-литералы ── }

function GV3(const V: TTripoVec3): string;
begin Result := 'vec3(' + GNum(V.X) + ',' + GNum(V.Y) + ',' + GNum(V.Z) + ')'; end;

function GQ(const Q: TTripoVec4): string;
begin Result := 'vec4(' + GNum(Q.X) + ',' + GNum(Q.Y) + ',' + GNum(Q.Z) + ',' + GNum(Q.W) + ')'; end;

function GMat4(const M: TTripoMat4): string;
var I: Integer;
begin
  Result := 'mat4(';
  for I := 0 to 15 do
  begin
    if I > 0 then Result := Result + ',';
    Result := Result + GNum(M[I]);
  end;
  Result := Result + ')';
end;

{ ═══════════ TGpuRiderSkin ═══════════ }

constructor TGpuRiderSkin.Create(ARider: TTripoRiderScene);
begin
  inherited Create;
  FRider := ARider;
  FEffect := nil;
  FReady := False;
  FRestCount := 0;
  FRestList := TMatrix4List.Create;
  FBindTList := TVector3List.Create;
end;

destructor TGpuRiderSkin.Destroy;
begin
  if(FRider<>nil)and(FRider.Correctives<>nil)then FRider.Correctives.DetachGpu;
  if(FRider<>nil)and(FRider.Face<>nil)then FRider.Face.DetachGpu;
  { FEffect is parented to appearances — it dies with the rider scene.
    Do not Free it here: LoadTripoRider / a live slider can destroy the
    wrapper while CGE still holds the node in the current frame. }
  try
    if FEffect <> nil then
      FEffect.Enabled := False;
  except
  end;
  FEffect := nil;
  FUInvP := nil;
  FUScalars := nil;
  FUVecs := nil;
  FURest := nil;
  FUBindT := nil;
  FScalarsList.Free;
  FVecsList.Free;
  FRestList.Free;
  FBindTList.Free;
  FShNameIdx.Free;
  inherited;
end;

procedure TGpuRiderSkin.Detach;
begin
  { Disable only. Extract/Free of TEffectNode while the scene is mounted
    races the renderer and raises EObjectCheck (often on rider-list click). }
  FReady := False;
  if(FRider<>nil)and(FRider.Face<>nil)then FRider.Face.DetachGpu;
  if(FRider<>nil)and(FRider.Correctives<>nil)then FRider.Correctives.DetachGpu;
  if FEffect = nil then Exit;
  try
    FEffect.Enabled := False;
  except
  end;
end;

function RestToCastle(const M: TTripoMat4): TMatrix4;
var
  c, r: Integer;
begin
  for c := 0 to 3 do
    for r := 0 to 3 do
      Result.Data[c, r] := M[c * 4 + r];
end;

procedure TGpuRiderSkin.UploadBindUniforms;
var
  Rig: TTripoRig;
  HandMatrices: array of TTripoMat4;
  HandList: TMatrix4List;
  I, J, P, Side: Integer;
  RestM: TTripoMat4;
  Contact: TVector3;
  HintV: TVector3;
  SpineIdx: array[0..RiderSpineChainCount-1] of Integer;
  LegIdx: array[0..1, 0..2] of Integer;
  ArmIdx: array[0..1, 0..3] of Integer;
  LegOk, ArmOk: array[0..1] of Boolean;
  ClavParentSpine: array[0..1] of Integer;

  function BindPos(A: Integer): TTripoVec3;
  begin Result := V3(Rig.BindWorld[A][12], Rig.BindWorld[A][13], Rig.BindWorld[A][14]); end;
  function BindRot(A: Integer): TTripoVec4;
  begin Result := Mat4ToQuat(Rig.BindWorld[A]); end;
  function LocalOff(Parent, Child: Integer): TTripoVec3;
  begin
    Result := QuatRotateV3(QuatConj(BindRot(Parent)), V3Sub(BindPos(Child), BindPos(Parent)));
  end;
  function BoneLen(Parent, Child: Integer): Single;
  begin Result := V3Len(V3Sub(BindPos(Child), BindPos(Parent))); end;
begin
  if (FRider = nil) or (FRider.Rig = nil) then Exit;
  Rig := FRider.Rig;
  if (FRestCount <= 0) or (Rig.JointCount <> FRestCount) then Exit;
  if FUHandRest <> nil then
  begin
    SetLength(HandMatrices, Rig.JointCount);
    Rig.ClosedHandMatrices(HandMatrices);
    HandList := TMatrix4List.Create;
    try
      HandList.Add(TMatrix4.Identity);
      for I := 1 to High(FHandJointIndices) do
        HandList.Add(RestToCastle(HandMatrices[FHandJointIndices[I]]));
      FUHandRest.Send(HandList);
    finally HandList.Free end;
  end;
  if (Length(Rig.BindWorld) <> Rig.JointCount) then Exit;

  FRestList.Clear;
  FBindTList.Clear;
  for I := 0 to FRestCount - 1 do
  begin
    FBindTList.Add(Vector3(Rig.BindWorld[I][12], Rig.BindWorld[I][13], Rig.BindWorld[I][14]));
    if Length(Rig.NativeInvBind) = Rig.JointCount then
      RestM := Mat4Mul(Rig.BindWorld[I], Rig.NativeInvBind[I])
    else
      RestM := Mat4Identity;
    FRestList.Add(RestToCastle(RestM));
  end;
  if (FUBindT <> nil) and (FEffect <> nil) and (FEffect.Scene <> nil) then
    FUBindT.Send(FBindTList)
  else if FUBindT <> nil then
    FUBindT.Items.Assign(FBindTList);
  if (FURest <> nil) and (FEffect <> nil) and (FEffect.Scene <> nil) then
    FURest.Send(FRestList)
  else if FURest <> nil then
    FURest.Items.Assign(FRestList);

  { ── FSh* bind capture (helmet / capsule shadow) from live BindWorld ── }
  for I := 0 to RiderSpineChainCount-1 do SpineIdx[I] := Rig.JointIndexByName(RiderSpineChainNames[I]);
  LegIdx[0,0] := Rig.JointIndexByName('R_Thigh');
  LegIdx[0,1] := Rig.JointIndexByName('R_Calf');
  LegIdx[0,2] := Rig.JointIndexByName('R_Foot');
  LegIdx[1,0] := Rig.JointIndexByName('L_Thigh');
  LegIdx[1,1] := Rig.JointIndexByName('L_Calf');
  LegIdx[1,2] := Rig.JointIndexByName('L_Foot');
  ArmIdx[0,0] := Rig.JointIndexByName('R_Clavicle');
  ArmIdx[0,1] := Rig.JointIndexByName('R_Upperarm');
  ArmIdx[0,2] := Rig.JointIndexByName('R_Forearm');
  ArmIdx[0,3] := Rig.JointIndexByName('R_Hand');
  ArmIdx[1,0] := Rig.JointIndexByName('L_Clavicle');
  ArmIdx[1,1] := Rig.JointIndexByName('L_Upperarm');
  ArmIdx[1,2] := Rig.JointIndexByName('L_Forearm');
  ArmIdx[1,3] := Rig.JointIndexByName('L_Hand');
  for Side := 0 to 1 do
  begin
    LegOk[Side] := (LegIdx[Side,0] >= 0) and (LegIdx[Side,1] >= 0) and (LegIdx[Side,2] >= 0);
    ArmOk[Side] := (ArmIdx[Side,0] >= 0) and (ArmIdx[Side,1] >= 0) and (ArmIdx[Side,2] >= 0) and (ArmIdx[Side,3] >= 0);
    ClavParentSpine[Side] := -1;
    if ArmIdx[Side,0] >= 0 then
    begin
      P := Rig.JointParent[ArmIdx[Side,0]];
      for I := 0 to RiderSpineChainCount-1 do
        if SpineIdx[I] = P then ClavParentSpine[Side] := I;
    end;
  end;
  for Side := 0 to 1 do
    if LegOk[Side] then
      with FShLegs[Side] do
      begin
        Ok := True;
        HP := BindPos(LegIdx[Side,0]);  UR := BindRot(LegIdx[Side,0]);
        AXM := V3Norm(LocalOff(LegIdx[Side,0], LegIdx[Side,1]));
        MR := BindRot(LegIdx[Side,1]);
        AXE := V3Norm(LocalOff(LegIdx[Side,1], LegIdx[Side,2]));
        ER := BindRot(LegIdx[Side,2]);
        Contact := FRider.GpuContactLocal(Side);
        CT := V3(Contact.X, Contact.Y, Contact.Z);
        L1 := BoneLen(LegIdx[Side,0], LegIdx[Side,1]);
        L2 := BoneLen(LegIdx[Side,1], LegIdx[Side,2]);
      end;
  HintV := FRider.LegPlaneHint;
  FShLegHint := V3(HintV.X, HintV.Y, HintV.Z);
  HintV := FRider.ArmPlaneHint;
  FShArmHint := V3(HintV.X, HintV.Y, HintV.Z);
  HintV := FRider.LeanAxis;
  FShLean := V3(HintV.X, HintV.Y, HintV.Z);
  HintV := FRider.FlareAxis;
  FShFlare := V3(HintV.X, HintV.Y, HintV.Z);
  for I := 0 to RiderSpineChainCount-1 do
    if SpineIdx[I] >= 0 then
      with FShSpine[I] do
      begin
        Ex := True;
        PP := BindPos(SpineIdx[I]);
        PR := BindRot(SpineIdx[I]);
        ParentInChain := False;
        ParentSpine := -1;
        P := Rig.JointParent[SpineIdx[I]];
        for J := 0 to RiderSpineChainCount-1 do
          if SpineIdx[J] = P then
          begin
            ParentInChain := True;
            ParentSpine := J;
          end;
        if ParentInChain then PO := LocalOff(P, SpineIdx[I]);
      end;
  for Side := 0 to 1 do
    if ArmOk[Side] then
      with FShArms[Side] do
      begin
        Ok := True;
        CP := BindPos(ArmIdx[Side,0]);  CR := BindRot(ArmIdx[Side,0]);
        CO := LocalOff(Rig.JointParent[ArmIdx[Side,0]], ArmIdx[Side,0]);
        AO := LocalOff(ArmIdx[Side,0], ArmIdx[Side,1]);
        ClavInSpine := ClavParentSpine[Side] >= 0;
        ParentSpine := ClavParentSpine[Side];
        if ClavInSpine then PR := BindRot(SpineIdx[ClavParentSpine[Side]])
        else PR := CR;
        UR := BindRot(ArmIdx[Side,1]);
        AXM := V3Norm(LocalOff(ArmIdx[Side,1], ArmIdx[Side,2]));
        MR := BindRot(ArmIdx[Side,2]);
        AXE := V3Norm(LocalOff(ArmIdx[Side,2], ArmIdx[Side,3]));
        ER := BindRot(ArmIdx[Side,3]);
        RiderHandAxes(Rig,Side,FShArms[Side].HandForward,FShArms[Side].HandPalm);
        Contact := FRider.GpuContactLocal(2 + Side);
        CT := V3(Contact.X, Contact.Y, Contact.Z);
        L1 := BoneLen(ArmIdx[Side,1], ArmIdx[Side,2]);
        L2 := BoneLen(ArmIdx[Side,2], ArmIdx[Side,3]);
      end;
  for Side := 0 to 1 do
    if FUHandForward[Side] <> nil then
      with FShArms[Side].HandForward do
        FUHandForward[Side].Send(Vector3(X, Y, Z));
  for I := 0 to GPU_SHJ_COUNT - 1 do
  begin
    J := Rig.JointIndexByName(SHJ_NAMES[I]);
    FShEx[I] := J >= 0;
    if FShEx[I] then FShBind[I] := BindPos(J)
    else FShBind[I] := V3(0, 0, 0);
  end;
end;

function TGpuRiderSkin.RefreshBind: Boolean;
begin
  Result := False;
  if (not FReady) or (FEffect = nil) or (FRider = nil) or (FRider.Rig = nil) then Exit;
  if FRider.Rig.JointCount <> FRestCount then Exit;
  UploadBindUniforms;
  Result := True;
end;

function TGpuRiderSkin.Build(ALog: TStrings): Boolean;
const
  { процедурные роли суставов }
  PK_NONE = 0; PK_LEGR = 1; PK_LEGL = 2; PK_SPINE = 3; PK_ARMR = 4; PK_ARML = 5;
var
  Rig: TTripoRig;
  SL: TStringList;
  Apps: TList;
  I, J, P, NJ, Side: Integer;
  Anc: array of Integer;
  Kind, PPart: array of Integer;
  SpineIdx: array[0..RiderSpineChainCount-1] of Integer;
  LegIdx: array[0..1, 0..2] of Integer;   { [side][0=thigh,1=calf,2=foot] }
  ArmIdx: array[0..1, 0..3] of Integer;   { [side][0=clav,1=upper,2=fore,3=hand] }
  TwistIdx: array[0..1, 0..1] of Integer;
  TwistOk: array[0..1] of Boolean;
  LegOk, ArmOk: array[0..1] of Boolean;
  ClavParentSpine: array[0..1] of Integer; { spine-part родителя ключицы, -1 = вне цепи }
  S: string;
  ShapeNode: TShapeNode;
  App: TAppearanceNode;
  PartV: TEffectPartNode;
  JointCode, Iterations: TMFInt32;
  LegNames: array[0..1, 0..2] of string;
  ArmNames: array[0..1, 0..3] of string;
  Contact: TVector3;
  SpIdx: Integer;
  HintV: TVector3;
  RestM: TTripoMat4;

  { bind-данные сустава J: мировая поза (из BindWorld) }
  function BindPos(J: Integer): TTripoVec3;
  begin Result := V3(Rig.BindWorld[J][12], Rig.BindWorld[J][13], Rig.BindWorld[J][14]); end;
  function BindRot(J: Integer): TTripoVec4;
  begin Result := Mat4ToQuat(Rig.BindWorld[J]); end;
  function BindLocalTrans(J: Integer): TTripoVec3;   { трансляция в кадре родителя }
  begin Result := V3(Rig.BindLocal[J][12], Rig.BindLocal[J][13], Rig.BindLocal[J][14]); end;
  { смещение ребёнка в кадре родителя, пересчитанное из BindWorld:
    BindLocal после ApplyLimbLengths/ApplyBodyShape рассинхронизирован с BindWorld
    (проверено sim_gpu_skin.py: спина/ключицы err 0.04..0.08), поэтому направления
    костей и локальные смещения эмитим только из BindWorld }
  function LocalOff(Parent, Child: Integer): TTripoVec3;
  begin
    Result := QuatRotateV3(QuatConj(BindRot(Parent)), V3Sub(BindPos(Child), BindPos(Parent)));
  end;
  function BoneLen(Parent, Child: Integer): Single;
  begin Result := V3Len(V3Sub(BindPos(Child), BindPos(Parent))); end;

  procedure Log(const Msg: string);
  begin
    if ALog <> nil then ALog.Add('[gpu-skin] ' + Msg);
    StartupLog('[gpu-skin] ' + Msg);   { ALog обычно nil — не терять причину отказа }
  end;

  { ближайший процедурный предок сустава J (через JointParent), -1 = нет }
  function ProcAncestor(J: Integer): Integer;
  begin
    while J >= 0 do
    begin
      if Kind[J] <> PK_NONE then Exit(J);
      J := Rig.JointParent[J];
    end;
    Result := -1;
  end;

  function SpineMatrixSlot(Index: Integer): Integer;
  begin
    if Index<5 then Result:=7+Index else Result:=15+Index;
  end;

  function PsdRotation(J: Integer): string;
  var A, Slot: Integer;
  begin
    Result := 'mat3(1.0)';
    if J < 0 then Exit;
    A := Anc[J];
    if A < 0 then Exit;
    if (Kind[A] >= PK_ARMR) and (PPart[A] >= 4) then
      Exit('mat3(gskTwistD(' + IntToStr(Kind[A]) + ',' + IntToStr(PPart[A]) + '))');
    case Kind[A] of
      PK_LEGR: Slot := 1;
      PK_LEGL: Slot := 4;
      PK_SPINE: if PPart[A]<5 then Slot := 7 else Slot := 15;
      PK_ARMR: Slot := 12;
      PK_ARML: Slot := 16;
      else Exit;
    end;
    Result := 'mat3(gskDelta[' + IntToStr(Slot + PPart[A]) + '])';
  end;

  procedure EmitConst(const CName: string; const V: TTripoVec3);
  begin SL.Add('const vec3 ' + CName + ' = ' + GV3(V) + ';'); end;
  procedure EmitConstQ(const CName: string; const Q: TTripoVec4);
  begin SL.Add('const vec4 ' + CName + ' = ' + GQ(Q) + ';'); end;

  { конечность: ротации/контакт — const; позиции/длины — uBindT (HeightK live) }
  procedure EmitLimbConsts(const Pfx: string; U, M, E: Integer; const Cnt: TVector3);
  begin
    SL.Add('#define ' + Pfx + 'HP uBindT[' + IntToStr(U) + ']');
    EmitConstQ(Pfx + 'UR', BindRot(U));
    SL.Add('#define ' + Pfx + 'AXM normalize(gskQRot(gskQConj(' + Pfx + 'UR), uBindT[' + IntToStr(M) + ']-' + Pfx + 'HP))');
    SL.Add('#define ' + Pfx + 'MP uBindT[' + IntToStr(M) + ']');
    EmitConstQ(Pfx + 'MR', BindRot(M));
    SL.Add('#define ' + Pfx + 'AXE normalize(gskQRot(gskQConj(' + Pfx + 'MR), uBindT[' + IntToStr(E) + ']-' + Pfx + 'MP))');
    SL.Add('#define ' + Pfx + 'EP uBindT[' + IntToStr(E) + ']');
    EmitConstQ(Pfx + 'ER', BindRot(E));
    EmitConst(Pfx + 'CT', V3(Cnt.X, Cnt.Y, Cnt.Z));
    SL.Add('#define ' + Pfx + 'L1 length(' + Pfx + 'MP-' + Pfx + 'HP)');
    SL.Add('#define ' + Pfx + 'L2 length(' + Pfx + 'EP-' + Pfx + 'MP)');
  end;

  { GLSL-решатель ноги: 3 уточнения контакта + 1 финальный IK голеностопа }
  procedure EmitLegSolve(const Fn, Pfx, CrankU: string; SideSign: Integer);
  begin
    SL.Add('void ' + Fn + '(out mat4 dU, out mat4 dM, out mat4 dE) {');
    SL.Add('  float ang = uPedalDir * uPhase * 6.2831853;');
    SL.Add('  float ca = cos(ang), sa = sin(ang);');
    SL.Add('  vec2 rc = vec2(' + CrankU + '.x*ca - ' + CrankU + '.y*sa, ' + CrankU + '.x*sa + ' + CrankU + '.y*ca);');
    { free-нога (этап 3-хвост): цель блендится педаль↔free-позиция (bike frame),
      анклинг гасится (1-free) — зеркало AnimateFrame: AnkleR/FootPitchR }
    if SideSign > 0 then
    begin
      SL.Add('  vec3 pedal = uBB + vec3(rc, uStanceZ);');
      SL.Add('  float free = clamp(uLegFreeR, 0.0, 1.0);');
      SL.Add('  pedal = mix(pedal, uLegFreePosR, free);');
    end
    else
    begin
      SL.Add('  vec3 pedal = uBB + vec3(rc, -uStanceZ);');
      SL.Add('  float free = clamp(uLegFreeL, 0.0, 1.0);');
      SL.Add('  pedal = mix(pedal, uLegFreePosL, free);');
    end;
    SL.Add('  vec3 tgt = (uInvP * vec4(pedal, 1.0)).xyz;');
    SL.Add('  float flexRad = 0.0;');
    SL.Add('  if (abs(uAnkleFlex) > 0.001) {');
    SL.Add('    float crankAng = atan(' + CrankU + '.y, ' + CrankU + '.x) + ang;');
    SL.Add('    flexRad = -radians(gskAnkleCurve(90.0 - degrees(crankAng))) * (1.0 - free);');
    SL.Add('  }');
    if SideSign > 0 then
      SL.Add('  vec3 hint = gskLHINT + gskFLARE * uKneeFlare;')
    else
      SL.Add('  vec3 hint = gskLHINT - gskFLARE * uKneeFlare;');
    SL.Add('  vec3 root = ' + Pfx + 'HP;');
    SL.Add('  vec3 aim = tgt;');
    SL.Add('  vec4 qU = ' + Pfx + 'UR, qM = ' + Pfx + 'MR, qE = ' + Pfx + 'ER;');
    SL.Add('  vec3 pM = ' + Pfx + 'MP;');
    SL.Add('  vec4 footTurn = vec4(uFootYawXYZ * ' + GNum(SideSign) + ', uFootYawW);');
    SL.Add('  footTurn = qmul(footTurn, gskQAA(gskLEAN, flexRad));');
    SL.Add('  vec3 contactLower = ' + Pfx + 'AXE * ' + Pfx + 'L2 + gskQRot(qmul(gskQConj(' + Pfx + 'MR), ' + Pfx + 'ER), ' + Pfx + 'CT);');
    SL.Add('  float contactLength = length(contactLower);');
    SL.Add('  vec3 contactAxis = contactLower / max(contactLength, 1e-6);');
    SL.Add('  for (int pass = 0; pass < uGskIterations[0]-1; pass++) {');
    SL.Add('    vec3 mid = gskSolveJoint(root, aim, ' + Pfx + 'L1, contactLength, hint, 0.02 * (' + Pfx + 'L1 + contactLength));');
    SL.Add('    vec3 uDir = normalize(mid - root);');
    SL.Add('    qU = qmul(gskQFromTo(gskQRot(' + Pfx + 'UR, ' + Pfx + 'AXM), uDir), ' + Pfx + 'UR);');
    SL.Add('    pM = root + uDir * ' + Pfx + 'L1;');
    SL.Add('    vec4 qMpre = qmul(qU, qmul(gskQConj(' + Pfx + 'UR), ' + Pfx + 'MR));');
    SL.Add('    vec3 mDir = normalize(aim - pM);');
    SL.Add('    qM = qmul(gskQFromTo(gskQRot(qMpre, contactAxis), mDir), qMpre);');
    SL.Add('    vec4 qEnat = qmul(qM, qmul(gskQConj(' + Pfx + 'MR), ' + Pfx + 'ER));');
    SL.Add('    qE = qmul(footTurn, qEnat);');
    SL.Add('    aim = tgt + gskQRot(qEnat, ' + Pfx + 'CT) - gskQRot(qE, ' + Pfx + 'CT);');
    SL.Add('  }');
    { Final solve uses the actual shin length and the ankle matching the chosen
      foot orientation. Previously dM used the preceding aim while dE used the
      next one, stretching the shin and moving the knee at reach transitions. }
    SL.Add('  aim = tgt - gskQRot(qE, ' + Pfx + 'CT);');
    SL.Add('  vec3 mid = gskSolveJoint(root, aim, ' + Pfx + 'L1, ' + Pfx + 'L2, hint, 0.0);');
    SL.Add('  vec3 uDir = normalize(mid - root);');
    SL.Add('  qU = qmul(gskQFromTo(gskQRot(' + Pfx + 'UR, ' + Pfx + 'AXM), uDir), ' + Pfx + 'UR);');
    SL.Add('  pM = root + uDir * ' + Pfx + 'L1;');
    SL.Add('  vec4 qMpre = qmul(qU, qmul(gskQConj(' + Pfx + 'UR), ' + Pfx + 'MR));');
    SL.Add('  vec3 mDir = normalize(aim - pM);');
    SL.Add('  qM = qmul(gskQFromTo(gskQRot(qMpre, ' + Pfx + 'AXE), mDir), qMpre);');
    SL.Add('  aim = pM + mDir * ' + Pfx + 'L2;');
    SL.Add('  dU = gskDMat(qU, root, ' + Pfx + 'UR, ' + Pfx + 'HP);');
    SL.Add('  dM = gskDMat(qM, pM, ' + Pfx + 'MR, ' + Pfx + 'MP);');
    SL.Add('  dE = gskDMat(qE, aim, ' + Pfx + 'ER, ' + Pfx + 'EP);');
    SL.Add('}');
  end;

  { GLSL-решатель руки: part 0 = ключица (из базы), 1..3 = two-bone IK + пронация }
  procedure EmitArmSolve(const Fn, Pfx, BaseFn, GripU, PronU: string; SideSign: Integer);
  var Side:Integer;
  begin
    Side:=(1-SideSign) div 2;
    SL.Add('void ' + Fn + '(bool limb, out mat4 dCl, out mat4 dU, out mat4 dM, out mat4 dE, out vec4 foreRoll, out vec3 forePivot) {');
    SL.Add('  vec4 qU0; vec3 pSh;');
    SL.Add('  ' + BaseFn + '(qU0, pSh, dCl);');
    SL.Add('  dU = mat4(1.0); dM = mat4(1.0); dE = mat4(1.0);');
    SL.Add('  foreRoll = vec4(0.0,0.0,0.0,1.0); forePivot = pSh;');
    SL.Add('  if (!limb) return;');
    SL.Add('  vec3 tgt = (uInvP * vec4(' + GripU + ', 1.0)).xyz;');
    if SideSign > 0 then
      SL.Add('  vec3 hint = gskAHINT + gskFLARE * uElbowFlare;')
    else
      SL.Add('  vec3 hint = gskAHINT - gskFLARE * uElbowFlare;');
    SL.Add('  vec3 root = pSh;');
    SL.Add('  vec3 aim = tgt;');
    SL.Add('  float reach = ' + Pfx + 'L1 + ' + Pfx + 'L2;');
    SL.Add('  vec4 qU = qU0, qM = ' + Pfx + 'MR, qE = ' + Pfx + 'ER;');
    SL.Add('  vec3 pM = ' + Pfx + 'MP, pE = ' + Pfx + 'EP;');
    SL.Add('  for (int pass = 0; pass < uGskIterations[1]; pass++) {');
    SL.Add('    vec3 requestedAim = aim;');
    SL.Add('    vec3 sv = aim - root; float sl = length(sv);');
    SL.Add('    if (sl > reach*0.999) aim = root + sv*(reach*0.999/sl);');
    SL.Add('    vec3 mid = gskSolveJoint(root, aim, ' + Pfx + 'L1, ' + Pfx + 'L2, hint, 0.0);');
    SL.Add('    vec3 uDir = normalize(mid - root);');
    SL.Add('    qU = qmul(gskQFromTo(gskQRot(qU0, ' + Pfx + 'AXM), uDir), qU0);');
    SL.Add('    pM = root + uDir * ' + Pfx + 'L1;');
    SL.Add('    vec4 qMpre = qmul(qU, qmul(gskQConj(' + Pfx + 'UR), ' + Pfx + 'MR));');
    SL.Add('    vec3 mDir = normalize(aim - pM);');
    SL.Add('    qM = qmul(gskQFromTo(gskQRot(qMpre, ' + Pfx + 'AXE), mDir), qMpre);');
    SL.Add('    vec4 qEnat = qmul(qM, qmul(gskQConj(' + Pfx + 'MR), ' + Pfx + 'ER));');
    SL.Add('    pE = pM + mDir * ' + Pfx + 'L2;');
    SL.Add('    qE = gskGripOrientation(qEnat,uGripQ'+IntToStr(Side)+',mDir,uGskHandForward'+IntToStr(Side)+',');
    SL.Add('      uScalars['+IntToStr(43+Side)+'],'+PronU+','+IntToStr(-SideSign)+'.0,uHandLevel);');
    SL.Add('    vec3 newAim = tgt - gskQRot(qE, ' + Pfx + 'CT);');
    SL.Add('    if (length(newAim - requestedAim) < 1e-5) break;');
    { Wrist orientation feeds back into the target. Full corrections can
      alternate and diverge near reach; damp after the first placement.
      pE must remain from the same solve as qM/qE, never the next target. }
    SL.Add('    aim = mix(aim, newAim, pass == 0 ? 1.0 : 0.35);');
    SL.Add('  }');
    SL.Add('  dU = gskDMat(qU, root, ' + Pfx + 'UR, ' + Pfx + 'HP);');
    SL.Add('  dM = gskDMat(qM, pM, ' + Pfx + 'MR, ' + Pfx + 'MP);');
    SL.Add('  dE = gskDMat(qE, pE, ' + Pfx + 'ER, ' + Pfx + 'EP);');
    if TwistOk[(1-SideSign) div 2] then
    begin
      { Same swing/twist decomposition as TripoRig.DistributeForearmTwist.
        These transforms roll around the elbow-wrist line, so they cannot
        move the wrist pivot or spread its flexion onto the forearm. }
      SL.Add('  vec3 twistAxis = normalize(pE-pM);');
      SL.Add('  vec4 naturalHand = qmul(qM, qmul(gskQConj(' + Pfx + 'MR), ' + Pfx + 'ER));');
      SL.Add('  vec4 relativeHand = normalize(qmul(qE, gskQConj(naturalHand)));');
      SL.Add('  if (relativeHand.w < 0.0) relativeHand = -relativeHand;');
      SL.Add('  foreRoll = normalize(vec4(twistAxis*dot(relativeHand.xyz,twistAxis),relativeHand.w));');
      SL.Add('  forePivot = pM;');
    end;
    SL.Add('}');
  end;

begin
  Result := False;
  if (FEffect <> nil) and (FRestCount > 0) and (FRider <> nil)
     and (FRider.Rig <> nil) and (FRider.Rig.JointCount = FRestCount) then
  begin
    FReady := True;
    Exit(RefreshBind);
  end;
  FReady := False;
  Rig := FRider.Rig;
  if (Rig = nil) or (Rig.JointCount <= 0) then begin Log('rig missing'); Exit; end;
  if FRider.SkinNode = nil then begin Log('skin node missing'); Exit; end;

  LegNames[0,0] := 'R_Thigh'; LegNames[0,1] := 'R_Calf'; LegNames[0,2] := 'R_Foot';
  LegNames[1,0] := 'L_Thigh'; LegNames[1,1] := 'L_Calf'; LegNames[1,2] := 'L_Foot';
  ArmNames[0,0] := 'R_Clavicle'; ArmNames[0,1] := 'R_Upperarm'; ArmNames[0,2] := 'R_Forearm'; ArmNames[0,3] := 'R_Hand';
  ArmNames[1,0] := 'L_Clavicle'; ArmNames[1,1] := 'L_Upperarm'; ArmNames[1,2] := 'L_Forearm'; ArmNames[1,3] := 'L_Hand';

  { ── разрешение индексов и валидация цепочек ── }
  NJ := Rig.JointCount;
  SetLength(Kind, NJ); SetLength(PPart, NJ); SetLength(Anc, NJ);
  for I := 0 to NJ - 1 do begin Kind[I] := PK_NONE; PPart[I] := 0; Anc[I] := -1; end;

  for I := 0 to RiderSpineChainCount-1 do
  begin
    SpineIdx[I] := Rig.JointIndexByName(RiderSpineChainNames[I]);
    FSpineIdx[I] := SpineIdx[I];
    FSpineEx[I] := SpineIdx[I] >= 0;
  end;

  for Side := 0 to 1 do
  begin
    for I := 0 to 2 do LegIdx[Side, I] := Rig.JointIndexByName(LegNames[Side, I]);
    for I := 0 to 3 do ArmIdx[Side, I] := Rig.JointIndexByName(ArmNames[Side, I]);
    { цепочка валидна, если все звенья есть и родительство совпадает }
    LegOk[Side] := (LegIdx[Side,0] >= 0) and (LegIdx[Side,1] >= 0) and (LegIdx[Side,2] >= 0)
      and (Rig.JointParent[LegIdx[Side,1]] = LegIdx[Side,0])
      and (Rig.JointParent[LegIdx[Side,2]] = LegIdx[Side,1]);
    ArmOk[Side] := (ArmIdx[Side,0] >= 0) and (ArmIdx[Side,1] >= 0) and (ArmIdx[Side,2] >= 0) and (ArmIdx[Side,3] >= 0)
      and (Rig.JointParent[ArmIdx[Side,1]] = ArmIdx[Side,0])
      and (Rig.JointParent[ArmIdx[Side,2]] = ArmIdx[Side,1])
      and Rig.JointDescendsFrom(ArmIdx[Side,3], ArmIdx[Side,2]);
    TwistOk[Side] := ArmOk[Side] and Rig.ForearmTwistJoints(
      ArmIdx[Side,2], ArmIdx[Side,3], TwistIdx[Side,0], TwistIdx[Side,1]);
    { родитель ключицы — какой из суставов позвоночника? }
    ClavParentSpine[Side] := -1;
    if ArmIdx[Side,0] >= 0 then
    begin
      P := Rig.JointParent[ArmIdx[Side,0]];
      for I := 0 to RiderSpineChainCount-1 do
        if SpineIdx[I] = P then ClavParentSpine[Side] := I;
    end;
  end;

  { ── классификация суставов: процедурные роли ── }
  for Side := 0 to 1 do
  begin
    if LegOk[Side] then
      for I := 0 to 2 do
      begin
        Kind[LegIdx[Side,I]] := PK_LEGR + Side;
        PPart[LegIdx[Side,I]] := I;
      end;
    if ArmOk[Side] then
      for I := 0 to 3 do
      begin
        Kind[ArmIdx[Side,I]] := PK_ARMR + Side;
        PPart[ArmIdx[Side,I]] := I;
      end;
  end;
  for I := 0 to RiderSpineChainCount-1 do
    if FSpineEx[I] then
    begin
      Kind[SpineIdx[I]] := PK_SPINE;
      PPart[SpineIdx[I]] := I;
    end;

  { ── разметка follower'ов: ближайший процедурный предок ── }
  for Side := 0 to 1 do
    if TwistOk[Side] then
      for I := 0 to 1 do
      begin
        Kind[TwistIdx[Side,I]] := PK_ARMR + Side;
        PPart[TwistIdx[Side,I]] := 4 + I;
      end;
  for I := 0 to NJ - 1 do
    if Kind[I] = PK_NONE then
      Anc[I] := ProcAncestor(Rig.JointParent[I])
    else
      Anc[I] := I;

  { ── uniforms ── }
  FEffect := TEffectNode.Create;
  FEffect.Language := slGLSL;
  FEffect.X3DName := 'TripoGpuSkin';
  FEffect.InternalCacheVertexAnimation := True;
  if FRider.Face<>nil then FRider.Face.AttachGpu(FEffect);
  { Static skeleton routing is data, not a separate IK call site for every
    joint. The driver otherwise inlines the full limb solver in dozens of
    branches, making first-use shader linking take seconds per shape. }
  JointCode := TMFInt32.Create(FEffect, True, 'uGskJointCode', []);
  { Only hands/fingers use the closed-grip palette. Keeping NJ matrices here
    exhausted the 1024 vertex constant registers when facial joints grew.
    The low six bits retain limb routing; high bits select this compact bank. }
  SetLength(FHandJointIndices,1);FHandJointIndices[0]:=-1;
  for I := 0 to NJ - 1 do
  begin
    J := Anc[I];
    if J < 0 then JointCode.Items.Add(0)
    else if (Kind[J] in [PK_ARMR,PK_ARML]) and(PPart[J]=3) then begin
      SetLength(FHandJointIndices,Length(FHandJointIndices)+1);
      FHandJointIndices[High(FHandJointIndices)]:=I;
      JointCode.Items.Add(Kind[J]*8+PPart[J]+High(FHandJointIndices)*64);
    end else JointCode.Items.Add(Kind[J] * 8 + PPart[J]);
  end;
  FEffect.AddCustomField(JointCode);
  { Uniform bounds preserve the solver iterations without driver unrolling. }
  Iterations := TMFInt32.Create(FEffect, True, 'uGskIterations', [4, 8, 4]);
  FEffect.AddCustomField(Iterations);
  FUInvP := TSFMatrix4f.Create(FEffect, true, 'uInvP', TMatrix4.Identity);
  FEffect.AddCustomField(FUInvP);
  { скаляры одним MF-массивом (порядок = #define-алиасы в GLSL):
    0 phase, 1 stanceZ, 2 pedalDir, 3 kneeFlare, 4 elbowFlare, 5 ankleFlex,
    6 pronR, 7 pronL, 8 shoulderRound, 9 handLevel, 10 legFreeR, 11 legFreeL,
    12..31 spine world quaternions, 32 foot yaw W, 33/34 grip closed,
    35..42 clavicle deltas, 43/44 hand alignment, 45..52 grip rotations,
    53..60 upper neck and skull world rotations }
  FUScalars := TMFFloat.Create(FEffect, true, 'uScalars',
    [0, 0.07, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0,
     0,0,0,1, 0,0,0,1, 0,0,0,1, 0,0,0,1, 0,0,0,1,
     1,1,1, 0,0,0,1, 0,0,0,1, 1,1, 0,0,0,1, 0,0,0,1,
     0,0,0,1, 0,0,0,1]);
  FEffect.AddCustomField(FUScalars);
  FUVecs := TMFVec3f.Create(FEffect, true, 'uVecs',
    [Vector3(0, 0, 0), Vector3(0, -0.17, 0), Vector3(0, 0.17, 0),
     Vector3(0, 1, 0), Vector3(0, 1, 0), Vector3(0, 0, 0), Vector3(0, 0, 0),
     Vector3(0, 0, 0)]);
  FEffect.AddCustomField(FUVecs);
  FScalarsList := TSingleList.Create;
  FVecsList := TVector3List.Create;
  { Live bind: HeightK / limb lengths update these without shader recompile. }
  FRestCount := NJ;
  FRestList.Clear;
  FBindTList.Clear;
  for I := 0 to NJ - 1 do
  begin
    FRestList.Add(TMatrix4.Identity);
    FBindTList.Add(Vector3(0, 0, 0));
  end;
  FURest := TMFMatrix4f.Create(FEffect, True, 'uGskRest', []);
  FURest.Items.Assign(FRestList);
  FEffect.AddCustomField(FURest);
  FUBindT := TMFVec3f.Create(FEffect, True, 'uBindT', []);
  FUBindT.Items.Assign(FBindTList);
  FEffect.AddCustomField(FUBindT);
  FUHandRest := TMFMatrix4f.Create(FEffect, True, 'uGskHandRest', []);
  for I:=0 to High(FHandJointIndices)do FUHandRest.Items.Add(TMatrix4.Identity);
  FEffect.AddCustomField(FUHandRest);
  { These axes come from the live bind. Embedding their floating-point
    values made almost identical avatars compile separate full shaders,
    and left the GPU axis stale after a body-shape edit. }
  for Side := 0 to 1 do
  begin
    FUHandForward[Side] := TSFVec3f.Create(FEffect, True,
      'uGskHandForward' + IntToStr(Side), Vector3(0, 1, 0));
    FEffect.AddCustomField(FUHandForward[Side]);
  end;
  if FRider.Correctives <> nil then
  begin
    FRider.Correctives.SetGpuActive(True);
    FRider.Correctives.AddUniforms(FEffect);
  end;
  if FRider.Face<>nil then FRider.Face.Gpu:=True;

  { ── GLSL ── }
  SL := TStringList.Create;
  try
    { CGE компилит каждый chunk Source[stVertex] как ОТДЕЛЬНЫЙ shader object
      (desktop GL, castleglshaders AttachShader(Parts) — цикл по частям);
      глобалы соседних чанков на этапе компиляции не видны. Поэтому skin-
      атрибуты объявляем сами — совпадающее объявление в чанке
      skin_animation легально (так работает и сам движок: линк мержит
      глобальный скоуп). }
    SL.Add('attribute vec4 castle_Vertex;');
    SL.Add('attribute vec3 castle_Normal;');
    SL.Add('#ifdef RIDER_SURFACE_MOTION');
    SL.Add('vec3 riderSurfaceOffset();');
    SL.Add('#endif');
    SL.Add('attribute vec4 castle_SkinJoints0;');
    SL.Add('attribute vec4 castle_SkinWeights0;');
    SL.Add('');
    { глобальная skinMatrix движкового skin-чанка (skin_animation.vs) —
      линкер мержит global-scope. Содержит УЖЕ применённый движком скиннинг
      S = Σw·(sceneWorld·IBM). При лимб-скейлинге (ApplyBodyShape пишет
      FJointNode[].Translation) S ≠ I, и домножение M·(S·bind) даёт
      перекрёстные члены D_i·S_k — мятый меш. Отматываем движковый скиннинг
      обратно к bind-вершине и применяем СВОЙ LBS: вершина = M·inverse(S)·v,
      что тождественно Σw·D·bind при любом состоянии суставов. }
    SL.Add('mat4 skinMatrix;');
    SL.Add('uniform mat4 uInvP;');
    SL.Add('uniform float uScalars[61];');
    SL.Add('uniform mat4 uGskHandRest[' + IntToStr(Length(FHandJointIndices)) + '];');
    SL.Add('uniform int uGskIterations[3];');
    SL.Add('uniform vec3 uGskHandForward0, uGskHandForward1;');
    SL.Add('uniform vec3 uVecs[8];');
    SL.Add('uniform mat4 uGskRest[' + IntToStr(NJ) + '];');
    SL.Add('uniform int uGskJointCode[' + IntToStr(NJ) + '];');
    SL.Add('uniform vec3 uBindT[' + IntToStr(NJ) + '];');
    SL.Add('#define uGripQ0 vec4(uScalars[45],uScalars[46],uScalars[47],uScalars[48])');
    SL.Add('#define uGripQ1 vec4(uScalars[49],uScalars[50],uScalars[51],uScalars[52])');
    SL.Add('#define uPhase uScalars[0]');
    SL.Add('#define uStanceZ uScalars[1]');
    SL.Add('#define uPedalDir uScalars[2]');
    SL.Add('#define uKneeFlare uScalars[3]');
    SL.Add('#define uElbowFlare uScalars[4]');
    SL.Add('#define uAnkleFlex uScalars[5]');
    SL.Add('#define uPronR uScalars[6]');
    SL.Add('#define uPronL uScalars[7]');
    SL.Add('#define uShoulderRound uScalars[8]');
    SL.Add('#define uHandLevel uScalars[9]');
    SL.Add('#define uLegFreeR uScalars[10]');
    SL.Add('#define uLegFreeL uScalars[11]');
    { Reuse the five rotations already evaluated for the attached helmet.
      Positions and all limb IK/skinning remain in GLSL. Apart from redundant
      vertex ALU, composing nested full quaternions here causes expensive
      driver optimization on every material / shadow program. }
    for I := 0 to RiderSpineChainCount-1 do begin
      if I<5 then J:=12+I*4 else J:=53+(I-5)*4;
      SL.Add(Format('#define uSpineQ%d vec4(uScalars[%d],uScalars[%d],uScalars[%d],uScalars[%d])',
        [I,J,J+1,J+2,J+3]));
    end;
    SL.Add('#define uFootYawW uScalars[32]');
    for Side:=0 to 1 do
      SL.Add(Format('#define uClavicleQ%d vec4(uScalars[%d],uScalars[%d],uScalars[%d],uScalars[%d])',
        [Side,35+Side*4,36+Side*4,37+Side*4,38+Side*4]));
    SL.Add('#define uFootYawXYZ uVecs[7]');
    SL.Add('#define uBB uVecs[0]');
    SL.Add('#define uCrankR uVecs[1]');
    SL.Add('#define uCrankL uVecs[2]');
    SL.Add('#define uGripR uVecs[3]');
    SL.Add('#define uGripL uVecs[4]');
    SL.Add('#define uLegFreePosR uVecs[5]');
    SL.Add('#define uLegFreePosL uVecs[6]');
    SL.Add('');

    { хелперы (конвенции кватернионов = TripoRig: Hamilton, qrot = q*v*q') }
    SL.Add('vec4 qmul(vec4 a, vec4 b) {');
    SL.Add('  return vec4(');
    SL.Add('    a.w*b.x + a.x*b.w + a.y*b.z - a.z*b.y,');
    SL.Add('    a.w*b.y - a.x*b.z + a.y*b.w + a.z*b.x,');
    SL.Add('    a.w*b.z + a.x*b.y - a.y*b.x + a.z*b.w,');
    SL.Add('    a.w*b.w - a.x*b.x - a.y*b.y - a.z*b.z);');
    SL.Add('}');
    SL.Add('vec3 gskQRot(vec4 q, vec3 v) { return v + 2.0*cross(q.xyz, cross(q.xyz, v) + q.w*v); }');
    SL.Add('vec4 gskQConj(vec4 q) { return vec4(-q.xyz, q.w); }');
    SL.Add('vec4 gskQAA(vec3 ax, float ang) { float h = 0.5*ang; return vec4(ax*sin(h), cos(h)); }');
    SL.Add('vec4 gskQFromTo(vec3 a, vec3 b) {');   { shortest arc, порт QuatFromTo }
    SL.Add('  a = normalize(a); b = normalize(b);');
    SL.Add('  float d = dot(a, b);');
    SL.Add('  if (d >= 0.999999) return vec4(0.0,0.0,0.0,1.0);');
    SL.Add('  if (d <= -0.999999) {');
    SL.Add('    vec3 ax = cross(vec3(1.0,0.0,0.0), a);');
    SL.Add('    if (length(ax) < 1e-6) ax = cross(vec3(0.0,1.0,0.0), a);');
    SL.Add('    return vec4(normalize(ax), 0.0);');
    SL.Add('  }');
    SL.Add('  vec3 ax = cross(a, b);');
    SL.Add('  float s = sqrt((1.0 + d) * 2.0);');
    SL.Add('  return vec4(ax / s, s * 0.5);');
    SL.Add('}');
    SL.Add('mat4 gskTrs(vec4 q, vec3 t) {');   { column-major, = Mat4FromQuat + трансляция }
    SL.Add('  float x = q.x, y = q.y, z = q.z, w = q.w;');
    SL.Add('  float n = length(q); if (n < 1e-6) return mat4(1.0);');
    SL.Add('  x/=n; y/=n; z/=n; w/=n;');
    SL.Add('  return mat4(');
    SL.Add('    1.0-2.0*(y*y+z*z), 2.0*(x*y+z*w),     2.0*(x*z-y*w),     0.0,');
    SL.Add('    2.0*(x*y-z*w),     1.0-2.0*(x*x+z*z), 2.0*(y*z+x*w),     0.0,');
    SL.Add('    2.0*(x*z+y*w),     2.0*(y*z-x*w),     1.0-2.0*(x*x+y*y), 0.0,');
    SL.Add('    t.x, t.y, t.z, 1.0);');
    SL.Add('}');
    SL.Add('mat4 gskDMat(vec4 q, vec3 t, vec4 qb, vec3 tb) {');  { D = W * inv(Wbind) }
    SL.Add('  vec4 dq = qmul(q, gskQConj(qb));');
    SL.Add('  return gskTrs(dq, t - gskQRot(dq, tb));');
    SL.Add('}');
    SL.Add('vec3 gskSolveJoint(vec3 root, vec3 target, float L1, float L2, vec3 hint, float softReach) {');
    SL.Add('  vec3 rt = target - root; float d = length(rt);');
    SL.Add('  if (d < 1e-6) return root + vec3(0.0, L1, 0.0);');
    SL.Add('  vec3 dir = rt / d;');
    SL.Add('  if (softReach > 0.0 && d > L1 + L2 - softReach) {');
    SL.Add('    float over = d - (L1 + L2 - softReach);');
    SL.Add('    d = L1 + L2 - softReach + over / (1.0 + over / softReach);');
    SL.Add('  }');
    SL.Add('  d = min(d, L1+L2-1e-5); d = max(d, abs(L1-L2)+1e-5);');
    SL.Add('  float a = (d*d + L1*L1 - L2*L2) / (2.0*d);');
    SL.Add('  float h = sqrt(max(L1*L1 - a*a, 0.0));');
    SL.Add('  vec3 base = root + dir*a;');
    SL.Add('  vec3 perp = hint - dir*dot(dir, hint);');
    SL.Add('  if (length(perp) < 1e-6) {');
    SL.Add('    perp = cross(dir, vec3(0.0,0.0,1.0));');
    SL.Add('    if (length(perp) < 1e-6) perp = cross(dir, vec3(0.0,1.0,0.0));');
    SL.Add('  }');
    SL.Add('  return base + normalize(perp)*h;');
    SL.Add('}');
    SL.Add('float gskAnkleCurve(float crankDeg) {');   { порт BicycleAnkleFlexCurve (BikeGfxUtil) }
    SL.Add('  float A = mod(crankDeg, 360.0); if (A < 0.0) A += 360.0;');
    SL.Add('  float S = cos(radians(A-' + GNum(ANKLE_CURVE_PHASE1) + ')) + 0.25*cos(radians(2.0*(A-' + GNum(ANKLE_CURVE_PHASE2) + ')));');
    SL.Add('  return S >= 0.0 ? uAnkleFlex*(S/' + GNum(ANKLE_CURVE_POS_PEAK) + ') : uAnkleFlex*(S/' + GNum(ANKLE_CURVE_NEG_PEAK) + ');');
    SL.Add('}');
    SL.Add('');

    { ── bind-константы ── }
    if LegOk[0] then
    begin
      Contact := FRider.GpuContactLocal(0);
      EmitLimbConsts('gskLGR_', LegIdx[0,0], LegIdx[0,1], LegIdx[0,2], Contact);
    end;
    if LegOk[1] then
    begin
      Contact := FRider.GpuContactLocal(1);
      EmitLimbConsts('gskLGL_', LegIdx[1,0], LegIdx[1,1], LegIdx[1,2], Contact);
    end;
    HintV := FRider.LegPlaneHint;
    EmitConst('gskLHINT', V3(HintV.X, HintV.Y, HintV.Z));
    HintV := FRider.ArmPlaneHint;
    EmitConst('gskAHINT', V3(HintV.X, HintV.Y, HintV.Z));
    HintV := FRider.LeanAxis;
    EmitConst('gskLEAN', V3(HintV.X, HintV.Y, HintV.Z));
    HintV := FRider.FlareAxis;
    EmitConst('gskFLARE', V3(HintV.X, HintV.Y, HintV.Z));
    { Rest stretch = BindWorld × fileIBM. Live uniform: HeightK updates
      uGskRest without recompiling this giant if-chain (that froze the UI). }
    SL.Add('mat4 gskRest(int j) {');
    SL.Add('  if (j < 0 || j >= ' + IntToStr(NJ) + ') return mat4(1.0);');
    SL.Add('  return uGskRest[j];');
    SL.Add('}');

    { позвоночник: ротации const; позиции/оффсеты с uBindT }
    for I := 0 to RiderSpineChainCount-1 do
      if FSpineEx[I] then
      begin
        SL.Add('#define gskSPP' + IntToStr(I) + ' uBindT[' + IntToStr(SpineIdx[I]) + ']');
        EmitConstQ('gskSPR' + IntToStr(I), BindRot(SpineIdx[I]));
        P := Rig.JointParent[SpineIdx[I]];
        SpIdx := -1;
        for J := 0 to RiderSpineChainCount-1 do if SpineIdx[J] = P then SpIdx := J;
        if SpIdx >= 0 then
          SL.Add('#define gskSPO' + IntToStr(I) + ' gskQRot(gskQConj(gskSPR' + IntToStr(SpIdx) +
            '), uBindT[' + IntToStr(SpineIdx[I]) + ']-uBindT[' + IntToStr(P) + '])')
        else if P >= 0 then
        begin
          EmitConstQ('gskSPPR' + IntToStr(I), BindRot(P));
          SL.Add('#define gskSPO' + IntToStr(I) + ' gskQRot(gskQConj(gskSPPR' + IntToStr(I) +
            '), uBindT[' + IntToStr(SpineIdx[I]) + ']-uBindT[' + IntToStr(P) + '])');
        end
        else
          EmitConst('gskSPO' + IntToStr(I), BindLocalTrans(SpineIdx[I]));
      end;
    { ключицы/руки: ротации const; позиции/оффсеты с uBindT }
    for Side := 0 to 1 do
      if ArmOk[Side] then
      begin
        S := 'gskAC' + IntToStr(Side) + '_';
        EmitConstQ(S + 'CR', BindRot(ArmIdx[Side,0]));
        if ClavParentSpine[Side] >= 0 then
          EmitConstQ(S + 'PR', BindRot(SpineIdx[ClavParentSpine[Side]]))
        else
          EmitConstQ(S + 'PR', BindRot(ArmIdx[Side,0]));
        SL.Add('#define ' + S + 'CP uBindT[' + IntToStr(ArmIdx[Side,0]) + ']');
        P := Rig.JointParent[ArmIdx[Side,0]];
        if P >= 0 then
          SL.Add('#define ' + S + 'CO gskQRot(gskQConj(' + S + 'PR), uBindT[' +
            IntToStr(ArmIdx[Side,0]) + ']-uBindT[' + IntToStr(P) + '])')
        else
          EmitConst(S + 'CO', BindLocalTrans(ArmIdx[Side,0]));
        SL.Add('#define ' + S + 'AO gskQRot(gskQConj(' + S + 'CR), uBindT[' +
          IntToStr(ArmIdx[Side,1]) + ']-uBindT[' + IntToStr(ArmIdx[Side,0]) + '])');
        RiderHandAxes(Rig,Side,FShArms[Side].HandForward,FShArms[Side].HandPalm);
        Contact := FRider.GpuContactLocal(2 + Side);
        EmitLimbConsts(S + 'A_', ArmIdx[Side,1], ArmIdx[Side,2], ArmIdx[Side,3], Contact);
      end;
    SL.Add('');

    { ── этап 5: те же bind-константы — в поля для аналитической тени ── }
    for Side := 0 to 1 do
      if LegOk[Side] then
        with FShLegs[Side] do
        begin
          Ok := True;
          HP := BindPos(LegIdx[Side,0]);  UR := BindRot(LegIdx[Side,0]);
          AXM := V3Norm(LocalOff(LegIdx[Side,0], LegIdx[Side,1]));
          MR := BindRot(LegIdx[Side,1]);
          AXE := V3Norm(LocalOff(LegIdx[Side,1], LegIdx[Side,2]));
          ER := BindRot(LegIdx[Side,2]);
          Contact := FRider.GpuContactLocal(Side);
          CT := V3(Contact.X, Contact.Y, Contact.Z);
          L1 := BoneLen(LegIdx[Side,0], LegIdx[Side,1]);
          L2 := BoneLen(LegIdx[Side,1], LegIdx[Side,2]);
        end;
    HintV := FRider.LegPlaneHint;
    FShLegHint := V3(HintV.X, HintV.Y, HintV.Z);
    HintV := FRider.ArmPlaneHint;
    FShArmHint := V3(HintV.X, HintV.Y, HintV.Z);
    HintV := FRider.LeanAxis;
    FShLean := V3(HintV.X, HintV.Y, HintV.Z);
    HintV := FRider.FlareAxis;
    FShFlare := V3(HintV.X, HintV.Y, HintV.Z);
    for I := 0 to RiderSpineChainCount-1 do
      if FSpineEx[I] then
        with FShSpine[I] do
        begin
          Ex := True;
          PP := BindPos(SpineIdx[I]);
          PR := BindRot(SpineIdx[I]);
          ParentInChain := False;
          ParentSpine := -1;
          P := Rig.JointParent[SpineIdx[I]];
          for J := 0 to RiderSpineChainCount-1 do
            if SpineIdx[J] = P then
            begin
              ParentInChain := True;
              ParentSpine := J;
            end;
          if ParentInChain then PO := LocalOff(P, SpineIdx[I]);
        end;
    for Side := 0 to 1 do
      if ArmOk[Side] then
        with FShArms[Side] do
        begin
          Ok := True;
          CP := BindPos(ArmIdx[Side,0]);  CR := BindRot(ArmIdx[Side,0]);
          CO := LocalOff(Rig.JointParent[ArmIdx[Side,0]], ArmIdx[Side,0]);
          AO := LocalOff(ArmIdx[Side,0], ArmIdx[Side,1]);
          ClavInSpine := ClavParentSpine[Side] >= 0;
          ParentSpine := ClavParentSpine[Side];
          if ClavInSpine then PR := BindRot(SpineIdx[ClavParentSpine[Side]])
          else PR := CR;
          UR := BindRot(ArmIdx[Side,1]);
          AXM := V3Norm(LocalOff(ArmIdx[Side,1], ArmIdx[Side,2]));
          MR := BindRot(ArmIdx[Side,2]);
          AXE := V3Norm(LocalOff(ArmIdx[Side,2], ArmIdx[Side,3]));
          ER := BindRot(ArmIdx[Side,3]);
          Contact := FRider.GpuContactLocal(2 + Side);
          CT := V3(Contact.X, Contact.Y, Contact.Z);
          L1 := BoneLen(ArmIdx[Side,1], ArmIdx[Side,2]);
          L2 := BoneLen(ArmIdx[Side,2], ArmIdx[Side,3]);
        end;
    { bind-позиции всех суставов тени + предок головы в цепи позвоночника }
    for I := 0 to GPU_SHJ_COUNT - 1 do
    begin
      J := Rig.JointIndexByName(SHJ_NAMES[I]);
      FShEx[I] := J >= 0;
      if FShEx[I] then FShBind[I] := BindPos(J)
      else FShBind[I] := V3(0, 0, 0);
    end;
    FShHeadAnc := -1;
    J := Rig.JointIndexByName('Head');
    if J >= 0 then
    begin
      P := J;
      while (P >= 0) and (FShHeadAnc < 0) do
      begin
        for I := 0 to RiderSpineChainCount-1 do
          if SpineIdx[I] = P then FShHeadAnc := I;
        P := Rig.JointParent[P];
      end;
    end;

    { ── позвоночник: FK-цепочка с кватернионами из uSpineQ* ── }
    SL.Add(Format('vec4 gskSpineR[%d]; vec3 gskSpineP[%d];',
      [RiderSpineChainCount,RiderSpineChainCount]));
    SL.Add('void gskSolveSpine() {');

    for I := 0 to RiderSpineChainCount-1 do
      if FSpineEx[I] then
      begin
        P := Rig.JointParent[SpineIdx[I]];
        SpIdx := -1;
        for J := 0 to RiderSpineChainCount-1 do if SpineIdx[J] = P then SpIdx := J;
        if SpIdx >= 0 then
        begin
          { родитель — сустав той же цепи: его текущие r/p уже посчитаны }
          SL.Add('  vec4 r' + IntToStr(I) + ' = uSpineQ' + IntToStr(I) + ';');
          SL.Add('  vec3 p' + IntToStr(I) + ' = p' + IntToStr(SpIdx) +
            ' + gskQRot(r' + IntToStr(SpIdx) + ', gskSPO' + IntToStr(I) + ');');
        end
        else
        begin
          { родитель вне цепи (таз и т.п.) — не анимируется: база = bind }
          SL.Add('  vec4 r' + IntToStr(I) + ' = uSpineQ' + IntToStr(I) + ';');
          SL.Add('  vec3 p' + IntToStr(I) + ' = gskSPP' + IntToStr(I) + ';');
        end;
      end;
    for I := 0 to RiderSpineChainCount-1 do
      if FSpineEx[I] then
      begin
        SL.Add('  gskSpineR[' + IntToStr(I) + '] = r' + IntToStr(I) + ';');
        SL.Add('  gskSpineP[' + IntToStr(I) + '] = p' + IntToStr(I) + ';');
      end;
    SL.Add('}');
    SL.Add('void gskSpineRP(int idx, out vec4 r, out vec3 p) {');
    SL.Add('  r = gskSpineR[idx]; p = gskSpineP[idx];');
    SL.Add('}');
    SL.Add('mat4 gskSpineD(int idx) {');
    SL.Add('  vec4 r; vec3 p; gskSpineRP(idx, r, p);');
    for I := 0 to RiderSpineChainCount-1 do
      if FSpineEx[I] then
        SL.Add('  if (idx == ' + IntToStr(I) + ') return gskDMat(r, p, gskSPR' + IntToStr(I) + ', gskSPP' + IntToStr(I) + ');');
    SL.Add('  return mat4(1.0);');
    SL.Add('}');

    { ── база рук: ключица (+ shoulder round) и плечо из цепи позвоночника ── }
    for Side := 0 to 1 do
      if ArmOk[Side] then
      begin
        S := 'gskAC' + IntToStr(Side) + '_';
        SL.Add('void gskArmBase' + IntToStr(Side) + '(out vec4 qSh, out vec3 pSh, out mat4 dCl) {');
        if ClavParentSpine[Side] >= 0 then
        begin
          SL.Add('  vec4 rb; vec3 pb; gskSpineRP(' + IntToStr(ClavParentSpine[Side]) + ', rb, pb);');
          SL.Add('  vec4 chest = qmul(rb,gskQConj(' + S + 'PR));');
          SL.Add('  vec4 qCl = qmul(chest,qmul(uClavicleQ' + IntToStr(Side) + ',' + S + 'CR));');
          SL.Add('  vec3 pCl = pb + gskQRot(rb, ' + S + 'CO);');
        end
        else
        begin
          { родитель ключицы вне цепи позвоночника — не анимируется: база = bind }
          SL.Add('  vec4 qCl = qmul(uClavicleQ' + IntToStr(Side) + ',' + S + 'CR);');
          SL.Add('  vec3 pCl = ' + S + 'CP;');
        end;
        SL.Add('  dCl = gskDMat(qCl, pCl, ' + S + 'CR, ' + S + 'CP);');
        SL.Add('  qSh = qmul(qCl, qmul(gskQConj(' + S + 'CR), ' + S + 'A_UR));');
        SL.Add('  pSh = pCl + gskQRot(qCl, ' + S + 'AO);');
        SL.Add('}');
      end;

    AppendRiderGripGlsl(SL);
    { ── решатели конечностей ── }
    if LegOk[0] then EmitLegSolve('gskLegD_R', 'gskLGR_', 'uCrankR', +1);
    if LegOk[1] then EmitLegSolve('gskLegD_L', 'gskLGL_', 'uCrankL', -1);
    if ArmOk[0] then EmitArmSolve('gskArmD_R', 'gskAC0_A_', 'gskArmBase0', 'uGripR', 'uPronR', +1);
    if ArmOk[1] then EmitArmSolve('gskArmD_L', 'gskAC1_A_', 'gskArmBase1', 'uGripL', 'uPronL', -1);

    { ── getD: отображение индекса сустава в дельта-матрицу ── }
    SL.Add('mat4 gskDelta[22];');
    { Keep the dynamically indexed matrix bank small. A quaternion and pivot
      are enough; construct a twist matrix only for a vertex using a helper. }
    SL.Add('vec4 gskForeRoll[2];');
    SL.Add('vec3 gskForePivot[2];');
    SL.Add('mat4 gskTwistD(int kind, int part) {');
    SL.Add('  int side=kind-4; vec4 q=gskForeRoll[side];');
    SL.Add('  if(part==4) q=normalize(vec4(q.xyz,q.w+1.0));');
    SL.Add('  vec3 p=gskForePivot[side];');
    SL.Add('  return gskDMat(q,p,vec4(0.0,0.0,0.0,1.0),p)*gskDelta[side==0?14:18];');
    SL.Add('}');
    if FRider.Face<>nil then SL.Add(FRider.Face.ShaderSource)
    else SL.Add('mat4 riderFaceDelta(int j){return mat4(1.0);}');
    SL.Add('mat4 gskGetD(int j) {');
    SL.Add('  int routing = uGskJointCode[j]; int handSlot=routing/64; int code=routing-handSlot*64;');
    SL.Add('  if (code == 0) return gskRest(j);');
    SL.Add('  int kind = code / 8; int part = code - kind*8;');
    SL.Add('  int slot = kind == 1 ? 1 : (kind == 2 ? 4 : (kind == 3 ? (part<5 ? 7 : 15) : (kind == 4 ? 12 : 16)));');
    SL.Add('  if (kind >= 4 && part >= 4) return gskTwistD(kind,part) * gskRest(j);');
    SL.Add('  mat4 hand = mat4(1.0);');
    SL.Add('  if (kind >= 4 && part == 3 && uScalars[33 + kind - 4] > 0.5) hand = uGskHandRest[handSlot];');
    SL.Add('  return gskDelta[slot + part] * hand * gskRest(j) * riderFaceDelta(j);');
    SL.Add('}');

    { ── plug: LBS по 4 влияниям ── }
    if FRider.Correctives <> nil then
    begin
      { Corrective joints are fixed for this model. Resolve their matrix
        slots here instead of duplicating dynamic skeleton routing in each
        corrective expression (very expensive for the GLSL compiler). }
      SL.Add('float gskPsdLocalComponent(mat3 childDelta, mat3 parentDelta, mat3 bindRot,int axis) {');
      SL.Add('  mat3 d=transpose(bindRot)*transpose(parentDelta)*childDelta*bindRot;');
      SL.Add('  if(axis==1)return atan(-d[0][2],length(d[0].xy));');
      SL.Add('  if(axis==2)return atan(d[0][1],d[0][0]);');
      SL.Add('  return atan(d[1][2], d[2][2]);');
      SL.Add('}');
      SL.Add('float riderPsdComponent(int j,int axis) {');
      for I := 0 to NJ - 1 do
        if FRider.Correctives.NeededJoints[I] then
        begin
          RestM := Mat4FromQuat(BindRot(I));
          S := 'mat3(';
          for J := 0 to 8 do
          begin
            if J > 0 then S := S + ',';
            S := S + GNum(RestM[(J div 3)*4 + J mod 3]);
          end;
          SL.Add('  if(j==' + IntToStr(I) + ') return gskPsdLocalComponent(' +
            PsdRotation(I) + ',' + PsdRotation(Rig.JointParent[I]) + ',' + S + '),axis);');
        end;
      SL.Add('  return 0.0;'); SL.Add('}');
      SL.Add(FRider.Correctives.ShaderSource);
      if FRider.Correctives.Body<>nil then SL.Add(FRider.Correctives.Body.ShaderSource('gskGetD'));
    end;
    SL.Add('void PLUG_vertex_object_space(inout vec4 vertex, inout vec3 normal) {');
    SL.Add('  vec4 W = castle_SkinWeights0;');
    SL.Add('  if (dot(W, vec4(1.0)) < 1e-6) return;');
    SL.Add('  ivec4 J = ivec4(castle_SkinJoints0 + vec4(0.5));');
    { Each limb has one solver call site per vertex. Weighted joints only
      select its results, avoiding repeated inlining of the entire solver. }
    SL.Add('  bool need[6]; bool armLimb[2];');
    SL.Add('  for (int k = 0; k < 6; k++) need[k] = false;');
    SL.Add('  armLimb[0] = false; armLimb[1] = false;');
    if FRider.Correctives <> nil then
    begin
      SL.Add('  int psdMask=int(riderPsdSpan.z+0.5);');
      if FRider.Correctives.Body<>nil then
      begin
        SL.Add('  int tissueMask=int(riderTissue.w+0.5);');
        SL.Add('  int combined=0;int bitValue=1;for(int bit=0;bit<5;bit++){if(mod(float(psdMask/bitValue),2.0)>0.5 || mod(float(tissueMask/bitValue),2.0)>0.5)combined+=bitValue;bitValue*=2;}psdMask=combined;');
      end;
      SL.Add('  need[1] = (psdMask - (psdMask/2)*2) != 0;');
      SL.Add('  need[2] = ((psdMask/2) - (psdMask/4)*2) != 0;');
      SL.Add('  need[3] = ((psdMask/4) - (psdMask/8)*2) != 0;');
      SL.Add('  need[4] = ((psdMask/8) - (psdMask/16)*2) != 0;');
      SL.Add('  need[5] = ((psdMask/16) - (psdMask/32)*2) != 0;');
      SL.Add('  armLimb[0] = need[4]; armLimb[1] = need[5];');
    end;
    SL.Add('  for (int i = 0; i < uGskIterations[2]; i++) {');
    SL.Add('    if (W[i] <= 0.0) continue;');
    SL.Add('    int routing = uGskJointCode[J[i]]; int code=routing-(routing/64)*64; int kind = code / 8;');
    SL.Add('    need[kind] = true;');
    SL.Add('    if (kind >= 4 && code - kind*8 > 0) armLimb[kind-4] = true;');
    SL.Add('  }');
    SL.Add('  if (need[3] || need[4] || need[5]) gskSolveSpine();');
    if LegOk[0] then
      SL.Add('  if (need[1]) gskLegD_R(gskDelta[1], gskDelta[2], gskDelta[3]);');
    if LegOk[1] then
      SL.Add('  if (need[2]) gskLegD_L(gskDelta[4], gskDelta[5], gskDelta[6]);');
    SL.Add('  if (need[3]) {');
    for I := 0 to RiderSpineChainCount-1 do
      if FSpineEx[I] then
        SL.Add('    gskDelta[' + IntToStr(SpineMatrixSlot(I)) + '] = gskSpineD(' + IntToStr(I) + ');');
    SL.Add('  }');
    if ArmOk[0] then
      SL.Add('  if (need[4]) gskArmD_R(armLimb[0], gskDelta[12], gskDelta[13], gskDelta[14], gskDelta[15], gskForeRoll[0], gskForePivot[0]);');
    if ArmOk[1] then
      SL.Add('  if (need[5]) gskArmD_L(armLimb[1], gskDelta[16], gskDelta[17], gskDelta[18], gskDelta[19], gskForeRoll[1], gskForePivot[1]);');
    if (FRider.Correctives<>nil)and(FRider.Correctives.Body<>nil)then
    begin
      SL.Add('vec3 psdP,psdN;riderPsdOffset(psdP,psdN);vec3 p=castle_Vertex.xyz+psdP;');
      SL.Add('#ifdef RIDER_SURFACE_MOTION');SL.Add('p+=riderSurfaceOffset();');SL.Add('#endif');
      SL.Add('vec3 n=vec3(0.0,1.0,0.0);');
      SL.Add('#if !defined(CASTLE_SHADOW_DEPTH) || defined(CASTLE_CACHE_DEFORMATION)');
      SL.Add('n=castle_Normal+psdN;');SL.Add('#endif');
      SL.Add('vec3 outP,outN;bodyDeform(p,n,W,J,outP,outN);vertex=vec4(outP,1.0);normal=outN;');
    end else begin
    { Zero-weight joints do not contribute and need no procedural solve. }
    SL.Add('  mat4 M = mat4(0.0);');
    SL.Add('  for (int influence = 0; influence < uGskIterations[2]; influence++)');
    SL.Add('    if (W[influence] > 0.0) M += W[influence]*gskGetD(J[influence]);');
    { отмотка движкового скиннинга + наш LBS (комментарий — только здесь,
      в GLSL-строке { } это БРАСЫ, а не комментарий!) }
    SL.Add('#if defined(CASTLE_SHADOW_DEPTH) && !defined(CASTLE_CACHE_DEFORMATION)');
    SL.Add('  vertex = M * castle_Vertex;');
    SL.Add('#ifdef RIDER_SURFACE_MOTION');
    SL.Add('  vertex += M * vec4(riderSurfaceOffset(),0.0);');
    SL.Add('#endif');
    SL.Add('#else');
    SL.Add('  mat4 C = M * inverse(skinMatrix);');
    SL.Add('  vertex = C * vertex;');
    SL.Add('  normal = mat3(C) * normal;');
    SL.Add('#endif');
    if FRider.Correctives <> nil then
    begin
      SL.Add('  vec3 psdP, psdN; riderPsdOffset(psdP, psdN);');
      SL.Add('  vertex += M * vec4(psdP, 0.0);');
      SL.Add('  normal += mat3(M) * psdN;');
    end;
    end;
    SL.Add('}');

    PartV := TEffectPartNode.Create;
    PartV.FdType.Value := 'VERTEX';
    PartV.Contents := SL.Text;
    FEffect.FdParts.Add(PartV);
    ShareRiderEffect(FEffect);
    { дамп сгенерированного GLSL — отладка compile/link (пурпурный меш =
      шейдер не собрался; текст ошибки идёт в [castle:*] через OnWarning).
      Только при BikeDumpShaders — запись на диск в горячем пути билда. }
    if BikeDumpShaders then
      try
        ForceDirectories(ExtractFilePath(ParamStr(0)) + 'logs');
        SL.SaveToFile(ExtractFilePath(ParamStr(0)) + 'logs' + PathDelim + 'gpu_skin.vs');
      except
        { дамп — диагностика, не повод падать }
      end;
  finally
    SL.Free;
  end;

  { ── навеска на шейпы скина ── }
  Apps := TList.Create;
  try
    if (FRider.Scene <> nil) then
      FRider.Scene.BeginChangesSchedule;
    try
      for I := 0 to FRider.SkinNode.FdShapes.Count - 1 do
        if FRider.SkinNode.FdShapes[I] is TShapeNode then
        begin
          ShapeNode := TShapeNode(FRider.SkinNode.FdShapes[I]);
          App := ShapeNode.Appearance;
          if (App = nil) or (Apps.IndexOf(App) >= 0) then Continue;
          Apps.Add(App);
          { Cloth displaces the posed surface. Keep it after GPU skinning,
            just as after the native corrective effect in walking mode. }
          J:=0;
          while(J<App.FdEffects.Count)and
            (App.FdEffects[J].X3DName<>'AvatarFreeCloth')and
            (App.FdEffects[J].X3DName<>'AvatarSolvedCloth')do Inc(J);
          App.FdEffects.Add(J,FEffect);
        end;
    finally
      if (FRider.Scene <> nil) then
        FRider.Scene.EndChangesSchedule;
    end;
    J := Apps.Count;   { запоминаем ДО Free — для итогового лога }
  finally
    Apps.Free;
  end;
  { FdEffects.Add не проставляет ноду Scene, а без неё TX3DField.Changed
    молчит (Parent.Scene=nil) и uniform'ы не доходят до GPU — тот же корень,
    что в этапе 4 у TGpuBikeSpin. Без этого GpuAnim=True со старта рисовал
    райдера дефолтными uniform'ами (тёмный «взорвавшийся» меш на весь экран);
    после toggle CPU→GPU шейдер перелинковывался и заливал текущие значения —
    поэтому раньше баг не проявлялся. }
  FEffect.Scene := FRider.Scene;
  FRider.Scene.ProcessEvents := True;   { Send() uniform'ов должен доходить до GPU }
  FReady := True;
  FLastValid := False;   { первый SendFrame после Build обязан послать все uniform'ы }
  UploadBindUniforms;    { fill uGskRest / uBindT now that Scene is set }
  Result := True;
  if BikeDumpShaders then
    StartupLog(Format('[gpu-skin] built: %d joints, %d shape(s), GLSL -> logs%sgpu_skin.vs',
      [NJ, J, PathDelim]))
  else
    StartupLog(Format('[gpu-skin] built: %d joints, %d shape(s)', [NJ, J]));
end;

procedure TGpuRiderSkin.UpdateShadowSpine;
var
  I, ci, ri: Integer;
  dq: TTripoVec4;
  Mh: TTripoMat4;
  SM: TMatrix4;
begin
  { стартовое заполнение — bind (суставы вне процедурных цепей: таз, пальцы…);
    делается здесь, а не в UpdateShadowLimbs: конечности перезаписывают свои
    слоты при ленивом пересчёте, а bind-заполнение обязано быть свежим кадра }
  CountRiderWork(rwSpineFK);
  for I := 0 to GPU_SHJ_COUNT - 1 do FShRigPts[I] := FShBind[I];

  { ── спина: FK-цепь, зеркало gskSpineRP ── }
  for I := 0 to RiderSpineChainCount-1 do
    if FShSpine[I].Ex then
      with FShSpine[I] do
      begin
        if ParentInChain then
        begin
          FShRS[I] := QuatMul(FShRS[ParentSpine], QuatMul(QuatConj(FShSpine[ParentSpine].PR),
            QuatMul(FShDelta[I], PR)));
          FShPS[I] := V3Add(FShPS[ParentSpine], QuatRotateV3(FShRS[ParentSpine], PO));
        end
        else
        begin
          FShRS[I] := QuatMul(FShDelta[I], PR);
          FShPS[I] := PP;
        end;
        if I<5 then FShRigPts[SHJ_WAIST + I] := FShPS[I];
      end;

  { Head/helmet use the same complete cervical chain as the skin shader. }
  if FShEx[SHJ_HEAD] and (FShHeadAnc >= 0) and FShSpine[FShHeadAnc].Ex then
  begin
    dq := QuatMul(FShRS[FShHeadAnc], QuatConj(FShSpine[FShHeadAnc].PR));
    FShRigPts[SHJ_HEAD] := V3Add(FShPS[FShHeadAnc],
      QuatRotateV3(dq, V3Sub(FShBind[SHJ_HEAD], FShSpine[FShHeadAnc].PP)));
    { шлем следует за головой (этап 3): та же дельта-матрица предка, что у
      шейдера (gskDMat(r, p, SPR, SPP)); без этого шлем висел в позе
      застывших joint-нод, пока голова ездит в шейдере }
    Mh := Mat4FromTRS(V3Sub(FShPS[FShHeadAnc], QuatRotateV3(dq, FShSpine[FShHeadAnc].PP)),
      dq, V3(1, 1, 1));
    for ci := 0 to 3 do for ri := 0 to 3 do SM.Data[ci, ri] := Mh[ci * 4 + ri];
    FRider.ApplyHelmetSkinMatrix(SM);
  end;
end;

procedure TGpuRiderSkin.UpdateShadowLimbs;
var
  GripFrame:TRiderGripFrame;
  M: TMatrix4;
  I, Side, Pass: Integer;
  Crk, Pedal, TgtV, GripV: TVector3;
  AngRad, Ca, Sa, FlexRad, CrankAng, Reach, Sl, Pron: Single;
  FreeF, Ptv, Hang, Hs: Single;
  Tgt, Hint, Root, Aim, Mid, UDir, MDir, NewAim, Sv, FoAxis: TTripoVec3;
  DirH, AxL, ContactLower, ContactAxis: TTripoVec3;
  ContactLength: Single;
  pM, pCl, pSh, Pb, HandPos, RequestedAim: TTripoVec3;
  qU, qU0, qM, qE, qMpre, qEnat, qCl, Rb, FootTurn: TTripoVec4;
begin
  CountRiderWork(rwLimbIK);
  AngRad := FShInPedalDir * FShInPhase * 2 * Pi;
  Ca := Cos(AngRad);  Sa := Sin(AngRad);

  { ── ноги: зеркало EmitLegSolve (3 уточнения контакта + финальный IK) ── }
  for Side := 0 to 1 do
    if FShLegs[Side].Ok then
      with FShLegs[Side] do
      begin
        if Side = 0 then Crk := FShInCrankR else Crk := FShInCrankL;
        Pedal := FShInOBB + Vector3(Crk.X * Ca - Crk.Y * Sa, Crk.X * Sa + Crk.Y * Ca,
          FShInStanceZ * (1 - 2 * Side));   { R: +Z, L: -Z }
        { free-нога: зеркало mix(pedal, uLegFreePos*, free) из EmitLegSolve }
        if Side = 0 then
        begin
          FreeF := FShInPose.LegFreeR;
          if FreeF < 0 then FreeF := 0 else if FreeF > 1 then FreeF := 1;
          Pedal := Pedal + (FShInFreeR - Pedal) * FreeF;
        end
        else
        begin
          FreeF := FShInPose.LegFreeL;
          if FreeF < 0 then FreeF := 0 else if FreeF > 1 then FreeF := 1;
          Pedal := Pedal + (FShInFreeL - Pedal) * FreeF;
        end;
        TgtV := FShInInvP.MultPoint(Pedal);
        Tgt := V3(TgtV.X, TgtV.Y, TgtV.Z);
        FlexRad := 0;
        if Abs(FShInPose.AnkleFlex) > 0.001 then
        begin
          CrankAng := ArcTan2(Crk.Y, Crk.X) + AngRad;
          FlexRad := -DegToRad(BicycleAnkleFlexCurve(90.0 - RadToDeg(CrankAng), FShInPose.AnkleFlex)) * (1 - FreeF);
        end;
        Hint := FShLegHint;
        if Side = 0 then Hint := V3Add(Hint, V3Scale(FShFlare, FShInPose.KneeFlare))
        else Hint := V3Sub(Hint, V3Scale(FShFlare, FShInPose.KneeFlare));
        Root := HP;  Aim := Tgt;
        pM := V3(0, 0, 0);
        if Side = 0 then FootTurn := FShInFootYaw
        else FootTurn := QuatConj(FShInFootYaw);
        FootTurn := QuatMul(FootTurn,
          QuatFromAxisAngle(FShLean.X, FShLean.Y, FShLean.Z, FlexRad));
        ContactLower := V3Add(V3Scale(AXE, L2),
          QuatRotateV3(QuatMul(QuatConj(MR), ER), CT));
        ContactLength := V3Len(ContactLower);
        ContactAxis := V3Norm(ContactLower);
        for Pass := 0 to 2 do
        begin
          Mid := ShSolveJoint(Root, Aim, L1, ContactLength, Hint,
            0.02 * (L1 + ContactLength));
          UDir := V3Norm(V3Sub(Mid, Root));
          qU := QuatMul(QuatFromTo(QuatRotateV3(UR, AXM), UDir), UR);
          pM := V3Add(Root, V3Scale(UDir, L1));
          qMpre := QuatMul(qU, QuatMul(QuatConj(UR), MR));
          MDir := V3Norm(V3Sub(Aim, pM));
          qM := QuatMul(QuatFromTo(QuatRotateV3(qMpre, ContactAxis), MDir), qMpre);
          qEnat := QuatMul(qM, QuatMul(QuatConj(MR), ER));
          qE := QuatMul(FootTurn, qEnat);
          Aim := V3Add(Tgt, V3Sub(QuatRotateV3(qEnat, CT), QuatRotateV3(qE, CT)));
        end;
        Aim := V3Sub(Tgt, QuatRotateV3(qE, CT));
        Mid := ShSolveJoint(Root, Aim, L1, L2, Hint);
        UDir := V3Norm(V3Sub(Mid, Root));
        pM := V3Add(Root, V3Scale(UDir, L1));
        MDir := V3Norm(V3Sub(Aim, pM));
        Aim := V3Add(pM, V3Scale(MDir, L2));
        FShRigPts[SHJ_THIGH_R + Side] := Root;
        FShRigPts[SHJ_CALF_R + Side] := pM;
        FShRigPts[SHJ_FOOT_R + Side] := Aim;
        Sv := V3Add(Aim, QuatRotateV3(qE, CT));
        FShContacts[Side] := FRider.Scene.Transform.MultPoint(Vector3(Sv.X, Sv.Y, Sv.Z));
      end;

  { ── руки: зеркало gskArmBase* + EmitArmSolve ── }
  for Side := 0 to 1 do
    if FShArms[Side].Ok then
      with FShArms[Side] do
      begin
        if ClavInSpine then
        begin
          Rb := FShRS[ParentSpine];  Pb := FShPS[ParentSpine];
          qCl := QuatMul(Rb,QuatMul(QuatConj(PR),QuatMul(FShClavicleDelta[Side],CR)));
          pCl := V3Add(Pb, QuatRotateV3(Rb, CO));
        end
        else
        begin
          qCl := QuatMul(FShClavicleDelta[Side], CR);
          pCl := CP;
        end;
        qU0 := QuatMul(qCl, QuatMul(QuatConj(CR), UR));
        pSh := V3Add(pCl, QuatRotateV3(qCl, AO));
        if Side = 0 then GripV := FShInGripR else GripV := FShInGripL;
        TgtV := FShInInvP.MultPoint(GripV);
        Tgt := V3(TgtV.X, TgtV.Y, TgtV.Z);
        Hint := FShArmHint;
        if Side = 0 then Hint := V3Add(Hint, V3Scale(FShFlare, FShInPose.ElbowFlare))
        else Hint := V3Sub(Hint, V3Scale(FShFlare, FShInPose.ElbowFlare));
        if Side = 0 then Pron := FShInPose.ArmPronationR
        else Pron := FShInPose.ArmPronationL;
        if Side=0 then GripFrame:=FShInPose.HandFrameR else GripFrame:=FShInPose.HandFrameL;
        GripFrame:=TransformGripFrame(GripFrame,FShInInvP);
        Root := pSh;  Aim := Tgt;  Reach := L1 + L2;
        pM := V3(0, 0, 0);
        for Pass := 0 to 7 do
        begin
          RequestedAim := Aim;
          Sv := V3Sub(Aim, Root);  Sl := V3Len(Sv);
          if Sl > Reach * 0.999 then
            Aim := V3Add(Root, V3Scale(Sv, Reach * 0.999 / Sl));
          Mid := ShSolveJoint(Root, Aim, L1, L2, Hint);
          UDir := V3Norm(V3Sub(Mid, Root));
          qU := QuatMul(QuatFromTo(QuatRotateV3(qU0, AXM), UDir), qU0);
          pM := V3Add(Root, V3Scale(UDir, L1));
          qMpre := QuatMul(qU, QuatMul(QuatConj(UR), MR));
          MDir := V3Norm(V3Sub(Aim, pM));
          qM := QuatMul(QuatFromTo(QuatRotateV3(qMpre, AXE), MDir), qMpre);
          qEnat := QuatMul(qM, QuatMul(QuatConj(MR), ER));
          FoAxis := V3Norm(V3Sub(Aim, pM));
          qE:=RiderGripPoseOrientation(qEnat,FShGripTarget[Side],FoAxis,HandForward,GripFrame.Weight,
            Pron,FShInPose.HandLevel,Side);
          HandPos := V3Add(pM, V3Scale(MDir, L2));
          NewAim := V3Sub(Tgt, QuatRotateV3(qE, CT));
          if V3Len(V3Sub(NewAim, RequestedAim)) < 1e-5 then Break;
          if Pass = 0 then Aim := NewAim
          else Aim := V3Add(Aim, V3Scale(V3Sub(NewAim, Aim), 0.35));
        end;
        FShRigPts[SHJ_CLAV_R + Side] := pCl;
        FShRigPts[SHJ_UPARM_R + Side] := pSh;
        FShRigPts[SHJ_FORE_R + Side] := pM;
        FShRigPts[SHJ_HAND_R + Side] := HandPos;
        FShHandQ[Side]:=qE;
        qEnat:=QuatNormalize(QuatMul(qE,QuatConj(qEnat)));
        if qEnat.W<0 then begin qEnat.X:=-qEnat.X;qEnat.Y:=-qEnat.Y;qEnat.Z:=-qEnat.Z;qEnat.W:=-qEnat.W;end;
        FShHandTwist[Side]:=RadToDeg(2*ArcTan2(V3Dot(V3(qEnat.X,qEnat.Y,qEnat.Z),FoAxis),qEnat.W));
        Sv := V3Add(HandPos, QuatRotateV3(qE, CT));
        FShContacts[2 + Side] := FRider.Scene.Transform.MultPoint(Vector3(Sv.X, Sv.Y, Sv.Z));
      end;

  { ── rig frame -> кадр байка (тот же Transform, что PosedJointParent) ── }
  M := FRider.Scene.Transform;
  for I := 0 to GPU_SHJ_COUNT - 1 do
    FShPts[I] := M.MultPoint(Vector3(FShRigPts[I].X, FShRigPts[I].Y, FShRigPts[I].Z));
  FShValid := True;
end;

function TGpuRiderSkin.SpineSkin(const Name:string;out M:TMatrix4):Boolean;
var I,J:Integer;Q:TTripoVec4;D:TTripoMat4;
begin
  Result:=False;M:=TMatrix4.Identity;
  if not FLastValid or(FRider.Rig=nil)then Exit;
  J:=FRider.Rig.JointIndexByName(Name);
  if(J<0)or(J>=FRestList.Count)then Exit;
  M:=FRestList.Items[J];
  if Name='Pelvis'then Exit(True);
  for I:=0 to RiderSpineChainCount-1 do
    if(Name=RiderSpineChainNames[I])and FSpineEx[I]then begin
      Q:=QuatMul(FShRS[I],QuatConj(FShSpine[I].PR));
      D:=Mat4FromTRS(V3Sub(FShPS[I],QuatRotateV3(Q,FShSpine[I].PP)),Q,V3(1,1,1));
      M:=RestToCastle(D)*M;Exit(True);
    end;
end;

function TGpuRiderSkin.ShadowJoint(const AName: string; out P: TVector3): Boolean;
var I: Integer;
begin
  P := Vector3(0, 0, 0);
  Result := False;
  { ленивый пересчёт (этап 5): тяжёлый IK конечностей — один раз за кадр,
    по первому запросу теневой точки; дальше в кадре — готовые FShPts }
  if FShDirty then
  begin
    UpdateShadowLimbs;
    FShDirty := False;
  end;
  if not FShValid then Exit;
  { кэш имя→индекс: SHJ_NAMES фиксирована, таблица строится один раз
    (было: линейный поиск по строке, ~46 вызовов за кадр из UpdateShadowDynamic) }
  if FShNameIdx = nil then
  begin
    FShNameIdx := TStringList.Create;
    FShNameIdx.CaseSensitive := True;
    for I := 0 to GPU_SHJ_COUNT - 1 do
      FShNameIdx.AddObject(SHJ_NAMES[I], TObject(PtrInt(I)));
    FShNameIdx.Sorted := True;
  end;
  if FShNameIdx.Find(AName, I) then
  begin
    I := PtrInt(FShNameIdx.Objects[I]);
    Result := FShEx[I];
    if Result then P := FShPts[I];
  end;
end;

function TGpuRiderSkin.ShadowContact(Index: Integer; out P: TVector3): Boolean;
var Dummy: TVector3;
begin
  Result := False; P := TVector3.Zero;
  if (Index < 0) or (Index > 3) then Exit;
  ShadowJoint('Head', Dummy); { same lazy analytic solution as the GPU shader }
  if not FShValid then Exit;
  if Index < 2 then Result := FShLegs[Index].Ok
  else Result := FShArms[Index - 2].Ok;
  if Result then P := FShContacts[Index];
end;

function TGpuRiderSkin.ShadowHandFrame(Side:Integer;out Forward,Palm:TVector3;out Twist:Single):Boolean;
var Dummy:TVector3; V:TTripoVec3;
begin
  Forward:=TVector3.Zero;Palm:=TVector3.Zero;Twist:=0;
  Result:=False;if (Side<0) or (Side>1) then Exit;
  ShadowJoint('Head',Dummy);
  Result:=FShValid and FShArms[Side].Ok;if not Result then Exit;
  Twist:=FShHandTwist[Side];
  V:=QuatRotateV3(FShHandQ[Side],FShArms[Side].HandForward);
  Forward:=FRider.Scene.Transform.MultDirection(Vector3(V.X,V.Y,V.Z)).Normalize;
  V:=QuatRotateV3(FShHandQ[Side],FShArms[Side].HandPalm);
  Palm:=FRider.Scene.Transform.MultDirection(Vector3(V.X,V.Y,V.Z)).Normalize;
end;

function TGpuRiderSkin.Active: Boolean;
begin
  Result := (FEffect <> nil) and FEffect.Enabled;
end;

procedure TGpuRiderSkin.SetActive(AOn: Boolean);
begin
  if FRider.Correctives <> nil then FRider.Correctives.SetGpuActive(AOn);
  if FRider.Face<>nil then FRider.Face.Gpu:=AOn;
  if (FEffect <> nil) and (FEffect.Enabled <> AOn) then
  begin
    FEffect.Enabled := AOn;   { FdEnabled.Send внутри; ProcessEvents включён в Build }
    if AOn then FLastValid := False;   { перестраховка: после enable дослать uniform'ы }
  end;
  if (FRider.Correctives<>nil) and (FRider.Correctives.Body<>nil) then
    FRider.Correctives.Body.SendActiveFrame;
end;

function TGpuRiderSkin.EffectSceneAssigned: Boolean;
begin
  Result := (FEffect <> nil) and (FEffect.Scene <> nil);
end;

procedure TGpuRiderSkin.SendFrame(const Phase: Single; const InvP: TMatrix4;
  const OBB, CrankR, CrankL: TVector3; StanceZ, PedalDir: Single;
  const GripR, GripL: TVector3; const FreePosR, FreePosL: TVector3;
  const Pose: TRiderPose);
var
  I, ci, ri: Integer;
  Ang: TSpineAngles;
  ChS, ChM, ChV: Boolean;
  FootYaw: TTripoVec4;
  GripFrame:TRiderGripFrame;

  function FV(const V: TVector3): string;
  begin Result := Format('(%.5f,%.5f,%.5f)', [V.X, V.Y, V.Z]); end;

begin
  if not FReady then Exit;
  CountRiderWork(rwGpuFrame);
  { TEMP-DIAG (этап 2 отладка): первые 2 кадра — дамп входов для численной
    сверки GLSL-математики с CPU-путём. }
  if FDiagDumps < 2 then
  begin
    Inc(FDiagDumps);
    StartupLog(Format('[gpu-diag] phase=%.4f OBB=%s CrankR=%s CrankL=%s stanceZ=%.4f dir=%.1f',
      [Phase, FV(OBB), FV(CrankR), FV(CrankL), StanceZ, PedalDir]));
    StartupLog(Format('[gpu-diag] GripR=%s GripL=%s lean=%.2f curve=%.2f',
      [FV(GripR), FV(GripL), Pose.TorsoLeanDeg, Pose.SpineCurve]));
    StartupLog(Format('[gpu-diag] InvP: (%.4f,%.4f,%.4f,%.4f) (%.4f,%.4f,%.4f,%.4f) (%.4f,%.4f,%.4f,%.4f) (%.4f,%.4f,%.4f,%.4f)',
      [InvP.Data[0,0], InvP.Data[0,1], InvP.Data[0,2], InvP.Data[0,3],
       InvP.Data[1,0], InvP.Data[1,1], InvP.Data[1,2], InvP.Data[1,3],
       InvP.Data[2,0], InvP.Data[2,1], InvP.Data[2,2], InvP.Data[2,3],
       InvP.Data[3,0], InvP.Data[3,1], InvP.Data[3,2], InvP.Data[3,3]]));
  end;
  { скаляры одним MF (порядок = #define-алиасы в шейдере) }
  FScalarsList.Clear;
  FScalarsList.Add(Phase);
  FScalarsList.Add(StanceZ);
  FScalarsList.Add(PedalDir);
  FScalarsList.Add(Pose.KneeFlare);
  FScalarsList.Add(Pose.ElbowFlare);
  FScalarsList.Add(Pose.AnkleFlex);
  FScalarsList.Add(Pose.ArmPronationR);
  FScalarsList.Add(Pose.ArmPronationL);
  FScalarsList.Add(Pose.ShoulderRoundDeg);
  FScalarsList.Add(Pose.HandLevel);
  FScalarsList.Add(Pose.LegFreeR);
  FScalarsList.Add(Pose.LegFreeL);
  { Спина: те же дельты поворота, что PoseSpine. }
  if Pose.SpineManual then
  begin
    for I := 0 to 4 do Ang[I] := Pose.SpineAngles[I];
  end
  else
  begin
    SpineAutoLeanDeg(Pose.TorsoLeanDeg, Pose.SpineCurve, FSpineIdx, Ang);
  end;
  for I := 0 to RiderSpineChainCount-1 do
    FShDelta[I] := RiderSpineChainDelta(FRider.LeanAxis,
      Ang, Pose.SpineYaw, Pose.SpineRoll, FSpineIdx,I,FRider.HasParametricBody);
  { This FK was already necessary every frame for the external helmet. Share
    its rotations with the shader instead of evaluating the same chain twice. }
  UpdateShadowSpine;
  for I := 0 to 4 do
  begin
    FScalarsList.Add(FShRS[I].X); FScalarsList.Add(FShRS[I].Y);
    FScalarsList.Add(FShRS[I].Z); FScalarsList.Add(FShRS[I].W);
  end;
  FootYaw := RiderFootYawRotation(InvP, FRider.FootYawDeg);
  FScalarsList.Add(FootYaw.W);
  FScalarsList.Add(Ord(Pose.HandPosR > 0));
  FScalarsList.Add(Ord(Pose.HandPosL > 0));
  for I:=0 to 1 do begin
    FShClavicleDelta[I]:=RiderScapulaDelta(FRider.LeanAxis,
      Pose.ShoulderRoundDeg+Pose.ScapulaProtraction[I],
      EnsureRange((GripR.X-GripL.X)*220.0,-22.0,22.0),Pose.ScapulaElevation[I],I);
    FScalarsList.Add(FShClavicleDelta[I].X);FScalarsList.Add(FShClavicleDelta[I].Y);
    FScalarsList.Add(FShClavicleDelta[I].Z);FScalarsList.Add(FShClavicleDelta[I].W);
  end;
  FScalarsList.Add(Pose.HandFrameR.Weight);FScalarsList.Add(Pose.HandFrameL.Weight);
  for I:=0 to 1 do begin
    if I=0 then GripFrame:=Pose.HandFrameR else GripFrame:=Pose.HandFrameL;
    GripFrame:=TransformGripFrame(GripFrame,InvP);
    FShGripTarget[I]:=RiderGripTarget(FShArms[I].HandForward,FShArms[I].HandPalm,GripFrame);
    FScalarsList.Add(FShGripTarget[I].X);FScalarsList.Add(FShGripTarget[I].Y);
    FScalarsList.Add(FShGripTarget[I].Z);FScalarsList.Add(FShGripTarget[I].W);
  end;
  for I := 5 to RiderSpineChainCount-1 do begin
    FScalarsList.Add(FShRS[I].X);FScalarsList.Add(FShRS[I].Y);
    FScalarsList.Add(FShRS[I].Z);FScalarsList.Add(FShRS[I].W);
  end;
  FVecsList.Clear;
  FVecsList.Add(OBB);
  FVecsList.Add(CrankR);
  FVecsList.Add(CrankL);
  FVecsList.Add(GripR);
  FVecsList.Add(GripL);
  FVecsList.Add(FreePosR);
  FVecsList.Add(FreePosL);
  FVecsList.Add(Vector3(FootYaw.X, FootYaw.Y, FootYaw.Z));
  { OPT: Send только при изменении (Send = X3D-event + glUseProgram + glUniform
    на каждый вызов). Неподвижная поза → 0 Send'ов вместо 3. Первый кадр после
    Build/включения эффекта (FLastValid=False) шлёт всё. }
  ChS := not FLastValid;
  if not ChS then
    for I := 0 to FScalarsList.Count - 1 do
      if Abs(FScalarsList[I] - FLastScalars[I]) > 1e-6 then begin ChS := True; Break; end;
  if ChS then
  begin
    FUScalars.Send(FScalarsList);
    for I := 0 to FScalarsList.Count - 1 do FLastScalars[I] := FScalarsList[I];
  end;
  ChM := not FLastValid;
  if not ChM then
    for ci := 0 to 3 do
    begin
      for ri := 0 to 3 do
        if Abs(InvP.Data[ci, ri] - FLastInvP.Data[ci, ri]) > 1e-6 then
        begin ChM := True; Break; end;
      if ChM then Break;
    end;
  if ChM then
  begin
    FUInvP.Send(InvP);
    FLastInvP := InvP;
  end;
  ChV := not FLastValid;
  if not ChV then
    for I := 0 to FVecsList.Count - 1 do
      if (Abs(FVecsList[I].X - FLastVecs[I].X) > 1e-6)
         or (Abs(FVecsList[I].Y - FLastVecs[I].Y) > 1e-6)
         or (Abs(FVecsList[I].Z - FLastVecs[I].Z) > 1e-6) then
      begin ChV := True; Break; end;
  if ChV then
  begin
    FUVecs.Send(FVecsList);
    for I := 0 to FVecsList.Count - 1 do FLastVecs[I] := FVecsList[I];
  end;
  FLastValid := True;
  { этап 5: позиции суставов для капсульной тени — ЛЕНИВО. Спина/голова/шлем
    считаются сразу той же математикой, что шейдер (Ang — те же углы спины,
    что отправлены выше; шлем обязан следовать за головой каждый кадр), а
    тяжёлый IK конечностей + перенос в кадр байка — при первом ShadowJoint
    кадра (UpdateShadowDynamic; без капсульной тени не считается вообще). }
  FShInPhase := Phase; FShInInvP := InvP;
  FShInOBB := OBB; FShInCrankR := CrankR; FShInCrankL := CrankL;
  FShInStanceZ := StanceZ; FShInPedalDir := PedalDir;
  FShInGripR := GripR; FShInGripL := GripL;
  FShInFreeR := FreePosR; FShInFreeL := FreePosL;
  FShInPose := Pose;
  FShInFootYaw := FootYaw;
  FShDirty := True;
end;

end.

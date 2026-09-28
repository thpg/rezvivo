{
  TripoRig — Strategy A foundation.

  Loads a skinned glb (the Tripo cyclist) DIRECTLY from the binary and exposes:

    - the mesh     : Positions / Normals / TexCoords / Indices, plus the
                     authored 4-influence skin (Joints[4] + Weights[4]/vertex)
    - the skeleton : the skin joint palette (the order JOINTS_0 indexes),
                     names, palette-parent links, inverse-bind + bind-world
                     + bind-local matrices
    - a pose API   : per-joint LOCAL rotation deltas (rest = identity), then
                     ComputePose fills WorldPose and, crucially, SkinMatrix
                     = WorldPose * InvBind  (upload these to the GPU)

  Standard glTF skinning math: at rest every SkinMatrix is identity, so the
  mesh renders in bind pose; an animation layer sets joint deltas (e.g. rotate
  L_Thigh about the hip) and the same vertices deform with the authored weights.
  No proximity re-rig, no per-bone-unrolled shader.

  RTL-only and column-major (glTF native) so it is unit testable. The
  integration layer converts TTripoMat4 (array[0..15] col-major) to engine types.

  License: MIT
}
unit TripoRig;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  TTripoVec2 = record X, Y: Single; end;
  TTripoVec3 = record X, Y, Z: Single; end;
  TTripoVec4 = record X, Y, Z, W: Single; end;   { also a quaternion (x,y,z,w) }
  TTripoMat4 = array[0..15] of Single;            { COLUMN-MAJOR (glTF native) }

  TJointInf  = array[0..3] of Word;
  TWeightInf = array[0..3] of Single;

  TTripoRig = class
  public
    { mesh (skinned primitive) }
    VertexCount: Integer;
    Positions: array of TTripoVec3;
    Normals:   array of TTripoVec3;
    TexCoords: array of TTripoVec2;     { all-zero if the mesh has no UV }
    HasTexCoords: Boolean;
    Joints:    array of TJointInf;      { palette indices, 4 per vertex }
    Weights:   array of TWeightInf;     { matching weights (renormalized) }
    Indices:   array of LongWord;       { triangle list }

    { skeleton (palette order = JOINTS_0 indexing) }
    JointCount:  Integer;
    JointName:   array of string;
    JointNode:   array of Integer;      { source glTF node index }
    JointParent: array of Integer;      { palette parent, -1 if a skin root }
    InvBind:     array of TTripoMat4;   { mesh space -> joint space (kept NATIVE across
                                          limb scaling so SkinMatrix encodes the stretch) }
    NativeInvBind: array of TTripoMat4; { file IBM as exported — NOT rewritten to
                                          inv(BindWorld). BindWorld includes Armature
                                          scale; many Tripo/Mixamo IBMs do not. CGE
                                          skins with this file IBM (mesh = 1.7×1m). }
    BindWorld:   array of TTripoMat4;   { = inverse(InvBind) at load; after a limb-length
                                          change BindWorld grows (IK lengths) while InvBind
                                          stays native, so they are intentionally desynced }
    BindLocal:   array of TTripoMat4;   { joint relative to its palette parent }

    { pose }
    Delta:      array of TTripoMat4;    { per-joint LOCAL rotation delta }
    WorldPose:  array of TTripoMat4;    { current world transform of each joint }
    SkinMatrix: array of TTripoMat4;    { WorldPose * InvBind  - UPLOAD THESE }
    BendCache:  array of TTripoVec3;     { last bend (pole) direction per Mid joint, world
                                          frame; used by the stabilized IK to keep the
                                          elbow/knee from flipping side across the hint
                                          singularity between frames }

    { OPT (pose-7ms): статичный топологический порядок суставов (родитель
      раньше ребёнка) — JointParent после загрузки не меняется, поэтому
      Depth/Order считаются один раз, а не на каждый ComputePose (который
      зовётся из IK десятки раз за кадр). FOrderPos — обратная таблица. }
    FOrder:     array of Integer;
    FOrderPos:  array of Integer;
    FOrderValid: Boolean;
    { OPT (hot-frame): кэш имя→индекс для JointIndexByName — JointName после
      загрузки не меняется. Сортированные параллельные массивы + бинпоиск
      (без TStringList: юнит RTL-only). Перестраивается в LoadFromFile. }
    FNameKeys: array of string;
    FNameVals: array of Integer;
    procedure EnsureOrder;
    { Пересчитать WorldPose/SkinMatrix только для сустава J и всех ПОСЛЕ
      него в топологическом порядке (= J + его потомки + чужие ветки,
      что безвредно). Инвариант: все изменения Delta[] завершаются
      ComputePose/ComputePoseFrom, поэтому суставы до J в порядке
      консистентны. Полный ComputePose нужен только после ResetPose. }
    procedure ComputePoseFrom(J: Integer);

    constructor Create;
    function LoadFromFile(const FileName: string; Errors: TStrings = nil): Boolean;
    function JointIndexByName(const AName: string): Integer;
    function JointDescendsFrom(Child, Ancestor: Integer): Boolean;
    function ForearmTwistJoints(Forearm, Hand: Integer; out T1, T2: Integer): Boolean;
    procedure DistributeForearmTwist(const Side: string);
    function FingerDelta(J: Integer; Grip: Single): TTripoMat4;
    procedure ApplyHandGrip(GripR, GripL: Single);
    procedure ClosedHandMatrices(out Matrices: array of TTripoMat4);
    procedure BuildNameIndex;   { перестроить FNameKeys/FNameVals (из LoadFromFile) }
    procedure ResetPose;
    procedure SetJointDeltaQuat(J: Integer; const Q: TTripoVec4);
    procedure SetJointDeltaAxisAngle(J: Integer; Ax, Ay, Az, AngleRad: Single);
    procedure ComputePose;
    { Rebuild BindWorld + InvBind from the current BindLocal. Call after editing
      bone offsets (BindLocal translations) so bind positions / IK lengths follow. }
    procedure RecomputeBindWorld(KeepInvBind: Boolean = False);
    { Left-multiply every bind world by M (extra parent). BindLocal of
      non-roots stays the same; InvBind is rebuilt. }
    procedure PrependBindWorld(const M: TTripoMat4);
    function JointBindPos(J: Integer): TTripoVec3;
    function JointWorldPos(J: Integer): TTripoVec3;

    { ── IK (operates on the bind skeleton; results expressed as joint-local
         deltas, so they can be pushed straight to the CGE joint nodes) ── }
    function JointWorldRot(J: Integer): TTripoVec4;   { current pose rotation, quat }
    function DeltaQuat(J: Integer): TTripoVec4;        { current local delta, quat }

    { Two-bone analytic IK: aim Upper->Mid->End so End reaches TargetWorld
      (in the rig's own/glb frame), bending toward PlaneHint. Sets Delta on
      Upper and Mid and re-runs ComputePose. Call AFTER any torso/parent
      deltas + ComputePose so parent world transforms are current. }
    procedure SolveTwoBone(UpperIdx, MidIdx, EndIdx: Integer;
      const TargetWorld, PlaneHint: TTripoVec3; Stabilize: Boolean = False);
    { Aim a leg at its cleat, using knee->cleat as the effective lower segment.
      Returns a foot orientation and the corresponding ankle target. The caller
      solves the actual thigh/shin to that ankle, preserving their lengths. }
    procedure AimLegContact(UpperIdx, MidIdx, EndIdx: Integer;
      const TargetWorld, PlaneHint, ContactLocal: TTripoVec3;
      const FootTurn: TTripoVec4; out FootRotation: TTripoVec4;
      out AnkleTarget: TTripoVec3);
    { knee/elbow placement with frame-to-frame side continuity (kept in BendCache[MidIdx]) }
    function SolveJointStable(MidIdx: Integer; const Root, Target: TTripoVec3;
      L1, L2: Single; const PlaneHint: TTripoVec3): TTripoVec3;

    { Pitch a joint (and everything below it) by AngleRad about a WORLD-space
      axis, expressed as a joint-local delta. Used for torso lean. Re-runs
      ComputePose. Call after ResetPose+ComputePose. }
    procedure ApplyWorldPitch(const AName: string;
      AxisX, AxisY, AxisZ, AngleRad: Single);
    { То же по уже известному индексу — без строкового поиска (горячий IK-путь). }
    procedure ApplyWorldRotationByIndex(J: Integer; const WorldQ: TTripoVec4);
    procedure ApplyWorldPitchByIndex(J: Integer;
      AxisX, AxisY, AxisZ, AngleRad: Single);
  end;

{ Map exporter-specific joint names to the canonical Tripo set used by
  RiderTripo IK (R_Foot, L_Hand, Pelvis, …). Strips Mixamo / Blender /
  Armature prefixes and matches common synonyms. Unknown names pass through. }
function CanonicalJointName(const AName: string): string;

{ small matrix/quaternion helpers (column-major), exposed for integration }
function Mat4Identity: TTripoMat4;
function Mat4Mul(const A, B: TTripoMat4): TTripoMat4;          { A*B }
function Mat4Inverse(const M: TTripoMat4): TTripoMat4;
function Mat4FromQuat(const Q: TTripoVec4): TTripoMat4;
function Mat4FromTRS(const T: TTripoVec3; const R: TTripoVec4; const S: TTripoVec3): TTripoMat4;
function Mat4MulPoint(const M: TTripoMat4; const P: TTripoVec3): TTripoVec3;
function QuatFromAxisAngle(Ax, Ay, Az, AngleRad: Single): TTripoVec4;
function QuatMul(const A, B: TTripoVec4): TTripoVec4;

{ vector + quaternion + IK helpers (exposed for the integration / tests) }
function V3(X, Y, Z: Single): TTripoVec3;
function V3Sub(const A, B: TTripoVec3): TTripoVec3;
function V3Add(const A, B: TTripoVec3): TTripoVec3;
function V3Scale(const A: TTripoVec3; S: Single): TTripoVec3;
function V3Dot(const A, B: TTripoVec3): Single;
function V3Cross(const A, B: TTripoVec3): TTripoVec3;
function V3Len(const A: TTripoVec3): Single;
function V3Norm(const A: TTripoVec3): TTripoVec3;
function QuatConj(const Q: TTripoVec4): TTripoVec4;
function QuatNormalize(const Q: TTripoVec4): TTripoVec4;
function QuatRotateV3(const Q: TTripoVec4; const V: TTripoVec3): TTripoVec3;
function QuatFromTo(const AFrom, ATo: TTripoVec3): TTripoVec4;   { shortest arc }
function Mat4ToQuat(const M: TTripoMat4): TTripoVec4;            { rotation part }
function SolveJoint(const Root, Target: TTripoVec3; L1, L2: Single;
  const PlaneHint: TTripoVec3; SoftReach: Single = 0): TTripoVec3;

implementation

uses
  Math, fpjson, jsonparser, GltfCore;

{ ===================== joint name canonicalization ===================== }

function CanonicalJointName(const AName: string): string;
var
  S, Low: string;
  P: Integer;
begin
  S := Trim(AName);
  { strip common hierarchy prefixes: "mixamorig:LeftFoot", "Armature|Root",
    "Armature_Root", "Character1_Hips" }
  while True do
  begin
    P := LastDelimiter(':|/', S);
    if P > 0 then
      Delete(S, 1, P)
    else
      Break;
  end;
  if (Length(S) > 9) and SameText(Copy(S, 1, 9), 'mixamorig') then
  begin
    { mixamorigLeftFoot / mixamorig_LeftFoot }
    if (Length(S) > 9) and (S[10] in ['_', '-', '.']) then
      Delete(S, 1, 10)
    else
      Delete(S, 1, 9);
  end;
  if (Length(S) > 8) and SameText(Copy(S, 1, 8), 'Armature') then
  begin
    if (Length(S) > 8) and (S[9] in ['_', '-', '.', '|']) then
      Delete(S, 1, 9);
  end;
  Low := LowerCase(S);

  { ── spine / torso ── }
  if (Low = 'root') or (Low = 'reference') or (Low = 'armature') then
    Exit('Root');
  if (Low = 'hip') or (Low = 'hips') or (Low = 'pelvis') or (Low = 'hips_01') then
  begin
    { Mixamo Hips ≈ our Hip (parent of Pelvis); if only one hips bone exists
      callers also try Pelvis. Keep Hip as default for "Hips". }
    if (Low = 'pelvis') then Exit('Pelvis');
    Exit('Hip');
  end;
  if Low = 'waist' then
    Exit('Waist');
  { Bare "Spine" is the lumbar joint (Tripo). Do not alias it to Spine01 —
    that collapsed two bones, so auto-lean hit Waist+lumbar and skipped the
    thoracic hinge (belt hump). Mixamo Spine1 / Spine01 stay Spine01. }
  if Low = 'spine' then
    Exit('Spine');
  if (Low = 'spine1') or (Low = 'spine_01')
     or (Low = 'spine01') or (Low = 'spine.001') then
    Exit('Spine01');
  if (Low = 'spine2') or (Low = 'spine_02') or (Low = 'spine02')
     or (Low = 'spine.002') or (Low = 'chest') or (Low = 'spine3')
     or (Low = 'spine_03') then
    Exit('Spine02');
  if (Low = 'neck') or (Low = 'neck1') or (Low = 'neck_01') or (Low = 'necktwist01')
     or (Low = 'neck.001') then
    Exit('NeckTwist01');
  if (Low = 'neck2') or (Low = 'neck_02') or (Low = 'necktwist02') then
    Exit('NeckTwist02');
  if (Low = 'head') or (Low = 'head_01') then
    Exit('Head');

  { ── legs L (Mixamo: LeftUpLeg=thigh, LeftLeg=shin) ── }
  if (Low = 'l_thigh') or (Low = 'leftupleg') or (Low = 'left_up_leg')
     or (Low = 'leftupperleg') or (Low = 'upperleg_l') or (Low = 'thigh_l')
     or (Low = 'l_upleg') or (Low = 'leg_l') then
    Exit('L_Thigh');
  if (Low = 'l_calf') or (Low = 'leftleg') or (Low = 'left_leg')
     or (Low = 'leftlowerleg') or (Low = 'lowerleg_l') or (Low = 'shin_l')
     or (Low = 'l_shin') or (Low = 'calf_l') then
    Exit('L_Calf');
  if (Low = 'l_foot') or (Low = 'leftfoot') or (Low = 'left_foot')
     or (Low = 'foot_l') then
    Exit('L_Foot');
  if (Low = 'l_toebase') or (Low = 'lefttoebase') or (Low = 'left_toe_base')
     or (Low = 'lefttoe') or (Low = 'toe_l') or (Low = 'l_toe') then
    Exit('L_ToeBase');

  { ── legs R ── }
  if (Low = 'r_thigh') or (Low = 'rightupleg') or (Low = 'right_up_leg')
     or (Low = 'rightupperleg') or (Low = 'upperleg_r') or (Low = 'thigh_r')
     or (Low = 'r_upleg') or (Low = 'leg_r') then
    Exit('R_Thigh');
  if (Low = 'r_calf') or (Low = 'rightleg') or (Low = 'right_leg')
     or (Low = 'rightlowerleg') or (Low = 'lowerleg_r') or (Low = 'shin_r')
     or (Low = 'r_shin') or (Low = 'calf_r') then
    Exit('R_Calf');
  if (Low = 'r_foot') or (Low = 'rightfoot') or (Low = 'right_foot')
     or (Low = 'foot_r') then
    Exit('R_Foot');
  if (Low = 'r_toebase') or (Low = 'righttoebase') or (Low = 'right_toe_base')
     or (Low = 'righttoe') or (Low = 'toe_r') or (Low = 'r_toe') then
    Exit('R_ToeBase');

  { ── arms L ── }
  if (Low = 'l_clavicle') or (Low = 'leftshoulder') or (Low = 'left_shoulder')
     or (Low = 'shoulder_l') or (Low = 'l_shoulder') or (Low = 'clavicle_l') then
    Exit('L_Clavicle');
  if (Low = 'l_upperarm') or (Low = 'leftarm') or (Low = 'left_arm')
     or (Low = 'leftupperarm') or (Low = 'upperarm_l') or (Low = 'arm_l') then
    Exit('L_Upperarm');
  if (Low = 'l_forearm') or (Low = 'leftforearm') or (Low = 'left_forearm')
     or (Low = 'leftforearm') or (Low = 'forearm_l') or (Low = 'lowerarm_l') then
    Exit('L_Forearm');
  if (Low = 'l_hand') or (Low = 'lefthand') or (Low = 'left_hand')
     or (Low = 'hand_l') then
    Exit('L_Hand');

  { ── arms R ── }
  if (Low = 'r_clavicle') or (Low = 'rightshoulder') or (Low = 'right_shoulder')
     or (Low = 'shoulder_r') or (Low = 'r_shoulder') or (Low = 'clavicle_r') then
    Exit('R_Clavicle');
  if (Low = 'r_upperarm') or (Low = 'rightarm') or (Low = 'right_arm')
     or (Low = 'rightupperarm') or (Low = 'upperarm_r') or (Low = 'arm_r') then
    Exit('R_Upperarm');
  if (Low = 'r_forearm') or (Low = 'rightforearm') or (Low = 'right_forearm')
     or (Low = 'forearm_r') or (Low = 'lowerarm_r') then
    Exit('R_Forearm');
  if (Low = 'r_hand') or (Low = 'righthand') or (Low = 'right_hand')
     or (Low = 'hand_r') then
    Exit('R_Hand');

  { already canonical or twist bones: keep as-is (preserve case for twists) }
  if (S = 'Root') or (S = 'Hip') or (S = 'Pelvis') or (S = 'Waist')
     or (S = 'Spine01') or (S = 'Spine02') or (S = 'Head')
     or (S = 'L_Thigh') or (S = 'L_Calf') or (S = 'L_Foot') or (S = 'L_ToeBase')
     or (S = 'R_Thigh') or (S = 'R_Calf') or (S = 'R_Foot') or (S = 'R_ToeBase')
     or (S = 'L_Clavicle') or (S = 'L_Upperarm') or (S = 'L_Forearm') or (S = 'L_Hand')
     or (S = 'R_Clavicle') or (S = 'R_Upperarm') or (S = 'R_Forearm') or (S = 'R_Hand')
     or (Pos('Twist', S) > 0) or (Pos('twist', Low) > 0) then
    Exit(S);

  Result := S;   { unknown — leave exporter name }
end;

{ ===================== matrix / quaternion ===================== }

function Mat4Identity: TTripoMat4;
var I: Integer;
begin
  for I := 0 to 15 do Result[I] := 0;
  Result[0] := 1; Result[5] := 1; Result[10] := 1; Result[15] := 1;
end;

function Mat4Mul(const A, B: TTripoMat4): TTripoMat4;
var c, r, k: Integer; s: Single;
begin
  for c := 0 to 3 do
    for r := 0 to 3 do
    begin
      s := 0;
      for k := 0 to 3 do s := s + A[k*4 + r] * B[c*4 + k];
      Result[c*4 + r] := s;
    end;
end;

function Mat4MulPoint(const M: TTripoMat4; const P: TTripoVec3): TTripoVec3;
begin
  Result.X := M[0]*P.X + M[4]*P.Y + M[8] *P.Z + M[12];
  Result.Y := M[1]*P.X + M[5]*P.Y + M[9] *P.Z + M[13];
  Result.Z := M[2]*P.X + M[6]*P.Y + M[10]*P.Z + M[14];
end;

function Mat4Inverse(const M: TTripoMat4): TTripoMat4;
var inv: TTripoMat4; det: Single; I: Integer;
begin
  inv[0]  :=  M[5]*M[10]*M[15] - M[5]*M[11]*M[14] - M[9]*M[6]*M[15]
            + M[9]*M[7]*M[14] + M[13]*M[6]*M[11] - M[13]*M[7]*M[10];
  inv[4]  := -M[4]*M[10]*M[15] + M[4]*M[11]*M[14] + M[8]*M[6]*M[15]
            - M[8]*M[7]*M[14] - M[12]*M[6]*M[11] + M[12]*M[7]*M[10];
  inv[8]  :=  M[4]*M[9]*M[15] - M[4]*M[11]*M[13] - M[8]*M[5]*M[15]
            + M[8]*M[7]*M[13] + M[12]*M[5]*M[11] - M[12]*M[7]*M[9];
  inv[12] := -M[4]*M[9]*M[14] + M[4]*M[10]*M[13] + M[8]*M[5]*M[14]
            - M[8]*M[6]*M[13] - M[12]*M[5]*M[10] + M[12]*M[6]*M[9];
  inv[1]  := -M[1]*M[10]*M[15] + M[1]*M[11]*M[14] + M[9]*M[2]*M[15]
            - M[9]*M[3]*M[14] - M[13]*M[2]*M[11] + M[13]*M[3]*M[10];
  inv[5]  :=  M[0]*M[10]*M[15] - M[0]*M[11]*M[14] - M[8]*M[2]*M[15]
            + M[8]*M[3]*M[14] + M[12]*M[2]*M[11] - M[12]*M[3]*M[10];
  inv[9]  := -M[0]*M[9]*M[15] + M[0]*M[11]*M[13] + M[8]*M[1]*M[15]
            - M[8]*M[3]*M[13] - M[12]*M[1]*M[11] + M[12]*M[3]*M[9];
  inv[13] :=  M[0]*M[9]*M[14] - M[0]*M[10]*M[13] - M[8]*M[1]*M[14]
            + M[8]*M[2]*M[13] + M[12]*M[1]*M[10] - M[12]*M[2]*M[9];
  inv[2]  :=  M[1]*M[6]*M[15] - M[1]*M[7]*M[14] - M[5]*M[2]*M[15]
            + M[5]*M[3]*M[14] + M[13]*M[2]*M[7] - M[13]*M[3]*M[6];
  inv[6]  := -M[0]*M[6]*M[15] + M[0]*M[7]*M[14] + M[4]*M[2]*M[15]
            - M[4]*M[3]*M[14] - M[12]*M[2]*M[7] + M[12]*M[3]*M[6];
  inv[10] :=  M[0]*M[5]*M[15] - M[0]*M[7]*M[13] - M[4]*M[1]*M[15]
            + M[4]*M[3]*M[13] + M[12]*M[1]*M[7] - M[12]*M[3]*M[5];
  inv[14] := -M[0]*M[5]*M[14] + M[0]*M[6]*M[13] + M[4]*M[1]*M[14]
            - M[4]*M[2]*M[13] - M[12]*M[1]*M[6] + M[12]*M[2]*M[5];
  inv[3]  := -M[1]*M[6]*M[11] + M[1]*M[7]*M[10] + M[5]*M[2]*M[11]
            - M[5]*M[3]*M[10] - M[9]*M[2]*M[7] + M[9]*M[3]*M[6];
  inv[7]  :=  M[0]*M[6]*M[11] - M[0]*M[7]*M[10] - M[4]*M[2]*M[11]
            + M[4]*M[3]*M[10] + M[8]*M[2]*M[7] - M[8]*M[3]*M[6];
  inv[11] := -M[0]*M[5]*M[11] + M[0]*M[7]*M[9] + M[4]*M[1]*M[11]
            - M[4]*M[3]*M[9] - M[8]*M[1]*M[7] + M[8]*M[3]*M[5];
  inv[15] :=  M[0]*M[5]*M[10] - M[0]*M[6]*M[9] - M[4]*M[1]*M[10]
            + M[4]*M[2]*M[9] + M[8]*M[1]*M[6] - M[8]*M[2]*M[5];

  det := M[0]*inv[0] + M[1]*inv[4] + M[2]*inv[8] + M[3]*inv[12];
  if Abs(det) < 1e-20 then begin Result := Mat4Identity; Exit; end;
  det := 1.0 / det;
  for I := 0 to 15 do Result[I] := inv[I] * det;
end;

function Mat4FromQuat(const Q: TTripoVec4): TTripoMat4;
var x, y, z, w, n, xx, yy, zz, xy, xz, yz, wx, wy, wz: Single;
begin
  x := Q.X; y := Q.Y; z := Q.Z; w := Q.W;
  n := Sqrt(x*x + y*y + z*z + w*w);
  if n < 1e-20 then begin Result := Mat4Identity; Exit; end;
  x := x/n; y := y/n; z := z/n; w := w/n;
  xx := x*x; yy := y*y; zz := z*z; xy := x*y; xz := x*z; yz := y*z;
  wx := w*x; wy := w*y; wz := w*z;
  Result := Mat4Identity;
  Result[0] := 1 - 2*(yy+zz);  Result[1] := 2*(xy+wz);      Result[2]  := 2*(xz-wy);
  Result[4] := 2*(xy-wz);      Result[5] := 1 - 2*(xx+zz);  Result[6]  := 2*(yz+wx);
  Result[8] := 2*(xz+wy);      Result[9] := 2*(yz-wx);      Result[10] := 1 - 2*(xx+yy);
end;

function Mat4FromTRS(const T: TTripoVec3; const R: TTripoVec4; const S: TTripoVec3): TTripoMat4;
var M: TTripoMat4;
begin
  M := Mat4FromQuat(R);
  M[0] := M[0]*S.X; M[1] := M[1]*S.X; M[2] := M[2]*S.X;
  M[4] := M[4]*S.Y; M[5] := M[5]*S.Y; M[6] := M[6]*S.Y;
  M[8] := M[8]*S.Z; M[9] := M[9]*S.Z; M[10] := M[10]*S.Z;
  M[12] := T.X; M[13] := T.Y; M[14] := T.Z;
  Result := M;
end;

function QuatFromAxisAngle(Ax, Ay, Az, AngleRad: Single): TTripoVec4;
var n, s, h: Single;
begin
  n := Sqrt(Ax*Ax + Ay*Ay + Az*Az);
  if n < 1e-20 then begin Result.X:=0; Result.Y:=0; Result.Z:=0; Result.W:=1; Exit; end;
  Ax := Ax/n; Ay := Ay/n; Az := Az/n;
  h := AngleRad*0.5; s := Sin(h);
  Result.X := Ax*s; Result.Y := Ay*s; Result.Z := Az*s; Result.W := Cos(h);
end;

function QuatMul(const A, B: TTripoVec4): TTripoVec4;
begin
  Result.W := A.W*B.W - A.X*B.X - A.Y*B.Y - A.Z*B.Z;
  Result.X := A.W*B.X + A.X*B.W + A.Y*B.Z - A.Z*B.Y;
  Result.Y := A.W*B.Y - A.X*B.Z + A.Y*B.W + A.Z*B.X;
  Result.Z := A.W*B.Z + A.X*B.Y - A.Y*B.X + A.Z*B.W;
end;

{ glTF JSON / GLB byte helpers (U32, ObjOf, ArrOf, ObjAt, IntOf, StrOf,
  ArrInt, CompSize, TypeCount) now live in the shared GltfCore unit. }

{ ===================== TTripoRig ===================== }

constructor TTripoRig.Create;
begin inherited Create; VertexCount := 0; JointCount := 0; HasTexCoords := False;
  FOrderValid := False; end;

function TTripoRig.JointIndexByName(const AName: string): Integer;

  function FindExact(const Key: string): Integer;
  var I, Lo, Hi, Mid: Integer;
  begin
    Result := -1;
    if Key = '' then Exit;
    if Length(FNameKeys) = JointCount then
    begin
      Lo := 0; Hi := JointCount - 1;
      while Lo <= Hi do
      begin
        Mid := (Lo + Hi) div 2;
        if FNameKeys[Mid] = Key then
        begin
          Result := FNameVals[Mid];
          I := Mid - 1;
          while (I >= 0) and (FNameKeys[I] = Key) do
          begin
            if FNameVals[I] < Result then Result := FNameVals[I];
            Dec(I);
          end;
          I := Mid + 1;
          while (I < JointCount) and (FNameKeys[I] = Key) do
          begin
            if FNameVals[I] < Result then Result := FNameVals[I];
            Inc(I);
          end;
          Exit;
        end;
        if FNameKeys[Mid] < Key then Lo := Mid + 1 else Hi := Mid - 1;
      end;
      Exit;
    end;
    for I := 0 to JointCount - 1 do
      if JointName[I] = Key then
        Exit(I);
  end;

var
  Canon: string;
begin
  Result := FindExact(AName);
  if Result >= 0 then Exit;
  Canon := CanonicalJointName(AName);
  if Canon <> AName then
    Result := FindExact(Canon);
  if Result >= 0 then Exit;
  { last resort: compare every stored name by canonical form }
  if Canon <> '' then
    for Result := 0 to JointCount - 1 do
      if CanonicalJointName(JointName[Result]) = Canon then
        Exit;
  Result := -1;
end;

procedure TTripoRig.BuildNameIndex;
var I, J, TmpI: Integer; TmpS: string;
begin
  SetLength(FNameKeys, JointCount);
  SetLength(FNameVals, JointCount);
  for I := 0 to JointCount - 1 do
  begin
    FNameKeys[I] := JointName[I];
    FNameVals[I] := I;
  end;
  { сортировка вставками: суставов десятки, вызывается один раз за загрузку }
  for I := 1 to JointCount - 1 do
  begin
    TmpS := FNameKeys[I]; TmpI := FNameVals[I]; J := I;
    while (J > 0) and (FNameKeys[J - 1] > TmpS) do
    begin
      FNameKeys[J] := FNameKeys[J - 1];
      FNameVals[J] := FNameVals[J - 1];
      Dec(J);
    end;
    FNameKeys[J] := TmpS; FNameVals[J] := TmpI;
  end;
end;

function TTripoRig.JointBindPos(J: Integer): TTripoVec3;
begin
  if (J<0) or (J>=JointCount) then begin Result.X:=0;Result.Y:=0;Result.Z:=0; Exit; end;
  Result.X := BindWorld[J][12]; Result.Y := BindWorld[J][13]; Result.Z := BindWorld[J][14];
end;

function TTripoRig.JointWorldPos(J: Integer): TTripoVec3;
begin
  if (J<0) or (J>=JointCount) or (Length(WorldPose)<JointCount) then
  begin Result.X:=0;Result.Y:=0;Result.Z:=0; Exit; end;
  Result.X := WorldPose[J][12]; Result.Y := WorldPose[J][13]; Result.Z := WorldPose[J][14];
end;

procedure TTripoRig.ResetPose;
var I: Integer;
begin SetLength(Delta, JointCount);
  for I := 0 to JointCount-1 do Delta[I] := Mat4Identity; end;

procedure TTripoRig.SetJointDeltaQuat(J: Integer; const Q: TTripoVec4);
begin if (J<0) or (J>=JointCount) then Exit;
  if Length(Delta) < JointCount then ResetPose; Delta[J] := Mat4FromQuat(Q); end;

procedure TTripoRig.SetJointDeltaAxisAngle(J: Integer; Ax, Ay, Az, AngleRad: Single);
begin SetJointDeltaQuat(J, QuatFromAxisAngle(Ax, Ay, Az, AngleRad)); end;

procedure TTripoRig.EnsureOrder;
var Depth: array of Integer; I, J, P, D, Tmp, A: Integer;
begin
  if FOrderValid and (Length(FOrder) = JointCount) then Exit;
  SetLength(FOrder, JointCount);
  SetLength(FOrderPos, JointCount);
  SetLength(Depth, JointCount);
  for J := 0 to JointCount-1 do
  begin
    D := 0; P := JointParent[J];
    while (P >= 0) and (D < JointCount) do begin Inc(D); P := JointParent[P]; end;
    Depth[J] := D; FOrder[J] := J;
  end;
  for I := 1 to JointCount-1 do
  begin
    Tmp := FOrder[I]; A := I;
    while (A > 0) and (Depth[FOrder[A-1]] > Depth[Tmp]) do
    begin FOrder[A] := FOrder[A-1]; Dec(A); end;
    FOrder[A] := Tmp;
  end;
  for I := 0 to JointCount-1 do FOrderPos[FOrder[I]] := I;
  FOrderValid := True;
end;

procedure TTripoRig.ComputePose;
var I, J, P: Integer;
begin
  if JointCount = 0 then Exit;
  if Length(Delta) < JointCount then ResetPose;
  if Length(WorldPose) <> JointCount then SetLength(WorldPose, JointCount);
  if Length(SkinMatrix) <> JointCount then SetLength(SkinMatrix, JointCount);
  EnsureOrder;
  for I := 0 to JointCount-1 do
  begin
    J := FOrder[I]; P := JointParent[J];
    if P < 0 then WorldPose[J] := Mat4Mul(BindLocal[J], Delta[J])
    else WorldPose[J] := Mat4Mul(Mat4Mul(WorldPose[P], BindLocal[J]), Delta[J]);
    SkinMatrix[J] := Mat4Mul(WorldPose[J], InvBind[J]);
  end;
end;

procedure TTripoRig.ComputePoseFrom(J: Integer);
var I, K, P: Integer;
begin
  if JointCount = 0 then Exit;
  if (J < 0) or (J >= JointCount) then begin ComputePose; Exit; end;
  EnsureOrder;
  { WorldPose/SkinMatrix гарантированно построены (ComputePose при ResetPose
    или первом SolveTwoBone); иначе — полный пересчёт }
  if (Length(WorldPose) < JointCount) or (Length(SkinMatrix) < JointCount) then
  begin ComputePose; Exit; end;
  for I := FOrderPos[J] to JointCount-1 do
  begin
    K := FOrder[I]; P := JointParent[K];
    if P < 0 then WorldPose[K] := Mat4Mul(BindLocal[K], Delta[K])
    else WorldPose[K] := Mat4Mul(Mat4Mul(WorldPose[P], BindLocal[K]), Delta[K]);
    SkinMatrix[K] := Mat4Mul(WorldPose[K], InvBind[K]);
  end;
end;

procedure TTripoRig.RecomputeBindWorld(KeepInvBind: Boolean);
var Order, Depth: array of Integer; I, J, P, D, Tmp, A: Integer;
begin
  if JointCount = 0 then Exit;
  SetLength(Depth, JointCount); SetLength(Order, JointCount);
  for J := 0 to JointCount-1 do
  begin
    D := 0; P := JointParent[J];
    while (P >= 0) and (D < JointCount) do begin Inc(D); P := JointParent[P]; end;
    Depth[J] := D; Order[J] := J;
  end;
  for I := 1 to JointCount-1 do          { stable depth sort: parents before children }
  begin
    Tmp := Order[I]; A := I;
    while (A > 0) and (Depth[Order[A-1]] > Depth[Tmp]) do begin Order[A] := Order[A-1]; Dec(A); end;
    Order[A] := Tmp;
  end;
  for I := 0 to JointCount-1 do
  begin
    J := Order[I]; P := JointParent[J];
    if P < 0 then BindWorld[J] := BindLocal[J]
    else BindWorld[J] := Mat4Mul(BindWorld[P], BindLocal[J]);
    { KeepInvBind=True leaves InvBind at its loaded (native) value while BindWorld
      grows with the new BindLocal. That is exactly how the GPU stretches a limb:
      native inverse-bind matrices + moved joint nodes => SkinMatrix = BindWorld_new
      * InvBind_native reproduces the stretch in the rest pose (NOT identity). If we
      re-derived InvBind here, SkinMatrix would collapse to identity at rest and the
      mesh / contacts would ignore the length change. }
    if not KeepInvBind then
      InvBind[J] := Mat4Inverse(BindWorld[J]);
  end;
end;

procedure TTripoRig.PrependBindWorld(const M: TTripoMat4);
var
  J: Integer;
begin
  if JointCount = 0 then Exit;
  for J := 0 to JointCount - 1 do
    BindWorld[J] := Mat4Mul(M, BindWorld[J]);
  for J := 0 to JointCount - 1 do
  begin
    if JointParent[J] < 0 then
      BindLocal[J] := BindWorld[J]
    else
      BindLocal[J] := Mat4Mul(Mat4Inverse(BindWorld[JointParent[J]]), BindWorld[J]);
    InvBind[J] := Mat4Inverse(BindWorld[J]);
  end;
  ComputePose;
end;

function TTripoRig.JointDescendsFrom(Child, Ancestor: Integer): Boolean;
var Guard: Integer;
begin
  Result := False;
  if (Child < 0) or (Ancestor < 0) then Exit;
  for Guard := 0 to JointCount - 1 do
  begin
    if (Child < 0) or (Child >= JointCount) then Exit;
    if Child = Ancestor then Exit(True);
    Child := JointParent[Child];
  end;
end;

function TTripoRig.ForearmTwistJoints(Forearm, Hand: Integer;
  out T1, T2: Integer): Boolean;
var Axis, V: TTripoVec3; L: Single; J, I: Integer;
begin
  Result := False; T1 := -1; T2 := -1;
  if (Forearm < 0) or (Hand < 0) or
     (Forearm >= JointCount) or (Hand >= JointCount) then Exit;
  T1 := JointIndexByName(Copy(JointName[Forearm], 1, 2) + 'ForearmTwist01');
  T2 := JointIndexByName(Copy(JointName[Forearm], 1, 2) + 'ForearmTwist02');
  if (T1 < 0) or (T2 < 0) or (JointParent[T1] <> Forearm) or
     (JointParent[T2] <> T1) or (JointParent[Hand] <> T2) then Exit;
  Axis := V3Sub(JointBindPos(Hand), JointBindPos(Forearm));
  L := V3Len(Axis);
  if L < 1e-6 then Exit;
  Axis := V3Scale(Axis, 1 / L);
  for I := 0 to 1 do
  begin
    if I = 0 then J := T1 else J := T2;
    V := V3Sub(JointBindPos(J), JointBindPos(Forearm));
    if V3Len(V3Cross(V, Axis)) > L * 0.001 then Exit;
  end;
  Result := True;
end;

procedure TTripoRig.DistributeForearmTwist(const Side: string);
var
  M, E, T1, T2: Integer;
  Axis: TTripoVec3;
  Base, HandQ, Natural, Relative: TTripoVec4;
  Angle: Single;

  procedure SetWorldOrientation(J: Integer; const Q: TTripoVec4);
  var Pre: TTripoVec4; P: Integer;
  begin
    P := JointParent[J]; Pre := Mat4ToQuat(BindLocal[J]);
    if P >= 0 then Pre := QuatMul(JointWorldRot(P), Pre);
    SetJointDeltaQuat(J, QuatNormalize(QuatMul(QuatConj(Pre), Q)));
    ComputePoseFrom(J);
  end;

  procedure SetTwist(J: Integer; Fraction: Single);
  var Q: TTripoVec4;
  begin
    Q := QuatMul(Base, Mat4ToQuat(BindWorld[J]));
    Q := QuatMul(QuatFromAxisAngle(Axis.X, Axis.Y, Axis.Z, Angle * Fraction), Q);
    SetWorldOrientation(J, Q);
  end;

begin
  M := JointIndexByName(Side + 'Forearm'); E := JointIndexByName(Side + 'Hand');
  if not ForearmTwistJoints(M, E, T1, T2) then Exit;
  Axis := V3Norm(V3Sub(JointWorldPos(E), JointWorldPos(M)));
  Base := QuatMul(JointWorldRot(M), QuatConj(Mat4ToQuat(BindWorld[M])));
  Natural := QuatMul(Base, Mat4ToQuat(BindWorld[E]));
  HandQ := JointWorldRot(E);
  Relative := QuatNormalize(QuatMul(HandQ, QuatConj(Natural)));
  if Relative.W < 0 then
  begin
    Relative.X := -Relative.X; Relative.Y := -Relative.Y;
    Relative.Z := -Relative.Z; Relative.W := -Relative.W;
  end;
  { Swing/twist decomposition: wrist bend stays on Hand. Only axial roll
    propagates through the forearm; keep the solved hand orientation. }
  Angle := 2 * ArcTan2(Relative.X*Axis.X + Relative.Y*Axis.Y + Relative.Z*Axis.Z,
    Relative.W);
  SetTwist(T1, 0.5); SetTwist(T2, 1.0);
  SetWorldOrientation(E, HandQ);
end;

function TTripoRig.FingerDelta(J: Integer; Grip: Single): TTripoMat4;
var S: string; A, Z: Single; Segment: Integer;
begin
  Result := Mat4Identity;
  if (J < 0) or (J >= JointCount) then Exit;
  S := JointName[J];
  if (Length(S) < 4) or not (S[Length(S)] in ['1'..'3']) then Exit;
  Segment := Ord(S[Length(S)]) - Ord('1');
  Z := 0;
  if Pos('_Thumb', S) > 0 then
  begin
    if Segment = 0 then begin
      A := 12; Z := 55;
      if Copy(S, 1, 2) = 'L_' then Z := -Z;
    end else A := 35;
  end
  else if (Pos('_Index', S) > 0) or (Pos('_Middle', S) > 0) or
    (Pos('_Ring', S) > 0) or (Pos('_Little', S) > 0) then
  begin
    if Segment = 1 then A := 85 else A := 65;
  end else Exit;
  if Grip < 0 then Grip := 0 else if Grip > 1 then Grip := 1;
  Grip := Grip * Pi / 180;
  Result := Mat4FromQuat(QuatMul(QuatFromAxisAngle(0, 0, 1, Z * Grip),
    QuatFromAxisAngle(1, 0, 0, A * Grip)));
end;

procedure TTripoRig.ApplyHandGrip(GripR, GripL: Single);
var J: Integer;
begin
  if JointIndexByName('L_IndexMetacarpal') < 0 then Exit;
  for J := 0 to JointCount - 1 do
    if (Pos('_Index', JointName[J]) > 0) or (Pos('_Middle', JointName[J]) > 0) or
       (Pos('_Ring', JointName[J]) > 0) or (Pos('_Little', JointName[J]) > 0) or
       (Pos('_Thumb', JointName[J]) > 0) then
    begin
      if Copy(JointName[J], 1, 2) = 'R_' then Delta[J] := FingerDelta(J, GripR)
      else Delta[J] := FingerDelta(J, GripL);
    end;
  ComputePose;
end;

procedure TTripoRig.ClosedHandMatrices(out Matrices: array of TTripoMat4);
var W: array of TTripoMat4; I, J, P: Integer; HasFingers: Boolean;
begin
  SetLength(W, JointCount);
  EnsureOrder;
  HasFingers := JointIndexByName('L_IndexMetacarpal') >= 0;
  for I := 0 to JointCount - 1 do
  begin
    J := FOrder[I]; P := JointParent[J];
    W[J] := BindLocal[J];
    if HasFingers then W[J] := Mat4Mul(W[J], FingerDelta(J, 1));
    if P >= 0 then W[J] := Mat4Mul(W[P], W[J]);
    Matrices[J] := Mat4Mul(W[J], Mat4Inverse(BindWorld[J]));
  end;
end;

function TTripoRig.LoadFromFile(const FileName: string; Errors: TStrings): Boolean;
var
  Bytes: TBytes;
  FS: TFileStream;
  JsonStr: string;
  BinOfs, BinLen: Integer;
  RootD: TJSONData;
  Root: TJSONObject;
  NodesA, SkinsA, MeshesA, AccA, BVA: TJSONArray;
  MeshObj, Prim, Attrs, Sk, Nd: TJSONObject;
  Prims, JointsArr, ChildA: TJSONArray;
  SkinIdx, MeshIdx, MeshNodeIdx, I, J, K, NodeI, ParI, BestVerts: Integer;
  SumVerts, OldVC, VertN: Integer;
  ReadMesh, ReadNode: Integer;
  MeshUsesSkin: Boolean;
  PosAcc, NrmAcc, UvAcc, JntAcc, WgtAcc, IdxAcc, IbmAcc: Integer;
  ParentNode, NodeToPalette: array of Integer;
  NodeCount: Integer;

  procedure Err(const S: string); begin if Errors <> nil then Errors.Add(S); end;
  function ReadF(Ofs: Integer): Single; inline; begin Result := PSingle(@Bytes[Ofs])^; end;
  function ReadU(Ofs, Sz: Integer): LongWord;
  begin case Sz of 1: Result := Bytes[Ofs];
    2: Result := LongWord(Bytes[Ofs]) or (LongWord(Bytes[Ofs+1]) shl 8);
    else Result := U32(Bytes, Ofs); end; end;

  function AccInfo(Ai: Integer; out Base, Stride, Ct, Cc, Cnt: Integer): Boolean;
  var Acc, Bv: TJSONObject; BvIdx, AccByte, BvByte, BvStride: Integer; Tp: string;
  begin
    Result := False; Base:=0; Stride:=0; Ct:=0; Cc:=0; Cnt:=0;
    Acc := ObjAt(AccA, Ai); if Acc = nil then Exit;
    BvIdx := IntOf(Acc, 'bufferView', -1); Bv := ObjAt(BVA, BvIdx); if Bv = nil then Exit;

    Ct := IntOf(Acc, 'componentType', 0); Tp := StrOf(Acc, 'type', '');
    Cc := TypeCount(Tp); Cnt := IntOf(Acc, 'count', 0);
    if (Cc = 0) or (CompSize(Ct) = 0) then Exit;
    AccByte := IntOf(Acc, 'byteOffset', 0); BvByte := IntOf(Bv, 'byteOffset', 0);
    BvStride := IntOf(Bv, 'byteStride', 0);
    if BvStride = 0 then BvStride := Cc * CompSize(Ct);
    Base := BinOfs + BvByte + AccByte; Stride := BvStride; Result := True;
  end;

  procedure ReadVec3(Ai: Integer; var Dst: array of TTripoVec3; Ofs: Integer);
  var Base, Stride, Ct, Cc, Cnt, E, O: Integer;
  begin
    if not AccInfo(Ai, Base, Stride, Ct, Cc, Cnt) then Exit;
    if (Ct <> 5126) or (Cc < 3) then Exit;
    for E := 0 to Cnt-1 do
    begin O := Base + E*Stride; if O+12 > Length(Bytes) then Break;
      if Ofs+E > High(Dst) then Break;
      Dst[Ofs+E].X := ReadF(O); Dst[Ofs+E].Y := ReadF(O+4); Dst[Ofs+E].Z := ReadF(O+8); end;
  end;

  procedure ReadVec2(Ai: Integer; var Dst: array of TTripoVec2; Ofs: Integer);
  var Base, Stride, Ct, Cc, Cnt, E, O: Integer;
  begin
    if not AccInfo(Ai, Base, Stride, Ct, Cc, Cnt) then Exit;
    if (Ct <> 5126) or (Cc < 2) then Exit;       { only FLOAT UV in stage 1 }
    for E := 0 to Cnt-1 do
    begin O := Base + E*Stride; if O+8 > Length(Bytes) then Break;
      if Ofs+E > High(Dst) then Break;
      Dst[Ofs+E].X := ReadF(O); Dst[Ofs+E].Y := ReadF(O+4); end;
    HasTexCoords := True;
  end;

  procedure ReadJoints(Ai: Integer; Ofs: Integer);
  var Base, Stride, Ct, Cc, Cnt, E, O, Cs: Integer;
  begin
    if not AccInfo(Ai, Base, Stride, Ct, Cc, Cnt) then Exit;
    if Cc < 4 then Exit; Cs := CompSize(Ct);
    for E := 0 to Cnt-1 do
    begin O := Base + E*Stride; if O + 4*Cs > Length(Bytes) then Break;
      if Ofs+E >= Length(Joints) then Break;
      Joints[Ofs+E][0] := Word(ReadU(O,        Cs));
      Joints[Ofs+E][1] := Word(ReadU(O+Cs,     Cs));
      Joints[Ofs+E][2] := Word(ReadU(O+2*Cs,   Cs));
      Joints[Ofs+E][3] := Word(ReadU(O+3*Cs,   Cs)); end;
  end;

  procedure ReadWeights(Ai: Integer; Ofs: Integer);
  var Base, Stride, Ct, Cc, Cnt, E, O, Cs, M: Integer; sm, v: Single;
  begin
    if not AccInfo(Ai, Base, Stride, Ct, Cc, Cnt) then Exit;
    if Cc < 4 then Exit; Cs := CompSize(Ct);
    for E := 0 to Cnt-1 do
    begin
      O := Base + E*Stride; if O + 4*Cs > Length(Bytes) then Break;
      if Ofs+E >= Length(Weights) then Break;
      for M := 0 to 3 do
      begin
        case Ct of
          5126: v := ReadF(O + M*Cs);
          5121: v := ReadU(O + M*Cs, 1) / 255.0;
          5123: v := ReadU(O + M*Cs, 2) / 65535.0;
        else v := 0; end;
        Weights[Ofs+E][M] := v;
      end;
      sm := Weights[Ofs+E][0]+Weights[Ofs+E][1]+Weights[Ofs+E][2]+Weights[Ofs+E][3];
      if sm > 1e-8 then for M := 0 to 3 do Weights[Ofs+E][M] := Weights[Ofs+E][M] / sm;
    end;
  end;

  procedure AppendIndices(Ai: Integer; VertOfs, VertN: Integer);
  var Base, Stride, Ct, Cc, Cnt, E, O, Cs, Old: Integer;
  begin
    Old := Length(Indices);
    if Ai < 0 then
    begin
      SetLength(Indices, Old + VertN);
      for E := 0 to VertN-1 do Indices[Old+E] := LongWord(VertOfs + E);
      Exit;
    end;
    if not AccInfo(Ai, Base, Stride, Ct, Cc, Cnt) then Exit;
    Cs := CompSize(Ct); SetLength(Indices, Old + Cnt);
    for E := 0 to Cnt-1 do
    begin O := Base + E*Stride; if O + Cs > Length(Bytes) then Break;
      Indices[Old+E] := ReadU(O, Cs) + LongWord(VertOfs); end;
  end;

  procedure ReadInvBind(Ai: Integer);
  var Base, Stride, Ct, Cc, Cnt, E, O, M: Integer;
  begin
    for E := 0 to JointCount-1 do InvBind[E] := Mat4Identity;
    if Ai < 0 then Exit;
    if not AccInfo(Ai, Base, Stride, Ct, Cc, Cnt) then Exit;
    if (Ct <> 5126) or (Cc < 16) then Exit;
    for E := 0 to JointCount-1 do
    begin
      if E >= Cnt then Break;
      O := Base + E*Stride; if O + 64 > Length(Bytes) then Break;
      for M := 0 to 15 do InvBind[E][M] := ReadF(O + M*4);
    end;
  end;

  { local TRS (or matrix) of a glTF node as a column-major Mat4 (scale included) }
  function NodeLocalMat(NodeIdx: Integer): TTripoMat4;
  var Nd2: TJSONObject; MA, TA, RA, SA: TJSONArray;
      T, Sc: TTripoVec3; R: TTripoVec4; m: Integer;
  begin
    Result := Mat4Identity;
    if (NodeIdx < 0) or (NodeIdx >= NodeCount) then Exit;
    Nd2 := ObjAt(NodesA, NodeIdx); if Nd2 = nil then Exit;
    MA := ArrOf(Nd2, 'matrix');
    if (MA <> nil) and (MA.Count >= 16) then
    begin
      for m := 0 to 15 do Result[m] := MA.Items[m].AsFloat;   { glTF matrix is column-major }
      Exit;
    end;
    T.X:=0; T.Y:=0; T.Z:=0; Sc.X:=1; Sc.Y:=1; Sc.Z:=1; R.X:=0; R.Y:=0; R.Z:=0; R.W:=1;
    TA := ArrOf(Nd2, 'translation');
    if (TA<>nil) and (TA.Count>=3) then begin T.X:=TA.Items[0].AsFloat; T.Y:=TA.Items[1].AsFloat; T.Z:=TA.Items[2].AsFloat; end;
    RA := ArrOf(Nd2, 'rotation');
    if (RA<>nil) and (RA.Count>=4) then begin R.X:=RA.Items[0].AsFloat; R.Y:=RA.Items[1].AsFloat; R.Z:=RA.Items[2].AsFloat; R.W:=RA.Items[3].AsFloat; end;
    SA := ArrOf(Nd2, 'scale');
    if (SA<>nil) and (SA.Count>=3) then begin Sc.X:=SA.Items[0].AsFloat; Sc.Y:=SA.Items[1].AsFloat; Sc.Z:=SA.Items[2].AsFloat; end;
    Result := Mat4FromTRS(T, R, Sc);
  end;

  { global transform of a node = compose its local with every ancestor's local }
  function NodeGlobalMat(NodeIdx: Integer): TTripoMat4;
  var p, guard: Integer;
  begin
    Result := NodeLocalMat(NodeIdx);
    p := -1;
    if (NodeIdx >= 0) and (NodeIdx < NodeCount) then p := ParentNode[NodeIdx];
    guard := 0;
    while (p >= 0) and (p < NodeCount) and (guard < NodeCount) do
    begin
      Result := Mat4Mul(NodeLocalMat(p), Result);
      p := ParentNode[p]; Inc(guard);
    end;
  end;

begin
  Result := False;
  FOrderValid := False;   { топологический порядок — по новым JointParent }
  SetLength(FNameKeys, 0); SetLength(FNameVals, 0);   { кэш имён — по новым JointName }
  if not FileExists(FileName) then begin Err('file not found'); Exit; end;
  try
    FS := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
    try SetLength(Bytes, FS.Size); if FS.Size > 0 then FS.ReadBuffer(Bytes[0], FS.Size);
    finally FS.Free; end;
  except on E: Exception do begin Err('read error: ' + E.Message); Exit; end; end;

  if (Length(Bytes) < 12) or (U32(Bytes,0) <> GLB_MAGIC) then
  begin Err('not a GLB binary'); Exit; end;
  ExtractGltfJson(Bytes, JsonStr, BinOfs, BinLen);
  if JsonStr = '' then begin Err('no JSON chunk'); Exit; end;
  if BinLen = 0 then begin Err('no BIN chunk (external buffers unsupported)'); Exit; end;

  RootD := nil;
  try RootD := GetJSON(JsonStr);
  except on E: Exception do begin Err('JSON parse: ' + E.Message); Exit; end; end;
  if (RootD = nil) or (RootD.JSONType <> jtObject) then
  begin Err('JSON root not object'); if RootD <> nil then RootD.Free; Exit; end;

  Root := TJSONObject(RootD);
  try
    NodesA := ArrOf(Root,'nodes'); SkinsA := ArrOf(Root,'skins');
    MeshesA := ArrOf(Root,'meshes'); AccA := ArrOf(Root,'accessors');
    BVA := ArrOf(Root,'bufferViews');
    if (NodesA=nil) or (SkinsA=nil) or (MeshesA=nil) or (AccA=nil) or (BVA=nil) then
    begin Err('glTF missing core arrays'); Exit; end;

    { Body mesh = most skinned verts across ALL its primitives. After Split,
      Head is the largest single prim and a one-prim load stuck the hem
      bound on the neck. Helmet/accessories stay on other meshes. }
    MeshIdx:=-1; SkinIdx:=-1;
    PosAcc:=-1; NrmAcc:=-1; UvAcc:=-1; JntAcc:=-1; WgtAcc:=-1; IdxAcc:=-1;
    BestVerts := -1;
    for I := 0 to MeshesA.Count-1 do
    begin
      MeshObj := ObjAt(MeshesA, I); Prims := ArrOf(MeshObj,'primitives');
      if Prims = nil then Continue;
      SumVerts := 0;
      for J := 0 to Prims.Count-1 do
      begin
        Prim := ObjAt(Prims, J); Attrs := ObjOf(Prim,'attributes');
        if (Attrs = nil) or (Attrs.Find('JOINTS_0') = nil) then Continue;
        K := IntOf(Attrs,'POSITION',-1);
        if K >= 0 then K := IntOf(ObjAt(AccA, K), 'count', 0) else K := 0;
        SumVerts := SumVerts + K;
      end;
      if SumVerts > BestVerts then
      begin
        BestVerts := SumVerts;
        MeshIdx := I;
      end;
    end;
    if MeshIdx < 0 then begin Err('no skinned primitive (JOINTS_0)'); Exit; end;

    { skin from the node referencing this mesh }
    NodeCount := NodesA.Count;
    MeshNodeIdx := -1;
    for I := 0 to NodeCount-1 do
    begin Nd := ObjAt(NodesA,I);
      if (IntOf(Nd,'mesh',-1)=MeshIdx) and (Nd.Find('skin')<>nil) then
      begin SkinIdx := IntOf(Nd,'skin',-1); MeshNodeIdx := I; Break; end; end;
    if SkinIdx < 0 then SkinIdx := 0;
    Sk := ObjAt(SkinsA, SkinIdx); JointsArr := ArrOf(Sk,'joints');
    IbmAcc := IntOf(Sk,'inverseBindMatrices',-1);
    if (JointsArr=nil) or (JointsArr.Count=0) then begin Err('skin has no joints'); Exit; end;

    VertexCount := 0;
    HasTexCoords := False;
    SetLength(Positions, 0); SetLength(Normals, 0); SetLength(TexCoords, 0);
    SetLength(Joints, 0); SetLength(Weights, 0); SetLength(Indices, 0);
    { Contacts must sample the complete rider. The largest mesh in a split
      anatomical model can be its head; using only it pinned hands/cleats
      to head weights instead of their actual surfaces. }
    for ReadMesh := 0 to MeshesA.Count - 1 do
    begin
      MeshUsesSkin := False;
      for ReadNode := 0 to NodeCount - 1 do
      begin
        Nd := ObjAt(NodesA, ReadNode);
        if (IntOf(Nd, 'mesh', -1) = ReadMesh) and
           (IntOf(Nd, 'skin', -1) = SkinIdx) then MeshUsesSkin := True;
      end;
      if not MeshUsesSkin then Continue;
      MeshObj := ObjAt(MeshesA, ReadMesh);
      Prims := ArrOf(MeshObj, 'primitives');
      if Prims <> nil then
      for J := 0 to Prims.Count-1 do
      begin
        Prim := ObjAt(Prims, J); Attrs := ObjOf(Prim, 'attributes');
        if (Attrs = nil) or (Attrs.Find('JOINTS_0') = nil) then Continue;
        PosAcc := IntOf(Attrs, 'POSITION', -1);
        if PosAcc < 0 then Continue;
        VertN := IntOf(ObjAt(AccA, PosAcc), 'count', 0);
        if VertN <= 0 then Continue;
        NrmAcc := IntOf(Attrs, 'NORMAL', -1);
        UvAcc  := IntOf(Attrs, 'TEXCOORD_0', -1);
        JntAcc := IntOf(Attrs, 'JOINTS_0', -1);
        WgtAcc := IntOf(Attrs, 'WEIGHTS_0', -1);
        IdxAcc := IntOf(Prim, 'indices', -1);
        OldVC := VertexCount;
        VertexCount := VertexCount + VertN;
        SetLength(Positions, VertexCount); SetLength(Normals, VertexCount);
        SetLength(TexCoords, VertexCount); SetLength(Joints, VertexCount);
        SetLength(Weights, VertexCount);
        for I := OldVC to VertexCount-1 do
        begin
          Normals[I].X:=0; Normals[I].Y:=0; Normals[I].Z:=1;
          TexCoords[I].X:=0; TexCoords[I].Y:=0;
          Joints[I][0]:=0; Joints[I][1]:=0; Joints[I][2]:=0; Joints[I][3]:=0;
          Weights[I][0]:=1; Weights[I][1]:=0; Weights[I][2]:=0; Weights[I][3]:=0;
        end;
        ReadVec3(PosAcc, Positions, OldVC);
        if NrmAcc >= 0 then ReadVec3(NrmAcc, Normals, OldVC);
        if UvAcc  >= 0 then ReadVec2(UvAcc, TexCoords, OldVC);
        ReadJoints(JntAcc, OldVC);
        if WgtAcc >= 0 then ReadWeights(WgtAcc, OldVC);
        AppendIndices(IdxAcc, OldVC, VertN);
      end;
    end;
    if VertexCount <= 0 then begin Err('POSITION count 0'); Exit; end;

    { skeleton }
    JointCount := JointsArr.Count;
    SetLength(JointName, JointCount); SetLength(JointNode, JointCount);
    SetLength(JointParent, JointCount); SetLength(InvBind, JointCount);
    SetLength(BindWorld, JointCount); SetLength(BindLocal, JointCount);

    SetLength(NodeToPalette, NodeCount);
    for I := 0 to NodeCount-1 do NodeToPalette[I] := -1;
    for J := 0 to JointCount-1 do
    begin
      NodeI := ArrInt(JointsArr, J, -1);
      JointNode[J] := NodeI;
      if (NodeI >= 0) and (NodeI < NodeCount) then NodeToPalette[NodeI] := J;
      if (NodeI >= 0) and (NodeI < NodeCount) then
        JointName[J] := CanonicalJointName(
          StrOf(ObjAt(NodesA, NodeI), 'name', 'joint#'+IntToStr(J)))
      else JointName[J] := 'joint#'+IntToStr(J);
    end;

    { parent map over all nodes }
    SetLength(ParentNode, NodeCount);
    for I := 0 to NodeCount-1 do ParentNode[I] := -1;
    for I := 0 to NodeCount-1 do
    begin
      ChildA := ArrOf(ObjAt(NodesA,I),'children');
      if ChildA <> nil then
        for K := 0 to ChildA.Count-1 do
        begin J := ArrInt(ChildA,K,-1);
          if (J>=0) and (J<NodeCount) then ParentNode[J] := I; end;
    end;

    for J := 0 to JointCount-1 do
    begin
      NodeI := JointNode[J]; ParI := -1;
      if (NodeI>=0) and (NodeI<NodeCount) then ParI := ParentNode[NodeI];
      if (ParI>=0) and (ParI<NodeCount) then JointParent[J] := NodeToPalette[ParI]
      else JointParent[J] := -1;
    end;

    ReadInvBind(IbmAcc);
    SetLength(NativeInvBind, JointCount);
    for J := 0 to JointCount-1 do NativeInvBind[J] := InvBind[J];
    { Bind world per joint = the joint node's GLOBAL rest transform composed straight
      down the node tree (RootNode..Armature..Root..joint) — EXACTLY what CGE uses to
      skin the mesh. For a spec-compliant file (skeleton root: none) this equals
      inverse(invBind); composing the chain ourselves is what makes it robust to an
      extra wrapper node above the Armature. The previous code did
      inverse(invBind) THEN folded the mesh-node global on top — but inverse(invBind)
      is already scene-space, so any RootNode/Armature ROTATION got applied twice. That
      double-count left FRig's bind rotated relative to the bind CGE actually skins
      from, so the IK deltas posed the mesh on its side (legs still reached the pedals
      because the IK<->Scene loop is self-consistent, but the torso rolled over). One
      clean composition fixes it for any hierarchy; scale is included once here and
      cancels in InvBind below. }
    for J := 0 to JointCount-1 do
      if JointNode[J] >= 0 then BindWorld[J] := NodeGlobalMat(JointNode[J])
      else BindWorld[J] := Mat4Inverse(InvBind[J]);

    for J := 0 to JointCount-1 do
    begin
      if JointParent[J] < 0 then BindLocal[J] := BindWorld[J]
      else BindLocal[J] := Mat4Mul(Mat4Inverse(BindWorld[JointParent[J]]), BindWorld[J]);
    end;
    { keep InvBind consistent with the rescaled bind (SkinMatrix = identity at rest) }
    for J := 0 to JointCount-1 do InvBind[J] := Mat4Inverse(BindWorld[J]);

    ResetPose;
    ComputePose;
    BuildNameIndex;   { кэш имя→индекс для горячих JointIndexByName }
    Result := True;
  finally
    RootD.Free;
  end;
end;

{ ===================== vector / quaternion / IK ===================== }

function QIdent: TTripoVec4;
begin Result.X:=0; Result.Y:=0; Result.Z:=0; Result.W:=1; end;

function V3(X, Y, Z: Single): TTripoVec3;
begin Result.X:=X; Result.Y:=Y; Result.Z:=Z; end;
function V3Sub(const A, B: TTripoVec3): TTripoVec3;
begin Result.X:=A.X-B.X; Result.Y:=A.Y-B.Y; Result.Z:=A.Z-B.Z; end;
function V3Add(const A, B: TTripoVec3): TTripoVec3;
begin Result.X:=A.X+B.X; Result.Y:=A.Y+B.Y; Result.Z:=A.Z+B.Z; end;
function V3Scale(const A: TTripoVec3; S: Single): TTripoVec3;
begin Result.X:=A.X*S; Result.Y:=A.Y*S; Result.Z:=A.Z*S; end;
function V3Dot(const A, B: TTripoVec3): Single;
begin Result := A.X*B.X + A.Y*B.Y + A.Z*B.Z; end;
function V3Cross(const A, B: TTripoVec3): TTripoVec3;
begin
  Result.X := A.Y*B.Z - A.Z*B.Y;
  Result.Y := A.Z*B.X - A.X*B.Z;
  Result.Z := A.X*B.Y - A.Y*B.X;
end;
function V3Len(const A: TTripoVec3): Single;
begin Result := Sqrt(A.X*A.X + A.Y*A.Y + A.Z*A.Z); end;
function V3Norm(const A: TTripoVec3): TTripoVec3;
var L: Single;
begin
  L := V3Len(A);
  if L < 1e-12 then begin Result := V3(0,0,0); Exit; end;
  Result := V3Scale(A, 1.0/L);
end;

function QuatConj(const Q: TTripoVec4): TTripoVec4;
begin Result.X:=-Q.X; Result.Y:=-Q.Y; Result.Z:=-Q.Z; Result.W:=Q.W; end;
function QuatNormalize(const Q: TTripoVec4): TTripoVec4;
var L: Single;
begin
  L := Sqrt(Q.X*Q.X+Q.Y*Q.Y+Q.Z*Q.Z+Q.W*Q.W);
  if L < 1e-12 then begin Result := QIdent; Exit; end;
  Result.X:=Q.X/L; Result.Y:=Q.Y/L; Result.Z:=Q.Z/L; Result.W:=Q.W/L;
end;
function QuatRotateV3(const Q: TTripoVec4; const V: TTripoVec3): TTripoVec3;
var qv, t: TTripoVec3;
begin
  qv := V3(Q.X, Q.Y, Q.Z);
  t := V3Scale(V3Cross(qv, V), 2.0);
  Result := V3Add(V, V3Add(V3Scale(t, Q.W), V3Cross(qv, t)));
end;
function QuatFromTo(const AFrom, ATo: TTripoVec3): TTripoVec4;
var a, b, axis: TTripoVec3; d, s, invs: Single;
begin
  a := V3Norm(AFrom); b := V3Norm(ATo);
  d := V3Dot(a, b);
  if d >= 0.999999 then begin Result := QIdent; Exit; end;
  if d <= -0.999999 then
  begin
    axis := V3Cross(V3(1,0,0), a);
    if V3Len(axis) < 1e-6 then axis := V3Cross(V3(0,1,0), a);
    axis := V3Norm(axis);
    Result.X:=axis.X; Result.Y:=axis.Y; Result.Z:=axis.Z; Result.W:=0;
    Exit;
  end;
  axis := V3Cross(a, b);
  s := Sqrt((1.0 + d) * 2.0);
  invs := 1.0 / s;
  Result.X := axis.X*invs; Result.Y := axis.Y*invs; Result.Z := axis.Z*invs;
  Result.W := s * 0.5;
  Result := QuatNormalize(Result);
end;

function Mat4ToQuat(const M: TTripoMat4): TTripoVec4;
var c0, c1, c2: TTripoVec3; r: TTripoMat4; tr, s: Single;
begin
  c0 := V3Norm(V3(M[0], M[1], M[2]));   { basis columns, scale stripped }
  c1 := V3Norm(V3(M[4], M[5], M[6]));
  c2 := V3Norm(V3(M[8], M[9], M[10]));
  r := Mat4Identity;
  r[0]:=c0.X; r[1]:=c0.Y; r[2]:=c0.Z;
  r[4]:=c1.X; r[5]:=c1.Y; r[6]:=c1.Z;
  r[8]:=c2.X; r[9]:=c2.Y; r[10]:=c2.Z;
  tr := r[0] + r[5] + r[10];
  if tr > 0 then
  begin
    s := Sqrt(tr + 1.0) * 2.0;
    Result.W := 0.25*s; Result.X := (r[6]-r[9])/s; Result.Y := (r[8]-r[2])/s; Result.Z := (r[1]-r[4])/s;
  end
  else if (r[0] > r[5]) and (r[0] > r[10]) then
  begin
    s := Sqrt(1.0 + r[0] - r[5] - r[10]) * 2.0;
    Result.W := (r[6]-r[9])/s; Result.X := 0.25*s; Result.Y := (r[4]+r[1])/s; Result.Z := (r[8]+r[2])/s;
  end
  else if r[5] > r[10] then
  begin
    s := Sqrt(1.0 + r[5] - r[0] - r[10]) * 2.0;
    Result.W := (r[8]-r[2])/s; Result.X := (r[4]+r[1])/s; Result.Y := 0.25*s; Result.Z := (r[9]+r[6])/s;
  end
  else
  begin
    s := Sqrt(1.0 + r[10] - r[0] - r[5]) * 2.0;
    Result.W := (r[1]-r[4])/s; Result.X := (r[8]+r[2])/s; Result.Y := (r[9]+r[6])/s; Result.Z := 0.25*s;
  end;
  Result := QuatNormalize(Result);
end;

function SolveJoint(const Root, Target: TTripoVec3; L1, L2: Single;
  const PlaneHint: TTripoVec3; SoftReach: Single): TTripoVec3;
var rt, dir, perp, base: TTripoVec3; d, a, h, over: Single;
begin
  rt := V3Sub(Target, Root);
  d := V3Len(rt);
  if d < 1e-6 then begin Result := V3Add(Root, V3(0, L1, 0)); Exit; end;
  dir := V3Scale(rt, 1.0/d);                 { unit Root->Target (real direction) }
  { The virtual knee->cleat chain only chooses foot orientation. Ease its reach
    limit to avoid a singular straight chain; the final ankle IK stays exact. }
  if (SoftReach > 0) and (d > L1 + L2 - SoftReach) then
  begin
    over := d - (L1 + L2 - SoftReach);
    d := L1 + L2 - SoftReach + over / (1 + over / SoftReach);
  end;
  if d > L1 + L2 - 1e-5 then d := L1 + L2 - 1e-5;
  if d < Abs(L1 - L2) + 1e-5 then d := Abs(L1 - L2) + 1e-5;
  a := (d*d + L1*L1 - L2*L2) / (2.0 * d);
  h := L1*L1 - a*a; if h < 0 then h := 0; h := Sqrt(h);
  base := V3Add(Root, V3Scale(dir, a));
  perp := V3Sub(PlaneHint, V3Scale(dir, V3Dot(dir, PlaneHint)));  { perp component }
  if V3Len(perp) < 1e-6 then
  begin
    perp := V3Cross(dir, V3(0, 0, 1));
    if V3Len(perp) < 1e-6 then perp := V3Cross(dir, V3(0, 1, 0));
  end;
  perp := V3Norm(perp);
  Result := V3Add(base, V3Scale(perp, h));
end;

function TTripoRig.SolveJointStable(MidIdx: Integer; const Root, Target: TTripoVec3;
  L1, L2: Single; const PlaneHint: TTripoVec3): TTripoVec3;
const
  cMinPerp  = 0.04;   { below this the hint's in-plane direction is unreliable -> reuse last bend }
var
  rt, dir, perp, base, phn, cached, projc: TTripoVec3;
  d, a, h, lp, lc: Single;
begin
  rt := V3Sub(Target, Root);
  d := V3Len(rt);
  if d < 1e-6 then begin Result := V3Add(Root, V3(0, L1, 0)); Exit; end;
  dir := V3Scale(rt, 1.0/d);
  if d > L1 + L2 - 1e-5 then d := L1 + L2 - 1e-5;
  if d < Abs(L1 - L2) + 1e-5 then d := Abs(L1 - L2) + 1e-5;
  a := (d*d + L1*L1 - L2*L2) / (2.0 * d);
  h := L1*L1 - a*a; if h < 0 then h := 0; h := Sqrt(h);
  base := V3Add(Root, V3Scale(dir, a));

  { raw bend direction from the (normalized) hint, perpendicular to dir }
  phn := PlaneHint;
  if V3Len(phn) > 1e-9 then phn := V3Norm(phn);
  perp := V3Sub(phn, V3Scale(dir, V3Dot(dir, phn)));
  lp := V3Len(perp);

  { last frame's bend direction, re-projected perpendicular to the current dir }
  cached := V3(0, 0, 0);
  if (MidIdx >= 0) and (MidIdx < Length(BendCache)) then cached := BendCache[MidIdx];
  projc := V3Sub(cached, V3Scale(dir, V3Dot(dir, cached)));
  lc := V3Len(projc);

  if lp < cMinPerp then
  begin
    { at the hint singularity the in-plane direction is undefined -> keep the previous bend }
    if lc > 1e-4 then perp := projc
    else begin
      perp := V3Cross(dir, V3(0, 0, 1));
      if V3Len(perp) < 1e-6 then perp := V3Cross(dir, V3(0, 1, 0));
    end;
  end;
  { When the hint IS reliable (lp >= cMinPerp) we FOLLOW it as computed above — we do NOT
    force perp back to the cached side. The earlier unconditional "mirror to cached side"
    locked a STALE bend: when a pose legitimately moved the elbow to the other side, it was
    yanked back to the old cached side, so one arm's elbow stuck (e.g. winged 'up') while
    the mirror arm solved correctly — an L/R asymmetry at equal params. The per-frame reach
    flip that the hold was meant to suppress is now prevented at the source by the reach-
    sphere clamps in RiderTripo, so following the symmetric hint keeps both elbows mirrored.
    The cache is still updated below and used only to bridge the singularity case above. }

  perp := V3Norm(perp);
  if (MidIdx >= 0) and (MidIdx < Length(BendCache)) then BendCache[MidIdx] := perp;
  Result := V3Add(base, V3Scale(perp, h));
end;

function TTripoRig.JointWorldRot(J: Integer): TTripoVec4;
begin
  if (J<0) or (J>=JointCount) or (Length(WorldPose)<JointCount) then
  begin Result := QIdent; Exit; end;
  Result := Mat4ToQuat(WorldPose[J]);
end;

function TTripoRig.DeltaQuat(J: Integer): TTripoVec4;
begin
  if (J<0) or (J>=JointCount) or (Length(Delta)<JointCount) then
  begin Result := QIdent; Exit; end;
  Result := Mat4ToQuat(Delta[J]);
end;

procedure TTripoRig.SolveTwoBone(UpperIdx, MidIdx, EndIdx: Integer;
  const TargetWorld, PlaneHint: TTripoVec3; Stabilize: Boolean);
var
  HipPos, MidPos, Knee, BoneAxis, CurDir, TgtLocal: TTripoVec3;
  L1, L2: Single;
  ParWorldRot, CWR: TTripoVec4;
  P: Integer;
begin
  if (UpperIdx<0) or (MidIdx<0) or (EndIdx<0) then Exit;
  if (UpperIdx>=JointCount) or (MidIdx>=JointCount) or (EndIdx>=JointCount) then Exit;
  if Length(WorldPose) < JointCount then ComputePose;
  if Stabilize and (Length(BendCache) < JointCount) then SetLength(BendCache, JointCount);

  HipPos := JointWorldPos(UpperIdx);
  L1 := V3Len(V3Sub(JointBindPos(MidIdx), JointBindPos(UpperIdx)));
  L2 := V3Len(V3Sub(JointBindPos(EndIdx), JointBindPos(MidIdx)));
  if Stabilize then
    Knee := SolveJointStable(MidIdx, HipPos, TargetWorld, L1, L2, PlaneHint)
  else
    Knee := SolveJoint(HipPos, TargetWorld, L1, L2, PlaneHint);

  { upper joint: aim its bone (Upper->Mid) from HipPos toward Knee }
  P := JointParent[UpperIdx];
  if P < 0 then ParWorldRot := QIdent else ParWorldRot := JointWorldRot(P);
  CWR := QuatMul(ParWorldRot, Mat4ToQuat(BindLocal[UpperIdx]));   { Upper world rot pre-delta }
  BoneAxis := V3Norm(QuatRotateV3(QuatConj(Mat4ToQuat(BindWorld[UpperIdx])),
    V3Sub(JointBindPos(MidIdx), JointBindPos(UpperIdx))));
  CurDir := V3Norm(V3Sub(Knee, HipPos));
  TgtLocal := QuatRotateV3(QuatConj(CWR), CurDir);
  Delta[UpperIdx] := Mat4FromQuat(QuatFromTo(BoneAxis, TgtLocal));
  ComputePoseFrom(UpperIdx);   { OPT: Mid/End — потомки Upper, покрыты частичным пересчётом }

  { mid joint: aim its bone (Mid->End) from MidPos toward Target }
  MidPos := JointWorldPos(MidIdx);
  P := JointParent[MidIdx];
  if P < 0 then ParWorldRot := QIdent else ParWorldRot := JointWorldRot(P);
  CWR := QuatMul(ParWorldRot, Mat4ToQuat(BindLocal[MidIdx]));
  { Twist helpers may sit between the elbow and wrist. BindLocal[EndIdx]
    then measures only the last helper segment, in a different frame. }
  BoneAxis := V3Norm(QuatRotateV3(QuatConj(Mat4ToQuat(BindWorld[MidIdx])),
    V3Sub(JointBindPos(EndIdx), JointBindPos(MidIdx))));
  CurDir := V3Norm(V3Sub(TargetWorld, MidPos));
  TgtLocal := QuatRotateV3(QuatConj(CWR), CurDir);
  Delta[MidIdx] := Mat4FromQuat(QuatFromTo(BoneAxis, TgtLocal));
  ComputePoseFrom(MidIdx);   { OPT: End — потомок Mid }
end;

procedure TTripoRig.AimLegContact(UpperIdx, MidIdx, EndIdx: Integer;
  const TargetWorld, PlaneHint, ContactLocal: TTripoVec3;
  const FootTurn: TTripoVec4; out FootRotation: TTripoVec4;
  out AnkleTarget: TTripoVec3);
var
  Root, MidBind, EndBind, UpperAxis, ContactAxis, EffectiveLower: TTripoVec3;
  Aim, Knee, KneePos, UpperDir, LowerDir: TTripoVec3;
  UR, MR, ER, QU, QM, QMPre, NaturalFoot: TTripoVec4;
  L1, ContactLength: Single;
  Pass: Integer;
begin
  FootRotation := FootTurn;
  AnkleTarget := TargetWorld;
  if (UpperIdx < 0) or (MidIdx < 0) or (EndIdx < 0) or
     (UpperIdx >= JointCount) or (MidIdx >= JointCount) or
     (EndIdx >= JointCount) then Exit;
  if Length(WorldPose) < JointCount then ComputePose;
  Root := JointWorldPos(UpperIdx);
  MidBind := JointWorldPos(MidIdx);
  EndBind := JointWorldPos(EndIdx);
  UR := JointWorldRot(UpperIdx);
  MR := JointWorldRot(MidIdx);
  ER := JointWorldRot(EndIdx);
  L1 := V3Len(V3Sub(MidBind, Root));
  UpperAxis := V3Norm(QuatRotateV3(QuatConj(UR), V3Sub(MidBind, Root)));
  EffectiveLower := V3Add(QuatRotateV3(QuatConj(MR), V3Sub(EndBind, MidBind)),
    QuatRotateV3(QuatMul(QuatConj(MR), ER), ContactLocal));
  ContactLength := V3Len(EffectiveLower);
  FootRotation := QuatMul(FootTurn, ER);
  AnkleTarget := V3Sub(TargetWorld, QuatRotateV3(FootRotation, ContactLocal));
  if (L1 < 1e-6) or (ContactLength < 1e-6) then Exit;
  ContactAxis := V3Norm(EffectiveLower);
  Aim := TargetWorld;
  { Only foot yaw/pitch needs refinement. The initial solve already accounts
    for foot length, so a reachable cleat never falsely straightens the knee. }
  for Pass := 0 to 2 do
  begin
    Knee := SolveJoint(Root, Aim, L1, ContactLength, PlaneHint,
      0.02 * (L1 + ContactLength));
    UpperDir := V3Norm(V3Sub(Knee, Root));
    QU := QuatMul(QuatFromTo(QuatRotateV3(UR, UpperAxis), UpperDir), UR);
    KneePos := V3Add(Root, V3Scale(UpperDir, L1));
    QMPre := QuatMul(QU, QuatMul(QuatConj(UR), MR));
    LowerDir := V3Norm(V3Sub(Aim, KneePos));
    QM := QuatMul(QuatFromTo(QuatRotateV3(QMPre, ContactAxis), LowerDir), QMPre);
    NaturalFoot := QuatMul(QM, QuatMul(QuatConj(MR), ER));
    FootRotation := QuatMul(FootTurn, NaturalFoot);
    Aim := V3Add(TargetWorld, V3Sub(QuatRotateV3(NaturalFoot, ContactLocal),
      QuatRotateV3(FootRotation, ContactLocal)));
  end;
  AnkleTarget := V3Sub(TargetWorld, QuatRotateV3(FootRotation, ContactLocal));
end;

procedure TTripoRig.ApplyWorldPitch(const AName: string;
  AxisX, AxisY, AxisZ, AngleRad: Single);
begin
  ApplyWorldPitchByIndex(JointIndexByName(AName), AxisX, AxisY, AxisZ, AngleRad);
end;

procedure TTripoRig.ApplyWorldPitchByIndex(J: Integer;
  AxisX, AxisY, AxisZ, AngleRad: Single);
begin
  ApplyWorldRotationByIndex(J, QuatFromAxisAngle(AxisX, AxisY, AxisZ, AngleRad));
end;

procedure TTripoRig.ApplyWorldRotationByIndex(J: Integer; const WorldQ: TTripoVec4);
var
  P: Integer;
  CWR, LocalDelta: TTripoVec4;
begin
  if (J < 0) or (J >= JointCount) then Exit;
  if Length(WorldPose) < JointCount then ComputePose;
  P := JointParent[J];
  if P < 0 then CWR := Mat4ToQuat(BindLocal[J])
  else CWR := QuatMul(JointWorldRot(P), Mat4ToQuat(BindLocal[J]));  { pre-delta world rot }
  { express the world rotation in the joint's local frame: conj(CWR)*W*CWR }
  LocalDelta := QuatMul(QuatMul(QuatConj(CWR), WorldQ), CWR);
  Delta[J] := Mat4FromQuat(LocalDelta);
  ComputePoseFrom(J);   { OPT: затронуты только J и его потомки }
end;

end.

{
  RiderTripo — Strategy A runtime layer (CGE native skinning).

  Loads the Tripo cyclist glb as a normal CastleScene. CGE 7.0-alpha builds a
  TSkinNode and GPU-skins it automatically every frame from the joints' current
  transforms (TSkinNode.BeforeTraverse -> InternalJointMatrix). So we do NOT
  skin anything ourselves: we just drive the joint Transform nodes, and the mesh
  deforms with the model's own authored 4-influence weights.

  Each glTF node becomes a TTransformNode whose X3DName = the glTF node name
  (x3dloadinternalgltf.pas: Transform.X3DName := Node.Name). The joints are
  bound from TSkinNode.FdJoints — the exact TTransformNode instances of the
  armature that skins the mesh, in palette order — NOT by a global name
  search: a glb can carry a second leftover armature with the same bone
  names, and a name search would silently bind to that dead skeleton.

  We reuse the tested TripoRig unit purely for skeleton METADATA — the joint
  names in palette order, the hierarchy, and the bind matrices — which the IK
  layer (next stage) needs. TripoRig does no skinning here; CGE does it.

  Driving a joint:
    we capture each joint's REST local rotation at load, and per frame set
    node.Rotation := (restQuat * deltaQuat).ToAxisAngle
  i.e. the bind orientation with an extra local-frame delta on top (non-
  accumulating: always composed from the fixed rest, so a zero delta == bind).

  This unit is API-faithful to CGE 7.0-alpha (verified against the engine
  source) but is not compiled here — build it inside your Lazarus project.

  License: MIT
}
unit RiderTripo;

{$mode objfpc}{$H+}
{$codepage utf8}   { source is UTF-8; makes the Cyrillic pose-name literal reliable
                     (ASCII joint-name literals are unaffected) }

interface

uses RiderClothShader,
  Classes, SysUtils, Types, Math, fpjson, jsonparser,
  CastleUtils, CastleVectors, CastleQuaternions, CastleScene, CastleTransform, X3DNodes,
  X3DFields, CastleBoxes, CastleImages, CastleRenderOptions, TripoRig,
  BikeLog, GltfCore, X3DLoad, CastleURIUtils, RiderPoseCorrectives, RiderEquipment, RiderMotion;

type
  { ── A named body-pose preset: the posture fields plus the saddle-relative
    offset. Scale/yaw/visibility are calibration, not pose, and stay out. ── }
  TRiderPose = record
    Name: string;
    OffsetX, OffsetY, OffsetZ: Single;   { fine offset of rig origin vs saddle }
    TorsoLeanDeg: Single;
    SpineCurve: Single;
    SpineManual: Boolean;
    SpineAngles: TSpineAngles;
    SpineYaw, SpineRoll: TSpineAngles; { transient frame rotations, degrees }
    Motion: TRiderMotionProfile;
    KneeFlare, ElbowFlare: Single;
    AnkleFlex: Single;
    ArmPronationR, ArmPronationL: Single;
    ShoulderRoundDeg: Single;
    HandLevel: Single;                   { wrist leveling 0..1: 1 = hand fully parallel to the ground }
    PedalSway: Single;                   { lateral body sway amplitude (in time with pedals) }
    TorsoBobAmp: Single;                 { vertical torso bob amplitude }
    HandPosR, HandPosL: Integer;         { bar grip each hand uses (1-based); 0 = free hand }
    HandFreeRPos, HandFreeLPos: TVector3;{ free hand target (when HandPos=0), bike frame }
    HandFreeRWave, HandFreeLWave: Single;{ free-hand wave amplitude (bob in time with pedals) }
    LegFreeR, LegFreeL: Single;          { 0 = foot on pedal (pedalling), 1 = free static foot }
    LegFreeRPos, LegFreeLPos: TVector3;  { free foot target in bike frame (X fwd, Y up, Z lateral) }

    { ── pose-selection metadata (used by the game's automatic pose picker;
         ignored by the visual rig) ── }
    Special: Boolean;                    { true = event-driven pose (e.g. drinking) — the auto
                                           picker SKIPS it; it is triggered by its own event }
    Grounded: Boolean;                   { support on the ground; crank must be held }
    SelPriority: Integer;                { higher wins when several auto poses match the situation }
    SelSpeedMin, SelSpeedMax: Single;    { speed window this pose covers, km/h (0..999 = any) }
    SelIntensityMin, SelIntensityMax: Single; { effort window = power / FTP, fraction (0..9 = any) }
    SelGradeMin, SelGradeMax: Single;    { road grade window, % (-99..99 = any) }
    TurnSuitable: Boolean;               { true = a cornering pose: chosen in sharp turns, skipped on straights }
  end;

{ The built-in pose used whenever a list has nothing to load. }
function DefaultRiderPose: TRiderPose;
{ Auto torso lean in degrees for spine slots 0..4 (Waist, Spine, Spine01,
  Spine02, NeckTwist01). Waist is left at 0 — pitching it folds the jersey
  at the belt. Duplicate palette indices (old Spine/Spine01 alias) count once. }
procedure SpineAutoLeanDeg(LeanDeg, Curve: Single;
  const JointIdx: array of Integer; var AngDeg: array of Single);
{ A ready-made "standing still" pose: auto-selectable only at ~zero speed/effort, feet
  level and planted, torso fairly upright, hands on the hoods. Seeded into fresh lists. }
function StationaryRiderPose: TRiderPose;
{ Linear blend a..b at t in [0,1]; booleans/name snap to b past the half-way mark. }
function LerpRiderPose(const A, B: TRiderPose; T: Single): TRiderPose;
function RiderSpineDelta(const LeanAxis: TVector3; Pitch, Yaw, Roll: Single): TTripoVec4;

{ Right-foot yaw in rig space, about bike up. Positive degrees = toes out;
  conjugate for the left foot. Shared by CPU posing and GPU uniform upload. }
function RiderFootYawRotation(const BikeToRig: TMatrix4; AngleDeg: Single): TTripoVec4;

{ Raw CGE.Load preview (fit-page tiles, no Tripo/GPU): TSkinNode ignores
  Armature.Scale until a skin update, while unskinned accessories (Helmet)
  keep their authored metres. If the file IBM does not already cancel that
  scale, apply it on the CastleScene and compensate the accessories so the
  figure is one piece and fills the tile. No-op when Armature is 1 or IBM
  already has 1/scale (fema). Mixamo tiles face +Z; yaw 180 so they look
  at the camera. Embedded-animation glbs: reparent Helmet under Head so
  PlayAnimation carries it. }
procedure PrepareRiderPreviewScene(AScene: TCastleScene);
{ Stop glTF TimeSensors / CGE AutoAnimation so only LoadFileClip drives the pose. }
procedure DisableEmbeddedAnimations(AScene: TCastleScene);

{ Folder with one-clip animation-only GLBs (idle.glb, walk.glb, …). }
function DefaultRiderClipDir: string;
{ Fill ADest with clip slugs (file names without .glb), sorted. Returns count. }
function ListRiderFileClips(const ADir: string; ADest: TStrings): Integer;

{ ── Общий файл освещения райдера (rider_lighting.json в data игры) ──
  Редактор сохраняет при каждом изменении света (UI/MCP), редактор и игра
  применяют при старте/загрузке райдера. See implementation for format. }
procedure SaveRiderLighting(const Env, Key, Fill, RKey, RFill: Single);
procedure LoadRiderLighting(out Env, Key, Fill, RKey, RFill: Single);

{ CPU-only GLB parse (LoadNode + TTripoRig) for a background thread.
  Steal Root/Rig after Ok, then LoadPrepared on the main thread. }
type
  TTripoGlbPrepared = class
  public
    Path: string;
    Root: TX3DRootNode;
    Rig: TTripoRig;
    Error: string;
    Ok: Boolean;
    destructor Destroy; override;
  end;

  TTripoGlbWorker = class(TThread)
  private
    FPath: string;
  protected
    procedure Execute; override;
  public
    Prepared: TTripoGlbPrepared;
    constructor Create(const APath: string);
    destructor Destroy; override;
    property Path: string read FPath;
  end;

type
  { Editable in-memory copy of the compiled pose catalog. }
  TRiderPoseList = class
  strict private
    FItems: array of TRiderPose;
    function GetItem(Index: Integer): TRiderPose;
    procedure SetItem(Index: Integer; const P: TRiderPose);
  public
    function Count: Integer;
    property Items[Index: Integer]: TRiderPose read GetItem write SetItem; default;
    function Add(const P: TRiderPose): Integer;
    procedure Delete(Index: Integer);
    procedure Clear;
    function IndexByName(const AName: string): Integer;
    procedure EnsureDefault;                 { guarantees a 'Default' entry exists }
  end;

type
  { ── покраска одежды (cloth dye) ──
    Слоты одежды и способ применения цвета. В glb всегда лежит ИСХОДНАЯ
    текстура; цвета применяются при загрузке (запечка в текстуру) или
    на лету (GLSL-эффект) — файл на диске не меняется никогда. }
  TClothSlot = (csJersey, csShorts, csSocks, csBoots, csGloves, csSkin, csHair);
  TClothDyeMode = (cdmNone, cdmShader, cdmTexture);

  { Родной цвет ткани слота в исходной текстуре — по нему (hue-маatch)
    выбираются пиксели одежды; логотипы другого оттенка не трогаются. }
function ClothDyeNativeColor(Slot: TClothSlot): TVector3;
{ Слот по имени части/материала/shape'а (Jersey, Shorts, …, Hair). }
function ClothSlotOfName(const Nm: string; out Slot: TClothSlot): Boolean;

type
  TRiderPoseReplay = record
    Pose: TRiderPose;
    PoseFrom: TRiderPose;
    PoseTo: TRiderPose;
    PoseElapsed: Single;
    PoseDur: Single;
    PoseAnimating: Boolean;
    HasPose: Boolean;
  end;

  TTripoRiderScene = class
  strict private
    FScene: TCastleScene;                 { owned, пока не MountInto }
    FSceneOwned: Boolean;                 { False после MountInto — сцена чужая }
    FRig: TTripoRig;                       { metadata: names / hierarchy / bind }
    FJointNode: array of TTransformNode;   { CGE node per palette joint (nil if unresolved) }
    FRestRot: array of TVector4;           { captured bind local rotation per joint }
    FSkin: TSkinNode;                      { the Skin node that DRIVES the mesh (matched to FRig in LoadGlb) }
    FSkinList: array of TSkinNode;         { every Skin node CGE built — a glb can carry several armatures }
    FStrayShapes: TStringList;             { transient (LoadGlb log): shapes NOT driven by the matched skin }
    FHemBiasBuf: array of TShapeNode;      { transient: all shapes while attaching hem bias }
    FHemOverlayOn: Boolean;
    FLoaded: Boolean;
    FResolved: Integer;
    FBaseOrientQ: TTripoVec4;               { rig->upright/forward correction, cached }
    FBaseOrientDone: Boolean;               { FBaseOrientQ computed for this rig }
    FLegPlaneHint: TVector3;               { knee bend direction (rig/glb frame) }
    FArmPlaneHint: TVector3;               { elbow bend direction (rig/glb frame) }
    FLeanAxis: TVector3;                   { spine/ankle pitch axis in rig frame }
    FFlareAxis: TVector3;                  { knee/elbow splay axis in rig frame }
    FFileNeedsYaw: Boolean;                { Mixamo bind: Scene needs +90° Y }
    FFileBaseYaw: Single;                  { 0 = bike-aligned bind; Pi/2 = Mixamo }
    FTorsoLeanDeg: Single;                 { total forward lean of the torso }
    FSpineCurve: Single;                   { 0 = even lean, >0 = more curl up top }
    FSpineYaw, FSpineRoll: TSpineAngles;
    FSpineManual: Boolean;                 { use FSpineAngles instead of auto lean }
    FSpineAngles: array[0..4] of Single;   { per-joint manual spine pitch (deg) }
    FKneeFlare: Single;                    { knees out(+)/in(-), lateral }
    FElbowFlare: Single;                   { elbows out(+)/in(-), lateral }
    FFootPitchR: Single;                   { right foot roll, radians (set by bike) }
    FFootPitchL: Single;                   { left foot roll, radians }
    FFootYawDeg: Single;                   { mirrored yaw correction, degrees; + = toes out }
    FLastError: string;                    { why the last LoadGlb failed }
    FArmPronationDegR, FArmPronationDegL: Single;  { hand roll about the forearm axis, per side }
    FShoulderRoundDeg: Single;             { clavicles swing fwd/together (round shoulders) }
    FHandLevel: Single;                    { wrist leveling 0..1: rotate the hand toward horizontal }
    FShoulderTwistDeg: Single;             { transient torso/shoulder yaw (set by bike during asymmetric hand moves) }
    { ── live, possibly-animating body pose (owned here; the bike reads it back
      for offset/stance/ankle and no longer pushes the posture each frame). ── }
    FPose: TRiderPose;                     { current (interpolated) pose }
    FPoseFrom, FPoseTo: TRiderPose;        { animation endpoints }
    FPoseElapsed, FPoseDur: Single;        { seconds }
    FPoseAnimating: Boolean;
    FHasPose: Boolean;                     { ApplyPose has run at least once }
    { ── animation-only GLB clip (preview / retarget; never written back) ── }
    FFileClipLoaded: Boolean;
    FFileClipPlaying: Boolean;
    FFileClipLoop: Boolean;
    FFileClipTime: Single;
    FFileClipDur: Single;
    FFileClipName: string;
    FFileClipJoints: array of record
      Name: string;
      RestQ: TTripoVec4;                   { clip-file bind, xyzw }
      Times: array of Single;
      Rots: array of TTripoVec4;           { local anim, xyzw }
    end;
    FFileClipBlendDur: Single;             { default seconds; 0 = snap }
    FFileClipBlendLen: Single;             { current transition length }
    FFileClipBlendT: Single;
    FFileClipBlending: Boolean;
    FFileClipBlendToRest: Boolean;
    FFileClipBlendFrom: array of TTripoVec4;
    FFileClipHasBlendFrom: Boolean;
    { ── contact markers baked at load: BoatClipse/ArmContact are SEPARATE single-
      bone skins, not joints in the main armature, so they don't move with the IK.
      At load we measure each marker once IN THE LOCAL BIND FRAME of the nearest
      movable end joint (R_Foot/L_Foot/R_Hand/L_Hand). UpdatePose then treats the
      marker as a rigid child of that joint and solves so it lands on the bike
      contact — including the foot-roll, which is applied as part of the solve. }
    FContactLocal: array[0..3] of TTripoVec3;  { 0=R_Foot 1=L_Foot 2=R_Hand 3=L_Hand }
    FContactValid: array[0..3] of Boolean;     { marker resolved at load? }
    { ── frozen hand orientation on a still grip: recomputed only when the grip
      target moves (a position-change animation) or the wrist intent changes, so
      a planted hand does not rotate with the per-frame torso bob. 0=R 1=L. ── }
    FHandFreezeQ:     array[0..1] of TTripoVec4;
    FHandFreezePt:    array[0..1] of TTripoVec3;
    FHandFreezeRoll:  array[0..1] of Single;
    FHandFreezeLevel: array[0..1] of Single;
    FHandFreezeOk:    array[0..1] of Boolean;
    { OPT (pose-7ms): кэш индексов суставов 4 конечностей — SolveLimb раньше
      искал по имени каждый вызов (десятки линейных сканов JointName за кадр).
      Индексы 0=Upper 1=Mid 2=End, по LimbIdx (нога R/L, рука R/L). }
    FLimbJ:     array[0..3, 0..2] of Integer;
    FLimbValid: array[0..3] of Boolean;
    { ── blended GPU skinning of the marker so the debug point sticks to the
      RENDERED boot/glove surface. That surface is skinned by a BLEND of bones
      (e.g. R_Foot + R_Calf near the ankle), so a single-bone reconstruction
      coincides in bind pose but DRIFTS as the limb poses. At load we find the
      nearest rest-mesh vertices to the marker and keep their joint indices +
      weights; in pose we skin the marker exactly like a mesh vertex. }
    FCSkinM:     array[0..3] of TTripoVec3;        { marker bind pos (model frame) }
    FCSkinVtx:   array[0..3] of array of Integer;  { nearest rest-mesh vertex indices }
    FCSkinIDW:   array[0..3] of array of Single;   { normalized inverse-dist weights }
    FCSkinValid: array[0..3] of Boolean;
    { ── body-shape (vertex deformation of the rest mesh) ── }
    FShapeCached: Boolean;
    FShapeCoords: array of TCoordinateNode;        { every rest-mesh Coordinate }
    FOrigPts: array of array of TVector3;          { pristine vertices per node }
    FBulkW: array of array of Single;              { T-pose bulk mask 0..1 (0 = arms) }
    FBulkWaistRX, FBulkWaistRZ: Single;            { T-pose waist half-axes, model m }
    FBoxMinX, FBoxMaxX, FBoxMinY, FBoxMaxY: Single;
    FBoxMinZ, FBoxMaxZ, FBoxCX, FBoxCZ, FBoxW, FBoxD: Single;
    { ── limb-length on the skeleton ── }
    FBonesCached: Boolean;
    FBoneJoint: array[0..34] of Integer;           { joint idx per limb bone (-1 = missing) }
    FBoneOrigLocalT: array[0..34] of TVector3;     { original BindLocal translation }
    FBoneOrigNodeT: array[0..34] of TVector3;      { original CGE node translation }
    { ── optional 'Helmet' accessory node, animated to follow the head ── }
    FHelmetNode: TTransformNode;    { the glb's 'Helmet' TTransformNode (nil = none) }
    FHelmetHeadJ: Integer;          { rig joint the helmet follows (Head, with fallbacks) }
    FHelmetBindT: TVector3;         { authored node transform — the skin matrix is applied on top }
    FHelmetBindR: TVector4;
    FHelmetApplies: Integer;        { follow invocations — diagnostics }
    FHelmetScan: TTransformNode;    { EnumerateNodes result — heuristic helmet search }
    FHelmetParented: Boolean;       { True = Helmet is a child of Head; follow via graph }
    FHelmetPitchXDeg: Single;       { extra nod about helmet local X; + = visor down }
    FBodyHeightF: Single;           { last ApplyBodyShape HeightF (height itself is skeleton) }
    FBodyMorphed: Boolean;          { rest verts currently carry bulk/belly disp }
    FCorrectives: TRiderPoseCorrectives;
    FHelmetRest0: TTripoMat4;       { Head gskRest at CacheHelmet (pre-HeightK) }
    FHelmetRest0Ok: Boolean;
    { ── helmet colorization ── }
    FHelmetMatsCached: Boolean;
    FHelmetMats: array of TX3DNode;        { TPhysicalMaterialNode / TUnlitMaterialNode }
    FHelmetOrigColor: array of TVector3;   { authored base/emissive color factors }

    { ── IBL-ambient (pure-IBL лук) ── }
    FEnvLight: TEnvironmentLightNode;      { 'RiderEnv' — живёт в сцене райдера }
    FRiderKeyLight: TDirectionalLightNode; { 'RiderKey' — для runtime-интенсивности }
    FRiderFillLight: TDirectionalLightNode; { 'RiderFill' — для runtime-интенсивности }
    FDiagBuf: TStringList;                 { временное накопление LightDiag }

    { ── PBR gloss correction (roughness of every PhysicalMaterial) ── }
    FMatCached: Boolean;
    FMatNodes: array of TPhysicalMaterialNode;     { every PBR material in the rider }
    FMatOrigRough: array of Single;                { authored roughness factor per material }
    FMatOrigMetal: array of Single;                { authored metallic factor per material }
    FMatTexNode: array of TX3DNode;                { the material's MR texture node (stays attached) }
    FMatOrigImg: array of TCastleImage;            { pristine decoded copy of the MR texture (owned; lazy) }
    FMatAppliedRough, FMatAppliedMetal: Single;    { last applied coefficients (skip redundant rebakes) }
    FOrigLegReach: Single;                         { leg reach before any scaling }
    FOrigThighLen: Single;                         { |Thigh→Calf| at bind, metres }
    FOrigShinLen: Single;                          { |Calf→Foot| at bind, metres }
    FNativeRestH: Single;                          { bind-pose standing height, metres }
    { ── cloth dye: цвета одежды как свойства райдера ── }
    FDyeMode: TClothDyeMode;                     { нет / шейдер / текстура }
    FDyeColor: array[TClothSlot] of TVector3;    { целевой цвет слота }
    FDyeActive: array[TClothSlot] of Boolean;    { слот включён }
    FDyeTexCached: Boolean;
    FDyeTexNode: array of TX3DNode;              { distinct baseColor texture nodes }
    FDyeOrigImg: array of TCastleImage;          { pristine decoded copies (owned; lazy) }
    FDyeBaked: Boolean;                          { текстуры сейчас несут покраску }
    FDyeInLoad: Boolean;                         { идёт загрузка glb: запечка разрешена (GL ещё не живой) }
    FDyeMaterial: array of record
      Node: TPhysicalMaterialNode;
      Color: TVector3;
      Slot: TClothSlot;
    end;
    FDyeJerseyReferenceLum, FDyeJerseyMaxLum: Single;
    { ── UV-маски: красим только те тексели, куда реально попадают UV одежды ── }
    FDyeShapeBuf: array of TShapeNode;           { transient: shapes for mask build }
    FDyeMaskOk: Boolean;                         { маски построены для текущей сцены }
    FDyeMaskAny: Boolean;                        { нашлась хоть одна UV-геометрия }
    FDyeMaskHasGlobal: set of TClothSlot;        { слоты со своей геометрией (split) }
    FDyeMaskW: array of Integer;                 { per FDyeTexNode }
    FDyeSourcePath: string;                      { glb-путь — ключ кэша масок/тона кожи }    FDyeMaskH: array of Integer;
    FDyeMaskJerseyHem: array of TBytes;          { lower jersey band, distinct from logo UVs }
    FDyeMaskAll: array of TBytes;                { битовая маска W*H: любые UV меша }
    FDyeMaskSlot: array of array of TBytes;      { [tex][ord(slot)]: UV слота }
    FDyePartNames: array of string;              { extras.avatarPartNames: имя части по индексу примитива }
    FSkinTone: TVector3;                         { исходный тон кожи — вычислен из текстуры }
    FSkinToneOk: Boolean;
    { шейдерный окрас (cdmShader): live uniforms, без запечки пикселей }
    FDyeShColor: array[TClothSlot] of array of TSFVec3f;
    FDyeShAmt: array[TClothSlot] of array of TSFFloat;
    FDyeShAppBuf: array of TAppearanceNode;
    FDyeShBusy: Boolean;
    procedure GrabDyeAppearance(Node: TX3DNode);
    function  DyeLabelOfShape(Sh: TShapeNode): string;
    function  SlotOfLiveShape(Sh: TShapeNode; out Slot: TClothSlot): Boolean;
    procedure ClearShaderDyeFields;
    procedure ApplyMaterialClothDye;
    function ShaderClothDyeColor(Slot: TClothSlot): TVector3;
    procedure RemoveShaderClothDye;
    procedure PushShaderClothDye(Slot: TClothSlot);
    procedure WritePoseToFields;           { push FPose posture into the IK fields }
    procedure CaptureFileClipPose;
    procedure ApplyFileClipDeltas(T, BlendA: Single);
    procedure GrabSkin(Node: TX3DNode);    { EnumerateNodes callback (collects ALL Skin nodes) }
    function  SelectSkinForRig: TSkinNode; { the Skin whose joint palette matches FRig }
    procedure GrabStrayShape(Node: TX3DNode); { EnumerateNodes callback: shapes outside FSkin.FdShapes }
    procedure GrabCoord(Node: TX3DNode);   { EnumerateNodes callback (coords) }
  private
    FGroundShadeEffect: TEffectNode;
    FGroundShadeUniform: TSFFloat;
    FGroundShade: Single;
    procedure AttachGroundShade(Node: TX3DNode);
    procedure ResetGroundShadeEffect;
    procedure SetGroundShade(const Value: Single);
    function  RiderContentRoot: TX3DNode;  { glb/rider subtree only — never BikeFrame }
    function  DyeSceneIsRiderOnly: Boolean; { True until MountBikeIntoRider }
    function  FinishLoadAfterGraph(const AFileName: string; Log: TStrings): Boolean;
    function  BuildRiderEnvLight: TEnvironmentLightNode; { IBL-подобный ambient для PBR (замена купола филлов) }
    procedure CacheShape;                  { collect coords, cache originals, bbox }
    procedure ComputeBulkMaskFromTPose;    { rest-mesh: which verts bulk may move }
    procedure CacheBones;                  { cache original limb bone offsets + reach }
    procedure FreezeBootSkin;              { boot verts follow Foot/Toe only — constant Y }
    procedure BindShinToBoot;              { local ankle blend; calf stays on its own bones }
    procedure CacheHelmet;                 { find optional 'Helmet' node, capture head-relative bind }
    procedure GrabHelmetCandidate(Node: TX3DNode);  { EnumerateNodes callback for the heuristic }
    function HelmetSubtreeHasAccessoryMesh(Node: TX3DNode): Boolean;
    function HelmetSubtreeHasBodyMesh(Node: TX3DNode): Boolean;
    function HelmetNameExcluded(const AName: string): Boolean;
    procedure CacheHelmetMaterials;        { collect the helmet subtree's materials once }
    procedure ApplyHelmetFollow;           { per-frame: place the helmet on the posed head }
    function  HelmetBindTAdj: TVector3;    { authored helmet Translation; height is on the Head joint }
    function  HelmetBindWithPitch: TQuaternion; { authored bind rotation · pitch X }
    procedure ReadHelmetPitchExtra(const AFileName: string);
    procedure LoadEquipmentGraph(Root: TJSONObject; const ModelPath: string);
    procedure SetHelmetPitchXDeg(const V: Single);
    procedure GrabPhysMat(Node: TX3DNode); { EnumerateNodes callback (PBR materials) }
    procedure GrabDyePhysMat(Node: TX3DNode); { EnumerateNodes callback (baseColor textures) }
    procedure CacheDyeTextures;            { collect distinct baseColor texture nodes }
    procedure ResetDyeCache;               { drop baked state + pristine copies (scene reload) }
    procedure GrabDyeShape(Node: TX3DNode); { EnumerateNodes callback (shapes for UV masks) }
    procedure ReadDyePartNames(const AFileName: string); { extras.avatarPartNames из glb }
    procedure BuildDyeMasks;               { rasterize cloth UV shells into texel masks }
    procedure EnsureDyeOrig;               { декодировать pristine-копии всех baseColor }
    procedure DetectSkinTone;              { вычислить исходный тон кожи из текстуры }
    procedure BakeClothDye;                { (re)bake baseColor pixels or restore originals }
    function  GetDyeColor(Slot: TClothSlot): TVector3;
    procedure SetDyeColor(Slot: TClothSlot; const V: TVector3);
    function  GetDyeActive(Slot: TClothSlot): Boolean;
    procedure SetDyeMode(const V: TClothDyeMode);
    procedure GrabHemBiasShape(Node: TX3DNode);
    procedure StripHemOverlayFrom(Node: TX3DNode);
    procedure ApplyJerseyHemDepthBias;
    procedure StripJerseyHemDepthBias;
    procedure CacheMaterials;              { collect PhysicalMaterials + authored roughness }
    procedure CacheContactOffsets;         { bake marker->end-joint local offsets at load }
    procedure CacheContactSkin;            { bake nearest-vertex blend weights for markers }
    function  BindV(const AName: string; out P: TVector3): Boolean; { joint bind pos }
    procedure FillLimb(const Names: array of string;
                       var Pts: array of TVector3; out N: Integer); { build polyline }
    function  LimbStretchDisp(const v: TVector3; const P: array of TVector3;
                       PCount: Integer; Factor, Radius, TipR: Single): TVector3;
    procedure PoseSpine;                   { lean/curl the torso (auto or manual) }
    function  GetSpineAngle(Index: Integer): Single;
    procedure SetSpineAngle(Index: Integer; const V: Single);
    procedure PushDelta(const AName: string);   { rig delta -> CGE joint node }
    function ParentToRig(const P: TVector3): TVector3;  { rider parent frame -> glb frame }
    function BindLateral: TVector3;        { L-R arms/hands in bind, XZ }
    procedure ApplyBikeAlignedSpace;
    procedure ApplyMixamoFileSpace;
    procedure ConfigureFileSpace;          { detect Mixamo vs baked; set axes + base yaw }
    function OrientQuat(YawRad: Single): TTripoVec4;  { heading * fileBaseYaw * upright }
  public
    function CaptureReplay: TRiderPoseReplay;
    procedure RestoreReplay(const Saved: TRiderPoseReplay);
  public
    constructor Create;
    destructor Destroy; override;

    { Load a local .glb. Returns False on failure; a human-readable report is
      appended to Log if provided. After this, add Scene to your viewport /
      bike transform and set its placement (Translation/Scale/Rotation). }
    function LoadGlb(const AFileName: string; Log: TStrings = nil): Boolean;
    { Attach a worker-parsed graph+rig (steals APrep.Root/Rig). Main thread. }
    function LoadPrepared(APrep: TTripoGlbPrepared; Log: TStrings = nil): Boolean;

    { The skinned scene — add this to TCastleViewport.Items (or a parent
      TCastleTransform) and position it where the rider sits on the bike. }
    property Scene: TCastleScene read FScene;

    { Перенести граф райдера в чужую сцену (единая сцена байка — требование
      shadow maps CGE: casters/receivers per-scene). Узлы переезжают без
      клонирования; пустая обёртка-сцена освобождается. После вызова
      Scene = AScene и Destroy её НЕ освобождает. }
    procedure MountInto(AScene: TCastleScene; AParent: TAbstractGroupingNode);
    property Rig: TTripoRig read FRig;
    property Correctives: TRiderPoseCorrectives read FCorrectives;
    property Loaded: Boolean read FLoaded;
    { TEMP-DIAG: posed-позиции спины/плеч в кадре байка (Transform сцены × WorldPose) }
    function DbgSpineShoulders: string;
    property ResolvedJoints: Integer read FResolved;
    function HasNativeSkin: Boolean;

    { ── GPU-скин (GPU_ANIM_DESIGN.md, этап 2): доступ для BikeGpuSkin. ── }
    { Skin-узел, ведущий меш (на его шейпы навешивается эффект). }
    function SkinNode: TSkinNode;
    { Запечённое локальное смещение контакта конечности в кадре конечного
      сустава (0=R_Foot 1=L_Foot 2=R_Hand 3=L_Hand). Ноль, если маркера нет. }
    function GpuContactLocal(Idx: Integer): TVector3;
    { Сустав, за которым следует шлем (-1 = шлема нет). GPU-аним, этап 3. }
    property HelmetHeadJoint: Integer read FHelmetHeadJ;
    { Поставить шлем по готовой skin-матрице головы (GPU-аним, этап 3):
      аналог ApplyHelmetFollow, но матрицу считает BikeGpuSkin аналитически,
      без posed-позы рига. }
    procedure ApplyHelmetSkinMatrix(const S: TMatrix4);
    { After the scene is in a viewport / mounted on the bike: build
      TSkinNode.InternalJointMatrix so the engine skin chunk is linked.
      Call from the GpuAnim prime — too early (in LoadGlb) and ChangedAll
      leaves InternalJointMatrix stale → plug compiles without skinMatrix
      and the mesh turns pink. }
    procedure EnsureNativeSkinReady;
    { Rebuild each skin once when switching between GPU and a fixed CPU mesh. }
    procedure SetSkinnedAnimationShaders(AOn: Boolean);
    { Re-scan helmet after reparent / armature-scale fold. }
    procedure RefreshHelmetBind;
    { Vertex overlay so JerseyHem wins z-test vs the body. Re-apply after
      highlight swaps Appearance. }
    procedure SetHemOverlay(AOn: Boolean);
    function HemOverlayOn: Boolean;
    procedure RefreshHemOverlay;

    function JointIndex(const AName: string): Integer;
    function JointNodeByName(const AName: string): TTransformNode;

    { Pose API. Delta is a rotation in the joint's OWN (rest-oriented) frame;
      a zero/identity delta leaves the joint in its bind orientation. }
    procedure ResetPose;
    { Re-send rest rotations so TSkinNode rebuilds joint matrices even when
      the values are unchanged (CGE skips Changed on assign-equal). }
    procedure SetJointDelta(JointIdx: Integer; const DeltaQ: TQuaternion); overload;
    procedure SetJointDelta(const AName: string; const DeltaQ: TQuaternion); overload;
    procedure SetJointDeltaAxisAngle(const AName: string;
      const Axis: TVector3; const AngleRad: Single);
    { Absolute local rotation (replaces bind orientation entirely). }
    procedure SetJointLocalRotation(JointIdx: Integer; const Rot: TVector4);
    { Remember current node rotation as rest so ResetPose / T-pose keep a
      static pose instead of snapping back to the file bind. }
    procedure PushJointRest(JointIdx: Integer);
    procedure PushJointRestByName(const AName: string);

    { ── Real pose: solve legs onto the pedals and arms onto the bars. ──
      Targets are positions in the rider Scene's PARENT coordinate frame
      (i.e. the bike frame where you already compute pedal/grip positions).
      Foot* = pedal spindle (ball-of-foot) target; Hand* = bar grip target.
      Call once per frame (where the old AnimateFrame was called). }
    procedure UpdatePose(const FootTargetR, FootTargetL,
      HandTargetR, HandTargetL: TVector3);

    { Deform the REST mesh in place (no topology change) to retarget body
      proportions. All args are fractions around 0 (0 = unchanged):
        Bulk     - overall girth (horizontal scale from the body axis)
        Belly    - forward belly bulge
        HeightF  - stored only; mesh Y is NOT morphed (that left rest verts
                   off the bind). Height is skeleton HeightK. Helmet follows Head.
        LegLen   - extra leg length (stretch below the hips)
        ArmLen   - extra arm length (stretch the outstretched parts sideways)
      Cheap enough to call live; re-derives from a pristine cached copy each
      time, so changes are not cumulative. }
    procedure ApplyBodyShape(Bulk, Belly, HeightF: Single);

    { Change limb LENGTH on the SKELETON: scale the thigh+shin bones (legs),
      upperarm+forearm bones (arms), clavicle bones (shoulder width), the
      pelvis->thigh offsets (pelvis width) and the spine-chain bone offsets
      (torso length). The GPU-skinned mesh follows the bones, and the IK
      re-reaches the pedal/bars (so the limbs bend to fit).
      All args are DIRECT scale coefficients: 1.0 = unchanged, 1.1 = +10%.
      A value of exactly 0 is treated as 1.0 (unset/default in old files).
      HeightK is standing scale (1 = native RestHeight) on thighs + shins + spine.
      Inseam extra (LegK) is the whole thigh+shin chain. Boot mesh stays rigid
      on the Foot joint (FreezeBootSkin) so it does not flatten or become a
      half-boot. TorsoK absorbs the leftover so stature stays HeightK.
      Arms / clavicles stay at ArmK / ShoulderK (bar reach).
      Pelvis joint is not scaled, so BottomContact still sits on the saddle.
      Re-derives from a cached original each call (not cumulative). }
    procedure ApplyLimbLengths(LegK, ArmK, ShoulderK, PelvisK, TorsoK: Single;
      HeightK: Single = 1);
    { PBR gloss correction. DIRECT coefficients: 1 = material exactly as
      authored, exactly 0 = 1 (unset/default in old files).
      RoughK < 1 = glossier (shinier), > 1 = more matte. MetalK < 1 = more
      dielectric (kills the metallic sheen on skin/lycra), > 1 = more metallic.
      HOW: for materials driven by a metallicRoughness TEXTURE the correction
      is BAKED into the texture pixels (G channel = roughness scaled by RoughK,
      B channel = metallic scaled by MetalK, clamped) and loaded back into the
      SAME texture node via the standard LoadFromImage — no node swapping, no
      shader re-setup, safe alongside the per-frame joint updates. Per-pixel
      gloss variation is preserved; only its level shifts. Materials without an
      MR texture get their plain factors multiplied instead. Setting both
      coefficients back to 1 restores the authored pixels and factors exactly.
      Rebakes from a cached pristine copy each call — not cumulative. }
    procedure ApplyGlossCorrection(RoughK, MetalK: Single);
    { Colorize the OPTIONAL helmet: multiply the base/emissive color factor
      of every material in the helmet subtree by C. The helmet texture is
      white with baked shading, so factor * texture = the tint C with the
      shading preserved ("color laid over"). Enable=False restores the
      authored factors exactly. Non-cumulative (originals cached). No-op
      when the model has no helmet. }
    procedure ApplyHelmetColor(const C: TVector3; const Enable: Boolean);
    { ── цвета одежды (cloth dye) ──
      Цвета — свойства райдера; в glb всегда исходная текстура, покраска
      применяется при загрузке (режим cdmTexture — запечка в пиксели
      baseColor-текстуры в памяти) или шейдерным эффектом (cdmShader —
      RefreshShaderClothDye на живой сцене, байкфит). cdmNone — ничего.
      SetClothColor включает слот и запекает; ClearClothColor выключает.
      Запечка всегда из pristine-копии — не накапливается, исходные пиксели
      восстанавливаются точно. }
    procedure SetClothColor(Slot: TClothSlot; const C: TVector3);
    procedure ClearClothColor(Slot: TClothSlot);
    { Только обновляют состояние слота БЕЗ запечки. Live-запечка
      (BakeClothDye на уже подготовленной GL-сцене) глушит рендер —
      CGE не переживает LoadFromImage на живом GPU-скиннутом мешe.
      Поэтому на живой сцене цвета только стейджим, а запечка произойдёт
      при следующей загрузке (перезагрузка через ReloadScene). }
    procedure StageClothColor(Slot: TClothSlot; const C: TVector3);
    procedure StageClearClothColor(Slot: TClothSlot);
    { Скопировать настройки покраски из другого райдера (перед LoadGlb,
      чтобы запечка сработала уже при загрузке). }
    procedure CopyClothDyeFrom(Src: TTripoRiderScene);
    { Исходный тон кожи — вычисляется из текстуры (доминантный тёплый hue
      в UV-областях Legs/Head/Arms/Fingers, без split — всей текстуры),
      лениво; fallback — ClothDyeNativeColor(csSkin). }
    function  SkinToneColor: TVector3;
    { Шейдерный окрас на живой сцене (байкфит). Езда по-прежнему печёт
      текстуру (cdmTexture). }
    procedure RefreshShaderClothDye;
    property ClothColor[Slot: TClothSlot]: TVector3 read GetDyeColor write SetDyeColor;
    property ClothColorActive[Slot: TClothSlot]: Boolean read GetDyeActive;
    property ClothDyeMode: TClothDyeMode read FDyeMode write SetDyeMode;
    { Extra helmet nod about local X (degrees). Positive = visor down / forward. }
    property HelmetPitchXDeg: Single read FHelmetPitchXDeg write SetHelmetPitchXDeg;
    { Straight-leg reach BEFORE any limb-length scaling (auto-fit uses this so the
      rider keeps its size and longer legs bend instead of shrinking the rider). }
    function StableLegReach: Single;
    function StableThighLen: Single;
    function StableShinLen: Single;
    { Bind-pose standing height in metres: rest-mesh bbox × GPU rest stretch
      (BindWorld × file IBM). Mixamo/Tripo file mesh is ~1 m; Armature.Scale
      (~1.6–1.8) lives in BindWorld and is the displayed size. Fema IBM already
      cancels armature, so stretch≈1 and the mesh verts are already metres. }
    function RestHeight: Single;

    { Интенсивность IBL-ambient (свет 'RiderEnv'). 0 = ambient выключен
      (остаются только направленные свети). Меняeтся на живой сцене —
      intensity это per-frame uniform, ChangedAll не нужен. }
    function GetRiderEnvIntensity: Single;
    procedure SetRiderEnvIntensity(const V: Single);
    property RiderEnvIntensity: Single read GetRiderEnvIntensity write SetRiderEnvIntensity;
    { Интенсивности направленных светов сцены райдера ('RiderKey'/'RiderFill'). }
    function GetRiderKeyIntensity: Single;
    procedure SetRiderKeyIntensity(const V: Single);
    property RiderKeyIntensity: Single read GetRiderKeyIntensity write SetRiderKeyIntensity;
    function GetRiderFillIntensity: Single;
    procedure SetRiderFillIntensity(const V: Single);
    property RiderFillIntensity: Single read GetRiderFillIntensity write SetRiderFillIntensity;
    { ДИАГ: все света поддерева райдера одной строкой (имя:класс=интензивность). }
    { Smoothed building/tree coverage sampled under the front wheel. }
    property GroundShade: Single read FGroundShade write SetGroundShade;
    function LightDiag: String;
    procedure GrabDiagLight(Node: TX3DNode);

    { Bend-plane hints (rig/glb frame). Flip a component's sign if a knee or
      elbow bends the wrong way. Defaults are a reasonable first guess. }
    property LegPlaneHint: TVector3 read FLegPlaneHint write FLegPlaneHint;
    property ArmPlaneHint: TVector3 read FArmPlaneHint write FArmPlaneHint;
    { Lateral axis for spine lean and ankle flex (rig frame). Bike-aligned
      bind: +Z. Mixamo/file +Z-facing bind: +X. }
    property LeanAxis: TVector3 read FLeanAxis write FLeanAxis;
    { Lateral splay for KneeFlare / ElbowFlare (rig frame). Bike-aligned: +Z.
      Mixamo +Z-facing bind: +X. Must NOT stay on +Z after a display-only yaw. }
    property FlareAxis: TVector3 read FFlareAxis write FFlareAxis;
    { True when bind is Mixamo (+Z face, +X right): OrientedRotationVec4
      prepends +90° Y so the mesh faces bike +X. IK axes stay in FILE. }
    property FileNeedsYaw: Boolean read FFileNeedsYaw;
    property FileBaseYaw: Single read FFileBaseYaw;
    { Forward lean of the torso (degrees), split across Spine..Spine02. 0 = upright. }
    property TorsoLeanDeg: Single read FTorsoLeanDeg write FTorsoLeanDeg;
    { 0 = lean spread evenly; >0 curls more toward the upper spine. }
    property SpineCurve: Single read FSpineCurve write FSpineCurve;
    { When true, ignore TorsoLeanDeg/SpineCurve and apply SpineAngle[0..4]. }
    property SpineManual: Boolean read FSpineManual write FSpineManual;
    { Per-joint manual spine pitch, degrees (0..4 = Waist,Spine,Spine01,Spine02,NeckTwist01). }
    property SpineAngle[Index: Integer]: Single read GetSpineAngle write SetSpineAngle;
    { Knees out(+)/in(-) and elbows out(+)/in(-) — lateral flare added to the IK hint. }
    property KneeFlare: Single read FKneeFlare write FKneeFlare;
    property ElbowFlare: Single read FElbowFlare write FElbowFlare;
    { Per-side foot roll in RADIANS, driven each frame by the bike's ankle flex. }
    property FootPitchR: Single read FFootPitchR write FFootPitchR;
    property FootPitchL: Single read FFootPitchL write FFootPitchL;
    property FootYawDeg: Single read FFootYawDeg write FFootYawDeg;
    { Human-readable reason the last LoadGlb returned False (empty on success). }
    property LastError: string read FLastError;
    property ArmPronationDegR: Single read FArmPronationDegR write FArmPronationDegR;
    property ArmPronationDegL: Single read FArmPronationDegL write FArmPronationDegL;
    { + rounds the shoulders forward/together, - pulls them back/open (degrees) }
    property ShoulderRoundDeg: Single read FShoulderRoundDeg write FShoulderRoundDeg;
    property HandLevel: Single read FHandLevel write FHandLevel;
    { Transient shoulder/torso yaw in degrees, driven each frame by the bike from the
      fore-aft asymmetry of the two hand grips (e.g. during a staggered hand change).
      Same vertical axis as ShoulderRound, so they simply add. }
    property ShoulderTwistDeg: Single read FShoulderTwistDeg write FShoulderTwistDeg;

    { ── Pose application (animated) ──
      ApplyPose blends the rider from its current pose to P over Duration seconds
      (default 1). Duration <= 0 snaps instantly. The very first call always snaps.
      AdvancePose is ticked each frame by the bike; CurrentPose feeds the bike the
      live offset/stance/ankle values it needs for placement and pedals. }
    procedure AdaptPoseReach(var P: TRiderPose; const GripR, GripL: TVector3);
    procedure ApplyFramePose(const P: TRiderPose);
    procedure ApplyPose(const P: TRiderPose; Duration: Single = 1.0);
    procedure AdvancePose(Dt: Single);
    function  CurrentPose: TRiderPose;
    property  PoseAnimating: Boolean read FPoseAnimating;
    property  HasPose: Boolean read FHasPose;
    { Концы текущего перехода позы — для событийных пакетов uPoseA/uPoseB
      (GPU-аним, этап 3): GPU сам лерпит между ними по accum-времени. }
    property  PoseFrom: TRiderPose read FPoseFrom;
    property  PoseTo: TRiderPose read FPoseTo;
    property  PoseDur: Single read FPoseDur;
    property  PoseElapsed: Single read FPoseElapsed;

    { Auto-fit helpers (rig/glb frame): pelvis joint bind position and the
      straight-leg length (thigh+calf). Used to scale the rider to the bike
      and seat the pelvis on the saddle. }
    function PelvisBindLocal: TVector3;
    function LegReach: Single;

    { ── Rig-based orientation (position the model BY THE RIG, not by the mesh) ──
      LoadGlb detects FILE space (Mixamo +Z-forward vs already bike-aligned) and
      sets IK axes + FileBaseYaw. Callers keep doing
        Scene.Rotation := OrientedRotationVec4(YawRad)
        Translation    := Saddle - OrientedSeatOffset(YawRad, Scale)
      — no extra yaw in BikeParametric / the game. ONE yaw on Scene; IK stays
      in FILE (ParentToRig undoes Scene.R). Double rotation = Scene +90° AND
      bike-aligned hints. }
    function RigBaseOrientQuat: TTripoVec4;
    { Axis-angle for Scene.Rotation: heading yaw · FileBaseYaw · upright.
      Feed FTripoRiderYawDeg here. Mixamo FileBaseYaw = +90° Y. }
    function OrientedRotationVec4(YawRad: Single): TVector4;
    { The seat reference (BottomContact bone, else pelvis joint) scaled and rotated
      by the SAME quat as OrientedRotationVec4, so subtracting it lands the seat
      on the saddle exactly. }
    function OrientedSeatOffset(YawRad, Scale: Single): TVector3;

    { ── File clip: load an animation-only GLB and play it on THIS bind.
      Rest-relative rotation deltas; the clip is never written into the model. }
    function LoadFileClip(const AFileName: string): Boolean;
    procedure ClearFileClip;
    procedure PlayFileClip(ALoop: Boolean = True; ABlendSec: Single = -1;
      AStartTime: Single = 0);
    procedure StopFileClip;
    procedure AdvanceFileClip(Dt: Single);
    function FileClipPlaying: Boolean;
    function FileClipBusy: Boolean;
    function FileClipName: string;
    function FileClipDuration: Single;
    { Cross-fade length when switching clips. 0 = cut. Default 0.30 s. }
    property FileClipBlendDuration: Single read FFileClipBlendDur write FFileClipBlendDur;

    { ── Optional contact-marker bones authored in the armature ──
      Some rigs carry explicit contact markers placed exactly where the rider
      meets the bike: BottomContact (seat), ArmContactR/L (hands on the bars),
      BoatClipseR/L (cleats on the pedals). In this rig they are authored as
      their OWN single-bone armatures (separate glTF skins; the inner joint is
      literally named "Bone"), so they are NOT in the main skin's joint palette
      and FRig.JointIndexByName can't see them. We resolve them by NODE name in
      the loaded CGE scene instead. When a marker exists the bike places the
      rider by it; otherwise it falls back to the computed heuristic. }

    { World rest position (bone head = node origin) of a contact-marker node,
      looked up by node name in the CGE scene; falls back to a same-named main
      skin joint. False if neither exists. The marker's own scale is irrelevant
      to its origin, so no scale handling is needed. }
    function ContactNodeWorld(const ANodeName: string; out P: TVector3): Boolean;

    { Seat / absolute reference: the contact marker's bone-head position. }
    function ContactBindLocal(const AName: string; out P: TVector3): Boolean;

    { Parent(bike)-frame vector from ContactName's marker to JointName's IK end
      joint. Add it to a bike-side target so the contact marker, not the joint,
      lands on it. False if the marker is absent. Requires Scene placement set. }
    function ContactOffsetParent(const JointName, ContactName: string;
      out OffParent: TVector3): Boolean;
    { The marker offset baked at load, in the end joint's LOCAL bind frame (rig
      units). LimbIdx: 0=R_Foot 1=L_Foot 2=R_Hand 3=L_Hand. False if no marker. }
    function ContactLocalOffset(LimbIdx: Integer; out P: TVector3): Boolean;
    { Live posed position of a limb's baked contact marker (cleat / hand) in the
      parent (bike) frame — where the marker ACTUALLY lands after UpdatePose (the
      same point SolveLimb aims at the pedal/grip). LimbIdx: 0=R_Foot 1=L_Foot
      2=R_Hand 3=L_Hand. False if the limb has no baked marker or joint. }
    function PosedContactParent(LimbIdx: Integer; out P: TVector3): Boolean;
    { Same reconstruction as PosedContactParent but left in the RIG frame (no lift
      to the parent/bike frame). Used by the IK so it can pin the BLENDED-skin
      contact (the rendered surface) on the pedal/grip, not just the rigid bone. }
    function PosedContactRig(LimbIdx: Integer; out PRig: TTripoVec3): Boolean;
    { Posed world position of a named joint (e.g. 'R_Foot' — the lowest leg bone),
      in the rider's parent (bike) frame. Same rig->parent lift PosedContactParent
      uses, exposed so the pedal log can print the foot bone next to its cleat. }
    function PosedJointParent(const JointName: string; out P: TVector3): Boolean;
    { BIND position of a named joint in the rider's parent (bike) frame —
      same lift as PosedJointParent but from the rest pose, so it works with
      GpuAnim where the rig is never posed on the CPU (этап 5: замер торса
      для масштаба капсульной тени). }
    function BindJointParent(const JointName: string; out P: TVector3): Boolean;
    { Diagnostics: assuming UpdatePose was just called, dump every scale and the
      ACTUAL posed contact coordinates (bike/parent frame) for both feet and hands:
      the pedal/grip target, the posed end joint, where SolveLimb AIMS the cleat
      (QUAT), and where the cleat mesh ACTUALLY renders via the GPU skin matrix
      (SKIN) — plus residuals. If SKIN misses while QUAT lands, the rig carries an
      internal scale the quaternion solve ignores. }
    procedure DiagContactDump(Lines: TStrings;
      const PedalR, PedalL, GripR, GripL: TVector3);
    { Pedal angle, in radians: the sagittal (about-Z) swing of the baked ankle->cleat
      offset vector since bind. The cleat is treated as rigidly attached to the foot
      bone at the offset we measured (FContactLocal), so as the foot poses the vector
      swings and the pedal turns by the same amount to stay under the cleat (90 deg to
      it, as at bind). Uses the real offset and captures off-Z foot rotation, unlike a
      plain twist. Side: 0=R, 1=L. Call AFTER UpdatePose. }
    function FootSagittalRoll(Side: Integer): Single;
  end;

  TDyeColorArray = array[TClothSlot] of TVector3;
  TDyeActiveArray = array[TClothSlot] of Boolean;

  { Полная сборка райдера с покраской в фоновом потоке: парс glb →
    TTripoRiderScene → запечка текстур. Всё CPU-only (GL-подготовка
    произойдёт на первом рендере после AdoptLoadedRider на главном потоке).
    Создаётся suspended: заполнить DyeMode/DyeColor/DyeActive, затем Start.
    После Finished забрать Rider (при неудаче Rider=nil, см. Error). }
  TTripoRiderBuildWorker = class(TThread)
  private
    FPath: string;
  protected
    procedure Execute; override;
  public
    DyeMode: TClothDyeMode;
    DyeColor: TDyeColorArray;
    DyeActive: TDyeActiveArray;
    Rider: TTripoRiderScene;
    Error: string;
    constructor Create(const APath: string);
    destructor Destroy; override;
    property Path: string read FPath;
  end;

{ castle-data:/foo.glb → абсолютный путь под data/, иначе APath как есть.
  TTripoRig.LoadFromFile / FileExists не умеют castle-data: URL. }
function ResolveGlbFilesystemPath(const APath: string): string;

implementation

function ResolveGlbFilesystemPath(const APath: string): string;
var
  DataRoot, Rel: string;
  P: Integer;
begin
  Result := Trim(APath);
  if Result = '' then Exit;
  if Pos('castle-data:', LowerCase(Result)) <> 1 then Exit;
  DataRoot := URIToFilenameSafe('castle-data:/');
  if DataRoot = '' then Exit;
  DataRoot := IncludeTrailingPathDelimiter(DataRoot);
  P := Pos('://', Result);
  if P > 0 then
    Rel := Copy(Result, P + 3, MaxInt)
  else
    Rel := Copy(Result, Length('castle-data:') + 1, MaxInt);
  while (Rel <> '') and ((Rel[1] = '/') or (Rel[1] = '\')) do
    Delete(Rel, 1, 1);
  Rel := StringReplace(Rel, '/', PathDelim, [rfReplaceAll]);
  Result := DataRoot + Rel;
  { Development tools share the game's avatar library. Packaged applications
    still resolve their own castle-data directory first. }
  if not FileExists(Result) then
  begin
    DataRoot := ExpandFileName(ExtractFilePath(ParamStr(0)) +
      '..' + PathDelim + 'rezvivo-osm-bckl' + PathDelim + 'data' + PathDelim + Rel);
    if FileExists(DataRoot) then Result := DataRoot;
  end;
end;

{ ═════════════════════════ TRiderPose / TRiderPoseList ═════════════════════════ }

procedure SpineAutoLeanDeg(LeanDeg, Curve: Single;
  const JointIdx: array of Integer; var AngDeg: array of Single);
var
  I, K: Integer;
  WSum, W: Single;

  function Unique(Slot: Integer): Boolean;
  var J: Integer;
  begin
    Result := False;
    if (Slot < Low(JointIdx)) or (Slot > High(JointIdx)) then Exit;
    if (Slot < Low(AngDeg)) or (Slot > High(AngDeg)) then Exit;
    if JointIdx[Slot] < 0 then Exit;
    for J := Low(JointIdx) to Slot - 1 do
      if JointIdx[J] = JointIdx[Slot] then Exit;
    Result := True;
  end;

begin
  for I := Low(AngDeg) to High(AngDeg) do
    AngDeg[I] := 0;
  if Abs(LeanDeg) < 0.01 then Exit;
  { Slots 1..3 = Spine, Spine01, Spine02. Slot 0 (Waist) stays bind so the
    pelvis/belt does not kink. Slot 4 (neck) is manual-only. }
  WSum := 0;
  K := 0;
  for I := 1 to 3 do
    if Unique(I) then
    begin
      WSum := WSum + (1.0 + Curve * (K / 2.0));
      Inc(K);
    end;
  if WSum < 1e-6 then Exit;
  K := 0;
  for I := 1 to 3 do
    if Unique(I) then
    begin
      W := (1.0 + Curve * (K / 2.0)) / WSum;
      AngDeg[I] := LeanDeg * W;
      Inc(K);
    end;
end;

function DefaultRiderPose: TRiderPose;
var i: Integer;
begin
  Result := Default(TRiderPose);
  Result.Name := 'Default';
  Result.OffsetX := 0; Result.OffsetY := 0; Result.OffsetZ := 0;
  Result.TorsoLeanDeg := -30;
  Result.SpineCurve := 0;
  Result.SpineManual := False;
  for i := 0 to 4 do Result.SpineAngles[i] := 0;
  Result.KneeFlare := 0; Result.ElbowFlare := 0;
  Result.AnkleFlex := 0;
  Result.ArmPronationR := 0; Result.ArmPronationL := 0;
  Result.ShoulderRoundDeg := 0;
  Result.HandLevel := 1.0;             { hand parallel to the ground by default }
  Result.PedalSway := 0; Result.TorsoBobAmp := 0;
  Result.HandPosR := 1; Result.HandPosL := 1;
  Result.HandFreeRPos := TVector3.Zero; Result.HandFreeLPos := TVector3.Zero;
  Result.HandFreeRWave := 0; Result.HandFreeLWave := 0;
  Result.LegFreeR := 0; Result.LegFreeL := 0;
  Result.LegFreeRPos := TVector3.Zero; Result.LegFreeLPos := TVector3.Zero;
  { selection metadata: by default a pose is auto-selectable and matches ANY situation
    at the lowest priority, so it only wins when no more specific pose applies. }
  Result.Special := False;
  Result.SelPriority := 0;
  Result.SelSpeedMin := 0;     Result.SelSpeedMax := 999;
  Result.SelIntensityMin := 0; Result.SelIntensityMax := 9;
  Result.SelGradeMin := -99;   Result.SelGradeMax := 99;
  Result.TurnSuitable := False;
end;

function StationaryRiderPose: TRiderPose;
begin
  Result := DefaultRiderPose;
  Result.Name := 'Стоит на месте';
  Result.Grounded := True;
  Result.TorsoLeanDeg := -12;          { fairly upright — rider is stopped, not racing }
  Result.HandLevel := 1.0;
  Result.HandPosR := 1; Result.HandPosL := 1;   { hands on the hoods }
  Result.LegFreeR := 0; Result.LegFreeL := 0;   { feet rest on the (non-turning) pedals }
  Result.PedalSway := 0; Result.TorsoBobAmp := 0;
  { auto-selectable, but only when essentially stopped and not putting out power; the
    higher priority makes it win over generic poses (whose speed window also spans 0). }
  Result.Special := False;
  Result.SelPriority := 10;
  Result.SelSpeedMin := 0;     Result.SelSpeedMax := 2;      { km/h }
  Result.SelIntensityMin := 0; Result.SelIntensityMax := 0.15; { fraction of FTP }
  Result.SelGradeMin := -99;   Result.SelGradeMax := 99;
  Result.TurnSuitable := False;
end;

function LerpRiderPose(const A, B: TRiderPose; T: Single): TRiderPose;
  function L(x, y: Single): Single; begin Result := x + (y - x) * T; end;
  procedure BlendFoot(FromFree, ToFree: Single; const FromPos, ToPos: TVector3;
    Left: Boolean; out Free: Single; out Pos: TVector3);
  var U: Single;
  begin
    U := T;
    { Keep the planted endpoint fixed. Lerping it towards the unused zero
      endpoint made the foot cut through the frame on its way to the pedal. }
    if (FromFree > 0.001) and (ToFree <= 0.001) then
    begin
      if A.Grounded then
      begin
        if Left then U := SmoothUnit(T / 0.65)
        else U := SmoothUnit((T - 0.12) / 0.80);
      end;
      Free := FromFree * (1 - U);
      Pos := FromPos;
      Pos.Y := Pos.Y + 0.16 * U; { blended clearance arc, zero at both endpoints }
    end
    else if (FromFree <= 0.001) and (ToFree > 0.001) then
    begin
      if B.Grounded then U := SmoothUnit((T - 0.22) / 0.78);
      Free := ToFree * U;
      Pos := ToPos;
      Pos.Y := Pos.Y + 0.16 * (1 - U);
    end
    else
    begin
      Free := L(FromFree, ToFree);
      Pos := FromPos + (ToPos - FromPos) * T;
    end;
  end;
var i: Integer;
begin
  if T < 0 then T := 0 else if T > 1 then T := 1;
  Result := B;
  Result.Name := B.Name;
  Result.Motion := BlendMotionProfile(A.Motion, B.Motion, T);
  for i := 0 to 4 do
  begin
    Result.SpineYaw[i] := L(A.SpineYaw[i], B.SpineYaw[i]);
    Result.SpineRoll[i] := L(A.SpineRoll[i], B.SpineRoll[i]);
  end;
  Result.OffsetX := L(A.OffsetX, B.OffsetX);
  Result.OffsetY := L(A.OffsetY, B.OffsetY);
  Result.OffsetZ := L(A.OffsetZ, B.OffsetZ);
  Result.TorsoLeanDeg := L(A.TorsoLeanDeg, B.TorsoLeanDeg);
  Result.SpineCurve := L(A.SpineCurve, B.SpineCurve);
  Result.SpineManual := Boolean(IfThen(T < 0.5, Ord(A.SpineManual), Ord(B.SpineManual)));
  for i := 0 to 4 do Result.SpineAngles[i] := L(A.SpineAngles[i], B.SpineAngles[i]);
  Result.KneeFlare := L(A.KneeFlare, B.KneeFlare);
  Result.ElbowFlare := L(A.ElbowFlare, B.ElbowFlare);
  Result.AnkleFlex := L(A.AnkleFlex, B.AnkleFlex);
  Result.ArmPronationR := L(A.ArmPronationR, B.ArmPronationR);
  Result.ArmPronationL := L(A.ArmPronationL, B.ArmPronationL);
  Result.ShoulderRoundDeg := L(A.ShoulderRoundDeg, B.ShoulderRoundDeg);
  Result.HandLevel := L(A.HandLevel, B.HandLevel);
  Result.PedalSway := L(A.PedalSway, B.PedalSway);
  Result.TorsoBobAmp := L(A.TorsoBobAmp, B.TorsoBobAmp);
  { hand grip indices are discrete; the bike animates the actual hand move
    (staggered R-then-L), so the pose just carries the target index }
  Result.HandPosR := B.HandPosR;
  Result.HandPosL := B.HandPosL;
  Result.HandFreeRPos := Vector3(L(A.HandFreeRPos.X, B.HandFreeRPos.X),
                                 L(A.HandFreeRPos.Y, B.HandFreeRPos.Y),
                                 L(A.HandFreeRPos.Z, B.HandFreeRPos.Z));
  Result.HandFreeLPos := Vector3(L(A.HandFreeLPos.X, B.HandFreeLPos.X),
                                 L(A.HandFreeLPos.Y, B.HandFreeLPos.Y),
                                 L(A.HandFreeLPos.Z, B.HandFreeLPos.Z));
  Result.HandFreeRWave := L(A.HandFreeRWave, B.HandFreeRWave);
  Result.HandFreeLWave := L(A.HandFreeLWave, B.HandFreeLWave);
  BlendFoot(A.LegFreeR, B.LegFreeR, A.LegFreeRPos, B.LegFreeRPos, False,
    Result.LegFreeR, Result.LegFreeRPos);
  BlendFoot(A.LegFreeL, B.LegFreeL, A.LegFreeLPos, B.LegFreeLPos, True,
    Result.LegFreeL, Result.LegFreeLPos);
  { selection metadata is descriptive, not animated — carry the target's values }
  Result.Special := B.Special;
  Result.SelPriority := B.SelPriority;
  Result.SelSpeedMin := B.SelSpeedMin;         Result.SelSpeedMax := B.SelSpeedMax;
  Result.SelIntensityMin := B.SelIntensityMin; Result.SelIntensityMax := B.SelIntensityMax;
  Result.SelGradeMin := B.SelGradeMin;         Result.SelGradeMax := B.SelGradeMax;
  Result.TurnSuitable := B.TurnSuitable;
end;

function RiderSpineDelta(const LeanAxis: TVector3; Pitch, Yaw, Roll: Single): TTripoVec4;
var ForwardAxis: TVector3;
begin
  ForwardAxis := TVector3.CrossProduct(Vector3(0, 1, 0), LeanAxis);
  Result := QuatMul(QuatFromAxisAngle(0, 1, 0, DegToRad(Yaw)),
    QuatMul(QuatFromAxisAngle(ForwardAxis.X, ForwardAxis.Y, ForwardAxis.Z, DegToRad(Roll)),
      QuatFromAxisAngle(LeanAxis.X, LeanAxis.Y, LeanAxis.Z, DegToRad(Pitch))));
end;

function TRiderPoseList.Count: Integer;
begin Result := Length(FItems); end;

function TRiderPoseList.GetItem(Index: Integer): TRiderPose;
begin Result := FItems[Index]; end;

procedure TRiderPoseList.SetItem(Index: Integer; const P: TRiderPose);
begin FItems[Index] := P; end;

function TRiderPoseList.Add(const P: TRiderPose): Integer;
begin
  Result := Length(FItems);
  SetLength(FItems, Result + 1);
  FItems[Result] := P;
end;

procedure TRiderPoseList.Delete(Index: Integer);
var i: Integer;
begin
  if (Index < 0) or (Index >= Length(FItems)) then Exit;
  for i := Index to High(FItems) - 1 do FItems[i] := FItems[i + 1];
  SetLength(FItems, Length(FItems) - 1);
end;

procedure TRiderPoseList.Clear;
begin SetLength(FItems, 0); end;

function TRiderPoseList.IndexByName(const AName: string): Integer;
var i: Integer;
begin
  Result := -1;
  for i := 0 to High(FItems) do
    if SameText(FItems[i].Name, AName) then Exit(i);
end;

procedure TRiderPoseList.EnsureDefault;
var I: Integer;
begin
  if IndexByName('Default') < 0 then
  begin
    SetLength(FItems, Length(FItems) + 1);
    { Managed strings: Move would duplicate references without AddRef. }
    for I := High(FItems) downto 1 do FItems[I] := FItems[I - 1];
    FItems[0] := DefaultRiderPose;
  end;
end;

function TTripoRiderScene.CaptureReplay: TRiderPoseReplay;
begin
  Result.Pose:=FPose;
  Result.PoseFrom:=FPoseFrom;
  Result.PoseTo:=FPoseTo;
  Result.PoseElapsed:=FPoseElapsed;
  Result.PoseDur:=FPoseDur;
  Result.PoseAnimating:=FPoseAnimating;
  Result.HasPose:=FHasPose;
end;

procedure TTripoRiderScene.RestoreReplay(const Saved: TRiderPoseReplay);
begin
  FPose:=Saved.Pose;
  FPoseFrom:=Saved.PoseFrom;
  FPoseTo:=Saved.PoseTo;
  FPoseElapsed:=Saved.PoseElapsed;
  FPoseDur:=Saved.PoseDur;
  FPoseAnimating:=Saved.PoseAnimating;
  FHasPose:=Saved.HasPose;
  WritePoseToFields;
end;

constructor TTripoRiderScene.Create;
var
  I: TClothSlot;
begin
  inherited Create;
  FScene := TCastleScene.Create(nil);
  { Shared with TBikeInstance.FBikeScene during MountBikeIntoRider. }
  FScene.InternalNodeSharing := True;
  FSceneOwned := True;
  FRig := TTripoRig.Create;
  FLoaded := False;
  FResolved := 0;
  FSkin := nil;
  { bend directions in the rig frame: Z is lateral, X is fore/aft, so the
    knee bends FORWARD (+X) and the elbow bends BACKWARD (-X). Flip a sign
    if a joint bends the wrong way. }
  ApplyBikeAlignedSpace;
  FTorsoLeanDeg := -30;   { forward lean; flip sign if it leans backward }
  FFileClipBlendDur := 0.30;
  FHelmetPitchXDeg := 0;
  FHelmetParented := False;
  FBodyHeightF := 0;
  FBodyMorphed := False;
  FHelmetRest0Ok := False;
  FHelmetNode := nil;
  FHelmetMatsCached := False;
  SetLength(FHelmetMats, 0);
  SetLength(FHelmetOrigColor, 0);
  FNativeRestH := 0;
  FHemOverlayOn := True;
  { цвета одежды: дефолтная палитра = родные цвета ткани, всё выключено,
    способ по умолчанию — запечка в текстуру при загрузке }
  FDyeMode := cdmTexture;
  FDyeShBusy := False;
  for I := Low(TClothSlot) to High(TClothSlot) do
  begin
    FDyeColor[I] := ClothDyeNativeColor(I);
    FDyeActive[I] := False;
  end;
end;

destructor TTripoRiderScene.Destroy;
var i: Integer;
begin
  FreeAndNil(FCorrectives);
  ResetGroundShadeEffect;
  { Free our pristine pixel copies of the MR textures. The texture NODES were
    never detached or replaced (only their image contents rewritten), so the
    scene owns and frees them normally. }
  for i := 0 to High(FMatOrigImg) do
    FreeAndNil(FMatOrigImg[i]);
  { То же для pristine-копий baseColor-текстур покраски одежды. }
  for i := 0 to High(FDyeOrigImg) do
    FreeAndNil(FDyeOrigImg[i]);
  { The caller must remove FScene from the viewport before freeing us.
    После MountInto сцена чужая (единая сцена байка) — не трогаем. }
  if FSceneOwned then
    FreeAndNil(FScene)
  else
    FScene := nil;
  FreeAndNil(FRig);
  inherited Destroy;
end;

procedure TTripoRiderScene.MountInto(AScene: TCastleScene; AParent: TAbstractGroupingNode);
begin
  if (AParent = nil) or (FScene = nil) or (FScene.RootNode = nil) then Exit;
  { Двойное родительство: корень GLB становится ребёнком группы в единой
    сцене, но остаётся корнем своей (вне-вьюпортной) сцены — весь код
    rig'а (поиск узлов, материалы, InverseTransform) работает по-прежнему
    на своей сцене, а рендер идёт через общую. Свою сцену не освобождаем —
    она владеет узлами графа; умрёт вместе с rig'ом в Destroy. }
  AParent.AddChildren(FScene.RootNode);
end;

procedure TTripoRiderScene.GrabSkin(Node: TX3DNode);
begin
  if Node is TSkinNode then
  begin
    SetLength(FSkinList, Length(FSkinList) + 1);
    FSkinList[High(FSkinList)] := TSkinNode(Node);
  end;
end;

{ Pick, among every Skin node CGE built, the one whose joint palette matches
  FRig — i.e. the skin of the first skinned primitive, the very skin CGE
  GPU-skins. Score = number of palette slots whose node name equals
  FRig.JointName at the SAME index, with big bonuses for an exactly equal
  joint count and for owning shapes (only a mesh-driving skin has FdShapes).
  A glb can carry a leftover second armature with the very same bone names
  (Root/Hip/Pelvis/...): matching the palette as a whole, not individual
  names, keeps such an orphan from winning. }
function TTripoRiderScene.SelectSkinForRig: TSkinNode;
var
  K, I, NJ, Score, Best: Integer;
  S: TSkinNode;
  NodeName: string;
begin
  Result := nil;
  Best := -1;
  for K := 0 to High(FSkinList) do
  begin
    S := FSkinList[K];
    if S = nil then Continue;
    Score := 0;
    NJ := Min(S.FdJoints.Count, FRig.JointCount);
    for I := 0 to NJ - 1 do
      if S.FdJoints[I] <> nil then
      begin
        NodeName := S.FdJoints[I].X3DName;
        { Exact palette match OR canonical alias (Mixamo / Blender prefixes). }
        if (NodeName = FRig.JointName[I])
           or (CanonicalJointName(NodeName) = FRig.JointName[I]) then
          Inc(Score);
      end;
    { Contact skins are 1-joint ("Bone") — never pick them over the body. }
    if S.FdJoints.Count = FRig.JointCount then Inc(Score, 1000);
    if S.FdJoints.Count >= 20 then Inc(Score, 200);  { real body palette size }
    if S.FdShapes.Count > 0 then Inc(Score, 2000 + S.FdShapes.Count * 10);
    if Score > Best then
    begin
      Best := Score;
      Result := S;
    end;
  end;
  { If nothing scored (exotic names), still take the skin that owns shapes. }
  if (Result = nil) or ((Best < 2000) and (Length(FSkinList) > 0)) then
    for K := 0 to High(FSkinList) do
      if (FSkinList[K] <> nil) and (FSkinList[K].FdShapes.Count > 0)
         and (FSkinList[K].FdJoints.Count >= 15) then
      begin
        Result := FSkinList[K];
        Break;
      end;
end;

procedure TTripoRiderScene.GrabStrayShape(Node: TX3DNode);
var K, I: Integer;
begin
  if not (Node is TShapeNode) then Exit;
  for K := 0 to High(FSkinList) do
    if FSkinList[K] <> nil then
      for I := 0 to FSkinList[K].FdShapes.Count - 1 do
        if FSkinList[K].FdShapes[I] = Node then Exit;   { skin-driven — fine }
  if FStrayShapes <> nil then
    FStrayShapes.Add(Node.NiceName);
end;

procedure TTripoRiderScene.GrabCoord(Node: TX3DNode);
begin
  if Node is TCoordinateNode then
  begin
    SetLength(FShapeCoords, Length(FShapeCoords) + 1);
    FShapeCoords[High(FShapeCoords)] := TCoordinateNode(Node);
  end;
end;

procedure TTripoRiderScene.ResetGroundShadeEffect;
begin
  FGroundShadeUniform := nil;
  if FGroundShadeEffect<>nil then FGroundShadeEffect.KeepExistingEnd;
  FGroundShadeEffect := nil;
end;

procedure TTripoRiderScene.AttachGroundShade(Node: TX3DNode);
var Sh: TShapeNode; App: TAppearanceNode;
begin
  Sh := Node as TShapeNode;
  if Sh.Appearance=nil then Sh.Appearance := TAppearanceNode.Create;
  if not (Sh.Appearance is TAppearanceNode) then Exit;
  App := Sh.Appearance as TAppearanceNode;
  if App.FdEffects.IndexOf(FGroundShadeEffect)>=0 then Exit;
  { Append preserves existing dye effects. SetEffects would clear/free them
    before reusing the same node pointers when scene events are disabled. }
  App.FdEffects.Add(FGroundShadeEffect);
end;

procedure TTripoRiderScene.SetGroundShade(const Value: Single);
var Part: TEffectPartNode; Scope: TX3DNode; V: Single;
begin
  V := EnsureRange(Value,0.0,1.0);
  FGroundShade := V;
  if FGroundShadeEffect=nil then
  begin
    Scope := RiderContentRoot;
    if Scope=nil then Exit;
    FGroundShadeEffect := TEffectNode.Create('RiderGroundShade');
    FGroundShadeEffect.KeepExistingBegin;
    FGroundShadeEffect.Language := slGLSL;
    FGroundShadeEffect.UniformMissing := umIgnore; { omitted by depth-only pass }
    FGroundShadeUniform := TSFFloat.Create(FGroundShadeEffect,True,'riderGroundShade',V);
    FGroundShadeEffect.AddCustomField(FGroundShadeUniform);
    Part := TEffectPartNode.Create; Part.FdType.Value := 'FRAGMENT';
    Part.Contents := 'uniform float riderGroundShade;' + #10 +
      'void PLUG_fragment_modify(inout vec4 fragment_color) {' + #10 +
      '  fragment_color.rgb *= 1.0 - 0.30 * clamp(riderGroundShade, 0.0, 1.0);' + #10 +
      '}';
    FGroundShadeEffect.SetParts([Part]);
    FScene.BeginChangesSchedule;
    try
      Scope.EnumerateNodes(TShapeNode,@AttachGroundShade,False);
      FGroundShadeEffect.Scene := FScene;
      FScene.ChangedAll;
    finally FScene.EndChangesSchedule end;
  end;
  if FGroundShadeUniform.Value<>V then FGroundShadeUniform.Send(V);
end;

function TTripoRiderScene.RiderContentRoot: TX3DNode;
{ After MountBikeIntoRider the shared scene root holds:
    RiderVis  (TSwitchNode)  — original glb mesh / materials / skeleton
    BikeFrame (TMatrixTransformNode) — parametric bike BSG_* geometry
  Body-shape (heightScale / bulk / belly) and gloss must only walk the rider
  subtree; EnumerateNodes on the full Root warps wheel Coordinate nodes
  (hub midY ≈ −4 mm with heightScale ≠ 0) → wheels jump, and retints bike PBR. }
var
  Root: TX3DRootNode;
  RiderVis: TX3DNode;
begin
  Result := nil;
  if (FScene = nil) or (FScene.RootNode = nil) then Exit;
  Root := FScene.RootNode;
  RiderVis := Root.TryFindNodeByName(TSwitchNode, 'RiderVis', false);
  if RiderVis <> nil then
    Result := RiderVis
  else
    Result := Root;   { pre-mount / no bike: whole scene is the rider glb }
end;

function TTripoRiderScene.DyeSceneIsRiderOnly: Boolean;
var
  Scope: TX3DNode;
begin
  { Editor: scene IS the glb. Game after MountBikeIntoRider: Root has
    RiderVis + BikeFrame — FdEffects.Add is chEverything and ChangedAll
    rebuilds the whole parametric bike (nvoglv64 freeze). }
  Scope := RiderContentRoot;
  Result := (FScene <> nil) and (FScene.RootNode <> nil) and (Scope = FScene.RootNode);
end;

procedure TTripoRiderScene.CacheShape;
var
  ci, vi: Integer;
  pts: TVector3List;
  v: TVector3;
  first: Boolean;
  Scope: TX3DNode;
begin
  if FShapeCached then Exit;
  FShapeCached := True;
  SetLength(FShapeCoords, 0);
  Scope := RiderContentRoot;
  if Scope <> nil then
    Scope.EnumerateNodes(TCoordinateNode, @GrabCoord, false);

  SetLength(FOrigPts, Length(FShapeCoords));
  first := True;
  for ci := 0 to High(FShapeCoords) do
  begin
    pts := FShapeCoords[ci].FdPoint.Items;
    SetLength(FOrigPts[ci], pts.Count);
    for vi := 0 to pts.Count - 1 do
    begin
      v := pts[vi];
      FOrigPts[ci][vi] := v;
      if first then
      begin
        FBoxMinX := v.X; FBoxMaxX := v.X;
        FBoxMinY := v.Y; FBoxMaxY := v.Y;
        FBoxMinZ := v.Z; FBoxMaxZ := v.Z;
        first := False;
      end
      else
      begin
        if v.X < FBoxMinX then FBoxMinX := v.X;  if v.X > FBoxMaxX then FBoxMaxX := v.X;
        if v.Y < FBoxMinY then FBoxMinY := v.Y;  if v.Y > FBoxMaxY then FBoxMaxY := v.Y;
        if v.Z < FBoxMinZ then FBoxMinZ := v.Z;  if v.Z > FBoxMaxZ then FBoxMaxZ := v.Z;
      end;
    end;
  end;
  FBoxCX := (FBoxMinX + FBoxMaxX) * 0.5;
  FBoxCZ := (FBoxMinZ + FBoxMaxZ) * 0.5;
  FBoxW  := FBoxMaxX - FBoxMinX;
  FBoxD  := FBoxMaxZ - FBoxMinZ;
  ComputeBulkMaskFromTPose;
end;

procedure TTripoRiderScene.ComputeBulkMaskFromTPose;
{ T-pose rest: arms are far from the body axis, waist band has no hands.
  Fit an XZ ellipse at the waist and store per-vertex weight — bulk then
  scales only the torso (and legs), not the outstretched arms. }
var
  ci, vi, n: Integer;
  H, y0, y1, wy, band, dx, dz, e, w, t: Single;
  v, jp: TVector3;
  xs, zs: array of Single;

  procedure SortN(var Arr: array of Single; N: Integer);
  var ii, jj: Integer; x: Single;
  begin
    for ii := 1 to N - 1 do
    begin
      x := Arr[ii];
      jj := ii;
      while (jj > 0) and (Arr[jj - 1] > x) do
      begin
        Arr[jj] := Arr[jj - 1];
        Dec(jj);
      end;
      Arr[jj] := x;
    end;
  end;

  function Perc(var Arr: array of Single; N: Integer; P: Single): Single;
  var k: Integer;
  begin
    if N <= 0 then Exit(0.12);
    SortN(Arr, N);
    k := Round(P * (N - 1));
    if k < 0 then k := 0;
    if k > N - 1 then k := N - 1;
    Result := Arr[k];
  end;

begin
  SetLength(FBulkW, Length(FOrigPts));
  FBulkWaistRX := 0.16;
  FBulkWaistRZ := 0.12;
  if Length(FOrigPts) = 0 then Exit;
  H := FBoxMaxY - FBoxMinY;
  if H < 1e-4 then Exit;

  wy := FBoxMinY + 0.52 * H;
  if BindV('Waist', jp) then wy := jp.Y
  else if BindV('Spine', jp) then wy := jp.Y
  else if BindV('Pelvis', jp) then wy := jp.Y
  else if BindV('Hips', jp) then wy := jp.Y;
  band := 0.04 * H;
  y0 := wy - band;
  y1 := wy + band;

  n := 0;
  SetLength(xs, 512);
  SetLength(zs, 512);
  for ci := 0 to High(FOrigPts) do
    for vi := 0 to High(FOrigPts[ci]) do
    begin
      v := FOrigPts[ci][vi];
      if (v.Y < y0) or (v.Y > y1) then Continue;
      if n >= Length(xs) then
      begin
        SetLength(xs, n * 2);
        SetLength(zs, n * 2);
      end;
      xs[n] := Abs(v.X - FBoxCX);
      zs[n] := Abs(v.Z - FBoxCZ);
      Inc(n);
    end;
  FBulkWaistRX := Max(0.05, Perc(xs, n, 0.90));
  FBulkWaistRZ := Max(0.04, Perc(zs, n, 0.90));

  for ci := 0 to High(FOrigPts) do
  begin
    SetLength(FBulkW[ci], Length(FOrigPts[ci]));
    for vi := 0 to High(FOrigPts[ci]) do
    begin
      v := FOrigPts[ci][vi];
      dx := (v.X - FBoxCX) / FBulkWaistRX;
      dz := (v.Z - FBoxCZ) / FBulkWaistRZ;
      e := Sqrt(dx * dx + dz * dz);
      { 1 = on the T-pose waist ellipse. Arms sit at e ≈ 3..6. }
      if e <= 1.12 then
        w := 1
      else if e >= 1.55 then
        w := 0
      else
      begin
        t := (e - 1.12) / (1.55 - 1.12);
        w := 1 - t * t * (3 - 2 * t);
      end;
      FBulkW[ci][vi] := w;
    end;
  end;
end;

function TTripoRiderScene.BindV(const AName: string; out P: TVector3): Boolean;
var idx: Integer; q: TTripoVec3;
begin
  idx := FRig.JointIndexByName(AName);
  Result := idx >= 0;
  if Result then
  begin
    q := FRig.JointBindPos(idx);
    P := Vector3(q.X, q.Y, q.Z);
  end
  else
    P := Vector3(0, 0, 0);
end;

procedure TTripoRiderScene.FillLimb(const Names: array of string;
  var Pts: array of TVector3; out N: Integer);
var i: Integer; p: TVector3;
begin
  N := 0;
  for i := 0 to High(Names) do
    if BindV(Names[i], p) and (N <= High(Pts)) then
    begin
      Pts[N] := p;
      Inc(N);
    end;
end;

{ Displacement of vertex v when the limb polyline P[0..PCount-1] (proximal→distal,
  in rest/bind space) is stretched lengthwise by Factor. Vertices within Radius of
  the polyline move along the bones (cumulative: a foot point gets the thigh +
  shin elongation, each along its own bone direction); far vertices get zero. This
  follows the actual bone directions, so it works in a bent/cycling rest pose. }
function TTripoRiderScene.LimbStretchDisp(const v: TVector3;
  const P: array of TVector3; PCount: Integer; Factor, Radius, TipR: Single): TVector3;
var
  i: Integer;
  a, dir, closest, cum, segDisp, Dtotal: TVector3;
  segLen, t, d, bestD, mBone, mTip, distTip, u: Single;
begin
  Result := Vector3(0, 0, 0);
  if PCount < 2 then Exit;
  bestD := 1e30;
  segDisp := Vector3(0, 0, 0);
  cum := Vector3(0, 0, 0);          { elongation accumulated up to segment i's start }
  for i := 0 to PCount - 2 do
  begin
    a := P[i];
    dir := P[i + 1] - a;
    segLen := dir.Length;
    if segLen < 1e-6 then Continue;
    dir := dir / segLen;
    t := TVector3.DotProduct(v - a, dir);   { projection along the bone (length units) }
    if t < 0 then t := 0;
    if t > segLen then t := segLen;
    closest := a + dir * t;
    d := (v - closest).Length;
    if d < bestD then
    begin
      bestD := d;
      segDisp := cum + dir * ((Factor - 1.0) * t);   { upstream + partial this bone }
    end;
    cum := cum + dir * ((Factor - 1.0) * segLen);     { full bone elongation }
  end;
  Dtotal := cum;                    { total limb elongation (the distal joint's move) }

  { bone membership — thin tube around the bones (excludes the torso) }
  mBone := 0.0;
  if bestD < Radius then
  begin
    mBone := 1.0 - bestD / Radius;
    mBone := mBone * mBone * (3.0 - 2.0 * mBone);
  end;

  { rigid extremity — the hand/foot sits BEYOND the last joint, so projecting it
    onto the bones squashes it. Instead, translate everything within a sphere of
    the distal joint rigidly by Dtotal. Plateau out to TipR (whole hand rigid),
    then fade. }
  distTip := (v - P[PCount - 1]).Length;
  if distTip <= TipR then
    mTip := 1.0
  else if distTip >= TipR * 1.4 then
    mTip := 0.0
  else
  begin
    u := (distTip - TipR) / (TipR * 0.4);
    mTip := 1.0 - u * u * (3.0 - 2.0 * u);
  end;

  { extremity rigid where mTip is high; bones stretch elsewhere. At the wrist both
    agree (segDisp ≈ Dtotal there), so the blend is seamless. }
  Result := Dtotal * mTip + segDisp * (mBone * (1.0 - mTip));
end;

procedure TTripoRiderScene.ApplyBodyShape(Bulk, Belly, HeightF: Single);
var
  ci, vi: Integer;
  pts: TVector3List;
  v0, disp: TVector3;
  H, bellyY, shoulderY, taper, g, t, depth, w: Single;
  NeedMorph: Boolean;
begin
  if not FLoaded then Exit;
  CacheShape;
  if Length(FShapeCoords) = 0 then Exit;
  H := FBoxMaxY - FBoxMinY;
  if H < 1e-6 then Exit;

  { Height is skeleton-side (ApplyLimbLengths HeightK). Do not rewrite the
    rest mesh on a height-only click — FdPoint.Changed reuploads every vert
    and was a big part of the UI freeze. }
  NeedMorph := (Abs(Bulk) > 1e-5) or (Abs(Belly) > 1e-5);
  if NeedMorph or FBodyMorphed then
  begin
    bellyY    := FBoxMinY + 0.58 * H;
    shoulderY := FBoxMinY + 0.80 * H;
    depth     := Max(FBoxD, 1e-4);

    for ci := 0 to High(FShapeCoords) do
    begin
      pts := FShapeCoords[ci].FdPoint.Items;
      if pts.Count <> Length(FOrigPts[ci]) then Continue;
      for vi := 0 to pts.Count - 1 do
      begin
        v0   := FOrigPts[ci][vi];
        disp := Vector3(0, 0, 0);

        if Abs(Bulk) > 1e-5 then
        begin
          taper := 1.0;
          if v0.Y > shoulderY then
            taper := Max(0.0, 1.0 - (v0.Y - shoulderY) / Max(FBoxMaxY - shoulderY, 1e-4));
          w := 1;
          if (ci <= High(FBulkW)) and (vi <= High(FBulkW[ci])) then
            w := FBulkW[ci][vi];
          disp.X := disp.X + (v0.X - FBoxCX) * Bulk * taper * w;
          disp.Z := disp.Z + (v0.Z - FBoxCZ) * Bulk * taper * w;
        end;

        if Abs(Belly) > 1e-5 then
        begin
          t := (v0.Y - bellyY) / (0.18 * H);
          g := Exp(-t * t);
          if v0.X > FBoxCX then
            disp.X := disp.X + Belly * g * depth;
        end;

        pts[vi] := v0 + disp;
      end;
      FShapeCoords[ci].FdPoint.Changed;
    end;
    FBodyMorphed := NeedMorph;
  end;
  FBodyHeightF := HeightF;
  if FHelmetNode <> nil then
    ApplyHelmetFollow;
end;

procedure TTripoRiderScene.CacheBones;
const
  { A child joint's LOCAL translation is the bone segment from its parent —
    scaling it changes that segment's length (or lateral offset). }
  BONES: array[0..34] of string =
    ('R_Calf', 'R_Foot', 'L_Calf', 'L_Foot',          { 0..3  leg: thigh+shin bones }
     'R_Forearm', 'R_Hand', 'L_Forearm', 'L_Hand',    { 4..7  arm: upperarm+forearm bones }
     'R_Upperarm', 'L_Upperarm',                      { 8..9  clavicle bones = shoulder width }
     'R_Thigh', 'L_Thigh',                            { 10..11 pelvis->hip offsets = pelvis width }
     'Waist', 'Spine', 'Spine01', 'Spine02',          { 12..16 spine chain = torso length }
     'NeckTwist01',
     { Mixamo twist helpers sit on the same segments as thigh/shin. Socks
       and calf flesh are weighted to CalfTwist*, not L_Calf — if we scale
       Foot but leave twists, the sock stays and the boot leaves. }
     'R_ThighTwist01', 'R_ThighTwist02', 'L_ThighTwist01', 'L_ThighTwist02',
     'R_CalfTwist01', 'R_CalfTwist02', 'L_CalfTwist01', 'L_CalfTwist02',
     'R_UpperarmTwist01', 'R_UpperarmTwist02', 'L_UpperarmTwist01', 'L_UpperarmTwist02',
     'R_ForearmTwist01', 'R_ForearmTwist02', 'L_ForearmTwist01', 'L_ForearmTwist02',
     'NeckTwist02', 'Head');
var k, j: Integer;
begin
  if FBonesCached then Exit;
  if (FRig = nil) or (not FLoaded) then Exit;
  FBonesCached := True;
  for k := 0 to High(BONES) do
  begin
    j := FRig.JointIndexByName(BONES[k]);
    FBoneJoint[k] := j;
    if j >= 0 then
    begin
      FBoneOrigLocalT[k] := Vector3(FRig.BindLocal[j][12], FRig.BindLocal[j][13],
                                    FRig.BindLocal[j][14]);
      if (j <= High(FJointNode)) and (FJointNode[j] <> nil) then
        FBoneOrigNodeT[k] := FJointNode[j].Translation
      else
        FBoneOrigNodeT[k] := Vector3(0, 0, 0);
    end
    else
    begin
      FBoneOrigLocalT[k] := Vector3(0, 0, 0);
      FBoneOrigNodeT[k]  := Vector3(0, 0, 0);
    end;
  end;
  FOrigLegReach := LegReach;     { capture reach BEFORE any scaling }
  FOrigThighLen := V3Len(V3Sub(FRig.JointBindPos(FRig.JointIndexByName('R_Calf')),
    FRig.JointBindPos(FRig.JointIndexByName('R_Thigh'))));
  FOrigShinLen := V3Len(V3Sub(FRig.JointBindPos(FRig.JointIndexByName('R_Foot')),
    FRig.JointBindPos(FRig.JointIndexByName('R_Calf'))));
  if FOrigThighLen < 0.05 then
    FOrigThighLen := FOrigLegReach * 0.53;
  if FOrigShinLen < 0.05 then
    FOrigShinLen := FOrigLegReach * 0.47;
end;

procedure TTripoRiderScene.FreezeBootSkin;
{ Boots primitive is skinned to Calf+Foot. Shin scale (inseam) then stretches
  the shoe into a half-boot or flattens it. Collapse boot weights onto
  Foot/Toe so the shoe is a rigid child of the ankle — mesh Y is constant. }
var
  I, V, A, Pal, NV, LFootPal, RFootPal, KeepPal: Integer;
  Sh: TShapeNode;
  Slot: TClothSlot;
  Geo: TAbstractComposedGeometryNode;
  Wts: TVector4List;
  Jts: TInt32List;
  W: TVector4;
  IsFoot: array of Boolean;
  Nm: string;
  JNode: TX3DNode;
  FootW, Comp: Single;
  Wa: array[0..3] of Single;
  SideL: Boolean;

  procedure SetComp(var Vec: TVector4; Idx: Integer; const Val: Single);
  begin
    case Idx of
      0: Vec.X := Val;
      1: Vec.Y := Val;
      2: Vec.Z := Val;
      else Vec.W := Val;
    end;
  end;

begin
  if (FSkin = nil) or (FScene = nil) or (FScene.RootNode = nil) then Exit;
  SetLength(IsFoot, FSkin.FdJoints.Count);
  LFootPal := -1;
  RFootPal := -1;
  for Pal := 0 to FSkin.FdJoints.Count - 1 do
  begin
    IsFoot[Pal] := False;
    JNode := FSkin.FdJoints[Pal];
    if JNode = nil then Continue;
    Nm := UpperCase(JNode.X3DName);
    if (Pos('FOOT', Nm) > 0) or (Pos('TOE', Nm) > 0) then
    begin
      IsFoot[Pal] := True;
      if Pos('L_', Nm) = 1 then
      begin
        if Pos('TOE', Nm) = 0 then LFootPal := Pal;
      end
      else if Pos('R_', Nm) = 1 then
        if Pos('TOE', Nm) = 0 then RFootPal := Pal;
    end;
  end;
  SetLength(FDyeShapeBuf, 0);
  FScene.RootNode.EnumerateNodes(TShapeNode, @GrabDyeShape, False);
  FScene.BeginChangesSchedule;
  try
    for I := 0 to High(FDyeShapeBuf) do
    begin
      Sh := FDyeShapeBuf[I];
      if (Sh = nil) or (not SlotOfLiveShape(Sh, Slot)) or (Slot <> csBoots) then
        Continue;
      if not (Sh.Geometry is TAbstractComposedGeometryNode) then Continue;
      Geo := TAbstractComposedGeometryNode(Sh.Geometry);
      if not Geo.SkinWeightsJoints(Wts, Jts) then Continue;
      NV := Wts.Count;
      if (NV <= 0) or (Jts.Count < NV * 4) then Continue;
      for V := 0 to NV - 1 do
      begin
        W := Wts[V];
        Wa[0] := W.X; Wa[1] := W.Y; Wa[2] := W.Z; Wa[3] := W.W;
        FootW := 0;
        SideL := False;
        for A := 0 to 3 do
        begin
          Pal := Jts[V * 4 + A];
          if (Pal >= 0) and (Pal <= High(IsFoot)) then
          begin
            if IsFoot[Pal] then
              FootW := FootW + Wa[A]
            else
            begin
              JNode := FSkin.FdJoints[Pal];
              if JNode <> nil then
              begin
                Nm := UpperCase(JNode.X3DName);
                if Pos('L_', Nm) = 1 then SideL := True;
              end;
            end;
          end;
        end;
        if FootW > 1e-4 then
        begin
          Comp := 1.0 / FootW;
          for A := 0 to 3 do
          begin
            Pal := Jts[V * 4 + A];
            if (Pal >= 0) and (Pal <= High(IsFoot)) and IsFoot[Pal] then
              SetComp(W, A, Wa[A] * Comp)
            else
              SetComp(W, A, 0);
          end;
        end
        else
        begin
          if SideL then KeepPal := LFootPal else KeepPal := RFootPal;
          if KeepPal < 0 then
            if LFootPal >= 0 then KeepPal := LFootPal else KeepPal := RFootPal;
          if KeepPal < 0 then Continue;
          Jts[V * 4 + 0] := KeepPal;
          Jts[V * 4 + 1] := KeepPal;
          Jts[V * 4 + 2] := KeepPal;
          Jts[V * 4 + 3] := KeepPal;
          W := Vector4(1, 0, 0, 0);
        end;
        Wts[V] := W;
      end;
      Geo.FdSkinWeights0.Changed;
      Geo.FdSkinJoints0.Changed;
    end;
  finally
    FScene.EndChangesSchedule;
    SetLength(FDyeShapeBuf, 0);
  end;
end;

procedure TTripoRiderScene.BindShinToBoot;
{ Homothety of Calf children (Foot vs CalfTwist) when inseam grows pulls a
  Foot-only boot away from a Twist-weighted sock. Blend only the ankle/cuff
  into the boot; the calf must not bend or twist with the foot.
  All distances here are in the NATIVE MESH frame (inverse file IBM), not
  BindWorld which already includes the armature's 1.6/1.8 scale. Mixing those
  frames spread foot influence up to the knee and creased the calf. }
const
  AnkleBlendStart = 0.78;  { fraction knee -> ankle }
  AnkleBlendEnd = 0.92;
var
  I, V, A, Pal, NV, LFootPal, RFootPal, FootPal, Weak: Integer;
  Sh: TShapeNode;
  Slot: TClothSlot;
  Geo: TAbstractComposedGeometryNode;
  Wts: TVector4List;
  Jts: TInt32List;
  Coord: TCoordinateNode;
  Pts: TVector3List;
  W: TVector4;
  Nm, Lb: string;
  JNode: TX3DNode;
  LCalfP, RCalfP, LFootP, RFootP, CalfP, FootP, Vert: TVector3;
  SumW, OtherW: Single;
  Wa: array[0..3] of Single;
  Tval, Dval, L2, SideMul: Single;
  SideL, HasThigh, HasCalf, IsSock, IsLeg: Boolean;
  IsFoot: array of Boolean;
  FoundFoot: Integer;

  function PalOf(const JointNm: string): Integer;
  var P: Integer;
  begin
    Result := -1;
    if FSkin = nil then Exit;
    for P := 0 to FSkin.FdJoints.Count - 1 do
    begin
      JNode := FSkin.FdJoints[P];
      if (JNode <> nil) and SameText(JNode.X3DName, JointNm) then
        Exit(P);
    end;
  end;

  function MeshBindP(const JointNm: string; out P: TVector3): Boolean;
  var Ji: Integer;
    M: TTripoMat4;
  begin
    Result := False;
    P := Vector3(0, 0, 0);
    if FRig = nil then Exit;
    Ji := FRig.JointIndexByName(JointNm);
    if (Ji < 0) or (Ji >= Length(FRig.NativeInvBind)) then Exit;
    M := Mat4Inverse(FRig.NativeInvBind[Ji]);
    P := Vector3(M[12], M[13], M[14]);
    Result := True;
  end;

begin
  if (FSkin = nil) or (FScene = nil) or (FScene.RootNode = nil) or (FRig = nil) then
    Exit;
  LFootPal := PalOf('L_Foot');
  RFootPal := PalOf('R_Foot');
  if not MeshBindP('L_Calf', LCalfP) or not MeshBindP('L_Foot', LFootP) then
    LFootPal := -1;
  if not MeshBindP('R_Calf', RCalfP) or not MeshBindP('R_Foot', RFootP) then
    RFootPal := -1;
  if (LFootPal < 0) and (RFootPal < 0) then Exit;
  SetLength(IsFoot, FSkin.FdJoints.Count);
  for Pal := 0 to High(IsFoot) do
  begin
    JNode := FSkin.FdJoints[Pal];
    if JNode = nil then Continue;
    Nm := UpperCase(JNode.X3DName);
    IsFoot[Pal] := (Pos('FOOT', Nm) > 0) or (Pos('TOE', Nm) > 0);
  end;

  SetLength(FDyeShapeBuf, 0);
  FScene.RootNode.EnumerateNodes(TShapeNode, @GrabDyeShape, False);
  FScene.BeginChangesSchedule;
  try
    for I := 0 to High(FDyeShapeBuf) do
    begin
      Sh := FDyeShapeBuf[I];
      if (Sh = nil) or (not SlotOfLiveShape(Sh, Slot)) then Continue;
      Lb := LowerCase(DyeLabelOfShape(Sh));
      IsSock := Slot = csSocks;
      IsLeg := (Slot = csSkin) and (Pos('leg', Lb) > 0) and (Pos('finger', Lb) = 0);
      if (not IsSock) and (not IsLeg) then Continue;
      if not (Sh.Geometry is TAbstractComposedGeometryNode) then Continue;
      Geo := TAbstractComposedGeometryNode(Sh.Geometry);
      if not Geo.SkinWeightsJoints(Wts, Jts) then Continue;
      if not (Geo.FdCoord.Value is TCoordinateNode) then Continue;
      Coord := TCoordinateNode(Geo.FdCoord.Value);
      Pts := Coord.FdPoint.Items;
      NV := Wts.Count;
      if (NV <= 0) or (Jts.Count < NV * 4) or (Pts.Count < NV) then Continue;

      for V := 0 to NV - 1 do
      begin
        SideL := False;
        HasThigh := False;
        HasCalf := False;
        W := Wts[V];
        for A := 0 to 3 do
        begin
          if W[A] <= 0 then Continue;  { unused slots may name any joint }
          Pal := Jts[V * 4 + A];
          if (Pal < 0) or (Pal >= FSkin.FdJoints.Count) then Continue;
          JNode := FSkin.FdJoints[Pal];
          if JNode = nil then Continue;
          Nm := UpperCase(JNode.X3DName);
          if Pos('THIGH', Nm) > 0 then HasThigh := True;
          if Pos('CALF', Nm) > 0 then
          begin
            HasCalf := True;
            SideL := Pos('L_', Nm) = 1;
          end;
        end;
        if HasThigh or not HasCalf then Continue;

        Vert := Pts[V];
        if SideL then
        begin
          CalfP := LCalfP;
          FootP := LFootP;
          FootPal := LFootPal;
        end
        else
        begin
          CalfP := RCalfP;
          FootP := RFootP;
          FootPal := RFootPal;
        end;
        if FootPal < 0 then Continue;
        L2 := TVector3.DotProduct(FootP - CalfP, FootP - CalfP);
        if L2 < 1e-8 then Continue;
        Tval := TVector3.DotProduct(Vert - CalfP, FootP - CalfP) / L2;
        Dval := (Vert - (CalfP + (FootP - CalfP) * EnsureRange(Tval, 0, 1))).Length;
        if (Dval > Sqrt(L2) * 0.4) or (Tval < 0) then Continue;
        SideMul := EnsureRange((Tval - AnkleBlendStart) /
          (AnkleBlendEnd - AnkleBlendStart), 0, 1);
        SideMul := SideMul * SideMul * (3 - 2 * SideMul);

        Wa[0] := W.X; Wa[1] := W.Y; Wa[2] := W.Z; Wa[3] := W.W;
        { Preserve the relative calf/twist weights. Replace, rather than add to,
          authored foot weights so yaw never leaks above the ankle transition. }
        FoundFoot := -1;
        Weak := 0;
        OtherW := 0;
        for A := 0 to 3 do
        begin
          Pal := Jts[V * 4 + A];
          if (Pal >= 0) and (Pal <= High(IsFoot)) and IsFoot[Pal] then
          begin
            Wa[A] := 0;
            if FoundFoot < 0 then FoundFoot := A;
          end;
          if Wa[A] < Wa[Weak] then Weak := A;
          OtherW := OtherW + Wa[A];
        end;
        if OtherW <= 1e-6 then Continue;
        if FoundFoot < 0 then FoundFoot := Weak;
        if SideMul > 0 then
        begin
          OtherW := OtherW - Wa[FoundFoot];
          Wa[FoundFoot] := 0;
          Jts[V * 4 + FoundFoot] := FootPal;
        end;
        if OtherW <= 1e-6 then Continue;
        for A := 0 to 3 do
          Wa[A] := Wa[A] * (1.0 - SideMul) / OtherW;
        if SideMul > 0 then Wa[FoundFoot] := SideMul;
        SumW := Wa[0] + Wa[1] + Wa[2] + Wa[3];
        if SumW > 1e-6 then
        begin
          W.X := Wa[0] / SumW;
          W.Y := Wa[1] / SumW;
          W.Z := Wa[2] / SumW;
          W.W := Wa[3] / SumW;
        end;
        Wts[V] := W;
      end;
      Geo.FdSkinWeights0.Changed;
      Geo.FdSkinJoints0.Changed;
    end;
  finally
    FScene.EndChangesSchedule;
    SetLength(FDyeShapeBuf, 0);
  end;
end;

procedure TTripoRiderScene.CacheContactOffsets;

  procedure One(Idx: Integer; const EndJoint, MarkerName: string);
  var
    ei: Integer;
    m: TVector3;
    mRig, jRig: TTripoVec3;
    restQ: TTripoVec4;
    nb: TTripoMat4;
  begin
    FContactValid[Idx] := False;
    FContactLocal[Idx] := V3(0, 0, 0);
    if FRig = nil then Exit;
    ei := FRig.JointIndexByName(EndJoint);
    if ei < 0 then Exit;
    if not ContactNodeWorld(MarkerName, m) then Exit;   { marker bone head, model frame }
    mRig := V3(m.X, m.Y, m.Z);
    { Bake the wrist/ankle->marker offset in the NATIVE end-bone frame. InvBind is
      kept native through limb scaling, so inverse(InvBind) is the native bind even
      after armLen/legLen stretch the bone. Using the native (not the stretched
      BindWorld) bind makes the offset the true rigid hand/foot length: the IK's
      reach to the contact then grows by the same delta the bone grew, instead of
      the +delta in the arm and the -delta in the offset cancelling (which pinned
      the contact to the native palm). }
    nb := Mat4Inverse(FRig.InvBind[ei]);
    jRig := V3(nb[12], nb[13], nb[14]);
    restQ := Mat4ToQuat(nb);
    FContactLocal[Idx] := QuatRotateV3(QuatConj(restQ), V3Sub(mRig, jRig));
    FContactValid[Idx] := True;
  end;

begin
  One(0, 'R_Foot', 'BoatClipseR');
  One(1, 'L_Foot', 'BoatClipseL');
  One(2, 'R_Hand', 'ArmContactR');
  One(3, 'L_Hand', 'ArmContactL');
  CacheContactSkin;          { binds resolved: bake nearest-vertex surface blend }
end;

procedure TTripoRiderScene.CacheContactSkin;
const
  KMAX = 8;                                   { nearest rest-mesh vertices to sample }
  MN: array[0..3] of string =
    ('BoatClipseR', 'BoatClipseL', 'ArmContactR', 'ArmContactL');
var
  idx, vi, k, cnt, worst: Integer;
  m: TVector3;
  mRig, d: TTripoVec3;
  dist2, sw: Single;
  bestD: array[0..KMAX-1] of Single;
  bestI: array[0..KMAX-1] of Integer;
begin
  for idx := 0 to 3 do
  begin
    FCSkinValid[idx] := False;
    SetLength(FCSkinVtx[idx], 0);
    SetLength(FCSkinIDW[idx], 0);
    if FRig = nil then Continue;
    if FRig.VertexCount <= 0 then Continue;
    if Length(FRig.Positions) < FRig.VertexCount then Continue;
    if Length(FRig.Joints) < FRig.VertexCount then Continue;
    if Length(FRig.Weights) < FRig.VertexCount then Continue;
    if not ContactNodeWorld(MN[idx], m) then Continue;  { marker bind pos, model frame }
    mRig := V3(m.X, m.Y, m.Z);
    FCSkinM[idx] := mRig;
    { one-time: find the KMAX nearest rest-mesh vertices to the marker. The rest
      mesh, the joint binds and the marker all live in the same model frame, so
      these are the boot/glove vertices whose skin weights drive the surface here. }
    cnt := 0;
    for k := 0 to KMAX-1 do begin bestD[k] := 1e30; bestI[k] := -1; end;
    for vi := 0 to FRig.VertexCount-1 do
    begin
      d := V3Sub(FRig.Positions[vi], mRig);
      dist2 := d.X*d.X + d.Y*d.Y + d.Z*d.Z;
      if cnt < KMAX then
      begin
        bestD[cnt] := dist2; bestI[cnt] := vi; Inc(cnt);
      end
      else
      begin
        worst := 0;
        for k := 1 to KMAX-1 do if bestD[k] > bestD[worst] then worst := k;
        if dist2 < bestD[worst] then begin bestD[worst] := dist2; bestI[worst] := vi; end;
      end;
    end;
    if cnt = 0 then Continue;
    { inverse-distance-squared blend so the nearest vertices dominate; weights are
      baked ONCE, so the sampled vertex set is fixed across the whole pedal cycle
      (no per-frame popping) — it is purely a better spatial estimate of the
      surface skin weights at the marker than any single vertex. }
    SetLength(FCSkinVtx[idx], cnt);
    SetLength(FCSkinIDW[idx], cnt);
    sw := 0;
    for k := 0 to cnt-1 do
    begin
      FCSkinVtx[idx][k] := bestI[k];
      FCSkinIDW[idx][k] := 1.0 / (bestD[k] + 1e-8);
      sw := sw + FCSkinIDW[idx][k];
    end;
    if sw <= 0 then Continue;
    for k := 0 to cnt-1 do FCSkinIDW[idx][k] := FCSkinIDW[idx][k] / sw;
    FCSkinValid[idx] := True;
  end;
end;

procedure TTripoRiderScene.ApplyLimbLengths(LegK, ArmK, ShoulderK, PelvisK, TorsoK: Single;
  HeightK: Single);

  { Direct scale coefficient: 1.0 = unchanged. Exactly 0 (unset/default in old
    files and empty edit cells) is treated as 1.0; clamp away non-positive values
    so a typo can never mirror a bone through its parent. }
  function NormK(const K: Single): Single;
  begin
    if Abs(K) < 1e-6 then Result := 1.0
    else if K < 0.01 then Result := 0.01
    else Result := K;
  end;

var k, j: Integer; factor: Single;
begin
  if (FRig = nil) or (not FLoaded) then Exit;
  CacheBones;
  LegK      := NormK(LegK);
  ArmK      := NormK(ArmK);
  ShoulderK := NormK(ShoulderK);
  PelvisK   := NormK(PelvisK);
  TorsoK    := NormK(TorsoK);
  HeightK   := NormK(HeightK);
  { Height scales the standing chain. Inseam extra (LegK) is thigh+shin.
    Boot mesh is not in this loop — FreezeBootSkin binds it to Foot only.
    Arms / clavicles stay at ArmK / ShoulderK (bar reach). }
  for k := 0 to High(FBoneJoint) do
  begin
    j := FBoneJoint[k];
    if j < 0 then Continue;
    if k < 4 then factor := LegK * HeightK                { thigh+shin: inseam }
    else if k < 8 then factor := ArmK                     { arms: bike reach }
    else if k < 10 then factor := ShoulderK               { shoulders: clavicle width }
    else if k < 12 then factor := PelvisK * HeightK       { hip offsets: stance }
    else if k <= 16 then factor := TorsoK * HeightK       { torso: spine / neck }
    else if k <= 24 then factor := LegK * HeightK         { thigh/calf twists: with inseam }
    else if k <= 32 then factor := ArmK                   { arm twist chain, including wrist parent }
    else factor := TorsoK * HeightK;                      { complete neck / head chain }
    { scale the bone offset in BindLocal — IK bone lengths follow it }
    FRig.BindLocal[j][12] := FBoneOrigLocalT[k].X * factor;
    FRig.BindLocal[j][13] := FBoneOrigLocalT[k].Y * factor;
    FRig.BindLocal[j][14] := FBoneOrigLocalT[k].Z * factor;
    { scale the CGE node offset — the GPU-skinned mesh stretches with it }
    if (j <= High(FJointNode)) and (FJointNode[j] <> nil) then
      FJointNode[j].Translation := FBoneOrigNodeT[k] * factor;
  end;
  FRig.RecomputeBindWorld(True);   { rebuild bind positions / IK lengths from new BindLocal;
                                     KEEP InvBind native so FRig.SkinMatrix reproduces the
                                     limb stretch exactly like the GPU (moved nodes + native
                                     inverse-bind) — otherwise the rest skin is identity and
                                     the mesh / contact ignore the length change }
  { Contact offsets use native IBM + unmoved marker nodes — independent of
    HeightK. Skip the O(verts) nearest-surface bake after the first time
    unless bulk/belly just rewrote rest verts. }
  if (not FContactValid[0]) or (not FContactValid[1])
     or (not FContactValid[2]) or (not FContactValid[3])
     or FBodyMorphed then
    CacheContactOffsets;
end;

function TTripoRiderScene.StableLegReach: Single;
begin
  if FBonesCached then Result := FOrigLegReach else Result := LegReach;
end;

function TTripoRiderScene.StableThighLen: Single;
begin
  CacheBones;
  Result := FOrigThighLen;
end;

function TTripoRiderScene.StableShinLen: Single;
begin
  CacheBones;
  Result := FOrigShinLen;
end;

function TTripoRiderScene.RestHeight: Single;
{ Visual metres after Tripo/Mixamo armature scale — not the 1 m file mesh.
  GPU rest stretch = BindWorld × NativeInvBind (same product as gskRest).
  Mixamo: IBM ≈ I, BindWorld has Armature.Scale → stretch 1.6–1.8.
  Fema: IBM already 1/armature → stretch ≈ 1, mesh bbox already metres. }
var
  MeshH, Stretch, L: Single;
  RestM: TTripoMat4;
  J, NJ, Pick: Integer;
begin
  if FNativeRestH > 0.15 then
    Exit(FNativeRestH);
  Result := 1.75;
  if not FLoaded then Exit;
  CacheShape;
  MeshH := FBoxMaxY - FBoxMinY;
  if MeshH < 1e-3 then
    MeshH := 1.0;
  Stretch := 1.0;
  if (FRig <> nil) and (FRig.JointCount > 0)
     and (Length(FRig.BindWorld) = FRig.JointCount)
     and (Length(FRig.NativeInvBind) = FRig.JointCount) then
  begin
    Pick := FRig.JointIndexByName('Pelvis');
    if Pick < 0 then Pick := FRig.JointIndexByName('Hips');
    if Pick < 0 then Pick := 0;
    Stretch := 0;
    NJ := FRig.JointCount;
    if NJ > 4 then NJ := 4;
    for J := 0 to NJ - 1 do
    begin
      RestM := Mat4Mul(FRig.BindWorld[J], FRig.NativeInvBind[J]);
      L := Sqrt(Sqr(RestM[0]) + Sqr(RestM[1]) + Sqr(RestM[2]));
      if L > Stretch then Stretch := L;
    end;
    if (Pick >= 0) and (Pick < FRig.JointCount) then
    begin
      RestM := Mat4Mul(FRig.BindWorld[Pick], FRig.NativeInvBind[Pick]);
      L := Sqrt(Sqr(RestM[0]) + Sqr(RestM[1]) + Sqr(RestM[2]));
      if L > Stretch then Stretch := L;
    end;
    if Stretch < 0.25 then
      Stretch := 1.0;
  end;
  Result := MeshH * Stretch;
  if Result < 0.3 then
    Result := 1.75;
  FNativeRestH := Result;
end;

procedure TTripoRiderScene.GrabPhysMat(Node: TX3DNode);
var n: Integer;
begin
  n := Length(FMatNodes);
  SetLength(FMatNodes, n + 1);
  SetLength(FMatOrigRough, n + 1);
  SetLength(FMatOrigMetal, n + 1);
  SetLength(FMatTexNode, n + 1);
  SetLength(FMatOrigImg, n + 1);
  FMatNodes[n] := TPhysicalMaterialNode(Node);
  FMatOrigRough[n] := TPhysicalMaterialNode(Node).Roughness;
  FMatOrigMetal[n] := TPhysicalMaterialNode(Node).Metallic;
  { The MR texture node itself — it stays attached to the material for its
    whole life (we only rewrite its PIXELS), so no ownership juggling. Raw
    SFNode field access is stable across CGE versions. }
  FMatTexNode[n] := TPhysicalMaterialNode(Node).FdMetallicRoughnessTexture.Value;
  FMatOrigImg[n] := nil;   { pristine pixel copy decoded lazily on first bake }
end;

procedure TTripoRiderScene.GrabHemBiasShape(Node: TX3DNode);
begin
  if not (Node is TShapeNode) then Exit;
  SetLength(FHemBiasBuf, Length(FHemBiasBuf) + 1);
  FHemBiasBuf[High(FHemBiasBuf)] := TShapeNode(Node);
end;

procedure TTripoRiderScene.ApplyJerseyHemDepthBias;
var
  I, J, E, NonHem: Integer;
  Scope: TX3DNode;
  Sh: TShapeNode;
  App: TAppearanceNode;
  Eff: TEffectNode;
  Part: TEffectPartNode;
  Attached: Boolean;
  Nm: string;
  Y0, Y1: Single;
  U0, U1: TSFFloat;
begin
  { Overlay after GPU skin. See shader comment: not toward-camera-origin. }
  if not FHemOverlayOn then Exit;
  SetLength(FHemBiasBuf, 0);
  Scope := RiderContentRoot;
  if Scope = nil then Exit;
  Scope.EnumerateNodes(TShapeNode, @GrabHemBiasShape, False);
  Attached := False;
  for I := 0 to High(FHemBiasBuf) do
  begin
    Sh := FHemBiasBuf[I];
    Nm := UpperCase(Sh.X3DName);
    if Pos('JERSEYHEM', Nm) <> 1 then Continue;
    App := Sh.Appearance;
    if App = nil then Continue;
    NonHem := 0;
    for J := 0 to High(FHemBiasBuf) do
      if (FHemBiasBuf[J].Appearance = App) and
         (Pos('JERSEYHEM', UpperCase(FHemBiasBuf[J].X3DName)) <> 1) then
        Inc(NonHem);
    if NonHem > 0 then Continue;
    for E := 0 to App.FdEffects.Count - 1 do
      if (App.FdEffects[E] is TEffectNode) and
         (TEffectNode(App.FdEffects[E]).X3DName = 'JerseyHemDepthBias') then
      begin
        App := nil;
        Break;
      end;
    if App = nil then Continue;
    Eff := TEffectNode.Create('JerseyHemDepthBias');
    Eff.Language := slGLSL;
    Y0 := 0;
    Y1 := 0;
    if not Sh.BBox.IsEmpty then
    begin
      Y0 := Sh.BBox.Min.Y;
      Y1 := Sh.BBox.Max.Y;
    end;
    { Whole-body bbox would flatten the taper — then push the full 8 mm. }
    if (Y1 - Y0 > 0.20) or (Y1 <= Y0) then
    begin
      Y0 := 0;
      Y1 := 0;
    end;
    U0 := TSFFloat.Create(Eff, True, 'uHemY0', Y0);
    U1 := TSFFloat.Create(Eff, True, 'uHemY1', Y1);
    Eff.AddCustomField(U0);
    Eff.AddCustomField(U1);
    Part := TEffectPartNode.Create;
    Part.ShaderType := stVertex;
    { Orange A/B: shader ON fills the band; remaining holes are a scalloped
      BOTTOM rim (same place 4 mm PushBot unhid). Taper radial XZ: 4.5 mm at
      flap min-Y, 1 mm at max-Y. eye.z += closer (GL eye z is negative). }
    Part.Contents :=
      'uniform float uHemY0;' + LineEnding +
      'uniform float uHemY1;' + LineEnding +
      'float hemT;' + LineEnding +
      'void PLUG_vertex_object_space(inout vec4 vertex, inout vec3 normal)' + LineEnding +
      '{' + LineEnding +
      '  hemT = 0.0;' + LineEnding +
      '  if (uHemY1 > uHemY0 + 1e-6)' + LineEnding +
      '    hemT = clamp((vertex.y - uHemY0) / (uHemY1 - uHemY0), 0.0, 1.0);' + LineEnding +
      '  vec2 xz = vertex.xz;' + LineEnding +
      '  float r = length(xz);' + LineEnding +
      '  float push = mix(0.0040, 0.0012, hemT);' + LineEnding +
      '  if (r > 1e-5)' + LineEnding +
      '    vertex.xz += xz * (push / r);' + LineEnding +
      '}' + LineEnding +
      'void PLUG_vertex_eye_space(inout vec4 vertex_eye, const in vec3 normal_eye)' + LineEnding +
      '{' + LineEnding +
      '  vertex_eye.z += mix(0.0080, 0.0025, hemT);' + LineEnding +
      '}';
    Eff.SetParts([Part]);
    if App.FdEffects.Count = 0 then
      App.SetEffects([Eff])
    else
      App.FdEffects.Add(Eff);
    Eff.Scene := FScene;
    App.ShadowCaster := False;
    Attached := True;
  end;
  SetLength(FHemBiasBuf, 0);
  if Attached and (FScene <> nil) then
    FScene.ChangedAll;
end;

procedure TTripoRiderScene.StripHemOverlayFrom(Node: TX3DNode);
var
  Sh: TShapeNode;
  App: TAppearanceNode;
  I: Integer;
begin
  if not (Node is TShapeNode) then Exit;
  Sh := TShapeNode(Node);
  if Pos('JERSEYHEM', UpperCase(Sh.X3DName)) <> 1 then Exit;
  App := Sh.Appearance;
  if App = nil then Exit;
  for I := App.FdEffects.Count - 1 downto 0 do
    if (App.FdEffects[I] is TEffectNode) and
       (TEffectNode(App.FdEffects[I]).X3DName = 'JerseyHemDepthBias') then
      App.FdEffects.Delete(I);
end;

procedure TTripoRiderScene.StripJerseyHemDepthBias;
var
  Scope: TX3DNode;
begin
  Scope := RiderContentRoot;
  if Scope = nil then Exit;
  Scope.EnumerateNodes(TShapeNode, @StripHemOverlayFrom, False);
  if FScene <> nil then
    FScene.ChangedAll;
end;

procedure TTripoRiderScene.SetHemOverlay(AOn: Boolean);
begin
  FHemOverlayOn := AOn;
  if AOn then
    ApplyJerseyHemDepthBias
  else
    StripJerseyHemDepthBias;
end;

function TTripoRiderScene.HemOverlayOn: Boolean;
begin
  Result := FHemOverlayOn;
end;

procedure TTripoRiderScene.RefreshHemOverlay;
begin
  if FHemOverlayOn then
    ApplyJerseyHemDepthBias
  else
    StripJerseyHemDepthBias;
end;

procedure TTripoRiderScene.CacheMaterials;
var
  Scope: TX3DNode;
begin
  if FMatCached then Exit;
  FMatCached := True;
  SetLength(FMatNodes, 0);
  SetLength(FMatOrigRough, 0);
  SetLength(FMatOrigMetal, 0);
  SetLength(FMatTexNode, 0);
  SetLength(FMatOrigImg, 0);
  FMatAppliedRough := 1.0;
  FMatAppliedMetal := 1.0;
  Scope := RiderContentRoot;
  if Scope = nil then Exit;
  { glTF PBR materials load as TPhysicalMaterialNode in CGE — grab rider-only
    materials (RiderVis after mount), so roughnessK/metallicK never retint the
    parametric bike under BikeFrame. Remember AUTHORED factors + texture pixels
    so setting coefficients back to 1 restores the model exactly. }
  Scope.EnumerateNodes(TPhysicalMaterialNode, @GrabPhysMat, false);
end;

procedure TTripoRiderScene.ApplyGlossCorrection(RoughK, MetalK: Single);
var
  lutG, lutB: array[0..255] of Byte;

  { Decode the authored MR texture once and keep a pristine TCastleImage copy
    so every bake starts from the original pixels (not cumulative). Must run
    BEFORE the first pixel rewrite. Returns nil when the material has no
    editable 2D texture image. }
  function PristineImage(idx: Integer): TCastleImage;
  var
    t2: TAbstractTexture2DNode;
    enc: TEncodedImage;
  begin
    Result := FMatOrigImg[idx];
    if Result <> nil then Exit;
    if not (FMatTexNode[idx] is TAbstractTexture2DNode) then Exit;
    t2 := TAbstractTexture2DNode(FMatTexNode[idx]);
    if not t2.IsTextureImage then Exit;   { forces decode of the embedded png/jpg }
    enc := t2.TextureImage;
    if not (enc is TCastleImage) then Exit;  { GPU-compressed — cannot edit pixels }
    Result := TCastleImage(enc).MakeCopy;
    FMatOrigImg[idx] := Result;
  end;

  { glTF metallicRoughness layout: G = roughness, B = metallic (R = unused/AO
    in combined ORM maps — left untouched). Fast byte walk with LUTs for the
    common uncompressed classes; generic per-pixel fallback otherwise. }
  procedure BakePixels(img: TCastleImage);
  var
    p: PByte;
    cnt, ps, xx, yy: Integer;
    c: TVector4;
  begin
    if (img is TRGBImage) or (img is TRGBAlphaImage) then
    begin
      if img is TRGBImage then ps := 3 else ps := 4;
      p := PByte(img.RawPixels);
      cnt := img.Width * img.Height * img.Depth;
      while cnt > 0 do
      begin
        p[1] := lutG[p[1]];   { G: roughness }
        p[2] := lutB[p[2]];   { B: metallic }
        Inc(p, ps);
        Dec(cnt);
      end;
    end
    else
      for yy := 0 to img.Height - 1 do
        for xx := 0 to img.Width - 1 do
        begin
          c := img.Colors[xx, yy, 0];
          c.Y := EnsureRange(c.Y * RoughK, 0.0, 1.0);
          c.Z := EnsureRange(c.Z * MetalK, 0.0, 1.0);
          img.Colors[xx, yy, 0] := c;
        end;
  end;

var
  i, v: Integer;
  neutral: Boolean;
  work: TCastleImage;
begin
  if not FLoaded then Exit;
  CacheMaterials;
  if Abs(RoughK) < 1e-6 then RoughK := 1.0;   { 0 = unset/default → unchanged }
  if Abs(MetalK) < 1e-6 then MetalK := 1.0;
  if RoughK < 0 then RoughK := 0;             { negative makes no physical sense }
  if MetalK < 0 then MetalK := 0;
  { skip redundant rebakes (e.g. repeated ApplyTripoBodyShape with same values) }
  if (Abs(RoughK - FMatAppliedRough) < 1e-5) and
     (Abs(MetalK - FMatAppliedMetal) < 1e-5) then Exit;
  FMatAppliedRough := RoughK;
  FMatAppliedMetal := MetalK;
  neutral := (Abs(RoughK - 1.0) < 1e-4) and (Abs(MetalK - 1.0) < 1e-4);

  if not neutral then
    for v := 0 to 255 do
    begin
      lutG[v] := EnsureRange(Round(v * RoughK), 0, 255);
      lutB[v] := EnsureRange(Round(v * MetalK), 0, 255);
    end;

  for i := 0 to High(FMatNodes) do
  begin
    if FMatNodes[i] = nil then Continue;

    if (PristineImage(i) <> nil) and
       ((FMatTexNode[i] is TImageTextureNode) or (FMatTexNode[i] is TPixelTextureNode)) then
    begin
      { texture-driven material: bake the correction into a fresh copy of the
        AUTHORED pixels and load it back into the SAME texture node. The node
        stays attached — only its image contents change, which CGE handles as
        a cheap texture update (no shader rebuild, no scene re-setup). }
      work := FMatOrigImg[i].MakeCopy;
      if not neutral then BakePixels(work);
      if FMatTexNode[i] is TImageTextureNode then
        TImageTextureNode(FMatTexNode[i]).LoadFromImage(work, true, '')
      else
      begin
        TPixelTextureNode(FMatTexNode[i]).FdImage.Value := work;  { SFImage owns it }
        TPixelTextureNode(FMatTexNode[i]).FdImage.Changed;
      end;
      { factors stay authored — the texture already carries the correction }
      FMatNodes[i].Roughness := FMatOrigRough[i];
      FMatNodes[i].Metallic  := FMatOrigMetal[i];
    end
    else
    begin
      { no (editable) MR texture → correct the plain factors }
      FMatNodes[i].Roughness := EnsureRange(FMatOrigRough[i] * RoughK, 0.0, 1.0);
      FMatNodes[i].Metallic  := EnsureRange(FMatOrigMetal[i] * MetalK, 0.0, 1.0);
    end;
  end;
end;

{ ── cloth dye: цвета одежды, запечка в baseColor-текстуру ─────────────────── }

function HairBlueFrac(R, G, B: Single): Single;
var
  Mx, Mn, Sat, H, D, T: Single;
begin
  { sRGB 0..1. Доля маркерного голубого. Кайма на Hair-меше смешана с
    персиком: B≈R, sat низкий — старый B≤R / (B−R)/0.85 отсекал её.
    0.72·R (не 0.80): деградированный затылок всё ещё B≳R, но JPEG
    чуть теплее. Персик (hue~322°) отсекается окном 120–290°. }
  if B < R * 0.72 then Exit(0.0);
  Mx := Max(R, Max(G, B));
  Mn := Min(R, Min(G, B));
  if Mx < 0.05 then Exit(0.0);
  if Mx < 1e-5 then Sat := 0.0 else Sat := (Mx - Mn) / Mx;
  D := Mx - Mn;
  if D > 1e-5 then
  begin
    if ((Mx - R) <= (Mx - G)) and ((Mx - R) <= (Mx - B)) then
      H := 60.0 * ((G - B) / D)
    else if (Mx - G) <= (Mx - B) then
      H := 60.0 * ((B - R) / D + 2.0)
    else
      H := 60.0 * ((R - G) / D + 4.0);
    if H < 0.0 then H := H + 360.0;
    { Лавандовая кайма затылка (253,191,232 hue~320, B/R≈0.92):
      старое окно 120–290 отсекало её. Персик и розовый джерси —
      B/R≲0.75, остаются за 0.80. }
    if (Sat > 0.05) and (B < R * 0.80) and ((H < 120.0) or (H > 290.0)) then
      Exit(0.0);
  end;
  T := (B - Min(R, G)) / 0.85;
  if T < 0.0 then T := 0.0;
  if T > 1.0 then T := 1.0;
  Result := T;
end;

function MarkerHairBlue(R, G, B: Single): Boolean;
begin
  Result := HairBlueFrac(R, G, B) >= 0.02;
end;

{ sRGB-байт → HairBlueFrac. Целочисленный отсев до float/hue.
  0.72 = 18/25; Mx<0.05 → byte < 13. }
function HairBlueFracByte(Rb, Gb, Bb: Byte): Single; inline;
begin
  if Integer(Bb) * 25 < Integer(Rb) * 18 then Exit(0.0);
  if (Rb < 13) and (Gb < 13) and (Bb < 13) then Exit(0.0);
  Result := HairBlueFrac(Rb * (1.0 / 255.0), Gb * (1.0 / 255.0),
    Bb * (1.0 / 255.0));
end;

{ RGB/RGBA packed. Colors[] = virtual GetColors → PixelPtr + 3×/255
  (castleimages_class_rgb.inc). На 2048² это основной тормоз покраски. }
function DyeRgbPtr(Img: TCastleImage; out P: PByte; out Ps: Integer): Boolean;
begin
  Result := False;
  P := nil;
  Ps := 0;
  if Img = nil then Exit;
  if Img is TRGBImage then
  begin
    P := PByte(Img.RawPixels);
    Ps := 3;
  end
  else if Img is TRGBAlphaImage then
  begin
    P := PByte(Img.RawPixels);
    Ps := 4;
  end
  else
    Exit;
  Result := P <> nil;
end;

function ClothDyeNativeColor(Slot: TClothSlot): TVector3;
begin
  { Родной цвет ткани в исходной текстуре — ключ hue-match'а (как uDyeKey
    в GLSL-варианте AvatarViewFrame). Логотипы другого оттенка не красятся. }
  case Slot of
    csJersey: Result := Vector3(0.95, 0.45, 0.72);
    csShorts: Result := Vector3(0.40, 0.75, 0.95);
    csSocks:  Result := Vector3(0.96, 0.85, 0.15);
    csBoots:  Result := Vector3(0.75, 0.52, 0.95);
    csGloves: Result := Vector3(0.35, 0.82, 0.30);
    { кожа модели: sRGB ~(200,125,100), hue ~11°. Ключ ближе к красному
      краю кожи, чтобы жёлтый (носки, hue ~46°) не попадал в окно ±32° }
    csSkin:   Result := Vector3(0.58, 0.21, 0.13);
    { волосы в исходнике выкрашены маркерным голубым (hue ~215-222°, окно
      AlbedoKindOf 185-240), чтобы split выделял их в отдельный меш Hair }
  else
    Result := Vector3(0.10, 0.35, 0.95);   { csHair }
  end;
end;

procedure TTripoRiderScene.GrabDyePhysMat(Node: TX3DNode);
var
  T: TX3DNode;
  I: Integer;
begin
  { baseColor-текстура PBR-материала. Один и тот же texture node может быть
    расшарен между материалами — собираем distinct, чтобы не запечь дважды. }
  T := TPhysicalMaterialNode(Node).FdBaseTexture.Value;
  if T = nil then Exit;
  for I := 0 to High(FDyeTexNode) do
    if FDyeTexNode[I] = T then Exit;
  SetLength(FDyeTexNode, Length(FDyeTexNode) + 1);
  SetLength(FDyeOrigImg, Length(FDyeOrigImg) + 1);
  FDyeTexNode[High(FDyeTexNode)] := T;
  FDyeOrigImg[High(FDyeOrigImg)] := nil;   { pristine-копия декодируется лениво }
end;

procedure TTripoRiderScene.CacheDyeTextures;
var
  Scope: TX3DNode;
begin
  if FDyeTexCached then Exit;
  FDyeTexCached := True;
  SetLength(FDyeTexNode, 0);
  SetLength(FDyeOrigImg, 0);
  Scope := RiderContentRoot;
  if Scope = nil then Exit;
  Scope.EnumerateNodes(TPhysicalMaterialNode, @GrabDyePhysMat, False);
end;

{ Геометрический кэш покраски: UV-маски и тон кожи зависят только от
  содержимого glb (геометрия/текстуры), НЕ от выбранных цветов. Перекраска
  перезагружает райдера из того же файла — кэш снимает повторные ~9 с
  растеризации масок и ~10 с скана тона кожи. Одна запись (последний файл). }
const
  { Bump when mask dilation / slot chroma rules change so the in-process
    UV-mask cache does not keep stale bitmaps. }
  DyeMaskCacheGen = 66;

type
  TDyeGeomCacheRec = record
    Valid: Boolean;
    Gen: Integer;
    Path: string;
    FileTime: TDateTime;
    MaskW, MaskH: array of Integer;
    MaskJerseyHem: array of TBytes;
    MaskAll: array of TBytes;
    MaskSlot: array of array of TBytes;
    MaskAny: Boolean;
    MaskHasGlobal: set of TClothSlot;
    SkinTone: TVector3;
    SkinToneOk: Boolean;
  end;

var
  GDyeGeomCache: TDyeGeomCacheRec;
  { Кэш теперь читается/пишется и из фонового dye-воркера (байкфит) —
    короткий лок на копирование/публикацию разделяемых ссылок. }
  GDyeGeomLock: TRTLCriticalSection;

function DyeGeomCacheMatch(const APath: string): Boolean;
var
  FT: TDateTime;
begin
  Result := False;
  if (not GDyeGeomCache.Valid) or (APath = '') then Exit;
  if GDyeGeomCache.Gen <> DyeMaskCacheGen then Exit;
  if not SameText(GDyeGeomCache.Path, APath) then Exit;
  { инвалидируемся по mtime: редактор мог пересохранить glb под тем же путём }
  if not FileAge(APath, FT) then Exit;
  Result := Abs(GDyeGeomCache.FileTime - FT) < 1.0 / 86400.0;  { ±1 с }
end;

{ Готовит запись кэша под APath (сбрасывает прошлую); False — файл
  недоступен, кэш не трогаем. Поля данных заполняет caller. }
function DyeGeomCacheStore(const APath: string): Boolean;
var
  FT: TDateTime;
begin
  Result := False;
  if (APath = '') or (not FileAge(APath, FT)) then Exit;
  GDyeGeomCache.Valid := False;
  GDyeGeomCache.Gen := DyeMaskCacheGen;
  GDyeGeomCache.Path := APath;
  GDyeGeomCache.FileTime := FT;
  GDyeGeomCache.SkinToneOk := False;
  GDyeGeomCache.Valid := True;
  Result := True;
end;

procedure TTripoRiderScene.ResetDyeCache;
var
  I: Integer;
begin
  FDyeTexCached := False;
  FDyeBaked := False;
  SetLength(FDyeMaterial, 0);
  FDyeJerseyReferenceLum := 0;
  FDyeJerseyMaxLum := 0;
  for I := 0 to High(FDyeOrigImg) do
    FreeAndNil(FDyeOrigImg[I]);
  SetLength(FDyeTexNode, 0);
  SetLength(FDyeOrigImg, 0);
  FDyeMaskOk := False;
  FDyeMaskAny := False;
  FDyeMaskHasGlobal := [];
  FSkinToneOk := False;
  SetLength(FDyeMaskW, 0);
  SetLength(FDyeMaskH, 0);
  SetLength(FDyeMaskJerseyHem, 0);
  SetLength(FDyeMaskAll, 0);
  SetLength(FDyeMaskSlot, 0);
  SetLength(FDyePartNames, 0);
  ClearShaderDyeFields;
end;

function ClothMaterialLuminance(const C: TVector3): Single; inline;
begin
  Result := 0.2126 * C.X + 0.7152 * C.Y + 0.0722 * C.Z;
end;

function TTripoRiderScene.ShaderClothDyeColor(Slot: TClothSlot): TVector3;
var
  Peak, Denominator: Single;
begin
  Result := FDyeColor[Slot];
  if (FCorrectives = nil) or (Slot <> csJersey) or
     (FDyeJerseyReferenceLum <= 0) then Exit;
  { Multiply source luminance by this scale. Keep the authored fabric ratios
    relative to the main jersey. If a bright target exceeds gamut, scale
    the entire palette together, rather than clipping lighter fabrics flat. }
  Peak := Max(Result.X, Max(Result.Y, Result.Z));
  Denominator := Max(FDyeJerseyReferenceLum, Peak * FDyeJerseyMaxLum);
  Result := Result * (1.0 / Max(Denominator, 0.00001));
end;

procedure TTripoRiderScene.ApplyMaterialClothDye;
var
  K, I, J: Integer;
  Sh: TShapeNode;
  Mat: TPhysicalMaterialNode;
  Slot: TClothSlot;
  Name: string;
  Lum: Single;
  Target: TVector3;
begin
  if (FCorrectives = nil) or (FScene = nil) then Exit;
  FScene.BeginChangesSchedule;
  try
    for K := 0 to High(FSkinList) do
      for I := 0 to FSkinList[K].FdShapes.Count - 1 do
      begin
        if not (FSkinList[K].FdShapes[I] is TShapeNode) then Continue;
        Sh := TShapeNode(FSkinList[K].FdShapes[I]);
        if not SlotOfLiveShape(Sh, Slot) or
           not (Slot in [csJersey, csShorts, csSocks, csBoots, csGloves]) or
           (Sh.Appearance = nil) or
           not (Sh.Appearance.Material is TPhysicalMaterialNode) then Continue;
        Mat := TPhysicalMaterialNode(Sh.Appearance.Material);
        J := 0;
        while (J < Length(FDyeMaterial)) and (FDyeMaterial[J].Node <> Mat) do Inc(J);
        if J = Length(FDyeMaterial) then
        begin
          SetLength(FDyeMaterial, J + 1);
          FDyeMaterial[J].Node := Mat;
          FDyeMaterial[J].Color := Mat.BaseColor;
          FDyeMaterial[J].Slot := Slot;
        end;
      end;
    { Capture every pristine factor before recoloring any shared material. }
    FDyeJerseyReferenceLum := 0;
    FDyeJerseyMaxLum := 0;
    for J := 0 to High(FDyeMaterial) do
      if FDyeMaterial[J].Slot = csJersey then
      begin
        Lum := ClothMaterialLuminance(FDyeMaterial[J].Color);
        FDyeJerseyMaxLum := Max(FDyeJerseyMaxLum, Lum);
        Name := LowerCase(FDyeMaterial[J].Node.X3DName);
        if (Pos('jersey', Name) > 0) and (Pos('side', Name) = 0) then
          FDyeJerseyReferenceLum := Max(FDyeJerseyReferenceLum, Lum);
      end;
    if FDyeJerseyReferenceLum <= 0 then
      FDyeJerseyReferenceLum := Max(FDyeJerseyMaxLum, 0.00001);
    for J := 0 to High(FDyeMaterial) do
    begin
      Slot := FDyeMaterial[J].Slot;
      Target := FDyeMaterial[J].Color;
      if (FDyeMode = cdmTexture) and FDyeActive[Slot] then
      begin
        Target := ShaderClothDyeColor(Slot);
        if Slot = csJersey then
          Target := Target * ClothMaterialLuminance(FDyeMaterial[J].Color);
      end;
      FDyeMaterial[J].Node.BaseColor := Target;
    end;
  finally FScene.EndChangesSchedule end;
end;

{ extras.avatarPartNames: порядок = индекс примитива меша (см. '_PrimitiveN'
  в имени shape'а). Файл только читаем. }
procedure TTripoRiderScene.ReadDyePartNames(const AFileName: string);
var
  B: TBytes;
  Js, Path: string;
  BinOfs, BinLen, I: Integer;
  Data: TJSONData;
  Root, Ex: TJSONObject;
  A: TJSONArray;
begin
  SetLength(FDyePartNames, 0);
  Path := ResolveGlbFilesystemPath(AFileName);
  if (Path = '') or (not FileExists(Path)) then Exit;
  B := LoadFileBytes(Path);
  if not ExtractGltfJson(B, Js, BinOfs, BinLen) then Exit;
  Data := nil;
  try
    Data := GetJSON(Js);
  except
    Data := nil;
  end;
  if Data = nil then Exit;
  try
    if not (Data is TJSONObject) then Exit;
    Root := TJSONObject(Data);
    Ex := ObjOf(Root, 'extras');
    if Ex = nil then Exit;
    A := ArrOf(Ex, 'avatarPartNames');
    if A = nil then Exit;
    SetLength(FDyePartNames, A.Count);
    for I := 0 to A.Count - 1 do
      FDyePartNames[I] := A.Strings[I];
    StartupLog(Format('[dye] avatarPartNames=%d from %s',
      [Length(FDyePartNames), ExtractFileName(Path)]));
  finally
    Data.Free;
  end;
end;

{ Слот одежды по имени shape'а (части split-модели называются Jersey/Shorts/…). }
function ClothSlotOfName(const Nm: string; out Slot: TClothSlot): Boolean;
var
  U: string;
begin
  Result := True;
  U := LowerCase(Nm);
  if (Pos('jersey', U) > 0) or (Pos('part_sleeves', U) > 0) then Slot := csJersey
  else if Pos('short', U) > 0 then Slot := csShorts
  else if Pos('sock', U) > 0 then Slot := csSocks
  else if (Pos('boot', U) > 0) or (Pos('cycling shoe', U) > 0) then Slot := csBoots
  else if Pos('glove', U) > 0 then Slot := csGloves
  else if Pos('hair', U) > 0 then Slot := csHair
  else if (Pos('face', U) > 0) or (Pos('finger', U) > 0)
       or (Pos('leg', U) > 0) or (Pos('head', U) > 0)
       or (Pos('arm', U) > 0)
       or (Pos('skin', U) > 0) then Slot := csSkin
  else Result := False;
end;

procedure TTripoRiderScene.GrabDyeShape(Node: TX3DNode);
begin
  if Node is TShapeNode then
  begin
    SetLength(FDyeShapeBuf, Length(FDyeShapeBuf) + 1);
    FDyeShapeBuf[High(FDyeShapeBuf)] := TShapeNode(Node);
  end;
end;

procedure TTripoRiderScene.BuildDyeMasks;
var
  Scope: TX3DNode;
  I, K, Ti, Oth, J: Integer;
  Sh: TShapeNode;
  NTex: Integer;
  Slot: TClothSlot;
  HasSlot: Boolean;
  HairFaceSign: Single;
  HairHeadZMin, HairHeadZMax, HairNeckY: Single;
  DyeNFace, DyeNScalp, DyeNEye: Integer;
  DyeSamp: string;
  JerseyCore: array of TBytes;
  JerseyVertices: TStringList;
  JerseyEdge: array of TBytes;
  JerseyLinear: array[0..255] of Single;
  EdgePixel: Integer;
  GatherJerseyVertices: Boolean;
  JerseyMinY, JerseyMaxY: Single;
  HairCore: array of TBytes;
  TexN, MatN: TX3DNode;
  T2: TAbstractTexture2DNode;
  Enc: TEncodedImage;
  W, H: Integer;
  Core: array of TBytes;
  FaceMask: array of TBytes;
  EyeMask: array of TBytes;
  HairPix: PByte;
  HairPixPs: Integer;

  procedure MaskSet(var M: TBytes; Idx: Integer); inline;
  begin
    M[Idx shr 3] := M[Idx shr 3] or (1 shl (Idx and 7));
  end;

  function MaskGet(const M: TBytes; Idx: Integer): Boolean; inline;
  begin
    Result := (Length(M) > 0) and (Idx >= 0) and ((Idx shr 3) < Length(M)) and
      ((M[Idx shr 3] and (1 shl (Idx and 7))) <> 0);
  end;

  procedure MaskOr(var Dst: TBytes; const Src: TBytes);
  var
    I2: Integer;
  begin
    if Length(Src) = 0 then Exit;
    if Length(Dst) = 0 then
    begin
      Dst := Copy(Src);
      Exit;
    end;
    for I2 := 0 to Min(High(Dst), High(Src)) do
      Dst[I2] := Dst[I2] or Src[I2];
  end;

  { Растеризация одного UV-треугольника в битовую маску W*H.
    Декодированная CGE картинка уже в render-ориентации: строка 0 = низ =
    v 0 (загрузчик флипает текстуру, UV не трогает), поэтому y = V*(H-1). }
  procedure RasterTri(var M: TBytes; const A, B, C: TVector2; TexelCoverage: Boolean = False);
  var
    Ax, Ay, Bx, By, Cx, Cy, Den, InvDen, W0, W1, W2, E0, E1, E2: Single;
    X0, X1, Y0, Y1, Xx, Yy: Integer;
  begin
    Ax := A.X * (W - 1); Ay := A.Y * (H - 1);
    Bx := B.X * (W - 1); By := B.Y * (H - 1);
    Cx := C.X * (W - 1); Cy := C.Y * (H - 1);
    X0 := Max(0, Floor(Min(Ax, Min(Bx, Cx))));
    X1 := Min(W - 1, Ceil(Max(Ax, Max(Bx, Cx))));
    Y0 := Max(0, Floor(Min(Ay, Min(By, Cy))));
    Y1 := Min(H - 1, Ceil(Max(Ay, Max(By, Cy))));
    Den := (By - Cy) * (Ax - Cx) + (Cx - Bx) * (Ay - Cy);
    if Abs(Den) < 1e-12 then Exit;
    InvDen := 1.0 / Den;
    E0 := 0.05; E1 := 0.05; E2 := 0.05;
    if TexelCoverage then
    begin
      { A texel covers a square. Centre-only tests lose subpixel-width UV
        triangles entirely, so later padding cannot recover them. }
      E0 := Max(E0, 0.5 * (Abs(By - Cy) + Abs(Cx - Bx)) * Abs(InvDen));
      E1 := Max(E1, 0.5 * (Abs(Cy - Ay) + Abs(Ax - Cx)) * Abs(InvDen));
      E2 := Max(E2, 0.5 * (Abs(Ay - By) + Abs(Bx - Ax)) * Abs(InvDen));
    end;
    for Yy := Y0 to Y1 do
      for Xx := X0 to X1 do
      begin
        W0 := ((By - Cy) * (Xx - Cx) + (Cx - Bx) * (Yy - Cy)) * InvDen;
        W1 := ((Cy - Ay) * (Xx - Cx) + (Ax - Cx) * (Yy - Cy)) * InvDen;
        W2 := 1.0 - W0 - W1;
        if (W0 >= -E0) and (W1 >= -E1) and (W2 >= -E2) then
          MaskSet(M, Yy * W + Xx);
      end;
  end;

  procedure StampUV(var M: TBytes; const T: TVector2; Rad: Integer);
  var
    Cx, Cy, Xx, Yy, X0, X1, Y0, Y1, R2: Integer;
  begin
    Cx := Round(T.X * (W - 1));
    Cy := Round(T.Y * (H - 1));
    R2 := Rad * Rad;
    X0 := Max(0, Cx - Rad);
    X1 := Min(W - 1, Cx + Rad);
    Y0 := Max(0, Cy - Rad);
    Y1 := Min(H - 1, Cy + Rad);
    for Yy := Y0 to Y1 do
      for Xx := X0 to X1 do
        if Sqr(Xx - Cx) + Sqr(Yy - Cy) <= R2 then
          MaskSet(M, Yy * W + Xx);
  end;

  procedure RasterHair(const A, B, C: TVector2);
  begin
    RasterTri(FDyeMaskSlot[Ti][Ord(csHair)], A, B, C);
    StampUV(FDyeMaskSlot[Ti][Ord(csHair)], A, 4);
    StampUV(FDyeMaskSlot[Ti][Ord(csHair)], B, 4);
    StampUV(FDyeMaskSlot[Ti][Ord(csHair)], C, 4);
  end;

  procedure RasterFace(const A, B, C: TVector2);
  begin
    RasterTri(FDyeMaskSlot[Ti][Ord(csSkin)], A, B, C);
    if (Ti >= 0) and (Ti <= High(FaceMask)) and (Length(FaceMask[Ti]) > 0) then
    begin
      RasterTri(FaceMask[Ti], A, B, C);
      StampUV(FaceMask[Ti], A, 1);
      StampUV(FaceMask[Ti], B, 1);
      StampUV(FaceMask[Ti], C, 1);
    end;
  end;

  procedure RasterEye(const A, B, C: TVector2);
  begin
    RasterFace(A, B, C);
    if (Ti >= 0) and (Ti <= High(EyeMask)) and (Length(EyeMask[Ti]) > 0) then
    begin
      RasterTri(EyeMask[Ti], A, B, C);
      StampUV(EyeMask[Ti], A, 5);
      StampUV(EyeMask[Ti], B, 5);
      StampUV(EyeMask[Ti], C, 5);
    end;
  end;

  function UVHairBlue(const T: TVector2): Boolean;
  var
    Xx, Yy, Off: Integer;
    Rb, Gb, Bb: Byte;
  begin
    Result := False;
    if HairPix = nil then Exit;
    Xx := Round(T.X * (W - 1));
    Yy := Round(T.Y * (H - 1));
    if (Xx < 0) or (Yy < 0) or (Xx >= W) or (Yy >= H) then Exit;
    Off := (Yy * W + Xx) * HairPixPs;
    Rb := HairPix[Off];
    Gb := HairPix[Off + 1];
    Bb := HairPix[Off + 2];
    Result := (Max(Rb, Max(Gb, Bb)) >= 57) and
      (HairBlueFracByte(Rb, Gb, Bb) >= 0.08);
  end;

  { 1-тексельная дилатация (3x3), чтобы швы UV и mip-блик не оставляли
    непрокрашенных каёмок. }
  procedure Dilate(var M: TBytes);
  var
    Src: TBytes;
    Xx, Yy, Dx, Dy, Nx, Ny, Pix, Bi, Bit, Lim, B: Integer;
  begin
    Src := Copy(M);
    Lim := W * H;
    for Bi := 0 to High(Src) do
    begin
      B := Src[Bi];
      if B = 0 then Continue;
      for Bit := 0 to 7 do
        if (B and (1 shl Bit)) <> 0 then
        begin
          Pix := (Bi shl 3) + Bit;
          if Pix >= Lim then Exit;
          Yy := Pix div W;
          Xx := Pix - Yy * W;
          for Dy := -1 to 1 do
          begin
            Ny := Yy + Dy;
            if (Ny < 0) or (Ny >= H) then Continue;
            for Dx := -1 to 1 do
            begin
              Nx := Xx + Dx;
              if (Nx < 0) or (Nx >= W) then Continue;
              MaskSet(M, Ny * W + Nx);
            end;
          end;
        end;
    end;
  end;

  { Заливка связной голубой компоненты от уже растеризованной маски Hair.
    Непрокрашенный затылок — соседний голубой тексель вне треугольника.
    DilateHairBlue×8 был подмножеством этой заливки (тот же 8-connected
    HairBlueFrac≥0.004) и сканировал весь 2048² через Colors[]. }
  procedure FloodHairBlue(var M: TBytes; Img: TCastleImage; const Block: TBytes);
  var
    Q: array of Integer;
    Head, Tail, Idx, Nidx, Xx, Yy, Nx, Ny, Dx, Dy, Off, Lim, Bi, Bit, B: Integer;
    P: PByte;
    Ps: Integer;
    HaveBlock: Boolean;
    Rb, Gb, Bb: Byte;
  begin
    if not DyeRgbPtr(Img, P, Ps) then Exit;
    if (Img.Width <> W) or (Img.Height <> H) then Exit;
    if Length(M) = 0 then Exit;
    Lim := W * H;
    HaveBlock := Length(Block) > 0;
    SetLength(Q, Lim);
    Head := 0;
    Tail := 0;
    for Bi := 0 to High(M) do
    begin
      B := M[Bi];
      if B = 0 then Continue;
      for Bit := 0 to 7 do
        if (B and (1 shl Bit)) <> 0 then
        begin
          Idx := (Bi shl 3) + Bit;
          if Idx >= Lim then Break;
          Q[Tail] := Idx;
          Inc(Tail);
        end;
    end;
    while Head < Tail do
    begin
      Idx := Q[Head];
      Inc(Head);
      Yy := Idx div W;
      Xx := Idx - Yy * W;
      for Dy := -1 to 1 do
        for Dx := -1 to 1 do
        begin
          if (Dx = 0) and (Dy = 0) then Continue;
          Nx := Xx + Dx;
          Ny := Yy + Dy;
          if (Nx < 0) or (Ny < 0) or (Nx >= W) or (Ny >= H) then Continue;
          Nidx := Ny * W + Nx;
          if (M[Nidx shr 3] and (1 shl (Nidx and 7))) <> 0 then Continue;
          if HaveBlock and
             ((Block[Nidx shr 3] and (1 shl (Nidx and 7))) <> 0) then
            Continue;
          Off := Nidx * Ps;
          Rb := P[Off];
          Gb := P[Off + 1];
          Bb := P[Off + 2];
          if HairBlueFracByte(Rb, Gb, Bb) < 0.004 then Continue;
          MaskSet(M, Nidx);
          Q[Tail] := Nidx;
          Inc(Tail);
        end;
    end;
  end;

  { Дилатация не должна захватывать UV-ядро соседнего слота: иначе лого
    джерси (голубое, рядом на атласе) красится как шорты. }
  procedure SubtractCore(var M: TBytes; const Core: TBytes);
  var
    I2: Integer;
  begin
    if (Length(M) = 0) or (Length(Core) = 0) then Exit;
    for I2 := 0 to Min(High(M), High(Core)) do
      M[I2] := M[I2] and not Core[I2];
  end;

  { Имя части: extras.avatarPartNames[prim], иначе Appearance.X3DName
    (CGE кладёт glTF material.name на Appearance, не на PhysicalMaterial). }
  function DyePartLabel(Sh: TShapeNode; MatN: TX3DNode): string;
  var
    U, Dig: string;
    P, Pi: Integer;
  begin
    Result := '';
    if Sh = nil then Exit;
    U := UpperCase(Sh.X3DName);
    P := Pos('_PRIMITIVE', U);
    if P > 0 then
    begin
      Dig := Copy(U, P + Length('_PRIMITIVE'), 8);
      while (Length(Dig) > 0) and not (Dig[Length(Dig)] in ['0'..'9']) do
        Delete(Dig, Length(Dig), 1);
      Pi := StrToIntDef(Dig, -1);
      if (Pi >= 0) and (Pi < Length(FDyePartNames)) then
        Exit(FDyePartNames[Pi]);
    end;
    if (Sh.Appearance <> nil) and (Sh.Appearance.X3DName <> '') then
      Exit(Sh.Appearance.X3DName);
    if (MatN <> nil) and (MatN.X3DName <> '') then
      Exit(MatN.X3DName);
    Result := Sh.X3DName;
  end;

  { Слот одежды для shape'а: extras.avatarPartNames / Part_Jersey / имя shape'а. }
  function ShapeSlot(Sh: TShapeNode; MatN: TX3DNode; out Slot: TClothSlot): Boolean;
  begin
    Result := ClothSlotOfName(DyePartLabel(Sh, MatN), Slot);
  end;

  function NameIsFace(const Nm: string): Boolean;
  begin
    Result := Pos('FACE', UpperCase(Nm)) > 0;
  end;

  function NameIsHead(const Nm: string): Boolean;
  var
    U: string;
  begin
    U := UpperCase(Nm);
    Result := (Pos('HEAD', U) > 0) and (Pos('FACE', U) = 0);
  end;

  function NameIsFinger(const Nm: string): Boolean;
  begin
    Result := Pos('FINGER', UpperCase(Nm)) > 0;
  end;

  function ShapeIsFace(Sh: TShapeNode; MatN: TX3DNode): Boolean;
  begin
    Result := NameIsFace(DyePartLabel(Sh, MatN));
  end;

  function ShapeIsHead(Sh: TShapeNode; MatN: TX3DNode): Boolean;
  begin
    Result := NameIsHead(DyePartLabel(Sh, MatN));
  end;

  function ShapeIsFinger(Sh: TShapeNode; MatN: TX3DNode): Boolean;
  begin
    Result := NameIsFinger(DyePartLabel(Sh, MatN));
  end;

  function VertInFace(const P: TVector3): Boolean;
  begin
    { Тот же овал, что split mpFace. Mixamo лицо +Z: HairFaceSign * Z ≥ 0.
      Trichion Yn≈0.97, menton Yn≈0.87, глаза Yn≈0.93 (доля роста).
      Не чёлка, не уши. Цвет не смотрим. }
    Result := (HairFaceSign * P.Z >= 0)
      and (P.Y >= 0.870)
      and (P.Y <= 0.968)
      and (Sqr(P.X / 0.055) + Sqr((P.Y - 0.920) / 0.048) <= 1.0);
  end;

  function VertInEye(const P: TVector3): Boolean;
  begin
    { Только глазница, не виски. |X|≲0.052 захватывало кайму причёски. }
    Result := (P.Y >= 0.924) and (P.Y <= 0.942)
      and (Abs(P.X) >= 0.012) and (Abs(P.X) <= 0.036)
      and (HairFaceSign * P.Z >= 0.0);
  end;

  function TriInFace(const A, B, C: TVector3): Boolean;
  begin
    Result := VertInFace(Vector3(
      (A.X + B.X + C.X) / 3.0,
      (A.Y + B.Y + C.Y) / 3.0,
      (A.Z + B.Z + C.Z) / 3.0));
  end;

  function TriInEye(const A, B, C: TVector3): Boolean;
  begin
    { any-vertex: маленький глазной трис не должен выпасть из FaceMask. }
    Result := VertInEye(A) or VertInEye(B) or VertInEye(C) or
      VertInEye(Vector3(
        (A.X + B.X + C.X) / 3.0,
        (A.Y + B.Y + C.Y) / 3.0,
        (A.Z + B.Z + C.Z) / 3.0));
  end;

  procedure ComputeHairFaceSign;
  var
    Si, J2: Integer;
    Sh2: TShapeNode;
    C3: TX3DNode;
    Pts2: TVector3List;
    P2: TVector3;
    FaceAbs: Single;
  begin
    { Mixamo лицо +Z. max|Z| на голове = затылок (причёска торчит дальше
      носа) — из‑за этого FaceSign становился −1 и овал садился сзади. }
    HairFaceSign := 1;
    HairHeadZMin := 1e9;
    HairHeadZMax := -1e9;
    FaceAbs := -1e9;
    for Si := 0 to High(FDyeShapeBuf) do
    begin
      Sh2 := FDyeShapeBuf[Si];
      if Sh2 = nil then Continue;
      if Sh2.Geometry = nil then Continue;
      if not (Sh2.Geometry is TAbstractComposedGeometryNode) then Continue;
      C3 := TAbstractComposedGeometryNode(Sh2.Geometry).FdCoord.Value;
      if not (C3 is TCoordinateNode) then Continue;
      Pts2 := TCoordinateNode(C3).FdPoint.Items;
      for J2 := 0 to Pts2.Count - 1 do
      begin
        P2 := Pts2.L[J2];
        if (P2.Y > 0.78) and (Abs(P2.X) < 0.08) then
        begin
          if P2.Z < HairHeadZMin then HairHeadZMin := P2.Z;
          if P2.Z > HairHeadZMax then HairHeadZMax := P2.Z;
        end;
        { Нос/глаза Yn 0.90–0.95, не подбородок 0.83–0.87. }
        if (P2.Y > 0.90) and (P2.Y < 0.95) and (Abs(P2.X) < 0.025) then
          if P2.Z > FaceAbs then
            FaceAbs := P2.Z;
      end;
    end;
    if HairHeadZMin > 1e8 then
    begin
      HairHeadZMin := -0.10;
      HairHeadZMax := 0.05;
    end;
    if (FaceAbs > -1e8) and (FaceAbs < -0.01) then
      HairFaceSign := -1;
    StartupLog(Format('[dye] headZ [%.3f %.3f] faceSign=%.0f noseZ=%.3f',
      [HairHeadZMin, HairHeadZMax, HairFaceSign, FaceAbs]));
  end;

  { Шея = наименьший Y меша Head (после split). Волосы только выше этой
    линии — лого на груди/спине, даже голубое, в Hair не попадает. }
  procedure ComputeHairNeckY;
  var
    Si, J2: Integer;
    Sh2: TShapeNode;
    C3, MatN2: TX3DNode;
    Pts2: TVector3List;
    P2: TVector3;
  begin
    HairNeckY := 1e9;
    for Si := 0 to High(FDyeShapeBuf) do
    begin
      Sh2 := FDyeShapeBuf[Si];
      if Sh2 = nil then Continue;
      if Sh2.Appearance <> nil then
        MatN2 := Sh2.Appearance.FdMaterial.Value
      else
        MatN2 := nil;
      if not ShapeIsHead(Sh2, MatN2) then Continue;
      if Sh2.Geometry = nil then Continue;
      if not (Sh2.Geometry is TAbstractComposedGeometryNode) then Continue;
      C3 := TAbstractComposedGeometryNode(Sh2.Geometry).FdCoord.Value;
      if not (C3 is TCoordinateNode) then Continue;
      Pts2 := TCoordinateNode(C3).FdPoint.Items;
      for J2 := 0 to Pts2.Count - 1 do
      begin
        P2 := Pts2.L[J2];
        if P2.Y < HairNeckY then
          HairNeckY := P2.Y;
      end;
    end;
    if HairNeckY > 1e8 then
      HairNeckY := 0.78; { нет части Head: ниже подбородка, выше лого }
    StartupLog(Format('[dye] hairNeckY=%.3f', [HairNeckY]));
  end;

  function IsGloveCuff(const A, B, C: TVector3): Boolean;
  var
    Cx, Cy: Single;
  begin
    { Манжета на меше Arms/Jersey. Кожу не красим — только маска перчаток. }
    Cx := (A.X + B.X + C.X) / 3.0;
    Cy := (A.Y + B.Y + C.Y) / 3.0;
    Result := (Abs(Cx) >= 0.28) and (Cy >= 0.70) and (Cy <= 0.90);
  end;

  function JerseyVertexKey(const P: TVector3): string;
  begin
    { Split primitives duplicate vertices. Compare rest positions, including
      duplicates across UV seams; never depend on the shared accessor range. }
    Result := IntToStr(Round(P.X * 1000000)) + ',' +
      IntToStr(Round(P.Y * 1000000)) + ',' + IntToStr(Round(P.Z * 1000000));
  end;

  procedure RasterShape(Sh: TShapeNode; HasSlot: Boolean; Slot: TClothSlot;
    FacePart, HeadPart, FingerPart: Boolean);
  var
    G2, TC, CC: TX3DNode;
    I0, I1, I2, NT, T: Integer;
    UV: TVector2List;
    Pos: TVector3List;
    HeadSplit: Boolean;

    procedure EmitTri(A0, A1, A2: Integer);
    var
      Eye, PosOk, WantHair: Boolean;
    begin
      if (A0 < 0) or (A1 < 0) or (A2 < 0) or
         (A0 >= UV.Count) or (A1 >= UV.Count) or (A2 >= UV.Count) then Exit;
      PosOk := (Pos <> nil) and (A0 < Pos.Count) and (A1 < Pos.Count) and
        (A2 < Pos.Count);
      if GatherJerseyVertices then
      begin
        if PosOk then
        begin
          JerseyMinY := Min(JerseyMinY, Min(Pos.L[A0].Y, Min(Pos.L[A1].Y, Pos.L[A2].Y)));
          JerseyMaxY := Max(JerseyMaxY, Max(Pos.L[A0].Y, Max(Pos.L[A1].Y, Pos.L[A2].Y)));
          JerseyVertices.Add(JerseyVertexKey(Pos.L[A0]));
          JerseyVertices.Add(JerseyVertexKey(Pos.L[A1]));
          JerseyVertices.Add(JerseyVertexKey(Pos.L[A2]));
        end;
        Exit;
      end;
      RasterTri(FDyeMaskAll[Ti], UV.L[A0], UV.L[A1], UV.L[A2]);
      { A split can put cuff/hem triangles into Arms or Shorts. Extend the
        jersey mask by one connected triangle ring, not to the whole part.
        The pixel chroma key still preserves skin and the shorts fabric. }
      if PosOk and HasSlot and (Slot in [csSkin, csShorts]) and
         not (FacePart or HeadPart or FingerPart) and
         ((JerseyVertices.IndexOf(JerseyVertexKey(Pos.L[A0])) >= 0) or
          (JerseyVertices.IndexOf(JerseyVertexKey(Pos.L[A1])) >= 0) or
          (JerseyVertices.IndexOf(JerseyVertexKey(Pos.L[A2])) >= 0)) then
        RasterTri(JerseyEdge[Ti], UV.L[A0], UV.L[A1], UV.L[A2], True);
      { FEM's hem contains blue/lilac cloth texels. Restrict their jersey
        ownership to the bottom 8% of the actual jersey geometry: the blue
        logo higher on the chest/back keeps its original colour. }
      if PosOk and HasSlot and (Slot = csJersey) and
         ((Pos.L[A0].Y + Pos.L[A1].Y + Pos.L[A2].Y) / 3.0 <=
          JerseyMinY + (JerseyMaxY - JerseyMinY) * 0.08) then
        RasterTri(FDyeMaskJerseyHem[Ti], UV.L[A0], UV.L[A1], UV.L[A2], True);
      Eye := False;
      if PosOk then
        Eye := TriInEye(Pos.L[A0], Pos.L[A1], Pos.L[A2]);
      { Глаза — EyeMask (радужка не волосы). Кайма причёски на Face/Head —
        в волосы по тону, без XYZ-овала и HairNeckY. }
      if Eye then
      begin
        RasterEye(UV.L[A0], UV.L[A1], UV.L[A2]);
        Inc(DyeNEye);
      end
      else if FacePart then
      begin
        RasterFace(UV.L[A0], UV.L[A1], UV.L[A2]);
        Inc(DyeNFace);
      end;
      if HasSlot and (Slot <> csHair) then
        RasterTri(FDyeMaskSlot[Ti][Ord(Slot)], UV.L[A0], UV.L[A1], UV.L[A2], Slot = csJersey);
      if FingerPart or
         (PosOk and IsGloveCuff(Pos.L[A0], Pos.L[A1], Pos.L[A2])
          and not (HasSlot and (Slot in [csHair, csShorts]))) then
      begin
        RasterTri(FDyeMaskSlot[Ti][Ord(csGloves)], UV.L[A0], UV.L[A1], UV.L[A2]);
        FDyeMaskHasGlobal := FDyeMaskHasGlobal + [csGloves];
      end;
      WantHair := (HasSlot and (Slot = csHair)) or HeadPart or FacePart;
      if WantHair and not Eye then
      begin
        RasterHair(UV.L[A0], UV.L[A1], UV.L[A2]);
        Inc(DyeNScalp);
        if UVHairBlue(UV.L[A0]) or UVHairBlue(UV.L[A1]) or
           UVHairBlue(UV.L[A2]) then
        begin
          StampUV(FDyeMaskSlot[Ti][Ord(csHair)], UV.L[A0], 8);
          StampUV(FDyeMaskSlot[Ti][Ord(csHair)], UV.L[A1], 8);
          StampUV(FDyeMaskSlot[Ti][Ord(csHair)], UV.L[A2], 8);
        end;
      end;
    end;

  begin
    G2 := Sh.Geometry;
    if G2 = nil then Exit;
    if not (G2 is TAbstractComposedGeometryNode) then Exit;
    TC := TAbstractComposedGeometryNode(G2).FdTexCoord.Value;
    { glTF-загрузчик кладёт TEXCOORD_0 в multi-узел даже при одном UV-сете }
    if TC is TMultiTextureCoordinateNode then
      if TMultiTextureCoordinateNode(TC).FdTexCoord.Count > 0 then
        TC := TMultiTextureCoordinateNode(TC).FdTexCoord[0]
      else
        TC := nil;
    if not (TC is TTextureCoordinateNode) then Exit;
    UV := TTextureCoordinateNode(TC).FdPoint.Items;
    if UV.Count = 0 then Exit;
    Pos := nil;
    CC := TAbstractComposedGeometryNode(G2).FdCoord.Value;
    if CC is TCoordinateNode then
      Pos := TCoordinateNode(CC).FdPoint.Items;
    { Волосы: меши Hair, Head и Face (кайма). Не Legs/Arms — без XYZ. }
    HeadSplit := HeadPart or FacePart or (HasSlot and (Slot = csHair));
    if HeadSplit then
      FDyeMaskHasGlobal := FDyeMaskHasGlobal + [csHair];
    if G2 is TIndexedTriangleSetNode then
    begin
      NT := TIndexedTriangleSetNode(G2).FdIndex.Count div 3;
      for T := 0 to NT - 1 do
      begin
        I0 := TIndexedTriangleSetNode(G2).FdIndex.Items[T * 3];
        I1 := TIndexedTriangleSetNode(G2).FdIndex.Items[T * 3 + 1];
        I2 := TIndexedTriangleSetNode(G2).FdIndex.Items[T * 3 + 2];
        EmitTri(I0, I1, I2);
      end;
    end
    else if G2 is TTriangleSetNode then
    begin
      NT := UV.Count div 3;
      for T := 0 to NT - 1 do
        EmitTri(T * 3, T * 3 + 1, T * 3 + 2);
    end;
    FDyeMaskAny := True;
  end;

  { Пустая маска (слот без геометрии в этой текстуре) — дилатировать нечего. }
  function MaskEmpty(const M: TBytes): Boolean;
  var
    I2: Integer;
  begin
    Result := True;
    for I2 := 0 to High(M) do
      if M[I2] <> 0 then Exit(False);
  end;

begin
  if FDyeMaskOk then Exit;
  FDyeMaskOk := True;
  { геометрический кэш: маски зависят только от файла, не от цветов }
  EnterCriticalSection(GDyeGeomLock);
  try
    if DyeGeomCacheMatch(FDyeSourcePath) then
    begin
      FDyeMaskW := GDyeGeomCache.MaskW;
      FDyeMaskH := GDyeGeomCache.MaskH;
      FDyeMaskJerseyHem := GDyeGeomCache.MaskJerseyHem;
      FDyeMaskAll := GDyeGeomCache.MaskAll;
      FDyeMaskSlot := GDyeGeomCache.MaskSlot;
      FDyeMaskAny := GDyeGeomCache.MaskAny;
      FDyeMaskHasGlobal := GDyeGeomCache.MaskHasGlobal;
      StartupLog('[dye] BuildDyeMasks: cache hit');
      Exit;
    end;
  finally
    LeaveCriticalSection(GDyeGeomLock);
  end;
  FDyeMaskAny := False;
  FDyeMaskHasGlobal := [];
  NTex := Length(FDyeTexNode);
  if NTex = 0 then Exit;
  SetLength(FDyeMaskW, NTex);
  SetLength(FDyeMaskH, NTex);
  SetLength(FDyeMaskJerseyHem, NTex);
  SetLength(FDyeMaskAll, NTex);
  SetLength(FDyeMaskSlot, NTex);
  SetLength(FaceMask, NTex);
  SetLength(EyeMask, NTex);
  SetLength(JerseyCore, NTex);
  SetLength(JerseyEdge, NTex);
  for I := 0 to 255 do
    if I / 255.0 <= 0.04045 then
      JerseyLinear[I] := (I / 255.0) / 12.92
    else
      JerseyLinear[I] := Power((I / 255.0 + 0.055) / 1.055, 2.4);
  SetLength(HairCore, NTex);
  for I := 0 to NTex - 1 do
  begin
    SetLength(FDyeMaskSlot[I], Ord(High(TClothSlot)) + 1);
    FDyeMaskW[I] := 0;
    FDyeMaskH[I] := 0;
  end;
  Scope := RiderContentRoot;
  if Scope = nil then Exit;

  { размеры масок — из декодированных текстур }
  for I := 0 to NTex - 1 do
  begin
    if not (FDyeTexNode[I] is TAbstractTexture2DNode) then Continue;
    T2 := TAbstractTexture2DNode(FDyeTexNode[I]);
    if not T2.IsTextureImage then Continue;
    Enc := T2.TextureImage;
    if not (Enc is TCastleImage) then Continue;
    FDyeMaskW[I] := TCastleImage(Enc).Width;
    FDyeMaskH[I] := TCastleImage(Enc).Height;
    SetLength(FDyeMaskAll[I], (FDyeMaskW[I] * FDyeMaskH[I] + 7) div 8);
    SetLength(JerseyEdge[I], (FDyeMaskW[I] * FDyeMaskH[I] + 7) div 8);
    SetLength(FDyeMaskJerseyHem[I], (FDyeMaskW[I] * FDyeMaskH[I] + 7) div 8);
    SetLength(FaceMask[I], (FDyeMaskW[I] * FDyeMaskH[I] + 7) div 8);
    SetLength(EyeMask[I], (FDyeMaskW[I] * FDyeMaskH[I] + 7) div 8);
    for K := 0 to Ord(High(TClothSlot)) do
      SetLength(FDyeMaskSlot[I][K], (FDyeMaskW[I] * FDyeMaskH[I] + 7) div 8);
  end;

  SetLength(FDyeShapeBuf, 0);
  Scope.EnumerateNodes(TShapeNode, @GrabDyeShape, False);
  ComputeHairFaceSign;
  ComputeHairNeckY;
  DyeNFace := 0;
  DyeNScalp := 0;
  DyeNEye := 0;
  DyeSamp := '';
  JerseyVertices := TStringList.Create;
  try
    JerseyVertices.Sorted := True;
    JerseyVertices.Duplicates := dupIgnore;
    JerseyMinY := 1e30; JerseyMaxY := -1e30;
    GatherJerseyVertices := True;
    for I := 0 to High(FDyeShapeBuf) do
    begin
      Sh := FDyeShapeBuf[I];
      if Sh.Appearance = nil then Continue;
      MatN := Sh.Appearance.FdMaterial.Value;
      if ShapeSlot(Sh, MatN, Slot) and (Slot = csJersey) then
        RasterShape(Sh, True, Slot, False, False, False);
    end;
    GatherJerseyVertices := False;
    for I := 0 to High(FDyeShapeBuf) do
    begin
      Sh := FDyeShapeBuf[I];
      if (Sh.Appearance = nil) then Continue;
      MatN := Sh.Appearance.FdMaterial.Value;
      if not (MatN is TPhysicalMaterialNode) then Continue;
      TexN := TPhysicalMaterialNode(MatN).FdBaseTexture.Value;
      if TexN = nil then Continue;
      Ti := -1;
      for K := 0 to NTex - 1 do
        if FDyeTexNode[K] = TexN then
        begin
          Ti := K;
          Break;
        end;
      if (Ti < 0) or (FDyeMaskW[Ti] <= 0) then Continue;
      W := FDyeMaskW[Ti];
      H := FDyeMaskH[Ti];
      HasSlot := ShapeSlot(Sh, MatN, Slot);
      if HasSlot then
      begin
        FDyeMaskHasGlobal := FDyeMaskHasGlobal + [Slot];
        if DyeSamp = '' then
          DyeSamp := DyePartLabel(Sh, MatN);
      end;
      HairPix := nil;
      HairPixPs := 0;
      if FDyeTexNode[Ti] is TAbstractTexture2DNode then
      begin
        T2 := TAbstractTexture2DNode(FDyeTexNode[Ti]);
        if T2.IsTextureImage and (T2.TextureImage is TCastleImage) then
          DyeRgbPtr(TCastleImage(T2.TextureImage), HairPix, HairPixPs);
      end;
      RasterShape(Sh, HasSlot, Slot, ShapeIsFace(Sh, MatN),
        ShapeIsHead(Sh, MatN), ShapeIsFinger(Sh, MatN));
    end;
  finally
    JerseyVertices.Free;
  end;
  SetLength(FDyeShapeBuf, 0);
  StartupLog(Format('[dye] headTris face=%d scalp=%d eye=%d samp=%s',
    [DyeNFace, DyeNScalp, DyeNEye, DyeSamp]));

  { Restrict recovered triangles to pink texels. Keep cyan shorts and skin
    eligible for their own dye even when they share a boundary triangle. }
  for I := 0 to NTex - 1 do
    if (FDyeMaskW[I] > 0) and (FDyeTexNode[I] is TAbstractTexture2DNode) then
    begin
      T2 := TAbstractTexture2DNode(FDyeTexNode[I]);
      if not T2.IsTextureImage or not (T2.TextureImage is TCastleImage) then Continue;
      if not DyeRgbPtr(TCastleImage(T2.TextureImage), HairPix, HairPixPs) then Continue;
      for J := 0 to FDyeMaskW[I] * FDyeMaskH[I] - 1 do
        if MaskGet(JerseyEdge[I], J) then
        begin
          EdgePixel := J * HairPixPs;
          if (JerseyLinear[HairPix[EdgePixel]] > JerseyLinear[HairPix[EdgePixel + 1]] + 0.003) and
             (JerseyLinear[HairPix[EdgePixel + 2]] > JerseyLinear[HairPix[EdgePixel + 1]] + 0.002) and
             (JerseyLinear[HairPix[EdgePixel]] >= JerseyLinear[HairPix[EdgePixel + 2]] * 0.85) then
            MaskSet(FDyeMaskSlot[I][Ord(csJersey)], J);
        end;
    end;

  if FDyeMaskAny then
    for I := 0 to NTex - 1 do
      if FDyeMaskW[I] > 0 then
      begin
        W := FDyeMaskW[I];
        H := FDyeMaskH[I];
        Dilate(FDyeMaskAll[I]);
        Dilate(FDyeMaskJerseyHem[I]);
        Dilate(FDyeMaskJerseyHem[I]);
        Dilate(FDyeMaskJerseyHem[I]);
        { ядро каждого слота до дилатации — чтобы не красить чужой остров }
        SetLength(Core, Ord(High(TClothSlot)) + 1);
        for K := 0 to Ord(High(TClothSlot)) do
          if Length(FDyeMaskSlot[I][K]) > 0 then
            Core[K] := Copy(FDyeMaskSlot[I][K]);
        if Length(Core[Ord(csJersey)]) > 0 then
          JerseyCore[I] := Copy(Core[Ord(csJersey)]);
        for K := 0 to Ord(High(TClothSlot)) do
          if (Length(FDyeMaskSlot[I][K]) > 0) and
             (not MaskEmpty(FDyeMaskSlot[I][K])) then
          begin
            Dilate(FDyeMaskSlot[I][K]);
            if TClothSlot(K) in [csSocks, csJersey] then
            begin
              Dilate(FDyeMaskSlot[I][K]);
              Dilate(FDyeMaskSlot[I][K]);
            end;
            { волосы: 1 px из общего цикла }
            if TClothSlot(K) = csHair then
              HairCore[I] := Copy(FDyeMaskSlot[I][K]);
          end;
        for K := 0 to Ord(High(TClothSlot)) do
          if Length(FDyeMaskSlot[I][K]) > 0 then
            for Oth := 0 to Ord(High(TClothSlot)) do
              if (Oth <> K) and (Length(Core[Oth]) > 0) then
              begin
                { Кайма затылка на атласе соседствует с шеей и воротом.
                  Любое вычитание ядра кожи/джерси выбивает голубые
                  тексели из маски Hair. Красим только голубые (IsKey). }
                { Из волос не вычитаем джерси и всю кожу (затылок рядом с
                  шеей на атласе). Глаза — отдельная FaceMask ниже. }
                if TClothSlot(K) = csHair then
                  Continue;
                { Манжета носка растерится и в csSkin (меш Legs), и в
                  csSocks. Вычитание ядра кожи выбивает её из носков. }
                if (TClothSlot(K) = csSocks) and (TClothSlot(Oth) = csSkin) then
                  Continue;
                { Полоска низа шорт тоже на csSkin (Legs) и в csShorts. }
                if (TClothSlot(K) = csShorts) and (TClothSlot(Oth) = csSkin) then
                  Continue;
                if (TClothSlot(K) = csGloves) and (TClothSlot(Oth) = csSkin) then
                  Continue;
                SubtractCore(FDyeMaskSlot[I][K], Core[Oth]);
              end;
        { лого джерси не красить шортами: любой тексель финальной маски
          джерси вычеркнуть из шорт (ядро шорт уже защищено вычитанием). }
        { UV overlap may include a jersey triangle in another part's core.
          The original jersey coverage always wins; clip only the padding. }
        MaskOr(FDyeMaskSlot[I][Ord(csJersey)], JerseyCore[I]);
        if (Length(FDyeMaskSlot[I][Ord(csShorts)]) > 0) and
           (Length(FDyeMaskSlot[I][Ord(csJersey)]) > 0) then
          SubtractCore(FDyeMaskSlot[I][Ord(csShorts)],
            FDyeMaskSlot[I][Ord(csJersey)]);
      end;

  { Face/Eye/Jersey UV одинаковы на клонах атласа (split копирует
    материал). Объединяем маски одного размера, иначе Hair-текстура
    не видит FaceMask с Head, а шорты не видят ядро джерси и
    дилатация закрашивает спину джерси. }
  for I := 0 to NTex - 1 do
    if FDyeMaskW[I] > 0 then
      for J := 0 to NTex - 1 do
        if (I <> J) and (FDyeMaskW[J] = FDyeMaskW[I]) and
           (FDyeMaskH[J] = FDyeMaskH[I]) then
        begin
          if (I <= High(FaceMask)) and (J <= High(FaceMask)) then
            MaskOr(FaceMask[I], FaceMask[J]);
          if (I <= High(EyeMask)) and (J <= High(EyeMask)) then
            MaskOr(EyeMask[I], EyeMask[J]);
          MaskOr(FDyeMaskJerseyHem[I], FDyeMaskJerseyHem[J]);
          if (Length(FDyeMaskSlot[I][Ord(csJersey)]) > 0) and
             (Length(FDyeMaskSlot[J][Ord(csJersey)]) > 0) then
            MaskOr(FDyeMaskSlot[I][Ord(csJersey)],
              FDyeMaskSlot[J][Ord(csJersey)]);
          if (I <= High(JerseyCore)) and (J <= High(JerseyCore)) and
             (Length(JerseyCore[I]) > 0) and (Length(JerseyCore[J]) > 0) then
            MaskOr(JerseyCore[I], JerseyCore[J]);
        end;
  for I := 0 to NTex - 1 do
    if (FDyeMaskW[I] > 0) and
       (Length(FDyeMaskSlot[I][Ord(csShorts)]) > 0) then
    begin
      if Length(FDyeMaskSlot[I][Ord(csJersey)]) > 0 then
        SubtractCore(FDyeMaskSlot[I][Ord(csShorts)],
          FDyeMaskSlot[I][Ord(csJersey)]);
      if (I <= High(JerseyCore)) and (Length(JerseyCore[I]) > 0) then
        SubtractCore(FDyeMaskSlot[I][Ord(csShorts)], JerseyCore[I]);
    end;

  for I := 0 to NTex - 1 do
    if (FDyeMaskW[I] > 0) and (Length(FDyeMaskSlot[I][Ord(csHair)]) > 0) then
    begin
      W := FDyeMaskW[I];
      H := FDyeMaskH[I];
      { Глаза: дилатация EyeMask + FaceMask. Затылок на другом UV-острове —
        паддинг лица больше не выедает затылок. }
      if (I <= High(EyeMask)) and (Length(EyeMask[I]) > 0) and
         (not MaskEmpty(EyeMask[I])) then
      begin
        Dilate(EyeMask[I]);
        Dilate(EyeMask[I]);
      end;
      { Лицо не вычитаем: кайма причёски на Face-меше. Радужка — EyeMask. }
      if (I <= High(EyeMask)) and (Length(EyeMask[I]) > 0) then
        SubtractCore(FDyeMaskSlot[I][Ord(csHair)], EyeMask[I]);
      { Барьер: лицо ∪ глаза ∪ ядро джерси — кайма волос не затекает
        в радужку и не заливает голубое лого на груди/спине. }
      if (I <= High(FaceMask)) then
        MaskOr(FaceMask[I], EyeMask[I]);
      if (I <= High(JerseyCore)) and (Length(JerseyCore[I]) > 0) then
        MaskOr(FaceMask[I], JerseyCore[I]);
      Enc := nil;
      if (I <= High(FDyeTexNode)) and
         (FDyeTexNode[I] is TAbstractTexture2DNode) then
      begin
        T2 := TAbstractTexture2DNode(FDyeTexNode[I]);
        if T2.IsTextureImage and (T2.TextureImage is TCastleImage) then
          Enc := T2.TextureImage;
      end;
      if Enc is TCastleImage then
        FloodHairBlue(FDyeMaskSlot[I][Ord(csHair)], TCastleImage(Enc),
          FaceMask[I]);
      { Ядро джерси вычесть из волос: лого на том же атласе, что причёска. }
      if (I <= High(JerseyCore)) and (Length(JerseyCore[I]) > 0) then
        SubtractCore(FDyeMaskSlot[I][Ord(csHair)], JerseyCore[I]);
      { Face/Eye/Jersey вычитание выедает тексели Hair-меша: на атласе
        остров причёски соседствует с глазами (V≈0.36) и паддингом.
        Вернуть голубые пиксели ядра Hair (до вычитаний). }
      if (I <= High(HairCore)) and (Length(HairCore[I]) > 0) and
         (Enc is TCastleImage) and
         DyeRgbPtr(TCastleImage(Enc), HairPix, HairPixPs) then
      begin
        W := FDyeMaskW[I];
        H := FDyeMaskH[I];
        J := 0;
        while J < W * H do
        begin
          if HairCore[I][J shr 3] = 0 then
          begin
            J := (J and not 7) + 8;
            Continue;
          end;
          if MaskGet(HairCore[I], J) and
             (not MaskGet(FDyeMaskSlot[I][Ord(csHair)], J)) then
          begin
            if not ((I <= High(JerseyCore)) and MaskGet(JerseyCore[I], J)) then
            begin
              K := J * HairPixPs;
              if HairBlueFracByte(HairPix[K], HairPix[K + 1], HairPix[K + 2])
                 >= 0.004 then
                MaskSet(FDyeMaskSlot[I][Ord(csHair)], J);
            end;
          end;
          Inc(J);
        end;
      end;
    end;

  { в кэш — следующая перезагрузка этого же glb (перекраска) возьмёт готовое.
    Разделяемые ссылки: маски после постройки только читаются (MaskBit). }
  EnterCriticalSection(GDyeGeomLock);
  try
    if DyeGeomCacheStore(FDyeSourcePath) then
    begin
      GDyeGeomCache.MaskW := FDyeMaskW;
      GDyeGeomCache.MaskH := FDyeMaskH;
      GDyeGeomCache.MaskJerseyHem := FDyeMaskJerseyHem;
      GDyeGeomCache.MaskAll := FDyeMaskAll;
      GDyeGeomCache.MaskSlot := FDyeMaskSlot;
      GDyeGeomCache.MaskAny := FDyeMaskAny;
      GDyeGeomCache.MaskHasGlobal := FDyeMaskHasGlobal;
    end;
  finally
    LeaveCriticalSection(GDyeGeomLock);
  end;
end;

procedure TTripoRiderScene.EnsureDyeOrig;
var
  I: Integer;
  T2: TAbstractTexture2DNode;
  Enc: TEncodedImage;
begin
  { pristine-копии исходных пикселей — декодируем один раз, запечка и
    детект тона кожи всегда из них (не из уже окрашенной текстуры). }
  for I := 0 to High(FDyeTexNode) do
    if FDyeOrigImg[I] = nil then
    begin
      if not (FDyeTexNode[I] is TAbstractTexture2DNode) then Continue;
      T2 := TAbstractTexture2DNode(FDyeTexNode[I]);
      if not T2.IsTextureImage then Continue;   { форсирует декод embedded png/jpg }
      Enc := T2.TextureImage;
      if not (Enc is TCastleImage) then Continue; { GPU-сжатая — пиксели не трогаем }
      FDyeOrigImg[I] := TCastleImage(Enc).MakeCopy;
    end;
end;

procedure TTripoRiderScene.DetectSkinTone;
const
  NB = 36;   { бины hue по 10° }
var
  Hist: array[0..NB - 1] of Integer;
  KeyH: array[TClothSlot] of Single;
  I, Xx, Yy, B, BestB, BestN, Off, Ps, V: Integer;
  Img: TCastleImage;
  Pix: PByte;
  R, G, Bc, H, Dh, SumR, SumG, SumB, SumN: Single;
  Slot: TClothSlot;
  Skip, UseMask: Boolean;
  LinLut: array[0..255] of Single;

  function S2L(C: Single): Single; inline;
  begin
    if C <= 0.04045 then Result := C / 12.92
    else Result := Power((C + 0.055) / 1.055, 2.4);
  end;

  function HueOf(R, G, B: Single): Single;
  var
    Mx, Mn, D, H2: Single;
  begin
    Mx := Max(R, Max(G, B));
    Mn := Min(R, Min(G, B));
    D := Mx - Mn;
    if D < 1e-5 then Exit(0.0);
    if ((Mx - R) <= (Mx - G)) and ((Mx - R) <= (Mx - B)) then
      H2 := 60.0 * ((G - B) / D)
    else if (Mx - G) <= (Mx - B) then
      H2 := 60.0 * ((B - R) / D + 2.0)
    else
      H2 := 60.0 * ((R - G) / D + 4.0);
    if H2 < 0.0 then H2 := H2 + 360.0;
    Result := H2;
  end;

  { -1 = пропустить; иначе hue текселя, линейные LR/LG/LB через out.
    Байты — sRGB (как Colors[].RGB = Pixel/255). }
  function AcceptHuePix(Rb, Gb, Bb: Byte; TexI, Xx, Yy, ImgW: Integer;
    UseMask: Boolean; out LR, LG, LB: Single): Single;
  var
    Mx, Mn, Sat: Single;
    Idx2: Integer;
  begin
    Result := -1;
    LR := 0; LG := 0; LB := 0;
    if UseMask then
    begin
      Idx2 := Yy * ImgW + Xx;
      if (Length(FDyeMaskSlot[TexI]) <= Ord(csSkin)) or
         (Length(FDyeMaskSlot[TexI][Ord(csSkin)]) = 0) or
         ((FDyeMaskSlot[TexI][Ord(csSkin)][Idx2 shr 3] and
           (1 shl (Idx2 and 7))) = 0) then Exit;
    end;
    LR := LinLut[Rb]; LG := LinLut[Gb]; LB := LinLut[Bb];
    Mx := Max(LR, Max(LG, LB));
    Mn := Min(LR, Min(LG, LB));
    if Mx < 0.06 then Exit;                        { совсем тёмное — волосы/подошвы }
    if Mx < 1e-5 then Sat := 0 else Sat := (Mx - Mn) / Mx;
    if Sat < 0.12 then Exit;                       { серое/белое — не кожа }
    Result := HueOf(LR, LG, LB);
  end;

begin
  if FSkinToneOk then Exit;
  FSkinToneOk := True;
  { кэш: тон зависит только от pristine-текстур файла }
  EnterCriticalSection(GDyeGeomLock);
  try
    if DyeGeomCacheMatch(FDyeSourcePath) and GDyeGeomCache.SkinToneOk then
    begin
      FSkinTone := GDyeGeomCache.SkinTone;
      StartupLog('[dye] SkinTone: cache hit');
      Exit;
    end;
  finally
    LeaveCriticalSection(GDyeGeomLock);
  end;
  FSkinTone := ClothDyeNativeColor(csSkin);   { fallback, если не нашли }
  for V := 0 to 255 do
    LinLut[V] := S2L(V / 255.0);
  for Slot := Low(TClothSlot) to High(TClothSlot) do
    KeyH[Slot] := HueOf(ClothDyeNativeColor(Slot).X,
      ClothDyeNativeColor(Slot).Y, ClothDyeNativeColor(Slot).Z);
  FillChar(Hist, SizeOf(Hist), 0);
  { 1-й проход: гистограмма тёплых hue (кожа — красно-оранжевая),
    без пикселей родных цветов одежды. Страйд 4 px: гистограмме хватает
    1/16 пикселей. }
  for I := 0 to High(FDyeOrigImg) do
  begin
    Img := FDyeOrigImg[I];
    if Img = nil then Continue;
    if not DyeRgbPtr(Img, Pix, Ps) then Continue;
    UseMask := FDyeMaskAny and (csSkin in FDyeMaskHasGlobal) and
      (I <= High(FDyeMaskW)) and (FDyeMaskW[I] = Img.Width) and
      (FDyeMaskH[I] = Img.Height);
    for Yy := 0 to (Img.Height - 1) div 4 do
      for Xx := 0 to (Img.Width - 1) div 4 do
      begin
        Off := ((Yy * 4) * Img.Width + (Xx * 4)) * Ps;
        H := AcceptHuePix(Pix[Off], Pix[Off + 1], Pix[Off + 2],
          I, Xx * 4, Yy * 4, Img.Width, UseMask, R, G, Bc);
        if H < 0 then Continue;
        if (H > 55.0) and (H < 320.0) then Continue;
        Skip := False;
        for Slot := csJersey to csGloves do
        begin
          Dh := Abs(H - KeyH[Slot]);
          Dh := Min(Dh, 360.0 - Dh);
          if Dh < 12.0 then
          begin
            Skip := True;
            Break;
          end;
        end;
        if Skip then Continue;
        Inc(Hist[EnsureRange(Floor(H / 10), 0, NB - 1)]);
      end;
  end;
  BestB := -1;
  BestN := 0;
  for B := 0 to NB - 1 do
    if Hist[B] > BestN then
    begin
      BestN := Hist[B];
      BestB := B;
    end;
  if BestN < 125 then Exit;   { кожи почти нет — fallback (порог /16 за страйд) }
  { 2-й проход: средний линейный цвет в окне ±15° вокруг центра бина }
  SumR := 0; SumG := 0; SumB := 0; SumN := 0;
  H := BestB * 10 + 5;
  for I := 0 to High(FDyeOrigImg) do
  begin
    Img := FDyeOrigImg[I];
    if Img = nil then Continue;
    if not DyeRgbPtr(Img, Pix, Ps) then Continue;
    UseMask := FDyeMaskAny and (csSkin in FDyeMaskHasGlobal) and
      (I <= High(FDyeMaskW)) and (FDyeMaskW[I] = Img.Width) and
      (FDyeMaskH[I] = Img.Height);
    for Yy := 0 to (Img.Height - 1) div 4 do
      for Xx := 0 to (Img.Width - 1) div 4 do
      begin
        Off := ((Yy * 4) * Img.Width + (Xx * 4)) * Ps;
        if AcceptHuePix(Pix[Off], Pix[Off + 1], Pix[Off + 2],
          I, Xx * 4, Yy * 4, Img.Width, UseMask, R, G, Bc) < 0 then Continue;
        Dh := Abs(HueOf(R, G, Bc) - H);
        Dh := Min(Dh, 360.0 - Dh);
        if Dh > 15.0 then Continue;
        SumR := SumR + R; SumG := SumG + G; SumB := SumB + Bc;
        SumN := SumN + 1;
      end;
  end;
  if SumN > 0 then
    FSkinTone := Vector3(SumR / SumN, SumG / SumN, SumB / SumN);
  { в кэш — перекраски этого же файла возьмут готовый тон }
  EnterCriticalSection(GDyeGeomLock);
  try
    if DyeGeomCacheMatch(FDyeSourcePath) then
    begin
      GDyeGeomCache.SkinTone := FSkinTone;
      GDyeGeomCache.SkinToneOk := True;
    end;
  finally
    LeaveCriticalSection(GDyeGeomLock);
  end;
end;

function TTripoRiderScene.SkinToneColor: TVector3;
begin
  if not FSkinToneOk then
  begin
    CacheDyeTextures;
    EnsureDyeOrig;
    BuildDyeMasks;
    DetectSkinTone;
  end;
  Result := FSkinTone;
end;

procedure TTripoRiderScene.BakeClothDye;
var
  { Текстурные байты — sRGB; шейдер сравнивал hue уже в линейном пространстве
    (после sRGB-декода сэмплера). Для паритета красим в линейном, с LUT в обе
    стороны. Ключи/цвета хранятся как линейные значения — как uniforms шейдера. }
  s2l: array[0..255] of Single;
  l2s: array[0..255] of Byte;
  CurTex, CurImgW, CurImgH: Integer;   { контекст текущей текстуры для UV-маски }
  NAct: Integer;
  Act: array[0..7] of TClothSlot;
  KeyH: array[TClothSlot] of Single;
  DyeLin: array[TClothSlot] of TVector3;
  NatLum: array[TClothSlot] of Single;
  DLumArr: array[TClothSlot] of Single;
  WMixArr: array[TClothSlot] of Single;
  UseUv: Boolean;

  function SrgbToLin(C: Single): Single; inline;
  begin
    if C <= 0.04045 then
      Result := C / 12.92
    else
      Result := Power((C + 0.055) / 1.055, 2.4);
  end;

  function LinToSrgbByte(C: Single): Byte; inline;
  var
    I2: Integer;
  begin
    if C <= 0.0 then Exit(l2s[0]);
    if C >= 1.0 then Exit(l2s[255]);
    I2 := Round(C * 255.0);
    if I2 < 0 then I2 := 0 else if I2 > 255 then I2 := 255;
    Result := l2s[I2];
  end;

  { Точное зеркало cloth_hue из GLSL-варианта. }
  function HueDeg(R, G, B: Single): Single;
  var
    Mx, Mn, D, H: Single;
  begin
    Mx := Max(R, Max(G, B));
    Mn := Min(R, Min(G, B));
    D := Mx - Mn;
    if D < 1e-5 then Exit(0.0);
    if ((Mx - R) <= (Mx - G)) and ((Mx - R) <= (Mx - B)) then
      H := 60.0 * ((G - B) / D)
    else if (Mx - G) <= (Mx - B) then
      H := 60.0 * ((B - R) / D + 2.0)
    else
      H := 60.0 * ((R - G) / D + 4.0);
    if H < 0.0 then H := H + 360.0;
    Result := H;
  end;

  { Слот-специфичный матч. H уже посчитан (один раз на тексель).
    Волосы — HairBlueFracByte по исходным sRGB-байтам, не сюда. }
  function IsKey(Slot: TClothSlot; R, G, B, H: Single): Boolean;
  var
    Mx, Mn, Sat, Dh: Single;
  begin
    Mx := Max(R, Max(G, B));
    Mn := Min(R, Min(G, B));
    if Mx < 1e-5 then Sat := 0.0 else Sat := (Mx - Mn) / Mx;
    case Slot of
      csShorts:
        begin
          { Бледный cyan и тень трусов: B≳G и B>R. Тень джерси (пыльная
            роза R>G≥B) и белый лого сюда не попадают — иначе 1 px
            дилатации маски шорт красит спину джерси. }
          if Mx < 0.04 then Exit(False);
          if (R > G + 0.02) and (G >= B * 0.90) and (R > B)
             and ((H < 50.0) or (H > 320.0)) then
            Exit(False);
          if ((H >= 300.0) or (H <= 22.0)) and (R > G + 0.04) and (Sat > 0.10) then
            Exit(False);
          Result := (B > R) and (B >= G * 0.85);
        end;
      csJersey:
        begin
          { Keep dark print. Match pale pink/lilac antialiasing by chroma
            instead of rejecting it at an arbitrary hue/saturation cutoff. }
          if Mx < 0.20 then Exit(False);
          Result := ((Sat >= 0.10) and (R > G + 0.04) and
            ((H >= 300.0) or (H <= 22.0))) or
            ((R > G + 0.003) and (B > G + 0.002) and (R >= B * 0.85));
        end;
      csSocks:
        begin
          { край / лайм манжеты: 188,238,53 → линейный hue~86, старое
            окно ≤85 отсекало. Перчатки (G≫R) не проходят R>B и маску. }
          if Mx < 0.12 then Exit(False);
          if Sat < 0.08 then Exit(False);
          if R <= B + 0.03 then Exit(False);
          if G <= B + 0.02 then Exit(False);
          Result := (H >= 28.0) and (H <= 105.0);
        end;
      csBoots:
        begin
          { Родной ключ 0.75,0.52,0.95 hue~272. Текстура — розово-сирень
            233..255, 206..220, 221..253 (hue 300–334). ±28° мимо.
            Peach (G≥B) и cyan (R<G) не берём. Джерси отсекает маска. }
          if Mx < 0.14 then Exit(False);
          if Sat < 0.04 then Exit(False);
          if B < G then Exit(False);
          if R < G then Exit(False);
          Result := (H >= 250.0) or (H <= 30.0);
        end;
      csGloves:
        begin
          { Мужские: олива 127–141,118–132. Женские: почти серые
            117–130,119–126,116–123 (R≈G≈B, hue любое, sat≲0.12).
            Персик (R>G+ε и G≳B) и cyan (B>G) не берём. }
          if Mx < 0.08 then Exit(False);
          if Sat < 0.015 then Exit(False);
          if (R > G + 0.035) and (G >= B * 0.90) then Exit(False);
          if (B > G + 0.025) and (B > R + 0.02) then Exit(False);
          if (Sat <= 0.16) and (Mx <= 0.48) then Exit(True);
          Result := (B <= G) and (R <= G + 0.02) and
            (H >= 45.0) and (H <= 165.0);
        end;
      csSkin:
        begin
          { Женская перчатка 116–121,119–121 sat≲0.09 и тёплый край
            120,115,111 sat~0.15 hue~24° попадали в окно кожи ±28°.
            Персик: sat≳0.25 и R>G. }
          if Mx < 0.10 then Exit(False);
          if Sat < 0.18 then Exit(False);
          if R <= G + 0.025 then Exit(False);
          if G < B * 0.88 then Exit(False);
          Dh := Abs(H - KeyH[csSkin]);
          Result := Min(Dh, 360.0 - Dh) < 28.0;
        end;
    else
      if Mx < 0.22 then Exit(False);
      if Sat < 0.10 then Exit(False);
      Dh := Abs(H - KeyH[Slot]);
      Result := Min(Dh, 360.0 - Dh) < 28.0;
    end;
  end;

  function MaskBit(const M: TBytes; Idx: Integer): Boolean; inline;
  begin
    Result := (Length(M) > 0) and (Idx >= 0) and ((Idx shr 3) < Length(M)) and
      ((M[Idx shr 3] and (1 shl (Idx and 7))) <> 0);
  end;

  function JerseyHemTexel(Idx: Integer): Boolean; inline;
  begin
    Result := UseUv and (CurTex >= 0) and (CurTex < Length(FDyeMaskJerseyHem)) and
      MaskBit(FDyeMaskJerseyHem[CurTex], Idx);
  end;

  function BytesEmpty(const M: TBytes): Boolean;
  var
    I2: Integer;
  begin
    Result := True;
    for I2 := 0 to High(M) do
      if M[I2] <> 0 then Exit(False);
  end;

  { Красим тексель, только если туда реально попадают UV одежды:
    у слота есть своя геометрия (split) — его UV-оболочки в ЭТОЙ текстуре;
    нет (цельный меш) — любые UV тела. Масок нет — старое поведение (hue only). }
  function TexelOk(Slot: TClothSlot; Idx: Integer): Boolean; inline;
  begin
    if not UseUv then Exit(True);
    { Кожа — только тон, без маски части: после split персик часто
      на носках/шортах/перчатках (XYZ-отрезы). Без split так и было. }
    if Slot = csSkin then
      Exit(True);
    if Slot in FDyeMaskHasGlobal then
      Result := MaskBit(FDyeMaskSlot[CurTex][Ord(Slot)], Idx)
    else
      Result := MaskBit(FDyeMaskAll[CurTex], Idx);
    { шорты никогда не красят UV джерси (подол / спина на общем атласе) }
    if Result and (Slot = csShorts) and (csJersey in FDyeMaskHasGlobal) then
      Result := not MaskBit(FDyeMaskSlot[CurTex][Ord(csJersey)], Idx);
    if Result and (Slot = csBoots) and (csJersey in FDyeMaskHasGlobal) then
      Result := not MaskBit(FDyeMaskSlot[CurTex][Ord(csJersey)], Idx);
    if Result and (Slot = csSocks) and (csBoots in FDyeMaskHasGlobal) then
      Result := not MaskBit(FDyeMaskSlot[CurTex][Ord(csBoots)], Idx);
  end;

  { Ключ hue-match слота: одежда — константа родного цвета, кожа —
    вычисленный из текстуры тон. }
  function DyeKeyOf(Slot: TClothSlot): TVector3; inline;
  begin
    if Slot = csSkin then
      Result := FSkinTone
    else
      Result := ClothDyeNativeColor(Slot);
  end;

  { Покраска текселя: меняется и тон, и яркость.
    Рельеф ткани = отношение яркости текселя к яркости родного цвета
    (ratio), результат = тон цели с яркостью dLum*ratio. Для тёмных
    целей чистое умножение убило бы складки (чёрный -> всё в ноль),
    поэтому подмешиваем аддитивный рельеф dLum + 0.5*(lum - lumNat)
    с весом w: чем темнее цель, тем больше аддитивной составляющей.
    Клиппинг ярких — равномерным делением на max-компонент, тон не сдвигается.
    Точное зеркало cloth_dye из GLSL-варианта. }
  procedure DyePix(Slot: TClothSlot; R, G, B: Single;
    out R2, G2, B2: Single; KeepNeutral: Boolean = True);
  var
    Lum, Nat, DLum, Ratio, Wgt, Ld, Sc, Mx, Coverage: Single;
    Dye: TVector3;
  begin
    Dye := DyeLin[Slot];
    Lum := 0.2126 * R + 0.7152 * G + 0.0722 * B;
    Nat := NatLum[Slot];
    DLum := DLumArr[Slot];
    Ratio := Lum / Nat;
    Wgt := WMixArr[Slot];
    Ld := Wgt * (DLum * Ratio) + (1.0 - Wgt) * (DLum + 0.5 * (Lum - Nat));
    if Ld < 0.0 then Ld := 0.0 else if Ld > 1.0 then Ld := 1.0;
    if DLum < 1e-4 then
    begin
      R2 := Ld; G2 := Ld; B2 := Ld;
    end
    else
    begin
      Sc := Ld / DLum;
      R2 := Dye.X * Sc; G2 := Dye.Y * Sc; B2 := Dye.Z * Sc;
      Mx := Max(R2, Max(G2, B2));
      if Mx > 1.0 then
      begin
        R2 := R2 / Mx; G2 := G2 / Mx; B2 := B2 / Mx;
      end;
    end;
    if (Slot = csJersey) and KeepNeutral then
    begin
      { Preserve the neutral part of white logo antialiasing. Remove its
        pink chroma without replacing an almost-white texel by solid dye. }
      Coverage := EnsureRange((R - G) / Max(R * 0.28, 0.0001), 0.0, 1.0);
      R2 := G * (1.0 - Coverage) + R2 * Coverage;
      G2 := G * (1.0 - Coverage) + G2 * Coverage;
      B2 := G * (1.0 - Coverage) + B2 * Coverage;
    end;
  end;

  { Среди слотов, чья UV-маска покрывает тексель, берём лучший chroma-match.
    Волосы: sRGB-байты (как Colors[] = Pixel/255), без LinToSrgbF/Power. }
  function BestSlot(R, G, B: Single; Rb, Gb, Bb: Byte; Idx: Integer;
    out Slot: TClothSlot): Boolean;
  var
    I2: Integer;
    S: TClothSlot;
    Best, Dh, H: Single;
    HDone: Boolean;
  begin
    Result := False;
    Best := 1e9;
    Slot := csJersey;
    HDone := False;
    H := 0;
    for I2 := 0 to NAct - 1 do
    begin
      S := Act[I2];
      { Перчатки уже взяли тексель — кожа (MaskAll) не перехватывает
        серую кожу перчаток/пальцев. Персик перчатки IsKey не берёт. }
      if (S = csSkin) and Result and (Slot = csGloves) then
        Continue;
      if not TexelOk(S, Idx) then Continue;
      if S = csHair then
      begin
        if HairBlueFracByte(Rb, Gb, Bb) < 0.004 then Continue;
      end
      else
      begin
        if not HDone then
        begin
          H := HueDeg(R, G, B);
          HDone := True;
        end;
        if not IsKey(S, R, G, B, H) then
          if not ((S = csJersey) and JerseyHemTexel(Idx) and
             (Max(R, Max(G, B)) >= 0.20) and IsKey(csShorts, R, G, B, H)) then Continue;
      end;
      if not HDone then
      begin
        H := HueDeg(R, G, B);
        HDone := True;
      end;
      Dh := Abs(H - KeyH[S]);
      Dh := Min(Dh, 360.0 - Dh);
      if (not Result) or (Dh < Best) then
      begin
        Best := Dh;
        Slot := S;
        Result := True;
      end;
    end;
  end;

  procedure DyeImg(Img: TCastleImage);
  var
    P: PByte;
    Cnt, Ps, Xx, Yy, Idx: Integer;
    R, G, B, R2, G2, B2: Single;
    Slot: TClothSlot;
    C: TVector4;
    HairEdge: Integer;
    HairDyed: TBytes;

    procedure BitSet(var M: TBytes; I2: Integer); inline;
    begin
      M[I2 shr 3] := M[I2 shr 3] or Byte(1 shl (I2 and 7));
    end;

    function BitGet(const M: TBytes; I2: Integer): Boolean; inline;
    begin
      Result := (M[I2 shr 3] and (1 shl (I2 and 7))) <> 0;
    end;

    { 2–3 px кайма волос/кожи: лавандовый антиалиас (hue~310) и слабо-
      голубые тексели не проходят HairBlueFrac и часто лежат вне маски.
      Красим соседей уже окрашенных, персик и розовый джерси не трогаем. }
    procedure ExpandHairFringe;
    var
      Orig: TCastleImage;
      Op, Dp: PByte;
      OPs, X, Y, Nx, Ny, Nidx, Dx, Dy, It, N, Lim: Integer;
      Rb, Gb, Bb: Byte;
      Src: TBytes;
    begin
      if not FDyeActive[csHair] then Exit;
      if (CurTex < 0) or (CurTex > High(FDyeOrigImg)) then Exit;
      Orig := FDyeOrigImg[CurTex];
      if Orig = nil then Exit;
      if Orig.Width <> Img.Width then Exit;
      if Orig.Height <> Img.Height then Exit;
      if not DyeRgbPtr(Orig, Op, OPs) then Exit;
      N := 0;
      Lim := Img.Width * Img.Height;
      for It := 1 to 6 do
      begin
        Src := Copy(HairDyed);
        Dp := PByte(Img.RawPixels);
        Idx := 0;
        while Idx < Lim do
        begin
          if Src[Idx shr 3] = 0 then
          begin
            Idx := (Idx and not 7) + 8;
            Continue;
          end;
          if not BitGet(Src, Idx) then
          begin
            Inc(Idx);
            Continue;
          end;
          Y := Idx div Img.Width;
          X := Idx - Y * Img.Width;
          for Dy := -1 to 1 do
            for Dx := -1 to 1 do
            begin
              if (Dx = 0) and (Dy = 0) then Continue;
              Nx := X + Dx;
              Ny := Y + Dy;
              if (Nx < 0) or (Ny < 0) or (Nx >= Img.Width) or
                 (Ny >= Img.Height) then Continue;
              Nidx := Ny * Img.Width + Nx;
              if BitGet(HairDyed, Nidx) then Continue;
              Rb := Op[Nidx * OPs];
              Gb := Op[Nidx * OPs + 1];
              Bb := Op[Nidx * OPs + 2];
              { персик / тёплый флеш: R>G≳B }
              if (Rb > Gb + 4) and (Gb >= (Bb * 230) div 255) and
                 (Rb > Bb + 8) then
                Continue;
              { насыщенный розовый джерси (G низкий). Лавандовая кайма
                волос (253,191,232) G/R≈0.75 — не трогаем. }
              if (Rb > Bb + 20) and (Gb < (Rb * 180) div 255) then
                Continue;
              if (Rb < 18) and (Gb < 18) and (Bb < 18) then
                Continue;
              R := s2l[Rb]; G := s2l[Gb]; B := s2l[Bb];
              DyePix(csHair, R, G, B, R2, G2, B2);
              Dp[Nidx * Ps] := LinToSrgbByte(R2);
              Dp[Nidx * Ps + 1] := LinToSrgbByte(G2);
              Dp[Nidx * Ps + 2] := LinToSrgbByte(B2);
              BitSet(HairDyed, Nidx);
              Inc(N);
            end;
          Inc(Idx);
        end;
      end;
      HairEdge := N;
    end;

  begin
    HairEdge := 0;
    CurImgW := Img.Width;
    CurImgH := Img.Height;
    UseUv := FDyeMaskAny and (CurTex >= 0) and
      (CurTex <= High(FDyeMaskW)) and (FDyeMaskW[CurTex] = CurImgW) and
      (FDyeMaskH[CurTex] = CurImgH);
    SetLength(HairDyed, (Img.Width * Img.Height + 7) div 8);
    if DyeRgbPtr(Img, P, Ps) then
    begin
      Cnt := Img.Width * Img.Height * Img.Depth;
      Idx := 0;
      while Cnt > 0 do
      begin
        R := s2l[P[0]]; G := s2l[P[1]]; B := s2l[P[2]];
        if BestSlot(R, G, B, P[0], P[1], P[2], Idx, Slot) then
        begin
          DyePix(Slot, R, G, B, R2, G2, B2, not JerseyHemTexel(Idx));
          P[0] := LinToSrgbByte(R2);
          P[1] := LinToSrgbByte(G2);
          P[2] := LinToSrgbByte(B2);
          if Slot = csHair then
            BitSet(HairDyed, Idx);
        end;
        Inc(P, Ps);
        Inc(Idx);
        Dec(Cnt);
      end;
      ExpandHairFringe;
    end
    else
      { редкие классы изображений — медленный путь через Colors[] }
      for Yy := 0 to Img.Height - 1 do
        for Xx := 0 to Img.Width - 1 do
        begin
          C := Img.Colors[Xx, Yy, 0];
          R := SrgbToLin(C.X); G := SrgbToLin(C.Y); B := SrgbToLin(C.Z);
          if BestSlot(R, G, B,
            Byte(EnsureRange(Round(C.X * 255), 0, 255)),
            Byte(EnsureRange(Round(C.Y * 255), 0, 255)),
            Byte(EnsureRange(Round(C.Z * 255), 0, 255)),
            Yy * Img.Width + Xx, Slot) then
          begin
            DyePix(Slot, R, G, B, R2, G2, B2, not JerseyHemTexel(Yy * Img.Width + Xx));
            C.X := R2; C.Y := G2; C.Z := B2;
            Img.Colors[Xx, Yy, 0] := C;
          end;
        end;
    if FDyeActive[csHair] then
      StartupLog(Format('[dye] tex hairEdge=%d', [HairEdge]));
  end;

var
  I, V: Integer;
  AnyOn, WantDye, TexHas: Boolean;
  Slot: TClothSlot;
  Work: TCastleImage;
  TD0: QWord;
  KeyVec: TVector3;
begin
  if not FLoaded then Exit;
  { Separate garment materials use their base factor. Hue matching an old
    painted atlas would reject neutral colour maps (or tint white heels). }
  ApplyMaterialClothDye;
  CurTex := -1;
  CurImgW := 0;
  CurImgH := 0;
  NAct := 0;
  UseUv := False;
  AnyOn := False;
  for Slot := Low(TClothSlot) to High(TClothSlot) do
    if FDyeActive[Slot] and ((FCorrectives = nil) or (Slot in [csSkin, csHair])) then AnyOn := True;
  WantDye := (FDyeMode = cdmTexture) and AnyOn;
  if (not WantDye) and (not FDyeBaked) then Exit;
  CacheDyeTextures;
  if Length(FDyeTexNode) = 0 then
  begin
    FDyeBaked := False;
    Exit;
  end;
  if WantDye then
  begin
    TD0 := GetTickCount64;
    BuildDyeMasks;
    StartupLog(Format('[dye] BuildDyeMasks %d ms', [GetTickCount64 - TD0]));
    TD0 := GetTickCount64;
    EnsureDyeOrig;
    StartupLog(Format('[dye] EnsureDyeOrig %d ms', [GetTickCount64 - TD0]));
    SkinToneColor;   { тон кожи из pristine-текстур до первой запечки }
    for V := 0 to 255 do
    begin
      s2l[V] := SrgbToLin(V / 255.0);
      if V / 255.0 <= 0.0031308 then
        l2s[V] := EnsureRange(Round(12.92 * (V / 255.0) * 255), 0, 255)
      else
        l2s[V] := EnsureRange(Round(
          (1.055 * Power(V / 255.0, 1 / 2.4) - 0.055) * 255), 0, 255);
    end;
    NAct := 0;
    for Slot := Low(TClothSlot) to High(TClothSlot) do
      if FDyeActive[Slot] and ((FCorrectives = nil) or (Slot in [csSkin, csHair])) then
      begin
        Act[NAct] := Slot;
        Inc(NAct);
        KeyVec := DyeKeyOf(Slot);
        KeyH[Slot] := HueDeg(KeyVec.X, KeyVec.Y, KeyVec.Z);
        DyeLin[Slot] := FDyeColor[Slot];
        NatLum[Slot] := Max(0.2126 * KeyVec.X + 0.7152 * KeyVec.Y +
          0.0722 * KeyVec.Z, 0.05);
        DLumArr[Slot] := 0.2126 * DyeLin[Slot].X + 0.7152 * DyeLin[Slot].Y +
          0.0722 * DyeLin[Slot].Z;
        WMixArr[Slot] := DLumArr[Slot] / 0.18;
        if WMixArr[Slot] < 0.0 then WMixArr[Slot] := 0.0
        else if WMixArr[Slot] > 1.0 then WMixArr[Slot] := 1.0;
      end;
  end;

  EnsureDyeOrig;   { pristine-копии нужны и для восстановления без покраски }
  for I := 0 to High(FDyeTexNode) do
  begin
    { запечка всегда из pristine-копии — не накапливается; возврат к
      оригиналу точный }
    if FDyeOrigImg[I] = nil then Continue;   { недекодируемая текстура }
    { На свежезагруженной сцене текстура УЖЕ pristine — если по UV-маскам
      в ней нет пикселей ни одного активного слота, пропускаем копию,
      покраску и аплоад целиком (главная экономия перекраски: трогаем
      только текстуры затронутых частей). }
    if WantDye and FDyeMaskAny and (I <= High(FDyeMaskW)) and
       (FDyeMaskW[I] > 0) then
    begin
      TexHas := False;
      for Slot := Low(TClothSlot) to High(TClothSlot) do
        if FDyeActive[Slot] then
        begin
          if Slot in FDyeMaskHasGlobal then
            TexHas := not BytesEmpty(FDyeMaskSlot[I][Ord(Slot)])
          else
            TexHas := not BytesEmpty(FDyeMaskAll[I]);
          if TexHas then Break;
        end;
      if not TexHas then Continue;
    end;
    TD0 := GetTickCount64;
    Work := FDyeOrigImg[I].MakeCopy;
    if WantDye then
    begin
      CurTex := I;
      DyeImg(Work);
      CurTex := -1;
    end;
    StartupLog(Format('[dye] tex %d copy+dye %d ms (%dx%d)',
      [I, GetTickCount64 - TD0, Work.Width, Work.Height]));
    TD0 := GetTickCount64;
    { Тот же приём, что и в ApplyGlossCorrection: узел остаётся на месте,
      меняются только пиксели — дешёвое обновление текстуры без пересборки
      шейдера и re-setup сцены. }
    if FDyeTexNode[I] is TImageTextureNode then
      TImageTextureNode(FDyeTexNode[I]).LoadFromImage(Work, True, '')
    else if FDyeTexNode[I] is TPixelTextureNode then
    begin
      TPixelTextureNode(FDyeTexNode[I]).FdImage.Value := Work;  { SFImage owns it }
      TPixelTextureNode(FDyeTexNode[I]).FdImage.Changed;
    end
    else
      Work.Free;
    StartupLog(Format('[dye] tex %d upload %d ms', [I, GetTickCount64 - TD0]));
  end;
  FDyeBaked := WantDye;
  { Живая сцена: после замены пикселей текстуры форсируем полную
    ре-подготовку render-данных — иначе renderer продолжает рисовать
    по протухшим GPU-дескрипторам и сцена пропадает целиком. }
  if FScene <> nil then
    FScene.ChangedAll;
end;

function TTripoRiderScene.GetDyeColor(Slot: TClothSlot): TVector3;
begin
  Result := FDyeColor[Slot];
end;

procedure TTripoRiderScene.SetDyeColor(Slot: TClothSlot; const V: TVector3);
begin
  FDyeColor[Slot] := V;
  if FDyeActive[Slot] and FDyeInLoad then BakeClothDye;
  { live-запечь нельзя: запечётся при следующей загрузке }
end;

function TTripoRiderScene.GetDyeActive(Slot: TClothSlot): Boolean;
begin
  Result := FDyeActive[Slot];
end;

procedure TTripoRiderScene.SetClothColor(Slot: TClothSlot; const C: TVector3);
begin
  FDyeColor[Slot] := C;
  FDyeActive[Slot] := True;
  { Live-запечка запрещена (глушит рендер живой GL-сцены) — только при
    загрузке. Шейдерный режим обновляет uniforms на живой сцене. }
  if FDyeInLoad then
    BakeClothDye
  else if FDyeMode = cdmShader then
  begin
    if Length(FDyeShColor[Slot]) = 0 then
    begin
      if DyeSceneIsRiderOnly then
        RefreshShaderClothDye;
    end
    else
      PushShaderClothDye(Slot);
  end;
end;

procedure TTripoRiderScene.ClearClothColor(Slot: TClothSlot);
begin
  if not FDyeActive[Slot] then Exit;
  FDyeActive[Slot] := False;
  if FDyeInLoad then
    BakeClothDye
  else if FDyeMode = cdmShader then
    PushShaderClothDye(Slot);
end;

procedure TTripoRiderScene.StageClothColor(Slot: TClothSlot; const C: TVector3);
begin
  FDyeColor[Slot] := C;
  FDyeActive[Slot] := True;   { запечётся при следующей загрузке }
end;

procedure TTripoRiderScene.StageClearClothColor(Slot: TClothSlot);
begin
  FDyeActive[Slot] := False;
end;

procedure TTripoRiderScene.SetDyeMode(const V: TClothDyeMode);
var
  Old: TClothDyeMode;
begin
  if FDyeMode = V then Exit;
  Old := FDyeMode;
  FDyeMode := V;
  ApplyMaterialClothDye;
  { Уходим с cdmTexture — вернуть исходные пиксели; приходим — запечь.
    На живой сцене запечь нельзя — caller перезагружает сцену сам. }
  if FDyeInLoad then
    BakeClothDye
  else if V = cdmShader then
  begin
    if DyeSceneIsRiderOnly then
      RefreshShaderClothDye;
  end
  else if Old = cdmShader then
    RemoveShaderClothDye;
end;

procedure TTripoRiderScene.CopyClothDyeFrom(Src: TTripoRiderScene);
var
  S: TClothSlot;
begin
  if Src = nil then Exit;
  FDyeMode := Src.FDyeMode;
  for S := Low(TClothSlot) to High(TClothSlot) do
  begin
    FDyeColor[S] := Src.FDyeColor[S];
    FDyeActive[S] := Src.FDyeActive[S];
  end;
end;

procedure TTripoRiderScene.GrabDyeAppearance(Node: TX3DNode);
begin
  if Node is TAppearanceNode then
  begin
    SetLength(FDyeShAppBuf, Length(FDyeShAppBuf) + 1);
    FDyeShAppBuf[High(FDyeShAppBuf)] := TAppearanceNode(Node);
  end;
end;

function TTripoRiderScene.DyeLabelOfShape(Sh: TShapeNode): string;
var
  U, Dig: string;
  P, Pi: Integer;
  MatN: TX3DNode;
begin
  Result := '';
  if Sh = nil then Exit;
  if (FCorrectives <> nil) and (Sh.Appearance <> nil) then
  begin
    if Sh.Appearance.X3DName <> '' then Exit(Sh.Appearance.X3DName);
    MatN := Sh.Appearance.FdMaterial.Value;
    if (MatN <> nil) and (MatN.X3DName <> '') then Exit(MatN.X3DName);
  end;
  U := UpperCase(Sh.X3DName);
  { CGE names the rigid accessory Helmet_Primitive0. Primitive 0 of the
    BODY mesh is Boots — without this guard the helmet gets ClothDye as
    boots on top of ApplyHelmetColor (BaseColor multiply). Red/pink
    fragments then match the boot chroma key and all become boot-blue. }
  if Pos('HELMET', U) > 0 then
    Exit(Sh.X3DName);
  P := Pos('_PRIMITIVE', U);
  if P > 0 then
  begin
    Dig := Copy(U, P + Length('_PRIMITIVE'), 8);
    while (Length(Dig) > 0) and not (Dig[Length(Dig)] in ['0'..'9']) do
      Delete(Dig, Length(Dig), 1);
    Pi := StrToIntDef(Dig, -1);
    if (Pi >= 0) and (Pi < Length(FDyePartNames)) then
      Exit(FDyePartNames[Pi]);
  end;
  if (Sh.Appearance <> nil) and (Sh.Appearance.X3DName <> '') then
    Exit(Sh.Appearance.X3DName);
  if Sh.Appearance <> nil then
    MatN := Sh.Appearance.FdMaterial.Value
  else
    MatN := nil;
  if (MatN <> nil) and (MatN.X3DName <> '') then
    Exit(MatN.X3DName);
  Result := Sh.X3DName;
end;

function TTripoRiderScene.SlotOfLiveShape(Sh: TShapeNode; out Slot: TClothSlot): Boolean;
begin
  Result := ClothSlotOfName(DyeLabelOfShape(Sh), Slot);
end;

procedure TTripoRiderScene.ClearShaderDyeFields;
var
  S: TClothSlot;
begin
  for S := Low(TClothSlot) to High(TClothSlot) do
  begin
    SetLength(FDyeShColor[S], 0);
    SetLength(FDyeShAmt[S], 0);
  end;
end;

procedure TTripoRiderScene.PushShaderClothDye(Slot: TClothSlot);
var
  I: Integer;
  Amt: Single;
begin
  if FDyeActive[Slot] then Amt := 1.0 else Amt := 0.0;
  for I := 0 to High(FDyeShColor[Slot]) do
    if FDyeShColor[Slot][I] <> nil then
      FDyeShColor[Slot][I].Send(ShaderClothDyeColor(Slot));
  for I := 0 to High(FDyeShAmt[Slot]) do
    if FDyeShAmt[Slot][I] <> nil then
      FDyeShAmt[Slot][I].Send(Amt);
end;

procedure TTripoRiderScene.RemoveShaderClothDye;
var
  I, E: Integer;
  App: TAppearanceNode;
  Removed: Boolean;
  Scope: TX3DNode;
  Nm: string;
begin
  Removed := False;
  ClearShaderDyeFields;
  Scope := RiderContentRoot;
  if Scope = nil then
  begin
    if (FScene <> nil) then Scope := FScene.RootNode;
  end;
  if Scope = nil then Exit;
  SetLength(FDyeShAppBuf, 0);
  Scope.EnumerateNodes(TAppearanceNode, @GrabDyeAppearance, False);
  { FdEffects.ChangeAlways = chEverything: каждый Delete без BeginChangesSchedule
    делает полный ChangedAll сцены (байк+райдер → фриз в nvoglv64). }
  if FScene <> nil then
    FScene.BeginChangesSchedule;
  try
    for I := 0 to High(FDyeShAppBuf) do
    begin
      App := FDyeShAppBuf[I];
      if App = nil then Continue;
      E := App.FdEffects.Count;
      while E > 0 do
      begin
        Dec(E);
        if not (App.FdEffects[E] is TEffectNode) then Continue;
        Nm := TEffectNode(App.FdEffects[E]).X3DName;
        if (Nm = 'ClothDye') or (Nm = 'ClothDyeHair') or
           (Nm = 'ClothDyeSkin') or (Nm = 'ClothDyeGloves') then
        begin
          App.FdEffects.Delete(E);
          Removed := True;
        end;
      end;
    end;
  finally
    if FScene <> nil then
      FScene.EndChangesSchedule;
  end;
  SetLength(FDyeShAppBuf, 0);
end;

procedure TTripoRiderScene.RefreshShaderClothDye;
const
  { 0 empty plug, no uniforms, one effect
    1 uniforms declared, plug still no-op
    2 full dye GLSL, still one effect
    3 full + extra Hair/Skin/Gloves }
  DyeShaderDiagStep = 3;
  DyeSrcEmpty =
    'void PLUG_main_texture_apply(inout vec4 fragment_color, const in vec3 normal)' + LineEnding +
    '{' + LineEnding +
    '}';
  DyeSrcUniformsNoop =
    'uniform vec3 uDye;' + LineEnding +
    'uniform vec3 uDyeKey;' + LineEnding +
    'uniform float uDyeAmt;' + LineEnding +
    'uniform float uDyeKind;' + LineEnding +
    'void PLUG_main_texture_apply(inout vec4 fragment_color, const in vec3 normal)' + LineEnding +
    '{' + LineEnding +
    '}';
  DyeSrcFull = RIDER_CLOTH_DYE_GLSL;
var
  Scope: TX3DNode;
  NeedAll: Boolean;
  Slot: TClothSlot;
  I, NSh, AttachN: Integer;
  Sh: TShapeNode;
  App: TAppearanceNode;
  Lb: string;
  Shapes: array of TShapeNode;
  DyeSrc: string;
  { One uniform set per dye slot/name on this rider. Sharing the exact node
    lets CGE reuse programs for separate primitives of the same material. }
  SharedDye: array[TClothSlot, 0..3] of TEffectNode;

  function DyeKeyOf(ASlot: TClothSlot): TVector3;
  begin
    { Live shader path must not call SkinToneColor: that builds UV dye
      masks on the main thread. Native peach is the chroma key. }
    if (ASlot = csSkin) and FSkinToneOk then
      Result := FSkinTone
    else
      Result := ClothDyeNativeColor(ASlot);
  end;

  procedure AttachEff(AApp: TAppearanceNode; ASlot: TClothSlot;
    const EffNm: string);
  var
    E, N, Key: Integer;
    Eff: TEffectNode;
    Part: TEffectPartNode;
    UDye: TSFVec3f;
    UAmt: TSFFloat;
    Has: Boolean;
    Amt: Single;
    Src: string;
  begin
    if AApp = nil then Exit;
    if not FDyeActive[ASlot] then Exit;
    Key := 0;
    if EffNm = 'ClothDyeHair' then Key := 1
    else if EffNm = 'ClothDyeSkin' then Key := 2
    else if EffNm = 'ClothDyeGloves' then Key := 3;
    Has := False;
    Eff := nil;
    Amt := 1.0;
    E := 0;
    while E < AApp.FdEffects.Count do
    begin
      if (AApp.FdEffects[E] is TEffectNode) and
         (TEffectNode(AApp.FdEffects[E]).X3DName = EffNm) then
      begin
        Eff := TEffectNode(AApp.FdEffects[E]);
        Has := True;
        Break;
      end;
      Inc(E);
    end;
    if Has then Exit; { this shared appearance was already visited }
    UDye := nil;
    UAmt := nil;
    if not Has and (SharedDye[ASlot, Key] <> nil) then
    begin
      AApp.FdEffects.Add(SharedDye[ASlot, Key]);
      Exit; { uniform fields were registered on the first attachment }
    end;
    if not Has then
    begin
      Eff := TEffectNode.Create(EffNm);
      Eff.Language := slGLSL;
      Src := DyeSrc;
      if (FCorrectives <> nil) and (ASlot in [csJersey, csShorts, csSocks, csBoots, csGloves]) then
      begin
        Src := 'uniform vec3 uDye; uniform float uDyeAmt;' + LineEnding +
          'void PLUG_main_texture_apply(inout vec4 fragment_color, const in vec3 normal) {' + LineEnding +
          '  fragment_color.rgb = mix(fragment_color.rgb, uDye, clamp(uDyeAmt,0.0,1.0)); }';
        if ASlot = csJersey then
          Src := 'uniform vec3 uDye; uniform float uDyeAmt;' + LineEnding +
            'void PLUG_main_texture_apply(inout vec4 fragment_color, const in vec3 normal) {' + LineEnding +
            '  float lum = dot(fragment_color.rgb, vec3(0.2126, 0.7152, 0.0722));' + LineEnding +
            '  fragment_color.rgb = mix(fragment_color.rgb, uDye * lum, clamp(uDyeAmt,0.0,1.0)); }';
      end;
      { Unique helpers AND uniforms per effect. Two ClothDye* on one
        appearance share a GL program; same uDye/cloth_hue names collide
        (magenta) or the last effect overwrites kind/color (no dye). }
      Src := StringReplace(Src, 'cloth_is_key', 'cloth_is_key_' + EffNm, [rfReplaceAll]);
      Src := StringReplace(Src, 'cloth_dye', 'cloth_dye_' + EffNm, [rfReplaceAll]);
      Src := StringReplace(Src, 'cloth_hue', 'cloth_hue_' + EffNm, [rfReplaceAll]);
      Src := StringReplace(Src, 'uDyeKind', 'uKind_' + EffNm, [rfReplaceAll]);
      Src := StringReplace(Src, 'uDyeKey', 'uKey_' + EffNm, [rfReplaceAll]);
      Src := StringReplace(Src, 'uDyeAmt', 'uAmt_' + EffNm, [rfReplaceAll]);
      Src := StringReplace(Src, 'uDye', 'uDye_' + EffNm, [rfReplaceAll]);
      if DyeShaderDiagStep >= 1 then
      begin
        UDye := TSFVec3f.Create(Eff, True, 'uDye_' + EffNm, ShaderClothDyeColor(ASlot));
        UAmt := TSFFloat.Create(Eff, True, 'uAmt_' + EffNm, Amt);
        Eff.AddCustomField(UDye);
        Eff.AddCustomField(UAmt);
        if Pos('uKey_' + EffNm, Src) > 0 then
          Eff.AddCustomField(TSFVec3f.Create(Eff, True, 'uKey_' + EffNm, DyeKeyOf(ASlot)));
        if Pos('uKind_' + EffNm, Src) > 0 then
          Eff.AddCustomField(TSFFloat.Create(Eff, True, 'uKind_' + EffNm, Ord(ASlot)));
      end;
      Part := TEffectPartNode.Create;
      Part.ShaderType := stFragment;
      Part.Contents := Src;
      Eff.SetParts([Part]);
      if AApp.FdEffects.Count = 0 then
        AApp.SetEffects([Eff])
      else
        AApp.FdEffects.Add(Eff);
      if FScene <> nil then
        Eff.Scene := FScene;
      Inc(AttachN);
      SharedDye[ASlot, Key] := Eff;
    end;
    if UDye <> nil then
    begin
      N := Length(FDyeShColor[ASlot]);
      SetLength(FDyeShColor[ASlot], N + 1);
      FDyeShColor[ASlot][N] := UDye;
      UDye.Send(ShaderClothDyeColor(ASlot));
    end;
    if UAmt <> nil then
    begin
      N := Length(FDyeShAmt[ASlot]);
      SetLength(FDyeShAmt[ASlot], N + 1);
      FDyeShAmt[ASlot][N] := UAmt;
      UAmt.Send(Amt);
    end;
  end;

begin
  if FDyeShBusy then Exit;
  FDyeShBusy := True;
  try
    if FScene = nil then Exit;
    ApplyMaterialClothDye;
    case DyeShaderDiagStep of
      0: DyeSrc := DyeSrcEmpty;
      1: DyeSrc := DyeSrcUniformsNoop;
      else DyeSrc := DyeSrcFull;
    end;
    AttachN := 0;
    FillChar(SharedDye, SizeOf(SharedDye), 0);
    if FDyeMode <> cdmShader then
    begin
      RemoveShaderClothDye;
      Exit;
    end;
    NeedAll := False;
    for Slot := Low(TClothSlot) to High(TClothSlot) do
      if FDyeActive[Slot] then
        NeedAll := True;
    if not NeedAll then
    begin
      RemoveShaderClothDye;
      Exit;
    end;
    Scope := RiderContentRoot;
    if Scope = nil then
      Scope := FScene.RootNode;
    if Scope = nil then Exit;
    SetLength(FDyeShapeBuf, 0);
    Scope.EnumerateNodes(TShapeNode, @GrabDyeShape, False);
    NSh := Length(FDyeShapeBuf);
    SetLength(Shapes, NSh);
    for I := 0 to NSh - 1 do
      Shapes[I] := FDyeShapeBuf[I];
    SetLength(FDyeShapeBuf, 0);
    { Appearance.FdEffects is chEverything. Batch remove+attach into one
      ChangedAll — otherwise each Add/Delete rebuilds the whole bike+rider
      scene and NVIDIA compiles shaders on the main thread (BikeFit freeze). }
    FScene.BeginChangesSchedule;
    try
      RemoveShaderClothDye;
      for I := 0 to NSh - 1 do
      begin
        Sh := Shapes[I];
        if (Sh = nil) or (not SlotOfLiveShape(Sh, Slot)) then Continue;
        App := Sh.Appearance;
        if App = nil then Continue;
        Lb := LowerCase(DyeLabelOfShape(Sh));
        if (DyeShaderDiagStep >= 3) and (FCorrectives = nil) then
        begin
          if (Pos('finger', Lb) > 0) or
             ((Pos('arm', Lb) > 0) and (Pos('hair', Lb) = 0)) then
            AttachEff(App, csGloves, 'ClothDyeGloves');
        end;
        AttachEff(App, Slot, 'ClothDye');
        { A MixedPortrait material retains both skin and hair in the source
          atlas. It needs the hair chroma-key effect even with the new rig;
          explicit single-part materials keep their existing shader path. }
        if (DyeShaderDiagStep >= 3) and
           ((FCorrectives = nil) or (Pos('mixedportrait', Lb) > 0)) then
        begin
          if ((Pos('head', Lb) > 0) and (Pos('face', Lb) = 0)) or
             (Pos('face', Lb) > 0) then
            AttachEff(App, csHair, 'ClothDyeHair');
          if Slot <> csSkin then
            AttachEff(App, csSkin, 'ClothDyeSkin');
        end;
      end;
    finally
      FScene.EndChangesSchedule;
    end;
    StartupLog(Format('[dye] RefreshShaderClothDye step=%d attached=%d',
      [DyeShaderDiagStep, AttachN]));
  finally
    FDyeShBusy := False;
  end;
end;

{ ── raw CGE.Load tile / preview normalize ──────────────────────────────── }

type
  TEmbeddedAnimOff = class
    procedure Grab(Node: TX3DNode);
  end;

procedure TEmbeddedAnimOff.Grab(Node: TX3DNode);
var
  TS: TTimeSensorNode;
begin
  if not (Node is TTimeSensorNode) then Exit;
  TS := TTimeSensorNode(Node);
  TS.Enabled := False;
  TS.Loop := False;
end;

procedure DisableEmbeddedAnimations(AScene: TCastleScene);
var
  Off: TEmbeddedAnimOff;
begin
  if AScene = nil then Exit;
  AScene.AutoAnimation := '';
  try
    AScene.StopAnimation;
  except
  end;
  if AScene.RootNode <> nil then
  begin
    Off := TEmbeddedAnimOff.Create;
    try
      AScene.RootNode.EnumerateNodes(TTimeSensorNode, @Off.Grab, false);
    finally
      Off.Free;
    end;
  end;
  try
    AScene.ResetAnimationState;
  except
  end;
end;

procedure PrepareRiderPreviewScene(AScene: TCastleScene);
const
  MarkerNames: array[0..4] of string = (
    'BottomContact', 'BoatClipseR', 'BoatClipseL', 'ArmContactR', 'ArmContactL');
  HeadNames: array[0..2] of string = ('Head', 'NeckTwist02', 'NeckTwist01');
var
  BodySkin: TSkinNode;
  ArmS, IbmS, S: Single;
  I, K: Integer;
  N: TX3DNode;
  Helmet, Head, ArmNode: TTransformNode;
  M, HeadW, HelmW, InvHead, Local: TMatrix4;
  LocT, LocS: TVector3;
  LocR: TVector4;
  HelmetBound: Boolean;

  function FindBodySkin(Node: TX3DNode): TSkinNode;
  var
    J: Integer;
    SN: TSkinNode;
  begin
    Result := nil;
    if Node = nil then Exit;
    if Node is TSkinNode then
    begin
      SN := TSkinNode(Node);
      if (SN.FdShapes.Count > 0) and (SN.FdJoints.Count >= 15) then
        Exit(SN);
      Result := FindBodySkin(SN.Skeleton);
      if Result <> nil then Exit;
    end;
    if Node is TAbstractGroupingNode then
      for J := 0 to TAbstractGroupingNode(Node).FdChildren.Count - 1 do
      begin
        Result := FindBodySkin(TAbstractGroupingNode(Node).FdChildren[J]);
        if Result <> nil then Exit;
      end;
  end;

  function MatColLen(const Mat: TMatrix4): Single;
  begin
    Result := Sqrt(Sqr(Mat.Data[0, 0]) + Sqr(Mat.Data[1, 0]) + Sqr(Mat.Data[2, 0]));
  end;

  function NodeParent(Node: TX3DNode): TX3DNode;
  begin
    Result := nil;
    if (Node <> nil) and (Node.ParentFieldsCount > 0) and (Node.ParentFields[0] <> nil) then
      Result := Node.ParentFields[0].ParentNode as TX3DNode;
  end;

  function NodeLocalMat(Node: TX3DNode): TMatrix4;
  var
    T: TTransformNode;
  begin
    Result := TMatrix4.Identity;
    if not (Node is TTransformNode) then Exit;
    T := TTransformNode(Node);
    Result := TranslationMatrix(T.Translation) *
              RotationMatrixRad(T.Rotation.W, T.Rotation.X, T.Rotation.Y, T.Rotation.Z) *
              ScalingMatrix(T.Scale);
  end;

  function NodeWorldMat(Node: TX3DNode): TMatrix4;
  var
    P: TX3DNode;
    Guard: Integer;
  begin
    Result := NodeLocalMat(Node);
    P := NodeParent(Node);
    Guard := 0;
    while (P <> nil) and (Guard < 64) do
    begin
      Result := NodeLocalMat(P) * Result;
      P := NodeParent(P);
      Inc(Guard);
    end;
  end;

  function FindHeadJoint: TTransformNode;
  var
    J, H: Integer;
  begin
    Result := nil;
    if BodySkin <> nil then
      for H := 0 to High(HeadNames) do
        for J := 0 to BodySkin.FdJoints.Count - 1 do
          if (BodySkin.FdJoints[J] is TTransformNode) and
             (TTransformNode(BodySkin.FdJoints[J]).X3DName = HeadNames[H]) then
            Exit(TTransformNode(BodySkin.FdJoints[J]));
    for H := 0 to High(HeadNames) do
    begin
      N := AScene.RootNode.TryFindNodeByName(TTransformNode, HeadNames[H], false);
      if N is TTransformNode then
        Exit(TTransformNode(N));
    end;
  end;

  procedure BindHelmetToHead;
  var
    P: TX3DNode;
    PG: TAbstractGroupingNode;
    Already: Boolean;
  begin
    if (Helmet = nil) or (Head = nil) then Exit;
    Already := False;
    P := NodeParent(Helmet);
    while P <> nil do
    begin
      if P = Head then begin Already := True; Break; end;
      P := NodeParent(P);
    end;
    if Already then Exit;

    HeadW := NodeWorldMat(Head);
    HelmW := NodeWorldMat(Helmet);
    if not HeadW.TryInverse(InvHead) then Exit;
    Local := InvHead * HelmW;
    MatrixDecompose(Local, LocT, LocR, LocS);

    Head.AddChildren(Helmet);
    P := NodeParent(Helmet);
    { Remove from every parent except Head (AddChildren may have left the old one). }
    K := Helmet.ParentFieldsCount - 1;
    while K >= 0 do
    begin
      if (Helmet.ParentFields[K] <> nil) and
         (Helmet.ParentFields[K].ParentNode is TAbstractGroupingNode) then
      begin
        PG := TAbstractGroupingNode(Helmet.ParentFields[K].ParentNode);
        if PG <> Head then
          PG.RemoveChildren(Helmet);
      end;
      Dec(K);
    end;
    Helmet.Translation := LocT;
    Helmet.Rotation := LocR;
    Helmet.Scale := LocS;
    HelmetBound := True;
  end;

begin
  if (AScene = nil) or (AScene.RootNode = nil) then Exit;
  AScene.ProcessEvents := True;
  DisableEmbeddedAnimations(AScene);
  HelmetBound := False;
  Helmet := nil;
  Head := nil;

  BodySkin := FindBodySkin(AScene.RootNode);
  { Rest-pose joint matrices so CGE actually GPU-skins the 1 m mesh. Without
    this, a glb with 0 animations stays unskinned (small body). }
  if BodySkin <> nil then
  begin
    BodySkin.AnimationSamplingForBox := 0;
    BodySkin.InternalUpdateSkin(AScene);
    if (BodySkin.FdJoints.Count > 0) and (BodySkin.FdJoints[0] is TTransformNode) then
    begin
      { CGE skips skin update when rotations are unchanged. Nudge so the
        rest matrices exist before the first FitCamera. }
      Head := TTransformNode(BodySkin.FdJoints[0]);
      LocR := Head.Rotation;
      Head.FdRotation.Send(Vector4(LocR.X, LocR.Y, LocR.Z, LocR.W + 1e-4));
      Head.FdRotation.Send(LocR);
      BodySkin.InternalUpdateSkin(AScene);
      Head := nil;
    end;
  end;

  N := AScene.RootNode.TryFindNodeByName(TTransformNode, 'Helmet', false);
  if N is TTransformNode then Helmet := TTransformNode(N);
  Head := FindHeadJoint;

  ArmS := 1.0;
  ArmNode := nil;
  N := AScene.RootNode.TryFindNodeByName(TTransformNode, 'Armature', false);
  if N is TTransformNode then
  begin
    ArmNode := TTransformNode(N);
    ArmS := ArmNode.Scale.X;
    if ArmS < 1e-3 then ArmS := 1.0;
  end;

  IbmS := 1.0;
  if (BodySkin <> nil) and (BodySkin.FdInverseBindMatrices.Items <> nil)
     and (BodySkin.FdInverseBindMatrices.Items.Count > 0) then
  begin
    M := BodySkin.FdInverseBindMatrices.Items.L[0];
    IbmS := MatColLen(M);
    if IbmS < 1e-3 then IbmS := 1.0;
  end;

  { Fold Armature.Scale into Scene.Scale and put bones in 1 m space. Then
    helmet (authored in metres) is compensated and parented to Head in the
    same space — first-frame bbox matches the visible figure, including
    glbs with embedded clips. fema IBM already cancels armature — skip. }
  S := 1.0;
  if (ArmS > 1.05) and (IbmS > 0.85) then
    S := ArmS;
  if S > 1.05 then
  begin
    if ArmNode <> nil then
      ArmNode.Scale := Vector3(1, 1, 1);
    if Helmet <> nil then
    begin
      Helmet.Translation := Helmet.Translation * (1.0 / S);
      Helmet.Scale := Helmet.Scale * (1.0 / S);
    end;
    AScene.Scale := Vector3(S, S, S);
  end;

  { File clips drive Head via joint deltas — parent Helmet under Head so it
    follows without CGE PlayAnimation. }
  BindHelmetToHead;

  { Dummy 1-joint contact armatures have no mesh but their origins sit at
    authored (scaled) metres and can pull the tile bbox up/sideways. }
  for I := 0 to High(MarkerNames) do
  begin
    N := AScene.RootNode.TryFindNodeByName(TTransformNode, MarkerNames[I], false);
    if N is TTransformNode then
      TTransformNode(N).Scale := Vector3(0, 0, 0);
  end;

  { Mixamo / Tripo face +Z; the tile camera looks +Z and saw their backs. }
  AScene.Rotation := Vector4(0, 1, 0, Pi);
end;

function DefaultRiderClipDir: string;
begin
  Result := URIToFilenameSafe('castle-data:/avatars/motion/');
end;

function ListRiderFileClips(const ADir: string; ADest: TStrings): Integer;
var
  Rec: TSearchRec;
  Code: Integer;
  Slug: string;
begin
  Result := 0;
  if ADest = nil then Exit;
  if (ADir = '') or (not DirectoryExists(ADir)) then Exit;
  Code := FindFirst(IncludeTrailingPathDelimiter(ADir) + '*.glb', faAnyFile, Rec);
  try
    while Code = 0 do
    begin
      if (Rec.Attr and faDirectory) = 0 then
      begin
        Slug := ChangeFileExt(Rec.Name, '');
        if Slug <> '' then
        begin
          ADest.Add(Slug);
          Inc(Result);
        end;
      end;
      Code := FindNext(Rec);
    end;
  finally
    FindClose(Rec);
  end;
  if ADest is TStringList then
    TStringList(ADest).Sort;
end;

destructor TTripoGlbPrepared.Destroy;
begin
  FreeAndNil(Root);
  FreeAndNil(Rig);
  inherited;
end;

constructor TTripoGlbWorker.Create(const APath: string);
begin
  inherited Create(True);
  FPath := APath;
  FreeOnTerminate := False;
  Start;
end;

destructor TTripoGlbWorker.Destroy;
begin
  WaitFor;
  FreeAndNil(Prepared);
  inherited;
end;

procedure TTripoGlbWorker.Execute;
var
  Url, FsPath: string;
begin
  Prepared := TTripoGlbPrepared.Create;
  FsPath := ResolveGlbFilesystemPath(FPath);
  Prepared.Path := FsPath;
  try
    Url := FsPath;
    if Pos('://', Url) = 0 then
      Url := FilenameToURISafe(FsPath);
    Prepared.Root := LoadNode(Url);
    Prepared.Rig := TTripoRig.Create;
    if not Prepared.Rig.LoadFromFile(FsPath) then
    begin
      Prepared.Error := 'rig parse failed';
      Prepared.Ok := False;
      Exit;
    end;
    Prepared.Ok := Prepared.Root <> nil;
    if not Prepared.Ok then
      Prepared.Error := 'LoadNode returned nil';
  except
    on E: Exception do
    begin
      Prepared.Error := E.ClassName + ': ' + E.Message;
      Prepared.Ok := False;
    end;
  end;
end;

type
  TRigParseThread = class(TThread)
  public
    Path: string;
    Rig: TTripoRig;
    Ok: Boolean;
    procedure Execute; override;
  end;

constructor TTripoRiderBuildWorker.Create(const APath: string);
begin
  inherited Create(True);   { suspended: caller заполняет Dye* и зовёт Start }
  FPath := APath;
  FreeOnTerminate := False;
  Rider := nil;
end;

destructor TTripoRiderBuildWorker.Destroy;
begin
  WaitFor;
  FreeAndNil(Rider);   { если результат не забрали на главном потоке }
  inherited;
end;

procedure TTripoRiderBuildWorker.Execute;
var
  Url, FsPath: string;
  Prep: TTripoGlbPrepared;
  R: TTripoRiderScene;
  S: TClothSlot;
begin
  FsPath := ResolveGlbFilesystemPath(FPath);
  Prep := TTripoGlbPrepared.Create;
  try
    Prep.Path := FsPath;
    try
      Url := FsPath;
      if Pos('://', Url) = 0 then
        Url := FilenameToURISafe(FsPath);
      Prep.Root := LoadNode(Url);
      Prep.Rig := TTripoRig.Create;
      if not Prep.Rig.LoadFromFile(FsPath) then
      begin
        Error := 'rig parse failed';
        Exit;
      end;
      if Prep.Root = nil then
      begin
        Error := 'LoadNode returned nil';
        Exit;
      end;
      Prep.Ok := True;
      R := TTripoRiderScene.Create;
      R.ClothDyeMode := DyeMode;
      for S := Low(TClothSlot) to High(TClothSlot) do
      begin
        R.ClothColor[S] := DyeColor[S];
        if DyeActive[S] then
          R.StageClothColor(S, DyeColor[S]);
      end;
      { запечка текстур — внутри LoadPrepared (FDyeInLoad=True), всё CPU }
      if not R.LoadPrepared(Prep) then
      begin
        Error := R.LastError;
        R.Free;
        Exit;
      end;
      Rider := R;
    except
      on E: Exception do
        Error := E.ClassName + ': ' + E.Message;
    end;
  finally
    Prep.Free;   { Root/Rig при успехе украдены LoadPrepared }
  end;
end;

procedure TRigParseThread.Execute;
begin
  Rig := TTripoRig.Create;
  Ok := Rig.LoadFromFile(Path);
  if not Ok then
    FreeAndNil(Rig);
end;

function TTripoRiderScene.LoadGlb(const AFileName: string; Log: TStrings): Boolean;
var
  RigErr: TStringList;
  I, NJ, NameMismatch: Integer;
  N: TX3DNode;
  TN: TTransformNode;
  L: TDirectionalLightNode;
  S: string;        { helmet diag line }
  BindVia: string;  { diagnostics: how the joints were bound }
  RigTh: TRigParseThread;
  Path: string;
begin
  FreeAndNil(FCorrectives);
  Result := False;
  FLoaded := False; FResolved := 0; FSkin := nil; SetLength(FSkinList, 0);
  StopFileClip;
  ApplyBikeAlignedSpace;
  FBaseOrientDone := False;
  FHasPose := False; FPoseAnimating := False; FPoseElapsed := 0; FPoseDur := 0;
  FBaseOrientQ.X := 0; FBaseOrientQ.Y := 0; FBaseOrientQ.Z := 0; FBaseOrientQ.W := 1;
  FLastError := '';
  FNativeRestH := 0;
  FBodyHeightF := 0;
  FBodyMorphed := False;
  FHelmetRest0Ok := False;
  FHelmetNode := nil;
  FHelmetMatsCached := False;
  SetLength(FHelmetMats, 0);
  SetLength(FHelmetOrigColor, 0);
  FShapeCached := False;
  FBonesCached := False;
  ResetDyeCache;

  Path := ResolveGlbFilesystemPath(AFileName);
  { Raw OS paths get a friendly existence check; remaining URIs (file://,
    http://) are left for FScene.Load, which resolves CGE's virtual filesystem. }
  if (Pos('://', Path) = 0) and (not FileExists(Path)) then
  begin
    FLastError := 'File not found: ' + Path;
    if Log <> nil then Log.Add(FLastError);
    Exit;
  end;

  { 1. CGE loads the glb (main thread — GL/textures). Parse the same file's
       skeleton on a worker so the second GLB walk is not sequential. }
  RigTh := TRigParseThread.Create(True);
  RigTh.FreeOnTerminate := False;
  RigTh.Path := Path;
  RigTh.Start;
  try
    ResetGroundShadeEffect;
    FScene.Load(Path);
  except
    on E: Exception do
    begin
      RigTh.WaitFor;
      FreeAndNil(RigTh);
      FLastError := 'CGE could not load the file (' + E.ClassName + '): ' + E.Message;
      if Log <> nil then Log.Add(FLastError);
      Exit;
    end;
  end;
  RigTh.WaitFor;
  if RigTh.Ok and (RigTh.Rig <> nil) then
  begin
    FRig.Free;
    FRig := RigTh.Rig;
    RigTh.Rig := nil;
  end;
  FreeAndNil(RigTh);
  Result := FinishLoadAfterGraph(Path, Log);
end;

function TTripoRiderScene.LoadPrepared(APrep: TTripoGlbPrepared; Log: TStrings): Boolean;
var
  TD0: QWord;
begin
  FreeAndNil(FCorrectives);
  FHelmetNode := nil;
  FHelmetMatsCached := False;
  SetLength(FHelmetMats, 0);
  SetLength(FHelmetOrigColor, 0);
  Result := False;
  FLoaded := False; FResolved := 0; FSkin := nil; SetLength(FSkinList, 0);
  StopFileClip;
  ApplyBikeAlignedSpace;
  FBaseOrientDone := False;
  FHasPose := False; FPoseAnimating := False; FPoseElapsed := 0; FPoseDur := 0;
  FBaseOrientQ.X := 0; FBaseOrientQ.Y := 0; FBaseOrientQ.Z := 0; FBaseOrientQ.W := 1;
  FLastError := '';
  FNativeRestH := 0;
  FBodyHeightF := 0;
  FBodyMorphed := False;
  FHelmetRest0Ok := False;
  FShapeCached := False;
  ResetDyeCache;
  if (APrep = nil) or (not APrep.Ok) or (APrep.Root = nil) then
  begin
    if (APrep <> nil) then
      FLastError := APrep.Error
    else
      FLastError := 'prepared glb is nil';
    Exit;
  end;
  try
    TD0 := GetTickCount64;
    ResetGroundShadeEffect;
    FScene.Load(APrep.Root, True);
    StartupLog(Format('[dye] LoadPrepared: Scene.Load %d ms', [GetTickCount64 - TD0]));
  except
    on E: Exception do
    begin
      FLastError := 'LoadPrepared: ' + E.ClassName + ' ' + E.Message;
      Exit;
    end;
  end;
  APrep.Root := nil;
  if APrep.Rig <> nil then
  begin
    FRig.Free;
    FRig := APrep.Rig;
    APrep.Rig := nil;
  end;
  Result := FinishLoadAfterGraph(APrep.Path, Log);
end;

{ ── IBL-подобный ambient для PBR-райдера ──

  PBR в CGE игнорирует AmbientIntensity, а environment-карты у сцены нет —
  поэтому раньше купол directional-филлов имитировал ambient. Но у каждого
  направленного источника свой жёсткий терминатор: любая складка геометрии
  ловит 2–3 границы свет/тень, вогнутости теряют сразу несколько источников —
  «лишние тени и складки» на модели, которая во вьюверах (там IBL) чиста.

  TEnvironmentLightNode для PhysicalMaterial работает иначе: light_dir :=
  normal_eye, NdotL = 1, diffuse-вклад умножается на diffuseTexture(N) —
  мягкий ambient по нормали, как IBL. Кубмап — нейтральная студия (небо/земля),
  6 граней генерируются в память (TPixelTextureNode, без файлов на диске).

  RiderUseIbl = False возвращает старый купол (A/B-сравнение). }
const
  RiderUseIbl: Boolean = True;
  { Pure-IBL (как в Babylon Sandbox): окружение — главный источник, ключи
    почти нулевые. Калибровка свипом через MCP avatar.lighting (один запуск):
    grad 1.91 vs 2.40 у старого лука; env 16+ растёт только выбой.
    Дефолт 3 (выбор пользователя): мягкий ambient без выбоя.
    ВАЖНО: имя НЕ должно совпадать со свойством RiderEnvIntensity — иначе
    внутри методов класса свойство затеняет константу и геттер читает
    ещё-не-созданный FEnvLight (даёт 0). }
  RiderEnvDefault: Single = 3.0;

{ ── Общий файл освещения райдера (пишет редактор, читают редактор и игра) ──

  rider_lighting.json в data-каталоге игры:
    {"env": 3.0, "key": 0.6, "fill": 0.4, "rkey": 0.5, "rfill": 0.3}
    env        — IBL-ambient райдера (свет 'RiderEnv')
    key/fill   — направленная пара вьюпорта (ключ/заполнение)
    rkey/rfill — направленная пара сцены райдера (RiderKey/RiderFill)
  Редактор сохраняет при каждом ApplyLighting (UI и MCP), игра и редактор
  применяют при старте/загрузке райдера. }
function RiderLightingFile: string;
begin
  Result := URIToFilenameSafe('castle-data:/rider_lighting.json');
end;

procedure SaveRiderLighting(const Env, Key, Fill, RKey, RFill: Single);
var
  O: TJSONObject;
  SL: TStringList;
begin
  O := TJSONObject.Create;
  try
    O.Add('env', Double(Env));
    O.Add('key', Double(Key));
    O.Add('fill', Double(Fill));
    O.Add('rkey', Double(RKey));
    O.Add('rfill', Double(RFill));
    ForceDirectories(ExtractFilePath(RiderLightingFile));
    SL := TStringList.Create;
    try
      SL.Text := O.AsJSON;
      SL.SaveToFile(RiderLightingFile);
    finally
      SL.Free;
    end;
  finally
    O.Free;
  end;
end;

procedure LoadRiderLighting(out Env, Key, Fill, RKey, RFill: Single);
var
  D: TJSONData;
  O: TJSONObject;
  SL: TStringList;
begin
  { дефолты = откалиброванный pure-IBL лук }
  Env := RiderEnvDefault;
  Key := 0.6;
  Fill := 0.4;
  RKey := 0.5;
  RFill := 0.3;
  if not FileExists(RiderLightingFile) then Exit;
  SL := TStringList.Create;
  try
    try
      SL.LoadFromFile(RiderLightingFile);
      D := GetJSON(SL.Text);
      try
        if D is TJSONObject then
        begin
          O := TJSONObject(D);
          if O.Find('env') <> nil then Env := O.Get('env', Double(Env));
          if O.Find('key') <> nil then Key := O.Get('key', Double(Key));
          if O.Find('fill') <> nil then Fill := O.Get('fill', Double(Fill));
          if O.Find('rkey') <> nil then RKey := O.Get('rkey', Double(RKey));
          if O.Find('rfill') <> nil then RFill := O.Get('rfill', Double(RFill));
        end;
      finally
        D.Free;
      end;
    except
      { битый файл — работаем на дефолтах }
    end;
  finally
    SL.Free;
  end;
end;

function TTripoRiderScene.BuildRiderEnvLight: TEnvironmentLightNode;

  function FaceImage(const CSky, CGround: TVector3Byte): TPixelTextureNode;
  const
    S = 64;
  var
    Img: TRGBImage;
    X, Y, K: Integer;
    P: PVector3Byte;
  begin
    Img := TRGBImage.Create(S, S);
    for Y := 0 to S - 1 do
      for X := 0 to S - 1 do
      begin
        K := (Y * 255) div (S - 1);   { 0 = низ грани, 255 = верх }
        P := Img.PixelPtr(X, Y);
        P^.X := (CGround.X * (255 - K) + CSky.X * K) div 255;
        P^.Y := (CGround.Y * (255 - K) + CSky.Y * K) div 255;
        P^.Z := (CGround.Z * (255 - K) + CSky.Z * K) div 255;
      end;
    Result := TPixelTextureNode.Create;
    Result.FdImage.Value := Img;
  end;

  function BuildCube: TComposedCubeMapTextureNode;
  const
    { Мягкая студия-«лайтбокс» (как environmentSpecular.env в Babylon):
      почти равномерное окружение с лёгким затемнением к полу. }
    CSkyTop: TVector3Byte    = (X: 228; Y: 231; Z: 238);
    CSkySide: TVector3Byte   = (X: 228; Y: 231; Z: 238);
    CGroundSide: TVector3Byte = (X: 165; Y: 167; Z: 162);
    CGroundBot: TVector3Byte = (X: 155; Y: 157; Z: 153);
  begin
    Result := TComposedCubeMapTextureNode.Create;
    Result.FdRight.Value  := FaceImage(CSkySide, CGroundSide);
    Result.FdLeft.Value   := FaceImage(CSkySide, CGroundSide);
    Result.FdTop.Value    := FaceImage(CSkyTop, CSkyTop);
    Result.FdBottom.Value := FaceImage(CGroundBot, CGroundBot);
    Result.FdFront.Value  := FaceImage(CSkySide, CGroundSide);
    Result.FdBack.Value   := FaceImage(CSkySide, CGroundSide);
  end;

begin
  Result := TEnvironmentLightNode.Create;
  Result.X3DName := 'RiderEnv';
  Result.Global := False;   { локальный: только поддерево райдера }
  Result.Color := Vector3(1.0, 1.0, 1.0);
  Result.Intensity := RiderEnvDefault;
  Result.FdDiffuseTexture.Value := BuildCube;
  { Specular-сэмплер обязан быть задан (uniform в шейдере безусловный);
    при roughness 0.9 его вклад почти нулевой, кубмап та же. }
  Result.FdSpecularTexture.Value := BuildCube;
end;

function TTripoRiderScene.GetRiderEnvIntensity: Single;
begin
  if FEnvLight <> nil then
    Result := FEnvLight.Intensity
  else
    Result := 0.0;
end;

procedure TTripoRiderScene.SetRiderEnvIntensity(const V: Single);
begin
  if FEnvLight <> nil then
    FEnvLight.Intensity := V;   { intensity — per-frame uniform, без ChangedAll }
end;

function TTripoRiderScene.GetRiderKeyIntensity: Single;
begin
  if FRiderKeyLight <> nil then
    Result := FRiderKeyLight.Intensity
  else
    Result := 0.0;
end;

procedure TTripoRiderScene.SetRiderKeyIntensity(const V: Single);
begin
  if FRiderKeyLight <> nil then
    FRiderKeyLight.Intensity := V;
end;

function TTripoRiderScene.GetRiderFillIntensity: Single;
begin
  if FRiderFillLight <> nil then
    Result := FRiderFillLight.Intensity
  else
    Result := 0.0;
end;

procedure TTripoRiderScene.SetRiderFillIntensity(const V: Single);
begin
  if FRiderFillLight <> nil then
    FRiderFillLight.Intensity := V;
end;

function TTripoRiderScene.LightDiag: String;
var
  I: Integer;
  Ch: TX3DNode;
begin
  FDiagBuf := TStringList.Create;
  try
    if (FScene = nil) or (FScene.RootNode = nil) then
      FDiagBuf.Add('scene=nil')
    else
    begin
      { указатель env: nil / мёртвый / живой }
      if FEnvLight = nil then
        FDiagBuf.Add('envField=nil')
      else
      try
        FDiagBuf.Add(Format('envField=%s int=%.2f',
          [FEnvLight.ClassName, FEnvLight.Intensity]));
      except
        on E: Exception do
          FDiagBuf.Add('envField=DANGLING(' + E.ClassName + ')');
      end;
      { прямые дети корня — имя:класс }
      for I := 0 to FScene.RootNode.FdChildren.Count - 1 do
      begin
        Ch := FScene.RootNode.FdChildren[I];
        try
          FDiagBuf.Add(Format('root[%d]=%s:%s', [I, Ch.X3DName, Ch.ClassName]));
        except
          on E: Exception do
            FDiagBuf.Add(Format('root[%d]=DEAD(%s)', [I, E.ClassName]));
        end;
      end;
      { все света в графе — с защитой на каждый узел }
      FScene.RootNode.EnumerateNodes(TAbstractLightNode, {$ifdef FPC}@{$endif}GrabDiagLight, False);
    end;
    Result := FDiagBuf.CommaText;
  finally
    FreeAndNil(FDiagBuf);
  end;
end;

procedure TTripoRiderScene.GrabDiagLight(Node: TX3DNode);
begin
  try
    if Node is TAbstractLightNode then
      FDiagBuf.Add(Format('%s:%s=%.2f', [Node.X3DName, Node.ClassName,
        TAbstractLightNode(Node).Intensity]))
    else
      FDiagBuf.Add('notlight:' + Node.ClassName);
  except
    on E: Exception do
      FDiagBuf.Add('dead-node(' + E.ClassName + ')');
  end;
end;

function TTripoRiderScene.FinishLoadAfterGraph(const AFileName: string; Log: TStrings): Boolean;
var
  RigErr: TStringList;
  I, NJ, NameMismatch: Integer;
  N: TX3DNode;
  TN: TTransformNode;
  L: TDirectionalLightNode;
  LSavedEnv, LSavedKey, LSavedFill, LSavedRKey, LSavedRFill: Single;
  S: string;
  BindVia: string;
  TD1: QWord;
begin
  Result := False;
  FDyeSourcePath := AFileName;   { ключ геом. кэша покраски (маски/тон кожи) }
  { старые световые узлы умрут со старым графом сцены }
  FEnvLight := nil;
  FRiderKeyLight := nil;
  FRiderFillLight := nil;
  DisableEmbeddedAnimations(FScene);
  { Skinning recomputes per render traversal; events let joint-rotation changes
    invalidate the cached transforms so the skin follows. }
  FScene.ProcessEvents := True;

  { GPU-скин: bbox шейпа считается из rest-геометрии и НЕ учитывает повороты
    костей. В позе на байке отрендеренный меш уходит далеко от rest-bbox, и
    frustum culling глушил ВЕСЬ райдер целиком — старый баг «после Делить
    (или иногда просто так) пропадает меш, остаются шары костей, save+open
    возвращает». Для одиночной сцены райдера culling ничего не экономит —
    выключаем оба уровня (в игре GameMcpServer делал то же самое вручную). }
  FScene.ShapeFrustumCulling := False;
  FScene.SceneFrustumCulling := False;
  { Occlusion recovery also tests per-part CPU boxes. Once the rest-pose
    legs leave the screen, those boxes cannot recover the visible posed
    thighs. Applies to MEN/FEM and every local/remote rider at load time. }
  FScene.SceneOcclusionCulling := False;

  { Pure-IBL лук (как в Babylon-вьюверах): яркий environment + ACES
    тонмаппинг, который сжимает света и не даёт выбоя на светлых тканях.
    Без ACES яркий IBL клиппит (пиксель-тест: env12 = 8% кадра в белом).
    ToneMapping — глобальная настройка движка (CastleRenderOptions);
    мир OSM рисуется своим шейдером и её не получает. }
  CastleRenderOptions.ToneMapping := tmACES;

  { 1b. The bike's lights are scoped to the bike scenes; this separate rider
        scene would render unlit (black). Inject its own key+fill directional
        lights. ВАЖНО: НЕ Global — локальная область (своё поддерево = весь
        райдер); в единой сцене байка глобальные света райдера попадали в
        light-лист catcher'а и ломали сэмплинг теневой карты BikeShadowSun
        (тень пропадала полностью).
        После MountBikeIntoRider света должны оставаться ПРЯМЫМИ детьми Root
        (не уходить в RiderVis switch) — см. BikeParametric.MountBikeIntoRider. }
  if FScene.RootNode <> nil then
  begin
    L := TDirectionalLightNode.Create;
    L.X3DName := 'RiderKey';
    L.Direction := Vector3(-0.35, -0.75, -0.45);
    L.Color := Vector3(1.0, 0.98, 0.94);
    { Pure-IBL: окружение даёт основной свет; ключ — лишь лёгкий намёк
      на направленность (как слабое «окно» в студии). }
    L.Intensity := 0.5; L.AmbientIntensity := 0.55; L.Global := False;
    FScene.RootNode.AddChildren(L);
    FRiderKeyLight := L;
    L := TDirectionalLightNode.Create;
    L.X3DName := 'RiderFill';
    L.Direction := Vector3(0.55, -0.15, 0.65);
    L.Color := Vector3(0.88, 0.93, 1.0);
    L.Intensity := 0.3; L.AmbientIntensity := 0.4; L.Global := False;
    FScene.RootNode.AddChildren(L);
    FRiderFillLight := L;

    { IBL-замена купола филлов (RiderUseIbl): EnvironmentLight даёт PBR
      diffuse-ambient по нормали (glTF-Sample-Viewer style: light_dir = normal,
      NdotL = 1, вклад умножается на diffuseTexture(N)) — мягкое затекание
      света в вогнутости, как HDR-окружение во вьюверах. Направленный купол
      из 6 филлов (ветка else) давал каждой складке по несколько жёстких
      терминаторов — «лишние тени и складки» на модели. Локальный (Global :=
      False): светит только поддерево райдера, не байк и не catcher. }
    if RiderUseIbl then
    begin
      FEnvLight := BuildRiderEnvLight;
      FScene.RootNode.AddChildren(FEnvLight);
    end else
    begin
    { The glTF rider uses PBR materials. In CGE, PBR IGNORES a light's AmbientIntensity, and
      there is no environment map here — a standard glTF viewer lights the model with an HDR
      environment (that is why it looks evenly lit there but dark here). So the two lights
      above leave every surface facing away from them unlit. Add a small DOME of dim fills
      from the remaining directions to approximate that environment ambient — PBR does
      respond to real lights. Локальные (Global := False): светят только на своё
      поддерево (райдера), не двойная подсветка байка и не ломают shadow map. }
    L := TDirectionalLightNode.Create; L.X3DName := 'RiderFillFront';
    L.Direction := Vector3(0.0, -0.25, -1.0);
    L.Color := Vector3(1.0, 0.98, 0.95); L.Intensity := 0.75; L.Global := False;
    FScene.RootNode.AddChildren(L);
    L := TDirectionalLightNode.Create; L.X3DName := 'RiderFillBack';
    L.Direction := Vector3(0.0, -0.15, 1.0);
    L.Color := Vector3(0.85, 0.9, 1.0); L.Intensity := 0.65; L.Global := False;
    FScene.RootNode.AddChildren(L);
    L := TDirectionalLightNode.Create; L.X3DName := 'RiderFillLeft';
    L.Direction := Vector3(1.0, -0.2, 0.15);
    L.Color := Vector3(0.95, 0.96, 1.0); L.Intensity := 0.65; L.Global := False;
    FScene.RootNode.AddChildren(L);
    L := TDirectionalLightNode.Create; L.X3DName := 'RiderFillRight';
    L.Direction := Vector3(-1.0, -0.2, 0.15);
    L.Color := Vector3(0.95, 0.96, 1.0); L.Intensity := 0.65; L.Global := False;
    FScene.RootNode.AddChildren(L);
    L := TDirectionalLightNode.Create; L.X3DName := 'RiderFillUnder';
    L.Direction := Vector3(0.0, 1.0, 0.0);
    L.Color := Vector3(0.7, 0.78, 0.65); L.Intensity := 0.5; L.Global := False;
    FScene.RootNode.AddChildren(L);
    { soft top sky bounce — reduces hard skull/shoulder caps under high camera }
    L := TDirectionalLightNode.Create; L.X3DName := 'RiderFillTop';
    L.Direction := Vector3(0.15, -1.0, 0.1);
    L.Color := Vector3(0.92, 0.95, 1.0); L.Intensity := 0.55; L.Global := False;
    FScene.RootNode.AddChildren(L);
    end;

    { Свет из rider_lighting.json (пишет редактор; дефолт — pure-IBL лук).
      Перекрывает константные интенсивности env/key/fill. }
    LoadRiderLighting(LSavedEnv, LSavedKey, LSavedFill, LSavedRKey, LSavedRFill);
    if FEnvLight <> nil then
      FEnvLight.Intensity := LSavedEnv;
    if FRiderKeyLight <> nil then
      FRiderKeyLight.Intensity := LSavedRKey;
    if FRiderFillLight <> nil then
      FRiderFillLight.Intensity := LSavedRFill;
    StartupLog(Format('[light] saved lighting applied: env=%.2f rkey=%.2f rfill=%.2f (viewport key/fill %.2f/%.2f)',
      [LSavedEnv, LSavedRKey, LSavedRFill, LSavedKey, LSavedFill]));

    FScene.ChangedAll;
  end;

  { 2. Skeleton metadata — already filled by the worker when it succeeded. }
  if FRig.JointCount <= 0 then
  begin
    RigErr := TStringList.Create;
    try
      if not FRig.LoadFromFile(AFileName, RigErr) then
      begin
        FLastError := 'Skeleton/rig could not be parsed from the glb. ' + Trim(RigErr.Text);
        if Log <> nil then
        begin
          Log.Add('TripoRig parse failed:');
          Log.AddStrings(RigErr);
        end;
        Exit;
      end;
    finally
      RigErr.Free;
    end;
  end;

  { 3. Collect every Skin node CGE built and pick the one whose joint palette
       matches FRig — i.e. the skin of the first skinned primitive, the very
       skin CGE GPU-skins. A glb can carry SEVERAL armatures (e.g. an orphan
       leftover rig exported next to the real one); only the mesh-driving one
       may be bound. }
  if FScene.RootNode <> nil then
    FScene.RootNode.EnumerateNodes(TSkinNode, @GrabSkin, false);
  FSkin := SelectSkinForRig;
  FCorrectives := TRiderPoseCorrectives.Create;
  if not FCorrectives.Load(AFileName, FScene, FSkin, FRig) then
    FreeAndNil(FCorrectives);
  ApplyJerseyHemDepthBias;

  { 4. Bind each palette joint to its CGE TTransformNode and capture its rest
       (bind) local rotation.

       PRIMARY: straight from the matched Skin node's joints list. FdJoints
       holds the EXACT TTransformNode instances of the armature that skins the
       mesh, in palette order (x3dloadinternalgltf: SkinNode.FdJoints[I] :=
       Nodes[Skin.Joints[I]]), so duplicate bone names cannot hijack the
       binding. The old global name search (FScene.Node by name) returned the
       FIRST node called "Root"/"Hip"/... anywhere in the scene: a glb that
       also carried an orphan second armature with the same bone names bound
       every joint to that dead skeleton — "resolved 42/42", zero motion on
       the mesh.

       FALLBACK (no Skin node matched the palette — e.g. CGE rejected the skin
       with a warning, or an exotic exporter): the old global name search. }
  SetLength(FJointNode, FRig.JointCount);
  SetLength(FRestRot, FRig.JointCount);
  for I := 0 to FRig.JointCount - 1 do
  begin
    FJointNode[I] := nil;
    FRestRot[I] := Vector4(0, 0, 1, 0);
  end;
  NameMismatch := 0;
  BindVia := '';
  if FSkin <> nil then
  begin
    BindVia := Format('Skin "%s" joints (palette order)', [FSkin.X3DName]);
    NJ := Min(FSkin.FdJoints.Count, FRig.JointCount);
    for I := 0 to NJ - 1 do
      if FSkin.FdJoints[I] is TTransformNode then
      begin
        TN := TTransformNode(FSkin.FdJoints[I]);
        FJointNode[I] := TN;
        FRestRot[I] := TN.Rotation;
        Inc(FResolved);
        if TN.X3DName <> FRig.JointName[I] then Inc(NameMismatch);
      end;
  end;
  if FResolved = 0 then
  begin
    BindVia := 'global name search (no Skin node matched the palette)';
    for I := 0 to FRig.JointCount - 1 do
    begin
      N := FScene.Node(TTransformNode, FRig.JointName[I], [fnNilOnMissing]);
      if not (N is TTransformNode) then
        { try original exporter aliases via scene walk }
        N := nil;
      if N is TTransformNode then
      begin
        TN := TTransformNode(N);
        FJointNode[I] := TN;
        FRestRot[I] := TN.Rotation;
        Inc(FResolved);
      end;
    end;
  end;
  { Still nothing: scan all Transform nodes, match by CanonicalJointName. }
  if FResolved = 0 then
  begin
    BindVia := 'canonical name scan';
    if FScene.RootNode <> nil then
      for I := 0 to FRig.JointCount - 1 do
      begin
        if FJointNode[I] <> nil then Continue;
        { Enumerate is heavy; use FindNode for a few known aliases only. }
        N := FScene.Node(TTransformNode, FRig.JointName[I], [fnNilOnMissing]);
        if N is TTransformNode then
        begin
          FJointNode[I] := TTransformNode(N);
          FRestRot[I] := TTransformNode(N).Rotation;
          Inc(FResolved);
        end;
      end;
  end;

  if FResolved = 0 then
  begin
    FLastError := Format(
      'The glb loaded, but none of its %d rig joints matched a node in the scene '
      + '(expected Tripo names like Pelvis, Spine, R_Thigh...). This model is '
      + 'probably rigged with different bone names or has no skinned skeleton.',
      [FRig.JointCount]);
    if Log <> nil then Log.Add(FLastError);
    Exit;
  end;

  FLoaded := True;
  ConfigureFileSpace;
  ReadDyePartNames(AFileName);
  { Body proportions and height must only inspect the avatar geometry.
    The external helmet is authored in head-local coordinates. }
  CacheShape;
  { Attach accessories before material effects so helmet and logos receive
    the same lighting/ground shading as the rider. }
  ReadHelmetPitchExtra(AFileName);
  { Anatomical assets provide authored ankle weights and pose correctives.
    The legacy boot/cuff repair must not overwrite that skinning. }
  if FCorrectives = nil then
  begin
    FreezeBootSkin;
    BindShinToBoot;
  end;
  { Цвета одежды: режим cdmTexture запекает их в baseColor-текстуру прямо
    при загрузке (glb на диске не меняется); иначе — быстрый no-op.
    Live-запечка на отображаемой GL-сцене глушит рендер (CGE не переживает
    LoadFromImage на живом GPU-скинне) — разрешена только здесь, в загрузке. }
  FDyeInLoad := True;
  try
    TD1 := GetTickCount64;
    BakeClothDye;
    StartupLog(Format('[dye] BakeClothDye total %d ms', [GetTickCount64 - TD1]));
  finally
    FDyeInLoad := False;
  end;
  { Shader dye on the rider-only graph, before the bike is mounted into
    this scene. After mount FdEffects.Add would ChangedAll the whole bike. }
  if FDyeMode = cdmShader then
  begin
    TD1 := GetTickCount64;
    RefreshShaderClothDye;
    StartupLog(Format('[dye] RefreshShaderClothDye (load) %d ms', [GetTickCount64 - TD1]));
  end;
  { Freeze visual standing height from the bind mesh × GPU rest stretch
    BEFORE limb-length edits rewrite BindWorld. }
  { Attach before GPU skin / bike mounting: no shader rebuild during riding. }
  SetGroundShade(FGroundShade);
  FNativeRestH := 0;
  RestHeight;
  FHandFreezeOk[0] := False;   { drop any stale frozen-hand orientation from a previous rig }
  FHandFreezeOk[1] := False;
  { Contact markers are NOT baked here on purpose: RiderArmLength / RiderLegLength /
    shoulder width move the end joints (and stretch the mesh), and the marker offsets
    + surface-skin weights must be measured against the FINAL geometry. The caller
    applies the limb-length / body-shape params next (ApplyLimbLengths bakes at its
    end), so the one and only bake happens after the rig is at its final proportions. }
  Result := True;

  if Log <> nil then
  begin
    Log.Add('Loaded: ' + AFileName);
    Log.Add(Format('RestHeight: %.3f m  (mesh bbox × GPU rest stretch)', [FNativeRestH]));
    if FFileNeedsYaw then
      Log.Add('File space: Mixamo (+Z face) — Scene base yaw +90° Y, IK axes in FILE')
    else
      Log.Add('File space: bike-aligned bind — Scene base yaw 0, IK axes bike');
    Log.Add(Format('Native skin: %s   palette joints: %d   resolved to nodes: %d   bound via: %s',
      [BoolToStr(FSkin <> nil, 'YES', 'no (mesh loaded WITHOUT rig?)'),
       FRig.JointCount, FResolved, BindVia]));
    if Length(FSkinList) > 1 then
      Log.Add(Format('  NOTE: scene carries %d Skin nodes — bound to the one matching the parsed palette.',
        [Length(FSkinList)]));
    if (FSkin = nil) and (Length(FSkinList) > 0) then
      Log.Add('  WARNING: Skin node(s) present but NONE matches the parsed joint palette; '
        + 'name-search binding may have hit the wrong armature.');
    if NameMismatch > 0 then
      Log.Add(Format('  NOTE: %d palette slots bound to nodes with a different name (renamed on import).',
        [NameMismatch]));
    if FResolved < FRig.JointCount then
      for I := 0 to FRig.JointCount - 1 do
        if FJointNode[I] = nil then
          Log.Add('  unresolved joint: ' + FRig.JointName[I]);
    { Shapes NOT driven by the matched skin: rigid accessories (helmet,
      bottle...) are normal here, but a full-body entry means a leftover
      UN-SKINNED duplicate of the character — it can never animate; delete
      it from the glb. }
    if (FSkin <> nil) and (FScene.RootNode <> nil) then
    begin
      FStrayShapes := TStringList.Create;
      try
        FScene.RootNode.EnumerateNodes(TShapeNode, @GrabStrayShape, false);
        if FStrayShapes.Count > 0 then
        begin
          Log.Add(Format('  NOTE: %d shape(s) are NOT driven by the skin '
            + '(rigid accessories are fine; a body-sized one is a static leftover):',
            [FStrayShapes.Count]));
          for I := 0 to FStrayShapes.Count - 1 do
            Log.Add('    ' + FStrayShapes[I]);
        end;
      finally
        FreeAndNil(FStrayShapes);
      end;
    end;
  end;

  { optional 'Helmet' accessory: capture its head-relative bind placement so
    UpdatePose can carry it with the animated head (see ApplyHelmetFollow) }
  CacheHelmet;
  if Log <> nil then
  begin
    if FHelmetNode <> nil then
    begin
      S := 'Helmet node found ("' + FHelmetNode.X3DName + '"): following joint "'
        + FRig.JointName[FHelmetHeadJ] + '" chain:';
      I := FHelmetHeadJ;
      while I >= 0 do
      begin
        S := S + ' ' + FRig.JointName[I];
        I := FRig.JointParent[I];
      end;
      Log.Add(S);
    end
    else if (FScene.RootNode.TryFindNodeByName(TTransformNode, 'Helmet', false) <> nil)
         or (FHelmetScan <> nil) then
      Log.Add('Helmet node PRESENT but not bound: no head/neck joint with a palette chain to the pelvis')
    else
      Log.Add('Helmet node: none');
  end;
end;

function TTripoRiderScene.HasNativeSkin: Boolean;
begin
  Result := FSkin <> nil;
end;

function TTripoRiderScene.SkinNode: TSkinNode;
begin
  Result := FSkin;
end;

function TTripoRiderScene.GpuContactLocal(Idx: Integer): TVector3;
begin
  { Маркера может не быть (старая модель) — тогда ноль, контакт = начало сустава. }
  if (Idx < 0) or (Idx > 3) or (not FContactValid[Idx]) then
    Exit(Vector3(0, 0, 0));
  Result := Vector3(FContactLocal[Idx].X, FContactLocal[Idx].Y, FContactLocal[Idx].Z);
end;

function TTripoRiderScene.JointIndex(const AName: string): Integer;
begin
  Result := FRig.JointIndexByName(AName);
end;

function TTripoRiderScene.JointNodeByName(const AName: string): TTransformNode;
var I: Integer;
begin
  Result := nil;
  I := FRig.JointIndexByName(AName);
  if (I >= 0) and (I < Length(FJointNode)) then Result := FJointNode[I];
end;

function TTripoRiderScene.HelmetNameExcluded(const AName: string): Boolean;
const EXCL: array[0..6] of string = ('Armature', 'BottomContact',
  'BoatClipseR', 'BoatClipseL', 'ArmContactR', 'ArmContactL', 'Bone');
var I: Integer;
begin
  for I := 0 to High(EXCL) do
    if AName = EXCL[I] then Exit(True);
  Result := FRig.JointIndexByName(AName) >= 0;   { any skin joint }
end;

{ True when the subtree under Node contains mesh geometry whose vertex count
  differs from the skinned BODY mesh (FRig.VertexCount) — i.e. an accessory
  mesh, not the rider body and not a degenerate marker. }
function TTripoRiderScene.HelmetSubtreeHasAccessoryMesh(Node: TX3DNode): Boolean;
var
  G: TAbstractGeometryNode;
  I, Cnt: Integer;
begin
  Result := False;
  if Node = nil then Exit;
  if Node is TShapeNode then
  begin
    G := TShapeNode(Node).Geometry;
    if (G is TAbstractComposedGeometryNode) and
       (TAbstractComposedGeometryNode(G).FdCoord.Value is TCoordinateNode) then
    begin
      Cnt := TCoordinateNode(TAbstractComposedGeometryNode(G).FdCoord.Value).FdPoint.Count;
      Exit((Cnt > 16) and (Cnt <> FRig.VertexCount));   { >16: skip tiny marker spheres }
    end;
    Exit;
  end;
  if Node is TAbstractGroupingNode then
    for I := 0 to TAbstractGroupingNode(Node).FdChildren.Count - 1 do
      if HelmetSubtreeHasAccessoryMesh(TAbstractGroupingNode(Node).FdChildren[I]) then
        Exit(True);
end;

{ True when the subtree under Node contains a mesh with the vertex count of
  the skinned BODY (FRig.VertexCount) — used to reject scene-level wrapper
  transforms whose subtree holds everything. }
function TTripoRiderScene.HelmetSubtreeHasBodyMesh(Node: TX3DNode): Boolean;
var
  G: TAbstractGeometryNode;
  I: Integer;
begin
  Result := False;
  if Node = nil then Exit;
  if Node is TShapeNode then
  begin
    G := TShapeNode(Node).Geometry;
    if (G is TAbstractComposedGeometryNode) and
       (TAbstractComposedGeometryNode(G).FdCoord.Value is TCoordinateNode) then
      Exit(TCoordinateNode(TAbstractComposedGeometryNode(G).FdCoord.Value).FdPoint.Count
        = FRig.VertexCount);
    Exit;
  end;
  if Node is TAbstractGroupingNode then
    for I := 0 to TAbstractGroupingNode(Node).FdChildren.Count - 1 do
      if HelmetSubtreeHasBodyMesh(TAbstractGroupingNode(Node).FdChildren[I]) then
        Exit(True);
end;

procedure TTripoRiderScene.GrabHelmetCandidate(Node: TX3DNode);
begin
  if FHelmetScan <> nil then Exit;                       { first hit wins }
  if not (Node is TTransformNode) then Exit;
  if HelmetNameExcluded(Node.X3DName) then Exit;
  if not HelmetSubtreeHasAccessoryMesh(Node) then Exit;
  { a wrapper over the whole scene also "contains" the accessory — reject
    anything whose subtree includes the body mesh as well }
  if HelmetSubtreeHasBodyMesh(Node) then Exit;
  FHelmetScan := TTransformNode(Node);
end;

procedure TTripoRiderScene.CacheHelmetMaterials;

  procedure Collect(Node: TX3DNode);
  var
    M: TX3DNode;
    I, K: Integer;
  begin
    if Node = nil then Exit;
    if Node is TShapeNode then
    begin
      if TShapeNode(Node).Appearance = nil then Exit;
      M := TShapeNode(Node).Appearance.Material;
      if (M is TPhysicalMaterialNode) or (M is TUnlitMaterialNode) then
      begin
        for K := 0 to High(FHelmetMats) do
          if FHelmetMats[K] = M then Exit;   { shared material — once }
        K := Length(FHelmetMats);
        SetLength(FHelmetMats, K + 1);
        SetLength(FHelmetOrigColor, K + 1);
        FHelmetMats[K] := M;
        if M is TPhysicalMaterialNode then
          FHelmetOrigColor[K] := TPhysicalMaterialNode(M).BaseColor
        else
          FHelmetOrigColor[K] := TUnlitMaterialNode(M).EmissiveColor;
      end;
      Exit;
    end;
    if Node is TAbstractGroupingNode then
      for I := 0 to TAbstractGroupingNode(Node).FdChildren.Count - 1 do
        Collect(TAbstractGroupingNode(Node).FdChildren[I]);
  end;

begin
  if FHelmetMatsCached then Exit;
  FHelmetMatsCached := True;
  SetLength(FHelmetMats, 0);
  SetLength(FHelmetOrigColor, 0);
  if FHelmetNode <> nil then
    Collect(FHelmetNode);
end;

procedure TTripoRiderScene.ApplyHelmetColor(const C: TVector3; const Enable: Boolean);
var
  I: Integer;
  V: TVector3;
begin
  if FHelmetNode = nil then Exit;   { model has no helmet — nothing to tint }
  CacheHelmetMaterials;
  for I := 0 to High(FHelmetMats) do
  begin
    if Enable then
      V := Vector3(FHelmetOrigColor[I].X * C.X,
                   FHelmetOrigColor[I].Y * C.Y,
                   FHelmetOrigColor[I].Z * C.Z)
    else
      V := FHelmetOrigColor[I];     { back to the authored factor }
    { the color FACTOR multiplies the base/emissive texture per glTF — the
      white texture takes the tint, its baked shading survives }
    if FHelmetMats[I] is TPhysicalMaterialNode then
      TPhysicalMaterialNode(FHelmetMats[I]).BaseColor := V
    else if FHelmetMats[I] is TUnlitMaterialNode then
      TUnlitMaterialNode(FHelmetMats[I]).EmissiveColor := V;
  end;
end;

procedure TTripoRiderScene.EnsureNativeSkinReady;
begin
  if FSkin = nil then Exit;
  FSkin.AnimationSamplingForBox := 0;
  FSkin.InternalUpdateSkin(FScene);
end;

procedure TTripoRiderScene.SetSkinnedAnimationShaders(AOn: Boolean);
var I: Integer;
begin
  if FScene.RenderOptions.SkinnedAnimationShaders = AOn then Exit;
  { Joint property writes queue parent transformations in CGE. Flush them
    before baking; TimePlayingSpeed=0 would otherwise leave the mesh in the
    previous pose while rigid accessories already use the new pose. }
  if not AOn then FScene.IncreaseTime(1E-6);
  FScene.RenderOptions.SkinnedAnimationShaders := AOn;
  for I := 0 to High(FSkinList) do
    FSkinList[I].InternalUpdateSkin(FScene);
end;

procedure TTripoRiderScene.RefreshHelmetBind;
begin
  CacheHelmet;
end;

procedure TTripoRiderScene.CacheHelmet;

  { The palette parent chain must reach the pelvis — otherwise the joint's
    WorldPose never inherits the spine lean (Tripo sometimes exports Head
    unskinned / detached in the skin palette) and a helmet following it
    would freeze at bind. }
  function ChainReachesPelvis(J: Integer): Boolean;
  var Guard: Integer;
  begin
    Result := False;
    Guard := 0;
    while (J >= 0) and (Guard <= FRig.JointCount) do
    begin
      if (FRig.JointName[J] = 'Pelvis') or (FRig.JointName[J] = 'Waist') then
        Exit(True);
      J := FRig.JointParent[J];
      Inc(Guard);
    end;
  end;

  function PickHeadJoint: Integer;
  const CAND: array[0..2] of string = ('Head', 'NeckTwist02', 'NeckTwist01');
  var I, J: Integer;
  begin
    Result := -1;
    for I := 0 to High(CAND) do
    begin
      J := FRig.JointIndexByName(CAND[I]);
      if (J >= 0) and ChainReachesPelvis(J) then Exit(J);
    end;
  end;

var
  N: TX3DNode;
  HeadNode: TTransformNode;
  I: Integer;
begin
  FHelmetNode := nil;
  FHelmetHeadJ := -1;
  FHelmetParented := False;
  if (FScene = nil) or (FScene.RootNode = nil) or (FRig = nil) then Exit;

  { Optional accessory: a separate rigid helmet mesh that is NOT skinned and
    NOT parented to the head — it just hangs in model space and stays behind
    when the head animates.
    1) by the conventional name 'Helmet';
    2) fallback: exporters often lose the object name (the node comes out as
       'tripo_node_<guid>'), so also accept ANY non-joint, non-marker
       transform whose subtree holds a mesh with a vertex count DIFFERENT
       from the skinned body — the only extra mesh these rigs carry. }
  N := FScene.RootNode.TryFindNodeByName(TTransformNode, 'Helmet', false);
  if not (N is TTransformNode) then
  begin
    N := nil;
    FHelmetScan := nil;
    FScene.RootNode.EnumerateNodes(TTransformNode, @GrabHelmetCandidate, false);
    N := FHelmetScan;
  end;
  if not (N is TTransformNode) then Exit;   { no helmet in this model — fine }

  { the joint to follow: the deepest head/neck joint whose palette chain is
    actually CONNECTED to the body (see ChainReachesPelvis above) }
  FHelmetHeadJ := PickHeadJoint;
  if FHelmetHeadJ < 0 then Exit;

  { Keep the node even when it is already a child of Head: file-clip tiles
    parent Helmet under Head, and we still need a handle for extra pitch. }
  HeadNode := nil;
  if FHelmetHeadJ < Length(FJointNode) then HeadNode := FJointNode[FHelmetHeadJ];
  FHelmetParented := False;
  if HeadNode <> nil then
    for I := 0 to HeadNode.FdChildren.Count - 1 do
      if HeadNode.FdChildren[I] = N then
      begin
        FHelmetParented := True;
        Break;
      end;

  FHelmetNode := TTransformNode(N);
  { the authored node TRS — the head's skin matrix is applied ON TOP of it
    every frame (unless already parented). Extra HelmetPitchXDeg is composed
    on the bind rotation in both modes. }
  FHelmetBindT := FHelmetNode.Translation;
  FHelmetBindR := FHelmetNode.Rotation;
  FHelmetRest0Ok := False;
  if (FHelmetHeadJ >= 0) and (FHelmetHeadJ < FRig.JointCount)
     and (Length(FRig.BindWorld) = FRig.JointCount)
     and (Length(FRig.NativeInvBind) = FRig.JointCount) then
  begin
    { Snapshot Head rest-stretch BEFORE ApplyLimbLengths HeightK so GPU follow
      can apply only the incremental stretch (not armature scale × height). }
    FHelmetRest0 := Mat4Mul(FRig.BindWorld[FHelmetHeadJ],
      FRig.NativeInvBind[FHelmetHeadJ]);
    FHelmetRest0Ok := True;
  end;
end;

function TTripoRiderScene.HelmetBindTAdj: TVector3;
{ Authored helmet Translation. Height lives on the skeleton — CPU follow
  uses Head SkinMatrix (already includes HeightK). Do NOT add a feet-relative
  Y grow here: that double-counted HeightK and lifted the helmet off the crown. }
begin
  Result := FHelmetBindT;
end;

function TTripoRiderScene.HelmetBindWithPitch: TQuaternion;
begin
  Result := CastleQuaternions.QuatFromAxisAngle(FHelmetBindR);
  if Abs(FHelmetPitchXDeg) < 1e-4 then Exit;
  { Local +X, Y-up: nod-forward (visor down) is a negative X rotation. }
  Result := Result * CastleQuaternions.QuatFromAxisAngle(
    Vector3(1, 0, 0), DegToRad(-FHelmetPitchXDeg), True);
end;

procedure TTripoRiderScene.SetHelmetPitchXDeg(const V: Single);
begin
  FHelmetPitchXDeg := V;
  if FLoaded and (FHelmetNode <> nil) then
    ApplyHelmetFollow;
end;

procedure TTripoRiderScene.LoadEquipmentGraph(Root: TJSONObject;
  const ModelPath: string);
var
  K, I, SlotIndex: Integer;
  Sh: TShapeNode;
  Mat: TPhysicalMaterialNode;
  Tex: TImageTextureNode;
  N: TX3DNode;
  Anchor: TTransformNode;
  ExternalRoot: TX3DRootNode;
  Slot, Path: string;
begin
  if (FScene = nil) or (FScene.RootNode = nil) then Exit;
  FScene.BeginChangesSchedule;
  try
    for K := 0 to High(FSkinList) do
      for I := 0 to FSkinList[K].FdShapes.Count - 1 do
      begin
        if not (FSkinList[K].FdShapes[I] is TShapeNode) then Continue;
        Sh := TShapeNode(FSkinList[K].FdShapes[I]);
        if (Sh.Appearance = nil) or
           not (Sh.Appearance.Material is TPhysicalMaterialNode) then Continue;
        Mat := TPhysicalMaterialNode(Sh.Appearance.Material);
        SlotIndex := -1;
        { CGE makes DEF names unique: the material can receive a suffix
          because our separate mesh/node deliberately has the same name. }
        if Pos('kitlogochest_primitive', LowerCase(Sh.X3DName)) = 1 then SlotIndex := 0;
        if Pos('kitlogoback_primitive', LowerCase(Sh.X3DName)) = 1 then SlotIndex := 1;
        if SlotIndex < 0 then Continue;
        Slot := RiderEquipmentSlots[SlotIndex];
        Sh.Visible := RiderEquipmentEnabled(Root, Slot);
        Path := ResolveGlbFilesystemPath(EquipmentAbsolutePath(
          RiderEquipmentPath(Root, Slot), ModelPath));
        if (Path <> '') and FileExists(Path) then
        begin
          Tex := TImageTextureNode.Create;
          { Keep glTF's top-left UV convention, just like its image loader. }
          Tex.FlipVertically := True;
          Tex.SetUrl([FilenameToUriSafe(Path)]);
          Tex.RepeatS := False;
          Tex.RepeatT := False;
          Mat.BaseTexture := Tex;
        end;
      end;
    N := FScene.RootNode.TryFindNodeByName(TTransformNode, 'Helmet', False);
    if not (N is TTransformNode) then Exit;
    Anchor := TTransformNode(N);
    if not RiderEquipmentEnabled(Root, 'helmet') then
    begin
      Anchor.FdChildren.Clear;
      Exit;
    end;
    Path := ResolveGlbFilesystemPath(EquipmentAbsolutePath(
      RiderEquipmentPath(Root, 'helmet'), ModelPath));
    if (Path <> '') and FileExists(Path) then
    begin
      ExternalRoot := LoadNode(FilenameToUriSafe(Path));
      Anchor.FdChildren.Clear;
      Anchor.AddChildren(ExternalRoot);
    end;
  finally
    FScene.EndChangesSchedule;
  end;
end;

procedure TTripoRiderScene.ReadHelmetPitchExtra(const AFileName: string);
var
  B: TBytes;
  JsonStr: string;
  BinOfs, BinLen: Integer;
  Data: TJSONData;
  Root, Ex: TJSONObject;
  D: TJSONData;
begin
  if (AFileName = '') or (Pos('://', AFileName) > 0) then Exit;
  if not FileExists(AFileName) then Exit;
  try
    B := LoadFileBytes(AFileName);
  except
    Exit;
  end;
  if not ExtractGltfJson(B, JsonStr, BinOfs, BinLen) then Exit;
  Data := GetJSON(JsonStr);
  if not (Data is TJSONObject) then
  begin
    Data.Free;
    Exit;
  end;
  Root := TJSONObject(Data);
  try
    LoadEquipmentGraph(Root, AFileName);
    D := Root.Find('extras');
    if not (D is TJSONObject) then Exit;
    Ex := TJSONObject(D);
    D := Ex.Find('helmetPitchX');
    if D = nil then D := Ex.Find('avatarHelmetPitchX');
    if (D <> nil) and (D.JSONType = jtNumber) then
      FHelmetPitchXDeg := D.AsFloat;
  finally
    Root.Free;
  end;
end;

procedure TTripoRiderScene.ApplyHelmetFollow;
var
  S: TTripoMat4;
  Q: TTripoVec4;
  SQ, BindQ: TQuaternion;
  BindT: TVector3;
begin
  if FHelmetNode = nil then Exit;
  BindQ := HelmetBindWithPitch;
  BindT := HelmetBindTAdj;
  if FHelmetParented then
  begin
    FHelmetNode.Translation := BindT;
    FHelmetNode.Rotation := BindQ.ToAxisAngle;
    Inc(FHelmetApplies);
    Exit;
  end;
  if FHelmetHeadJ < 0 then Exit;
  if Length(FRig.SkinMatrix) <= FHelmetHeadJ then
    FRig.ComputePose;   { self-heal: pose arrays not built yet in this path }
  if Length(FRig.SkinMatrix) <= FHelmetHeadJ then Exit;
  S := FRig.SkinMatrix[FHelmetHeadJ];
  Inc(FHelmetApplies);
  Q := Mat4ToQuat(S);
  SQ := Quaternion(Vector4(Q.X, Q.Y, Q.Z, Q.W));
  FHelmetNode.Rotation := (SQ * BindQ).ToAxisAngle;
  FHelmetNode.Translation :=
    SQ.Rotate(BindT) + Vector3(S[12], S[13], S[14]);
end;

procedure TTripoRiderScene.ApplyHelmetSkinMatrix(const S: TMatrix4);
var
  SQ: TQuaternion;
  M, RestNow, Rel: TTripoMat4;
  c, r: Integer;
  BindT: TVector3;
  P: TTripoVec3;
begin
  { S is the rigid pose delta D = W_posed * inv(W_bind_new). CPU follow uses
    SkinMatrix = D * gskRest. GPU must apply only the HeightK increment of
    gskRest so Mixamo armature scale already in BindT is not multiplied twice. }
  if (FHelmetNode = nil) or (FHelmetHeadJ < 0) then Exit;
  BindT := FHelmetBindT;
  if (not FHelmetParented) and FHelmetRest0Ok and (FRig <> nil)
     and (FHelmetHeadJ < FRig.JointCount)
     and (Length(FRig.BindWorld) = FRig.JointCount)
     and (Length(FRig.NativeInvBind) = FRig.JointCount) then
  begin
    RestNow := Mat4Mul(FRig.BindWorld[FHelmetHeadJ],
      FRig.NativeInvBind[FHelmetHeadJ]);
    Rel := Mat4Mul(RestNow, Mat4Inverse(FHelmetRest0));
    P := Mat4MulPoint(Rel, V3(BindT.X, BindT.Y, BindT.Z));
    BindT := Vector3(P.X, P.Y, P.Z);
  end;
  for c := 0 to 3 do for r := 0 to 3 do M[c * 4 + r] := S.Data[c, r];
  Inc(FHelmetApplies);
  SQ := Quaternion(Vector4(Mat4ToQuat(M).X, Mat4ToQuat(M).Y, Mat4ToQuat(M).Z, Mat4ToQuat(M).W));
  FHelmetNode.Rotation := (SQ * HelmetBindWithPitch).ToAxisAngle;
  FHelmetNode.Translation :=
    SQ.Rotate(BindT) + Vector3(S.Data[3, 0], S.Data[3, 1], S.Data[3, 2]);
end;

procedure TTripoRiderScene.ResetPose;
var I: Integer;
begin
  for I := 0 to High(FJointNode) do
    if FJointNode[I] <> nil then
      FJointNode[I].FdRotation.Send(FRestRot[I]);
  { the helmet is placed procedurally — put it back to bind · pitch · height }
  if FHelmetNode <> nil then
  begin
    if FHelmetParented then
      ApplyHelmetFollow
    else
    begin
      FHelmetNode.FdTranslation.Send(HelmetBindTAdj);
      FHelmetNode.FdRotation.Send(HelmetBindWithPitch.ToAxisAngle);
    end;
  end;
end;

procedure TTripoRiderScene.SetJointDelta(JointIdx: Integer; const DeltaQ: TQuaternion);
var Q: TQuaternion;
begin
  if (JointIdx < 0) or (JointIdx > High(FJointNode)) then Exit;
  if FJointNode[JointIdx] = nil then Exit;
  { new local = rest THEN delta-in-local-frame }
  Q := CastleQuaternions.QuatFromAxisAngle(FRestRot[JointIdx]) * DeltaQ;
  FJointNode[JointIdx].Rotation := Q.ToAxisAngle;
end;

procedure TTripoRiderScene.SetJointDelta(const AName: string; const DeltaQ: TQuaternion);
begin
  SetJointDelta(FRig.JointIndexByName(AName), DeltaQ);
end;

procedure TTripoRiderScene.SetJointDeltaAxisAngle(const AName: string;
  const Axis: TVector3; const AngleRad: Single);
begin
  SetJointDelta(AName, CastleQuaternions.QuatFromAxisAngle(Axis, AngleRad, true));
end;

procedure TTripoRiderScene.SetJointLocalRotation(JointIdx: Integer; const Rot: TVector4);
begin
  if (JointIdx < 0) or (JointIdx > High(FJointNode)) then Exit;
  if FJointNode[JointIdx] = nil then Exit;
  FJointNode[JointIdx].Rotation := Rot;
end;

procedure TTripoRiderScene.PushJointRest(JointIdx: Integer);
begin
  if (JointIdx < 0) or (JointIdx > High(FJointNode)) then Exit;
  if FJointNode[JointIdx] = nil then Exit;
  if JointIdx > High(FRestRot) then Exit;
  FRestRot[JointIdx] := FJointNode[JointIdx].Rotation;
end;

procedure TTripoRiderScene.PushJointRestByName(const AName: string);
begin
  if FRig = nil then Exit;
  PushJointRest(FRig.JointIndexByName(AName));
end;

function TTripoRiderScene.ParentToRig(const P: TVector3): TVector3;
begin
  { rider Scene's local inverse maps a point from the rider's parent (bike)
    frame into the rider's local (glb) frame, where the rig lives. }
  Result := FScene.InverseTransform.MultPoint(P);
end;

procedure TTripoRiderScene.PushDelta(const AName: string);
var
  Idx: Integer;
  DQ: TTripoVec4;
begin
  Idx := FRig.JointIndexByName(AName);
  if (Idx < 0) or (Idx > High(FJointNode)) then Exit;
  if FJointNode[Idx] = nil then Exit;
  DQ := FRig.DeltaQuat(Idx);
  { node.Rotation := restQuat * thisDelta  (see SetJointDelta) }
  SetJointDelta(Idx, Quaternion(Vector4(DQ.X, DQ.Y, DQ.Z, DQ.W)));
end;

function RiderFootYawRotation(const BikeToRig: TMatrix4; AngleDeg: Single): TTripoVec4;
var Axis: TVector3;
begin
  Axis := BikeToRig.MultDirection(Vector3(0, 1, 0)).Normalize;
  { Bike forward = +X, right = +Z, hence right toes-out is negative yaw. }
  Result := QuatFromAxisAngle(Axis.X, Axis.Y, Axis.Z, -DegToRad(AngleDeg));
end;

procedure TTripoRiderScene.UpdatePose(const FootTargetR, FootTargetL,
  HandTargetR, HandTargetL: TVector3);
var
  legR, legL, armR, armL: TTripoVec3;
  footYawR: TTripoVec4;
  i: Integer;

  function ToRig(const P: TVector3): TTripoVec3;
  var Q: TVector3;
  begin
    Q := ParentToRig(P);
    Result := V3(Q.X, Q.Y, Q.Z);
  end;

  { Solve a two-bone limb so the CONTACT MARKER lands on the bike target. The
    marker offset (in the end joint's local frame) was baked once at load into
    FContactLocal[LimbIdx]; we treat it as a rigid child of the end joint. EndPitch
    is the foot roll (ankle flex, radians about world Z; 0 for hands) — it is folded
    INTO the aim so the marker stays on target AFTER the roll, then applied for real.
    Iterates a few passes because the joint's rotation shifts as the limb re-aims.
    With no baked marker, the joint itself is driven to the target (then rolled). }
  procedure SolveLimb(const Upper, Mid, EndJoint: string; LimbIdx: Integer;
    const TargetParent: TVector3; const Hint: TTripoVec3; EndPitch: Single;
    ToeExtend: Boolean = False; RollDeg: Single = 0);
  const
    cEaseFrom = 0.90;   { below this fraction of leg length the foot keeps its natural
                          orientation and the cleat binds exactly; above it the foot
                          progressively plantar-flexes (toe down) to hold the cleat on
                          the pedal as the leg runs short }
    cEaseTo   = 0.99;   { the eased knee extension asymptotes here, so the toe points
                          ever further down while the knee nears but never locks straight }
    cMaxExt   = 0.999;  { a leg straighter than this that STILL cannot reach detaches }
    cPronVertDead = 0.65; { forearm-verticality (|dir.Y|) past which pronation starts
                            fading toward the natural wrist; 1 = fully vertical plane }
    cMaxWristBendRad = 0.698132; { hard cap on the wrist-leveling bend = 40 degrees }
    cGripStillEps = 1e-5;        { grip counts as stationary if it moved less than this (rig units) }
  var
    bikePt, jt, jp, mk, dLoc, hip, ankleAim, vOff, dirP, mkB, resid: TTripoVec3;
    bestJt: TTripoVec3;
    aimBase: TTripoVec3;
    dirH, axL: TTripoVec3;
    poseQ, pitchQ, finalQ, qfix, footQ, qroll, qLevel: TTripoVec4;
    ei, ui, mi, pass, cs: Integer;
    L1, L2, legReach, ang, sw: Single;
    bestMiss, missLen, reachLen: Single;
    hs, hc, hang: Single;
    effRoll, vert, ptv: Single;
    armSt: Boolean;
    reachTgt, rFrac, sgn, aCur, aLo, aHi, aMid, rr, rp, rm: Single;
    aCross, closestR, aClosest, aUse: Single;

    { Absolute orientation, independent of an old end-joint delta left by IK.
      ApplyWorldPitchByIndex replaces the delta; feeding it a relative correction
      after a second solve would discard the previous wrist rotation. }
    procedure SetEndOrientation(const OrientQ: TTripoVec4);
    var preQ: TTripoVec4; parentIdx: Integer;
    begin
      parentIdx := FRig.JointParent[ei];
      preQ := Mat4ToQuat(FRig.BindLocal[ei]);
      if parentIdx >= 0 then preQ := QuatMul(FRig.JointWorldRot(parentIdx), preQ);
      FRig.SetJointDeltaQuat(ei, QuatNormalize(QuatMul(QuatConj(preQ), OrientQ)));
      FRig.ComputePoseFrom(ei);
    end;

    { Limit the FINAL hand direction relative to the solved forearm, rather than
      just the earlier leveling increment. Pronation about that axis is retained. }
    function LimitedHandOrientation(const OrientQ: TTripoVec4): TTripoVec4;
    var bindAxis, handAxis, foreAxis, bendAxis: TTripoVec3; bend, c: Single;
    begin
      Result := OrientQ;
      if mi < 0 then Exit;
      bindAxis := V3Sub(FRig.JointBindPos(ei), FRig.JointBindPos(mi));
      foreAxis := V3Sub(FRig.JointWorldPos(ei), FRig.JointWorldPos(mi));
      if (V3Len(bindAxis) < 1e-6) or (V3Len(foreAxis) < 1e-6) then Exit;
      bindAxis := QuatRotateV3(QuatConj(Mat4ToQuat(FRig.BindWorld[ei])), V3Norm(bindAxis));
      handAxis := V3Norm(QuatRotateV3(OrientQ, bindAxis));
      foreAxis := V3Norm(foreAxis);
      c := V3Dot(handAxis, foreAxis);
      if c > 1 then c := 1 else if c < -1 then c := -1;
      bend := ArcCos(c);
      if bend <= cMaxWristBendRad then Exit;
      bendAxis := V3Cross(handAxis, foreAxis);
      if V3Len(bendAxis) < 1e-6 then
      begin
        bendAxis := V3Cross(handAxis, V3(0, 1, 0));
        if V3Len(bendAxis) < 1e-6 then bendAxis := V3Cross(handAxis, V3(1, 0, 0));
      end;
      bendAxis := V3Norm(bendAxis);
      Result := QuatNormalize(QuatMul(QuatFromAxisAngle(bendAxis.X,
        bendAxis.Y, bendAxis.Z, bend - cMaxWristBendRad), OrientQ));
    end;

    { After the limb is placed (end joint at AnkleAim, foot/hand at orientation OrientQ),
      the RIGID bone point is on the target — but the RENDERED, skin-blended contact can
      sit slightly off it (the cleat region blends R_Foot+R_Calf; the palm blends a
      forearm-twist bone). Nudge the end joint so the BLENDED marker lands on the target,
      restoring OrientQ each pass so the foot/hand keeps its solved roll.

      DAMPED + GUARDED: the blended marker does NOT track the wrist 1:1 where the surface
      is weighted to OTHER bones (the left palm rides a forearm-twist bone), so a raw
      "aim -= residual" step diverges there and throws the hand off the bar. So we take a
      damped step and KEEP it only if it reduced the residual; otherwise we revert to the
      previous (rigid, already-on-target) placement and stop. Stable limbs (feet, clean
      hand) still converge onto the rendered surface; unstable ones fall back to rigid. }
    procedure PinBlendedContact(const OrientQ: TTripoVec4);
    const cDamp = 0.6;
    var p2: Integer; q2: TTripoVec4; a2, s2, prevLen, curLen: Single; prevAim, shVec: TTripoVec3; shLen: Single;

      procedure SolveAndRestore;   { aim end joint at ankleAim, then restore OrientQ }
      begin
        FRig.SolveTwoBone(ui, mi, ei, ankleAim, Hint, armSt);
        if armSt then
        begin
          SetEndOrientation(LimitedHandOrientation(OrientQ));
          Exit;
        end;
        q2 := QuatMul(OrientQ, QuatConj(FRig.JointWorldRot(ei)));
        s2 := q2.W; if s2 > 1 then s2 := 1; if s2 < -1 then s2 := -1;
        a2 := 2.0 * ArcCos(s2);
        if (Abs(q2.X) + Abs(q2.Y) + Abs(q2.Z) > 1e-6) and (Abs(a2) > 1e-4) then
          FRig.ApplyWorldPitchByIndex(ei, q2.X, q2.Y, q2.Z, a2);
      end;

    begin
      if not PosedContactRig(LimbIdx, mkB) then Exit;
      prevLen := V3Len(V3Sub(mkB, bikePt));
      for p2 := 0 to 3 do
      begin
        if prevLen < 1e-5 then Break;
        resid   := V3Sub(mkB, bikePt);
        prevAim := ankleAim;
        ankleAim := V3Sub(ankleAim, V3Scale(resid, cDamp));   { damped step }
        if armSt and (ui >= 0) and (reachLen > 1e-6) then     { keep the wrist target within reach }
        begin
          shVec := V3Sub(ankleAim, FRig.JointWorldPos(ui));
          shLen := V3Len(shVec);
          if shLen > reachLen * 0.999 then
            ankleAim := V3Add(FRig.JointWorldPos(ui), V3Scale(shVec, (reachLen * 0.999) / shLen));
        end;
        SolveAndRestore;
        if not PosedContactRig(LimbIdx, mkB) then begin ankleAim := prevAim; SolveAndRestore; Break; end;
        curLen := V3Len(V3Sub(mkB, bikePt));
        if curLen >= prevLen - 1e-7 then                       { no improvement: revert + stop }
        begin
          ankleAim := prevAim;
          SolveAndRestore;
          Break;
        end;
        prevLen := curLen;
      end;
    end;
  begin
    { OPT: индексы суставов конечности — один раз, дальше без строковых поисков }
    if not FLimbValid[LimbIdx] then
    begin
      FLimbJ[LimbIdx][0] := FRig.JointIndexByName(Upper);
      FLimbJ[LimbIdx][1] := FRig.JointIndexByName(Mid);
      FLimbJ[LimbIdx][2] := FRig.JointIndexByName(EndJoint);
      FLimbValid[LimbIdx] := True;
    end;
    ui := FLimbJ[LimbIdx][0];
    mi := FLimbJ[LimbIdx][1];
    ei := FLimbJ[LimbIdx][2];
    if ei < 0 then Exit;
    bikePt := ToRig(TargetParent);
    armSt := LimbIdx >= 2;   { stabilize the elbow's bend side (arms only) so a hand-swap
                               sweep can't flip it across the hint singularity per frame }

    pitchQ := QuatFromAxisAngle(FLeanAxis.X, FLeanAxis.Y, FLeanAxis.Z, EndPitch);
    if (LimbIdx < 2) and (FFootYawDeg <> 0) then
    begin
      if LimbIdx = 0 then pitchQ := QuatMul(footYawR, pitchQ)
      else pitchQ := QuatMul(QuatConj(footYawR), pitchQ);
    end;

    if not FContactValid[LimbIdx] then
    begin   { rig without this marker — fall back to driving the joint itself }
      FRig.SolveTwoBone(ui, mi, ei, bikePt, Hint, armSt);
      if (Abs(EndPitch) > 1e-4) or ((LimbIdx < 2) and (FFootYawDeg <> 0)) then
        SetEndOrientation(QuatMul(pitchQ, FRig.JointWorldRot(ei)));
      Exit;
    end;

    dLoc := FContactLocal[LimbIdx];

    { Aim the end bone so the baked contact lands on the target. Legs start from
      the effective knee->cleat segment; hands refine the wrist target below. }
    { Ankle/wrist roll about the rig's LATERAL axis (FLeanAxis), not a
      hardcoded world Z. Bike-aligned bind: +Z. Mixamo file-space: +X
      (or -X, same axis the spine uses). Hardcoding Z after a display-only
      Scene yaw is the leftover "feet twist in the wrong plane". }
    { pitchQ also includes foot yaw BEFORE contact aiming: rotating a shoe must
      move its ankle around the cleat, not move the cleat off the pedal. }

    { arm reach clamp (continuous, no mode switch): pull the AIM target in to just inside
      the arm's length so the marker-aiming iteration ALWAYS has a reachable goal. Without
      this an out-of-reach grip makes the residual never shrink — the raw "jt -= miss" step
      runs the aim away and the straight arm claps. A hard "if out of reach then aim straight"
      switch instead toggles every frame as the shoulder bobs across the reach limit (two
      slightly different orientations -> clap in time with pedalling). Clamping the target
      is C0-continuous across the limit: the arm just extends to its max toward the bar and
      holds. Arms only; legs keep the real target and let the ToeExtend cascade handle a
      short leg. }
    reachLen := 0;
    if (ui >= 0) and (mi >= 0) then
      reachLen := V3Len(V3Sub(FRig.JointBindPos(mi), FRig.JointBindPos(ui)))
                + V3Len(V3Sub(FRig.JointBindPos(ei), FRig.JointBindPos(mi)));
    aimBase := bikePt;
    if armSt and (ui >= 0) and (reachLen > 1e-6) then
    begin
      jp      := FRig.JointWorldPos(ui);                 { shoulder }
      mk      := V3Sub(bikePt, jp);                      { shoulder -> grip }
      missLen := V3Len(mk);
      if missLen > reachLen * 0.999 then                 { clamp onto the reach sphere }
        aimBase := V3Add(jp, V3Scale(mk, (reachLen * 0.999) / missLen));
    end;

    if ToeExtend then
      FRig.AimLegContact(ui, mi, ei, bikePt, Hint, dLoc, pitchQ, footQ, ankleAim)
    else
    begin
      jt := aimBase;                                  { first guess: aim the joint at the (clamped) target }
      bestJt := jt; bestMiss := 1e30;
      for pass := 0 to 3 do
      begin
        FRig.SolveTwoBone(ui, mi, ei, jt, Hint, armSt);
        poseQ  := FRig.JointWorldRot(ei);
        finalQ := QuatMul(pitchQ, poseQ);             { fold in the not-yet-applied roll }
        jp := FRig.JointWorldPos(ei);
        mk := V3Add(jp, QuatRotateV3(finalQ, dLoc));  { where the marker would land }
        missLen := V3Len(V3Sub(mk, aimBase));
        if missLen < bestMiss then begin bestMiss := missLen; bestJt := jt; end;
        if missLen < 1e-5 then Break;
        jt := V3Sub(jt, V3Sub(mk, aimBase));          { shift the aim to cancel the miss }
      end;
      { use the BEST aim, not the last (reachable targets converge to miss~0, unchanged there). }
      FRig.SolveTwoBone(ui, mi, ei, bestJt, Hint, armSt);
    end;

    if ToeExtend then
    begin
      { -- FOOT-LEADING bind + toe-down reach cascade (legs only) -------------------
        The foot is the master bone. While the leg reaches comfortably the natural
        orientation is kept and the cleat binds EXACTLY (ankle = pedal - footQ*offset).

        As the leg runs short the cleat STAYS on the pedal: the whole foot is rolled
        toe-down about the PEDAL axle (world Z), which first removes the ankling flex
        (heel up to the pedal, never below) and then plantar-flexes (toe down), each
        step pulling the ankle toward the hip. The roll grows smoothly from cEaseFrom
        and targets an eased extension that asymptotes to cEaseTo, so the toe points
        progressively down while the knee approaches but never slams straight. If even
        max toe-down cannot reach that eased target, a still-straightening leg takes
        the max toe-down (cleat still on the pedal). Only when even a leg straighter
        than cMaxExt cannot reach do we DETACH the foot from the pedal. }
      { AimLegContact supplied a continuous foot orientation from the effective
        knee->cleat segment, rather than selecting among ankle-aim iterations. }
      vOff  := QuatRotateV3(footQ, dLoc);                 { world ankle->cleat (natural) }
      ankleAim := V3Sub(bikePt, vOff);                    { natural ankle: cleat on pedal }

      if (ui >= 0) and (mi >= 0) then
      begin
        L1 := V3Len(V3Sub(FRig.JointBindPos(mi), FRig.JointBindPos(ui)));
        L2 := V3Len(V3Sub(FRig.JointBindPos(ei), FRig.JointBindPos(mi)));
        legReach := L1 + L2;
        hip := FRig.JointWorldPos(ui);                    { thigh root, fixed during the IK }
        if legReach > 1e-6 then rFrac := V3Len(V3Sub(ankleAim, hip)) / legReach else rFrac := 0.0;

        if rFrac > cEaseFrom then
        begin
          { eased target extension (asymptotes to cEaseTo as the pedal moves away) }
          reachTgt := (cEaseFrom + (cEaseTo - cEaseFrom) *
                       (1.0 - Exp(-(rFrac - cEaseFrom) / (cEaseTo - cEaseFrom)))) * legReach;

          { toe-down sign = whichever small roll of the offset reduces |ankle - hip| }
          rp := V3Len(V3Sub(V3Sub(bikePt, QuatRotateV3(QuatFromAxisAngle(FLeanAxis.X, FLeanAxis.Y, FLeanAxis.Z, 0.02), vOff)), hip));
          rm := V3Len(V3Sub(V3Sub(bikePt, QuatRotateV3(QuatFromAxisAngle(FLeanAxis.X, FLeanAxis.Y, FLeanAxis.Z,-0.02), vOff)), hip));
          if rm < rp then sgn := -1.0 else sgn := 1.0;

          { sweep the toe-down roll: track the closest approach and the first angle
            that brings the ankle to the eased target distance }
          aCross := -1.0; closestR := 1e30; aClosest := 0.0; aCur := 0.0;
          while aCur <= Pi + 1e-4 do
          begin
            rr := V3Len(V3Sub(V3Sub(bikePt, QuatRotateV3(QuatFromAxisAngle(FLeanAxis.X, FLeanAxis.Y, FLeanAxis.Z, sgn*aCur), vOff)), hip));
            if rr < closestR then begin closestR := rr; aClosest := aCur; end;
            if (aCross < 0.0) and (rr <= reachTgt) then aCross := aCur;
            aCur := aCur + (Pi/180.0);                    { 1 deg steps }
          end;

          if aCross >= 0.0 then
          begin
            { eased target reachable by plantar-flex: refine the crossing }
            aLo := aCross - (Pi/180.0); if aLo < 0.0 then aLo := 0.0;
            aHi := aCross;
            for pass := 0 to 24 do
            begin
              aMid := 0.5 * (aLo + aHi);
              rr := V3Len(V3Sub(V3Sub(bikePt, QuatRotateV3(QuatFromAxisAngle(FLeanAxis.X, FLeanAxis.Y, FLeanAxis.Z, sgn*aMid), vOff)), hip));
              if rr > reachTgt then aLo := aMid else aHi := aMid;
            end;
            aUse := 0.5 * (aLo + aHi);
            qroll := QuatFromAxisAngle(FLeanAxis.X, FLeanAxis.Y, FLeanAxis.Z, sgn * aUse);
            footQ := QuatMul(qroll, footQ);                       { plantar-flexed foot }
            ankleAim := V3Sub(bikePt, QuatRotateV3(qroll, vOff)); { cleat still on the pedal }
          end
          else if closestR <= legReach * cMaxExt then
          begin
            { eased target out of reach, but a near-straight leg still reaches the max
              toe-down ankle -> take max plantar-flex, cleat stays on the pedal }
            qroll := QuatFromAxisAngle(FLeanAxis.X, FLeanAxis.Y, FLeanAxis.Z, sgn * aClosest);
            footQ := QuatMul(qroll, footQ);
            ankleAim := V3Sub(bikePt, QuatRotateV3(qroll, vOff));
          end
          else
          begin
            { DETACH: even a straight leg at max toe-down cannot reach. Point the leg
              at the pedal and aim the foot at it so the cleat gets as close as it can. }
            dirP := V3Sub(bikePt, hip);
            if V3Len(dirP) > 1e-6 then dirP := V3Norm(dirP);
            if V3Len(vOff) > 1e-6 then footQ := QuatMul(QuatFromTo(V3Norm(vOff), dirP), footQ);
            ankleAim := bikePt;                            { leg clamps straight toward pedal }
          end;
        end;
      end;

      { thigh+calf reach the ankle (dependent two-bone IK; foot delta stays identity),
        then restore the chosen foot orientation footQ (rotates about the ankle, so the
        ankle stays put and, while bound, the cleat stays on the pedal). }
      FRig.SolveTwoBone(ui, mi, ei, ankleAim, Hint, armSt);
      poseQ := FRig.JointWorldRot(ei);
      qfix  := QuatMul(footQ, QuatConj(poseQ));
      sw := qfix.W;
      if sw >  1 then sw :=  1;
      if sw < -1 then sw := -1;
      ang := 2.0 * ArcCos(sw);
      if (Abs(qfix.X) + Abs(qfix.Y) + Abs(qfix.Z) > 1e-6) and (Abs(ang) > 1e-4) then
        FRig.ApplyWorldPitchByIndex(ei, qfix.X, qfix.Y, qfix.Z, ang);
      { land the RENDERED (skin-blended) sole on the pedal, not just the rigid bone }
      PinBlendedContact(footQ);
      Exit;
    end;

    { arm: exact bind — place the hand bone so the palm contact lands ON the grip,
      exactly as the legs do, with no dependence on the iteration converging. footQ
      is the natural hand orientation the iteration just measured; pronation (RollDeg,
      a roll about the forearm axis) is folded INTO footQ BEFORE landing, so the palm
      stays on the grip AFTER the roll — mirroring how the foot folds its ankle-flex
      into the aim. (Applying pronation after the solve, as the old Pronate did, swung
      the palm marker off the grip because the marker sits off the forearm axis.) The
      hand bone then goes to grip - footQ*offset, the arm re-solves (dependent), and
      footQ is restored so the palm sits on the grip. Too-short arm => the solve clamps
      and the palm lands as close to the grip as the arm can reach. }
    footQ := QuatMul(pitchQ, FRig.JointWorldRot(ei));   { natural hand orientation }
    if Abs(RollDeg) > 0.01 then
    begin
      if mi >= 0 then
      begin
        dirP := V3Sub(FRig.JointWorldPos(ei), FRig.JointWorldPos(mi));  { forearm axis }
        if V3Len(dirP) > 1e-6 then
        begin
          dirP  := V3Norm(dirP);
          { pronation guard: the nearer the forearm/hand axis is to vertical — i.e. the
            hand lies in a vertical plane — the more the pronation roll is faded back to
            the natural wrist. Rolling a vertically-planed hand about a near-vertical axis
            twists the wrist past its natural range, so limit the angle there. }
          vert := Abs(dirP.Y);                            { 0 = horizontal, 1 = vertical plane }
          ptv  := (vert - cPronVertDead) / (1.0 - cPronVertDead);
          if ptv < 0 then ptv := 0;
          if ptv > 1 then ptv := 1;
          effRoll := RollDeg * (1.0 - ptv);               { -> natural (0) as the plane goes vertical }
          if Abs(effRoll) > 0.01 then
          begin
            qroll := QuatFromAxisAngle(dirP.X, dirP.Y, dirP.Z, effRoll * Pi / 180.0);
            footQ := QuatMul(qroll, footQ);               { pronation folded in (world frame) }
          end;
        end;
      end;
    end;
    { ── wrist leveling: pitch the hand so the continuation of the forearm lies
      horizontal — the hand ends up parallel to the ground. It's folded into footQ
      BEFORE the bind, so the hand pivots about the palm contact and stays on the grip.
      FHandLevel scales 0 (keep the natural wrist) .. 1 (fully level). }
    if FHandLevel > 1e-3 then
    begin
      if mi >= 0 then
      begin
        dirP := V3Sub(FRig.JointWorldPos(ei), FRig.JointWorldPos(mi));  { forearm axis (world) }
        if V3Len(dirP) > 1e-6 then
        begin
          dirP := V3Norm(dirP);
          dirH := V3(dirP.X, 0, dirP.Z);                { horizontal projection of the forearm axis }
          if V3Len(dirH) > 1e-3 then
          begin
            dirH := V3Norm(dirH);
            axL  := V3Cross(dirP, dirH);                { pitch axis (horizontal, ⟂ forearm) }
            hs   := V3Len(axL);
            if hs > 1e-6 then
            begin
              axL    := V3Scale(axL, 1.0 / hs);
              hc     := V3Dot(dirP, dirH);
              hang   := ArcTan2(hs, hc) * FHandLevel;   { angle forearm→horizontal, scaled }
              if hang > cMaxWristBendRad then           { never bend the wrist past 40° }
                hang := cMaxWristBendRad;
              qLevel := QuatFromAxisAngle(axL.X, axL.Y, axL.Z, hang);
              footQ  := QuatMul(qLevel, footQ);         { fold the level pitch into the hand orientation }
            end;
          end;
        end;
      end;
    end;
    { keep a hand planted on a still grip: recompute its orientation only when the
      grip target moves (a position-change animation) or the wrist intent changes;
      otherwise reuse the frozen orientation so the torso bob can't rotate the hand.
      A free (waving) hand has a moving target, so it never freezes. }
    cs := LimbIdx - 2;                                   { 0 = R_Hand, 1 = L_Hand }
    if (cs = 0) or (cs = 1) then
    begin
      if FHandFreezeOk[cs]
         and (V3Len(V3Sub(bikePt, FHandFreezePt[cs]))  < cGripStillEps)
         and (Abs(RollDeg    - FHandFreezeRoll[cs])     < 0.01)
         and (Abs(FHandLevel - FHandFreezeLevel[cs])    < 0.001) then
        footQ := FHandFreezeQ[cs]                        { settled -> hold the frozen orientation }
      else
      begin                                              { grip/intent changed -> adopt + cache }
        FHandFreezeQ[cs]     := footQ;
        FHandFreezePt[cs]    := bikePt;
        FHandFreezeRoll[cs]  := RollDeg;
        FHandFreezeLevel[cs] := FHandLevel;
        FHandFreezeOk[cs]    := True;
      end;
    end;
    { Solve the wrist position and its allowed orientation together. Using a
      frozen palm orientation for a single solve can push the wrist beyond arm
      reach, lock the elbow straight and put the whole correction into the wrist.
      Re-aim from the real grip after every orientation adjustment so available
      reach is taken up by the elbow. Never clamp the grip itself here. }
    finalQ := footQ;  { requested/frozen grip orientation }
    for pass := 0 to 31 do
    begin
      ankleAim := V3Sub(bikePt, QuatRotateV3(footQ, dLoc));
      if (ui >= 0) and (reachLen > 1e-6) then
      begin
        mk := V3Sub(ankleAim, FRig.JointWorldPos(ui));
        missLen := V3Len(mk);
        if missLen > reachLen * 0.999 then
          ankleAim := V3Add(FRig.JointWorldPos(ui), V3Scale(mk, reachLen * 0.999 / missLen));
      end;
      FRig.SolveTwoBone(ui, mi, ei, ankleAim, Hint, armSt);
      poseQ := LimitedHandOrientation(finalQ);
      missLen := V3Len(V3Sub(QuatRotateV3(poseQ, dLoc), QuatRotateV3(footQ, dLoc)));
      if missLen < 1e-5 then
      begin
        footQ := poseQ;
        Break;
      end;
      { Near full arm extension a complete wrist correction overshoots: the
        next IK pass alternates between a straight and a bent elbow. Relax the
        orientation within THIS solve (no previous-frame smoothing or lag).
        Shortest-arc normalized interpolation also handles q / -q equally. }
      if footQ.X * poseQ.X + footQ.Y * poseQ.Y +
         footQ.Z * poseQ.Z + footQ.W * poseQ.W < 0 then
      begin
        poseQ.X := -poseQ.X; poseQ.Y := -poseQ.Y;
        poseQ.Z := -poseQ.Z; poseQ.W := -poseQ.W;
      end;
      footQ.X := 3 * footQ.X + poseQ.X;
      footQ.Y := 3 * footQ.Y + poseQ.Y;
      footQ.Z := 3 * footQ.Z + poseQ.Z;
      footQ.W := 3 * footQ.W + poseQ.W;
      footQ := QuatNormalize(footQ);
    end;
    { Preserve the anatomical cap even if the iteration budget is exhausted. }
    footQ := LimitedHandOrientation(footQ);
    SetEndOrientation(footQ);
    { land the RENDERED (skin-blended) palm on the grip, not just the rigid bone. Its damped
      steps are clamped to the reach sphere inside (see PinBlendedContact), so out of reach
      it slides the marker along the sphere toward the grip instead of swinging the maxed
      arm around — stable and continuous across the reach limit. }
    PinBlendedContact(footQ);
  end;

begin
  if not FLoaded then Exit;

  footYawR := RiderFootYawRotation(FScene.InverseTransform, FFootYawDeg);

  { per-side bend hints: base direction (rig frame) + lateral flare along
    FFlareAxis (bike +Z / Mixamo +X). Adding flare to hint.Z always is
    bike-only: on a Mixamo bind it slides the hint along forward. }
  legR := V3(FLegPlaneHint.X + FFlareAxis.X * FKneeFlare,
             FLegPlaneHint.Y + FFlareAxis.Y * FKneeFlare,
             FLegPlaneHint.Z + FFlareAxis.Z * FKneeFlare);
  legL := V3(FLegPlaneHint.X - FFlareAxis.X * FKneeFlare,
             FLegPlaneHint.Y - FFlareAxis.Y * FKneeFlare,
             FLegPlaneHint.Z - FFlareAxis.Z * FKneeFlare);
  armR := V3(FArmPlaneHint.X + FFlareAxis.X * FElbowFlare,
             FArmPlaneHint.Y + FFlareAxis.Y * FElbowFlare,
             FArmPlaneHint.Z + FFlareAxis.Z * FElbowFlare);
  armL := V3(FArmPlaneHint.X - FFlareAxis.X * FElbowFlare,
             FArmPlaneHint.Y - FFlareAxis.Y * FElbowFlare,
             FArmPlaneHint.Z - FFlareAxis.Z * FElbowFlare);

  { bind -> lean/curl the spine -> solve limbs (arms read the leaned shoulders;
    the legs hang from the pelvis below the spine, so the lean doesn't move them) }
  FRig.ResetPose;
  FRig.ComputePose;
  PoseSpine;

  SolveLimb('R_Thigh', 'R_Calf', 'R_Foot', 0, FootTargetR, legR, FFootPitchR, True);
  SolveLimb('L_Thigh', 'L_Calf', 'L_Foot', 1, FootTargetL, legL, FFootPitchL, True);

  { round + twist the shoulders by swinging each clavicle about the vertical axis.
    Round mirrors L/R (protraction); twist is the SAME sign on both, so it yaws the
    whole shoulder line (one shoulder leads) — used during an asymmetric hand move.
    Both are about the same axis, so the angles just add. Done BEFORE the arm IK so
    the arms re-solve to the bars from the new shoulder positions. }
  if (Abs(FShoulderRoundDeg) > 0.01) or (Abs(FShoulderTwistDeg) > 0.01) then
  begin
    FRig.ApplyWorldPitch('R_Clavicle', 0, 1, 0, ( FShoulderRoundDeg + FShoulderTwistDeg) * Pi / 180.0);
    FRig.ApplyWorldPitch('L_Clavicle', 0, 1, 0, (-FShoulderRoundDeg + FShoulderTwistDeg) * Pi / 180.0);
  end;

  { Pronation is a roll about EACH forearm's own axis. Pose files store opposite
    numbers (R=-40, L=+40) expecting a shared world axis. The two forearm axes
    already point opposite (out along each arm), so applying stored L as-is
    cancelled the mirror: both wrists rolled the SAME world way (right looked
    fine, left crooked). Apply -L so world rolls stay opposite. Right unchanged. }
  SolveLimb('R_Upperarm', 'R_Forearm', 'R_Hand', 2, HandTargetR, armR, 0, False, FArmPronationDegR);
  SolveLimb('L_Upperarm', 'L_Forearm', 'L_Hand', 3, HandTargetL, armL, 0, False, -FArmPronationDegL);
  FRig.DistributeForearmTwist('R_');
  FRig.DistributeForearmTwist('L_');
  if FRig.JointIndexByName('L_IndexMetacarpal') >= 0 then
  begin
    FRig.ApplyHandGrip(Ord(FPose.HandPosR > 0), Ord(FPose.HandPosL > 0));
    for i := 0 to FRig.JointCount - 1 do PushDelta(FRig.JointName[i]);
  end;

  { foot roll (ankle flex) is now applied INSIDE SolveLimb, as part of landing the
    cleat marker on the pedal after the roll — see the leg SolveLimb calls above.
    Hand roll (pronation) is likewise folded into the arm SolveLimb calls above. }

  { push every joint we touched; untouched ones carry an identity delta (= bind) }
  PushDelta('Waist');      PushDelta('Spine');     PushDelta('Spine01');
  PushDelta('Spine02');    PushDelta('NeckTwist01');
  PushDelta('R_Thigh');    PushDelta('R_Calf');    PushDelta('R_Foot');
  PushDelta('L_Thigh');    PushDelta('L_Calf');    PushDelta('L_Foot');
  PushDelta('R_Clavicle'); PushDelta('L_Clavicle');
  PushDelta('R_Upperarm'); PushDelta('R_Forearm'); PushDelta('R_Hand');
  PushDelta('L_Upperarm'); PushDelta('L_Forearm'); PushDelta('L_Hand');
  PushDelta('R_ForearmTwist01'); PushDelta('R_ForearmTwist02');
  PushDelta('L_ForearmTwist01'); PushDelta('L_ForearmTwist02');
  if FCorrectives <> nil then FCorrectives.UpdateCpuPose;

  { carry the optional rigid Helmet node with the posed head — it is not
    skinned, so without this it would hang in bind pose while the head moves }
  ApplyHelmetFollow;
end;

function TTripoRiderScene.GetSpineAngle(Index: Integer): Single;
begin
  if (Index >= 0) and (Index <= 4) then Result := FSpineAngles[Index] else Result := 0;
end;

function TTripoRiderScene.DbgSpineShoulders: string;
const
  NAMES: array[0..5] of string = ('Waist', 'Spine01', 'Spine02', 'NeckTwist01',
    'R_Upperarm', 'L_Upperarm');
var
  I, J: Integer;
  P: TTripoVec3;
  V: TVector4;
  M: TMatrix4;
begin
  if (FRig = nil) or (Length(FRig.WorldPose) < FRig.JointCount) then
    Exit('(no pose)');
  if FScene = nil then Exit('(no scene)');
  M := FScene.Transform;   { rig frame -> bike frame }
  Result := Format('lean=%.2f ', [FTorsoLeanDeg]);
  for I := 0 to 5 do
  begin
    J := FRig.JointIndexByName(NAMES[I]);
    if J < 0 then Continue;
    P := V3(FRig.WorldPose[J][12], FRig.WorldPose[J][13], FRig.WorldPose[J][14]);
    V := M * Vector4(P.X, P.Y, P.Z, 1.0);
    Result := Result + Format('%s=(%.3f,%.3f,%.3f) ', [NAMES[I], V.X, V.Y, V.Z]);
  end;
end;

procedure TTripoRiderScene.SetSpineAngle(Index: Integer; const V: Single);
begin
  if (Index >= 0) and (Index <= 4) then FSpineAngles[Index] := V;
end;

procedure TTripoRiderScene.PoseSpine;
const
  SP: array[0..4] of string = ('Waist', 'Spine', 'Spine01', 'Spine02', 'NeckTwist01');
var I: Integer; Idx: array[0..4] of Integer; Ang: TSpineAngles;
begin
  for I := 0 to 4 do Idx[I] := FRig.JointIndexByName(SP[I]);
  if FSpineManual then
    for I := 0 to 4 do Ang[I] := FSpineAngles[I]
  else
    SpineAutoLeanDeg(FTorsoLeanDeg, FSpineCurve, Idx, Ang);
  for I := 0 to 4 do
    if Idx[I] >= 0 then
      FRig.ApplyWorldRotationByIndex(Idx[I],
        RiderSpineDelta(FLeanAxis, Ang[I], FSpineYaw[I], FSpineRoll[I]));
end;

function TTripoRiderScene.PelvisBindLocal: TVector3;
var Idx: Integer; P: TTripoVec3;
begin
  Result := Vector3(0, 0, 0);
  if FRig = nil then Exit;
  Idx := FRig.JointIndexByName('Pelvis');
  if Idx < 0 then Idx := FRig.JointIndexByName('Hip');
  if Idx < 0 then Idx := FRig.JointIndexByName('Waist');
  if Idx < 0 then Idx := FRig.JointIndexByName('Root');
  if Idx < 0 then Exit;
  P := FRig.JointBindPos(Idx);
  Result := Vector3(P.X, P.Y, P.Z);
end;

procedure TTripoRiderScene.ApplyBikeAlignedSpace;
begin
  FFileNeedsYaw := False;
  FFileBaseYaw := 0;
  FLegPlaneHint := Vector3(1, 0, 0);
  FArmPlaneHint := Vector3(-1, 0, 0);
  FLeanAxis := Vector3(0, 0, 1);
  FFlareAxis := Vector3(0, 0, 1);
end;

procedure TTripoRiderScene.ApplyMixamoFileSpace;
begin
  { FILE: +Z forward, +X right. Display-only +90° Y maps face → bike +X.
    IK / hints / lean / flare stay in FILE — InverseTransform undoes Scene.R. }
  FFileNeedsYaw := True;
  FFileBaseYaw := Pi / 2;
  FLegPlaneHint := Vector3(0, 0, 1);
  FArmPlaneHint := Vector3(0, 0, -1);
  FLeanAxis := Vector3(-1, 0, 0);
  FFlareAxis := Vector3(1, 0, 0);
end;

function TTripoRiderScene.BindLateral: TVector3;
var
  L, R: TVector3;
begin
  Result := Vector3(0, 0, 0);
  if BindV('L_Hand', L) and BindV('R_Hand', R) then
    Result := Vector3(L.X - R.X, L.Y - R.Y, L.Z - R.Z)
  else if BindV('L_Upperarm', L) and BindV('R_Upperarm', R) then
    Result := Vector3(L.X - R.X, L.Y - R.Y, L.Z - R.Z)
  else if BindV('L_Clavicle', L) and BindV('R_Clavicle', R) then
    Result := Vector3(L.X - R.X, L.Y - R.Y, L.Z - R.Z);
end;

procedure TTripoRiderScene.ConfigureFileSpace;
var
  Lat: TVector3;
begin
  ApplyBikeAlignedSpace;
  if (not FLoaded) or (FRig = nil) then Exit;
  Lat := BindLateral;
  { Mixamo T/A-pose: arms along ±X so |L-R|.X > |L-R|.Z.
    Armature-baked +90° Y: that axis lands on ±Z → already bike-aligned. }
  if Sqr(Lat.X) + Sqr(Lat.Z) < 0.0025 then Exit;
  if Abs(Lat.X) >= Abs(Lat.Z) then
    ApplyMixamoFileSpace;
  FBaseOrientDone := False;
end;

function TTripoRiderScene.OrientQuat(YawRad: Single): TTripoVec4;
var
  qy: TTripoVec4;
begin
  if not FBaseOrientDone then FBaseOrientQ := RigBaseOrientQuat;
  qy := QuatFromAxisAngle(0, 1, 0, YawRad + FFileBaseYaw);
  Result := QuatNormalize(QuatMul(qy, FBaseOrientQ));
end;

function TTripoRiderScene.RigBaseOrientQuat: TTripoVec4;
const
  cUpDead   = 8.0;    { deg: spine within this of +Y -> no up correction (already upright) }
  cLatDead  = 12.0;   { deg: facing within this of reference -> no correction }
  cTargetZ  = -1.0;   { reference rig has rider-LEFT (L_clav - R_clav) along -Z;
                        set to +1.0 if a corrected rig ends up facing backward }
var
  pel, hed, lcl, rcl: TVector3;
  up, lat, latXZ, yax: TTripoVec3;
  R1: TTripoVec4;
  curAng, tgtAng, dAng: Single;
begin
  Result.X := 0; Result.Y := 0; Result.Z := 0; Result.W := 1;   { identity }
  FBaseOrientDone := True;
  if (not FLoaded) or (FRig = nil) then Exit;
  if not BindV('Pelvis', pel) then
    if not BindV('Hip', pel) then Exit;
  if not BindV('Head', hed) then
    if not BindV('NeckTwist02', hed) then
      if not BindV('Spine02', hed) then Exit;

  { 1) upright: shortest arc taking the spine (pelvis->head) onto +Y, only when it is
       meaningfully off vertical (an already-upright rig is left exactly alone). }
  up  := V3Norm(V3(hed.X - pel.X, hed.Y - pel.Y, hed.Z - pel.Z));
  yax := V3(0, 1, 0);
  if V3Dot(up, yax) < Cos(DegToRad(cUpDead)) then R1 := QuatFromTo(up, yax)
  else begin R1.X := 0; R1.Y := 0; R1.Z := 0; R1.W := 1; end;

  { 2) facing: bring the rider-left axis (R->L clavicle) -- after the upright fix and
       flattened to the ground plane -- onto the reference -Z, by a rotation about +Y.
       Directed vector -> directed target, so 90 deg AND 180 deg mis-facings resolve
       unambiguously. Deadzoned so a correctly-built rig is not nudged. }
  Result := R1;
  { Mixamo facing is FileBaseYaw on Scene (OrientQuat), not a clavicle snap
    onto -Z — that one turned the rider backward (−X) and doubled with +90°. }
  if FFileNeedsYaw then Exit;
  { Facing: clavicles first. Bike-aligned / baked files only. }
  if not (BindV('L_Clavicle', lcl) and BindV('R_Clavicle', rcl)) then
    if not (BindV('L_Upperarm', lcl) and BindV('R_Upperarm', rcl)) then
      if not (BindV('L_Hand', lcl) and BindV('R_Hand', rcl)) then
      begin
        lcl := Vector3(0, 0, 0);
        rcl := Vector3(0, 0, 0);
      end;
  if (Sqr(lcl.X) + Sqr(lcl.Y) + Sqr(lcl.Z) +
      Sqr(rcl.X) + Sqr(rcl.Y) + Sqr(rcl.Z)) > 1e-8 then
  begin
    lat   := QuatRotateV3(R1, V3(lcl.X - rcl.X, lcl.Y - rcl.Y, lcl.Z - rcl.Z));
    latXZ := V3(lat.X, 0, lat.Z);
    if V3Len(latXZ) > 0.05 then
    begin
      latXZ  := V3Norm(latXZ);
      curAng := ArcTan2(latXZ.X, latXZ.Z);          { 0 = along +Z }
      if cTargetZ < 0 then tgtAng := Pi else tgtAng := 0.0;
      dAng := tgtAng - curAng;
      while dAng >  Pi do dAng := dAng - 2*Pi;
      while dAng < -Pi do dAng := dAng + 2*Pi;
      if Abs(dAng) > DegToRad(cLatDead) then
        Result := QuatMul(QuatFromAxisAngle(0, 1, 0, dAng), R1);
    end;
  end;
end;

function TTripoRiderScene.OrientedRotationVec4(YawRad: Single): TVector4;
var q: TTripoVec4; s, ang: Single;
begin
  q := OrientQuat(YawRad);
  s := q.W; if s > 1 then s := 1; if s < -1 then s := -1;
  ang := 2.0 * ArcCos(s);
  if (Abs(q.X) + Abs(q.Y) + Abs(q.Z) < 1e-6) or (Abs(ang) < 1e-5) then
    Result := Vector4(0, 1, 0, 0)
  else
    Result := Vector4(q.X, q.Y, q.Z, ang);          { CGE normalizes the axis }
end;

function TTripoRiderScene.OrientedSeatOffset(YawRad, Scale: Single): TVector3;
var seat: TVector3; q: TTripoVec4; v: TTripoVec3;
begin
  if not ContactBindLocal('BottomContact', seat) then seat := PelvisBindLocal;
  q := OrientQuat(YawRad);
  v := QuatRotateV3(q, V3(seat.X * Scale, seat.Y * Scale, seat.Z * Scale));
  Result := Vector3(v.X, v.Y, v.Z);
end;

procedure TTripoRiderScene.AdaptPoseReach(var P: TRiderPose; const GripR, GripL: TVector3);
const
  SP: array[0..3] of string = ('Waist', 'Spine', 'Spine01', 'Spine02');
  ARM: array[0..1,0..2] of string = (('R_Upperarm','R_Forearm','R_Hand'),
                                    ('L_Upperarm','L_Forearm','L_Hand'));
var
  J, K, Side, Idx, UIdx, MIdx, EIdx: Integer;
  Exists: array[0..3] of Boolean;
  Pivot: array[0..3] of TTripoVec3;
  Shoulder: array[0..1] of TTripoVec3;
  Axis, V, W, Mid, Tip, Target, Hinge: TTripoVec3;
  Q: TTripoVec4;
  InRig: TVector3;
  Reach, A, B, C, Radius, ParallelV, ParallelW, Extra, Need: Single;
begin
  if (FRig = nil) or not P.SpineManual then Exit;
  for J := 0 to 3 do
  begin
    Idx := FRig.JointIndexByName(SP[J]);
    Exists[J] := Idx >= 0;
    Pivot[J] := FRig.JointBindPos(Idx);
  end;
  if not Exists[0] then Exit;
  Hinge := Pivot[0];
  for Side := 0 to 1 do
    Shoulder[Side] := FRig.JointBindPos(FRig.JointIndexByName(ARM[Side,0]));
  { Only five rigid points, not posing/skinning the rig. Arm/leg IK remains
    in GLSL. This small reach envelope prevents locked elbows on short arms
    or a long/low cockpit, without stretching limbs or moving the saddle. }
  for J := 0 to 3 do
    if Exists[J] then
    begin
      Q := RiderSpineDelta(FLeanAxis, P.SpineAngles[J], P.SpineYaw[J], P.SpineRoll[J]);
      for K := J + 1 to 3 do
        if Exists[K] then Pivot[K] := V3Add(Pivot[J], QuatRotateV3(Q, V3Sub(Pivot[K], Pivot[J])));
      for Side := 0 to 1 do
        Shoulder[Side] := V3Add(Pivot[J], QuatRotateV3(Q, V3Sub(Shoulder[Side], Pivot[J])));
    end;
  Axis := V3(FLeanAxis.X, FLeanAxis.Y, FLeanAxis.Z);
  Extra := 0;
  for Side := 0 to 1 do
  begin
    if ((Side = 0) and (P.HandPosR = 0)) or ((Side = 1) and (P.HandPosL = 0)) then Continue;
    UIdx := FRig.JointIndexByName(ARM[Side,0]);
    MIdx := FRig.JointIndexByName(ARM[Side,1]);
    EIdx := FRig.JointIndexByName(ARM[Side,2]);
    if (UIdx < 0) or (MIdx < 0) or (EIdx < 0) then Continue;
    Mid := FRig.JointBindPos(MIdx); Tip := FRig.JointBindPos(EIdx);
    Reach := 0.975 * (V3Len(V3Sub(Mid, FRig.JointBindPos(UIdx))) + V3Len(V3Sub(Tip, Mid)));
    if FContactValid[Side + 2] then Reach := Reach + 0.6 * V3Len(FContactLocal[Side + 2]);
    if Side = 0 then InRig := ParentToRig(GripR) else InRig := ParentToRig(GripL);
    Target := V3(InRig.X, InRig.Y, InRig.Z);
    if V3Len(V3Sub(Shoulder[Side], Target)) <= Reach then Continue;
    V := V3Sub(Shoulder[Side], Hinge); W := V3Sub(Target, Hinge);
    ParallelV := V3Dot(V, Axis); ParallelW := V3Dot(W, Axis);
    A := V3Dot(V, W) - ParallelV * ParallelW;
    B := -V3Dot(V3Cross(Axis, V), W); { negative pitch = forward hip hinge }
    Radius := Sqrt(A * A + B * B);
    if Radius < 1e-8 then Continue;
    C := (V3Dot(V,V) + V3Dot(W,W) - Reach * Reach) * 0.5 - ParallelV * ParallelW;
    Need := ArcTan2(B, A) - ArcCos(EnsureRange(C / Radius, -1.0, 1.0));
    Extra := Max(Extra, EnsureRange(RadToDeg(Need), 0.0, 30.0));
  end;
  P.SpineAngles[0] := P.SpineAngles[0] - Extra;
  P.SpineAngles[4] := P.SpineAngles[4] + Extra; { keep the authored gaze }
end;

procedure TTripoRiderScene.WritePoseToFields;
begin
  ApplyFramePose(FPose);
end;

procedure TTripoRiderScene.ApplyFramePose(const P: TRiderPose);
var i: Integer;
begin
  FTorsoLeanDeg    := P.TorsoLeanDeg;
  FSpineCurve      := P.SpineCurve;
  FSpineManual     := P.SpineManual;
  for i := 0 to 4 do FSpineAngles[i] := P.SpineAngles[i];
  FSpineYaw := P.SpineYaw; FSpineRoll := P.SpineRoll;
  FKneeFlare       := P.KneeFlare;
  FElbowFlare      := P.ElbowFlare;
  FArmPronationDegR := P.ArmPronationR;
  FArmPronationDegL := P.ArmPronationL;
  FShoulderRoundDeg := P.ShoulderRoundDeg;
  FHandLevel        := P.HandLevel;
  { OffsetX/Y/Z and AnkleFlex are consumed by the bike via CurrentPose. StanceHalf is a
    main calibration param now (TripoStanceHalf), not part of the pose. }
end;

procedure TTripoRiderScene.ApplyPose(const P: TRiderPose; Duration: Single);
begin
  if (not FHasPose) or (Duration <= 0) then
  begin
    FPose := P; FPoseAnimating := False; FHasPose := True;
    WritePoseToFields; Exit;
  end;
  FPoseFrom := FPose; FPoseTo := P;
  FPoseElapsed := 0; FPoseDur := Duration; FPoseAnimating := True;
end;

procedure TTripoRiderScene.AdvancePose(Dt: Single);
var a: Single;
begin
  if not FPoseAnimating then Exit;
  if Dt < 0 then Dt := 0;
  FPoseElapsed := FPoseElapsed + Dt;
  if FPoseDur <= 1e-6 then a := 1 else a := FPoseElapsed / FPoseDur;
  if a >= 1 then begin a := 1; FPoseAnimating := False; end;
  FPose := LerpRiderPose(FPoseFrom, FPoseTo, SmoothUnit(a));
  WritePoseToFields;
end;

function TTripoRiderScene.CurrentPose: TRiderPose;
begin
  Result := FPose;
end;

function ClipQuatSlerp(const A, B: TTripoVec4; T: Single): TTripoVec4;
var
  Dot, Ang, S0, S1, W: Single;
  Bx, By, Bz, Bw: Single;
begin
  Bx := B.X; By := B.Y; Bz := B.Z; Bw := B.W;
  Dot := A.X * Bx + A.Y * By + A.Z * Bz + A.W * Bw;
  if Dot < 0 then
  begin
    Bx := -Bx; By := -By; Bz := -Bz; Bw := -Bw;
    Dot := -Dot;
  end;
  if Dot > 0.9995 then
  begin
    Result.X := A.X + (Bx - A.X) * T;
    Result.Y := A.Y + (By - A.Y) * T;
    Result.Z := A.Z + (Bz - A.Z) * T;
    Result.W := A.W + (Bw - A.W) * T;
    Exit(QuatNormalize(Result));
  end;
  Ang := ArcCos(Dot);
  W := Sin(Ang);
  if Abs(W) < 1e-8 then
    Exit(A);
  S0 := Sin((1 - T) * Ang) / W;
  S1 := Sin(T * Ang) / W;
  Result.X := A.X * S0 + Bx * S1;
  Result.Y := A.Y * S0 + By * S1;
  Result.Z := A.Z * S0 + Bz * S1;
  Result.W := A.W * S0 + Bw * S1;
end;

function ClipReadAccFloats(const B: TBytes; BinOfs, BinLen: Integer;
  Accs, Views: TJSONArray; AccI: Integer; out Count, NComp: Integer): TSingleDynArray;
var
  Acc, View: TJSONObject;
  Ct, Stride, Start, I: Integer;
  Off: Integer;
begin
  Result := nil;
  Count := 0;
  NComp := 0;
  Acc := ObjAt(Accs, AccI);
  if Acc = nil then Exit;
  Count := IntOf(Acc, 'count', 0);
  NComp := TypeCount(StrOf(Acc, 'type', 'SCALAR'));
  Ct := IntOf(Acc, 'componentType', 0);
  if (Count <= 0) or (NComp <= 0) or (Ct <> 5126) then
  begin
    Count := 0;
    Exit;
  end;
  View := ObjAt(Views, IntOf(Acc, 'bufferView', -1));
  if View = nil then
  begin
    Count := 0;
    Exit;
  end;
  Start := BinOfs + IntOf(View, 'byteOffset', 0) + IntOf(Acc, 'byteOffset', 0);
  Stride := IntOf(View, 'byteStride', 0);
  if Stride <= 0 then
    Stride := NComp * 4;
  if Start + (Count - 1) * Stride + NComp * 4 > BinOfs + BinLen then
  begin
    Count := 0;
    Exit;
  end;
  SetLength(Result, Count * NComp);
  for I := 0 to Count - 1 do
  begin
    Off := Start + I * Stride;
    Move(B[Off], Result[I * NComp], NComp * SizeOf(Single));
  end;
end;

function ClipSampleRot(const Times: array of Single;
  const Rots: array of TTripoVec4; T: Single): TTripoVec4;
var
  I, N: Integer;
  U, Den: Single;
begin
  Result.X := 0; Result.Y := 0; Result.Z := 0; Result.W := 1;
  N := Length(Times);
  if (N <= 0) or (Length(Rots) < N) then Exit;
  if N = 1 then
    Exit(Rots[0]);
  if T <= Times[0] then
    Exit(Rots[0]);
  if T >= Times[N - 1] then
    Exit(Rots[N - 1]);
  I := 0;
  while (I < N - 2) and (Times[I + 1] < T) do
    Inc(I);
  Den := Times[I + 1] - Times[I];
  if Den < 1e-8 then
    Exit(Rots[I]);
  U := (T - Times[I]) / Den;
  Result := ClipQuatSlerp(Rots[I], Rots[I + 1], U);
end;

function TTripoRiderScene.LoadFileClip(const AFileName: string): Boolean;
var
  B: TBytes;
  JsonStr: string;
  BinOfs, BinLen, I, J, Ni, AccI, NComp, NKeys: Integer;
  Root, NodeO, Anim, Chan, Tgt, Samp: TJSONObject;
  NodesA, AnimsA, ChansA, SampsA, Accs, Views, RestA: TJSONArray;
  Data: TJSONData;
  Name, Path: string;
  Times, Vals: TSingleDynArray;
  RestQ: TTripoVec4;
  Slot: Integer;
begin
  Result := False;
  if FLoaded then
    CaptureFileClipPose;
  ClearFileClip;
  if (AFileName = '') or (not FileExists(AFileName)) then
  begin
    FLastError := 'Clip not found: ' + AFileName;
    Exit;
  end;
  B := LoadFileBytes(AFileName);
  if not ExtractGltfJson(B, JsonStr, BinOfs, BinLen) then
  begin
    FLastError := 'Clip is not a GLB: ' + AFileName;
    Exit;
  end;
  Data := GetJSON(JsonStr);
  if not (Data is TJSONObject) then
  begin
    Data.Free;
    FLastError := 'Clip JSON invalid: ' + AFileName;
    Exit;
  end;
  Root := TJSONObject(Data);
  try
    NodesA := ArrOf(Root, 'nodes');
    AnimsA := ArrOf(Root, 'animations');
    Accs := ArrOf(Root, 'accessors');
    Views := ArrOf(Root, 'bufferViews');
    if (NodesA = nil) or (AnimsA = nil) or (AnimsA.Count = 0) then
    begin
      FLastError := 'Clip has no animation: ' + AFileName;
      Exit;
    end;
    Anim := ObjAt(AnimsA, 0);
    ChansA := ArrOf(Anim, 'channels');
    SampsA := ArrOf(Anim, 'samplers');
    FFileClipName := StrOf(Anim, 'name', ChangeFileExt(ExtractFileName(AFileName), ''));
    FFileClipDur := 0;
    SetLength(FFileClipJoints, 0);
    if ChansA = nil then
    begin
      FLastError := 'Clip has no channels: ' + AFileName;
      Exit;
    end;
    for I := 0 to ChansA.Count - 1 do
    begin
      Chan := ObjAt(ChansA, I);
      Tgt := ObjOf(Chan, 'target');
      if Tgt = nil then Continue;
      Path := StrOf(Tgt, 'path', '');
      if Path <> 'rotation' then Continue;
      Ni := IntOf(Tgt, 'node', -1);
      NodeO := ObjAt(NodesA, Ni);
      if NodeO = nil then Continue;
      Name := CanonicalJointName(StrOf(NodeO, 'name', ''));
      if (Name = '') or SameText(Name, 'Armature') then Continue;
      Samp := ObjAt(SampsA, IntOf(Chan, 'sampler', -1));
      if Samp = nil then Continue;
      AccI := IntOf(Samp, 'input', -1);
      Times := ClipReadAccFloats(B, BinOfs, BinLen, Accs, Views, AccI, NKeys, NComp);
      if (NKeys <= 0) or (NComp <> 1) then Continue;
      AccI := IntOf(Samp, 'output', -1);
      Vals := ClipReadAccFloats(B, BinOfs, BinLen, Accs, Views, AccI, NKeys, NComp);
      if (NKeys <= 0) or (NComp < 4) then Continue;
      RestQ.X := 0; RestQ.Y := 0; RestQ.Z := 0; RestQ.W := 1;
      RestA := ArrOf(NodeO, 'rotation');
      if RestA <> nil then
      begin
        RestQ.X := ArrFloat(RestA, 0, 0);
        RestQ.Y := ArrFloat(RestA, 1, 0);
        RestQ.Z := ArrFloat(RestA, 2, 0);
        RestQ.W := ArrFloat(RestA, 3, 1);
      end;
      Slot := Length(FFileClipJoints);
      SetLength(FFileClipJoints, Slot + 1);
      FFileClipJoints[Slot].Name := Name;
      FFileClipJoints[Slot].RestQ := QuatNormalize(RestQ);
      SetLength(FFileClipJoints[Slot].Times, NKeys);
      SetLength(FFileClipJoints[Slot].Rots, NKeys);
      for J := 0 to NKeys - 1 do
      begin
        FFileClipJoints[Slot].Times[J] := Times[J];
        if Times[J] > FFileClipDur then
          FFileClipDur := Times[J];
        FFileClipJoints[Slot].Rots[J].X := Vals[J * NComp + 0];
        FFileClipJoints[Slot].Rots[J].Y := Vals[J * NComp + 1];
        FFileClipJoints[Slot].Rots[J].Z := Vals[J * NComp + 2];
        FFileClipJoints[Slot].Rots[J].W := Vals[J * NComp + 3];
        FFileClipJoints[Slot].Rots[J] := QuatNormalize(FFileClipJoints[Slot].Rots[J]);
      end;
    end;
    if Length(FFileClipJoints) = 0 then
    begin
      FLastError := 'Clip has no joint rotations: ' + AFileName;
      Exit;
    end;
    FFileClipLoaded := True;
    FLastError := '';
    Result := True;
  finally
    Root.Free;
  end;
end;

procedure TTripoRiderScene.CaptureFileClipPose;
var
  J, N: Integer;
begin
  FFileClipHasBlendFrom := False;
  if (FRig = nil) or (not FLoaded) then Exit;
  N := FRig.JointCount;
  if N <= 0 then Exit;
  SetLength(FFileClipBlendFrom, N);
  for J := 0 to N - 1 do
    FFileClipBlendFrom[J] := FRig.DeltaQuat(J);
  FFileClipHasBlendFrom := True;
end;

procedure TTripoRiderScene.ApplyFileClipDeltas(T, BlendA: Single);
var
  I, J, N: Integer;
  Src, NewD, FromD, Delta: TTripoVec4;
  HaveNew: Boolean;
  CQ: TQuaternion;
begin
  if FRig <> nil then
    FRig.ResetPose;
  N := 0;
  if FRig <> nil then
    N := FRig.JointCount;
  if (not FFileClipBlending) or (BlendA >= 1) then
  begin
    if FFileClipBlendToRest or (not FFileClipLoaded) then
    begin
      ResetPose;
      if FRig <> nil then
      begin
        FRig.ResetPose;
        FRig.ComputePose;
        ApplyHelmetFollow;
      end;
      Exit;
    end;
    for I := 0 to High(FFileClipJoints) do
    begin
      J := JointIndex(FFileClipJoints[I].Name);
      if J < 0 then Continue;
      Src := ClipSampleRot(FFileClipJoints[I].Times, FFileClipJoints[I].Rots, T);
      Delta := QuatMul(QuatConj(FFileClipJoints[I].RestQ), Src);
      if FRig <> nil then
        FRig.SetJointDeltaQuat(J, Delta);
      CQ := Quaternion(Vector4(Delta.X, Delta.Y, Delta.Z, Delta.W));
      SetJointDelta(J, CQ);
    end;
  end
  else
  begin
    for J := 0 to N - 1 do
    begin
      NewD.X := 0; NewD.Y := 0; NewD.Z := 0; NewD.W := 1;
      HaveNew := False;
      if FFileClipLoaded and (not FFileClipBlendToRest) then
        for I := 0 to High(FFileClipJoints) do
          if SameText(FFileClipJoints[I].Name, FRig.JointName[J]) then
          begin
            Src := ClipSampleRot(FFileClipJoints[I].Times, FFileClipJoints[I].Rots, T);
            NewD := QuatMul(QuatConj(FFileClipJoints[I].RestQ), Src);
            HaveNew := True;
            Break;
          end;
      if FFileClipHasBlendFrom and (J <= High(FFileClipBlendFrom)) then
        FromD := FFileClipBlendFrom[J]
      else
      begin
        FromD.X := 0; FromD.Y := 0; FromD.Z := 0; FromD.W := 1;
      end;
      if (not HaveNew) and (not FFileClipHasBlendFrom) then Continue;
      Delta := ClipQuatSlerp(FromD, NewD, BlendA);
      FRig.SetJointDeltaQuat(J, Delta);
      CQ := Quaternion(Vector4(Delta.X, Delta.Y, Delta.Z, Delta.W));
      SetJointDelta(J, CQ);
    end;
  end;
  if FRig <> nil then
  begin
    FRig.ComputePose;
    ApplyHelmetFollow;
  end;
end;

procedure TTripoRiderScene.ClearFileClip;
begin
  FFileClipPlaying := False;
  FFileClipLoaded := False;
  FFileClipTime := 0;
  FFileClipDur := 0;
  FFileClipName := '';
  FFileClipBlending := False;
  FFileClipBlendToRest := False;
  SetLength(FFileClipJoints, 0);
end;

procedure TTripoRiderScene.PlayFileClip(ALoop: Boolean; ABlendSec: Single;
  AStartTime: Single);
var
  Blend: Single;
begin
  if not FFileClipLoaded then Exit;
  if ABlendSec >= 0 then
    Blend := ABlendSec
  else
    Blend := FFileClipBlendDur;
  if Blend < 0 then Blend := 0;
  if (not FFileClipHasBlendFrom) and FLoaded then
    CaptureFileClipPose;
  FFileClipLoop := ALoop;
  if (AStartTime > 0) and (FFileClipDur > 1e-6) then
    FFileClipTime := AStartTime - FFileClipDur * Floor(AStartTime / FFileClipDur)
  else if AStartTime > 0 then
    FFileClipTime := AStartTime
  else
    FFileClipTime := 0;
  FFileClipPlaying := True;
  FFileClipBlendToRest := False;
  FFileClipBlending := FFileClipHasBlendFrom and (Blend > 1e-4);
  FFileClipBlendT := 0;
  FFileClipBlendLen := Blend;
  if FLoaded then
    AdvanceFileClip(0);
end;

procedure TTripoRiderScene.StopFileClip;
begin
  if FLoaded and (FFileClipPlaying or FFileClipLoaded or FFileClipBlending) then
    CaptureFileClipPose;
  FFileClipPlaying := False;
  FFileClipTime := 0;
  FFileClipBlendToRest := True;
  if FFileClipHasBlendFrom and (FFileClipBlendDur > 1e-4) and FLoaded then
  begin
    FFileClipBlending := True;
    FFileClipBlendT := 0;
    FFileClipBlendLen := FFileClipBlendDur;
    AdvanceFileClip(0);
  end
  else
  begin
    FFileClipBlending := False;
    if FLoaded then
    begin
      ResetPose;
      if FRig <> nil then
      begin
        FRig.ResetPose;
        FRig.ComputePose;
      end;
    end;
  end;
end;

procedure TTripoRiderScene.AdvanceFileClip(Dt: Single);
var
  T, A, U: Single;
begin
  if not FLoaded then Exit;
  if (not FFileClipPlaying) and (not FFileClipBlending) then Exit;
  T := 0;
  A := 1;
  if FFileClipBlending then
  begin
    { Hold the incoming clip on its first pose while we slerp from the
      outgoing last pose — "blend between the two end poses". }
    FFileClipBlendT := FFileClipBlendT + Dt;
    if FFileClipBlendLen <= 1e-4 then
      U := 1
    else
      U := FFileClipBlendT / FFileClipBlendLen;
    if U >= 1 then
    begin
      U := 1;
      FFileClipBlending := False;
      FFileClipHasBlendFrom := False;
    end;
    A := U * U * (3 - 2 * U);
    T := FFileClipTime;
  end
  else if FFileClipPlaying and FFileClipLoaded then
  begin
    FFileClipTime := FFileClipTime + Dt;
    T := FFileClipTime;
    if FFileClipDur > 1e-6 then
    begin
      if FFileClipLoop then
      begin
        T := T - FFileClipDur * Floor(T / FFileClipDur);
        FFileClipTime := T;
      end
      else if T > FFileClipDur then
      begin
        T := FFileClipDur;
        FFileClipPlaying := False;
      end;
    end;
  end;
  ApplyFileClipDeltas(T, A);
end;

function TTripoRiderScene.FileClipPlaying: Boolean;
begin
  Result := FFileClipPlaying;
end;

function TTripoRiderScene.FileClipBusy: Boolean;
begin
  Result := FFileClipPlaying or FFileClipBlending;
end;

function TTripoRiderScene.FileClipName: string;
begin
  Result := FFileClipName;
end;

function TTripoRiderScene.FileClipDuration: Single;
begin
  Result := FFileClipDur;
end;

function TTripoRiderScene.LegReach: Single;
var Ti, Ci, Fi: Integer;
begin
  Result := 0;
  if FRig = nil then Exit;
  Ti := FRig.JointIndexByName('R_Thigh');
  Ci := FRig.JointIndexByName('R_Calf');
  Fi := FRig.JointIndexByName('R_Foot');
  if (Ti < 0) or (Ci < 0) or (Fi < 0) then Exit;
  Result := V3Len(V3Sub(FRig.JointBindPos(Ci), FRig.JointBindPos(Ti)))
          + V3Len(V3Sub(FRig.JointBindPos(Fi), FRig.JointBindPos(Ci)));
end;

function TTripoRiderScene.ContactNodeWorld(const ANodeName: string; out P: TVector3): Boolean;
var N: TX3DNode;
begin
  P := Vector3(0, 0, 0);
  Result := False;
  { Primary: the marker is its own top-level node in the loaded scene, so its
    local Translation is its world origin (the bone head). The node's own scale
    does not affect its origin, so nothing to undo. }
  if FScene <> nil then
  begin
    N := FScene.Node(TTransformNode, ANodeName, [fnNilOnMissing]);
    if N is TTransformNode then
    begin
      P := TTransformNode(N).Translation;
      Exit(True);
    end;
  end;
  { Fallback: a rig that authored the contact directly as a main-skin joint. }
  if (FRig <> nil) and BindV(ANodeName, P) then
    Result := True;
end;

function TTripoRiderScene.ContactBindLocal(const AName: string; out P: TVector3): Boolean;
begin
  Result := ContactNodeWorld(AName, P);
end;

function TTripoRiderScene.ContactOffsetParent(const JointName, ContactName: string;
  out OffParent: TVector3): Boolean;
var pj3: TTripoVec3; pj, pc: TVector3; ji: Integer;
begin
  OffParent := Vector3(0, 0, 0);
  Result := False;
  if not ContactNodeWorld(ContactName, pc) then Exit;   { marker bone head }
  if FRig = nil then Exit;
  ji := FRig.JointIndexByName(JointName);               { IK end joint (main skin) }
  if ji < 0 then Exit;
  pj3 := FRig.JointBindPos(ji);
  pj := Vector3(pj3.X, pj3.Y, pj3.Z);
  { both -> parent frame; the shared translation cancels, leaving the offset
    that shifts the bike target so the marker (not the joint) lands on it. }
  OffParent := FScene.Transform.MultPoint(pj) - FScene.Transform.MultPoint(pc);
  Result := True;
end;

function TTripoRiderScene.ContactLocalOffset(LimbIdx: Integer; out P: TVector3): Boolean;
begin
  P := Vector3(0, 0, 0);
  Result := (LimbIdx >= 0) and (LimbIdx <= 3) and FContactValid[LimbIdx];
  if Result then
    P := Vector3(FContactLocal[LimbIdx].X, FContactLocal[LimbIdx].Y, FContactLocal[LimbIdx].Z);
end;

function TTripoRiderScene.PosedContactRig(LimbIdx: Integer; out PRig: TTripoVec3): Boolean;
const
  JN: array[0..3] of string = ('R_Foot', 'L_Foot', 'R_Hand', 'L_Hand');
var
  ei, i, k, vi, jpi: Integer;
  jp, acc, sp: TTripoVec3;
  jr: TTripoVec4;
  ww, vw: Single;
begin
  PRig := V3(0, 0, 0);
  Result := False;
  if (LimbIdx < 0) or (LimbIdx > 3) or (FRig = nil) then Exit;

  { BLENDED-SKIN reconstruction for FEET and HANDS: skin the marker with the SAME
    blended bone weights as the nearest rendered vertices, so it tracks the deforming
    SURFACE the GPU actually draws — not a single bone. The cleat region of the boot
    carries weight on R_Foot AND R_Calf (the ankle blend), so a pure R_Foot rigid
    offset slides off the rendered sole as the knee flexes through the stroke; the
    blend follows it. (Hands had this already because the palm is partly weighted to
    a forearm-twist bone — the feet have the exact same problem at the ankle.)
    posed = Σ_vert idw_vert · ( Σ_k w_k · SkinMatrix[joint_k] · markerBind ). }
  if FCSkinValid[LimbIdx] and (Length(FRig.SkinMatrix) > 0)
     and (Length(FCSkinVtx[LimbIdx]) > 0) then
  begin
    acc := V3(0, 0, 0);
    for i := 0 to High(FCSkinVtx[LimbIdx]) do
    begin
      vi := FCSkinVtx[LimbIdx][i];
      vw := FCSkinIDW[LimbIdx][i];
      if (vi < 0) or (vi >= FRig.VertexCount) then Continue;
      sp := V3(0, 0, 0);
      for k := 0 to 3 do
      begin
        ww := FRig.Weights[vi][k];
        if ww <= 0 then Continue;
        jpi := FRig.Joints[vi][k];                 { palette idx = rig joint idx }
        if (jpi < 0) or (jpi >= Length(FRig.SkinMatrix)) then Continue;
        sp := V3Add(sp, V3Scale(Mat4MulPoint(FRig.SkinMatrix[jpi], FCSkinM[LimbIdx]), ww));
      end;
      acc := V3Add(acc, V3Scale(sp, vw));
    end;
    PRig := acc;
    Result := True;
    Exit;
  end;

  { Fallback (limb without skin data): single end-bone RIGID reconstruction =
    foot/hand bone posed world transform * baked local offset (FContactLocal). }
  if not FContactValid[LimbIdx] then Exit;
  ei := FRig.JointIndexByName(JN[LimbIdx]);
  if ei < 0 then Exit;
  jp := FRig.JointWorldPos(ei);
  jr := FRig.JointWorldRot(ei);
  PRig := V3Add(jp, QuatRotateV3(jr, FContactLocal[LimbIdx]));
  Result := True;
end;

function TTripoRiderScene.PosedContactParent(LimbIdx: Integer; out P: TVector3): Boolean;
var
  pr: TTripoVec3;
begin
  P := Vector3(0, 0, 0);
  Result := PosedContactRig(LimbIdx, pr);
  if Result then P := FScene.Transform.MultPoint(Vector3(pr.X, pr.Y, pr.Z));
end;

function TTripoRiderScene.PosedJointParent(const JointName: string; out P: TVector3): Boolean;
var
  ji: Integer;
  jp: TTripoVec3;
begin
  P := Vector3(0, 0, 0);
  Result := False;
  if FRig = nil then Exit;
  ji := FRig.JointIndexByName(JointName);
  if ji < 0 then Exit;
  jp := FRig.JointWorldPos(ji);                          { posed joint origin (rig frame) }
  P := FScene.Transform.MultPoint(Vector3(jp.X, jp.Y, jp.Z));   { -> parent (bike) frame }
  Result := True;
end;

function TTripoRiderScene.BindJointParent(const JointName: string; out P: TVector3): Boolean;
var
  ji: Integer;
  jp: TTripoVec3;
begin
  P := Vector3(0, 0, 0);
  Result := False;
  if FRig = nil then Exit;
  ji := FRig.JointIndexByName(JointName);
  if ji < 0 then Exit;
  jp := FRig.JointBindPos(ji);                           { bind joint origin (rig frame) }
  P := FScene.Transform.MultPoint(Vector3(jp.X, jp.Y, jp.Z));   { -> parent (bike) frame }
  Result := True;
end;

function TTripoRiderScene.FootSagittalRoll(Side: Integer): Single;
var
  nm: string;
  ji, idx: Integer;
  d, vBind, vNow: TTripoVec3;
  bindRot, poseRot: TTripoVec4;
begin
  Result := 0;
  if FRig = nil then Exit;
  if Side = 0 then begin nm := 'R_Foot'; idx := 0; end
  else            begin nm := 'L_Foot'; idx := 1; end;
  if not FContactValid[idx] then Exit;            { need the baked offset }
  ji := FRig.JointIndexByName(nm);
  if ji < 0 then Exit;

  { The cleat is rigidly attached to the foot bone at the baked offset d (cleat in
    the foot's LOCAL frame). The world vector ankle->cleat = footRot * d. As the
    foot poses, this vector swings; the pedal must turn by the SAME swing (in the
    sagittal X-Y plane) to stay under the cleat. We measure that swing relative to
    the bind pose, so the pedal is level when the foot is at rest. This uses the
    real offset and captures off-Z foot rotation too, unlike a pure Z-twist. }
  d := FContactLocal[idx];
  bindRot := Mat4ToQuat(FRig.BindWorld[ji]);      { foot orientation at rest }
  poseRot := FRig.JointWorldRot(ji);              { foot orientation now (posed) }
  vBind := QuatRotateV3(bindRot, d);              { ankle->cleat at rest }
  vNow  := QuatRotateV3(poseRot, d);              { ankle->cleat now }

  { sagittal-plane angle (about Z) swept by the offset vector since bind.
    atan2(Y,X) keeps the +Z sign convention the ankling FootPitch used. }
  Result := ArcTan2(vNow.Y, vNow.X) - ArcTan2(vBind.Y, vBind.X);
  while Result >  Pi do Result := Result - 2 * Pi;
  while Result < -Pi do Result := Result + 2 * Pi;
end;

procedure TTripoRiderScene.DiagContactDump(Lines: TStrings;
  const PedalR, PedalL, GripR, GripL: TVector3);

  function F(const P: TVector3): string;
  begin
    Result := Format('(%8.4f %8.4f %8.4f)', [P.X, P.Y, P.Z]);
  end;

  { uniform-ish scale of a rig matrix = lengths of its transformed basis vectors }
  function MatScale(const M: TTripoMat4): TVector3;
  var o, ux, uy, uz: TTripoVec3;
  begin
    o  := Mat4MulPoint(M, V3(0, 0, 0));
    ux := Mat4MulPoint(M, V3(1, 0, 0));
    uy := Mat4MulPoint(M, V3(0, 1, 0));
    uz := Mat4MulPoint(M, V3(0, 0, 1));
    Result := Vector3(V3Len(V3Sub(ux, o)), V3Len(V3Sub(uy, o)), V3Len(V3Sub(uz, o)));
  end;

  function SceneScale: TVector3;
  var o, ux, uy, uz: TVector3;
  begin
    o  := FScene.Transform.MultPoint(Vector3(0, 0, 0));
    ux := FScene.Transform.MultPoint(Vector3(1, 0, 0));
    uy := FScene.Transform.MultPoint(Vector3(0, 1, 0));
    uz := FScene.Transform.MultPoint(Vector3(0, 0, 1));
    Result := Vector3((ux - o).Length, (uy - o).Length, (uz - o).Length);
  end;

  { straight-line length between two bind joints (= the IK bone length), rig frame }
  function BoneLen(const A, B: string): Single;
  var ia, ib: Integer;
  begin
    Result := 0;
    ia := FRig.JointIndexByName(A); ib := FRig.JointIndexByName(B);
    if (ia < 0) or (ib < 0) then Exit;
    Result := V3Len(V3Sub(FRig.JointBindPos(ib), FRig.JointBindPos(ia)));
  end;

  { whole-skeleton scale audit: BIND scale should be ~objScale (the rendered height);
    ~objScale^2 means the double-scale fix did NOT take (file not rebuilt / rig not
    reloaded). Also prints the straight leg/arm reach so a genuine geometry limit is
    visible vs a scale artefact. }
  procedure Audit;
  var pj: Integer;
  begin
    pj := FRig.JointIndexByName('Pelvis');
    if (pj >= 0) and (Length(FRig.BindWorld) > pj) and (Length(FRig.WorldPose) > pj) then
      Lines.Add('  FRig scale @Pelvis: BIND=' + F(MatScale(FRig.BindWorld[pj])) +
                '  POSE=' + F(MatScale(FRig.WorldPose[pj])) +
                '   (BIND ~objScale OK; ~objScale^2 = fix NOT active)');
    Lines.Add('  straight reach: leg(thigh+calf)=' +
      Format('%.4f', [BoneLen('R_Thigh', 'R_Calf') + BoneLen('R_Calf', 'R_Foot')]) +
      '   arm(upperarm+forearm)=' +
      Format('%.4f', [BoneLen('R_Upperarm', 'R_Forearm') + BoneLen('R_Forearm', 'R_Hand')]));
  end;

  procedure One(Idx: Integer; const Upper, Mid, EndJoint, MarkerName, Tag: string;
    const TgtParent: TVector3);
  var
    ei, ui: Integer;
    mbind: TVector3;
    jpR, mkQuat, mkSkin, jbr, ofs, rootP: TTripoVec3;
    jrQ: TTripoVec4;
    jPar, quatPar, skinPar, mkNodePar, rootPar, tgtRig: TVector3;
    haveM, haveSkin: Boolean;
    L1, L2, reach, dist: Single;
    ii, kk, jj, v0: Integer;                 { blended-surface cleat report }
    ww: Single;
    mkBlend, spv: TTripoVec3;
    blendPar, sbPar: TVector3;
    blendStr: string;
  begin
    Lines.Add('  --- ' + Tag + '  (' + EndJoint + ' / ' + MarkerName + ') ---');
    ei := FRig.JointIndexByName(EndJoint);
    ui := FRig.JointIndexByName(Upper);
    if ei < 0 then begin Lines.Add('    (joint missing)'); Exit; end;
    haveSkin := (Length(FRig.SkinMatrix) > ei) and (Length(FRig.WorldPose) > ei);

    haveM := ContactNodeWorld(MarkerName, mbind);     { marker model-space (bind) }
    jpR := FRig.JointWorldPos(ei);
    jrQ := FRig.JointWorldRot(ei);
    jbr := FRig.JointBindPos(ei);
    jPar := FScene.Transform.MultPoint(Vector3(jpR.X, jpR.Y, jpR.Z));

    Lines.Add('    target (bike)      = ' + F(TgtParent));
    if haveSkin then
      Lines.Add('    joint posed        = ' + F(jPar) + '   rigScale@joint=' + F(MatScale(FRig.WorldPose[ei])))
    else
      Lines.Add('    joint posed        = ' + F(jPar));

    if (Length(FRig.BindWorld) > ei) then
      Lines.Add('    BIND scale @joint  = ' + F(MatScale(FRig.BindWorld[ei])) +
                '   (want ~objScale; ~objScale^2 = double-scale)');

    L1 := BoneLen(Upper, Mid); L2 := BoneLen(Mid, EndJoint); reach := L1 + L2;
    Lines.Add(Format('    bones: L1(%s->%s)=%.4f  L2(%s->%s)=%.4f  straight reach=%.4f',
      [Upper, Mid, L1, Mid, EndJoint, L2, reach]));

    if FContactValid[Idx] then
    begin
      ofs := FContactLocal[Idx];
      Lines.Add(Format('    baked offset (rig) = (%8.4f %8.4f %8.4f)  len=%.4f',
        [ofs.X, ofs.Y, ofs.Z, V3Len(ofs)]));
    end;

    if haveM then
      Lines.Add(Format('    markerWorld(rig)=%s  jointBind(rig)=%s  |Delta|=%.4f' +
        '   (Delta ~= offset len; large at a HIGH joint = frames still scaled apart)',
        [F(mbind), F(Vector3(jbr.X, jbr.Y, jbr.Z)),
         (mbind - Vector3(jbr.X, jbr.Y, jbr.Z)).Length]));

    if ui >= 0 then
    begin
      rootP := FRig.JointWorldPos(ui);
      rootPar := FScene.Transform.MultPoint(Vector3(rootP.X, rootP.Y, rootP.Z));
      tgtRig := ParentToRig(TgtParent);
      dist := (Vector3(rootP.X, rootP.Y, rootP.Z) - tgtRig).Length;
      if dist > reach + 1e-4 then
        Lines.Add(Format('    REACH: root(posed)=%s  dist->target=%.4f  reach=%.4f' +
          '  >> CLAMPED, short by %.4f', [F(rootPar), dist, reach, dist - reach]))
      else
        Lines.Add(Format('    REACH: root(posed)=%s  dist->target=%.4f  reach=%.4f' +
          '  -> OK (slack %.4f)', [F(rootPar), dist, reach, reach - dist]));
    end;

    if FContactValid[Idx] then
    begin
      mkQuat := V3Add(jpR, QuatRotateV3(jrQ, FContactLocal[Idx]));
      quatPar := FScene.Transform.MultPoint(Vector3(mkQuat.X, mkQuat.Y, mkQuat.Z));
      Lines.Add('    cleat QUAT (aimed) = ' + F(quatPar) +
                '   miss=' + Format('%.4f', [(quatPar - TgtParent).Length]));
    end
    else
      Lines.Add('    cleat QUAT         = (no baked offset for this limb)');

    if haveM and haveSkin then
    begin
      mkSkin := Mat4MulPoint(FRig.SkinMatrix[ei], V3(mbind.X, mbind.Y, mbind.Z));
      skinPar := FScene.Transform.MultPoint(Vector3(mkSkin.X, mkSkin.Y, mkSkin.Z));
      mkNodePar := FScene.Transform.MultPoint(mbind);
      Lines.Add('    cleat SKIN (real)  = ' + F(skinPar) +
                '   miss=' + Format('%.4f', [(skinPar - TgtParent).Length]));
      Lines.Add('    marker bind/static = ' + F(mkNodePar));
    end
    else
      Lines.Add('    cleat SKIN         = (marker node or skin matrix unavailable)');

    { Blended-surface cleat: skin the marker with the SAME weights as the nearest
      rendered vertices (linear-blend skin, exactly what the GPU does to the mesh).
      If the surface is multi-bone this diverges from the single-bone SKIN above as
      the limb poses — that divergence is the drift you saw, and the blended point
      is where the debug sphere now sits (fixed on the boot). }
    if FCSkinValid[Idx] and (Length(FRig.SkinMatrix) > ei) and (Length(FCSkinVtx[Idx]) > 0) then
    begin
      mkBlend := V3(0, 0, 0);
      for ii := 0 to High(FCSkinVtx[Idx]) do
      begin
        v0 := FCSkinVtx[Idx][ii];
        spv := V3(0, 0, 0);
        for kk := 0 to 3 do
        begin
          ww := FRig.Weights[v0][kk];
          if ww <= 0 then Continue;
          jj := FRig.Joints[v0][kk];
          if (jj < 0) or (jj >= Length(FRig.SkinMatrix)) then Continue;
          spv := V3Add(spv, V3Scale(Mat4MulPoint(FRig.SkinMatrix[jj], FCSkinM[Idx]), ww));
        end;
        mkBlend := V3Add(mkBlend, V3Scale(spv, FCSkinIDW[Idx][ii]));
      end;
      blendPar := FScene.Transform.MultPoint(Vector3(mkBlend.X, mkBlend.Y, mkBlend.Z));
      spv  := Mat4MulPoint(FRig.SkinMatrix[ei], FCSkinM[Idx]);   { single-bone ref }
      sbPar := FScene.Transform.MultPoint(Vector3(spv.X, spv.Y, spv.Z));
      Lines.Add('    cleat BLEND (boot) = ' + F(blendPar) +
                '   vs single-bone d=' + Format('%.4f', [(blendPar - sbPar).Length]) +
                '  (d>0 => surface IS multi-bone; sphere sits here now)');
      v0 := FCSkinVtx[Idx][0];                                  { dominant bones }
      blendStr := '';
      for kk := 0 to 3 do
        if FRig.Weights[v0][kk] > 0.001 then
        begin
          jj := FRig.Joints[v0][kk];
          if (jj >= 0) and (jj < FRig.JointCount) then
            blendStr := blendStr +
              Format('%s=%.2f ', [FRig.JointName[jj], FRig.Weights[v0][kk]]);
        end;
      Lines.Add('    nearest-vtx weights= ' + blendStr);
    end;
  end;

begin
  if (FRig = nil) or (FScene = nil) then
  begin
    Lines.Add('  (rider not ready for contact diagnostics)');
    Exit;
  end;
  Lines.Add('  scene(rider) scale = ' + F(SceneScale));
  { helmet accessory diagnostics: is the follow alive and does the head's
    skin matrix actually carry the pose? }
  if FHelmetNode <> nil then
    Lines.Add(Format('  helmet: joint="%s"  applies=%d  nodeT=%s  bindT=%s',
      [FRig.JointName[FHelmetHeadJ], FHelmetApplies,
       F(FHelmetNode.Translation), F(FHelmetBindT)]))
  else
    Lines.Add('  helmet: not bound (node absent or joint chain unusable — see load log)');
  Audit;
  Lines.Add('');
  One(0, 'R_Thigh',    'R_Calf',    'R_Foot', 'BoatClipseR', 'RIGHT FOOT', PedalR);
  One(1, 'L_Thigh',    'L_Calf',    'L_Foot', 'BoatClipseL', 'LEFT FOOT',  PedalL);
  One(2, 'R_Upperarm', 'R_Forearm', 'R_Hand', 'ArmContactR', 'RIGHT HAND', GripR);
  One(3, 'L_Upperarm', 'L_Forearm', 'L_Hand', 'ArmContactL', 'LEFT HAND',  GripL);
end;

initialization
  InitCriticalSection(GDyeGeomLock);

finalization
  DoneCriticalSection(GDyeGeomLock);

end.

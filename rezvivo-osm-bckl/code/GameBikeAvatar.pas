{
  GameBikeAvatar — loads a parametric bike+rider model from JSON
  and applies it to a TCastleScene for use as the player avatar.

  The bike model is built facing +X.  The game physics system applies
  ModelBaseYRotation (-Pi/2) to Scene.Rotation, which maps -X to -Z
  (CGE forward).  So we rotate BikeRoot by 180 deg to flip +X to -X.

  Usage:
    LoadBikeAvatarFromJSON('castle-data:/bike_road.json', SceneAvatar);
}
unit GameBikeAvatar;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  CastleScene, X3DNodes, BikeParametric, RiderTripo;

var
  { Session-only MCP benchmark override. Empty uses the player's selection. }
  PerformanceRiderModel: string = '';

{ Build a bike+rider model from a JSON configuration file and load it
  into AScene.  The JSON path can be a castle-data:/ URI or an absolute
  file path.  AScene's previous content is replaced.
  Returns the TX3DRootNode that was loaded (owned by AScene). }
function LoadBikeAvatarFromJSON(const AJsonUrl: string;
  AScene: TCastleScene): TX3DRootNode;

{ Build a TBikeInstance with LOD from a JSON config file.
  Bicycle groups and the rider share one scene. StripEnvironment and
  ReorientBikeRoot are applied once to that scene root. }
function LoadBikeInstanceFromJSON(const AJsonUrl: string;
  AOwner: TComponent;
  LOD3Dist: Single = 15.0;
  LOD2Dist: Single = 40.0;
  LOD1Dist: Single = 80.0): TBikeInstance;

{ Same but builds from a JSON string. AAttachRider=False — только геометрия
  байка; caller стейджит cloth-dye preset и сам зовёт AttachTripoRiderFromJSON. }
function LoadBikeInstanceFromJSONString(const AJsonText: string;
  AOwner: TComponent;
  LOD3Dist: Single = 15.0;
  LOD2Dist: Single = 40.0;
  LOD1Dist: Single = 80.0;
  AAttachRider: Boolean = True;
  AUseLod: Boolean = True;
  AAutoFitRider: Boolean = False): TBikeInstance;

{ Монтирует tripoRider из JSON в уже собранный инстанс. }
procedure AttachTripoRiderFromJSON(Inst: TBikeInstance; const AJsonText: string;
  Prepared: TTripoGlbPrepared = nil);

{ Selected bike URL: Insights provides geometry overrides for the base bike.
  Rider postures are defined independently in RiderPoseCatalog. }
function ResolveActiveBikeJsonUrl: string;

{ Base JSON used to build the bicycle geometry and attach the avatar. }
function ResolveActiveBikeBuildUrl: string;

{ castle-data:/ или file:// → путь на диске. Если URI не резолвится,
  но AUrl уже существующий файл — возвращает AUrl. }
function BikeJsonUrlToFilename(const AUrl: string): string;

{ Подмена/добавление tripoRider.path в тексте bike JSON (для превью Байкфита). }
function InjectRiderPath(const AJsonText, ARiderGlb: string; UseProfile:Boolean=True): string;

{ Загрузка с учётом Байкфита: bike JSON + подмена tripoRider.path на
  SelectedRiderGlb (если задан). }
function LoadActiveBikeInstance(AOwner: TComponent;
  LOD3Dist: Single = 15.0;
  LOD2Dist: Single = 40.0;
  LOD1Dist: Single = 80.0): TBikeInstance;

{ Рост/inseam в см относительно rest-меша, bulk/belly — доли (0 = как в модели). }
procedure ApplyRiderShapeAdjustments(Inst: TBikeInstance;
  HeightCm, InseamCm, Bulk, Belly: Single);

{ Байкфит: knee flare / ankle flex поверх позы (не из RiderPoseCatalog). }
procedure ApplyFitKneeAnkle(Inst: TBikeInstance; KneeFlare, AnkleFlex: Single);

{ Применить к инстансу цвета, сохранённые на вкладке Байкфит
  (Settings.BikeFitColors: 10 hex-csv — 7 слотов одежды, рама, обода, шлем;
  пустая строка = выкл). Одежда стейджится в preset и запекается при
  следующем LoadTripoRider / AttachTripoRiderFromJSON — без повторной
  загрузки glb. Шлем — live tint, если райдер уже смонтирован. }
procedure ApplyBikeFitColorsToInstance(Inst: TBikeInstance);

{ Helper procedures — also used by gameviewplay for incremental build assembly }
procedure StripEnvironmentNodes(Root: TX3DRootNode);
procedure ReorientBikeRoot(Root: TX3DRootNode);

implementation


uses GameRiderWardrobe, RiderBodyParameters, RiderHair, RiderHeadAppearance, GameUserData,
  SysUtils, Math, fpjson, jsonparser, CastleURIUtils, CastleVectors, CastleBoxes,
  CastleFilesUtils, BikeJSON, BikeParametric_Animation, BikeGeometryLib,
  DebugLog, AppSettings, GameBikeAutoFit;

{ Remove environment nodes that belong to the standalone viewer
  (Background, NavigationInfo, Viewpoint, DirectionalLight) but keep
  BikeRoot and everything inside it. }
procedure StripEnvironmentNodes(Root: TX3DRootNode);
var
  I: Integer;
  Child: TX3DNode;
begin
  I := 0;
  while I < Root.FdChildren.Count do
  begin
    Child := Root.FdChildren[I];
    if (Child is TBackgroundNode) or
       (Child is TNavigationInfoNode) or
       (Child is TViewpointNode) then
      Root.FdChildren.Delete(I)
    else
      Inc(I);
  end;
end;

{ Rotate BikeRoot 180 deg so the bike faces -X.
  ApplyModelRotation (ModelBaseYRotation = -Pi/2) then maps -X to -Z,
  which is the CGE forward direction for Transform.Direction. }
procedure ReorientBikeRoot(Root: TX3DRootNode);
var
  I: Integer;
  Child: TX3DNode;
  Xf: TTransformNode;
begin
  for I := 0 to Root.FdChildren.Count - 1 do
  begin
    Child := Root.FdChildren[I];
    if (Child is TTransformNode) and (Child.X3DName = 'BikeRoot') then
    begin
      Xf := TTransformNode(Child);
      { Rotate 180 deg around Y: bike native +X maps to -X.
        Then ModelBaseYRotation (-Pi/2) in ApplyModelRotation
        maps -X to -Z (CGE forward). }
      Xf.Rotation := Vector4(0, 1, 0, Pi);
      Exit;
    end;
  end;
  Logger.Info('[BikeAvatar] ' + 'WARNING: BikeRoot transform node NOT FOUND in scene graph!');
end;

{ Log top-level children of root node }
procedure LogRootChildren(const Tag: string; Root: TX3DRootNode);
var
  I: Integer;
  Child: TX3DNode;
begin
  Logger.Info('[' + Tag + '] ' + Format('  Root has %d top-level children:', [Root.FdChildren.Count]));
  for I := 0 to Root.FdChildren.Count - 1 do
  begin
    Child := Root.FdChildren[I];
    Logger.Info('[' + Tag + '] ' + Format('    [%d] %s (X3DName="%s")',
      [I, Child.ClassName, Child.X3DName]));
  end;
end;

function BuildBikeRootNode(const AJsonUrl: string): TX3DRootNode;
var
  SL: TStringList;
  JSON: string;
  Builder: TBikeBuilder;
  I: Integer;
begin
  Logger.Info('[BikeAvatar] ' + '=== BuildBikeRootNode START === URL: ' + AJsonUrl);

  Result := nil;

  Logger.Info('[BikeAvatar] ' + '  Step 1: Reading file...');
  SL := TStringList.Create;
  try
    SL.LoadFromFile(URIToFilenameSafe(AJsonUrl));
    JSON := SL.Text;
    Logger.Info('[BikeAvatar] ' + Format('  Step 2: JSON text ready, length=%d', [Length(JSON)]));
  finally
    SL.Free;
  end;

  { Log JSON preview — safe, no arithmetic overflow }
  if Length(JSON) > 200 then
    Logger.Info('[BikeAvatar] ' + '  JSON preview: ' + Copy(JSON, 1, 200) + '...')
  else
    Logger.Info('[BikeAvatar] ' + '  JSON preview: ' + JSON);

  Logger.Info('[BikeAvatar] ' + '  Step 4: Calling LoadBikeFromJSON...');
  Builder := LoadBikeFromJSON(JSON);
  try
    Logger.Info('[BikeAvatar] ' + '  Step 5: LoadBikeFromJSON returned OK');

    { Log what Builder got from JSON.
      Note: after TBikeParams refactor, SeatTubeLength/HeadTubeAngle live on
      TFrameComponent, WheelRadius on TWheelComponent, and BarType is derived
      via Builder.BarType. To re-enable this log, add
        BikeParametric_Frame, BikeParametric_Wheel
      to the implementation uses clause and fetch via Builder.FindComponent. }
    Logger.Info('[BikeAvatar] ' + Format('  Builder.Colors.Frame: (%.3f, %.3f, %.3f)',
      [Builder.Colors.Frame.X, Builder.Colors.Frame.Y, Builder.Colors.Frame.Z]));
    Logger.Info('[BikeAvatar] ' + Format('  Builder.ComponentCount: %d', [Builder.ComponentCount]));
    for I := 0 to Builder.ComponentCount - 1 do
      Logger.Info('[BikeAvatar] ' + Format('    Component[%d]: %s', [I, Builder.Components[I].ComponentName]));

    { Builtin (procedural) rider was removed — only the Tripo authored rig
      remains, so the old TBuiltinRiderComponent path/color diagnostic log
      is gone. Rider tuning now lives in the bike JSON "tripoRider" section. }


    Logger.Info('[BikeAvatar] ' + '  Step 6: Calling Builder.Build...');
    Result := Builder.Build;
    Logger.Info('[BikeAvatar] ' + Format('  Step 7: Build done. RootNode=$%p', [Pointer(Result)]));
  finally
    Builder.Free;
  end;

  { Log scene graph before stripping }
  LogRootChildren('BikeAvatar[pre-strip]', Result);

  { Remove standalone-viewer environment -- the game has its own
    camera, lighting, and background. }
  StripEnvironmentNodes(Result);

  { Log scene graph after stripping }
  LogRootChildren('BikeAvatar[post-strip]', Result);

  { Rotate so the bike faces the CGE forward direction (-Z) }
  ReorientBikeRoot(Result);

  Logger.Info('[BikeAvatar] ' + '=== BuildBikeRootNode END === URL: ' + AJsonUrl);
end;

procedure ApplySceneSettings(AScene: TCastleScene);
var
  BB: TBox3D;
begin
  { Enable X3D event processing -- needed for TimeSensor-driven
    wheel / crank / pedal animations. }
  AScene.ProcessEvents := true;

  BB := AScene.BoundingBox;
  if not BB.IsEmpty then
    Logger.Info('[BikeAvatar] ' + Format('  BoundingBox: (%.3f,%.3f,%.3f)-(%.3f,%.3f,%.3f)',
      [BB.Data[0].X, BB.Data[0].Y, BB.Data[0].Z,
       BB.Data[1].X, BB.Data[1].Y, BB.Data[1].Z]))
  else
    Logger.Info('[BikeAvatar] ' + '  WARNING: BoundingBox is empty!');
end;

function LoadBikeAvatarFromJSON(const AJsonUrl: string;
  AScene: TCastleScene): TX3DRootNode;
var
  BB: TBox3D;
begin
  Logger.Info('[BikeAvatar] ' + '>>> LoadBikeAvatarFromJSON: ' + AJsonUrl);
  Logger.Info('[BikeAvatar] ' + Format('  Target scene: Name="%s" $%p',
    [AScene.Name, Pointer(AScene)]));

  { Log scene state BEFORE loading }
  Logger.Info('[BikeAvatar] ' + Format('  Scene BEFORE load: Url="%s" RootNode=$%p',
    [AScene.Url, Pointer(AScene.RootNode)]));
  BB := AScene.BoundingBox;
  if not BB.IsEmpty then
    Logger.Info('[BikeAvatar] ' + Format('  Scene BEFORE BBox: (%.3f,%.3f,%.3f)-(%.3f,%.3f,%.3f)',
      [BB.Data[0].X, BB.Data[0].Y, BB.Data[0].Z,
       BB.Data[1].X, BB.Data[1].Y, BB.Data[1].Z]))
  else
    Logger.Info('[BikeAvatar] ' + '  Scene BEFORE BBox: EMPTY');

  Result := BuildBikeRootNode(AJsonUrl);

  Logger.Info('[BikeAvatar] ' + Format('  Calling AScene.Load(RootNode=$%p, ownsNode=true)',
    [Pointer(Result)]));
  AScene.Load(Result, true { AScene owns the node });

  { Log scene state AFTER loading }
  Logger.Info('[BikeAvatar] ' + Format('  Scene AFTER load: Url="%s" RootNode=$%p',
    [AScene.Url, Pointer(AScene.RootNode)]));
  ApplySceneSettings(AScene);

  Logger.Info('[BikeAvatar] ' + '<<< LoadBikeAvatarFromJSON done: ' + AJsonUrl);
end;

{ ═══════════════════════════════════════════════════════════════════
  TBikeInstance-based loading (with multi-LOD support)
  ═══════════════════════════════════════════════════════════════════ }

{ Strip environment and reorient the unified bike scene. }
procedure PostProcessBikeInstance(Inst: TBikeInstance);
var
  S: TCastleScene;
begin
  S := Inst.Scene;
  if (S <> nil) and (S.RootNode <> nil) then
  begin
    StripEnvironmentNodes(S.RootNode);
    ReorientBikeRoot(S.RootNode);
  end;
end;

function DoBuildBikeInstance(AJson: TJSONObject; AOwner: TComponent;
  LOD3Dist, LOD2Dist, LOD1Dist: Single; AUseLod: Boolean;
  AAutoFitRider: Boolean = False): TBikeInstance;
var
  Comps: TBikeComponentClassArray;
  Preset: string;
  Colors: TBikeColors;
  D: TJSONData;
begin
  { Лёгкий разбор заголовка вместо мастер-билдера: LoadBikeFromJSON
    конструировал полный набор компонентов только как носителя параметров
    (Preset/Colors + состояние для AssignComponentStateFrom) и сразу
    уничтожал его. Теперь параметры компонентов диспетчатся из JSON
    напрямую в постоянные компоненты экземпляра. }
  ParseBikeHeaderJSON(AJson, Preset, Colors);
  Comps := TBikeInstance.PrepareBuildComps(Preset);

  Result := TBikeInstance.Create(AOwner);
  try
    { Copy Preset / DetailLevel onto the instance up front — BuildWithLOD
      reads them to drive the per-LOD transient builders.
      DetailLevel=3 — дефолт TBikeBuilder.InitDefaults, который раньше
      приезжал сюда через мастер-билдер. }
    Result.Preset      := Preset;
    Result.DetailLevel := 3;
    { Pre-create the instance's persistent components so we can push the
      just-loaded component state onto them before BuildWithLOD reads
      those fields. Without this step the instance's fresh components hold
      defaults (empty rider paths, default geometry, …) and the bike
      builds without the externally-supplied configuration. }
    Result.EnsureComponents(Comps);
    D := AJson.Find('components');
    if (D <> nil) and (D is TJSONObject) then
      Result.AssignComponentStateFromJSON(TJSONObject(D));
    if AAutoFitRider then
    begin
      D := AJson.FindPath('tripoRider.body');
      if not (D is TJSONObject) then
        raise Exception.Create('Automatic bike fit requires rider body parameters');
      AutoFitRoadBike(Result, ReadRiderBody(TJSONObject(D), DefaultRiderBody));
    end;
    { Runtime-only flags — дефолты TBikeBuilder.InitDefaults, которые
      раньше копировались с мастер-билдера. }
    Result.ShowSkeleton := False;
    Result.LogGeometry  := False;

    if AUseLod then
      Result.BuildWithLOD(
        Comps,
        Colors,
        nil,
        LOD3Dist, LOD2Dist, LOD1Dist
      )
    else
      Result.Build(Comps, Colors, nil);
    PostProcessBikeInstance(Result);

    Result.Scene.Pickable := False;
    Result.Scene.Collides := False;

    { CPU-driven procedural rider bone animation was removed. The Tripo
      authored rig is GPU-skinned by CGE and driven via AnimateFrame, so the
      old ActivateRiderAnim / BSG_CRANK single-LOD rebuild is not needed. }

    Logger.Info('[BikeAvatar] ' + Format('TBikeInstance built with LOD (%.0f/%.0f/%.0f)',
      [LOD3Dist, LOD2Dist, LOD1Dist]));
  except
    Result.Free;
    raise;
  end;
end;

{ ── Tripo authored-rig rider ──────────────────────────────────────────
  The editor saves the rider glb path plus the full tuning block into the
  bike JSON under "tripoRider". The bike builder no longer builds the old
  procedural rider, so the game mounts the authored rider explicitly:
  parse that section and hand it to TBikeInstance.LoadTripoRiderFromSection,
  which sets every tuning field, loads the glb as a sibling scene under the
  bike group, and applies body shape — so the in-game rider matches the
  editor. AnimateFrame then drives it each frame. No-op (logged) if the
  section/path is absent or the load fails — the bike still renders. }
procedure AttachTripoRiderFromJSON(Inst: TBikeInstance; const AJsonText: string;
  Prepared: TTripoGlbPrepared);
var
  Data, Node: TJSONData;
  Ok: Boolean;
begin
  if Inst = nil then Exit;
  Ok := False;
  try
    Data := GetJSON(AJsonText);
    try
      if Data is TJSONObject then
      begin
        Node := TJSONObject(Data).Find('tripoRider');
        if (Node <> nil) and (Node is TJSONObject) then
          Ok := Inst.LoadTripoRiderFromSection(TJSONObject(Node),Prepared);
      end;
    finally
      Data.Free;
    end;
  except
    on E: Exception do
      Logger.Info('[BikeAvatar] tripoRider JSON parse failed: ' + E.Message);
  end;

  if Ok then
    Logger.Info('[BikeAvatar] Tripo rider mounted: ' + Inst.TripoRiderPath)
  else
    Logger.Info('[BikeAvatar] Tripo rider not mounted (no section/path, or load failed: '
                + Inst.TripoRiderError + ')');
end;

function LoadBikeInstanceFromJSON(const AJsonUrl: string;
  AOwner: TComponent;
  LOD3Dist: Single;
  LOD2Dist: Single;
  LOD1Dist: Single): TBikeInstance;
var
  SL: TStringList;
  JSON: string;
  Root: TJSONObject;
begin
  Logger.Info('[BikeAvatar] ' + '>>> LoadBikeInstanceFromJSON: ' + AJsonUrl);

  SL := TStringList.Create;
  try
    SL.LoadFromFile(URIToFilenameSafe(AJsonUrl));
    JSON := SL.Text;
  finally
    SL.Free;
  end;

  Root := TJSONObject(GetJSON(JSON));
  try
    Result := DoBuildBikeInstance(Root, AOwner, LOD3Dist, LOD2Dist, LOD1Dist, True);
  finally
    Root.Free;
  end;

  AttachTripoRiderFromJSON(Result, JSON);   { mount the authored Tripo rider, if any }

  Logger.Info('[BikeAvatar] ' + '<<< LoadBikeInstanceFromJSON done');
end;

function LoadBikeInstanceFromJSONString(const AJsonText: string;
  AOwner: TComponent;
  LOD3Dist: Single;
  LOD2Dist: Single;
  LOD1Dist: Single;
  AAttachRider: Boolean;
  AUseLod: Boolean;
  AAutoFitRider: Boolean): TBikeInstance;
var
  Root: TJSONObject;
begin
  Logger.Info('[BikeAvatar] ' + '>>> LoadBikeInstanceFromJSONString');

  Root := TJSONObject(GetJSON(AJsonText));
  try
    Result := DoBuildBikeInstance(Root, AOwner, LOD3Dist, LOD2Dist, LOD1Dist, AUseLod, AAutoFitRider);
  finally
    Root.Free;
  end;

  if AAttachRider then
    AttachTripoRiderFromJSON(Result, AJsonText);   { mount the authored Tripo rider, if any }

  Logger.Info('[BikeAvatar] ' + '<<< LoadBikeInstanceFromJSONString done');
end;

function ResolveActiveBikeJsonUrl: string;
var
  S: string;
  Fn: string;
begin
  S := '';
  if Settings <> nil then
    S := Trim(Settings.SelectedBikeJson);
  if S <> '' then
  begin
    if Pos('://', S) > 0 then
      Result := S
    else
    begin
      Fn := S;
      if FileExists(Fn) then
        Result := FilenameToURISafe(Fn)
      else
        Result := S; { assume already usable path/URL }
    end;
    Exit;
  end;
  Result := 'castle-data:/bike_road.json';
end;

function ResolveActiveBikeBuildUrl: string;
var
  S: string;
begin
  S := ResolveActiveBikeJsonUrl;
  { Same redirect LoadActiveBikeInstance / BikeFit (BaseBikeUrl) already
    use: Insights contains geometry overrides for the base build. }
  if IsBikeInsightsPath(S) then
    Result := 'castle-data:/bike_road.json'
  else
    Result := S;
end;

function BikeJsonUrlToFilename(const AUrl: string): string;
begin
  Result := URIToFilenameSafe(AUrl);
  if (Result = '') or (not FileExists(Result)) then
  begin
    if FileExists(AUrl) then
      Result := AUrl
    else
      Result := '';
  end;
end;

{ Inject/override tripoRider.path in bike JSON text. }
function InjectRiderPath(const AJsonText, ARiderGlb: string; UseProfile:Boolean): string;
var
  Data: TJSONData;
  Root, Sec: TJSONObject;
  Path: string;
begin
  Result := AJsonText;
  Path := StringReplace(Trim(ARiderGlb), '\', '/', [rfReplaceAll]);
  if Path = '' then Exit;
  try
    Data := GetJSON(AJsonText);
    try
      if not (Data is TJSONObject) then Exit;
      Root := TJSONObject(Data);
      Sec := nil;
      if Root.Find('tripoRider') is TJSONObject then
        Sec := TJSONObject(Root.Find('tripoRider'))
      else
      begin
        Sec := TJSONObject.Create;
        Root.Add('tripoRider', Sec);
      end;
      Sec.Strings['path'] := Path;
      if UseProfile then begin
        Sec.Delete('body');Sec.Add('body',WriteRiderBody(AvatarBodyParameters));
      end;
      if Sec.Find('showRider') = nil then
        Sec.Add('showRider', True)
      else
        Sec.Booleans['showRider'] := True;
      Result := Root.FormatJSON;
    finally
      Data.Free;
    end;
  except
    on E: Exception do
      Logger.Info('[BikeAvatar] InjectRiderPath failed: ' + E.Message);
  end;
end;

function LoadActiveBikeInstance(AOwner: TComponent;
  LOD3Dist: Single; LOD2Dist: Single; LOD1Dist: Single): TBikeInstance;
var
  Url, Fn, JsonText, Rider, Size: string;
  SL: TStringList;
  Insights: Boolean;
begin
  Insights := IsBikeInsightsPath(ResolveActiveBikeJsonUrl);
  Url := ResolveActiveBikeBuildUrl;
  Logger.Info('[BikeAvatar] LoadActiveBikeInstance url=' + Url +
    ' insights=' + BoolToStr(Insights, True));
  SL := TStringList.Create;
  try
    Fn := BikeJsonUrlToFilename(Url);
    if (Fn = '') or (not FileExists(Fn)) then
      raise Exception.Create('bike JSON not found: ' + Url);
    SL.LoadFromFile(Fn);
    JsonText := SL.Text;
  finally
    SL.Free;
  end;
  Rider := '';
  Size := '';
  if Settings <> nil then
  begin
    Rider := WardrobeRiderPath(ResolveRiderGlbPath(Settings.SelectedRiderGlb));
    Size := Trim(Settings.SelectedBikeSize);
  end;
  if PerformanceRiderModel <> '' then Rider := PerformanceRiderModel;
  if Rider <> '' then
  begin
    Logger.Info('[BikeAvatar] override rider glb=' + Rider);
    JsonText := InjectRiderPath(JsonText, Rider);
  end;
  { Как BikeFit: сначала геометрия байка, потом dye-preset, потом один
    LoadGlb. Раньше Attach шёл сразу, а ApplyBikeFitColorsToInstance
    перезагружал FEM/MEN целиком — второй CREATE+LOAD в scene_lifecycle
    и ~11 с запечки на выброшенном первом экземпляре. }
  Result := LoadBikeInstanceFromJSONString(JsonText, AOwner,
    LOD3Dist, LOD2Dist, LOD1Dist, False);
  if Insights and (Settings <> nil) and (Result <> nil) then
  begin
    Fn := URIToFilenameSafe(Settings.SelectedBikeJson);
    if (Fn = '') or (not FileExists(Fn)) then
      Fn := Settings.SelectedBikeJson;
    if ApplyInsightsFileToBikeInstance(Result, Fn, Size) then
      Logger.Info('[BikeAvatar] applied insights ' + ExtractFileName(Fn) +
        ' size=' + Size)
    else
      Logger.Info('[BikeAvatar] insights apply failed ' + Fn);
  end;
  if (Settings <> nil) and Settings.FitParamsValid and (Result <> nil) then
    ApplyFitAdjustments(Result,
      Settings.FitSeatpostExt, Settings.FitSaddleOffset,
      Settings.FitHeadsetSpacer, Settings.FitStemLength);
  if Result <> nil then
    Result.ClothDyePresetMode := cdmShader;
  ApplyBikeFitColorsToInstance(Result);
  AttachTripoRiderFromJSON(Result, JsonText);
  if Result<>nil then Result.BodyParameters:=AvatarBodyParameters;
  if (Settings <> nil) and Settings.FitParamsValid and (Result <> nil) then
  begin
    ApplyRiderShapeAdjustments(Result,
      Settings.FitHeightCm, Settings.FitInseamCm,
      Settings.FitBulk, Settings.FitBelly);
    ApplyFitKneeAnkle(Result, Settings.FitKneeFlare, Settings.FitAnkleFlex);
  end;
  { Шлем — live tint: райдер уже в сцене. Повторный вызов только
    применяет шлем; glb больше не грузится. }
  ApplyBikeFitColorsToInstance(Result);
end;

procedure ApplyFitKneeAnkle(Inst: TBikeInstance; KneeFlare, AnkleFlex: Single);
begin
  if Inst = nil then Exit;
  Inst.TripoKneeFlare := KneeFlare;
  Inst.TripoAnkleFlex := AnkleFlex;
end;

procedure ApplyBikeFitColorsToInstance(Inst: TBikeInstance);

  function VecOf(const H: string; out C: TVector3): Boolean;
  var
    V: Integer;
  begin
    Result := (Length(H) = 6) and TryStrToInt('$' + H, V);
    if Result then
      C := Vector3(((V shr 16) and $FF) / 255.0,
                   ((V shr 8) and $FF) / 255.0,
                   (V and $FF) / 255.0);
  end;

var
  SL: TStringList;
  S: TClothSlot;
  C: TVector3;
  AnyCloth, HelmetOn: Boolean;
  HelmetC: TVector3;
begin
  if (Inst = nil) or (Settings = nil) then Exit;
  if Inst.TripoRider<>nil then begin
    Inst.TripoRider.HairStyle:=ParseRiderHairStyle(UserPreference('rider_hair_style','short'));
    Inst.TripoRider.SetHeadAppearance(WardrobeHeadwear,
      ParseBeard(UserPreference('rider_beard','none')),ParseMustache(UserPreference('rider_mustache','none')));
  end;
  if Trim(Settings.BikeFitColors) = '' then begin
    Inst.SetHeadwearColorLive(Vector3(1,1,1),False);
    Exit;
  end;
  AnyCloth := False;
  HelmetOn := True;   { станет False, если валидного hex в слоте 9 нет }
  HelmetC := Vector3(0, 0, 0);
  SL := TStringList.Create;
  try
    SL.StrictDelimiter := True;
    SL.Delimiter := ',';
    SL.DelimitedText := Settings.BikeFitColors;
    for S := Low(TClothSlot) to High(TClothSlot) do
      if (Ord(S) < SL.Count) and VecOf(SL[Ord(S)], C) then
      begin
        Inst.StageRiderClothColor(S, C);
        AnyCloth := True;
      end;
    if (SL.Count > 7) and VecOf(SL[7], C) then
      Inst.SetFrameColorLive(C);
    if (SL.Count > 8) and VecOf(SL[8], C) then
      Inst.SetRimColorLive(C);
    { шлем — tint материалов, живой; нужен уже смонтированный райдер }
    if (SL.Count > 9) and VecOf(SL[9], C) then
      HelmetC := C
    else
      HelmetOn := False;
  finally
    SL.Free;
  end;
  { Одежда: только preset. Запечка/шейдер — внутри ближайшего LoadGlb
    (ApplyDyePresetToRider). Повторный LoadTripoRider того же glb
    выкидывал уже загруженную сцену. }
  if AnyCloth then
  begin
    if Inst.HasTripoRider then
      Logger.Info('[BikeAvatar] cloth dye staged on live rider (no glb reload), glb=' +
        Inst.TripoRiderPath)
    else
      Logger.Info('[BikeAvatar] cloth dye staged for next rider load');
  end;
  Inst.SetHeadwearColorLive(HelmetC,HelmetOn);
end;

procedure ApplyRiderShapeAdjustments(Inst: TBikeInstance;
  HeightCm, InseamCm, Bulk, Belly: Single);
var
  RestH, RestI, HeightF, HeightK, LegK, UpperK: Single;
  H, I, Upper0, Upper1: Single;
  Same: Boolean;
begin
  if (Inst = nil) or (Inst.TripoRider = nil) then Exit;
  if Inst.TripoRider.HasParametricBody then
  begin
    Inst.BodyParameters:=AvatarBodyParameters;
    Exit;
  end;
  RestH := Inst.TripoRider.RestHeight;
  RestI := Inst.TripoRider.StableLegReach;
  if RestH < 0.5 then RestH := 1.75;
  if RestI < 0.4 then RestI := 0.80;
  H := RestH;
  if (HeightCm >= 80) and (HeightCm <= 230) then
    H := HeightCm * 0.01;
  I := RestI;
  if (InseamCm >= 55) and (InseamCm <= 105) then
    I := InseamCm * 0.01;
  { Leave room for a torso; inseam is crotch-to-floor, not full stature. }
  if I > H - 0.35 then I := H - 0.35;
  if I < 0.45 then I := 0.45;

  HeightK := H / RestH;
  HeightF := HeightK - 1.0;
  if HeightF > 0.18 then
  begin
    HeightF := 0.18;
    HeightK := 1.0 + HeightF;
  end;
  if HeightF < -0.15 then
  begin
    HeightF := -0.15;
    HeightK := 1.0 + HeightF;
  end;

  { Whole thigh+shin chain = inseam. Boot mesh is rigid on Foot (not here). }
  LegK := (I / RestI) / HeightK;
  if LegK < 0.70 then LegK := 0.70;
  if LegK > 1.40 then LegK := 1.40;

  { Torso/neck take the leftover so standing height stays H when I changes. }
  Upper0 := RestH - RestI;
  if Upper0 < 0.25 then Upper0 := 0.25;
  Upper1 := H - I;
  if Upper1 < 0.25 then Upper1 := 0.25;
  UpperK := (Upper1 / Upper0) / HeightK;
  if UpperK < 0.70 then UpperK := 0.70;
  if UpperK > 1.40 then UpperK := 1.40;

  Same := (Abs(Inst.TripoBodyHeight - HeightF) < 1e-5) and
          (Abs(Inst.TripoLegLen - LegK) < 1e-5) and
          (Abs(Inst.TripoInseamUpper - UpperK) < 1e-5) and
          (Abs(Inst.TripoBulk - Bulk) < 1e-5) and
          (Abs(Inst.TripoBelly - Belly) < 1e-5);
  Inst.TripoBodyHeight := HeightF;
  Inst.TripoLegLen := LegK;
  Inst.TripoInseamUpper := UpperK;
  Inst.TripoBulk := Bulk;
  Inst.TripoBelly := Belly;
  { LoadTripoRider already applied default 0/1/0/0 and primed GPU skin.
    Re-applying identity morphs rest verts after that prime and explodes
    the mesh. Only push when the shape actually changed. }
  if Same then Exit;
  Inst.ApplyTripoBodyShape;
end;

end.

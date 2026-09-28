unit Osm3dCompositeShader;

{ overflow/range-проверки выключены намеренно — единый стиль модулей проекта }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses
  Classes, SysUtils,
  CastleRenderOptions,         { slGLSL }
  X3DNodes,                    { TEffectNode/TEffectPartNode/TShapeNode/TAppearanceNode }
  X3DFields,                   { TSFFloat }
  Osm3dEffectUtils
;

type
  TCompositeShader = class;

  { Stored in TGroundMaterialDesc.ShaderClass: nil = static surface (drawn by the normal
    composite); otherwise the material is EXTRACTED into its own shape and drawn by this shader. }
  TCompositeShaderClass = class of TCompositeShader;

  { One clock per shader class, but scene-owned effects. X3D nodes must never
    be shared between TCastleScene instances. Destruction notifications keep
    the borrowed uniform registry in sync with streamed scene lifetimes. }
  TCompositeShader = class
  private
    FBindings: array of record
      Effect: TEffectNode;
      TimeField: TSFFloat;
    end;
    FTimeField: TSFFloat; { output of the current BuildEffect call only }
    FClock:        Single;
    procedure EffectDestroyed(const Node: TX3DNode);
  protected
    { Subclass builds the WHOLE effect (parts + uniforms) and, if animated, hands its
      'time' TSFFloat to SetTimeField. Called for each appearance; its scene
      owns the returned node. }
    function BuildEffect: TEffectNode; virtual; abstract;
    { Subclass registers its 'time' uniform here so Tick can drive it. No call = static shader. }
    procedure SetTimeField(AField: TSFFloat);
  public
    constructor Create; virtual;
    destructor Destroy; override;

    { Vertical lift (m) for the extracted mesh; non-zero when extraction loses the ZIndex
      offset (water). 0 = no lift. }
    function MeshLift: Single; virtual;

    { Build a scene-owned effect and ADD it to the shape's appearance, keeping existing
      effects (LOD/atlas). }
    procedure ApplyToShape(Shape: TShapeNode); virtual;

    { Сдвинуть часы и послать их в uniform 'time'. No-op если не анимирован. }
    procedure Tick(SecondsElapsed: Single); virtual;

    { Detach borrowed notifications before scene teardown; scenes own the nodes. }
    procedure Clear; virtual;

    function Clock: Single;
    function Animated: Boolean;     { есть ли uniform 'time' }

    { Get-or-create the process singleton for the concrete class it's called on
      (e.g. TWaterCompositeShader.Instance). The virtual ctor dispatches to the right subclass. }
    class function Instance: TCompositeShader;
  end;

{ Advance every live shader's clock and send it to its 'time' uniform. Call once per frame. }
{ Negative time returns to the scene clock. Used by FIT replay/pause. }
procedure CompositeShaderSetPlaybackTime(Seconds: Single);
procedure CompositeShaderTickAll(SecondsElapsed: Single);

{ Reset all live shaders. MUST run before freeing shapes/effects (tile teardown). }
procedure CompositeShaderClearAll;

{ Diagnostics: count of shaders with a live animated effect, and the max clock among them. }
function CompositeShaderLiveCount: Integer;
function CompositeShaderMaxClock: Single;

implementation

uses
  SyncObjs, CastleSceneCore;

var
  { Live singletons, one per class (few -> linear search). Process-lifetime objects:
    ClearAll resets their STATE but does not free them.
    Реестр и состояние синглтонов трогают и фоновая сборка тайлов
    (Instance/ApplyToShape из Osm3dSceneAssembler), и кадровый тик на
    главном потоке (CompositeShaderTickAll / ClearAll) — все обращения
    сериализованы FShaderLock. }
  FShaders: array of TCompositeShader;
  FShaderLock: TCriticalSection;
  FPlaybackTime: Single = -1;

function FindShader(ACls: TCompositeShaderClass): TCompositeShader;
var I: Integer;
begin
  { вызывается только под FShaderLock }
  Result := nil;
  for I := 0 to High(FShaders) do
    if FShaders[I].ClassType = ACls then
    begin
      Result := FShaders[I];
      Exit;
    end;
end;

{ TCompositeShader }

constructor TCompositeShader.Create;
begin
  inherited Create;
  FTimeField    := nil;
  FClock        := 0.0;
end;

destructor TCompositeShader.Destroy;
begin
  Clear;
  inherited;
end;

procedure TCompositeShader.EffectDestroyed(const Node: TX3DNode);
var I, J: Integer;
begin
  FShaderLock.Enter;
  try
    for I := 0 to High(FBindings) do
      if FBindings[I].Effect = Node then
      begin
        for J := I to High(FBindings) - 1 do FBindings[J] := FBindings[J + 1];
        SetLength(FBindings, Length(FBindings) - 1);
        Break;
      end;
  finally FShaderLock.Leave end;
end;

procedure TCompositeShader.SetTimeField(AField: TSFFloat);
begin
  FTimeField := AField;
end;

function TCompositeShader.MeshLift: Single;
begin
  Result := 0.0;
end;

function TCompositeShader.Animated: Boolean;
var I: Integer;
begin
  Result := False;
  for I := 0 to High(FBindings) do
    if FBindings[I].TimeField <> nil then Exit(True);
end;

function TCompositeShader.Clock: Single;
begin
  Result := FClock;
end;

procedure TCompositeShader.ApplyToShape(Shape: TShapeNode);
var
  App:      TAppearanceNode;
  Effect: TEffectNode;
  N: Integer;
begin
  if Shape = nil then Exit;
  if not (Shape.Appearance is TAppearanceNode) then Exit;
  App := Shape.Appearance as TAppearanceNode;

  FShaderLock.Enter;
  try
    FTimeField := nil;
    Effect := BuildEffect;
    if Effect = nil then Exit;
    try
      if FTimeField <> nil then FTimeField.Value := FClock;
      ChainEffectApp(App, Effect);
      N := Length(FBindings);
      SetLength(FBindings, N + 1);
      FBindings[N].Effect := Effect;
      FBindings[N].TimeField := FTimeField;
      Effect.AddDestructionNotification(@EffectDestroyed);
    finally
      FTimeField := nil;
      Effect.FreeIfUnused;
    end;
  finally
    FShaderLock.Leave;
  end;
end;

procedure TCompositeShader.Tick(SecondsElapsed: Single);
var I: Integer; E: TEffectNode;
begin
  FShaderLock.Enter;
  try
    if FPlaybackTime>=0 then FClock:=FPlaybackTime
    else FClock := FClock + SecondsElapsed;
    for I := 0 to High(FBindings) do
    begin
      E := FBindings[I].Effect;
      { An inactive scene may still be traversed by the mount worker. }
      if (FBindings[I].TimeField <> nil) and
         (E.Scene is TCastleSceneCore) and TCastleSceneCore(E.Scene).Exists then
        FBindings[I].TimeField.Send(FClock);
    end;
  finally
    FShaderLock.Leave;
  end;
end;

procedure TCompositeShader.Clear;
var I: Integer;
begin
  FShaderLock.Enter;
  try
    for I := 0 to High(FBindings) do
      FBindings[I].Effect.RemoveDestructionNotification(@EffectDestroyed);
    FBindings := nil;
    FTimeField := nil;
    FClock     := 0.0;
  finally
    FShaderLock.Leave;
  end;
end;

class function TCompositeShader.Instance: TCompositeShader;
var
  Sh: TCompositeShader;
begin
  FShaderLock.Enter;
  try
    Sh := FindShader(Self);          { Self = метакласс конкретного класса }
    if Sh = nil then
    begin
      Sh := Self.Create;             { виртуальный ctor → объект нужного подкласса }
      SetLength(FShaders, Length(FShaders) + 1);
      FShaders[High(FShaders)] := Sh;
    end;
    Result := Sh;
  finally
    FShaderLock.Leave;
  end;
end;

procedure CompositeShaderSetPlaybackTime(Seconds: Single);
begin
  FShaderLock.Enter;
  try FPlaybackTime:=Seconds; finally FShaderLock.Leave end;
end;

procedure CompositeShaderTickAll(SecondsElapsed: Single);
var I: Integer;
begin
  FShaderLock.Enter;
  try
    for I := 0 to High(FShaders) do
      FShaders[I].Tick(SecondsElapsed);
  finally
    FShaderLock.Leave;
  end;
end;

procedure CompositeShaderClearAll;
var I: Integer;
begin
  FShaderLock.Enter;
  try
    for I := 0 to High(FShaders) do
      FShaders[I].Clear;
  finally
    FShaderLock.Leave;
  end;
end;

function CompositeShaderLiveCount: Integer;
var I: Integer;
begin
  FShaderLock.Enter;
  try
    Result := 0;
    for I := 0 to High(FShaders) do
      if FShaders[I].Animated then
        Inc(Result);
  finally
    FShaderLock.Leave;
  end;
end;

function CompositeShaderMaxClock: Single;
var I: Integer;
begin
  FShaderLock.Enter;
  try
    Result := 0.0;
    for I := 0 to High(FShaders) do
      if FShaders[I].FClock > Result then
        Result := FShaders[I].FClock;
  finally
    FShaderLock.Leave;
  end;
end;

initialization
  FShaderLock := TCriticalSection.Create;

{ Намеренно БЕЗ finalization/Free: при закрытии приложения поздние Destroy
  (остановка view из finalization castle-юнитов) могут ещё входить под замок,
  когда finalization этого юнита уже отработал (см. Osm3dCacheHTTPFetcher).
  Замок живёт до конца процесса. }
end.

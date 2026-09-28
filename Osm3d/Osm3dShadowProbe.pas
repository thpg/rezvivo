unit Osm3dShadowProbe;

{$mode objfpc}{$H+}

interface

uses CastleVectors, CastleGL, CastleGLShaders, CastleTimeUtils;

type
  { Nine depth tests in the existing shadow framebuffer. Two asynchronous
    query objects carry only sample counts, never another shadow texture. }
  TShadowGroundProbe = class
  private
    FProgram: TGLSLProgram;
    FVAO: GLuint;
    FLocation, FStepLocation: TGLSLUniform;
    FQueries: array[0..1] of record
      Id: GLuint;
      Pending: Boolean;
      Point: TVector3;
      Time: TTimerResult;
      Serial: QWord;
    end;
    FSerial, FResultSerial, FMinSerial: QWord;
    FValid, FHasSubmitted: Boolean;
    FLastSubmitTime: TTimerResult;
    FLastSubmitPoint: TVector3;
    FPoint: TVector3;
    FTime: TTimerResult;
    FCoverage: Single;
    procedure Poll;
  public
    destructor Destroy; override;
    procedure ContextClose;
    procedure Reset;
    function SampleDue(const Point: TVector3): Boolean;
    procedure Submit(const Point, ClipPoint: TVector3; const TileSize: Integer;
      const TexelMetres: Single);
    function TryCoverage(const Point: TVector3; out Value: Single): Boolean;
    function Coverage(const Point: TVector3): Single;
  end;

const
  SHADOW_PROBE_VS = '#version 330' + #10 +
    'uniform vec3 probe;' + #10 +
    'uniform float stepSize;' + #10 +
    'void main() {' + #10 +
    '  vec2 offset = vec2(gl_VertexID % 3, gl_VertexID / 3) - 1.0;' + #10 +
    '  gl_Position = vec4(probe.xy + offset * stepSize, probe.z, 1.0);' + #10 +
    '  gl_PointSize = 1.0;' + #10 +
    '}' + #10;
  SHADOW_PROBE_FS = '#version 330' + #10 + 'void main() {}' + #10;

implementation

uses SysUtils, Math, CastleRenderContext;

destructor TShadowGroundProbe.Destroy;
begin
  ContextClose;
  inherited;
end;

procedure TShadowGroundProbe.Reset;
begin
  FValid := False;
  FHasSubmitted := False;
  FMinSerial := FSerial + 1; { discard outstanding results after a toggle/teleport }
end;

procedure TShadowGroundProbe.ContextClose;
var I: Integer;
begin
  for I := 0 to High(FQueries) do
  begin
    if FQueries[I].Id <> 0 then glDeleteQueries(1, @FQueries[I].Id);
    FQueries[I].Id := 0;
    FQueries[I].Pending := False;
  end;
  if FVAO <> 0 then glDeleteVertexArrays(1, @FVAO);
  FVAO := 0;
  FreeAndNil(FProgram);
  Reset;
end;

function TShadowGroundProbe.Coverage(const Point: TVector3): Single;
begin
  if not TryCoverage(Point, Result) then Result := 0;
end;

function TShadowGroundProbe.TryCoverage(const Point: TVector3; out Value: Single): Boolean;
begin
  Value := FCoverage;
  Result := FValid and ((Point - FPoint).Length < 4) and
    (TimerSeconds(Timer, FTime) < 0.5);
end;

procedure TShadowGroundProbe.Poll;
var I: Integer; Available, Count: GLuint;
begin
  for I := 0 to High(FQueries) do
  begin
    if FQueries[I].Pending then
    begin
      glGetQueryObjectuiv(FQueries[I].Id, GL_QUERY_RESULT_AVAILABLE, @Available);
      if Available <> 0 then
      begin
        glGetQueryObjectuiv(FQueries[I].Id, GL_QUERY_RESULT, @Count);
        FQueries[I].Pending := False;
        if (FQueries[I].Serial >= FMinSerial) and
          (FQueries[I].Serial > FResultSerial) then
        begin
          FResultSerial := FQueries[I].Serial;
          FCoverage := Min(Count / 9.0, 1.0);
          FPoint := FQueries[I].Point;
          FTime := FQueries[I].Time;
          FValid := True;
        end;
      end;
    end;
  end;
end;

function TShadowGroundProbe.SampleDue(const Point: TVector3): Boolean;
begin
  Poll;
  { Wind changes slowly at rest; movement requests another sample after
    15 cm, retaining frame-rate updates when riding fast. Poll every frame. }
  Result := not FHasSubmitted or
    (TimerSeconds(Timer, FLastSubmitTime) >= 1.0 / 30.0) or
    ((Point - FLastSubmitPoint).Length >= 0.15);
end;

procedure TShadowGroundProbe.Submit(const Point, ClipPoint: TVector3; const TileSize: Integer;
  const TexelMetres: Single);
var
  I, Slot: Integer;
  SavedProgram, SavedVAO, SavedFunc, ActiveQuery: GLint;
  SavedContextProgram: TGLSLProgram;
  SavedMask, HadDepth, HadCull, HadOffset, HadPointSize: GLboolean;
  SavedRange: array[0..1] of GLdouble;
  P: TVector3;
  Spacing: Integer;
begin
  Slot := -1;
  for I := 0 to High(FQueries) do
    if not FQueries[I].Pending then Slot := I;
  { Never wait for a busy GPU or reuse a pending query. }
  if Slot < 0 then Exit;
  Spacing := Max(1, Round(0.12 / Max(TexelMetres, 0.0001)));
  if (Abs(ClipPoint.X) >= 1 - 2.0 * (Spacing + 1) / TileSize) or
     (Abs(ClipPoint.Y) >= 1 - 2.0 * (Spacing + 1) / TileSize) or
     (Abs(ClipPoint.Z) >= 1) then begin Reset; Exit end;
  glGetQueryiv(GL_SAMPLES_PASSED, GL_CURRENT_QUERY, @ActiveQuery);
  if ActiveQuery <> 0 then Exit;
  if FProgram = nil then
  begin
    FProgram := TGLSLProgram.Create;
    FProgram.AttachVertexShader(SHADOW_PROBE_VS);
    FProgram.AttachFragmentShader(SHADOW_PROBE_FS);
    FProgram.Link;
    FLocation := FProgram.Uniform('probe');
    FStepLocation := FProgram.Uniform('stepSize');
    glGenVertexArrays(1, @FVAO);
  end;
  if FQueries[Slot].Id = 0 then glGenQueries(1, @FQueries[Slot].Id);
  SavedContextProgram := RenderContext.CurrentProgram;
  glGetIntegerv(GL_CURRENT_PROGRAM, @SavedProgram);
  glGetIntegerv(GL_VERTEX_ARRAY_BINDING, @SavedVAO);
  glGetIntegerv(GL_DEPTH_FUNC, @SavedFunc);
  glGetBooleanv(GL_DEPTH_WRITEMASK, @SavedMask);
  glGetDoublev(GL_DEPTH_RANGE, @SavedRange[0]);
  HadDepth := glIsEnabled(GL_DEPTH_TEST);
  HadCull := glIsEnabled(GL_CULL_FACE);
  HadOffset := glIsEnabled(GL_POLYGON_OFFSET_FILL);
  HadPointSize := glIsEnabled(GL_PROGRAM_POINT_SIZE);
  try
    glEnable(GL_DEPTH_TEST);
    glDepthFunc(GL_GREATER); { count only ground samples hidden from sunlight }
    glDepthMask(GL_FALSE);
    glDepthRange(0, 1);
    glDisable(GL_CULL_FACE);
    glDisable(GL_POLYGON_OFFSET_FILL);
    glEnable(GL_PROGRAM_POINT_SIZE);
    FProgram.Enable;
    glBindVertexArray(FVAO);
    P := ClipPoint;
    P.X := (Floor((P.X * 0.5 + 0.5) * TileSize) + 0.5) * 2 / TileSize - 1;
    P.Y := (Floor((P.Y * 0.5 + 0.5) * TileSize) + 0.5) * 2 / TileSize - 1;
    FLocation.SetValue(P);
    { Nine one-pixel tests over a stable 24 cm footprint, at every atlas LOD.
      Adjacent texels in the finest zone only sampled a few millimetres. }
    FStepLocation.SetValue(Single(2.0 * Spacing / TileSize));
    glBeginQuery(GL_SAMPLES_PASSED, FQueries[Slot].Id);
    try
      glDrawArrays(GL_POINTS, 0, 9);
    finally glEndQuery(GL_SAMPLES_PASSED) end;
    Inc(FSerial);
    FQueries[Slot].Serial := FSerial;
    FQueries[Slot].Point := Point;
    FQueries[Slot].Time := Timer;
    FQueries[Slot].Pending := True;
    FLastSubmitTime := FQueries[Slot].Time;
    FLastSubmitPoint := Point;
    FHasSubmitted := True;
  finally
    RenderContext.CurrentProgram := SavedContextProgram;
    glUseProgram(SavedProgram);
    glBindVertexArray(SavedVAO);
    glDepthFunc(SavedFunc);
    glDepthMask(SavedMask);
    glDepthRange(SavedRange[0], SavedRange[1]);
    if HadDepth <> GL_FALSE then glEnable(GL_DEPTH_TEST) else glDisable(GL_DEPTH_TEST);
    if HadCull <> GL_FALSE then glEnable(GL_CULL_FACE) else glDisable(GL_CULL_FACE);
    if HadOffset <> GL_FALSE then glEnable(GL_POLYGON_OFFSET_FILL) else glDisable(GL_POLYGON_OFFSET_FILL);
    if HadPointSize <> GL_FALSE then glEnable(GL_PROGRAM_POINT_SIZE) else glDisable(GL_PROGRAM_POINT_SIZE);
  end;
end;

end.

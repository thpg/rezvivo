unit Osm3dGpuTimer;

{$mode objfpc}{$H+}

interface

uses CastleGL;

type
  TGpuTimestampPair = array[0..1] of GLuint;
  { Timestamp pairs can overlap other timers. An exhausted ring drops a
    measurement, never waits for the GPU and never overwrites pending data. }
  TAsyncGpuTimer = class
  private
    FQueries: array[0..7] of TGpuTimestampPair;
    FPending: array[0..7] of Boolean;
    FOpen: Integer;
    procedure ContextClose(Sender: TObject);
  public
    constructor Create;
    destructor Destroy; override;
    procedure BeginSample;
    procedure EndSample;
    procedure Reset;
    function ReadSample(out Nanoseconds: QWord): Boolean;
  end;

function GpuTimestampBegin(var Pair: TGpuTimestampPair): Boolean;
procedure GpuTimestampEnd(const Pair: TGpuTimestampPair);
function GpuTimestampRead(const Pair: TGpuTimestampPair; out Nanoseconds: QWord): Boolean;
procedure GpuTimestampFree(var Pair: TGpuTimestampPair);

implementation

uses CastleApplicationProperties;

function GpuTimestampBegin(var Pair: TGpuTimestampPair): Boolean;
begin
  Result := Assigned(glQueryCounter) and Assigned(glGetQueryObjectui64v);
  if not Result then Exit;
  if Pair[0] = 0 then glGenQueries(2, @Pair[0]);
  glQueryCounter(Pair[0], GL_TIMESTAMP);
end;

procedure GpuTimestampEnd(const Pair: TGpuTimestampPair);
begin
  if Pair[0] <> 0 then glQueryCounter(Pair[1], GL_TIMESTAMP);
end;

function GpuTimestampRead(const Pair: TGpuTimestampPair; out Nanoseconds: QWord): Boolean;
var Ready: GLuint; A, B: GLuint64;
begin
  Nanoseconds := 0; Result := False;
  if Pair[0] = 0 then Exit;
  glGetQueryObjectuiv(Pair[1], GL_QUERY_RESULT_AVAILABLE, @Ready);
  if Ready = 0 then Exit;
  glGetQueryObjectuiv(Pair[0], GL_QUERY_RESULT_AVAILABLE, @Ready);
  if Ready = 0 then Exit;
  glGetQueryObjectui64v(Pair[0], GL_QUERY_RESULT, @A);
  glGetQueryObjectui64v(Pair[1], GL_QUERY_RESULT, @B);
  if B >= A then Nanoseconds := B - A;
  Result := True;
end;

procedure GpuTimestampFree(var Pair: TGpuTimestampPair);
begin
  if Pair[0] <> 0 then glDeleteQueries(2, @Pair[0]);
  FillChar(Pair, SizeOf(Pair), 0);
end;

constructor TAsyncGpuTimer.Create;
begin
  inherited;
  FOpen := -1;
  ApplicationProperties.OnGLContextCloseObject.Add(@ContextClose);
end;

destructor TAsyncGpuTimer.Destroy;
begin
  ApplicationProperties.OnGLContextCloseObject.Remove(@ContextClose);
  ContextClose(nil);
  inherited;
end;

procedure TAsyncGpuTimer.ContextClose(Sender: TObject);
var I: Integer;
begin
  for I := 0 to High(FQueries) do GpuTimestampFree(FQueries[I]);
  Reset;
end;

procedure TAsyncGpuTimer.Reset;
begin
  FillChar(FPending, SizeOf(FPending), 0);
  FOpen := -1;
end;

procedure TAsyncGpuTimer.BeginSample;
var I: Integer;
begin
  if FOpen >= 0 then Exit;
  for I := 0 to High(FQueries) do
    if not FPending[I] then
    begin
      if GpuTimestampBegin(FQueries[I]) then FOpen := I;
      Exit;
    end;
end;

procedure TAsyncGpuTimer.EndSample;
begin
  if FOpen < 0 then Exit;
  GpuTimestampEnd(FQueries[FOpen]);
  FPending[FOpen] := True;
  FOpen := -1;
end;

function TAsyncGpuTimer.ReadSample(out Nanoseconds: QWord): Boolean;
var I: Integer;
begin
  for I := 0 to High(FQueries) do
    if FPending[I] and GpuTimestampRead(FQueries[I], Nanoseconds) then
    begin
      FPending[I] := False;
      Exit(True);
    end;
  Nanoseconds := 0; Result := False;
end;

end.

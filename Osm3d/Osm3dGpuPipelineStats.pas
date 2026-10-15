unit Osm3dGpuPipelineStats;
{$ifdef ANDROID}{$define OpenGLES}{$endif}
{$mode objfpc}{$H+}

{ Explicit diagnostics only. Hardware pipeline counts are collected in their
  own capture, not used as an FPS benchmark. No atomics or shader changes. }
interface
uses fpjson, {$ifdef OpenGLES}CastleGLES{$else}CastleGL{$endif};
const PipelineCounterCount = 7;
type
  TPipelineValues = array[0..PipelineCounterCount-1] of QWord;
  TAsyncPipelineStats = class
  private
    FQueries: array[0..7,0..PipelineCounterCount-1] of GLuint;
    FPending: array[0..7] of Boolean;
    FOpen: Integer;
    FChecked, FSupported: Boolean;
    FReason,FVendor,FRenderer,FVersion:string;
    FFrames,FSkipped:QWord;
    FSum,FMin,FMax:TPipelineValues;
    procedure ContextClose(Sender:TObject);
    procedure Collect;
    function Supported:Boolean;
  public
    constructor Create;
    destructor Destroy;override;
    procedure BeginFrame;
    procedure EndFrame;
    procedure Snapshot(Dest:TJSONObject;Reset:Boolean);
  end;
implementation
uses SysUtils,Math,CastleApplicationProperties;
const
  Targets:array[0..PipelineCounterCount-1]of Cardinal=(
    $82EE,$82EF,$82F0,$82F4,$82F6,$82F7,$82F5);
  Names:array[0..PipelineCounterCount-1]of string=(
    'vertices_submitted','primitives_submitted','vertex_shader_invocations',
    'fragment_shader_invocations','clipping_input_primitives',
    'clipping_output_primitives','compute_shader_invocations');

constructor TAsyncPipelineStats.Create;
begin
  inherited;FOpen:=-1;
  ApplicationProperties.OnGLContextCloseObject.Add(@ContextClose);
end;
destructor TAsyncPipelineStats.Destroy;
begin
  ApplicationProperties.OnGLContextCloseObject.Remove(@ContextClose);
  ContextClose(nil);inherited;
end;
procedure TAsyncPipelineStats.ContextClose(Sender:TObject);
var I,J:Integer;
begin
  EndFrame;
  for I:=0 to High(FQueries) do for J:=0 to PipelineCounterCount-1 do
    if FQueries[I,J]<>0 then glDeleteQueries(1,@FQueries[I,J]);
  FillChar(FQueries,SizeOf(FQueries),0);FillChar(FPending,SizeOf(FPending),0);
  FChecked:=False;FSupported:=False;FOpen:=-1;
end;
function TAsyncPipelineStats.Supported:Boolean;
{$ifndef OpenGLES}var I,Bits:Integer;{$endif}
begin
  if not FChecked then begin
    FChecked:=True;FReason:='ARB_pipeline_statistics_query unavailable';
    {$ifndef OpenGLES}
    FVendor:=string(PAnsiChar(glGetString(GL_VENDOR)));
    FRenderer:=string(PAnsiChar(glGetString(GL_RENDERER)));
    FVersion:=string(PAnsiChar(glGetString(GL_VERSION)));
    FSupported:=GL_ARB_pipeline_statistics_query and Assigned(glGetQueryObjectui64v);
    if FSupported then for I:=0 to PipelineCounterCount-1 do begin
      glGetQueryiv(Targets[I],GL_QUERY_COUNTER_BITS,@Bits);
      if Bits=0 then begin FSupported:=False;FReason:='Unavailable counter: '+Names[I];Break;end;
    end;
    {$endif}
    if FSupported then FReason:='';
  end;
  Result:=FSupported;
end;
procedure TAsyncPipelineStats.Collect;
{$ifndef OpenGLES}var I,J:Integer;Ready:GLuint;V:GLuint64;Values:TPipelineValues;Complete:Boolean;{$endif}
begin
  {$ifndef OpenGLES}
  for I:=0 to High(FQueries) do if FPending[I] then begin
    Complete:=True;
    for J:=0 to PipelineCounterCount-1 do begin
      glGetQueryObjectuiv(FQueries[I,J],GL_QUERY_RESULT_AVAILABLE,@Ready);
      if Ready=0 then begin Complete:=False;Break;end;
    end;
    if not Complete then Continue;
    for J:=0 to PipelineCounterCount-1 do begin
      glGetQueryObjectui64v(FQueries[I,J],GL_QUERY_RESULT,@V);Values[J]:=V;
    end;
    for J:=0 to PipelineCounterCount-1 do begin
      Inc(FSum[J],Values[J]);
      if (FFrames=0) or (Values[J]<FMin[J]) then FMin[J]:=Values[J];
      if Values[J]>FMax[J] then FMax[J]:=Values[J];
    end;
    Inc(FFrames);FPending[I]:=False;
  end;
  {$endif}
end;
procedure TAsyncPipelineStats.BeginFrame;
{$ifndef OpenGLES}var I,J,Active:Integer;{$endif}
begin
  if (FOpen>=0) or not Supported then Exit;
  Collect;
  {$ifndef OpenGLES}
  { Never nest an existing query target from another diagnostic. }
  for J:=0 to PipelineCounterCount-1 do begin
    glGetQueryiv(Targets[J],GL_CURRENT_QUERY,@Active);
    if Active<>0 then begin Inc(FSkipped);Exit;end;
  end;
  for I:=0 to High(FQueries) do if not FPending[I] then begin
    for J:=0 to PipelineCounterCount-1 do begin
      if FQueries[I,J]=0 then glGenQueries(1,@FQueries[I,J]);
      glBeginQuery(Targets[J],FQueries[I,J]);
    end;
    FOpen:=I;Exit;
  end;
  Inc(FSkipped);
  {$endif}
end;
procedure TAsyncPipelineStats.EndFrame;
{$ifndef OpenGLES}var J:Integer;{$endif}
begin
  if FOpen<0 then Exit;
  {$ifndef OpenGLES}for J:=PipelineCounterCount-1 downto 0 do glEndQuery(Targets[J]);{$endif}
  FPending[FOpen]:=True;FOpen:=-1;
end;
procedure TAsyncPipelineStats.Snapshot(Dest:TJSONObject;Reset:Boolean);
var J:Integer;O:TJSONObject;
begin
  Dest.Add('supported',FSupported);Dest.Add('reason',FReason);
  Dest.Add('vendor',FVendor);Dest.Add('renderer',FRenderer);Dest.Add('version',FVersion);
  Dest.Add('frames',Int64(FFrames));Dest.Add('skipped',Int64(FSkipped));
  Dest.Add('scope','All OpenGL draws between frame BeforeRender and HUD end; excludes Vulkan RTX compute');
  Dest.Add('pixel_semantics','FS invocations, including hidden/alpha-rejected/helper work; not unique screen pixels');
  for J:=0 to PipelineCounterCount-1 do begin
    O:=TJSONObject.Create;Dest.Add(Names[J],O);
    O.Add('total',Int64(FSum[J]));O.Add('min',Int64(FMin[J]));O.Add('max',Int64(FMax[J]));
    if FFrames>0 then O.Add('mean',FSum[J]/FFrames);
  end;
  if Reset then begin
    FFrames:=0;FSkipped:=0;FillChar(FSum,SizeOf(FSum),0);
    FillChar(FMin,SizeOf(FMin),0);FillChar(FMax,SizeOf(FMax),0);
  end;
end;
end.

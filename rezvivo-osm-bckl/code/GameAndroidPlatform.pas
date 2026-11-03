unit GameAndroidPlatform;
{$mode objfpc}{$H+}
{$codepage UTF8}
interface
uses Classes, SysUtils;

var AndroidPhysicalDpi:Single=160;
    AndroidKeyboardBottomPixels:Integer=0;

procedure InitializeAndroidPlatform;
function AndroidPreviousExitInfo(Pid: Integer; SinceUtcMs: Int64): String;
function AndroidNewHttpRequest: Int64;
procedure AndroidCancelHttpRequest(Id: Int64);
procedure AndroidFinishHttpRequest(Id: Int64);
procedure AndroidHttpRequest(Id: Int64; const Method, Url: String;
  Headers: TStrings; Body: TStream; ConnectMs, ReadMs: Integer;
  Response: TStream; out Status: Integer; ResponseHeaders: TStrings;
  FollowRedirects: Boolean = True; MaxBytes: Int64 = 0);

implementation
uses JNI, CastleAndroidNativeAppGlue, CastleFilesUtils, CastleURIUtils, Osm3dPlatformHttp,
  CastleMessaging, CastleStringUtils, CastleWindow, CastleKeysMouse,
  GameMachineInfo, CastleLog, GameLocalization, CastleInternalAndroidShaderJobs;
type
  TAndroidNavigation=class
    constructor Create;
    destructor Destroy;override;
    function Receive(const Parts:TCastleStringList;const Stream:TMemoryStream):Boolean;
  end;
  TAndroidMapRequest = class(TOsmPlatformHttpRequest)
  private FId: Int64;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Execute(const Method, Url: String; Headers: TStrings; Body: TStream;
      ConnectMs, ReadMs: Integer; Response: TStream; out Status: Integer;
      ResponseHeaders: TStrings); override;
    procedure Cancel; override;
  end;
var
  PlatformClass: jclass;
  NewRequestMethod, CancelMethod, FinishMethod, HttpMethod: jmethodID;
  PreviousExitMethod: jmethodID;
  GraphicsProgressMethod: jmethodID;
  GraphicsProgressClass: jclass;
  GraphicsProgressDisabled: Boolean;
  Navigation:TAndroidNavigation;

constructor TAndroidNavigation.Create;
begin inherited;Messaging.OnReceive.Add(@Receive) end;
destructor TAndroidNavigation.Destroy;
begin Messaging.OnReceive.Remove(@Receive);inherited end;
function TAndroidNavigation.Receive(const Parts:TCastleStringList;
  const Stream:TMemoryStream):Boolean;
var Event:TInputPressRelease;
begin
  if (Parts.Count=2)and(Parts[0]='rezvivo-keyboard-inset') then
  begin
    AndroidKeyboardBottomPixels:=StrToIntDef(Parts[1],0);
    if AndroidKeyboardBottomPixels<0 then AndroidKeyboardBottomPixels:=0;
    Exit(True);
  end;
  Result:=(Parts.Count=1)and(Parts[0]='rezvivo-back');
  if not Result or(Application.MainWindow=nil)then Exit;
  { Dispatch on the native UI thread through the same hierarchy as Escape:
    dialogs first, then page details, then menu/ride. }
  with Application.MainWindow.Container do begin
    Event:=InputKey(MousePosition,keyEscape,'',[]);
    EventPress(Event);EventRelease(Event);
  end;
end;

function CreateMapRequest: TOsmPlatformHttpRequest;
begin Result := TAndroidMapRequest.Create end;

constructor TAndroidMapRequest.Create;
begin inherited; FId := AndroidNewHttpRequest end;
destructor TAndroidMapRequest.Destroy;
begin AndroidFinishHttpRequest(FId); inherited end;
procedure TAndroidMapRequest.Cancel;
begin AndroidCancelHttpRequest(FId) end;
procedure TAndroidMapRequest.Execute(const Method, Url: String; Headers: TStrings; Body: TStream;
  ConnectMs, ReadMs: Integer; Response: TStream; out Status: Integer; ResponseHeaders: TStrings);
begin AndroidHttpRequest(FId, Method, Url, Headers, Body, ConnectMs, ReadMs, Response, Status, ResponseHeaders, not NoRedirects, MaxResponseBytes) end;

function Attach(out Detach: Boolean): PJNIEnv;
var Code: jint;
begin
  if (AndroidMainApp = nil) or (AndroidMainApp^.Activity = nil) then
    raise Exception.Create('Android activity is not available');
  Result := nil;
  Code := AndroidMainApp^.Activity^.VM^^.GetEnv(AndroidMainApp^.Activity^.VM,
    @Result, JNI_VERSION_1_6);
  Detach := Code = JNI_EDETACHED;
  if Detach then Code := AndroidMainApp^.Activity^.VM^^.AttachCurrentThread(
    AndroidMainApp^.Activity^.VM, @Result, nil);
  if Code <> JNI_OK then raise Exception.Create('Cannot attach Android worker');
  if Result^^.PushLocalFrame(Result, 32) <> JNI_OK then
  begin
    if Detach then AndroidMainApp^.Activity^.VM^^.DetachCurrentThread(AndroidMainApp^.Activity^.VM);
    raise Exception.Create('Cannot allocate JNI local frame');
  end;
end;

procedure Release(Env: PJNIEnv; Detach: Boolean);
begin
  Env^^.PopLocalFrame(Env, nil);
  if Detach then AndroidMainApp^.Activity^.VM^^.DetachCurrentThread(AndroidMainApp^.Activity^.VM);
end;

procedure Check(Env: PJNIEnv; const Operation: String);
begin
  if Env^^.ExceptionCheck(Env) <> 0 then
  begin
    Env^^.ExceptionDescribe(Env);
    Env^^.ExceptionClear(Env);
    raise Exception.Create('Android ' + Operation + ' failed; see system log');
  end;
end;

function JavaString(Env: PJNIEnv; const Value: String): jstring;
var U: UnicodeString;
begin
  U := UTF8Decode(Value);
  Result := Env^^.NewString(Env, PJChar(PWideChar(U)), Length(U));
  Check(Env, 'string allocation');
end;

function PascalString(Env: PJNIEnv; Value: jstring): String;
var Chars: PJChar; U: UnicodeString; Count: jsize; IsCopy: jboolean;
begin
  if Value = nil then Exit('');
  Count := Env^^.GetStringLength(Env, Value);
  IsCopy := 0;
  Chars := Env^^.GetStringChars(Env, Value, IsCopy);
  Check(Env, 'string access');
  if Chars = nil then raise Exception.Create('Cannot access Android string');
  try SetString(U, PWideChar(Chars), Count); Result := UTF8Encode(U);
  finally Env^^.ReleaseStringChars(Env, Value, Chars) end;
end;

function LoadPlatformClass(Env: PJNIEnv): jclass;
var ActivityClass, LoaderClass: jclass; Loader: jobject; M: jmethodID; Arg: jvalue;
begin
  ActivityClass := Env^^.GetObjectClass(Env, AndroidMainApp^.Activity^.Clazz);
  M := Env^^.GetMethodID(Env, ActivityClass, 'getClassLoader', '()Ljava/lang/ClassLoader;');
  Check(Env, 'class loader lookup');
  Loader := Env^^.CallObjectMethodA(Env, AndroidMainApp^.Activity^.Clazz, M, nil);
  Check(Env, 'class loader');
  LoaderClass := Env^^.GetObjectClass(Env, Loader);
  M := Env^^.GetMethodID(Env, LoaderClass, 'loadClass', '(Ljava/lang/String;)Ljava/lang/Class;');
  Check(Env, 'load class method');
  Arg.l := JavaString(Env, 'io.castleengine.RezvivoPlatform');
  Result := Env^^.CallObjectMethodA(Env, Loader, M, @Arg);
  Check(Env, 'platform class');
  if Result = nil then raise Exception.Create('Android platform service is missing');
end;

procedure ShaderProgress(const Stage, Name: String; const ElapsedMs: QWord;
  const Finished: Boolean);
var Env: PJNIEnv; Detach: Boolean; Args: array[0..3] of jvalue;
  Caption, LowerName: String;
begin
  if GraphicsProgressDisabled or (AndroidMainApp = nil) then Exit;
  { A status badge must never turn a successful resource load into an error. }
  try
    if Stage = 'cache' then Caption := 'Loading cached graphics'
    else if Stage = 'save' then Caption := 'Saving graphics cache'
    else begin
      LowerName := LowerCase(Name);
      if (Pos('rider', LowerName) > 0) or (Pos('avatar', LowerName) > 0) then
        Caption := 'Preparing rider'
      else if (Pos('ground', LowerName) > 0) or (Pos('tree', LowerName) > 0) or
        (Pos('grass', LowerName) > 0) or (Pos('building', LowerName) > 0) then
        Caption := 'Preparing scenery'
      else Caption := 'Preparing graphics';
    end;
    { CGE compiles its first image shader before ApplicationInitialize.
      Resources/localization are not installed yet at that early stage. }
    if PlatformClass <> nil then Caption := T(Caption);
    Caption := Caption + '...';
    if ElapsedMs >= 1000 then begin
      if PlatformClass <> nil then LowerName := T('Elapsed: %d s')
      else LowerName := 'Elapsed: %d s';
      Caption := Caption + LineEnding + Format(LowerName, [ElapsedMs div 1000]);
    end;
    Env := Attach(Detach);
    try
      if GraphicsProgressClass = nil then begin
        GraphicsProgressClass := Env^^.NewGlobalRef(Env, LoadPlatformClass(Env));
        Check(Env, 'graphics progress class');
        GraphicsProgressMethod := Env^^.GetStaticMethodID(Env, GraphicsProgressClass, 'graphicsProgress',
          '(Landroid/app/Activity;Ljava/lang/String;JZ)V');
        Check(Env, 'graphics progress method');
      end;
      FillChar(Args, SizeOf(Args), 0);
      Args[0].l := AndroidMainApp^.Activity^.Clazz;
      Args[1].l := JavaString(Env, Caption);
      Args[2].j := ElapsedMs;
      Args[3].z := Ord(Finished);
      Env^^.CallStaticVoidMethodA(Env, GraphicsProgressClass, GraphicsProgressMethod, @Args[0]);
      Check(Env, 'graphics progress');
    finally Release(Env, Detach) end;
  except
    on E: Exception do begin
      GraphicsProgressMethod := nil;
      GraphicsProgressDisabled := True;
      WritelnWarning('Android graphics progress', E.ClassName);
    end;
  end;
end;

procedure InitializeAndroidPlatform;
var Env: PJNIEnv; Detach: Boolean;
  Found, Directory: jobject; M: jmethodID; Args: array[0..0] of jvalue;
  Root: String;
begin
  if PlatformClass <> nil then Exit;
  Env := Attach(Detach);
  try
    Found := LoadPlatformClass(Env);
    NewRequestMethod := Env^^.GetStaticMethodID(Env, Found, 'newRequest', '()J');
    CancelMethod := Env^^.GetStaticMethodID(Env, Found, 'cancelRequest', '(J)V');
    FinishMethod := Env^^.GetStaticMethodID(Env, Found, 'finishRequest', '(J)V');
    HttpMethod := Env^^.GetStaticMethodID(Env, Found, 'http',
      '(JLjava/lang/String;Ljava/lang/String;Ljava/lang/String;[BIIZI)[Ljava/lang/Object;');
    Check(Env, 'HTTP methods');
    M := Env^^.GetStaticMethodID(Env, Found, 'prepareAssets', '(Landroid/app/Activity;)Ljava/lang/String;');
    Check(Env, 'asset method');
    Args[0].l := AndroidMainApp^.Activity^.Clazz;
    Directory := Env^^.CallStaticObjectMethodA(Env, Found, M, @Args[0]);
    Check(Env, 'asset installation');
    Root := PascalString(Env, Directory);
    if (Root = '') or not DirectoryExists(Root) then raise Exception.Create('Android resources are not installed');
    ApplicationDataOverride := FilenameToUriSafe(IncludeTrailingPathDelimiter(Root));
    M := Env^^.GetStaticMethodID(Env, Found, 'displayDpi', '(Landroid/app/Activity;)F');
    Check(Env, 'display metrics method');
    AndroidPhysicalDpi := Env^^.CallStaticFloatMethodA(Env, Found, M, @Args[0]);
    Check(Env, 'display metrics');
    PlatformClass := Env^^.NewGlobalRef(Env, Found);
    Check(Env, 'platform reference');
    { Optional diagnostics cannot make a working device fail to start. }
    try
      M := Env^^.GetStaticMethodID(Env, Found, 'machineInformation', '(Landroid/app/Activity;)Ljava/lang/String;');
      Check(Env, 'machine information method');
      Directory := Env^^.CallStaticObjectMethodA(Env, Found, M, @Args[0]);
      Check(Env, 'machine information');
      SetMachinePlatformInformation(PascalString(Env, Directory));
      PreviousExitMethod := Env^^.GetStaticMethodID(Env, Found, 'previousExitInfo',
        '(Landroid/app/Activity;IJ)Ljava/lang/String;');
      Check(Env, 'previous process exit method');
    except on E: Exception do WritelnWarning('Android diagnostics', E.ClassName); end;
    OsmPlatformHttpFactory := @CreateMapRequest;
    Navigation:=TAndroidNavigation.Create;
  finally Release(Env, Detach) end;
end;

function AndroidPreviousExitInfo(Pid: Integer; SinceUtcMs: Int64): String;
var Env: PJNIEnv; Detach: Boolean; Args: array[0..2] of jvalue; Reply: jstring;
begin
  Result := '';
  if (PlatformClass = nil) or (PreviousExitMethod = nil) then Exit;
  Env := Attach(Detach);
  try
    FillChar(Args, SizeOf(Args), 0);
    Args[0].l := AndroidMainApp^.Activity^.Clazz;
    Args[1].i := Pid;
    Args[2].j := SinceUtcMs;
    Reply := Env^^.CallStaticObjectMethodA(Env, PlatformClass, PreviousExitMethod, @Args[0]);
    Check(Env, 'previous process exit');
    Result := PascalString(Env, Reply);
  finally Release(Env, Detach) end;
end;

function AndroidNewHttpRequest: Int64;
var Env: PJNIEnv; Detach: Boolean;
begin
  if PlatformClass = nil then raise Exception.Create('Android HTTP is not initialized');
  Env := Attach(Detach);
  try
    Result := Env^^.CallStaticLongMethodA(Env, PlatformClass, NewRequestMethod, nil);
    Check(Env, 'HTTP request allocation');
  finally Release(Env, Detach) end;
end;

procedure RequestAction(Id: Int64; Method: jmethodID);
var Env: PJNIEnv; Detach: Boolean; Arg: jvalue;
begin
  Env := Attach(Detach);
  try
    Arg.j := Id;
    Env^^.CallStaticVoidMethodA(Env, PlatformClass, Method, @Arg);
    Check(Env, 'HTTP request cleanup');
  finally Release(Env, Detach) end;
end;

procedure AndroidCancelHttpRequest(Id: Int64);
begin RequestAction(Id, CancelMethod) end;
procedure AndroidFinishHttpRequest(Id: Int64);
begin RequestAction(Id, FinishMethod) end;

procedure AndroidHttpRequest(Id: Int64; const Method, Url: String;
  Headers: TStrings; Body: TStream; ConnectMs, ReadMs: Integer;
  Response: TStream; out Status: Integer; ResponseHeaders: TStrings;
  FollowRedirects: Boolean; MaxBytes: Int64);
var Env: PJNIEnv; Detach: Boolean; Args: array[0..8] of jvalue;
  Reply: jobjectArray; Bytes: jbyteArray; Buffer: array[0..65535] of Byte;
  Count, Offset, Total: Integer; Error: String;
begin
  Env := Attach(Detach);
  try
    FillChar(Args, SizeOf(Args), 0);
    Args[0].j := Id;
    Args[1].l := JavaString(Env, Method);
    Args[2].l := JavaString(Env, Url);
    if Headers <> nil then Args[3].l := JavaString(Env, Headers.Text)
    else Args[3].l := JavaString(Env, '');
    if Body <> nil then
    begin
      if Body.Size > 256 * 1024 * 1024 then raise Exception.Create('Android HTTP body exceeds 256 MiB');
      Bytes := Env^^.NewByteArray(Env, Body.Size);
      Check(Env, 'HTTP body allocation');
      Body.Position := 0; Offset := 0;
      repeat
        Count := Body.Read(Buffer, SizeOf(Buffer));
        if Count > 0 then Env^^.SetByteArrayRegion(Env, Bytes, Offset, Count, PJByte(@Buffer[0]));
        Inc(Offset, Count);
      until Count = 0;
      Check(Env, 'HTTP body copy');
      Args[4].l := Bytes;
    end;
    Args[5].i := ConnectMs; Args[6].i := ReadMs;
    Args[7].z := Ord(FollowRedirects);
    if (MaxBytes <= 0) or (MaxBytes > 256 * 1024 * 1024) then MaxBytes := 256 * 1024 * 1024;
    Args[8].i := MaxBytes;
    Reply := Env^^.CallStaticObjectMethodA(Env, PlatformClass, HttpMethod, @Args[0]);
    Check(Env, 'HTTP request');
    if Reply = nil then raise Exception.Create('Android HTTP returned no response');
    Error := PascalString(Env, Env^^.GetObjectArrayElement(Env, Reply, 3));
    if Error <> '' then raise Exception.Create(Error);
    Status := StrToInt(PascalString(Env, Env^^.GetObjectArrayElement(Env, Reply, 0)));
    if ResponseHeaders <> nil then ResponseHeaders.Text := PascalString(Env,
      Env^^.GetObjectArrayElement(Env, Reply, 1));
    Bytes := Env^^.GetObjectArrayElement(Env, Reply, 2);
    Total := Env^^.GetArrayLength(Env, Bytes); Offset := 0;
    while Offset < Total do
    begin
      Count := Total - Offset;
      if Count > SizeOf(Buffer) then Count := SizeOf(Buffer);
      Env^^.GetByteArrayRegion(Env, Bytes, Offset, Count, PJByte(@Buffer[0]));
      Check(Env, 'HTTP response copy');
      Response.WriteBuffer(Buffer, Count); Inc(Offset, Count);
    end;
  finally Release(Env, Detach) end;
end;

{ PlatformClass lives as long as the native library. Worker finalizers can still
  use it after Application.OnInitialize's owning unit has finalized. }
initialization
  AndroidShaderProgress := @ShaderProgress;
finalization
  AndroidShaderProgress := nil;
  FreeAndNil(Navigation);
end.

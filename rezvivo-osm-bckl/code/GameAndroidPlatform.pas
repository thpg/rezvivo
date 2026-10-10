unit GameAndroidPlatform;
{$mode objfpc}{$H+}
interface
uses Classes, SysUtils;

var AndroidPhysicalDpi:Single=160;

procedure InitializeAndroidPlatform;
function AndroidNewHttpRequest: Int64;
procedure AndroidCancelHttpRequest(Id: Int64);
procedure AndroidFinishHttpRequest(Id: Int64);
procedure AndroidHttpRequest(Id: Int64; const Method, Url: String;
  Headers: TStrings; Body: TStream; ConnectMs, ReadMs: Integer;
  Response: TStream; out Status: Integer; ResponseHeaders: TStrings;
  FollowRedirects: Boolean = True; MaxBytes: Int64 = 0);

implementation
uses JNI, CastleAndroidNativeAppGlue, CastleFilesUtils, CastleURIUtils, Osm3dPlatformHttp;
type
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

procedure InitializeAndroidPlatform;
var Env: PJNIEnv; Detach: Boolean; ActivityClass, LoaderClass: jclass;
  Loader, Found, Directory: jobject; M: jmethodID; Args: array[0..0] of jvalue;
  Root: String;
begin
  if PlatformClass <> nil then Exit;
  Env := Attach(Detach);
  try
    ActivityClass := Env^^.GetObjectClass(Env, AndroidMainApp^.Activity^.Clazz);
    M := Env^^.GetMethodID(Env, ActivityClass, 'getClassLoader', '()Ljava/lang/ClassLoader;');
    Check(Env, 'class loader lookup');
    Loader := Env^^.CallObjectMethodA(Env, AndroidMainApp^.Activity^.Clazz, M, nil);
    Check(Env, 'class loader');
    LoaderClass := Env^^.GetObjectClass(Env, Loader);
    M := Env^^.GetMethodID(Env, LoaderClass, 'loadClass', '(Ljava/lang/String;)Ljava/lang/Class;');
    Args[0].l := JavaString(Env, 'io.castleengine.RezvivoPlatform');
    Found := Env^^.CallObjectMethodA(Env, Loader, M, @Args[0]);
    Check(Env, 'platform class');
    if Found = nil then raise Exception.Create('Android platform service is missing');
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
    OsmPlatformHttpFactory := @CreateMapRequest;
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
end.

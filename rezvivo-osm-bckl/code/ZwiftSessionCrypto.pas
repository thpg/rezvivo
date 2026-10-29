{ Legacy Play/Click transport. Protocol independently implemented from
  https://www.makinolo.com/blog/2023/10/08/connecting-to-zwift-play-controllers/
  Cryptographic primitives are provided by OpenSSL, never by handwritten AES
  or elliptic-curve arithmetic. Keys are session-local; unauthenticated or
  replayed packets never reach the controller decoder. }
unit ZwiftSessionCrypto;
{$mode objfpc}{$H+}
interface
uses SysUtils,Dynlibs;
type
  TZwiftSessionCrypto=class
  private
    FLib:TLibHandle;
    FKey:Pointer;
    FPublic:TBytes;
    FSecret:array[0..35]of Byte;
    FReady,FReceived:Boolean;
    FCounter:Cardinal;
    NewKey:function(Nid:Integer):Pointer;cdecl;
    GenerateKey:function(Key:Pointer):Integer;cdecl;
    FreeKey:procedure(Key:Pointer);cdecl;
    GetGroup,GetPublic:function(Key:Pointer):Pointer;cdecl;
    NewPoint:function(Group:Pointer):Pointer;cdecl;
    FreePoint:procedure(Point:Pointer);cdecl;
    PointToOct:function(Group,Point:Pointer;Form:Integer;Buf:Pointer;Len:NativeUInt;Ctx:Pointer):NativeUInt;cdecl;
    OctToPoint:function(Group,Point,Buf:Pointer;Len:NativeUInt;Ctx:Pointer):Integer;cdecl;
    IsOnCurve:function(Group,Point,Ctx:Pointer):Integer;cdecl;
    Derive:function(Buf:Pointer;Len:NativeUInt;Point,Key,Kdf:Pointer):Integer;cdecl;
    SHA256,AES256CCM,NewCtx:function:Pointer;cdecl;
    FreeCtx:procedure(Ctx:Pointer);cdecl;
    Hmac:function(Md,Key:Pointer;KeyLen:Integer;Data:Pointer;Len:NativeUInt;OutData:Pointer;OutLen:PCardinal):Pointer;cdecl;
    DecryptInit:function(Ctx,Cipher,Engine,Key,IV:Pointer):Integer;cdecl;
    Control:function(Ctx:Pointer;Kind,Arg:Integer;Data:Pointer):Integer;cdecl;
    DecryptUpdate:function(Ctx,OutData:Pointer;OutLen:PInteger;InData:Pointer;InLen:Integer):Integer;cdecl;
    function Load:Boolean;
  public
    destructor Destroy;override;
    function BeginHandshake:TBytes;
    function CompleteHandshake(const Bytes:TBytes):Boolean;
    function Decrypt(const Bytes:TBytes;out Plain:TBytes):Boolean;
    property Ready:Boolean read FReady;
  end;
implementation
function TZwiftSessionCrypto.Load:Boolean;
  function Bind(var Proc;const Name:AnsiString):Boolean;
  begin Pointer(Proc):=GetProcedureAddress(FLib,Name);Result:=Pointer(Proc)<>nil end;
begin
  if FLib<>NilHandle then Exit(Assigned(DecryptUpdate));
  {$ifdef WINDOWS}
    {$ifdef CPU64}
    FLib:=LoadLibrary(ExtractFilePath(ParamStr(0))+'libcrypto-3-x64.dll');
    if FLib=NilHandle then FLib:=LoadLibrary(ExtractFilePath(ParamStr(0))+'libcrypto-1_1-x64.dll');
    {$else}
    FLib:=LoadLibrary(ExtractFilePath(ParamStr(0))+'libcrypto-3.dll');
    if FLib=NilHandle then FLib:=LoadLibrary(ExtractFilePath(ParamStr(0))+'libcrypto-1_1.dll');
    {$endif}
  {$else}
    {$ifdef DARWIN}FLib:=LoadLibrary('libcrypto.3.dylib');{$else}FLib:=LoadLibrary('libcrypto.so.3');{$endif}
    if FLib=NilHandle then FLib:=LoadLibrary('libcrypto.so.1.1');
    if FLib=NilHandle then FLib:=LoadLibrary('libcrypto.so');
  {$endif}
  Result:=(FLib<>NilHandle)and
    Bind(NewKey,'EC_KEY_new_by_curve_name')and Bind(GenerateKey,'EC_KEY_generate_key')and
    Bind(FreeKey,'EC_KEY_free')and Bind(GetGroup,'EC_KEY_get0_group')and
    Bind(GetPublic,'EC_KEY_get0_public_key')and Bind(NewPoint,'EC_POINT_new')and
    Bind(FreePoint,'EC_POINT_free')and Bind(PointToOct,'EC_POINT_point2oct')and
    Bind(OctToPoint,'EC_POINT_oct2point')and Bind(IsOnCurve,'EC_POINT_is_on_curve')and
    Bind(Derive,'ECDH_compute_key')and Bind(SHA256,'EVP_sha256')and Bind(Hmac,'HMAC')and
    Bind(NewCtx,'EVP_CIPHER_CTX_new')and Bind(FreeCtx,'EVP_CIPHER_CTX_free')and
    Bind(AES256CCM,'EVP_aes_256_ccm')and Bind(DecryptInit,'EVP_DecryptInit_ex')and
    Bind(Control,'EVP_CIPHER_CTX_ctrl')and Bind(DecryptUpdate,'EVP_DecryptUpdate');
  if not Result and(FLib<>NilHandle)then begin UnloadLibrary(FLib);FLib:=NilHandle end;
end;
destructor TZwiftSessionCrypto.Destroy;
begin
  if FKey<>nil then FreeKey(FKey);
  FillChar(FSecret,SizeOf(FSecret),0);
  if FLib<>NilHandle then UnloadLibrary(FLib);
  inherited;
end;
function TZwiftSessionCrypto.BeginHandshake:TBytes;
begin
  Result:=nil;FReady:=False;FReceived:=False;
  FillChar(FSecret,SizeOf(FSecret),0);
  if not Load then Exit;
  if FKey<>nil then FreeKey(FKey);
  FKey:=NewKey(415); // NID_X9_62_prime256v1
  if(FKey=nil)or(GenerateKey(FKey)<>1)then Exit;
  SetLength(FPublic,65);
  if PointToOct(GetGroup(FKey),GetPublic(FKey),4,@FPublic[0],65,nil)<>65 then Exit;
  Result:=TBytes.Create($52,$69,$64,$65,$4F,$6E,$01,$02);
  SetLength(Result,72);Move(FPublic[1],Result[8],64);
end;
function TZwiftSessionCrypto.CompleteHandshake(const Bytes:TBytes):Boolean;
var Peer:Pointer;Point:array[0..64]of Byte;Salt:array[0..127]of Byte;
  Secret,PRK,T1,T2:array[0..31]of Byte;Expand:array[0..32]of Byte;
  Len:Cardinal;One:Byte;
begin
  Result:=False;
  if FReady or(FKey=nil)or(Length(Bytes)<>72)or(Length(FPublic)<>65)then Exit;
  if(Bytes[0]<>$52)or(Bytes[1]<>$69)or(Bytes[2]<>$64)or(Bytes[3]<>$65)or
    (Bytes[4]<>$4F)or(Bytes[5]<>$6E)then Exit;
  Peer:=NewPoint(GetGroup(FKey));if Peer=nil then Exit;
  try
    Point[0]:=4;Move(Bytes[8],Point[1],64);
    if OctToPoint(GetGroup(FKey),Peer,@Point[0],65,nil)<>1 then Exit;
    if IsOnCurve(GetGroup(FKey),Peer,nil)<>1 then Exit;
    if Derive(@Secret[0],32,Peer,FKey,nil)<>32 then Exit;
    Move(Bytes[8],Salt[0],64);Move(FPublic[1],Salt[64],64);
    Len:=0;if(Hmac(SHA256(),@Salt[0],128,@Secret[0],32,@PRK[0],@Len)=nil)or(Len<>32)then Exit;
    One:=1;Len:=0;if(Hmac(SHA256(),@PRK[0],32,@One,1,@T1[0],@Len)=nil)or(Len<>32)then Exit;
    Move(T1[0],Expand[0],32);Expand[32]:=2;Len:=0;
    if(Hmac(SHA256(),@PRK[0],32,@Expand[0],33,@T2[0],@Len)=nil)or(Len<>32)then Exit;
    Move(T1[0],FSecret[0],32);Move(T2[0],FSecret[32],4);
    FReady:=True;Result:=True;
  finally
    FreePoint(Peer);FillChar(Secret,SizeOf(Secret),0);FillChar(PRK,SizeOf(PRK),0);
    FillChar(T1,SizeOf(T1),0);FillChar(T2,SizeOf(T2),0);FillChar(Expand,SizeOf(Expand),0);
  end;
end;
function TZwiftSessionCrypto.Decrypt(const Bytes:TBytes;out Plain:TBytes):Boolean;
var N,L:Integer;Counter:Cardinal;Nonce:array[0..7]of Byte;Ctx:Pointer;
begin
  Result:=False;Plain:=nil;
  if not FReady or(Length(Bytes)<9)or(Length(Bytes)>520)then Exit;
  Counter:=Cardinal(Bytes[0])or(Cardinal(Bytes[1])shl 8)or
    (Cardinal(Bytes[2])shl 16)or(Cardinal(Bytes[3])shl 24);
  if FReceived and(Counter<=FCounter)then Exit;
  Move(FSecret[32],Nonce[0],4);Move(Bytes[0],Nonce[4],4);
  N:=Length(Bytes)-8;Ctx:=NewCtx();if Ctx=nil then Exit;
  try
    if DecryptInit(Ctx,AES256CCM(),nil,nil,nil)<>1 then Exit;
    if Control(Ctx,9,8,nil)<>1 then Exit; // AEAD_SET_IVLEN
    if Control(Ctx,$11,4,@Bytes[Length(Bytes)-4])<>1 then Exit; // AEAD_SET_TAG
    if DecryptInit(Ctx,nil,nil,@FSecret[0],@Nonce[0])<>1 then Exit;
    if DecryptUpdate(Ctx,nil,@L,nil,N)<>1 then Exit;
    SetLength(Plain,N);
    Result:=(DecryptUpdate(Ctx,@Plain[0],@L,@Bytes[4],N)=1)and(L=N);
    if Result then begin FReceived:=True;FCounter:=Counter end else Plain:=nil;
  finally FreeCtx(Ctx) end;
end;
end.

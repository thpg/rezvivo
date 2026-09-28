{ Update downloads never modify the running installation. Only a size- and
  SHA-256-verified package is renamed from .part to .exe in the user cache. }
unit GameUpdateDownload;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses Classes, SysUtils, SyncObjs, fpjson, GameHttpClient;
type
  TUpdatePackage = record
    Build: Integer;
    Version, SHA256, URL, Kind, FromManifestSHA256: String;
    SizeBytes, ProgramBytes, ResourceBytes: Int64;
    InstallerProtocol: Integer;
  end;
  TUpdateDownloadState = (udsDownloading, udsVerifying, udsReady, udsPaused, udsFailed);
  TUpdateDownloadStatus = record
    State: TUpdateDownloadState;
    Received, Total: Int64;
    ErrorText, Filename: String;
  end;
  TUpdateDownload = class(TThread)
  private
    FLock: TCriticalSection;
    FCancel: TGameHttpCancellation;
    FPackage: TUpdatePackage;
    FStatus: TUpdateDownloadStatus;
    FDirectory: String;
    procedure SetStatus(State: TUpdateDownloadState; Received: Int64;
      const ErrorText: String = '');
  protected
    procedure Execute; override;
  public
    Done: TEvent;
    constructor Create(const Package: TUpdatePackage; const Directory: String);
    destructor Destroy; override;
    procedure Pause;
    function Status: TUpdateDownloadStatus;
  end;
function ParseUpdatePackage(Latest: TJSONObject; const ApiBase: String;
  out Package: TUpdatePackage; const InstalledManifestSHA256: String = '';
  SelectVariants: Boolean = True): Boolean;
function UpdateSHA256(const Filename: String; Cancellation: TGameHttpCancellation = nil): String;
function ValidUpdateRange(const Header: String; Offset, Count, Total: Int64): Boolean;

implementation
uses URIParser, Math, {$IFDEF WINDOWS}Windows,{$ENDIF} GameBuildInfo;
const ChunkBytes = 8 * 1024 * 1024;
type
  TUpdateChunk = class(TMemoryStream)
    function Write(const Buffer; Count: LongInt): LongInt; override;
  end;
function TUpdateChunk.Write(const Buffer; Count: LongInt): LongInt;
begin
  if (Count < 0) or (Position + Count > ChunkBytes) then
    raise Exception.Create('Update response exceeded the requested range');
  Result := inherited Write(Buffer, Count);
end;

function ValidSHA256(const Value: String): Boolean;
var C: Char;
begin
  Result := Length(Value) = 64;
  if Result then for C in Value do
    if not (C in ['0'..'9','a'..'f','A'..'F']) then Exit(False);
end;

function ParseUpdatePackage(Latest: TJSONObject; const ApiBase: String;
  out Package: TUpdatePackage; const InstalledManifestSHA256: String;
  SelectVariants: Boolean): Boolean;
var URI: TURI; Data:TJSONData; I:Integer; Choice:TUpdatePackage;
begin
  Package := Default(TUpdatePackage);
  Result := False;
  if Latest = nil then Exit;
  try
    Package.Build := Latest.Get('build', 0);
    Package.Version := Latest.Get('version', '');
    Package.SHA256 := LowerCase(Latest.Get('sha256', ''));
    Package.SizeBytes := Latest.Get('size_bytes', Int64(0));
    Package.Kind := Latest.Get('kind', 'full');
    Package.FromManifestSHA256 := Latest.Get('from_manifest_sha256', '');
    Package.ProgramBytes := Latest.Get('program_bytes', Int64(0));
    Package.ResourceBytes := Latest.Get('resource_bytes', Int64(0));
    Package.InstallerProtocol := Latest.Get('installer_protocol', 0);
    URI := ParseURI(ApiBase);
    { Executable metadata must come over TLS; loopback is for isolated tests. }
    if (LowerCase(URI.Protocol) <> 'https') and
      not ((LowerCase(URI.Protocol) = 'http') and
      ((URI.Host = '127.0.0.1') or (LowerCase(URI.Host) = 'localhost'))) then Exit;
    if (URI.Host = '') or (URI.UserName <> '') or (URI.Password <> '') then Exit;
    if (Package.Build <= 0) or (Package.SizeBytes <= 0) or
      (Package.SizeBytes > Int64(16) * 1024 * 1024 * 1024) or
      not ValidSHA256(Package.SHA256) then Exit;
    Package.URL := ExcludeTrailingPathDelimiter(ApiBase) + '/client/download/' + IntToStr(Package.Build);
    if Package.Kind = 'delta' then Package.URL := Package.URL + '?variant=' + Package.SHA256;
    Data := Latest.Find('packages');
    if SelectVariants and(Data is TJSONArray) then
      for I := 0 to Math.Min(Data.Count,32)-1 do
        if Data.Items[I] is TJSONObject then
          if ParseUpdatePackage(TJSONObject(Data.Items[I]),ApiBase,Choice,'',False) and
            (Choice.Build=Package.Build) and(Choice.Version=Package.Version) and
            (Choice.InstallerProtocol=1) then begin
            if(Choice.Kind='full')and(Choice.SHA256=Package.SHA256)then Package:=Choice
            else if(Choice.Kind='delta')and(InstalledManifestSHA256<>'')and
              SameText(Choice.FromManifestSHA256,InstalledManifestSHA256)and
              (Choice.SizeBytes<Package.SizeBytes)then Package:=Choice;
          end;
    Result := True;
  except Result := False end;
end;

function ValidUpdateRange(const Header: String; Offset, Count, Total: Int64): Boolean;
var Dash, Slash: Integer; First, Last, Size: Int64; S: String;
begin
  Result := False;
  if (Offset < 0) or (Count <= 0) or (Total <= 0) or (Count > Total - Offset) then Exit;
  S := Trim(Header);
  if Copy(S, 1, 6) <> 'bytes ' then Exit;
  Delete(S, 1, 6);
  Dash := Pos('-', S); Slash := Pos('/', S);
  if (Dash < 2) or (Slash <= Dash + 1) then Exit;
  if not TryStrToInt64(Copy(S,1,Dash-1),First) or
    not TryStrToInt64(Copy(S,Dash+1,Slash-Dash-1),Last) or
    not TryStrToInt64(Copy(S,Slash+1,MaxInt),Size) then Exit;
  Result := (First = Offset) and (Last = Offset + Count - 1) and (Size = Total);
end;

{$IFDEF WINDOWS}
function BCryptOpenAlgorithmProvider(out Algorithm: Pointer; Name, Provider: PWideChar; Flags: Cardinal): LongInt; stdcall; external 'bcrypt.dll';
function BCryptGetProperty(Handle: Pointer; Name: PWideChar; Output: Pointer; Size: Cardinal; out ResultSize: Cardinal; Flags: Cardinal): LongInt; stdcall; external 'bcrypt.dll';
function BCryptCreateHash(Algorithm: Pointer; out Hash: Pointer; ObjectBuffer: Pointer; ObjectSize: Cardinal; Secret: Pointer; SecretSize, Flags: Cardinal): LongInt; stdcall; external 'bcrypt.dll';
function BCryptHashData(Hash, Data: Pointer; Count, Flags: Cardinal): LongInt; stdcall; external 'bcrypt.dll';
function BCryptFinishHash(Hash, Output: Pointer; Count, Flags: Cardinal): LongInt; stdcall; external 'bcrypt.dll';
function BCryptDestroyHash(Hash: Pointer): LongInt; stdcall; external 'bcrypt.dll';
function BCryptCloseAlgorithmProvider(Algorithm: Pointer; Flags: Cardinal): LongInt; stdcall; external 'bcrypt.dll';
procedure CheckCrypto(Status: LongInt);
begin
  if Status < 0 then raise Exception.Create('Cannot verify update SHA-256');
end;
{$ENDIF}

function UpdateSHA256(const Filename: String; Cancellation: TGameHttpCancellation): String;
{$IFDEF WINDOWS}
var Algorithm, Hash: Pointer; ObjectSize, ResultSize: Cardinal;
  ObjectBuffer: TBytes; Digest: array[0..31] of Byte;
  Buffer: array[0..65535] of Byte; Input: TFileStream; Count, I: Integer;
{$ENDIF}
begin
  Result := '';
  {$IFDEF WINDOWS}
  Algorithm := nil; Hash := nil; Input := nil;
  try
    CheckCrypto(BCryptOpenAlgorithmProvider(Algorithm, 'SHA256', nil, 0));
    CheckCrypto(BCryptGetProperty(Algorithm, 'ObjectLength', @ObjectSize, SizeOf(ObjectSize), ResultSize, 0));
    if (ObjectSize = 0) or (ObjectSize > 1024 * 1024) then raise Exception.Create('Invalid SHA-256 provider');
    SetLength(ObjectBuffer, ObjectSize);
    CheckCrypto(BCryptCreateHash(Algorithm, Hash, @ObjectBuffer[0], ObjectSize, nil, 0, 0));
    Input := TFileStream.Create(Filename, fmOpenRead or fmShareDenyWrite);
    repeat
      if Cancellation <> nil then Cancellation.Check;
      Count := Input.Read(Buffer, SizeOf(Buffer));
      if Count > 0 then CheckCrypto(BCryptHashData(Hash, @Buffer[0], Count, 0));
    until Count = 0;
    CheckCrypto(BCryptFinishHash(Hash, @Digest[0], SizeOf(Digest), 0));
    for I := 0 to High(Digest) do Result := Result + LowerCase(IntToHex(Digest[I], 2));
  finally
    Input.Free;
    if Hash <> nil then BCryptDestroyHash(Hash);
    if Algorithm <> nil then BCryptCloseAlgorithmProvider(Algorithm, 0);
  end;
  {$ELSE}
  raise Exception.Create('Verified updates are not supported on this platform');
  {$ENDIF}
end;

constructor TUpdateDownload.Create(const Package: TUpdatePackage; const Directory: String);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FLock := SyncObjs.TCriticalSection.Create;
  FCancel := TGameHttpCancellation.Create;
  Done := TEvent.Create(nil, True, False, '');
  FPackage := Package;
  FDirectory := IncludeTrailingPathDelimiter(Directory);
  FStatus.State := udsDownloading;
  FStatus.Total := Package.SizeBytes;
  FStatus.Filename := FDirectory + IntToStr(Package.Build) + '-' + Package.SHA256 + '.exe';
  Start;
end;

destructor TUpdateDownload.Destroy;
begin
  Pause;
  WaitFor;
  Done.Free;
  FCancel.Free;
  FLock.Free;
  inherited;
end;

procedure TUpdateDownload.Pause;
begin
  Terminate;
  FCancel.Cancel;
end;

function TUpdateDownload.Status: TUpdateDownloadStatus;
begin
  FLock.Enter;
  try Result := FStatus; finally FLock.Leave end;
end;

procedure TUpdateDownload.SetStatus(State: TUpdateDownloadState; Received: Int64; const ErrorText: String);
begin
  FLock.Enter;
  try FStatus.State := State; FStatus.Received := Received; FStatus.ErrorText := ErrorText;
  finally FLock.Leave end;
end;

procedure TUpdateDownload.Execute;
var Partial, Filename, ID, URL, ETag, Encoding: String; IDFile: TStringList;
  GUID: TGUID; Output: TFileStream; Chunk: TUpdateChunk;
  Headers, ResponseHeaders: TStringList; Offset, Last: Int64; Code: Integer;
  function Header(const Name: String): String;
  begin Result := Trim(ResponseHeaders.Values[Name]); end;
begin
  Output := nil; Chunk := nil; Headers := nil; ResponseHeaders := nil; IDFile := nil; Offset := 0;
  try
    try
      if not ValidSHA256(FPackage.SHA256) or (FPackage.SizeBytes <= 0) then
        raise Exception.Create('Invalid update metadata');
      if not ForceDirectories(FDirectory) then raise Exception.Create('Cannot create update cache');
      Filename := FStatus.Filename;
      Partial := Filename + '.part';
      if FileExists(Filename) then
      begin
        SetStatus(udsVerifying, FPackage.SizeBytes);
        Output := TFileStream.Create(Filename, fmOpenRead or fmShareDenyWrite);
        Offset := Output.Size;
        FreeAndNil(Output);
        if (Offset = FPackage.SizeBytes) and (UpdateSHA256(Filename, FCancel) = FPackage.SHA256) then
        begin SetStatus(udsReady, Offset); Exit end;
        if not SysUtils.DeleteFile(Filename) then raise Exception.Create('Cannot replace damaged cached update');
      end;
      IDFile := TStringList.Create;
      if FileExists(Filename + '.id') then IDFile.LoadFromFile(Filename + '.id');
      ID := Trim(IDFile.Text);
      if not TryStringToGUID('{' + ID + '}', GUID) then
      begin
        CreateGUID(GUID);
        ID := LowerCase(Copy(GUIDToString(GUID), 2, 36));
        IDFile.Text := ID;
        IDFile.SaveToFile(Filename + '.id');
      end;
      if Pos('?',FPackage.URL)>0 then URL := FPackage.URL + '&download=' + ID
      else URL := FPackage.URL + '?download=' + ID;
      if FileExists(Partial) then Output := TFileStream.Create(Partial, fmOpenReadWrite or fmShareExclusive)
      else Output := TFileStream.Create(Partial, fmCreate or fmShareExclusive);
      if Output.Size > FPackage.SizeBytes then Output.Size := 0;
      Offset := Output.Size;
      Headers := TStringList.Create;
      ResponseHeaders := TStringList.Create;
      ResponseHeaders.NameValueSeparator := ':';
      Chunk := TUpdateChunk.Create;
      while Offset < FPackage.SizeBytes do
      begin
        FCancel.Check;
        SetStatus(udsDownloading, Offset);
        Last := Math.Min(Offset + ChunkBytes, FPackage.SizeBytes) - 1;
        Headers.Clear;
        Headers.Add('User-Agent: ' + ClientUserAgent);
        Headers.Add('Range: bytes=' + IntToStr(Offset) + '-' + IntToStr(Last));
        Headers.Add('If-Range: "' + FPackage.SHA256 + '"');
        Headers.Add('Accept-Encoding: identity');
        Chunk.Clear;
        GameHttpRequest('GET', URL, Headers, nil, 3000, 6000, Chunk, Code, FCancel, ResponseHeaders);
        Encoding := LowerCase(Header('Content-Encoding'));
        if (Encoding <> '') and (Encoding <> 'identity') then raise Exception.Create('Unexpected update encoding');
        ETag := Header('ETag');
        if (ETag <> '') and (ETag <> '"' + FPackage.SHA256 + '"') then
          raise Exception.Create('Update changed on the server; check for updates again');
        if Code = 206 then
        begin
          if not ValidUpdateRange(Header('Content-Range'), Offset, Chunk.Size, FPackage.SizeBytes) or
            (Chunk.Size <> Last - Offset + 1) then raise Exception.Create('Invalid update byte range');
        end
        else if not ((Code = 200) and (Offset = 0) and (Chunk.Size = FPackage.SizeBytes)) then
          raise Exception.CreateFmt('Update download HTTP %d', [Code]);
        Output.Position := Offset;
        Chunk.Position := 0;
        Output.CopyFrom(Chunk, Chunk.Size);
        Offset := Output.Size;
      end;
      FreeAndNil(Output);
      SetStatus(udsVerifying, Offset);
      if UpdateSHA256(Partial, FCancel) <> FPackage.SHA256 then
      begin
        SysUtils.DeleteFile(Partial);
        raise Exception.Create('Update integrity check failed; download it again');
      end;
      FCancel.Check;
      if not RenameFile(Partial, Filename) then raise Exception.Create('Cannot finish update download');
      SetStatus(udsReady, Offset);
    except
      on E: Exception do
        if Terminated then SetStatus(udsPaused, Offset)
        else SetStatus(udsFailed, Offset, E.Message);
    end;
  finally
    Output.Free; Chunk.Free; Headers.Free; ResponseHeaders.Free; IDFile.Free;
    Done.SetEvent;
  end;
end;
end.

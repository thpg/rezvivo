unit GameJournalWriter;
{$mode objfpc}{$H+}
interface
uses Classes, SysUtils, SyncObjs;
type
  { The render thread only enqueues bytes. The worker owns every file handle. }
  TJournalWriter = class(TThread)
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FPath,FHeader,FPending,FError,FOwner: String;
    FSnapshotPath,FSnapshot: String;
    FAppend,FClosed,FRelease: Boolean;
    function GetError: String;
  protected
    procedure Execute; override;
  public
    constructor Create(const Path,Header:String;AppendExisting:Boolean;const OwnerKey:String='');
    destructor Destroy; override;
    procedure Add(const Line:String);
    procedure Snapshot(const Path,Json:String);
    procedure Finish(ReleaseActivity:Boolean);
    property ErrorText:String read GetError;
  end;
{ Shared by the journal checkpoints and the saved-activity completion journal. }
procedure AtomicSnapshot(const Path,Json:String);
implementation
uses {$ifdef MSWINDOWS}Windows,{$endif} Math;
const MaxQueuedBytes=8*1024*1024;

procedure Durable(Stream:TFileStream);
begin
  {$ifdef MSWINDOWS}
  if not FlushFileBuffers(Stream.Handle) then RaiseLastOSError;
  {$endif}
end;

procedure AtomicSnapshot(const Path,Json:String);
var S:TFileStream;Tmp:String;
begin
  if Path='' then Exit;
  ForceDirectories(ExtractFilePath(Path));Tmp:=Path+'.writing';
  S:=TFileStream.Create(Tmp,fmCreate);
  try if Json<>''then S.WriteBuffer(Json[1],Length(Json));Durable(S);finally S.Free;end;
  {$ifdef MSWINDOWS}
  if not MoveFileExW(PWideChar(UnicodeString(Tmp)),PWideChar(UnicodeString(Path)),
    MOVEFILE_REPLACE_EXISTING or $00000008)then RaiseLastOSError;
  {$else}
  if not RenameFile(Tmp,Path)then RaiseLastOSError;
  {$endif}
end;

constructor TJournalWriter.Create(const Path,Header:String;AppendExisting:Boolean;const OwnerKey:String);
begin
  inherited Create(True);FreeOnTerminate:=False;
  FLock:=SyncObjs.TCriticalSection.Create;FWake:=SyncObjs.TEvent.Create(nil,False,False,'');
  FPath:=Path;FHeader:=Header;FAppend:=AppendExisting;FOwner:=OwnerKey;Start;
end;
destructor TJournalWriter.Destroy;
begin Finish(False);FWake.Free;FLock.Free;inherited;end;
function TJournalWriter.GetError:String;
begin FLock.Enter;try Result:=FError;finally FLock.Leave;end;end;
procedure TJournalWriter.Add(const Line:String);
begin
  FLock.Enter;
  try
    if FClosed then raise EInvalidOperation.Create('Journal is closed');
    if Length(FPending)+Length(Line)>MaxQueuedBytes then
      raise EWriteError.Create('Recording queue is full: '+FError);
    FPending:=FPending+Line+LineEnding;
  finally FLock.Leave;end;
  FWake.SetEvent;
end;
procedure TJournalWriter.Snapshot(const Path,Json:String);
begin
  FLock.Enter;
  try if not FClosed then begin FSnapshotPath:=Path;FSnapshot:=Json;end;
  finally FLock.Leave;end;
  FWake.SetEvent;
end;
procedure TJournalWriter.Finish(ReleaseActivity:Boolean);
begin
  FLock.Enter;
  try if FClosed then Exit;FClosed:=True;FRelease:=ReleaseActivity;
  finally FLock.Leave;end;
  FWake.SetEvent;WaitFor;
end;
procedure PauseBeforeResume(S:TFileStream);
var Tail:String;Parts:TStringList;N,P:Integer;
begin
  N:=Min(Int64(8192),S.Size);SetLength(Tail,N);S.Position:=S.Size-N;
  if N>0 then S.ReadBuffer(Tail[1],N);
  Tail:=TrimRight(Tail);P:=LastDelimiter(#10,Tail);if P>0 then Delete(Tail,1,P);
  Parts:=TStringList.Create;
  try
    Parts.StrictDelimiter:=True;Parts.Delimiter:=',';Parts.QuoteChar:=#0;Parts.DelimitedText:=Tail;
    if(Parts.Count in[17,18])and(Parts[14]='1')then begin
      Parts[14]:='0';Parts[16]:='0';Tail:=Parts.DelimitedText+LineEnding;
      S.Position:=S.Size;S.WriteBuffer(Tail[1],Length(Tail));Durable(S);
    end;
  finally Parts.Free;end;
  S.Position:=S.Size;
end;

procedure TJournalWriter.Execute;
var S,M:TFileStream;Data,SnapshotPath,Json:String;LastFlush:QWord;
    PosBefore,RepairPosition:Int64;Dirty,Good,Closing:Boolean;Tail:Byte;
begin
  S:=nil;Dirty:=False;Good:=False;RepairPosition:=-1;LastFlush:=GetTickCount64;
  try
    repeat
      FLock.Enter;try Closing:=FClosed;finally FLock.Leave;end;
      try
        if S=nil then begin
          ForceDirectories(ExtractFilePath(FPath));
          if FOwner<>''then AtomicSnapshot(FPath+'.owner',FOwner);
          M:=TFileStream.Create(FPath+'.active',fmCreate);M.Free;
          if FAppend and FileExists(FPath)then begin
            S:=TFileStream.Create(FPath,fmOpenReadWrite or fmShareDenyWrite);
            { A torn final line is never appended to or interpreted as telemetry. }
            while S.Size>0 do begin
              S.Position:=S.Size-1;S.ReadBuffer(Tail,1);
              if Tail=10 then Break;S.Size:=S.Size-1;
            end;
            S.Position:=S.Size;
            if RepairPosition<0 then PauseBeforeResume(S);
          end else begin
            M:=TFileStream.Create(FPath,fmCreate);M.Free;
            S:=TFileStream.Create(FPath,fmOpenReadWrite or fmShareDenyWrite);
            Data:=FHeader+LineEnding;
            if Data<>''then S.WriteBuffer(Data[1],Length(Data));
          end;
        end;
        if RepairPosition>=0 then begin S.Size:=RepairPosition;S.Position:=RepairPosition;RepairPosition:=-1;end;
        FLock.Enter;
        try Data:=FPending;FPending:='';SnapshotPath:=FSnapshotPath;Json:=FSnapshot;
          FSnapshotPath:='';FSnapshot:='';
        finally FLock.Leave;end;
        PosBefore:=S.Position;
        try
          if Data<>''then begin S.WriteBuffer(Data[1],Length(Data));Dirty:=True;end;
          if Dirty and(Closing or(Json<>'')or(GetTickCount64-LastFlush>=1000))then begin
            Durable(S);Dirty:=False;LastFlush:=GetTickCount64;
          end;
          if Json<>''then AtomicSnapshot(SnapshotPath,Json);
          FLock.Enter;try FError:='';finally FLock.Leave;end;
        except
          { Retain telemetry on transient failures; roll back a partial write. }
          FLock.Enter;
          try FPending:=Data+FPending;
            if FSnapshot=''then begin FSnapshot:=Json;FSnapshotPath:=SnapshotPath;end;
          finally FLock.Leave;end;
          try S.Size:=PosBefore;S.Position:=PosBefore;
          except FreeAndNil(S);FAppend:=True;RepairPosition:=PosBefore;end;
          raise;
        end;
        Good:=True;
      except on E:Exception do begin
        Good:=False;FLock.Enter;try FError:=E.Message;finally FLock.Leave;end;
      end;end;
      if Closing then Break;
      if Good then FWake.WaitFor(250) else FWake.WaitFor(1000);
    until False;
  finally
    S.Free;
    if Good and FRelease and FileExists(FPath+'.active')then
      if not SysUtils.DeleteFile(FPath+'.active')then begin
        FLock.Enter;
        try FError:='Could not release completed ride: '+SysErrorMessage(GetLastOSError);
        finally FLock.Leave;end;
      end;
  end;
end;
end.

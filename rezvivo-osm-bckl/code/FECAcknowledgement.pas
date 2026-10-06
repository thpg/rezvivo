unit FECAcknowledgement;
{$mode objfpc}{$H+}
interface
uses SysUtils, SyncObjs, GameTrainerControl;
type
  { FE-C command status is page 71, not an ANT USB write acknowledgement.
    Match both command and echoed target. Unsupported status reporting remains
    'sent'; never manufacture an 'accepted' result on timeout. }
  TFECAcknowledgement = class
  private
    FLock: TCriticalSection;
    FEvent: TEvent;
    FPage: TBytes;
    FPending, FHaveSequence, FCancelled: Boolean;
    FLastSequence, FStartSequence: Byte;
    FNextProbe: QWord;
    FResult: TTrainerControlState;
  public
    constructor Create;
    destructor Destroy; override;
    procedure NewConnection;
    function BeginCommand(const Page: TBytes): Boolean;
    procedure Receive(const Page: TBytes);
    function Wait(TimeoutMs: Cardinal): TTrainerControlState;
    procedure Cancel;
  end;
implementation
constructor TFECAcknowledgement.Create;
begin
  inherited;
  FLock:=TCriticalSection.Create;
  FEvent:=TEvent.Create(nil,True,False,'');
  NewConnection;
end;
destructor TFECAcknowledgement.Destroy;
begin FEvent.Free; FLock.Free; inherited end;
procedure TFECAcknowledgement.NewConnection;
begin
  FLock.Enter;
  try
    FPending:=False; FHaveSequence:=False; FCancelled:=False;
    FNextProbe:=0; FResult:=tcsSent; FPage:=nil; FEvent.ResetEvent;
  finally FLock.Leave end;
end;
function TFECAcknowledgement.BeginCommand(const Page: TBytes): Boolean;
begin
  FLock.Enter;
  try
    Result:=(Length(Page)=8) and (Page[0] in [48..51]) and
      (GetTickCount64>=FNextProbe) and not FCancelled;
    FPending:=Result;
    if not Result then Exit;
    FPage:=Copy(Page); FStartSequence:=FLastSequence;
    FResult:=tcsSent; FEvent.ResetEvent;
  finally FLock.Leave end;
end;
procedure TFECAcknowledgement.Receive(const Page: TBytes);
var I,FirstEcho: Integer; Fresh: Boolean;
begin
  if (Length(Page)<>8) or (Page[0]<>71) or (Page[1]=$FF) or (Page[2]=$FF) then Exit;
  FLock.Enter;
  try
    Fresh:=not FHaveSequence or (Page[2]<>FStartSequence);
    FLastSequence:=Page[2]; FHaveSequence:=True;
    if not FPending or not Fresh or (Page[1]<>FPage[0]) then Exit;
    if Page[3]=4 then Exit; { pending }
    if Page[3]=0 then
    begin
      case FPage[0] of
        48: FirstEcho:=7;
        49: FirstEcho:=6;
        else FirstEcho:=5;
      end;
      for I:=FirstEcho to 7 do if Page[I]<>FPage[I] then Exit;
    end;
    case Page[3] of
      0: FResult:=tcsAccepted;
      1: FResult:=tcsFailed;
      2: FResult:=tcsUnsupported;
      3: FResult:=tcsDenied;
      else Exit;
    end;
    FPending:=False; FNextProbe:=0; FEvent.SetEvent;
  finally FLock.Leave end;
end;
function TFECAcknowledgement.Wait(TimeoutMs: Cardinal): TTrainerControlState;
begin
  FEvent.WaitFor(TimeoutMs);
  FLock.Enter;
  try
    if FPending then FNextProbe:=GetTickCount64+30000;
    FPending:=False; Result:=FResult;
  finally FLock.Leave end;
end;
procedure TFECAcknowledgement.Cancel;
begin
  FLock.Enter;
  try
    FCancelled:=True; FPending:=False; FResult:=tcsUnavailable;
    FEvent.SetEvent;
  finally FLock.Leave end;
end;
end.

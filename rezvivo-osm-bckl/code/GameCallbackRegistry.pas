unit GameCallbackRegistry;

{$mode objfpc}{$H+}

interface

uses GameTrainerControl;

{ For C libraries that cannot own/release a callback context. UserData is a
  monotonically increasing opaque token, NEVER an address to dereference.
  Removing the token blocks late callbacks, drains acquired callbacks and
  releases the gate. Reconnect receives a new token, so old data cannot enter
  the new session even if the external library dispatches after unsubscribe. }
function RegisterCallbackTarget(Target:TObject):Pointer;
function AcquireCallbackTarget(Token:Pointer;out Target:TObject):TTrainerCallbackGate;
procedure UnregisterCallbackTarget(var Token:Pointer);

implementation

uses SysUtils;

type TEntry=record Token:NativeUInt;Gate:TTrainerCallbackGate;end;
var Entries:array of TEntry;
    Lock:TRTLCriticalSection;
    Serial:NativeUInt=0;
    Closed:Boolean=False;

function RegisterCallbackTarget(Target:TObject):Pointer;
var N:Integer;Gate:TTrainerCallbackGate;
begin
  { Construct before publishing an entry: allocation failure must never leave
    a token whose gate is nil in the callback lookup table. }
  Gate:=TTrainerCallbackGate.Create(Target);
  try
  EnterCriticalSection(Lock);
  try
    if Closed or (Serial=High(NativeUInt)) then
      raise Exception.Create('Callback registry closed');
    N:=Length(Entries);SetLength(Entries,N+1);Inc(Serial);
    Entries[N].Token:=Serial;Entries[N].Gate:=Gate;Gate:=nil;
    Result:=Pointer(Serial);
  finally LeaveCriticalSection(Lock);end;
  finally Gate.Free;end;
end;

function AcquireCallbackTarget(Token:Pointer;out Target:TObject):TTrainerCallbackGate;
var I:Integer;
begin
  Result:=nil;Target:=nil;
  EnterCriticalSection(Lock);
  try
    if Closed or (Token=nil) then Exit;
    for I:=0 to High(Entries) do
      if Entries[I].Token=NativeUInt(Token) then begin
        if Entries[I].Gate.Acquire(Target) then Result:=Entries[I].Gate;
        Exit;
      end;
  finally LeaveCriticalSection(Lock);end;
end;

procedure UnregisterCallbackTarget(var Token:Pointer);
var I,N:Integer;Gate:TTrainerCallbackGate;
begin
  Gate:=nil;
  EnterCriticalSection(Lock);
  try
    N:=Length(Entries);
    for I:=0 to N-1 do
      if Entries[I].Token=NativeUInt(Token) then begin
        Gate:=Entries[I].Gate;Gate.Detach;
        Entries[I]:=Entries[N-1];SetLength(Entries,N-1);Break;
      end;
    Token:=nil;
  finally LeaveCriticalSection(Lock);end;
  { Never hold the registry lock while waiting for an acquired callback. }
  if Gate<>nil then begin Gate.WaitForIdle;Gate.Free;end;
end;

initialization
  InitCriticalSection(Lock);
finalization
  { DLL callbacks can still be in the OS dispatch queue. Keep this tiny
    process-lifetime lock valid until OS teardown; no target remains usable. }
  EnterCriticalSection(Lock);
  Closed:=True;
  LeaveCriticalSection(Lock);
end.

unit GameAccountChange;
{$mode objfpc}{$H+}
interface
{ Leases belong to a stable local rider key. EndAccountChange uses its token,
  so a detached worker never resolves a changing UI selection. }
function BeginAccountChange(RiderIndex:Integer=0):QWord;
procedure EndAccountChange(const Token:QWord);
function AccountChangePending(RiderIndex:Integer=0):Boolean;
function RiderAccountChangeError(RiderIndex:Integer=0):String;
procedure BeginRideAccount(RiderIndex:Integer=0);
procedure EndRideAccount(RiderIndex:Integer=0);
implementation
uses SysUtils,Classes,GameUserData;
type TAccountGate=record Key:String;Pending:QWord;Rides:Integer;end;
var Lock:TRTLCriticalSection;Generation:QWord;Gates:array of TAccountGate;
function GateFor(const Key:String):Integer;
var I:Integer;
begin
  for I:=0 to High(Gates)do if Gates[I].Key=Key then Exit(I);
  Result:=Length(Gates);SetLength(Gates,Result+1);Gates[Result].Key:=Key;
end;
function BeginAccountChange(RiderIndex:Integer):QWord;
var I:Integer;Key:String;
begin
  Key:=LocalRider(RiderIndex).Key;
  EnterCriticalSection(Lock);
  try
    I:=GateFor(Key);
    if Gates[I].Rides<>0 then raise EInvalidOperation.Create('Finish this rider''s ride before switching accounts.');
    if Gates[I].Pending<>0 then raise EInvalidOperation.Create('Account change in progress. Please wait.');
    Inc(Generation);if Generation=0 then Inc(Generation);
    Gates[I].Pending:=Generation;Result:=Generation;
  finally LeaveCriticalSection(Lock);end;
end;
procedure EndAccountChange(const Token:QWord);
var I:Integer;
begin
  if Token=0 then Exit;
  EnterCriticalSection(Lock);
  try for I:=0 to High(Gates)do if Gates[I].Pending=Token then begin Gates[I].Pending:=0;Break end;
  finally LeaveCriticalSection(Lock);end;
end;
function AccountChangePending(RiderIndex:Integer):Boolean;
var I:Integer;Key:String;
begin
  Key:=LocalRider(RiderIndex).Key;
  EnterCriticalSection(Lock);
  try I:=GateFor(Key);Result:=Gates[I].Pending<>0;finally LeaveCriticalSection(Lock);end;
end;
function RiderAccountChangeError(RiderIndex:Integer):String;
var I:Integer;Key:String;
begin
  Key:=LocalRider(RiderIndex).Key;
  EnterCriticalSection(Lock);
  try
    I:=GateFor(Key);Result:='';
    if Gates[I].Rides<>0 then Result:='Finish this rider''s ride before switching accounts.'
    else if Gates[I].Pending<>0 then Result:='Account change in progress. Please wait.';
  finally LeaveCriticalSection(Lock);end;
end;
procedure BeginRideAccount(RiderIndex:Integer);
var I:Integer;Key:String;
begin
  Key:=LocalRider(RiderIndex).Key;
  EnterCriticalSection(Lock);
  try
    I:=GateFor(Key);
    if Gates[I].Pending<>0 then raise EInvalidOperation.Create('Account change in progress. Please wait.');
    LocalRider(RiderIndex).HoldRideIdentity;
    Inc(Gates[I].Rides);
  finally LeaveCriticalSection(Lock);end;
end;
procedure EndRideAccount(RiderIndex:Integer);
var I:Integer;Key:String;
begin
  Key:=LocalRider(RiderIndex).Key;
  EnterCriticalSection(Lock);
  try
    I:=GateFor(Key);
    if Gates[I].Rides>0 then begin
      Dec(Gates[I].Rides);LocalRider(RiderIndex).ReleaseRideIdentity;
    end;
  finally LeaveCriticalSection(Lock);end;
end;
initialization
  InitCriticalSection(Lock);
  { Process-lifetime lock: detached workers may release leases late. }
end.

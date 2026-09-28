unit GameAccountChange;
{$mode objfpc}{$H+}
interface
{ Acquired on the UI thread before starting an auth worker. A detached worker
  keeps the lease until its response has finished mutating the current account. }
function BeginAccountChange:QWord;
procedure EndAccountChange(const Token:QWord);
function AccountChangePending:Boolean;
procedure BeginRideAccount;
procedure EndRideAccount;
implementation
uses SysUtils,Classes;
var Lock:TRTLCriticalSection;Generation,Pending:QWord;Rides:Integer;
function BeginAccountChange:QWord;
begin
  EnterCriticalSection(Lock);
  try
    if Rides<>0 then raise EInvalidOperation.Create('Finish your ride before switching accounts.');
    if Pending<>0 then raise EInvalidOperation.Create('Account change in progress. Please wait.');
    Inc(Generation);if Generation=0 then Inc(Generation);
    Pending:=Generation;Result:=Pending;
  finally LeaveCriticalSection(Lock);end;
end;
procedure EndAccountChange(const Token:QWord);
begin
  EnterCriticalSection(Lock);
  try if(Token<>0)and(Pending=Token)then Pending:=0;finally LeaveCriticalSection(Lock);end;
end;
function AccountChangePending:Boolean;
begin EnterCriticalSection(Lock);try Result:=Pending<>0;finally LeaveCriticalSection(Lock);end;end;
procedure BeginRideAccount;
begin
  EnterCriticalSection(Lock);
  try
    if Pending<>0 then raise EInvalidOperation.Create('Account change in progress. Please wait.');
    Inc(Rides);
  finally LeaveCriticalSection(Lock);end;
end;
procedure EndRideAccount;
begin EnterCriticalSection(Lock);try if Rides>0 then Dec(Rides);finally LeaveCriticalSection(Lock);end;end;
initialization
  InitCriticalSection(Lock);
  { Process-lifetime lock: detached auth workers are joined by the route-task
    owner, whose unit may finalize after this one. Never destroy their gate
    while a final EndAccountChange can still arrive. The OS reclaims it. }
end.

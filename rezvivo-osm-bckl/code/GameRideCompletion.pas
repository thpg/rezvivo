unit GameRideCompletion;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses SysUtils,fpjson;

{ The terminal snapshot is durable before releasing CSV.active. A failed marker
  deletion leaves the original checkpoint usable. A crash after deletion is
  finished from the terminal snapshot when history is read again. }
function ReadCompletedRide(const Path,Account:String):TJSONObject;
procedure CompleteSavedRide(const Path,Account:String);
procedure CancelSavedRideCompletion(const Path,Account:String);

implementation
uses Classes,jsonparser,GameJournalWriter;

function ReadObject(const Path:String):TJSONObject;
var F:TFileStream;D:TJSONData;
begin
  Result:=nil;
  F:=TFileStream.Create(Path,fmOpenRead or fmShareDenyWrite);
  try D:=GetJSON(F);finally F.Free;end;
  if not(D is TJSONObject)then begin D.Free;raise EReadError.Create('Invalid saved ride');end;
  Result:=TJSONObject(D);
end;

procedure Validate(const Path,Account:String;O:TJSONObject);
var Id:String;
begin
  Id:=O.Get('id','');
  if(Id='')or(ExtractFileName(Id)<>Id)or(Pos('..',Id)>0)or
    not SameFileName(ExtractFileName(Path),Id+'.json')or
    (O.Get('account','')<>Account)then
    raise EReadError.Create('Saved ride belongs to a different account');
end;

function ReadCompletedRide(const Path,Account:String):TJSONObject;
var Pending:TJSONObject;Stage,Journal:String;
begin
  Result:=ReadObject(Path);
  try
    Stage:=Path+'.completing';
    if not FileExists(Stage)then Exit;
    Validate(Path,Account,Result);
    { A successfully completed or resumed ride must not be overwritten by a
      leftover staging file. RequestResume removes it before opening the CSV. }
    if Result.Get('complete',False)then begin DeleteFile(Stage);Exit;end;
    Journal:=Result.Get('journal','');
    if(Journal='')or FileExists(Journal+'.active')then Exit;
    Pending:=ReadObject(Stage);
    try
      Validate(Path,Account,Pending);
      if not Pending.Get('complete',False)or(Pending.Get('journal','')<>Journal)then
        raise EReadError.Create('Invalid saved ride completion');
      AtomicSnapshot(Path,Pending.AsJSON);
      Result.Free;Result:=Pending;Pending:=nil;
      DeleteFile(Stage); { Already committed: a leftover is harmless. }
    finally Pending.Free;end;
  except Result.Free;raise;end;
end;

procedure CompleteSavedRide(const Path,Account:String);
var O:TJSONObject;Journal,Stage:String;
begin
  O:=ReadCompletedRide(Path,Account);
  try
    Validate(Path,Account,O);
    if O.Get('complete',False)then Exit; { Repeated click / interrupted commit. }
    Journal:=O.Get('journal','');
    if not(O.Find('resume') is TJSONObject)or(Journal='')or
      not FileExists(Journal)or not FileExists(Journal+'.active')then
      raise EReadError.Create('Saved ride is unavailable');
    Stage:=Path+'.completing';
    O.Booleans['complete']:=True;O.Delete('resume');
    AtomicSnapshot(Stage,O.AsJSON);
    if not DeleteFile(Journal+'.active')then
      raise EWriteError.Create('Could not release saved ride for upload');
    { Once released, never recreate the marker: the upload queue can already
      see the terminal journal. The durable staging snapshot makes this retryable. }
    AtomicSnapshot(Path,O.AsJSON);
    DeleteFile(Stage);
  finally O.Free;end;
end;

procedure CancelSavedRideCompletion(const Path,Account:String);
var O:TJSONObject;Stage:String;
begin
  O:=ReadObject(Path);
  try
    Validate(Path,Account,O);Stage:=Path+'.completing';
    if FileExists(Stage)and not DeleteFile(Stage)then
      raise EWriteError.Create('Could not reopen saved ride; please retry');
  finally O.Free;end;
end;
end.

unit GameRideHistory;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses Classes,SysUtils,fpjson,GameTrainingLoad;
type
  TRideHistory=class
  private
    FCurrent,FLast,FPending:TJSONObject;
    FRestoreNeeded,FAccountHeld:Boolean;
    FLoad:TTrainingLoad;
    FFile:String;
    FElapsed,FDistance,FWork,FPowerSeconds,FHeight,FGain,FLastRawDistance:Double;
    FHeightValid,FLastRawDistanceValid:Boolean;
    FLastSave:QWord;
    procedure Save(Completed:Boolean);
  public
    constructor Create;
    destructor Destroy;override;
    procedure BeginRide(const Title,Route,World:String);
    procedure SetWorkout(const Title,Url:String);
    procedure RebaseDistance(Distance:Double);
    procedure Step(Seconds,Distance,Height,Watts,Ftp:Double;Active,Valid:Boolean);
    procedure Finish;
    function CanResume(Activity:TJSONObject):Boolean;
    procedure RequestResume(Activity:TJSONObject);
    procedure CancelResume;
    function TakeResume:TJSONObject;
    procedure ResumeApplied;
    function CheckpointDue:Boolean;
    procedure Checkpoint(Rider:TJSONObject);
    procedure CompleteSaved(Activity:TJSONObject);
    function AccountChangeError(const HasLiveWorld:Boolean):String;
    function LatestUnfinished:TJSONObject;
    property RestoreNeeded:Boolean read FRestoreNeeded;
    function List:TJSONArray;
    property LastResult:TJSONObject read FLast;
  end;
var RideHistory:TRideHistory;
implementation
uses Math,DateUtils,GameUserData,GameRouteLibraryData,GameSensorLog,DebugLog,
  GameWorkoutPlayer,GameDailyTraining,GameActivityAccounting,GameRideCompletion,GameAccountChange,
  GameRideJournalRecovery;

constructor TRideHistory.Create;
begin inherited;FLoad:=TTrainingLoad.Create;end;
destructor TRideHistory.Destroy;
begin Finish;FPending.Free;FLast.Free;FLoad.Free;inherited;end;

procedure TRideHistory.BeginRide(const Title,Route,World:String);
var Id:String;Resume,Rider:TJSONData;
begin
  Finish;
  BeginRideAccount;FAccountHeld:=True;
  try
  SensorLog.OwnerKey:=UserDataDir;
  { A cancelled load must not apply its checkpoint to a different map/profile. }
  if(FPending<>nil)and(not CanResume(FPending)or
    (FPending.Get('world','')<>World)or
    ((World='')and not SameFileName(FPending.Get('route',''),Route)))then
    CancelResume;
  if FPending<>nil then begin
    FCurrent:=FPending;FPending:=nil;FRestoreNeeded:=True;
    RecoverJournalTail(FCurrent,TSensorLog.LoadSession(FCurrent.Get('journal','')));
    FFile:=UserDataDir+'activities'+PathDelim+FCurrent.Get('id','')+'.json';
    FElapsed:=FCurrent.Get('seconds',0.0);FDistance:=FCurrent.Get('distance_m',0.0);
    FWork:=FCurrent.Get('work_j',0.0);FPowerSeconds:=FCurrent.Get('power_seconds',0.0);
    FGain:=FCurrent.Get('gain_m',0.0);FHeight:=FCurrent.Get('height',0.0);FHeightValid:=False;
    FLastRawDistance:=FCurrent.Get('last_raw_distance',0.0);
    FLastRawDistanceValid:=FCurrent.Get('last_raw_distance_valid',False);
    { Old checkpoints store the route odometer in the rider snapshot. }
    if FCurrent.Find('last_raw_distance_valid')=nil then begin
      Resume:=FCurrent.Find('resume');Rider:=nil;
      if Resume is TJSONObject then Rider:=TJSONObject(Resume).Find('rider');
      if(Rider is TJSONObject)and(TJSONObject(Rider).Find('distance')<>nil)then begin
        FLastRawDistance:=TJSONObject(Rider).Get('distance',0.0);
        FLastRawDistanceValid:=True;
      end;
    end;
    FLastRawDistanceValid:=FLastRawDistanceValid and not IsNan(FLastRawDistance) and
      not IsInfinite(FLastRawDistance) and(FLastRawDistance>=0);
    if FCurrent.Find('load') is TJSONObject then FLoad.RestoreState(FCurrent.Objects['load']);
    SensorLog.Resume(FCurrent.Get('journal',''),FCurrent.Get('journal_elapsed',0.0));
    FLastSave:=GetTickCount64;Exit;
  end;
  Id:=FormatDateTime('yyyymmdd-hhnnss-zzz',Now);
  FFile:=UserDataDir+'activities'+PathDelim+Id+'.json';
  FCurrent:=TJSONObject.Create(['id',Id,'title',Title,'route',Route,'world',World,
    'date',FormatDateTime('yyyy-mm-dd hh:nn',Now),'complete',False,'account',UserDataDir]);
  FElapsed:=0;FDistance:=0;FWork:=0;FPowerSeconds:=0;FGain:=0;
  FHeightValid:=False;FLastRawDistance:=0;FLastRawDistanceValid:=False;
  FLoad.Reset;FLastSave:=GetTickCount64;
  except
    EndRideAccount;FAccountHeld:=False;raise;
  end;
end;

procedure TRideHistory.SetWorkout(const Title,Url:String);
begin
  if FCurrent=nil then Exit;
  FCurrent.Strings['workout']:=Title;FCurrent.Strings['workout_url']:=Url;
end;

procedure TRideHistory.RebaseDistance(Distance:Double);
begin
  if(FCurrent=nil)or FRestoreNeeded then Exit;
  ActiveDistanceDelta(Distance,False,FLastRawDistance,FLastRawDistanceValid);
end;

procedure TRideHistory.Step(Seconds,Distance,Height,Watts,Ftp:Double;Active,Valid:Boolean);
var Counting:Boolean;
begin
  if(FCurrent=nil)or FRestoreNeeded then Exit;
  Counting:=Active and(Seconds>0)and not IsNan(Seconds)and not IsInfinite(Seconds);
  FDistance:=FDistance+ActiveDistanceDelta(Distance,Counting,FLastRawDistance,FLastRawDistanceValid);
  if not Counting then begin
    FHeightValid:=False;
    FLoad.Step(Watts,Seconds,Ftp,Active,Valid);
    Exit;
  end;
  FElapsed:=FElapsed+Seconds;
  if not IsNan(Height)and not IsInfinite(Height)then begin
    if FHeightValid then begin
      if Height>FHeight+1 then begin FGain:=FGain+Height-FHeight;FHeight:=Height;end
      else if Height<FHeight-1 then FHeight:=Height;
    end else begin FHeight:=Height;FHeightValid:=True;end;
  end;
  Valid:=Valid and not IsNan(Watts)and not IsInfinite(Watts);
  if Valid then begin FWork:=FWork+Max(0,Watts)*Seconds;FPowerSeconds:=FPowerSeconds+Seconds;end;
  FLoad.Step(Watts,Seconds,Ftp,True,Valid);
  FCurrent.Booleans['has_ftp']:=Ftp>0;
end;

procedure TRideHistory.Save(Completed:Boolean);
begin
  if FCurrent=nil then Exit;
  FCurrent.Booleans['complete']:=Completed;
  FCurrent.Floats['seconds']:=FElapsed;FCurrent.Floats['distance_m']:=FDistance;
  FCurrent.Floats['gain_m']:=FGain;FCurrent.Floats['work_j']:=FWork;
  FCurrent.Floats['tss']:=FLoad.TSS;FCurrent.Booleans['has_power']:=FPowerSeconds>0;
  FCurrent.Floats['power_seconds']:=FPowerSeconds;FCurrent.Floats['height']:=FHeight;
  FCurrent.Floats['last_raw_distance']:=FLastRawDistance;
  FCurrent.Booleans['last_raw_distance_valid']:=FLastRawDistanceValid;
  if FPowerSeconds>0 then FCurrent.Floats['avg_power']:=FWork/FPowerSeconds;
  if SensorLog.IsOpen then begin
    FCurrent.Strings['journal']:=SensorLog.FileName;
    FCurrent.Floats['journal_elapsed']:=SensorLog.JournalElapsed;
  end;
  FCurrent.Delete('save_error');
  try
    if SensorLog.IsOpen then SensorLog.SaveCheckpoint(FFile,FCurrent.AsJSON)
    else WriteAccountJSON(FFile,FCurrent);
  except on E:Exception do begin
    FCurrent.Strings['save_error']:=E.Message;Logger.Warning('[RideHistory] '+E.Message);
  end;end;
  FLastSave:=GetTickCount64;
end;

procedure TRideHistory.Finish;
begin
  try
  if FCurrent=nil then Exit;
  if FRestoreNeeded then begin
    FRestoreNeeded:=False;FreeAndNil(FCurrent);SensorLog.Close(False);Exit;
  end;
  FRestoreNeeded:=False;FCurrent.Delete('resume');
  if FElapsed>0.1 then begin
    Save(True);FreeAndNil(FLast);FLast:=FCurrent;FCurrent:=nil;
  end else FreeAndNil(FCurrent);
  finally
    if FAccountHeld then begin EndRideAccount;FAccountHeld:=False;end;
  end;
end;

function TRideHistory.CanResume(Activity:TJSONObject):Boolean;
var Id:String;
begin
  Result:=False;if Activity=nil then Exit;Id:=Activity.Get('id','');
  if(Id='')or(ExtractFileName(Id)<>Id)or(Pos('..',Id)>0)then Exit;
  Result:=not Activity.Get('complete',False)and(Activity.Get('account','')=UserDataDir)
    and(Activity.Find('resume') is TJSONObject)and
    FileExists(Activity.Get('journal',''))and FileExists(Activity.Get('journal','')+'.active');
end;
procedure TRideHistory.RequestResume(Activity:TJSONObject);
begin
  if not CanResume(Activity)then raise Exception.Create('Saved ride is unavailable');
  CancelSavedRideCompletion(UserDataDir+'activities'+PathDelim+Activity.Get('id','')+'.json',UserDataDir);
  FreeAndNil(FPending);FPending:=Activity.Clone as TJSONObject;
end;
procedure TRideHistory.CancelResume;
begin FreeAndNil(FPending);end;
function TRideHistory.TakeResume:TJSONObject;
begin
  Result:=nil;if not FRestoreNeeded or(FCurrent=nil)then Exit;
  if FCurrent.Find('resume') is TJSONObject then Result:=FCurrent.Objects['resume'].Clone as TJSONObject;
end;
procedure TRideHistory.ResumeApplied;
begin FRestoreNeeded:=False;end;
function TRideHistory.CheckpointDue:Boolean;
begin Result:=(FCurrent<>nil)and not FRestoreNeeded and(GetTickCount64-FLastSave>=1000);end;
procedure TRideHistory.Checkpoint(Rider:TJSONObject);
var O:TJSONObject;
begin
  if FCurrent=nil then begin Rider.Free;Exit;end;
  O:=TJSONObject.Create(['version',1]);O.Add('rider',Rider);
  O.Add('workout',WorkoutPlayer.SaveState);O.Add('daily',DailyTraining.SaveState);
  FCurrent.Delete('resume');FCurrent.Add('resume',O);
  FCurrent.Delete('load');FCurrent.Add('load',FLoad.SaveState);
  { Open the journal before serializing its name, including waiting starts. }
  SensorLog.SaveCheckpoint('','');Save(False);
end;
procedure TRideHistory.CompleteSaved(Activity:TJSONObject);
var Path,Id:String;
begin
  if Activity=nil then Exit;
  Id:=Activity.Get('id','');
  if(Id='')or(ExtractFileName(Id)<>Id)or(Pos('..',Id)>0)or
    (Activity.Get('account','')<>UserDataDir)then
    raise Exception.Create('Saved ride belongs to a different account');
  if(FCurrent<>nil)and(FCurrent.Get('id','')=Id)then
    raise Exception.Create('Finish the current ride before completing its recording');
  Path:=UserDataDir+'activities'+PathDelim+Id+'.json';
  CompleteSavedRide(Path,UserDataDir);
end;

function TRideHistory.AccountChangeError(const HasLiveWorld:Boolean):String;
begin
  Result:='';
  if AccountChangePending then Exit('Account change in progress. Please wait.');
  if HasLiveWorld or(FCurrent<>nil)or SensorLog.IsOpen then
    Exit('Finish your ride before switching accounts.');
  if(SensorLog.ErrorText<>'')or((FLast<>nil)and(FLast.Get('save_error','')<>''))then
    Result:='The last ride could not be saved. Restart the app to recover it before switching accounts.';
end;
function TRideHistory.LatestUnfinished:TJSONObject;
var A:TJSONArray;I:Integer;
begin
  Result:=nil;A:=List;
  try for I:=0 to A.Count-1 do if CanResume(A.Objects[I])then begin Result:=A.Objects[I].Clone as TJSONObject;Break;end;
  finally A.Free;end;
end;

function TRideHistory.List:TJSONArray;
var Files:TStringList;Search:TSearchRec;Dir:String;I:Integer;O:TJSONObject;
begin
  Result:=TJSONArray.Create;Dir:=UserDataDir+'activities'+PathDelim;
  Files:=TStringList.Create;
  try
    if FindFirst(Dir+'*.json',faAnyFile,Search)=0 then begin
      repeat if(Search.Attr and faDirectory)=0 then Files.Add(Search.Name);until FindNext(Search)<>0;
      FindClose(Search);
    end;
    Files.Sort;
    for I:=Files.Count-1 downto Max(0,Files.Count-200)do begin
      try O:=ReadCompletedRide(Dir+Files[I],UserDataDir);if O<>nil then Result.Add(O);
      except on E:Exception do Logger.Warning('[RideHistory] '+E.Message);end;
    end;
  finally Files.Free;end;
end;

initialization
  RideHistory:=TRideHistory.Create;
finalization
  FreeAndNil(RideHistory);
end.

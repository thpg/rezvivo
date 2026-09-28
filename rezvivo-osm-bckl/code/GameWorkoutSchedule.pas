unit GameWorkoutSchedule;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses Classes, SysUtils, fpjson, GameRouteLibraryData, WorkoutFile;
type
  TWorkoutSchedule=class
  private
    FUserId:Int64;
    FCalendar,FCompleted:TJSONObject;
    FTask:TRouteTask;
    FRevision,FNextSync,FLastPoll:QWord;
    FDay,FError:String;
    procedure Save;
    procedure LoadAccount;
    procedure Finished(Sender:TObject);
    procedure Pump(Sender:TObject);
    function GetItems:TJSONArray;
    function GetConnected:Boolean;
    function GetBusy:Boolean;
    function GetStatus:String;
  public
    constructor Create;
    destructor Destroy;override;
    procedure Tick;
    procedure Refresh;
    procedure ConnectionChanged;
    function EventKey(E:TJSONObject):String;
    function Completed(E:TJSONObject):Boolean;
    function Today:TJSONObject;
    function Find(const Key:String):TJSONObject;
    function LoadWorkout(E:TJSONObject):TWorkoutFile;
    property Items:TJSONArray read GetItems;
    property UserId:Int64 read FUserId;
    property Revision:QWord read FRevision;
    property Connected:Boolean read GetConnected;
    property Busy:Boolean read GetBusy;
    property Status:String read GetStatus;
  end;
function WorkoutSchedule:TWorkoutSchedule;
function ScheduleDay(Value:TDateTime):String;
implementation
uses DateUtils, jsonparser, md5, CastleApplicationProperties, CastleURIUtils,
  VeloSiteAPI, GameWorkoutPlayer, UiTranslations
  {$ifdef MSWINDOWS},Windows{$endif};
var Instance:TWorkoutSchedule;

function ScheduleDay(Value:TDateTime):String;
begin Result:=FormatDateTime('yyyy-mm-dd',Value);end;
function WorkoutSchedule:TWorkoutSchedule;
begin if Instance=nil then Instance:=TWorkoutSchedule.Create;Result:=Instance;end;
constructor TWorkoutSchedule.Create;
begin
  inherited;FUserId:=-1;
  ApplicationProperties.OnUpdate.Add(@Pump);
  WorkoutPlayer.OnFinished:=@Finished;
  Tick;
end;
destructor TWorkoutSchedule.Destroy;
begin
  ApplicationProperties.OnUpdate.Remove(@Pump);
  WorkoutPlayer.OnFinished:=nil;
  RouteDetach(FTask);FCalendar.Free;FCompleted.Free;inherited;
end;
procedure TWorkoutSchedule.Pump(Sender:TObject);
begin
  if GetTickCount64-FLastPoll<500 then Exit;
  FLastPoll:=GetTickCount64;Tick;
end;
function TWorkoutSchedule.GetItems:TJSONArray;
var D:TJSONData;
begin
  Result:=nil;if FCalendar=nil then Exit;
  D:=FCalendar.Find('items');if D is TJSONArray then Result:=TJSONArray(D);
end;
function TWorkoutSchedule.GetConnected:Boolean;
begin Result:=(FCalendar<>nil)and FCalendar.Get('connected',False);end;
function TWorkoutSchedule.GetBusy:Boolean;
begin Result:=FTask<>nil;end;
function TWorkoutSchedule.GetStatus:String;
begin
  if FUserId<=0 then Exit(UiText('Sign in and connect Intervals.icu to see your training schedule.'));
  if Busy then Exit(UiText('Syncing training schedule…'));
  if FError<>'' then Exit(UiText(FError));
  if not Connected then Exit(UiText('Connect Intervals.icu to sync your planned cycling workouts.'));
  if FCalendar.Get('status','')='calendar_permission' then
    Exit(UiText('Reconnect Intervals.icu with calendar read access.'));
  Result:=UiText('Synced from Intervals.icu')+' · '+FCalendar.Get('local_synced','');
end;
procedure TWorkoutSchedule.Save;
var C:TJSONObject;
begin
  if(FUserId<=0)or(FCalendar=nil)then Exit;
  C:=FCalendar.Clone as TJSONObject;
  try
    C.Add('user_id',FUserId);
    WriteAccountJSON(RouteAccountDir(FUserId)+'training-schedule.json',C);
  finally C.Free;end;
end;
procedure TWorkoutSchedule.LoadAccount;
var C:TJSONObject;
begin
  FreeAndNil(FCalendar);FreeAndNil(FCompleted);
  FError:='';FCompleted:=TJSONObject.Create;
  if FUserId<=0 then Exit;
  try
    C:=nil;
    if FileExists(RouteAccountDir(FUserId)+'training-schedule.json')then
      C:=ReadAccountJSON(RouteAccountDir(FUserId)+'training-schedule.json');
    if C<>nil then begin
      if(C.Get('user_id',Int64(0))=FUserId)and(C.Find('items') is TJSONArray)then begin
        C.Delete('user_id');FCalendar:=C;
      end else C.Free;
    end;
    C:=nil;
    if FileExists(RouteAccountDir(FUserId)+'training-schedule-completed.json')then
      C:=ReadAccountJSON(RouteAccountDir(FUserId)+'training-schedule-completed.json');
    if C<>nil then begin FCompleted.Free;FCompleted:=C;end;
  except
    FreeAndNil(FCalendar);FError:='Could not read the saved schedule. Sync to try again.';
  end;
end;
procedure TWorkoutSchedule.Tick;
var Id:Int64;Day:String;D:TJSONData;O:TJSONObject;
begin
  Id:=0;if VeloSite.IsAuthorized then Id:=VeloSite.CachedProfile.Id;
  Day:=ScheduleDay(Date);
  if(Id<>FUserId)or(Day<>FDay)then begin
    RouteDetach(FTask);
    if Id<>FUserId then begin FUserId:=Id;LoadAccount;end;
    FDay:=Day;FNextSync:=0;Inc(FRevision);
  end;
  if(FTask<>nil)and FTask.Done then begin
    try
      D:=FTask.Response;
      if(FTask.ErrorText<>'')or not(D is TJSONObject)or
        not(TJSONObject(D).Find('items') is TJSONArray)then
      begin
        FError:='Could not sync. Showing the saved schedule; check your connection and retry.';
        FNextSync:=GetTickCount64+300000;
      end else begin
        O:=D.Clone as TJSONObject;
        O.Add('local_synced',FormatDateTime('dd.mm.yyyy hh:nn',Now));
        FCalendar.Free;FCalendar:=O;FError:='';
        try Save;except FError:='Schedule loaded, but could not save it for offline use.';end;
        FNextSync:=GetTickCount64+900000;
      end;
    finally FreeAndNil(FTask);Inc(FRevision);end;
  end;
  if(FUserId>0)and(FTask=nil)and(GetTickCount64>=FNextSync)then Refresh;
end;
procedure TWorkoutSchedule.Refresh;
begin
  if(FTask<>nil)or(FUserId<=0)then Exit;
  FTask:=TRouteTask.Create(FUserId,'GET','/training-schedule?oldest='+
    ScheduleDay(Date-7)+'&newest='+ScheduleDay(Date+34),'');
  FTask.RequestTimeoutMS:=25000;FTask.Start;
  FNextSync:=GetTickCount64+900000;Inc(FRevision);
end;
procedure TWorkoutSchedule.ConnectionChanged;
begin
  RouteDetach(FTask);FreeAndNil(FCalendar);FError:='';
  if FUserId>0 then begin
    FCalendar:=TJSONObject.Create(['connected',False,'status','not_connected']);
    FCalendar.Add('items',TJSONArray.Create);
    try Save;except end;
  end;
  FNextSync:=0;Inc(FRevision);Tick;
end;
function TWorkoutSchedule.EventKey(E:TJSONObject):String;
begin
  Result:='';if(E=nil)or(FCalendar=nil)then Exit;
  Result:=FCalendar.Get('athlete','')+':'+IntToStr(E.Get('id',Int64(0)))+':'+E.Get('date','');
end;
function TWorkoutSchedule.Completed(E:TJSONObject):Boolean;
begin Result:=(E<>nil)and(E.Get('completed',False)or(FCompleted.Find(EventKey(E))<>nil));end;
function TWorkoutSchedule.Today:TJSONObject;
var A:TJSONArray;I:Integer;E:TJSONObject;
begin
  Result:=nil;if not Connected then Exit;A:=Items;if A=nil then Exit;
  for I:=0 to A.Count-1 do if A.Items[I] is TJSONObject then begin
    E:=A.Objects[I];
    if(E.Get('date','')=ScheduleDay(Date))and not Completed(E)and(E.Get('zwo','')<>'')then Exit(E);
  end;
end;
function TWorkoutSchedule.Find(const Key:String):TJSONObject;
var A:TJSONArray;I:Integer;
begin
  Result:=nil;A:=Items;if A=nil then Exit;
  for I:=0 to A.Count-1 do if(A.Items[I] is TJSONObject)and(EventKey(A.Objects[I])=Key)then Exit(A.Objects[I]);
end;
function TWorkoutSchedule.LoadWorkout(E:TJSONObject):TWorkoutFile;
var P,Z:String;S:TFileStream;I:Integer;
begin
  Result:=nil;if(E=nil)or(E.Get('zwo','')='')or(FUserId<=0)then Exit;
  Z:=E.Get('zwo','');if Length(Z)>128*1024 then Exit;
  P:=RouteAccountDir(FUserId)+'scheduled-workouts'+PathDelim+MD5Print(MD5String(EventKey(E)))+'.zwo';
  ForceDirectories(ExtractFileDir(P));
  S:=TFileStream.Create(P+'.tmp',fmCreate);
  try S.WriteBuffer(Z[1],Length(Z));finally S.Free;end;
  {$ifdef MSWINDOWS}
  if not MoveFileExW(PWideChar(UTF8Decode(P+'.tmp')),PWideChar(UTF8Decode(P)),MOVEFILE_REPLACE_EXISTING or $8)then
  {$else}
  if not RenameFile(P+'.tmp',P)then
  {$endif}
    raise Exception.Create(UiText('Could not save the workout'));
  Result:=TWorkoutFile.Create;
  try
    if not Result.LoadFromUrl(FilenameToURISafe(P))or(Result.Segments.Count=0)or(Result.TotalDuration<=0)then begin FreeAndNil(Result);Exit;end;
    for I:=0 to Result.Segments.Count-1 do
      if not(Result.Segments[I].Duration>0)then begin FreeAndNil(Result);Exit;end;
    Result.ScheduleUserId:=FUserId;Result.ScheduleKey:=EventKey(E);
  except FreeAndNil(Result);raise;end;
end;
procedure TWorkoutSchedule.Finished(Sender:TObject);
var P:TWorkoutFile;Key:String;
begin
  P:=WorkoutPlayer.Plan;
  if(P=nil)or(WorkoutPlayer.Elapsed<=0)or(P.ScheduleKey='')or
    (P.ScheduleUserId<>FUserId)or(FUserId<=0)or not VeloSite.IsAuthorized or
    (VeloSite.CachedProfile.Id<>FUserId)then Exit;
  Key:=P.ScheduleKey;
  if FCompleted.Find(Key)<>nil then Exit;
  FCompleted.Add(Key,ScheduleDay(Date));Inc(FRevision);
  // Keep a bounded local completion journal; provider pairing is authoritative.
  while FCompleted.Count>512 do FCompleted.Delete(0);
  try WriteAccountJSON(RouteAccountDir(FUserId)+'training-schedule-completed.json',FCompleted);
  except FError:='Could not save workout completion on this computer.';end;
end;
finalization
  FreeAndNil(Instance);
end.

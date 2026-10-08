unit GameAssistantMcp;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses fpjson;
procedure RegisterAssistantMcpTools;
procedure StopAssistantMcp;
function AssistantLiveStatus:TJSONObject;
procedure SyncAssistantContext(Force:Boolean=False);
implementation
uses Classes,SysUtils,Math,MD5,McpRegistry,GameAssistant,GameAssistantVoice,GameWorkoutPlayer,
  GameDeviceService,GameDeviceSensor,GameRideCommands,WorkoutFile,WorkoutLibrary,
  GameViewPlay,GameViewTrainingOnly,GameViewMenu,GameUserData,GameAccountChange;
type
  TAssistantObserver=class
    procedure WorkoutChanged(Sender:TObject);
  end;
var Observer:TAssistantObserver;NextContextCheck:QWord;

procedure SyncAssistantContext(Force:Boolean);
var NowMs:QWord;Key:string;
begin
  NowMs:=GetTickCount64;
  if not Force and (NowMs<NextContextCheck) then Exit;
  NextContextCheck:=NowMs+500;
  { UserDataDir computes the current account namespace from cached identity;
    no preferences, files or network requests are read. During an auth worker
    discard the old conversation before any new identity becomes observable. }
  if AccountChangePending then Key:='' else Key:=UserDataDir;
  if Assistant.BindContext(Key) then EndAssistantVoiceSession;
end;

function WorkoutStatus:TJSONObject;
const States:array[TWorkoutState]of string=('idle','ready','running','paused','finished');
  Kinds:array[TWorkoutSegmentKind]of string=('warmup','cooldown','ramp','steady','interval','freeride');
var N:Integer;Name,Kind:string;
begin
  N:=0;Name:='';Kind:='';
  if WorkoutPlayer.Plan<>nil then begin N:=WorkoutPlayer.Plan.Segments.Count;Name:=WorkoutPlayer.Plan.Name end;
  if WorkoutPlayer.Stage<>nil then Kind:=Kinds[WorkoutPlayer.Stage.Kind];
  Result:=TJSONObject.Create(['state',States[WorkoutPlayer.State],'name',Name,
    'index',WorkoutPlayer.Index,'number',Min(N,WorkoutPlayer.Index+1),'count',N,'kind',Kind,
    'elapsed_s',WorkoutPlayer.Elapsed,'stage_elapsed_s',WorkoutPlayer.StageTime,
    'remaining_s',WorkoutPlayer.StageRemaining,'target_watts',WorkoutPlayer.TargetWatts,
    'reference_watts',WorkoutPlayer.ReferenceWatts,'intensity',WorkoutPlayer.Intensity,
    'auto_paused',WorkoutPlayer.AutoPaused,'signal_lost',WorkoutPlayer.SignalLost]);
end;
function SensorStatus(S:TDeviceSensor):TJSONObject;
var Fresh:Boolean;Age:Double;
begin
  Fresh:=False;Age:=0;
  if (S<>nil) and S.HasData then begin Age:=S.DataAgeSec;Fresh:=Age<3 end;
  Result:=TJSONObject.Create(['fresh',Fresh]);
  if (S<>nil) and S.HasData and not IsNan(Age) and not IsInfinite(Age) then Result.Add('age_s',Max(0,Age))
  else Result.Add('age_s',TJSONNull.Create);
  if Fresh and not IsNan(S.Instant) and not IsInfinite(S.Instant) then Result.Add('value',S.Instant)
  else Result.Add('value',TJSONNull.Create);
end;
function AssistantLiveStatus:TJSONObject;
var Sensors:TJSONObject;
begin
  Result:=TJSONObject.Create(['sample_ms',Int64(GetTickCount64),
    'ride_alive',(ViewPlay<>nil) and ViewPlay.SessionAlive,
    'training_only_alive',(ViewTrainingOnly<>nil) and ViewTrainingOnly.SessionAlive,
    'workout',WorkoutStatus]);
  Sensors:=TJSONObject.Create;Result.Add('sensors',Sensors);
  if DeviceService<>nil then begin
    Sensors.Add('power',SensorStatus(DeviceService.Power));Sensors.Add('heart',SensorStatus(DeviceService.HR));
    Sensors.Add('cadence',SensorStatus(DeviceService.Cadence));Sensors.Add('speed',SensorStatus(DeviceService.Speed));
  end;
end;
procedure TAssistantObserver.WorkoutChanged(Sender:TObject);
begin
  if Assistant.Connected then Assistant.AddEvent('workout',WorkoutStatus);
end;
procedure CopyObject(Source,Target:TJSONObject);
var I:Integer;
begin try for I:=0 to Source.Count-1 do Target.Add(Source.Names[I],Source.Items[I].Clone) finally Source.Free end end;
function Token(P:TJSONObject):string;
begin SyncAssistantContext(True);Result:=P.Get('session','');Assistant.RequireSession(Result) end;
procedure CmdRegister(const P:TJSONObject;R:TJSONObject);
var S:string;WasConnected:Boolean;
begin
  SyncAssistantContext(True);
  if AccountChangePending then raise EAssistantError.Create('assistant_not_connected');
  WasConnected:=Assistant.Connected;
  S:=Assistant.RegisterAgent(P.Get('name',''),P.Get('session',''));
  if not WasConnected then try AssistantVoice.SessionStarted except end;
  R.Add('session',S);R.Add('name',Assistant.AgentName);R.Add('state',AssistantLiveStatus);
  R.Add('instructions','Poll assistant.receive every 1 second while observing. Keep message and event cursors. Reading is retryable; acknowledge explicitly, or reply with in_reply_to to acknowledge that one question. Use only actions requested by the user. No LLM or microphone is started by REZVIVO.');
end;
procedure CmdReceive(const P:TJSONObject;R:TJSONObject);
var S:string;Events:TJSONObject;
begin
  S:=Token(P);Events:=Assistant.EventsAfter(P.Get('event_after',Int64(0)));
  try
    { Validate the event cursor before a message ACK mutates the queue. }
    CopyObject(Assistant.Receive(S,P.Get('after_id',Int64(0)),P.Get('ack_through',Int64(0)),P.Get('limit',16)),R);
    R.Add('events',Events);Events:=nil;R.Add('state',AssistantLiveStatus);
  finally Events.Free end;
end;
procedure CmdReply(const P:TJSONObject;R:TJSONObject);
var Id:Int64;
begin
  Id:=Assistant.Reply(Token(P),P.Get('text',''),P.Get('in_reply_to',Int64(0)),P.Get('client_message_id',''));
  R.Add('message_id',Id);
  { Optional speech failure cannot turn a successfully delivered chat reply
    into an error or cause it to be retried as a new message. }
  try AssistantVoice.ReplyAdded(Id,P.Get('text','')) except end;
end;
procedure CmdStatus(const P:TJSONObject;R:TJSONObject);
begin Token(P);R.Add('state',AssistantLiveStatus);R.Add('chat',Assistant.Snapshot);end;
procedure CmdDisconnect(const P:TJSONObject;R:TJSONObject);
begin Token(P);Assistant.Disconnect;EndAssistantVoiceSession;R.Add('ok',True) end;
procedure Invoke(const Name:string;P,R:TJSONObject);
var Command:TMcpCommand;
begin
  Command:=FindMcpCommand(Name);
  if Command=nil then raise EAssistantError.Create('assistant_command_unavailable');
  Command.Handler(P,R);
end;
procedure CmdControl(const P:TJSONObject;R:TJSONObject);
var Action,S:string;Args:TJSONObject;
begin
  Token(P);Action:=P.Get('action','');Args:=TJSONObject.Create;
  try
    if Action='menu' then begin Args.Add('view','menu');Invoke('app.switch_view',Args,R) end
    else if Action='open_page' then begin
      S:=P.Get('page','');
      if Pos('|'+S+'|','|menu|devices|training|schedule|routes|dream|bikefit|settings|profile|')=0 then raise EAssistantError.Create('assistant_unknown_page');
      Args.Add('view',S);Invoke('app.switch_view',Args,R);
    end
    else if Action='ride_start' then Invoke('ride.start',Args,R)
    else if Action='ride_stop' then Invoke('ride.stop',Args,R)
    else if Action='ride_finish' then Invoke('ride.stop_full',Args,R)
    else begin
      if (WorkoutPlayer.State=wsIdle) or
        ((WorkoutPlayer.State=wsFinished) and not((Action='workout_restart') or (Action='workout_stop'))) then
        raise EAssistantError.Create('assistant_no_active_workout');
      if Action='workout_pause' then WorkoutPlayer.Pause
      else if Action='workout_resume' then WorkoutPlayer.Resume
      else if Action='workout_skip' then ExecuteRideCommand(rcSkip)
      else if Action='workout_restart' then WorkoutPlayer.Restart
      else if Action='workout_stop' then WorkoutPlayer.Stop
      else if Action='power_up' then ExecuteRideCommand(rcPowerUp)
      else if Action='power_down' then ExecuteRideCommand(rcPowerDown)
      else raise EAssistantError.Create('assistant_unknown_action');
      R.Add('ok',True);
    end;
  finally Args.Free end;
  R.Add('state',AssistantLiveStatus);
end;
function WorkoutId(W:TWorkoutFile):string;
begin Result:=MD5Print(MD5String(W.Url)) end;
procedure AddWorkout(A:TJSONArray;W:TWorkoutFile;const Category,Source:string);
begin
  A.Add(TJSONObject.Create(['id',WorkoutId(W),'name',W.Name,'category',Category,
    'source',Source,'duration_s',W.TotalDuration,'intervals',W.Segments.Count]));
end;
procedure CmdWorkouts(const P:TJSONObject;R:TJSONObject);
var A:TJSONArray;I,J:Integer;W:TWorkoutFile;Local:TWorkoutFileList;
begin
  Token(P);A:=TJSONArray.Create;R.Add('workouts',A);
  Local:=TWorkoutFileList.Create(True);
  try
    LoadLocalWorkoutFiles(UserDataDir+'workouts',Local);
    for I:=0 to Local.Count-1 do AddWorkout(A,Local[I],'','user');
  finally Local.Free end;
  if WorkoutLib<>nil then for I:=0 to WorkoutLib.Categories.Count-1 do for J:=0 to WorkoutLib.Categories[I].Workouts.Count-1 do begin
    W:=WorkoutLib.Categories[I].Workouts[J];
    AddWorkout(A,W,WorkoutLib.Categories[I].Name,'bundled');
  end;
  R.Add('bundled_loaded',WorkoutLib<>nil);
end;
procedure CmdStartWorkout(const P:TJSONObject;R:TJSONObject);
var I,J:Integer;W:TWorkoutFile;Reference:Double;Args,Unused:TJSONObject;Local:TWorkoutFileList;
begin
  Token(P);W:=nil;Local:=TWorkoutFileList.Create(True);
  try
    if WorkoutLib<>nil then for I:=0 to WorkoutLib.Categories.Count-1 do
      for J:=0 to WorkoutLib.Categories[I].Workouts.Count-1 do
        if WorkoutId(WorkoutLib.Categories[I].Workouts[J])=P.Get('id','') then W:=WorkoutLib.Categories[I].Workouts[J];
    if W=nil then begin
      LoadLocalWorkoutFiles(UserDataDir+'workouts',Local);
      for I:=0 to Local.Count-1 do if WorkoutId(Local[I])=P.Get('id','') then W:=Local[I];
    end;
    if W=nil then raise EAssistantError.Create('assistant_workout_not_found');
    Reference:=P.Get('reference_watts',Double(EffectiveRiderProfile.FtpW));
    if IsNan(Reference) or IsInfinite(Reference) or (Reference<0) or (Reference>1000) then raise EAssistantError.Create('assistant_invalid_reference');
    Args:=TJSONObject.Create(['view','menu']);Unused:=TJSONObject.Create;
    try Invoke('app.switch_view',Args,Unused) finally Unused.Free;Args.Free end;
    { StartWorkout clones the plan before returning, including device prompts. }
    ViewMenu.StartWorkout(W,Reference,P.Get('training_only',False));
    R.Add('requested',True);R.Add('state',AssistantLiveStatus);
  finally Local.Free end;
end;
procedure RegisterAssistantMcpTools;
const SessionProperty='"session":{"type":"string"}';
begin
  if Observer=nil then begin Observer:=TAssistantObserver.Create;WorkoutPlayer.AddStateObserver(@Observer.WorkoutChanged) end;
  RegisterMcpCommand('assistant.register','Register the agent name shown in the game Assistant window. Available over stdio or explicitly enabled same-user local attach. Workflow: register(name) -> receive(session) -> reply(session,text,in_reply_to); status/control/workouts use the same session. Re-registration while connected requires its token.',
    '{"type":"object","properties":{"name":{"type":"string","maxLength":80},'+SessionProperty+'},"required":["name"]}',@CmdRegister);
  RegisterMcpCommand('assistant.receive','Read queued user messages and workout transition events, plus current interval/sensors. Nonblocking; poll around once per second. Cursors are retryable; ack_through explicitly acknowledges delivered messages. Reply acknowledges only its referenced message. events.truncated signals event-ring overrun.',
    '{"type":"object","properties":{'+SessionProperty+',"after_id":{"type":"integer","minimum":0},"ack_through":{"type":"integer","minimum":0},"event_after":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":32}},"required":["session"]}',@CmdReceive);
  RegisterMcpCommand('assistant.reply','Display plain text in the game Assistant window. Optional client_message_id makes retries idempotent; in_reply_to acknowledges one delivered user message.',
    '{"type":"object","properties":{'+SessionProperty+',"text":{"type":"string","maxLength":4096},"in_reply_to":{"type":"integer","minimum":0},"client_message_id":{"type":"string","maxLength":80}},"required":["session","text"]}',@CmdReply);
  RegisterMcpCommand('assistant.status','Current ride/workout/interval/sensor snapshot and bounded chat history. Reads existing controllers; no simulation or trainer writes.',
    '{"type":"object","properties":{'+SessionProperty+'},"required":["session"]}',@CmdStatus);
  RegisterMcpCommand('assistant.disconnect','Revoke this agent session. Pending user questions remain available after reconnection.',
    '{"type":"object","properties":{'+SessionProperty+'},"required":["session"]}',@CmdDisconnect);
  RegisterMcpCommand('assistant.control','Carry out a user-requested application, ride or workout action through the existing game controllers. Power buttons change workout reference by 5 W. Does not set trainer resistance directly.',
    '{"type":"object","properties":{'+SessionProperty+',"action":{"type":"string","enum":["menu","open_page","ride_start","ride_stop","ride_finish","workout_pause","workout_resume","workout_skip","workout_restart","workout_stop","power_up","power_down"]},"page":{"type":"string"}},"required":["session","action"]}',@CmdControl);
  RegisterMcpCommand('assistant.workouts','List bundled and current-user workouts with stable IDs. Explicitly reads local user ZWO files through the Training page loader; never scans during receive/status. File paths and account IDs are not exposed.',
    '{"type":"object","properties":{'+SessionProperty+'},"required":["session"]}',@CmdWorkouts);
  RegisterMcpCommand('assistant.start_workout','Start a listed workout via the same Training-page flow, in the current ride or training-only window. reference_watts defaults to profile FTP; 0 is timed mode. Existing device prompts remain applicable.',
    '{"type":"object","properties":{'+SessionProperty+',"id":{"type":"string"},"reference_watts":{"type":"number","minimum":0,"maximum":1000},"training_only":{"type":"boolean"}},"required":["session","id"]}',@CmdStartWorkout);
end;
procedure StopAssistantMcp;
begin
  Assistant.SetTransportAvailable(False);
  EndAssistantVoiceSession;
  if Observer<>nil then begin WorkoutPlayer.RemoveStateObserver(@Observer.WorkoutChanged);FreeAndNil(Observer) end;
end;
finalization
  if Observer<>nil then begin WorkoutPlayer.RemoveStateObserver(@Observer.WorkoutChanged);Observer.Free end;
end.

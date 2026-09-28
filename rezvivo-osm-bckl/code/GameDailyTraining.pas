unit GameDailyTraining;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses Classes,SysUtils,GameTrainingLoad,GameRouteLibraryData,fpjson;
type
  TDailyTraining = class
  private
    type TDay = record
      Day:Integer;
      Source:String;
      Revision,Ack:Int64;
      Work,TSS,OtherWork,OtherTSS:Double;
    end;
    var FDays:array of TDay;
      FUserId:Int64;
      FAccountDir:String;
      FIndex,FTaskIndex:Integer;
      FBound,FDirty,FInRide:Boolean;
      FBaseTSS,FFtp:Double;
      FLoad:TTrainingLoad;
      FTask:TRouteTask;
      FLastSave,FNextSync,FLastPoll:QWord;
    procedure BindUser;
    procedure SetDay(Day:Integer);
    procedure Save;
    procedure Load;
    procedure Add(Watts,Seconds,Ftp:Double;Active,Valid:Boolean);
    function FileName:String;
    function GetWork:Double;
    function GetTSS:Double;
  public
    constructor Create;
    destructor Destroy;override;
    procedure BeginRide;
    procedure EndRide;
    procedure Step(Watts,Seconds,WallSeconds,Ftp:Double;Active,Valid:Boolean;LocalEnd:TDateTime);
    procedure Update(Sender:TObject);
    function SaveState:TJSONObject;
    procedure RestoreState(O:TJSONObject);
    property WorkJoules:Double read GetWork;
    property TSS:Double read GetTSS;
  end;
var DailyTraining:TDailyTraining;
implementation
uses Math,DateUtils,VeloSiteAPI,CastleApplicationProperties,CastleLog,GameUserData;

function TDailyTraining.SaveState:TJSONObject;
begin
  BindUser;SetDay(Trunc(Date));
  with FDays[FIndex]do Result:=TJSONObject.Create(['account',UserDataDir,'day',Day,
    'source',Source,'revision',Revision,'work',Work,'tss',TSS,'ftp',FFtp]);
  Result.Add('load',FLoad.SaveState);
end;

procedure TDailyTraining.RestoreState(O:TJSONObject);
var SavedDay,I:Integer;Recovered:TJSONData;

  procedure MergeRecovered(Draft:TJSONObject);
  var Day:Integer;NewWork,NewTSS:Double;
  begin
    if(Draft=nil)or(Draft.Get('account','')<>UserDataDir)then Exit;
    Day:=Draft.Get('day',0);
    if(Day<Trunc(Date)-7)or(Day>Trunc(Date))then Exit;
    NewWork:=Draft.Get('work',0.0);NewTSS:=Draft.Get('tss',0.0);
    if IsNan(NewWork)or IsInfinite(NewWork)or(NewWork<0)or
      IsNan(NewTSS)or IsInfinite(NewTSS)or(NewTSS<0)then Exit;
    SetDay(Day);
    with FDays[FIndex]do begin
      if(Revision=0)and(Work=0)and(TSS=0)and(Draft.Get('source','')<>'')then
        Source:=Draft.Get('source','');
      { A new day in the recovered tail has no saved source ID yet. Existing
        durable totals may already include some/all of that tail: never add
        it blindly, and never roll back contributions acknowledged online. }
      if(Draft.Get('source','')<>'')and(Source<>Draft.Get('source',''))then Exit;
      if(NewWork>Work)or(NewTSS>TSS)then begin
        Work:=Max(Work,NewWork);TSS:=Max(TSS,NewTSS);
        Revision:=Max(Revision,Draft.Get('revision',Int64(0)))+1;FDirty:=True;
      end;
    end;
  end;
begin
  if(O=nil)or(O.Get('account','')<>UserDataDir)then Exit;
  BindUser;
  if O.Get('recovery_max',False)then begin
    Recovered:=O.Find('recovered_days');
    if Recovered is TJSONArray then begin
      for I:=0 to Recovered.Count-1 do
        if Recovered.Items[I]is TJSONObject then MergeRecovered(TJSONObject(Recovered.Items[I]));
    end else MergeRecovered(O);
  end;
  SavedDay:=O.Get('day',0);
  if(SavedDay<Trunc(Date)-7)or(SavedDay>Trunc(Date))then Exit;
  SetDay(SavedDay);FInRide:=True;
  with FDays[FIndex]do begin
    if(Revision=0)and(Work=0)and(TSS=0)then Source:=O.Get('source',Source);
    if (Source=O.Get('source',''))and(Revision<O.Get('revision',Int64(0)))then begin
      Revision:=O.Get('revision',Int64(0));Work:=Max(Work,O.Get('work',0.0));
      TSS:=Max(TSS,O.Get('tss',0.0));FDirty:=True;
    end;
    if O.Find('load') is TJSONObject then FLoad.RestoreState(O.Objects['load']);
    FFtp:=O.Get('ftp',0.0);FBaseTSS:=Max(0,TSS-FLoad.TSS);
  end;
  if SavedDay<>Trunc(Date)then SetDay(Trunc(Date));
end;

function DayText(Day:Integer):String;
begin Result:=FormatDateTime('yyyy-mm-dd',TDateTime(Day));end;
constructor TDailyTraining.Create;
begin inherited;FIndex:=-1;FLoad:=TTrainingLoad.Create;end;
destructor TDailyTraining.Destroy;
begin
  Save;RouteDetach(FTask);FLoad.Free;inherited;
end;
function TDailyTraining.FileName:String;
begin Result:=FAccountDir+'daily-training.json';end;
procedure TDailyTraining.Save;
var O,E:TJSONObject;A:TJSONArray;I:Integer;
begin
  if not FBound or not FDirty then Exit;
  O:=TJSONObject.Create(['version',1,'user_id',FUserId]);A:=TJSONArray.Create;O.Add('days',A);
  try
    for I:=0 to High(FDays)do begin
      if(FDays[I].Day<Trunc(Date)-7)and(FDays[I].Ack>=FDays[I].Revision)then Continue;
      with FDays[I]do begin
        E:=TJSONObject.Create(['day',Day,'source',Source,'revision',Revision,'ack',Ack,
          'work_j',Work,'tss',TSS,'other_work_j',OtherWork,'other_tss',OtherTSS]);A.Add(E);
      end;
    end;
    WriteAccountJSON(FileName,O);FDirty:=False;
  except on E:Exception do WritelnLog('DailyTraining','Local save failed: '+E.Message);end;
  O.Free;FLastSave:=GetTickCount64;
end;
procedure TDailyTraining.Load;
var O,E:TJSONObject;A:TJSONData;I,N:Integer;
begin
  if not FileExists(FileName)then Exit;
  O:=nil;
  try
    O:=ReadAccountJSON(FileName);
    if O.Get('user_id',Int64(-1))<>FUserId then begin O.Free;Exit end;
    A:=O.Find('days');if not(A is TJSONArray)then begin O.Free;Exit end;
    for I:=0 to A.Count-1 do if A.Items[I] is TJSONObject then begin
      E:=TJSONObject(A.Items[I]);N:=Length(FDays);SetLength(FDays,N+1);
      with FDays[N]do begin
        Day:=E.Get('day',0);Source:=E.Get('source','');Revision:=E.Get('revision',Int64(0));Ack:=E.Get('ack',Int64(0));
        Work:=Max(0,E.Get('work_j',0.0));TSS:=Max(0,E.Get('tss',0.0));
        OtherWork:=Max(0,E.Get('other_work_j',0.0));OtherTSS:=Max(0,E.Get('other_tss',0.0));
      end;
    end;
  except on E:Exception do WritelnLog('DailyTraining','Local load failed: '+E.Message);end;
  O.Free;
end;
procedure TDailyTraining.BindUser;
var Id:Int64;Dir:String;
begin
  Id:=0;if VeloSite.IsAuthorized then Id:=VeloSite.CachedProfile.Id;Dir:=UserDataDir;
  if FBound and(Id=FUserId)and(FAccountDir=Dir)then Exit;
  Save;RouteDetach(FTask);FDays:=nil;FIndex:=-1;FDirty:=False;
  FUserId:=Id;FAccountDir:=Dir;FBound:=True;FNextSync:=0;FLoad.Reset;Load;
  SetDay(Trunc(Date));
end;
procedure TDailyTraining.SetDay(Day:Integer);
var I:Integer;G:TGUID;
begin
  if(FIndex>=0)and(FDays[FIndex].Day=Day)then Exit;
  Save;
  I:=0;while(I<Length(FDays))and(FDays[I].Day<>Day)do Inc(I);
  if I=Length(FDays)then begin
    SetLength(FDays,I+1);FDays[I].Day:=Day;CreateGUID(G);
    FDays[I].Source:=LowerCase(Copy(GUIDToString(G),2,36));FDirty:=True;
  end;
  FIndex:=I;FBaseTSS:=FDays[I].TSS;FLoad.Reset;FFtp:=0;FNextSync:=0;
end;
procedure TDailyTraining.BeginRide;
begin
  BindUser;SetDay(Trunc(Date));FBaseTSS:=FDays[FIndex].TSS;
  FLoad.Reset;FFtp:=0;FInRide:=True;
end;
procedure TDailyTraining.EndRide;
begin
  if not FBound then Exit;
  FInRide:=False;FLoad.Reset;FBaseTSS:=FDays[FIndex].TSS;FFtp:=0;
  Save;FNextSync:=0;
end;
procedure TDailyTraining.Add(Watts,Seconds,Ftp:Double;Active,Valid:Boolean);
var D:Double;
begin
  if (FFtp<>0)and(Ftp<>FFtp)then begin
    FBaseTSS:=FDays[FIndex].TSS;FLoad.Reset;
  end;
  FFtp:=Ftp;
  FLoad.Step(Watts,Seconds,Ftp,Active,Valid);
  if not Active or not Valid or IsNan(Watts) or IsInfinite(Watts) or
    IsNan(Seconds)or IsInfinite(Seconds)or(Seconds<=0)then Exit;
  D:=FBaseTSS+FLoad.TSS;
  if(Watts>0)or(D<>FDays[FIndex].TSS)then begin
    FDays[FIndex].Work:=FDays[FIndex].Work+Max(0,Watts)*Seconds;
    FDays[FIndex].TSS:=D;Inc(FDays[FIndex].Revision);FDirty:=True;
  end;
end;
procedure TDailyTraining.Step(Watts,Seconds,WallSeconds,Ftp:Double;Active,Valid:Boolean;LocalEnd:TDateTime);
var Start:TDateTime;Fraction:Double;
begin
  BindUser;
  if IsNan(WallSeconds)or IsInfinite(WallSeconds)or(WallSeconds<=0)then WallSeconds:=0;
  Start:=LocalEnd-WallSeconds/SecsPerDay;
  if(Trunc(Start)<>Trunc(LocalEnd))and(WallSeconds>0)then begin
    SetDay(Trunc(Start));
    Fraction:=EnsureRange((Trunc(LocalEnd)-Start)*SecsPerDay/WallSeconds,0.0,1.0);
    Add(Watts,Seconds*Fraction,Ftp,Active,Valid);SetDay(Trunc(LocalEnd));
    Add(Watts,Seconds*(1-Fraction),Ftp,Active,Valid);
  end else begin SetDay(Trunc(LocalEnd));Add(Watts,Seconds,Ftp,Active,Valid);end;
  if FDirty and(GetTickCount64-FLastSave>=10000)then Save;
end;
function TDailyTraining.GetWork:Double;
begin if FIndex>=0 then Result:=FDays[FIndex].Work+FDays[FIndex].OtherWork else Result:=0;end;
function TDailyTraining.GetTSS:Double;
begin if FIndex>=0 then Result:=FDays[FIndex].TSS+FDays[FIndex].OtherTSS else Result:=0;end;
procedure TDailyTraining.Update(Sender:TObject);
var I:Integer;O:TJSONObject;Body,Path:String;Stamp:QWord;R:Int64;
begin
  Stamp:=GetTickCount64;
  if Stamp-FLastPoll<250 then Exit;FLastPoll:=Stamp;
  BindUser;
  if not FInRide then SetDay(Trunc(Date));
  if(FTask<>nil)and FTask.Done then begin
    if(FTask.ErrorText='')and(FTask.Response is TJSONObject)then begin
      O:=TJSONObject(FTask.Response);I:=FTaskIndex;
      if(O.Get('date','')=DayText(FDays[I].Day))and(O.Get('source_id','')=FDays[I].Source)then begin
        R:=O.Get('revision',Int64(0));FDays[I].Ack:=Max(FDays[I].Ack,R);
        FDays[I].OtherWork:=Max(0,O.Get('other_work_j',0.0));
        FDays[I].OtherTSS:=Max(0,O.Get('other_tss',0.0));FDirty:=True;
      end;
    end;
    FreeAndNil(FTask);FNextSync:=Stamp+30000;Save;
  end;
  if FDirty and(Stamp-FLastSave>=10000)then Save;
  { Isolated tests exercise the real local accounting; only HTTP is disabled. }
  if(GetEnvironmentVariable('REZVIVO_TEST_AUTH_FILE')<>'')and
    (GetEnvironmentVariable('REZVIVO_TEST_NO_UPLOAD')='1')then Exit;
  if(FTask<>nil)or(Stamp<FNextSync)or(FUserId<=0)or not VeloSite.IsAuthorized then Exit;
  I:=0;while(I<Length(FDays))and(FDays[I].Ack>=FDays[I].Revision)do Inc(I);
  if I=Length(FDays)then begin
    I:=FIndex;Path:='/me/training-day?date='+DayText(FDays[I].Day)+'&source_id='+FDays[I].Source;
    FTask:=TRouteTask.Create(FUserId,'GET',Path,'');
  end else begin
    Save; // Durable contribution precedes the network request.
    if FDirty then begin FNextSync:=Stamp+30000;Exit end;
    O:=TJSONObject.Create(['date',DayText(FDays[I].Day),'source_id',FDays[I].Source,
      'revision',FDays[I].Revision,'work_j',FDays[I].Work,'tss',FDays[I].TSS]);
    Body:=O.AsJSON;O.Free;FTask:=TRouteTask.Create(FUserId,'PUT','/me/training-day',Body);
  end;
  FTaskIndex:=I;FTask.RequestTimeoutMS:=2000;FTask.Start;
end;
initialization
  DailyTraining:=TDailyTraining.Create;
  ApplicationProperties.OnUpdate.Add(@DailyTraining.Update);
finalization
  ApplicationProperties.OnUpdate.Remove(@DailyTraining.Update);
  FreeAndNil(DailyTraining);
end.

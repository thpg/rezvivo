program ActivitySourceTests;
{$mode objfpc}{$H+}
uses SysUtils,Classes,GameSensorLog,GameActivitySource,TrainerData;
var L:TSensorLog;D:TTrainerDataRecord;Rows:TSensorSessionRecordArray;P,Dir:String;I,K:Integer;
procedure Check(V:Boolean;const S:String);
begin if not V then raise Exception.Create(S);end;
procedure Frame(Source:Byte);
begin L.SetSessionState(True,1,200);L.LogFrame(D,0,1,Source);end;
function Eligible:Boolean;
begin L.Close;Rows:=TSensorLog.LoadSession(L.FileName);Result:=TSensorLog.CanUploadIntervals(Rows);end;
begin
  Dir:=ExpandFileName(ParamStr(1));ForceDirectories(Dir);
  L:=TSensorLog.Create(Dir);D:=Default(TTrainerDataRecord);D.InstantPower:=200;
  try
    Frame(ActivitySourceSmartTrainer);Frame(ActivitySourceSmartTrainer);
    Check(Eligible,'real trainer excluded');P:=L.FileName;
    L.Resume(P,2);Frame(ActivitySourceSmartTrainer);Check(Eligible,'real resume excluded');
    L.Resume(P,3);Frame(ActivitySourceSimulation);Check(not Eligible,'mixed resume uploaded');
    Frame(ActivitySourceSmartTrainer);Check(Eligible,'source leaked into next session');
    Frame(ActivitySourceSimulation);Frame(ActivitySourceSmartTrainer);
    Check(not Eligible,'sim then real uploaded');
    Frame(ActivitySourceSmartTrainer);Frame(ActivitySourceSimulation);
    Check(not Eligible,'real then sim uploaded');
    Frame(ActivitySourceSensors);Check(not Eligible,'power meter without trainer uploaded');
    Frame(ActivitySourceUnknown);Frame(ActivitySourceSmartTrainer);
    Check(not Eligible,'unverified data uploaded');
    L.SetSessionState(False,0,0);L.LogFrame(D,0,1,ActivitySourceSmartTrainer);
    Check(not Eligible,'paused session uploaded');
    D.InstantPower:=$FFFF;Frame(ActivitySourceSmartTrainer);Check(not Eligible,'missing power uploaded');
    D.InstantPower:=0;Frame(ActivitySourceSmartTrainer);Check(Eligible,'measured zero power excluded');
    Frame(ActivitySourceSmartTrainer);P:=L.FileName;L.Close;
    with TStringList.Create do try
      LoadFromFile(P);
      { Remove provenance to emulate a pre-feature, unverified recording. }
      for I:=0 to Count-1 do begin
        K:=Length(Strings[I]);while(K>0)and(Strings[I][K]<>',')do Dec(K);
        Strings[I]:=Copy(Strings[I],1,K-1);
      end;
      SaveToFile(P);
    finally Free;end;
    Rows:=TSensorLog.LoadSession(P);Check(Length(Rows)>0,'legacy unreadable');
    Check(not TSensorLog.CanUploadIntervals(Rows),'legacy uploaded');
  finally L.Free;end;
  WriteLn('Activity source tests passed');
end.

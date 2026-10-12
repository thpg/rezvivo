program ReadyRouteRoomTests;
{$mode objfpc}{$H+}
uses SysUtils,GameRideRooms,GameRideClient,GameUpdateDownload,VeloSiteAPI;
var Input,A,B,Left:TRideRoomInfo;C1,C2:TRideRelayClient;Task:TRideRoomTask;UntilAt:QWord;Root:string;
procedure Check(B:Boolean;const S:string);
begin if not B then raise Exception.Create(S)end;
function Run(Op:TRideRoomOperation;const Info:TRideRoomInfo):TRideRoomInfo;
begin
 Task:=TRideRoomTask.Create(Op,Info,VeloSite.BaseUrl,Root,Root,0);
 try UntilAt:=GetTickCount64+10000;while not Task.Finished do begin Check(GetTickCount64<UntilAt,'room task timeout');Sleep(5)end;
  Result:=Task.ResultInfo;Check(Result.ErrorText='',Result.ErrorText);
 finally Task.Free end;
end;
procedure Setup(C:TRideRelayClient;const I:TRideRoomInfo;const Name:string);
begin C.ServerUrl:=I.RelayUrl;C.PrivateRoom:=True;C.RoomToken:=I.SessionToken;C.LocalRiderId:=I.RiderId;C.LocalRiderName:=Name;C.Start end;
begin
 Root:=ParamStr(1);Input:=Default(TRideRoomInfo);Input.Kind:='real';Input.WorldId:='krylatskoye-small-circuit';Input.RouteFile:=ParamStr(2);
 Input.ContentHash:=LowerCase(UpdateSHA256(Input.RouteFile));
 Check(not VeloSite.IsAuthorized,'test must use a local profile');
 A:=Run(roCatalog,Input);B:=Run(roCatalog,Input);
 Check((A.Code=B.Code)and(A.RiderId<>B.RiderId),'clients did not share one room');
 Check((A.SessionToken<>'')and(A.SessionToken<>B.SessionToken),'invalid scoped tokens');
 Check(A.RouteFile=Input.RouteFile,'auto join replaced selected route');
 C1:=TRideRelayClient.Create;C2:=TRideRelayClient.Create;
 try
  Setup(C1,A,'Ready route test A');Setup(C2,B,'Ready route test B');
  C1.PushBikeConfig('{"test":1}');C2.PushBikeConfig('{"test":2}');
  UntilAt:=GetTickCount64+7000;
  repeat
   C1.PushLocalState(100,5,150,80,120);C2.PushLocalState(110,6,160,85,130);
   Sleep(50);C1.UpdateRemoteRiders;C2.UpdateRemoteRiders;
  until((C1.RemoteRiderCount=1)and(C2.RemoteRiderCount=1))or(GetTickCount64>UntilAt);
  Check(C1.RemoteRiderCount=1,'A did not see B: '+C1.LastError);Check(C2.RemoteRiderCount=1,'B did not see A: '+C2.LastError);
 finally C1.Free;C2.Free end;
 Left:=Run(roLeave,A);Left:=Run(roLeave,B);
 Writeln('PASS local profiles: same room, unique scoped identities, bidirectional relay, leave');
end.

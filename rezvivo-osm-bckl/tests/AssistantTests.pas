program AssistantTests;
{$mode objfpc}{$H+}{$codepage UTF8}
uses SysUtils,fpjson,GameAssistant;
var Checks:Integer;
procedure Check(B:Boolean;const Why:string);
begin Inc(Checks);if not B then raise Exception.Create(Why) end;
procedure Run;
var A:TGameAssistant;Token,OldToken,S:string;J,K:TJSONObject;Id,Id2,ReplyId:Int64;
  I:Integer;Failed:Boolean;
begin
  A:=TGameAssistant.Create;
  try
    Failed:=False;try A.RegisterAgent('Agent','') except on E:EAssistantError do Failed:=True end;Check(Failed,'no registration without local transport');
    A.SetTransportAvailable(True);Token:=A.RegisterAgent('Тестовый агент','');Check(A.Connected,'connected');
    Failed:=False;try A.RegisterAgent('Hijack','') except on E:EAssistantError do Failed:=True end;Check(Failed,'active agent cannot be replaced without token');
    Id:=A.SendUserMessage('Начать тренировку');Id2:=A.SendUserMessage('Покажи интервалы');
    Failed:=False;try J:=A.Receive(Token,9999,0,16);J.Free except on E:EAssistantError do Failed:=True end;Check(Failed,'future cursor rejected');
    Failed:=False;try J:=A.Receive(Token,Id,0,16);J.Free except on E:EAssistantError do Failed:=True end;Check(Failed,'cannot skip unread pending messages');
    Failed:=False;try A.Acknowledge(Token,Id2) except on E:EAssistantError do Failed:=True end;Check(Failed,'cannot ACK undelivered');
    J:=A.Receive(Token,0,0,1);try Check(J.Arrays['messages'].Count=1,'bounded receive');Check(J.Arrays['messages'].Objects[0].Get('id',Int64(0))=Id,'first message') finally J.Free end;
    J:=A.Receive(Token,0,0,1);try Check(J.Arrays['messages'].Objects[0].Get('id',Int64(0))=Id,'read is retryable') finally J.Free end;
    J:=A.Receive(Token,Id,0,1);J.Free;
    ReplyId:=A.Reply(Token,'Интервалы показаны',Id2,'reply-1');
    Check(A.Reply(Token,'Интервалы показаны',Id2,'reply-1')=ReplyId,'reply retry does not duplicate');
    Failed:=False;try A.Reply(Token,'changed',Id2,'reply-1') except on E:EAssistantError do Failed:=True end;Check(Failed,'session retry key cannot change content');
    J:=A.Receive(Token,0,0,16);try Check(J.Arrays['messages'].Count=1,'answering later question keeps earlier question queued');Check(J.Arrays['messages'].Objects[0].Get('id',Int64(0))=Id,'earlier question retained') finally J.Free end;
    OldToken:=Token;A.Disconnect;Check(not A.Connected,'disconnect');Token:=A.RegisterAgent('Next agent','');Check(Token<>OldToken,'fresh token');
    Failed:=False;try A.Reply(OldToken,'stale reply',0) except on E:EAssistantError do Failed:=True end;Check(Failed,'revoked token rejected');
    J:=A.Receive(Token,0,0,16);try Check(J.Arrays['messages'].Count=1,'pending question survives reconnect') finally J.Free end;
    Check(A.Reply(Token,'Начинаю',Id,'reply-1')<>ReplyId,'new session may restart its reply IDs');
    J:=A.Snapshot;try
      Check(J.Get('pending_count',-1)=0,'reply acknowledges one question');
      Check(J.Arrays['messages'].Objects[2].Get('sender_name','')='Тестовый агент','past answer keeps original agent name');
      Check(J.Arrays['messages'].Objects[3].Get('sender_name','')='Next agent','new answer new agent name');
    finally J.Free end;
    for I:=1 to ASSISTANT_PENDING_LIMIT do A.SendUserMessage('queued '+IntToStr(I));
    Failed:=False;try A.SendUserMessage('overflow') except on E:EAssistantError do Failed:=True end;Check(Failed,'pending queue bounded, no silent loss');
    for I:=1 to ASSISTANT_HISTORY_LIMIT*2 do A.Reply(Token,'agent history '+IntToStr(I),0);
    J:=A.Snapshot;try Check(J.Arrays['messages'].Count=ASSISTANT_HISTORY_LIMIT,'history bounded');Check(J.Get('pending_count',0)=ASSISTANT_PENDING_LIMIT,'history eviction preserves queued user text') finally J.Free end;
    J:=A.Receive(Token,0,0,ASSISTANT_PENDING_LIMIT);try A.Acknowledge(Token,J.Get('last_id',Int64(0))) finally J.Free end;
    J:=A.Snapshot;try Check(J.Get('pending_count',-1)=0,'explicit cumulative ack') finally J.Free end;
    S:=StringOfChar('x',ASSISTANT_TEXT_LIMIT+1);Failed:=False;try A.SendUserMessage(S) except on E:EAssistantError do Failed:=True end;Check(Failed,'text bound');
    for I:=1 to ASSISTANT_EVENT_LIMIT+5 do A.AddEvent('workout',TJSONObject.Create(['index',I]));
    J:=A.EventsAfter(1);try Check(J.Arrays['items'].Count=ASSISTANT_EVENT_LIMIT,'event ring bounded');Check(J.Get('truncated',False),'event gap explicit');Check(J.Arrays['items'].Objects[0].Objects['data'].Get('index',0)=6,'events ordered') finally J.Free end;
    J:=A.EventsAfter(0);try Check(J.Get('truncated',False),'first poll reports event overrun') finally J.Free end;
    Failed:=False;try J:=A.EventsAfter(9999);J.Free except on E:EAssistantError do Failed:=True end;Check(Failed,'future event cursor rejected');
    A.Disconnect;Token:=A.RegisterAgent('Reconnected','');
    J:=A.EventsAfter(0);try Check(J.Arrays['items'].Count=0,'reconnect clears old events');Check(not J.Get('truncated',True),'new registration not confused with prior overrun') finally J.Free end;
    A.AddEvent('workout',TJSONObject.Create(['state','running']));
    J:=A.EventsAfter(0);try Check(J.Arrays['items'].Count=1,'zero cursor begins at current registration') finally J.Free end;
    A.Reset;J:=A.Snapshot;try Check(J.Arrays['messages'].Count=0,'reset history');Check(not J.Get('connected',True),'reset revokes session') finally J.Free end;
    Token:=A.RegisterAgent('Fresh','');Id2:=A.SendUserMessage('fresh');Check(Id2>ReplyId,'IDs not reused across reset');
    A.SetTransportAvailable(False);Failed:=False;try A.RequireSession(Token) except on E:EAssistantError do Failed:=True end;Check(Failed,'transport EOF revokes token');
  finally A.Free end;
end;
begin Run;Writeln('PASS ',Checks) end.

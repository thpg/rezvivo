unit GameAssistant;
{$mode objfpc}{$H+}{$codepage UTF8}
{ Main-thread state shared by the game UI and its local MCP connection.
  No network, files, renderer, trainer calculations or per-frame polling. }
interface
uses SysUtils,fpjson;
const
  ASSISTANT_HISTORY_LIMIT=120;
  ASSISTANT_PENDING_LIMIT=32;
  ASSISTANT_TEXT_LIMIT=4096;
  ASSISTANT_EVENT_LIMIT=64;
type
  EAssistantError=class(Exception);
  TAssistantMessage=record
    Id,InReplyTo:Int64;
    Role,Text,ClientId,SenderName:string;
    SessionGeneration:QWord;
    Replied:Boolean;
  end;
  TGameAssistant=class
  private
    FRevision,FContextRevision:QWord;
    FContextKey:string;
    FTransportAvailable,FConnected:Boolean;
    FAgentName,FToken:string;
    FNextId,FDeliveredTo,FSessionFirstId,FEventSerial:Int64;
    FSessionGeneration:QWord;
    FSessionEventBase:Int64;
    FMessages:array of TAssistantMessage;
    FPending:array of Int64;
    FEvents:array of TJSONObject;
    function Append(const Role,Text:string;InReplyTo:Int64;const ClientId:string):Int64;
    function Pending(Id:Int64):Boolean;
    function MessageJSON(const M:TAssistantMessage):TJSONObject;
  public
    destructor Destroy;override;
    procedure SetTransportAvailable(Value:Boolean);
    function RegisterAgent(const Name,ExistingToken:string):string;
    procedure RequireSession(const Token:string);
    procedure Disconnect;
    procedure Reset;
    function BindContext(const Key:string):Boolean;
    function SendUserMessage(const Text:string):Int64;
    function Receive(const Token:string;AfterId,AckThrough:Int64;Limit:Integer):TJSONObject;
    procedure Acknowledge(const Token:string;ThroughId:Int64);
    function Reply(const Token,Text:string;InReplyTo:Int64;const ClientId:string=''):Int64;
    function Snapshot:TJSONObject;
    procedure AddEvent(const Kind:string;Payload:TJSONObject); { takes ownership }
    function EventsAfter(Id:Int64):TJSONObject;
    property Revision:QWord read FRevision;
    property ContextRevision:QWord read FContextRevision;
    property TransportAvailable:Boolean read FTransportAvailable;
    property Connected:Boolean read FConnected;
    property AgentName:string read FAgentName;
  end;
function Assistant:TGameAssistant;
implementation
var Instance:TGameAssistant;
procedure ValidateText(const S:string;MaxBytes:Integer;AllowLines:Boolean);
var I:Integer;
begin
  if (Trim(S)='') or (Length(S)>MaxBytes) then raise EAssistantError.Create('assistant_invalid_text');
  for I:=1 to Length(S) do if (Ord(S[I])<32) and
    not(AllowLines and (S[I] in [#9,#10,#13])) then raise EAssistantError.Create('assistant_invalid_text');
end;
function Assistant:TGameAssistant;
begin if Instance=nil then Instance:=TGameAssistant.Create;Result:=Instance end;
destructor TGameAssistant.Destroy;
var I:Integer;
begin for I:=0 to High(FEvents) do FEvents[I].Free;inherited end;
function TGameAssistant.Pending(Id:Int64):Boolean;
var I:Integer;
begin for I:=0 to High(FPending) do if FPending[I]=Id then Exit(True);Result:=False end;
procedure TGameAssistant.SetTransportAvailable(Value:Boolean);
begin
  if FTransportAvailable=Value then Exit;
  FTransportAvailable:=Value;
  if not Value then Disconnect;
  Inc(FRevision);
end;
function TGameAssistant.RegisterAgent(const Name,ExistingToken:string):string;
var G:TGUID;I:Integer;
begin
  if not FTransportAvailable then raise EAssistantError.Create('assistant_transport_unavailable');
  ValidateText(Name,80,False);
  if FConnected then begin
    RequireSession(ExistingToken);
    if FAgentName<>Trim(Name) then begin FAgentName:=Trim(Name);Inc(FRevision) end;
    Exit(FToken);
  end;
  if CreateGUID(G)<>0 then raise EAssistantError.Create('assistant_session_failed');
  FToken:=GUIDToString(G);FAgentName:=Trim(Name);FConnected:=True;FDeliveredTo:=0;
  FSessionFirstId:=FNextId+1;
  if Length(FPending)>0 then FSessionFirstId:=FPending[0];
  Inc(FSessionGeneration);FSessionEventBase:=FEventSerial;
  for I:=0 to High(FEvents) do FEvents[I].Free;FEvents:=nil;
  Inc(FRevision);Result:=FToken;
end;
procedure TGameAssistant.RequireSession(const Token:string);
begin
  if not(FTransportAvailable and FConnected) or (Token='') or (Token<>FToken) then
    raise EAssistantError.Create('assistant_session_expired');
end;
procedure TGameAssistant.Disconnect;
begin
  if not FConnected and (FToken='') then Exit;
  { Keep unanswered queued questions: a reconnected agent receives them.
    Token revocation prevents replies/actions from the previous session. }
  FConnected:=False;FToken:='';FDeliveredTo:=0;Inc(FRevision);
end;
procedure TGameAssistant.Reset;
var I:Integer;
begin
  Disconnect;FMessages:=nil;FPending:=nil;FAgentName:='';Inc(FRevision);Inc(FContextRevision);
  for I:=0 to High(FEvents) do FEvents[I].Free;FEvents:=nil;
  FSessionEventBase:=FEventSerial;
  { IDs stay monotonic for the process lifetime: stale UI cursors cannot
    accidentally address a different message after a reset/reconnection. }
end;
function TGameAssistant.BindContext(const Key:string):Boolean;
begin
  Result:=FContextKey<>Key;
  if Result then begin Reset;FContextKey:=Key end;
end;
function TGameAssistant.Append(const Role,Text:string;InReplyTo:Int64;const ClientId:string):Int64;
var I,J,N:Integer;
begin
  N:=Length(FMessages);
  if N=ASSISTANT_HISTORY_LIMIT then begin
    I:=0;while (I<N) and Pending(FMessages[I].Id) do Inc(I);
    if I=N then raise EAssistantError.Create('assistant_queue_full');
    for J:=I to N-2 do FMessages[J]:=FMessages[J+1];Dec(N);SetLength(FMessages,N);
  end;
  SetLength(FMessages,N+1);Inc(FNextId);Result:=FNextId;
  FMessages[N].Id:=Result;FMessages[N].Role:=Role;FMessages[N].Text:=Text;
  if Role='assistant' then FMessages[N].SenderName:=FAgentName else FMessages[N].SenderName:='';
  FMessages[N].InReplyTo:=InReplyTo;FMessages[N].ClientId:=ClientId;Inc(FRevision);
  FMessages[N].SessionGeneration:=FSessionGeneration;
  FMessages[N].Replied:=False;
end;
function TGameAssistant.SendUserMessage(const Text:string):Int64;
var N:Integer;
begin
  if not FConnected then raise EAssistantError.Create('assistant_not_connected');
  ValidateText(Text,ASSISTANT_TEXT_LIMIT,True);N:=Length(FPending);
  if N>=ASSISTANT_PENDING_LIMIT then raise EAssistantError.Create('assistant_queue_full');
  Result:=Append('user',Trim(Text),0,'');SetLength(FPending,N+1);FPending[N]:=Result;
end;
function TGameAssistant.MessageJSON(const M:TAssistantMessage):TJSONObject;
var Delivery:string;
begin
  if M.Role<>'user' then Delivery:='sent'
  else if M.Replied then Delivery:='answered'
  else if Pending(M.Id) then Delivery:='queued' else Delivery:='received';
  Result:=TJSONObject.Create(['id',M.Id,'role',M.Role,'text',M.Text,'in_reply_to',M.InReplyTo,
    'delivery',Delivery,'sender_name',M.SenderName]);
end;
procedure TGameAssistant.Acknowledge(const Token:string;ThroughId:Int64);
var I,N:Integer;
begin
  RequireSession(Token);
  if (ThroughId<0) or (ThroughId>FDeliveredTo) then raise EAssistantError.Create('assistant_invalid_ack');
  N:=0;for I:=0 to High(FPending) do if FPending[I]>ThroughId then begin FPending[N]:=FPending[I];Inc(N) end;
  if N<>Length(FPending) then begin SetLength(FPending,N);Inc(FRevision) end;
end;
function TGameAssistant.Receive(const Token:string;AfterId,AckThrough:Int64;Limit:Integer):TJSONObject;
var A:TJSONArray;I:Integer;Last:Int64;
begin
  RequireSession(Token);
  if (AfterId<0) or (AfterId>FNextId) or (Limit<1) or (Limit>ASSISTANT_PENDING_LIMIT) then raise EAssistantError.Create('assistant_invalid_cursor');
  for I:=0 to High(FPending) do if (FPending[I]<=AfterId) and (FPending[I]>FDeliveredTo) then
    raise EAssistantError.Create('assistant_cursor_skips_unread');
  if AckThrough<>0 then Acknowledge(Token,AckThrough);
  A:=TJSONArray.Create;Last:=AfterId;
  for I:=0 to High(FMessages) do if (FMessages[I].Id>AfterId) and Pending(FMessages[I].Id) then begin
    A.Add(MessageJSON(FMessages[I]));Last:=FMessages[I].Id;
    if Last>FDeliveredTo then FDeliveredTo:=Last;
    if A.Count>=Limit then Break;
  end;
  Result:=TJSONObject.Create(['messages',A,'last_id',Last,'pending_count',Length(FPending),
    'revision',Int64(FRevision),'recommended_poll_ms',1000]);
end;
function TGameAssistant.Reply(const Token,Text:string;InReplyTo:Int64;const ClientId:string):Int64;
var I,N:Integer;Found:Boolean;
begin
  RequireSession(Token);ValidateText(Text,ASSISTANT_TEXT_LIMIT,True);
  if ClientId<>'' then begin
    ValidateText(ClientId,80,False);
    for I:=0 to High(FMessages) do if (FMessages[I].SessionGeneration=FSessionGeneration) and
      (FMessages[I].ClientId=ClientId) then begin
      if (FMessages[I].Text<>Text) or (FMessages[I].InReplyTo<>InReplyTo) then raise EAssistantError.Create('assistant_duplicate_message_id');
      Exit(FMessages[I].Id);
    end;
  end;
  Found:=InReplyTo=0;
  for I:=0 to High(FMessages) do if (FMessages[I].Id=InReplyTo) and (FMessages[I].Role='user') then Found:=True;
  if not Found or (InReplyTo<0) or (InReplyTo>FDeliveredTo) or
    ((InReplyTo>0) and (InReplyTo<FSessionFirstId)) then raise EAssistantError.Create('assistant_invalid_reply');
  Result:=Append('assistant',Text,InReplyTo,ClientId);
  if InReplyTo>0 then begin
    for I:=0 to High(FMessages) do if FMessages[I].Id=InReplyTo then FMessages[I].Replied:=True;
    N:=0;for I:=0 to High(FPending) do if FPending[I]<>InReplyTo then begin FPending[N]:=FPending[I];Inc(N) end;
    SetLength(FPending,N);
  end;
end;
procedure TGameAssistant.AddEvent(const Kind:string;Payload:TJSONObject);
var I,N:Integer;
begin
  if not FConnected then begin Payload.Free;Exit end;
  N:=Length(FEvents);
  if N=ASSISTANT_EVENT_LIMIT then begin FEvents[0].Free;for I:=0 to N-2 do FEvents[I]:=FEvents[I+1];Dec(N) end;
  SetLength(FEvents,N+1);Inc(FEventSerial);
  FEvents[N]:=TJSONObject.Create(['id',FEventSerial,'kind',Kind,'data',Payload]);
end;
function TGameAssistant.EventsAfter(Id:Int64):TJSONObject;
var A:TJSONArray;I:Integer;First,Cursor:Int64;
begin
  if (Id<0) or (Id>FEventSerial) then raise EAssistantError.Create('assistant_invalid_cursor');
  { Zero starts at registration, not process startup. This distinguishes an
    initial poll that missed events from a freshly reconnected session. }
  if Id=0 then Cursor:=FSessionEventBase else Cursor:=Id;
  A:=TJSONArray.Create;First:=FEventSerial+1;
  if Length(FEvents)>0 then First:=FEvents[0].Get('id',Int64(0));
  for I:=0 to High(FEvents) do if FEvents[I].Get('id',Int64(0))>Cursor then A.Add(FEvents[I].Clone);
  Result:=TJSONObject.Create(['items',A,'last_id',FEventSerial,'first_id',First,
    'truncated',Cursor<First-1]);
end;
function TGameAssistant.Snapshot:TJSONObject;
var A:TJSONArray;I:Integer;
begin
  A:=TJSONArray.Create;for I:=0 to High(FMessages) do A.Add(MessageJSON(FMessages[I]));
  Result:=TJSONObject.Create(['revision',Int64(FRevision),'connected',FConnected,
    'transport_available',FTransportAvailable,'agent_name',FAgentName,'messages',A,
    'pending_count',Length(FPending),'text_limit_bytes',ASSISTANT_TEXT_LIMIT]);
end;
finalization
  Instance.Free;
end.

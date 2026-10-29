{ Zwift controller plaintext GATT protocol (RideOn handshake).
  Primary protocol research:
  https://www.makinolo.com/blog/2023/10/08/connecting-to-zwift-play-controllers/
  https://www.makinolo.com/blog/2024/07/26/zwift-ride-protocol/
  Current firmware/field-3 format and plaintext handshake:
  https://github.com/OpenBikeControl/bikecontrol/tree/main/lib/bluetooth/devices/zwift
  This is an independent bounded protobuf decoder, not a firmware unlocker.
  Legacy encrypted firmware uses authenticated session decryption. }
unit ZwiftControllerProtocol;
{$mode objfpc}{$H+}
interface
uses SysUtils, TrainerData, GameSteeringInput, ZwiftSessionCrypto;
const
  ZwiftServiceUUID='00000001-19ca-4651-86e5-fa29dcdd09d1';
  ZwiftRideServiceUUID='0000fc82-0000-1000-8000-00805f9b34fb';
  ZwiftNotifyUUID='00000002-19ca-4651-86e5-fa29dcdd09d1';
  ZwiftWriteUUID='00000003-19ca-4651-86e5-fa29dcdd09d1';
  ZwiftResponseUUID='00000004-19ca-4651-86e5-fa29dcdd09d1';
type
  TZwiftHandshake = (zhNone,zhPlaintext,zhEncrypted);
  TZwiftControllerParser = class
  private
    FEdge: TSteeringEdge;
    FSerial: Cardinal;
    FDirection: ShortInt;
    FShiftUp,FShiftDown:Boolean;
    FJournal:TTrainerDataRecord;
    FCrypto:TZwiftSessionCrypto;
    FEncryptedRequired:Boolean;
    function ParsePlain(const Bytes:TBytes;out Data:TTrainerDataRecord):Boolean;
    procedure RecordShift(Direction:ShortInt);
  public
    procedure Reset;
    constructor Create;
    destructor Destroy;override;
    function StartEncryptedHandshake:TBytes;
    function AcceptHandshake(const Bytes:TBytes):Boolean;
    function Parse(const Bytes: TBytes; out Data: TTrainerDataRecord): Boolean;
  end;
function IsZwiftControllerName(const Name: String): Boolean;
function ZwiftControllerLocked(const Bytes:TBytes):Boolean;
function ZwiftHandshakeRequest(const Name:String=''): TBytes;
function ZwiftHandshakeReply(const Bytes: TBytes): TZwiftHandshake;
implementation
uses Math;
var ControllerGeneration:LongInt=0;
function ZwiftControllerLocked(const Bytes:TBytes):Boolean;
begin
  Result:=(Length(Bytes)=5)and(Bytes[0]=$FF)and(Bytes[1]=$05)and
    (Bytes[2]=0)and(Bytes[3]in[$EA,$FA])and(Bytes[4]=$05);
end;
function IsZwiftControllerName(const Name: String): Boolean;
var N: String;
begin
  N:=UpperCase(Trim(Name));
  Result:=(Pos('ZWIFT PLAY',N)=1) or (Pos('ZWIFT CLICK',N)=1) or
    (Pos('ZWIFT RIDE',N)=1) or (Pos('ZWIFT SF2',N)=1) or
    (Pos('ZWIFT RC1',N)=1) or (Pos('ZWIFT BC1',N)=1) or
    (Pos('ZWIFT CLICK',N)=1) or (Pos('ZWIFT BC2',N)=1);
end;
function ZwiftHandshakeRequest(const Name:String): TBytes;
var N:String;
begin
  Result:=TBytes.Create($52,$69,$64,$65,$4f,$6e);N:=UpperCase(Name);
  if(Pos('CLICK',N)>0)or(Pos('BC2',N)>0)or(Pos('BC1',N)>0)then begin
    SetLength(Result,8);Result[6]:=1;Result[7]:=3;
    if(Pos('V2',N)>0)or(Pos('BC2',N)>0)then Result[6]:=2;
  end else if(Pos('PLAY',N)>0)or(Pos('RC1',N)>0)then begin
    SetLength(Result,8);Result[6]:=1;Result[7]:=4;
  end;
end;
function ZwiftHandshakeReply(const Bytes: TBytes): TZwiftHandshake;
var I: Integer; Header: TBytes;
begin
  Result:=zhNone; Header:=ZwiftHandshakeRequest;
  if Length(Bytes)<Length(Header) then Exit;
  for I:=0 to High(Header) do if Bytes[I]<>Header[I] then Exit;
  if Length(Bytes) in [6,8] then Result:=zhPlaintext
  else if Length(Bytes)=72 then Result:=zhEncrypted;
end;
{ Read a protobuf uint32 and reject overflow/truncation, including malformed
  lengths. All walks are bounded by the enclosing message. No recursive parse. }
function ReadVar(const B:TBytes; var P:Integer; Limit:Integer; out V:Cardinal):Boolean;
var I:Integer; X:Byte;
begin
  Result:=False; V:=0;
  for I:=0 to 4 do
  begin
    if P>=Limit then Exit;
    X:=B[P]; Inc(P);
    if (I=4) and (X>$0F) then Exit;
    V:=V or (Cardinal(X and $7F) shl (I*7));
    if X<$80 then Exit(True);
  end;
end;
function Field(const B:TBytes; var P:Integer; Limit:Integer;
  out Number,Wire:Cardinal; out V:Cardinal; out Start,Stop:Integer):Boolean;
var Tag,N:Cardinal;
begin
  Result:=False; Start:=P; Stop:=P; V:=0;
  if not ReadVar(B,P,Limit,Tag) or (Tag<8) then Exit;
  Number:=Tag shr 3; Wire:=Tag and 7;
  case Wire of
    0: if not ReadVar(B,P,Limit,V) then Exit;
    1: begin if Limit-P<8 then Exit; Inc(P,8) end;
    2: begin
      if not ReadVar(B,P,Limit,N) or (N>Cardinal(Limit-P)) then Exit;
      Start:=P; Inc(P,Integer(N)); Stop:=P;
    end;
    5: begin if Limit-P<4 then Exit; Inc(P,4) end;
    else Exit;
  end;
  Result:=True;
end;
function Zigzag(V:Cardinal):Int64;
begin
  Result:=Int64(V shr 1);
  if (V and 1)<>0 then Result:=-Result-1;
end;
function Analog(const B:TBytes; P,Limit:Integer; out Location:Integer; out Value:Single):Boolean;
var N,W,V:Cardinal; A,Z:Integer; HaveValue:Boolean; SignedValue:Int64;
begin
  Result:=False; Location:=0; Value:=0; HaveValue:=False;
  while P<Limit do
  begin
    if not Field(B,P,Limit,N,W,V,A,Z) then Exit;
    if N in [1,2] then
    begin
      if W<>0 then Exit;
      if N=1 then begin if V>3 then Exit; Location:=V end
      else begin
        SignedValue:=Zigzag(V); if Abs(SignedValue)>100 then Exit;
        Value:=SignedValue/100; HaveValue:=True;
      end;
    end;
  end;
  Result:=HaveValue;
end;
constructor TZwiftControllerParser.Create;
begin inherited;Reset end;
procedure TZwiftControllerParser.Reset;
begin
  FreeAndNil(FCrypto);FEncryptedRequired:=False;
  FEdge.Reset;FSerial:=0;FDirection:=0;FShiftUp:=False;FShiftDown:=False;
  FJournal:=Default(TTrainerDataRecord);
  FJournal.ControllerGeneration:=Cardinal(InterlockedIncrement(ControllerGeneration));
end;
destructor TZwiftControllerParser.Destroy;
begin FCrypto.Free;inherited end;
function TZwiftControllerParser.StartEncryptedHandshake:TBytes;
begin
  FEncryptedRequired:=True;
  if FCrypto=nil then FCrypto:=TZwiftSessionCrypto.Create;
  Result:=FCrypto.BeginHandshake;
end;
function TZwiftControllerParser.AcceptHandshake(const Bytes:TBytes):Boolean;
begin
  Result:=False;
  case ZwiftHandshakeReply(Bytes)of
    zhPlaintext:Result:=not FEncryptedRequired;
    zhEncrypted:begin
      FEncryptedRequired:=True;
      if FCrypto<>nil then Result:=FCrypto.CompleteHandshake(Bytes);
    end;
  end;
end;
function TZwiftControllerParser.Parse(const Bytes:TBytes;out Data:TTrainerDataRecord):Boolean;
var Plain:TBytes;
begin
  Data:=Default(TTrainerDataRecord);
  if FEncryptedRequired then begin
    Result:=(FCrypto<>nil)and FCrypto.Decrypt(Bytes,Plain);
    if Result then Result:=ParsePlain(Plain,Data);
  end else Result:=ParsePlain(Bytes,Data);
end;
procedure TZwiftControllerParser.RecordShift(Direction:ShortInt);
begin
  if FJournal.ControllerSerial=High(Cardinal) then begin
    FJournal.ControllerSerial:=0;
    FJournal.ControllerGeneration:=Cardinal(InterlockedIncrement(ControllerGeneration));
  end;
  FJournal.ControllerActions[FJournal.ControllerSerial mod 16]:=Direction;
  Inc(FJournal.ControllerSerial);
end;
function TZwiftControllerParser.ParsePlain(const Bytes:TBytes; out Data:TTrainerDataRecord):Boolean;
var P,A,Z,Q,A2,Z2,Location,Turn:Integer; N,W,V,N2,W2,V2:Cardinal;
  Seen: set of 0..9; Values:array[0..9] of Cardinal;
  Mask:Cardinal; Axis,Value,AnalogAxis:Single; HaveMap,HaveAnalog,Left,Right:Boolean;
  Up,Down,HaveShift:Boolean;
begin
  Result:=False; Data:=Default(TTrainerDataRecord);
  if (Length(Bytes)<3) or (Length(Bytes)>512) then Exit;
  if not (Bytes[0] in [$07,$23,$37]) then Exit;
  FillChar(Values,SizeOf(Values),0); Seen:=[];
  P:=1; HaveMap:=False; HaveAnalog:=False; AnalogAxis:=0; Mask:=$FFFFFFFF;
  while P<Length(Bytes) do
  begin
    if not Field(Bytes,P,Length(Bytes),N,W,V,A,Z) then Exit;
    if Bytes[0] in [$07,$37] then
    begin
      if N<=9 then
      begin
        if W<>0 then Exit;
        Include(Seen,N); Values[N]:=V;
        if (N<=7) and (V>1) then Exit;
      end;
    end else if N=1 then
    begin
      if W<>0 then Exit;
      HaveMap:=True; Mask:=V;
    end else if N in [2,3] then
    begin
      if W<>2 then Exit;
      if N=3 then
      begin
        if not Analog(Bytes,A,Z,Location,Value) then Exit;
        if Location<2 then begin AnalogAxis:=AnalogAxis-Value; HaveAnalog:=True end;
      end else begin
        { Original Ride firmware: field 2 contains repeated field-1 entries. }
        Q:=A;
        while Q<Z do
        begin
          if not Field(Bytes,Q,Z,N2,W2,V2,A2,Z2) then Exit;
          if N2=1 then
          begin
            if (W2<>2) or not Analog(Bytes,A2,Z2,Location,Value) then Exit;
            if Location<2 then begin AnalogAxis:=AnalogAxis-Value; HaveAnalog:=True end;
          end;
        end;
      end;
    end;
  end;
  Axis:=0;Left:=False;Right:=False;Up:=False;Down:=False;HaveShift:=False;
  case Bytes[0] of
    $07: begin
      if not (1 in Seen) then Exit;
      if 8 in Seen then begin
        if Abs(Zigzag(Values[8]))>100 then Exit;
        Axis:=-Zigzag(Values[8])/100;
      end;
      if Values[1]=1 then begin
        Left:=(3 in Seen) and (Values[3]=0);
        Right:=(4 in Seen) and (Values[4]=0);
      end;
      HaveShift:=7 in Seen;
      if HaveShift and(Values[7]=0) then begin
        Up:=Values[1]=0;Down:=not Up;
      end;
      if not (8 in Seen) and not ((3 in Seen) and (4 in Seen)) then Exit;
    end;
    $23: begin
      if not HaveMap and not HaveAnalog then Exit;
      if HaveMap then begin
        Left:=(Mask and 1)=0;Right:=(Mask and 4)=0;
        { Sequential shifting: both paddles on the left easier, both on the
          right harder. Also covers Play 2 and Click V2's single +/- buttons. }
        Down:=(Mask and $600)<>$600;Up:=(Mask and $6000)<>$6000;
        HaveShift:=True;
      end;
      Axis:=EnsureRange(AnalogAxis,-1,1);
    end;
    $37: begin
      if not ((1 in Seen) and (2 in Seen)) then Exit;
      { Click: minus selects left, plus selects right. }
      Left:=Values[2]=0; Right:=Values[1]=0;
      Up:=Right;Down:=Left;HaveShift:=True;
    end;
  end;
  if HaveShift then begin
    if Up and not Down and not FShiftUp then RecordShift(1);
    if Down and not Up and not FShiftDown then RecordShift(-1);
    FShiftUp:=Up;FShiftDown:=Down;
  end;
  if Left or Right then Axis:=Ord(Left)-Ord(Right);
  Turn:=FEdge.Update(Axis);
  if Turn<>0 then
  begin
    if FSerial=High(Cardinal) then FSerial:=1 else Inc(FSerial);
    FDirection:=Turn;
  end;
  BeginTrainerPacket(Data);
  { Preserve the existing degree-based sensor/zero calibration interface. }
  if Axis=0 then Data.SteeringAngle:=0
  else Data.SteeringAngle:=-Sign(Axis)*(0.6+Abs(Axis)*33.4);
  Data.SteeringTurnSerial:=FSerial;
  Data.SteeringTurnDirection:=FDirection;
  MarkTrainerMetric(Data,tmSteering);
  if HaveShift then begin
    Data.ControllerGeneration:=FJournal.ControllerGeneration;
    Data.ControllerSerial:=FJournal.ControllerSerial;
    Data.ControllerShiftOnly:=Bytes[0]=$37;
    Data.ControllerActions:=FJournal.ControllerActions;
    MarkTrainerMetric(Data,tmController);
  end;
  Result:=True;
end;
end.

unit GameNetworkSerializer;

interface

uses
  SysUtils, fpjson, jsonparser, jsonscanner,
  CastleVectors,
  GameAgentNetwork, GameNetworkMessages;

type
  INetworkSerializer = interface
    ['{7E72FA15-A620-4D0D-8309-79C5613A5132}']
    function SerializeMessage(const AMsg: TGameNetworkMessage): String;
    function DeserializeMessage(const AData: String): TGameNetworkMessage;
  end;

  TJsonNetworkSerializer = class(TInterfacedObject, INetworkSerializer)
  private
    function VectorToJson(const V: TVector3): TJSONObject;
    function JsonToVector(const Data: TJSONData): TVector3;
  public
    function SerializeMessage(const AMsg: TGameNetworkMessage): String;
    function DeserializeMessage(const AData: String): TGameNetworkMessage;
  end;

implementation

function TJsonNetworkSerializer.VectorToJson(const V: TVector3): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('x', V.X);
  Result.Add('y', V.Y);
  Result.Add('z', V.Z);
end;

function TJsonNetworkSerializer.JsonToVector(const Data: TJSONData): TVector3;
var
  O: TJSONObject;
begin
  if not (Data is TJSONObject) then
    raise EJSON.Create('Expected vector object');
  O := TJSONObject(Data);
  Result := Vector3(
    O.Get('x', 0.0),
    O.Get('y', 0.0),
    O.Get('z', 0.0)
  );
end;

function TJsonNetworkSerializer.SerializeMessage(const AMsg: TGameNetworkMessage): String;
var
  Root: TJSONObject;
  Obj: TJSONObject;
begin
  Root := TJSONObject.Create;
  try
    case AMsg.Kind of
      mkInputCommand:
        begin
          Root.Add('kind', 'input');

          Obj := TJSONObject.Create;
          Root.Add('payload', Obj);
          Obj.Add('network_id', Int64(AMsg.Input.NetworkId));
          Obj.Add('sequence_id', Int64(AMsg.Input.SequenceId));
          Obj.Add('delta_time', AMsg.Input.DeltaTime);
          Obj.Add('client_time', AMsg.Input.ClientTime);

          Obj.Add('move_forward', AMsg.Input.MoveForward);
          Obj.Add('move_backward', AMsg.Input.MoveBackward);
          Obj.Add('turn_left', AMsg.Input.TurnLeft);
          Obj.Add('turn_right', AMsg.Input.TurnRight);
          Obj.Add('brake', AMsg.Input.Brake);

          Obj.Add('desired_power_watts', AMsg.Input.DesiredPowerWatts);
          Obj.Add('wants_auto_move', AMsg.Input.WantsAutoMove);

        end;

      mkStateSnapshot:
        begin
          Root.Add('kind', 'state');

          Obj := TJSONObject.Create;
          Root.Add('payload', Obj);
          Obj.Add('network_id', Int64(AMsg.State.NetworkId));
          Obj.Add('sequence_id', Int64(AMsg.State.SequenceId));
          Obj.Add('server_time', AMsg.State.ServerTime);
          Obj.Add('position', VectorToJson(AMsg.State.Position));
          Obj.Add('forward_dir', VectorToJson(AMsg.State.ForwardDir));
          Obj.Add('speed', AMsg.State.Speed);
          Obj.Add('power_watts', AMsg.State.PowerWatts);
          Obj.Add('auto_move', AMsg.State.AutoMove);
          Obj.Add('physics_mode', AMsg.State.PhysicsMode);

        end;
    end;

    Result := Root.AsJSON;
  finally
    Root.Free;
  end;
end;

function TJsonNetworkSerializer.DeserializeMessage(const AData: String): TGameNetworkMessage;
var
  Root, Payload: TJSONObject;
  JsonData: TJSONData;
  KindStr: String;
begin
  Result := nil;

  JsonData := nil;
  try
    try
      JsonData := GetJSON(AData);
      if not (JsonData is TJSONObject) then Exit;

      Root := TJSONObject(JsonData);
      KindStr := Root.Get('kind', '');
      if not (Root.Find('payload') is TJSONObject) then Exit;
      Payload := TJSONObject(Root.Find('payload'));

      Result := TGameNetworkMessage.Create;

      if KindStr = 'input' then
      begin
        Result.Kind := mkInputCommand;
        Result.Input.NetworkId := TAgentNetworkId(Payload.Get('network_id', Int64(0)));
        Result.Input.SequenceId := Cardinal(Payload.Get('sequence_id', Int64(0)));
        Result.Input.DeltaTime := Payload.Get('delta_time', 0.0);
        Result.Input.ClientTime := Payload.Get('client_time', 0.0);

        Result.Input.MoveForward := Payload.Get('move_forward', false);
        Result.Input.MoveBackward := Payload.Get('move_backward', false);
        Result.Input.TurnLeft := Payload.Get('turn_left', false);
        Result.Input.TurnRight := Payload.Get('turn_right', false);
        Result.Input.Brake := Payload.Get('brake', false);

        Result.Input.DesiredPowerWatts := Payload.Get('desired_power_watts', 0.0);
        Result.Input.WantsAutoMove := Payload.Get('wants_auto_move', false);
      end
      else
      if KindStr = 'state' then
      begin
        Result.Kind := mkStateSnapshot;
        Result.State.NetworkId := TAgentNetworkId(Payload.Get('network_id', Int64(0)));
        Result.State.SequenceId := Cardinal(Payload.Get('sequence_id', Int64(0)));
        Result.State.ServerTime := Payload.Get('server_time', 0.0);
        Result.State.Position := JsonToVector(Payload.Find('position'));
        Result.State.ForwardDir := JsonToVector(Payload.Find('forward_dir'));
        Result.State.Speed := Payload.Get('speed', 0.0);
        Result.State.PowerWatts := Payload.Get('power_watts', 0.0);
        Result.State.AutoMove := Payload.Get('auto_move', false);
        Result.State.PhysicsMode := Payload.Get('physics_mode', 0);
      end
      else
      begin
        FreeAndNil(Result);
      end;
    except
      on E: EJSONParser do FreeAndNil(Result);
      on E: EScannerError do FreeAndNil(Result);
      on E: EJSON do FreeAndNil(Result);
      on E: EConvertError do FreeAndNil(Result);
      else
      begin
        FreeAndNil(Result);
        raise;
      end;
    end;
  finally
    JsonData.Free;
  end;
end;

end.

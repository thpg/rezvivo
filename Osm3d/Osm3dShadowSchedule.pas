unit Osm3dShadowSchedule;
{$mode objfpc}{$H+}
interface

{ Experimental, process-local. Zero preserves the normal per-frame renderer.
  Geometry belongs to exactly one bucket, regardless of camera or frame. }
var
  TemporalShadowPartitions: Integer = 0;
  TemporalShadowLiveNear: Boolean = True;
  TemporalShadowMeasure: Boolean = False;
  TemporalShadowStatic: Boolean = True;
  TemporalShadowSinglePass: Boolean = True;
  TemporalShadowFreezeReuse: Boolean = True;
  ShadowCapturePartitions: Integer = 0;
  ShadowCapturePartition: Integer = 0;

function ShadowPartitionHash(Key: QWord): Cardinal;
function ShadowPartitionForFrame(Frame: QWord; Count: Integer): Integer;
function ShadowPartitionAccept(Key: QWord): Boolean; inline;
procedure SetTemporalShadowPartitions(Count: Integer);

implementation
uses SysUtils;

{$push}{$Q-}{$R-}
function ShadowPartitionHash(Key: QWord): Cardinal;
var H: Cardinal;
begin
  H:=Cardinal(Key) xor Cardinal(Key shr 32);
  H:=(H xor (H shr 16))*$7feb352d;
  H:=(H xor (H shr 15))*$846ca68b;
  Result:=H xor (H shr 16);
end;
{$pop}

function ShadowPartitionForFrame(Frame: QWord; Count: Integer): Integer;
begin
  if Count<=1 then Exit(0);
  { A hashed permutation, not an independent random choice each frame.
    Every bucket is refreshed once in N frames; none can starve. }
  Result:=Integer((Frame xor ShadowPartitionHash($72657a76)) and QWord(Count-1));
end;

function ShadowPartitionAccept(Key: QWord): Boolean;
begin
  Result:=(ShadowCapturePartitions<=1) or
    (Integer(ShadowPartitionHash(Key) and Cardinal(ShadowCapturePartitions-1))=ShadowCapturePartition);
end;

procedure SetTemporalShadowPartitions(Count: Integer);
begin
  if not (Count in [0,1,2,4]) then
    raise EArgumentException.Create('Shadow partitions: expected 0, 1, 2 or 4');
  TemporalShadowPartitions:=Count;
end;

initialization
  TemporalShadowPartitions:=StrToIntDef(GetEnvironmentVariable('REZVIVO_SHADOW_PARTITIONS'),0);
  if not (TemporalShadowPartitions in [0,1,2,4]) then TemporalShadowPartitions:=0;
  TemporalShadowLiveNear:=GetEnvironmentVariable('REZVIVO_SHADOW_LIVE_NEAR')<>'0';
end.

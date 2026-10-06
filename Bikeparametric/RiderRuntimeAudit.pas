unit RiderRuntimeAudit;

{$mode objfpc}{$H+}

interface

uses fpjson;

type
  TRiderWork = (rwViewUpdate, rwRiderList, rwDistanceCull, rwProfileDisplay,
    rwBikeFrame, rwAppearance, rwGpuFrame, rwNativePose, rwSpineFK, rwLimbIK,
    rwBodyFrameSend, rwInactiveBodyFrameSend, rwBotShadowPose);

var
  RiderRuntimeAuditActive: Boolean = False;

{ Explicit performance captures only; no timers, allocations or file I/O
  in the per-frame counters. Shared totals include all rider instances. }
procedure CountRiderWork(const Work: TRiderWork); inline;
procedure ResetRiderRuntimeAudit;
procedure SnapshotRiderRuntimeAudit(Dest: TJSONObject; Reset: Boolean);

implementation

const
  WorkNames: array[TRiderWork] of string = ('view_update','rider_list',
    'distance_cull','profile_display','bike_frame','appearance','gpu_frame',
    'native_pose','spine_fk','limb_ik','body_frame_send','inactive_body_frame_send',
    'bot_shadow_pose');
var
  Counts: array[TRiderWork] of QWord;

procedure CountRiderWork(const Work: TRiderWork);
begin
  if RiderRuntimeAuditActive then Inc(Counts[Work]);
end;

procedure ResetRiderRuntimeAudit;
begin
  FillChar(Counts, SizeOf(Counts), 0);
end;

procedure SnapshotRiderRuntimeAudit(Dest: TJSONObject; Reset: Boolean);
var Work: TRiderWork;
begin
  for Work := Low(TRiderWork) to High(TRiderWork) do
    Dest.Add(WorkNames[Work], Int64(Counts[Work]));
  if Reset then ResetRiderRuntimeAudit;
end;

end.

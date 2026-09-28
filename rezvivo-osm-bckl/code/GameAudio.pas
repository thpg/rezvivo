unit GameAudio;
{$mode objfpc}{$H+}
interface
uses Classes,fpjson,CastleSoundEngine,GameAudioOptions,GameAudioCues,
  GameWorkoutPlayer,GamePhysicsCommon,Osm3dSoundscape;
type
  TGameAudio=class(TComponent)
  private
    FLoops:array[TEnvironmentSound]of TCastlePlayingSound;
    FEffects:array[0..4]of TCastleSound;
    FVoices:array[0..9]of TCastlePlayingSound;
    FVoiceGroups:array[0..9]of TAudioOption;
    FVoiceGains:array[0..9]of Single;
    FTargets,FLevels:TEnvironmentMix;
    FLoopDuration:array[TEnvironmentSound]of Single;
    FEffectDuration:array[0..4]of Single;
    FVolumes:TAudioValues;
    FRevision:Cardinal;
    FClock:TWorkoutAudioClock;
    FContacts:array[0..1]of TWheelAudioContact;
    FLastTick,FLastClick:QWord;
    FDuck:Single;
    FMenuOpen,FRiding:Boolean;
    FCounts:array[0..4]of Integer;
    function LoadSound(const AssetName:string;Stream:Boolean):TCastleSound;
    function SafeDuration(Sound:TCastleSound):Single;
    procedure PlayEffect(Index:Integer;Level:Single=1);
    procedure Update(Sender:TObject);
    function Gain(Group:TAudioOption):Single;
  public
    constructor Create(AOwner:TComponent);override;
    destructor Destroy;override;
    procedure MenuClick;
    procedure StopRide;
    procedure ResetContacts;
    procedure SetEnvironment(const Mix:TEnvironmentMix;Speed:Single);
    procedure StepRide(State:TPhysicsState;Player:TWorkoutPlayer;Advancing,MenuOpen:Boolean);
    function Diagnostics:TJSONObject;
  end;
var GameSound:TGameAudio;
procedure PlayMenuClick;
implementation
uses SysUtils,Math,CastleApplicationProperties,CastleLog,AppSettings;
const
  AmbienceNames:array[TEnvironmentSound]of string=('city','forest','sea','highway','wind');
  EffectNames:array[0..4]of string=('click','countdown','interval-start','wheel-front','wheel-rear');

function TGameAudio.LoadSound(const AssetName:string;Stream:Boolean):TCastleSound;
begin
  Result:=TCastleSound.Create(Self);Result.Stream:=Stream;
  if Stream then Result.Url:='castle-data:/audio/'+AssetName+'.ogg'
  else Result.Url:='castle-data:/audio/'+AssetName+'.wav';
end;

constructor TGameAudio.Create(AOwner:TComponent);
var K:TEnvironmentSound;I:Integer;
begin
  inherited;FClock:=TWorkoutAudioClock.Create;FVolumes:=AudioDefaults;
  FRevision:=High(Cardinal);FLastTick:=GetTickCount64;
  for K:=Low(K)to High(K)do begin
    FLoops[K]:=TCastlePlayingSound.Create(Self);
    FLoops[K].Sound:=LoadSound(AmbienceNames[K],True);
    FLoopDuration[K]:=SafeDuration(FLoops[K].Sound);
    FLoops[K].Loop:=True;FLoops[K].Volume:=0;
  end;
  for I:=0 to High(FEffects)do begin
    FEffects[I]:=LoadSound(EffectNames[I],False);FEffectDuration[I]:=SafeDuration(FEffects[I]);
  end;
  for I:=0 to High(FVoices)do FVoices[I]:=TCastlePlayingSound.Create(Self);
  ApplicationProperties.OnUpdate.Add(@Update);
end;

function TGameAudio.SafeDuration(Sound:TCastleSound):Single;
begin
  try Result:=Sound.Duration;
  except on E:Exception do begin
    Result:=-1;WritelnLog('Audio',Sound.Url+': '+E.Message);
  end;end;
end;

destructor TGameAudio.Destroy;
begin
  ApplicationProperties.OnUpdate.Remove(@Update);StopRide;FClock.Free;
  inherited;
end;

function TGameAudio.Gain(Group:TAudioOption):Single;
begin Result:=FVolumes[aoMaster]*FVolumes[Group]/10000;end;

procedure TGameAudio.Update(Sender:TObject);
var NowTick:QWord;Dt,A,Target:Single;K:TEnvironmentSound;O:TAudioOption;I:Integer;
begin
  NowTick:=GetTickCount64;Dt:=Min(0.15,(NowTick-FLastTick)*0.001);FLastTick:=NowTick;
  if FRevision<>Settings.AudioRevision then begin
    for O:=Low(O)to High(O)do FVolumes[O]:=Settings.GetAudioOption(Ord(O));
    FRevision:=Settings.AudioRevision;
  end;
  FDuck:=Max(0,FDuck-Dt);A:=1-Exp(-Dt/1.5);
  for K:=Low(K)to High(K)do begin
    Target:=FTargets[K];if not FRiding then Target:=0;
    FLevels[K]:=FLevels[K]+(Target-FLevels[K])*A;
    Target:=FLevels[K]*Gain(aoAmbience);
    if FMenuOpen then Target:=Target*0.4;
    if FDuck>0 then Target:=Target*0.45;
    FLoops[K].Volume:=Target;
    if Target<0.001 then FLoops[K].Stop
    else if not FLoops[K].Playing and(FLoopDuration[K]>0)then SoundEngine.Play(FLoops[K]);
  end;
  for I:=0 to High(FVoices)do
    if FVoices[I].Playing then FVoices[I].Volume:=FVoiceGains[I]*Gain(FVoiceGroups[I]);
end;

procedure TGameAudio.PlayEffect(Index:Integer;Level:Single);
var I:Integer;Group:TAudioOption;
begin
  if(Index<0)or(Index>High(FEffects))then Exit;
  if Index=0 then Group:=aoMenu else if Index<=2 then Group:=aoWorkout else Group:=aoEffects;
  if FRevision<>Settings.AudioRevision then Update(nil);
  if(Self.Gain(Group)<=0)or(FEffectDuration[Index]<=0)then Exit;
  I:=3;
  if Index<=2 then I:=Index
  else begin
    while(I<High(FVoices))and FVoices[I].Playing do Inc(I);
  end;
  FVoices[I].Stop;FVoices[I].Sound:=FEffects[Index];
  FVoiceGroups[I]:=Group;FVoiceGains[I]:=Level;
  FVoices[I].Volume:=Level*Self.Gain(Group);
  SoundEngine.Play(FVoices[I]);Inc(FCounts[Index]);
  if Index in[1,2]then FDuck:=0.9;
end;

procedure TGameAudio.MenuClick;
var T:QWord;
begin
  T:=GetTickCount64;if T-FLastClick<45 then Exit;FLastClick:=T;PlayEffect(0,0.55);
end;
procedure PlayMenuClick;
begin if GameSound<>nil then GameSound.MenuClick;end;

procedure TGameAudio.ResetContacts;
begin FillChar(FContacts,SizeOf(FContacts),0);FClock.Reset;end;

procedure TGameAudio.StopRide;
var K:TEnvironmentSound;I:Integer;
begin
  FRiding:=False;FTargets:=Default(TEnvironmentMix);FLevels:=FTargets;
  for K:=Low(K)to High(K)do if FLoops[K]<>nil then FLoops[K].Stop;
  for I:=1 to High(FVoices)do if FVoices[I]<>nil then FVoices[I].Stop;
  ResetContacts;FDuck:=0;
end;

procedure TGameAudio.SetEnvironment(const Mix:TEnvironmentMix;Speed:Single);
begin
  FTargets:=Mix;
  FTargets[esCity]:=Mix[esCity]*0.75;
  FTargets[esHighway]:=Mix[esHighway]*(1-0.75*Mix[esCity]);
  FTargets[esForest]:=Mix[esForest]*(1-0.35*Mix[esCity]);
  FTargets[esWind]:=(0.16+EnsureRange(Speed/25,0.0,0.35))*(1-0.65*Mix[esForest])*(1-0.45*Mix[esCity]);
end;

procedure TGameAudio.StepRide(State:TPhysicsState;Player:TWorkoutPlayer;Advancing,MenuOpen:Boolean);
var Cue:TWorkoutAudioCue;Impact,Grade:Single;
begin
  FRiding:=State<>nil;FMenuOpen:=MenuOpen;
  Cue:=FClock.Step(Player,Advancing);
  case Cue of wacCount:PlayEffect(1);wacStart:PlayEffect(2);end;
  if not FRiding or not Advancing then begin FillChar(FContacts,SizeOf(FContacts),0);Exit;end;
  Grade:=Tan(DegToRad(State.CurrentGroundPitch));
  Impact:=WheelAudioImpact(FContacts[0],State.FrontGroundPoint,State.FrontGroundPointValid,State.CurrentSpeed,Grade);
  if Impact>0 then PlayEffect(3,Impact);
  Impact:=WheelAudioImpact(FContacts[1],State.RearGroundPoint,State.RearGroundPointValid,State.CurrentSpeed,Grade);
  if Impact>0 then PlayEffect(4,Impact);
end;

function TGameAudio.Diagnostics:TJSONObject;
var A,B,C,D:TJSONObject;K:TEnvironmentSound;I:Integer;
begin
  Result:=TJSONObject.Create;Result.Add('device_open',SoundEngine.IsContextOpenSuccess);Result.Add('riding',FRiding);
  Result.Add('device_info',SoundEngine.Information);
  A:=TJSONObject.Create;B:=TJSONObject.Create;C:=TJSONObject.Create;D:=TJSONObject.Create;
  Result.Add('target',A);Result.Add('volume',B);Result.Add('events',C);Result.Add('duration',D);
  for K:=Low(K)to High(K)do begin
    A.Add(AmbienceNames[K],FTargets[K]);B.Add(AmbienceNames[K],FLoops[K].Volume);
    D.Add(AmbienceNames[K],FLoopDuration[K]);
  end;
  for I:=0 to High(FCounts)do begin C.Add(EffectNames[I],FCounts[I]);D.Add(EffectNames[I],FEffectDuration[I]);end;
end;
end.

unit GameLocalRiderCamera;
{$mode objfpc}{$H+}
interface
uses CastleTransform,CastleViewport,CastleVectors,GamePhysicalAgent,GameCinematicCamera;
type
  { This director selects subjects; TCinematicCamera owns lens safety and cuts.
    Call only in the live cinematic branch, before feeding target speed/pitch. }
  TLocalRiderCamera=class
  private
    FGroupTarget:TCastleTransform;
    FCamera:TCinematicCamera;
    FSelected,FNextIndividual:Integer;
    FShotSerial:Cardinal;
    FDwell,FGroupCredit,FShotRadius:Single;
    FGroupShot:Boolean;
    function ValidAgent(A:TPhysicalAgent):Boolean;
  public
    constructor Create;
    destructor Destroy;override;
    procedure Reset;
    function Update(Dt:Single;Camera:TCinematicCamera;Viewport:TCastleViewport;
      const Agents:array of TPhysicalAgent):Integer;
    property SelectedIndex:Integer read FSelected;
    property GroupShot:Boolean read FGroupShot;
  end;
implementation
uses Math,SysUtils,GamePath;

constructor TLocalRiderCamera.Create;
begin
  inherited;
  FGroupTarget:=TCastleTransform.Create(nil);
  FGroupTarget.Direction:=Vector3(0,0,1);
  Reset;
end;
destructor TLocalRiderCamera.Destroy;
begin
  { The camera is externally owned and may already have been released. }
  FGroupTarget.Free;
  inherited;
end;
procedure TLocalRiderCamera.Reset;
begin
  { The shared camera remains responsible for real interaction episodes. }
  FSelected:=-1;FNextIndividual:=0;
  FShotSerial:=0;FDwell:=0;FGroupCredit:=1;
  FGroupShot:=False;FShotRadius:=0;
end;
function TLocalRiderCamera.ValidAgent(A:TPhysicalAgent):Boolean;
begin
  Result:=(A<>nil)and(A.State<>nil)and(A.Actor<>nil)and(A.Actor.Transform<>nil);
end;

function TLocalRiderCamera.Update(Dt:Single;Camera:TCinematicCamera;Viewport:TCastleViewport;
  const Agents:array of TPhysicalAgent):Integer;
var I,J,Count,First,Leader,Chosen,OldSelected,Attempt:Integer;
  Center,Heading,Delta:TVector3;Span,Radius,GroupChance:Single;
  OldGroup,ChooseGroup,Aligned:Boolean;Target:TCastleTransform;Path:TGamePath;Mode:TCameraMode;
begin
  Result:=-1;
  if(Camera=nil)or(Viewport=nil)or(Viewport.Camera=nil)then Exit;
  if IsNan(Dt)or IsInfinite(Dt)or(Dt<0)then Exit;
  Count:=0;First:=-1;Leader:=-1;Center:=TVector3.Zero;Heading:=TVector3.Zero;Span:=0;
  for I:=0 to High(Agents)do if ValidAgent(Agents[I])then begin
    Inc(Count);if First<0 then First:=I;
    Center:=Center+Agents[I].Actor.Transform.Translation;
    Heading:=Heading+Agents[I].State.ForwardDir;
    if(Leader<0)then Leader:=I
    else if Agents[I].State.CumulativeDistance>Agents[Leader].State.CumulativeDistance then Leader:=I;
    for J:=0 to I-1 do if ValidAgent(Agents[J])then begin
      Delta:=Agents[I].Actor.Transform.Translation-Agents[J].Actor.Transform.Translation;
      Span:=Max(Span,Delta.Length);
    end;
  end;
  if Count=0 then Exit;
  Center:=Center*(1.0/Count);Heading.Y:=0;
  if Heading.LengthSqr<0.001 then Heading:=Agents[First].State.ForwardDir;
  Heading.Y:=0;
  if Heading.LengthSqr<0.001 then Heading:=Vector3(0,0,1)else Heading:=Heading.Normalize;
  Radius:=0;Aligned:=True;
  for I:=0 to High(Agents)do if ValidAgent(Agents[I])then begin
    Radius:=Max(Radius,(Agents[I].Actor.Transform.Translation-Center).Length);
    if TVector3.DotProduct(Heading,Agents[I].State.ForwardDir)<0.5 then Aligned:=False;
  end;
  FGroupTarget.Translation:=Center;FGroupTarget.Direction:=Heading;
  if FCamera<>Camera then begin
    FCamera:=Camera;FSelected:=-1;FDwell:=0;
    FGroupShot:=False;FGroupCredit:=1;
  end;
  if Count=1 then begin
    Camera.ExternalSubjectDirector:=False;
    Camera.GroupRadius:=0;
    if(FSelected<>First)or FGroupShot then
      Camera.Retarget(Agents[First].Actor.Transform,Agents[First].Path,True);
    FSelected:=First;FGroupShot:=False;Result:=First;Exit;
  end;
  if not Camera.AutoSwitch then begin
    Camera.ExternalSubjectDirector:=False;Camera.GroupRadius:=0;
    OldSelected:=FSelected;
    if(FSelected<0)or(FSelected>High(Agents))then FSelected:=First
    else if not ValidAgent(Agents[FSelected])then FSelected:=First;
    if FGroupShot or(OldSelected<>FSelected)then begin
      Mode:=Camera.Mode;
      Camera.Retarget(Agents[FSelected].Actor.Transform,Agents[FSelected].Path,True);
      Camera.ForceMode(Mode);
    end;
    FGroupShot:=False;Result:=FSelected;Exit;
  end;
  Camera.ExternalSubjectDirector:=True;
  { Finish short encounters before selecting another participant. Only the
    normal shot timer is managed here; event logic keeps its usual guards. }
  if Camera.Mode in[cmPuddle,cmRiderPass,cmInteraction]then begin
    Camera.GroupRadius:=0;Result:=FSelected;Exit;
  end;
  if FGroupShot then begin
    FShotRadius:=Max(FShotRadius,Radius);Camera.GroupRadius:=FShotRadius;
  end;
  FDwell:=Max(0,FDwell-Dt);
  { A separated/opposing group invalidates its composition immediately.
    Normal subject/mode selection is otherwise held for the whole dwell. }
  if FGroupShot and((Span>=80)or not Aligned)then FDwell:=0;
  if(FSelected<0)or(FSelected>High(Agents))then FDwell:=0
  else if not ValidAgent(Agents[FSelected])then FDwell:=0;
  if FDwell>0 then begin Result:=FSelected;Exit end;
  OldSelected:=FSelected;OldGroup:=FGroupShot;
  GroupChance:=0;
  if Aligned and(Span<80)then
    GroupChance:=0.75*EnsureRange((80-Span)/55,0,1);
  FGroupCredit:=FGroupCredit+GroupChance;
  ChooseGroup:=(GroupChance>0)and(FGroupCredit>=1);
  if ChooseGroup then FGroupCredit:=FGroupCredit-1;
  if ChooseGroup then begin
    Chosen:=Leader;Target:=FGroupTarget;Path:=nil;FShotRadius:=Max(0.5,Radius);
    Camera.GroupRadius:=FShotRadius;
    if(FShotSerial mod 2)=0 then Mode:=cmReverse else Mode:=cmMoto;
  end else begin
    Chosen:=First;
    for Attempt:=0 to High(Agents)do begin
      I:=(FNextIndividual+Attempt)mod Length(Agents);
      if ValidAgent(Agents[I])then begin Chosen:=I;Break end;
    end;
    { Group plans do not advance this cursor: every individual gets a turn. }
    FNextIndividual:=(Chosen+1)mod Length(Agents);
    Target:=Agents[Chosen].Actor.Transform;Path:=Agents[Chosen].Path;Camera.GroupRadius:=0;
    if Abs(Agents[Chosen].State.CurrentSpeed)<0.3 then Mode:=cmStandShot
    else if Chosen=Leader then begin
      if(FShotSerial mod 3)<2 then Mode:=cmReverse else Mode:=cmFrontQuarterLeft;
    end else case FShotSerial mod 3 of
      1:Mode:=cmFrontQuarterRight;
      else Mode:=cmMoto;
    end;
  end;
  FSelected:=Chosen;FGroupShot:=ChooseGroup;
  if(OldSelected<>Chosen)or(OldGroup<>ChooseGroup)or(FShotSerial=0)then
    Camera.Retarget(Target,Path,True);
  Camera.ForceMode(Mode);
  Inc(FShotSerial);FDwell:=6+((FShotSerial-1)mod 5);
  Result:=FSelected;
end;
end.

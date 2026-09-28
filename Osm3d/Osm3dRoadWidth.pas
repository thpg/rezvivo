unit Osm3dRoadWidth;

{$mode objfpc}{$H+}

interface

uses Osm3dOsmData, Osm3dRoadSurface;

function ResolveRoadWidth(const Tags:TOSMTags; out ForwardLanes,BackwardLanes:Integer;
  out Layout:TRoadLaneLayout):Single;

implementation

uses SysUtils, Math, Osm3dOsmTagUtils;

function Number(const Tags:TOSMTags; const Key:string; out N:Integer):Boolean;
begin
  Result:=TryStrToInt(Trim(Tags.Get(Key)),N);
  Result:=Result and (N>=0) and (N<=ROAD_MAX_LANES);
  if not Result then N:=0;
end;

function Meters(const Tags:TOSMTags; const Key:string):Single;
var V:Double;
begin
  V:=ParseOSMMeters(Trim(Tags.Get(Key)));
  if IsNan(V) or IsInfinite(V) or (V<0.1) or (V>200) then Result:=0 else Result:=V;
end;

function ResolveRoadWidth(const Tags:TOSMTags; out ForwardLanes,BackwardLanes:Integer;
  out Layout:TRoadLaneLayout):Single;
var H,S:string; OneWay,Reverse,Vehicle,HF,HB,HT,HasWidths:Boolean;
  N,F,B,C,D,I:Integer; Lane,Fixed,Total,ExplicitWidth,Scale:Single;
  Values:array[0..ROAD_MAX_LANES-1] of Single;
  function ReadWidths(const Key:string):Integer;
  var Text,Token:string; P,K:Integer; W:Double;
  begin
    Result:=0; Text:=Tags.Get(Key); if Text='' then Exit;
    P:=1;
    for K:=1 to Length(Text)+1 do
      if (K>Length(Text)) or (Text[K]='|') then
      begin
        if Result>=ROAD_MAX_LANES then Exit(0);
        Token:=Trim(Copy(Text,P,K-P)); W:=ParseOSMMeters(Token);
        if (Token<>'') and ((W<0.1) or (W>20) or IsNan(W) or IsInfinite(W)) then Exit(0);
        Values[Result]:=W; Inc(Result); P:=K+1;
      end;
  end;
  procedure ApplyWidths(const Key:string; Offset,Expected:Integer; Flip:Boolean);
  var K,Idx,L:Integer;
  begin
    L:=ReadWidths(Key); if (L=0) or (L<>Expected) then Exit;
    for K:=0 to L-1 do
    begin
      if Flip then Idx:=Offset+L-1-K else Idx:=Offset+K;
      if Values[K]>0 then begin Layout.Widths[Idx]:=Values[K]; HasWidths:=True end;
    end;
  end;
begin
  Layout:=Default(TRoadLaneLayout); ForwardLanes:=0; BackwardLanes:=0;
  H:=Tags.GetLower('highway'); S:=Tags.GetLower('oneway');
  Reverse:=(S='-1') or (S='reverse');
  OneWay:=Reverse or (S='yes') or (S='1') or (S='true');
  if S='' then OneWay:=(H='motorway') or (H='motorway_link') or
    (Tags.GetLower('junction')='roundabout');
  Vehicle:=(H='motorway') or (H='trunk') or (H='primary') or (H='secondary') or
    (H='tertiary') or (H='residential') or (H='unclassified') or (H='road') or
    (H='living_street') or (H='service') or (H='busway') or (H='raceway') or
    (H='track') or (Pos('_link',H)>0);
  Lane:=3.0; Fixed:=0; D:=2;
  if (Pos('motorway',H)=1) or (Pos('trunk',H)=1) then Lane:=3.75
  else if (Pos('primary',H)=1) or (Pos('secondary',H)=1) or (H='busway') then Lane:=3.5
  else if Pos('tertiary',H)=1 then Lane:=3.25;
  if (Pos('_link',H)>0) or (H='service') or (H='living_street') or
    (H='busway') or (H='track') then D:=1;
  if (H='service') or (H='living_street') or (H='track') then Lane:=3.5;
  if H='raceway' then begin D:=1; Lane:=6 end;
  if not Vehicle then
  begin
    D:=1; Fixed:=2.2;
    if (H='path') or (H='bridleway') then Fixed:=1.2;
    if (H='steps') or (H='corridor') then Fixed:=1.5;
    if H='pedestrian' then Fixed:=8;
    if H='cycleway' then
    begin
      if OneWay then begin Lane:=1.5; D:=1 end else begin Lane:=1.0; D:=2 end;
      Fixed:=0;
    end;
  end;
  HF:=Number(Tags,'lanes:forward',F); HB:=Number(Tags,'lanes:backward',B);
  Number(Tags,'lanes:both_ways',C);
  HT:=Number(Tags,'lanes',N) and (N>0);
  if not HT then
  begin
    N:=ReadWidths('width:lanes'); HT:=N>0;
    if not HF then begin F:=ReadWidths('width:lanes:forward'); HF:=F>0 end;
    if not HB then begin B:=ReadWidths('width:lanes:backward'); HB:=B>0 end;
    if not HT then
      if HF and HB then N:=F+B+C
      else if HF then N:=Max(D,F+C+Ord(not OneWay))
      else if HB then N:=Max(D,B+C+Ord(not OneWay))
      else N:=D;
  end;
  N:=EnsureRange(N,1,ROAD_MAX_LANES);
  if OneWay then
  begin
    C:=0;
    if Reverse then begin F:=0; if HB and not HT then N:=Max(1,B); B:=N end
    else begin B:=0; if HF and not HT then N:=Max(1,F); F:=N end;
  end else
  begin
    C:=Min(C,N-1);
    if HF and HB then begin N:=EnsureRange(F+B+C,1,ROAD_MAX_LANES); C:=Min(C,N-1) end;
    if not HF and not HB then begin F:=(N-C+1) div 2; B:=N-C-F end
    else if not HF then begin B:=Min(B,N-C); F:=N-C-B end
    else if not HB then begin F:=Min(F,N-C); B:=N-C-F end;
    F:=Min(F,N-C); B:=Min(B,N-C-F);
    if F+B+C=0 then F:=1;
    N:=F+B+C;
  end;
  if (not Vehicle) and (H<>'cycleway') then begin N:=1; F:=1; B:=0; C:=0 end;
  ForwardLanes:=F; BackwardLanes:=B; Layout.Count:=N; Layout.BothWays:=C;
  for I:=0 to N-1 do Layout.Widths[I]:=Lane;
  HasWidths:=False;
  // Road U runs right-to-left relative to the OSM way. Directional OSM
  // lists run left-to-right in their own direction of travel.
  ApplyWidths('width:lanes',0,N,not Reverse);
  ApplyWidths('width:lanes:forward',0,F,True);
  ApplyWidths('width:lanes:both_ways',F,C,True);
  ApplyWidths('width:lanes:backward',F+C,B,False);
  Total:=0; for I:=0 to N-1 do Total:=Total+Layout.Widths[I];
  ExplicitWidth:=Meters(Tags,'width');
  if ExplicitWidth=0 then ExplicitWidth:=Meters(Tags,'width:carriageway');
  if (ExplicitWidth=0) and not HasWidths then ExplicitWidth:=Meters(Tags,'est_width');
  if ExplicitWidth>0 then
  begin
    Result:=ExplicitWidth;
    // Preserve surveyed width. With explicit lanes, unused width is edge space;
    // otherwise use the full width instead of silently removing half a meter.
    if HasWidths and (Result>Total) then Layout.Edge:=(Result-Total)*0.5;
    Scale:=(Result-2*Layout.Edge)/Max(Total,0.001);
    for I:=0 to N-1 do Layout.Widths[I]:=Layout.Widths[I]*Scale;
  end else if (Fixed>0) and not HasWidths then
  begin Result:=Fixed; Layout.Widths[0]:=Fixed end
  else
  begin
    if (H<>'track') and (H<>'raceway') then Layout.Edge:=0.25;
    Result:=Total+2*Layout.Edge;
  end;
  for I:=1 to N-1 do
    if Abs(Layout.Widths[I]-Layout.Widths[0])>0.001 then Layout.Custom:=1;
end;

end.

unit Osm3dArchitectureAtlas;
{$mode objfpc}{$H+}

{ Immutable component atlas. It is shared by procedural facades and authored
  recipes. Presets are expanded once, before validation/baking; never in Update.
  Canonical recipes contain resolved dimensions, not mutable library links. }
interface
uses SysUtils, Math, fpjson, CastleVectors, Osm3dGeoMath;
const
  ARCHITECTURE_ATLAS_VERSION = 1;
  ARCHITECTURE_WINDOW_PATTERNS = 8;
type
  TArchitectureWindowPatterns = array[0..ARCHITECTURE_WINDOW_PATTERNS-1] of TVector4;
function ArchitectureWindowPatterns:TArchitectureWindowPatterns;
function ArchitectureWindowPattern(Seed:Integer; Material:Integer):Integer;
function ArchitectureAtlasPreset(const Name:string; Opening:Boolean):TJSONObject;
function ArchitectureAtlasCatalog:TJSONObject;
function ExpandArchitectureAtlas(Source:TJSONData):TJSONObject;

implementation
uses jsonparser;
const
  WindowNames:array[0..15] of string = (
    'window_single','window_double','window_triple','window_sash',
    'window_transom','window_industrial','window_grid','window_wide_transom',
    'window_round_arch','window_french','window_basement','window_shopfront',
    'door_single','door_double','door_glazed','door_service');
  PartNames:array[0..35] of string = (
    'balcony_vertical','balcony_horizontal','balcony_solid','balcony_glass','balcony_french',
    'entry_flat','entry_pitched','entry_porch','entry_portal','entry_glass',
    'drain_round','drain_square','gutter_round','gutter_box',
    'rail_vertical','rail_horizontal','rail_solid','rail_glass','rail_timber',
    'shutter_louver','shutter_board','shutter_panel',
    'vent_louver','vent_grid','sill_stone','lintel_stone','cornice_plain','cornice_classic',
    'damage_repair','damage_brick','damage_damp','damage_crack','damage_rust',
    'quoin_stone','panel_recess','pilaster_plain');
  FamilyNames:array[0..7] of string = ('urban_plaster','historic','brick',
    'panel','modern','timber','mediterranean','industrial');
  FamilyWindows:array[0..7] of string = ('window_transom','window_sash','window_double',
    'window_triple','window_single','window_grid','window_french','window_industrial');
  FamilyBalconies:array[0..7] of string = ('balcony_vertical','balcony_vertical','balcony_solid',
    'balcony_solid','balcony_glass','balcony_horizontal','balcony_vertical','balcony_horizontal');
  FamilyEntries:array[0..7] of string = ('entry_flat','entry_portal','entry_pitched',
    'entry_flat','entry_glass','entry_porch','entry_pitched','entry_flat');
  FamilyColors:array[0..7] of string = ('#c9bfa9','#d4c8af','#9d7662',
    '#bcbdb5','#b6b7b4','#9b8971','#ded5bd','#a5aaa7');

procedure Require(OK:Boolean; const MessageText:string);
begin if not OK then raise EConvertError.Create('architecture.atlas: '+MessageText) end;
function ObjectValue(J:TJSONData):TJSONObject;
begin Require((J<>nil) and (J.JSONType=jtObject),'object required');Result:=TJSONObject(J) end;
procedure CheckKeys(O:TJSONObject; const Allowed:string);
var I:Integer;
begin for I:=0 to O.Count-1 do Require(Pos('|'+O.Names[I]+'|',Allowed)>0,'unknown field '+O.Names[I]) end;
function Number(O:TJSONObject; const Key:string; Default,Lo,Hi:Double):Double;
var J:TJSONData;
begin
  J:=O.Find(Key);if J=nil then Exit(Default);
  Require(J.JSONType=jtNumber,Key+' must be a number');Result:=J.AsFloat;
  Require(not IsNan(Result) and not IsInfinite(Result) and (Result>=Lo) and (Result<=Hi),Key+' out of range');
end;
function Flag(O:TJSONObject; const Key:string; Default:Boolean):Boolean;
var J:TJSONData;
begin J:=O.Find(Key);if J=nil then Exit(Default);Require(J.JSONType=jtBoolean,Key+' must be boolean');Result:=J.AsBoolean end;
function TextValue(O:TJSONObject; const Key,Default:string):string;
var J:TJSONData;
begin J:=O.Find(Key);if J=nil then Exit(Default);Require(J.JSONType=jtString,Key+' must be text');Result:=J.AsString end;
procedure Merge(Target,Source:TJSONObject; const Skip:string='');
var I:Integer; N:string;
begin
  for I:=0 to Source.Count-1 do begin
    N:=Source.Names[I];if Pos('|'+N+'|',Skip)>0 then Continue;
    Target.Delete(N);Target.Add(N,Source.Items[I].Clone);
  end;
end;

function ArchitectureWindowPatterns:TArchitectureWindowPatterns;
begin
  { Vertical/horizontal divider counts, optional single transom height, spare.
    The very same table is uploaded to GLSL; no second hard-coded bar layout. }
  Result[0]:=Vector4(0,0,0,0);Result[1]:=Vector4(1,0,0,0);
  Result[2]:=Vector4(2,0,0,0);Result[3]:=Vector4(0,1,0,0);
  Result[4]:=Vector4(1,0,0.72,0);Result[5]:=Vector4(1,2,0,0);
  Result[6]:=Vector4(2,2,0,0);Result[7]:=Vector4(2,0,0.68,0);
end;
function ArchitectureWindowPattern(Seed:Integer; Material:Integer):Integer;
begin
  Result:=Seed mod ARCHITECTURE_WINDOW_PATTERNS;
  if Result<0 then Inc(Result,ARCHITECTURE_WINDOW_PATTERNS);
  if Material=1 then Result:=3+((Seed mod 4)+4) mod 4;
end;

function ArchitectureAtlasPreset(const Name:string; Opening:Boolean):TJSONObject;
var I,ID:Integer; Pattern:TVector4; Patterns:TArchitectureWindowPatterns;
  procedure S(const K,V:string);begin Result.Delete(K);Result.Add(K,V) end;
  procedure N(const K:string; V:Double);begin Result.Delete(K);Result.Add(K,V) end;
begin
  ID:=-1;
  if Opening then begin
    for I:=0 to High(WindowNames) do if Name=WindowNames[I] then ID:=I;
    Require(ID>=0,'unknown opening preset '+Name);
    Result:=TJSONObject.Create(['kind','window','width_m',1.4,'height_m',1.8,
      'recess_m',0.16,'frame_width_m',0.07,'frame_depth_m',0.045,
      'frame_color','#ded9cc','pane_color','#26353d','mullions_x',1,'mullions_y',0]);
    if ID<8 then begin
      Patterns:=ArchitectureWindowPatterns;Pattern:=Patterns[ID];
      N('mullions_x',Pattern.X);N('mullions_y',Pattern.Y);
      if Pattern.Z>0 then N('transom_at',Pattern.Z);
      if ID in [2,7] then N('width_m',2.0);
      if ID in [5,6] then begin N('width_m',2.2);N('height_m',2.2);S('frame_color','#515957') end;
    end;
    case ID of
      8:begin S('shape','round_arch');N('arch_rise_m',0.65);N('height_m',2.3);N('mullions_y',1) end;
      9:begin N('width_m',1.2);N('height_m',2.3);N('mullions_y',1) end;
      10:begin N('width_m',1.0);N('height_m',0.6);N('recess_m',0.24);N('mullions_x',0) end;
      11:begin N('width_m',3.4);N('height_m',2.8);N('mullions_x',2);S('frame_color','#434b4d') end;
      12..15:begin
        S('kind','door');N('width_m',1.05);N('height_m',2.2);N('mullions_x',0);
        S('pane_color','#525a54');N('frame_width_m',0.06);
        if ID=13 then begin N('width_m',1.8);N('mullions_x',1) end;
        if ID=14 then begin N('width_m',1.8);N('mullions_x',1);N('transom_at',0.78);Result.Add('glazed',True) end;
        if ID=15 then begin N('width_m',1.3);S('pane_color','#6a6c67') end;
      end;
    end;
    Exit;
  end;
  for I:=0 to High(PartNames) do if Name=PartNames[I] then ID:=I;
  Require(ID>=0,'unknown component preset '+Name);
  Result:=TJSONObject.Create(['kind','block','width_m',1.8,'height_m',1.0,
    'depth_m',0.8,'color','#b8b4a7','roughness',0.82]);
  case ID of
    0..4:begin
      S('kind','balcony');N('height_m',1.12);N('depth_m',1.0);S('style','vertical');
      if ID=1 then S('style','horizontal');if ID=2 then S('style','solid');
      if ID=3 then S('style','glass');
      if ID=4 then begin S('kind','railing');S('style','vertical');N('depth_m',0.16) end;
    end;
    5..9:begin
      S('kind','entrance');N('width_m',2.2);N('height_m',2.5);N('depth_m',1.1);S('style','flat');
      if ID=6 then S('style','pitched');if ID=7 then begin S('style','porch');N('depth_m',1.4) end;
      if ID=8 then S('style','portal');if ID=9 then S('style','glass');
    end;
    10..11:begin
      S('kind','downpipe');N('width_m',0.10);N('height_m',8);N('depth_m',0.30);
      N('segments',6);N('roughness',0.55);S('color','#646c69');S('style','round');
      if ID=11 then S('style','square');
    end;
    12..13:begin
      S('kind','gutter');N('width_m',8);N('height_m',0.15);N('depth_m',0.18);
      S('color','#646c69');N('roughness',0.55);S('style','round');
      if ID=13 then S('style','box');
    end;
    14..18:begin
      S('kind','railing');N('height_m',1.05);N('depth_m',0.08);S('style','vertical');
      S('color','#666965');if ID=15 then S('style','horizontal');
      if ID=16 then S('style','solid');if ID=17 then S('style','glass');
      if ID=18 then begin S('style','timber');S('color','#796956') end;
    end;
    19..21:begin
      S('kind','shutter');N('width_m',0.52);N('height_m',1.8);N('depth_m',0.055);
      S('color','#596c5d');S('style','louver');if ID=20 then S('style','board');if ID=21 then S('style','panel');
    end;
    22..23:begin
      S('kind','vent');N('width_m',0.65);N('height_m',0.45);N('depth_m',0.06);
      S('color','#606761');S('style','louver');if ID=23 then S('style','grid');
    end;
    24:begin N('height_m',0.10);N('depth_m',0.22) end;
    25:begin N('height_m',0.18);N('depth_m',0.12) end;
    26..27:begin
      S('kind','cornice');N('width_m',8);N('height_m',0.25);N('depth_m',0.25);
      if ID=26 then Result.Add('profile',GetJSON('[[0,0.6],[0.4,0.6],[0.4,1],[1,1]]'));
    end;
    28..32:begin
      S('kind','damage');N('width_m',1.2);N('height_m',0.7);N('depth_m',0.025);
      N('roughness',0.96);S('style','repair');S('color','#aaa592');
      if ID=29 then begin S('style','brick');S('color','#966d53') end;
      if ID=30 then begin S('style','damp');N('width_m',0.4);N('height_m',1.5);S('color','#747a65') end;
      if ID=31 then begin S('style','crack');N('width_m',0.14);N('height_m',1.3);S('color','#797568') end;
      if ID=32 then begin S('style','rust');N('width_m',0.3);N('height_m',1.0);S('color','#885d43') end;
    end;
    33:begin S('kind','quoins');N('width_m',0.6);N('height_m',6);N('depth_m',0.14) end;
    34:begin S('kind','wall_panel');N('width_m',1.3);N('height_m',0.9);N('depth_m',0.08) end;
    35:begin S('kind','pilaster');N('width_m',0.7);N('height_m',6);N('depth_m',0.18) end;
  end;
end;

function ArchitectureAtlasCatalog:TJSONObject;
var A,B,F:TJSONArray; I:Integer; P:TJSONObject;
begin
  A:=TJSONArray.Create;B:=TJSONArray.Create;F:=TJSONArray.Create;
  Result:=TJSONObject.Create(['version',ARCHITECTURE_ATLAS_VERSION,'openings',A,'components',B,'families',F]);
  for I:=0 to High(WindowNames) do begin P:=ArchitectureAtlasPreset(WindowNames[I],True);P.Add('id',WindowNames[I]);A.Add(P) end;
  for I:=0 to High(PartNames) do begin P:=ArchitectureAtlasPreset(PartNames[I],False);P.Add('id',PartNames[I]);B.Add(P) end;
  for I:=0 to High(FamilyNames) do F.Add(TJSONObject.Create(['id',FamilyNames[I],
    'window',FamilyWindows[I],'balcony',FamilyBalconies[I],'entry',FamilyEntries[I],
    'wall_color',FamilyColors[I]]));
  Result.Add('assembly','Optional root/facade assembly: family, floors (1..20), floor_height_m (2.3..6), bay_width_m (1.8..8), entrance, balconies, drainage, weathering booleans, seed integer, window/door/balcony preset overrides. Explicit rows/components, including [], replace generated entries. Unspecified facades stay automatic. Roof and terrain remain the existing building pipeline.');
  Result.Add('presets','row/component preset fills defaults only; explicit dimensions and colors win. Canonical recipes expand presets/assembly. Existing version-1 recipes stay valid.');
  Result.Add('rules','Use common style within a section; ground and eave positions are metres. Exterior drains need a verified eave, weathering is opt-in in prepared assembly. Doors and entrance accessories are separate. A loggia requires facade inset, an arch passage requires passages. No rooms or random new building wings.');
end;

procedure ExpandItems(F:TJSONObject; const Key:string; Opening:Boolean);
var A:TJSONArray; I:Integer; O,P:TJSONObject; Name:string;
begin
  if F.Find(Key)=nil then Exit;
  Require(F.Find(Key).JSONType=jtArray,Key+' must be an array');A:=TJSONArray(F.Find(Key));
  for I:=0 to A.Count-1 do begin
    O:=ObjectValue(A[I]);if O.Find('preset')=nil then Continue;
    Name:=TextValue(O,'preset','');P:=ArchitectureAtlasPreset(Name,Opening);
    try
      Merge(P,O,'|preset|');O.Clear;Merge(O,P);
    finally P.Free end;
  end;
end;

procedure AssembleFace(F,Options:TJSONObject; FaceIndex:Integer);
var I,J,Family,Floors,Bays,DoorBay,Seed:Integer; X,LengthM,FH,Pitch,WW,WH,Y,Top:Double;
  P:TLocalProjection; A,B:TJSONArray; D:TVector3; Rows,Parts:TJSONArray;
  O,W:TJSONObject; FamilyName,WinName,DoorName,BalconyName:string;Sill,DoorHeight:Double;
  Entrance,Balconies,GeneratedRows:Boolean;
  procedure AddPart(const Preset:string; X,Y,Width,Height,Depth:Double);
  begin
    O:=ArchitectureAtlasPreset(Preset,False);O.Add('x_m',X);O.Add('bottom_m',Y);
    O.Floats['width_m']:=Width;O.Floats['height_m']:=Height;O.Floats['depth_m']:=Depth;Parts.Add(O);
  end;
begin
  CheckKeys(Options,'|family|floors|floor_height_m|bay_width_m|entrance|balconies|drainage|weathering|seed|window|door|balcony|');
  FamilyName:=TextValue(Options,'family','urban_plaster');Family:=-1;
  for I:=0 to High(FamilyNames) do if FamilyName=FamilyNames[I] then Family:=I;
  Require(Family>=0,'unknown family '+FamilyName);
  X:=Number(Options,'floors',3,1,20);Require(Frac(X)=0,'floors must be integral');Floors:=Round(X);
  FH:=Number(Options,'floor_height_m',3.1,2.3,6);Top:=Floors*FH;
  X:=Number(Options,'seed',0,0,65535);Require(Frac(X)=0,'seed must be integral');Seed:=Round(X);
  Require((F.Find('start')<>nil) and (F.Find('start').JSONType=jtArray),'start coordinate required');
  Require((F.Find('end')<>nil) and (F.Find('end').JSONType=jtArray),'end coordinate required');
  A:=TJSONArray(F.Find('start'));B:=TJSONArray(F.Find('end'));
  Require((A.Count=2) and (B.Count=2),'start/end must be longitude, latitude');
  for I:=0 to 1 do begin
    Require((A[I].JSONType=jtNumber) and (B[I].JSONType=jtNumber),'numeric coordinates required');
    Require(not IsNan(A[I].AsFloat) and not IsInfinite(A[I].AsFloat) and
      not IsNan(B[I].AsFloat) and not IsInfinite(B[I].AsFloat),'finite coordinates required');
    X:=180;if I=1 then X:=85;Require((Abs(A[I].AsFloat)<=X) and (Abs(B[I].AsFloat)<=X),'coordinate out of range');
  end;
  P:=TLocalProjection.Create(TLatLon.Make(A[1].AsFloat,A[0].AsFloat),A[1].AsFloat);
  try D:=P.Project(TLatLon.Make(B[1].AsFloat,B[0].AsFloat),0);LengthM:=D.Length finally P.Free end;
  Require((LengthM>=1) and (LengthM<=300),'facade must be 1..300 m');
  Pitch:=Number(Options,'bay_width_m',3.6,1.8,8);
  Bays:=Min(32,Max(1,Floor(LengthM/Pitch)));Pitch:=LengthM/Bays;
  WinName:=TextValue(Options,'window',FamilyWindows[Family]);
  DoorName:=TextValue(Options,'door','door_single');BalconyName:=TextValue(Options,'balcony',FamilyBalconies[Family]);
  Entrance:=Flag(Options,'entrance',FaceIndex=0) and (LengthM>=2.5);
  Balconies:=Flag(Options,'balconies',False) and (Floors>1) and (Pitch>=2.4);
  DoorBay:=Bays div 2;GeneratedRows:=F.Find('rows')=nil;
  if Balconies and GeneratedRows then begin
    W:=ArchitectureAtlasPreset(BalconyName,False);
    try
      Require((TextValue(W,'kind','')='balcony') or (BalconyName='balcony_french'),
        'balcony override must be a balcony preset');
    finally W.Free end;
  end;
  DoorHeight:=Min(2.2,FH-0.4);
  if F.Find('wall_color')=nil then F.Add('wall_color',FamilyColors[Family]);
  if F.Find('wall_material')=nil then begin
    if Family=2 then F.Add('wall_material','brick');if Family=5 then F.Add('wall_material','wood');
  end;
  if GeneratedRows then begin
    Rows:=TJSONArray.Create;F.Add('rows',Rows);
    W:=ArchitectureAtlasPreset(WinName,True);
    try
      WW:=Min(Number(W,'width_m',1.4,0.3,12),Pitch-0.45);WH:=Min(Number(W,'height_m',1.8,0.3,15),FH-0.7);
      Require(TextValue(W,'kind','window')='window','window override must be a window preset');
      Sill:=Min(0.85,FH-WH-0.25);
      if WinName='window_french' then begin WH:=Min(2.3,FH-0.3);Sill:=0.06 end;
      Require(WW>=0.3,'facade too narrow for an opening');
      for I:=0 to Floors-1 do begin
        { Compact rows on each side of the entrance, never overlapping it. }
        J:=0;
        while J<Bays do begin
          if Entrance and (I=0) and (J=DoorBay) then begin
            O:=ArchitectureAtlasPreset(DoorName,True);Rows.Add(O);
            O.Add('x_m',(J+0.5)*Pitch);O.Add('bottom_m',0);
            Require(TextValue(O,'kind','')='door','door override must be a door preset');
            O.Floats['height_m']:=Min(O.Floats['height_m'],DoorHeight);
            O.Floats['width_m']:=Min(O.Floats['width_m'],Pitch-0.5);Inc(J);Continue;
          end;
          O:=TJSONObject(W.Clone);O.Add('x_m',(J+0.5)*Pitch);
          O.Add('bottom_m',I*FH+Sill);O.Floats['width_m']:=WW;O.Floats['height_m']:=WH;
          if O.Find('arch_rise_m')<>nil then O.Floats['arch_rise_m']:=Min(O.Floats['arch_rise_m'],WH*0.45);
          O.Add('step_m',Pitch);
          if Entrance and (I=0) and (J<DoorBay) then begin O.Add('count',DoorBay-J);J:=DoorBay end
          else begin O.Add('count',Bays-J);J:=Bays end;
          Rows.Add(O);
        end;
      end;
    finally W.Free end;
  end;
  if F.Find('components')<>nil then Exit;
  Parts:=TJSONArray.Create;F.Add('components',Parts);
  if Family=1 then AddPart('cornice_classic',LengthM*0.5,Top-0.22,LengthM,0.22,0.28)
  else AddPart('cornice_plain',LengthM*0.5,Top-0.16,LengthM,0.16,0.18);
  if Entrance and GeneratedRows then
    AddPart(FamilyEntries[Family],(DoorBay+0.5)*Pitch,0,Min(Pitch-0.25,2.3),DoorHeight+0.28,1.1);
  if Balconies and GeneratedRows then
    for I:=1 to Floors-1 do for J:=0 to Bays-1 do if ((J+Seed) mod 2)=0 then begin
      Y:=I*FH+Sill-0.14;
      { French railings are valid on a window; full platforms need a tall
        opening. Ordinary windows never pretend to be balcony doors. }
      if (WinName='window_french') and (BalconyName<>'balcony_french') then
        AddPart(BalconyName,(J+0.5)*Pitch,Y,Min(Pitch-0.5,1.8),1.12,1.0)
      else AddPart('balcony_french',(J+0.5)*Pitch,Y,Min(WW+0.18,Pitch-0.35),1.0,0.16);
    end;
  if Flag(Options,'drainage',False) and (LengthM>3) then begin
    AddPart('gutter_round',LengthM*0.5,Top-0.13,LengthM,0.13,0.18);
    AddPart('drain_round',0.22,0.12,0.10,Top-0.25,0.30);
  end;
  if Flag(Options,'weathering',False) and GeneratedRows and (LengthM>4) then begin
    AddPart('damage_repair',0.65,0.25,0.7,0.35,0.025);
    if Flag(Options,'drainage',False) then AddPart('damage_damp',0.24,0.18,0.23,1.4,0.025);
  end;
end;

function ExpandArchitectureAtlas(Source:TJSONData):TJSONObject;
var Faces:TJSONArray; I:Integer; F,O,RootOptions:TJSONObject;
begin
  Result:=TJSONObject(ObjectValue(Source).Clone);
  try
    RootOptions:=nil;
    if Result.Find('assembly')<>nil then RootOptions:=ObjectValue(Result.Find('assembly'));
    if Result.Find('facades')<>nil then begin
      Require(Result.Find('facades').JSONType=jtArray,'facades must be an array');
      Faces:=TJSONArray(Result.Find('facades'));Require(Faces.Count<=16,'at most 16 facades');
      for I:=0 to Faces.Count-1 do begin
        F:=ObjectValue(Faces[I]);
        if (RootOptions<>nil) or (F.Find('assembly')<>nil) then begin
          O:=TJSONObject.Create;
          try
            if RootOptions<>nil then Merge(O,RootOptions);
            if F.Find('assembly')<>nil then Merge(O,ObjectValue(F.Find('assembly')));
            AssembleFace(F,O,I);F.Delete('assembly');
          finally O.Free end;
        end;
        ExpandItems(F,'rows',True);ExpandItems(F,'components',False);
      end;
    end;
    Result.Delete('assembly');
  except Result.Free;raise end;
end;
end.

unit Osm3dArchitecture;
{$mode objfpc}{$H+}{$modeswitch advancedrecords}

{ A small, bounded architectural grammar. Units are metres, local X follows
  the directed facade, Y is up, Z points out of the building. It emits into
  the ordinary building mesh: no scene node, material or draw call per item.
  The immutable recipe is consumed by the tile worker, never by Update.

  Baked surface wire format (existing lossless float UV channel):
    U = RGB24 integer; V = -(1000000 + roughnessByte + metalByte*256 +
                             surfaceKind*65536).
  Values are exact float32 integers. All corners of a triangle agree; the
  building vertex shader forwards the payload with flat interpolation.
  This leaves ordinary UVs and the v3 tile container unchanged. }
interface
uses Classes, SysUtils, Math, fpjson, CastleVectors, Osm3dGeoMath, Osm3dGeomMesh,
  Osm3dArchitectureVoids, Osm3dArchitectureAtlas;
const
  ARCHITECTURE_TAG = 'rezvivo:architecture';
  ARCHITECTURE_GENERATOR = 10;
  ARCHITECTURE_UV_MARKER = -1000000;
type
  TArchProfile = array of TVector2; { height fraction, projection fraction }
  TArchComponentKind = (acBlock, acPilaster, acColumn, acCornice, acPediment,
    acCanopy, acSteps, acBalcony, acArch, acDrum, acDome, acSpire, acGableRoof,
    acCapital, acPedimentFrame, acDentilCourse, acRosette, acWallPanel, acQuoins,
    acRailing, acDownpipe, acGutter, acShutter, acVent, acEntrance, acDamage);
  TArchComponent = record
    Kind: TArchComponentKind;
    X,Y,Z,W,H,D,Step: Single;
    Count,Segments,Anchor: Integer; { anchor: ground / eave / ridge }
    Color: Cardinal;
    Roughness,Metallic: Single;
    Spacing: Single;
    Style: Integer; { capital: 0 doric, 1 ionic, 2 foliate }
    ShaftOnly: Boolean;
    Profile:TArchProfile;
  end;
  TArchComponents = array of TArchComponent;
  TArchOpening = record
    X,Y,W,H,Rise,Recess,FrameWidth,FrameDepth: Single;
    MullionsX,MullionsY: Integer;
    Door, Glazed: Boolean;
    Transom: Single;
    FrameColor,PaneColor: Cardinal;
  end;
  TArchOpenings = array of TArchOpening;
  TArchFacade = record
    Start,Finish: TLatLon;
    A,B: TVector3;
    WallColor: Cardinal;
    Roughness,Metallic,Inset: Single;
    MaterialKind: Integer; { 0 painted/plain; 2 timber boards; 3 brick }
    Openings: TArchOpenings;
    Components: TArchComponents;
    function Axis: TVector3;
    function Normal: TVector3;
    function LengthM: Single;
    function Matches(const P,N:TVector3):Boolean;
  end;
  TArchFacades = array of TArchFacade;
  TArchitectureRecipe = record
    Landmark: Boolean;
    HasGroundAnchor: Boolean;
    GroundAnchor: TLatLon;
    GroundOffset: Single;
    Facades: TArchFacades;
    Passages: TArchitecturePassages;
  end;
  TArchCaster = record
    Corners: array[0..3] of TVector3;
    BaseY,MaxY: Single;
    BlocksGround: Boolean;
  end;
  TArchCasters = array of TArchCaster;

function ArchitectureCapabilities:TJSONObject;
function CanonicalArchitecture(J:TJSONData):string;
function ParseArchitecture(J:TJSONData):TArchitectureRecipe;
procedure ProjectArchitecture(var R:TArchitectureRecipe; P:TLocalProjection;
  const Footprint:array of TVector3;const InnerRings:TArchitectureVoidRings=nil);
function EmitArchitecturalWall(const Facades:TArchFacades; const A,B,N:TVector3;
  Top:Single; Mesh:TMesh):Boolean;
procedure EmitArchitecturalParts(const R:TArchitectureRecipe; Base,Eave,Ridge:Single;
  Mesh:TMesh; out Casters:TArchCasters);
function ArchitectureUV(Color:Cardinal; Roughness,Metallic:Single; Kind:Integer=0):TVector2;
function IsArchitectureUV(const UV:TVector2):Boolean; inline;

implementation
const KindNames:array[TArchComponentKind] of string = ('block','pilaster','column',
  'cornice','pediment','canopy','steps','balcony','arch','drum','dome','spire','gable_roof',
  'capital','pediment_frame','dentil_course','rosette','wall_panel','quoins',
  'railing','downpipe','gutter','shutter','vent','entrance','damage');
type
  TPoints2 = array of TVector2;
  TFloats = array of Single;
  TArchEmitter = class
    Mesh:TMesh;
    O,U,N:TVector3;
    MinP,MaxP:TVector3;
    UV:TVector2;
    function World(X,Y,Z:Single):TVector3;
    procedure Tri(const A,B,C,Normal:TVector3);
    procedure Quad(const A,B,C,D,Normal:TVector3);
    procedure Panel(const P:TPoints2; Z:Single; Front:Boolean);
    procedure Prism(const P:TPoints2; Z0,Z1:Single);
    procedure Box(X0,Y0,X1,Y1,Z0,Z1:Single);
    procedure Revolve(X,Y,Z:Single; const Radius,Heights:array of Single; Segments:Integer; DepthScale:Single=1);
    procedure Cornice(X,Y,Z,W,H,D:Single; const Profile:TArchProfile);
    procedure Ring(const Outer,Inner:TPoints2; Z0,Z1:Single);
    procedure Medallion(X,Y,Z,W,H,D:Single; Segments,Lobes:Integer);
    procedure Decoration(const C:TArchComponent; X,Y,Z:Single);
    procedure Tube(const A,B:TVector3; Radius:Single; Sides:Integer);
    procedure Railing(X0,Z0,X1,Z1,Y,H:Single; Style:Integer; Color:Cardinal; Roughness:Single);
    procedure AtlasPart(const C:TArchComponent; X,Y,Z:Single);
  end;

function ComponentStyles(Kind:TArchComponentKind):string;
begin
  case Kind of
    acCapital:Result:='doric|ionic|foliate';
    acBalcony,acRailing:Result:='vertical|horizontal|solid|glass|timber';
    acDownpipe:Result:='round|square';
    acGutter:Result:='round|box';
    acShutter:Result:='louver|board|panel';
    acVent:Result:='louver|grid';
    acEntrance:Result:='flat|pitched|porch|portal|glass';
    acDamage:Result:='repair|brick|damp|crack|rust';
    else Result:='';
  end;
end;
function ComponentStyleName(Kind:TArchComponentKind; Index:Integer):string;
var Names:TStringArray;
begin
  Names:=ComponentStyles(Kind).Split('|');Result:='';
  if (Index>=0) and (Index<Length(Names)) then Result:=Names[Index];
end;

procedure Check(B:Boolean; const S:string);
begin if not B then raise EConvertError.Create('building.architecture: '+S) end;
function Obj(J:TJSONData):TJSONObject;
begin Check((J<>nil) and (J.JSONType=jtObject),'object required'); Result:=TJSONObject(J) end;
function Arr(J:TJSONData; Limit:Integer):TJSONArray;
begin
  Check((J<>nil) and (J.JSONType=jtArray),'array required');Result:=TJSONArray(J);
  Check(Result.Count<=Limit,'array exceeds '+IntToStr(Limit));
end;
procedure Keys(J:TJSONObject; const Allowed:string);
var I:Integer;
begin for I:=0 to J.Count-1 do Check(Pos('|'+J.Names[I]+'|',Allowed)>0,'unknown field '+J.Names[I]) end;
function Num(O:TJSONObject; const Name:string; Default,Lo,Hi:Double):Double;
var J:TJSONData;
begin
  J:=O.Find(Name);Result:=Default;if J=nil then Exit;
  Check(J.JSONType=jtNumber,Name+' must be numeric');Result:=J.AsFloat;
  Check(not IsNan(Result) and not IsInfinite(Result) and (Result>=Lo) and (Result<=Hi),Name+' out of range');
end;
function Int(O:TJSONObject; const Name:string; Default,Lo,Hi:Integer):Integer;
var V:Double;
begin V:=Num(O,Name,Default,Lo,Hi);Check(Frac(V)=0,Name+' must be integral');Result:=Round(V) end;
function Str(O:TJSONObject; const Name,Default:string):string;
var J:TJSONData;
begin J:=O.Find(Name);if J=nil then Exit(Default);Check(J.JSONType=jtString,Name+' must be a string');Result:=J.AsString end;
function Color(O:TJSONObject; const Name,Default:string):Cardinal;
var S:string; I:Integer;
begin
  S:=Str(O,Name,Default);Check((Length(S)=7) and (S[1]='#'),Name+' must be #RRGGBB');
  for I:=2 to 7 do Check(S[I] in ['0'..'9','a'..'f','A'..'F'],Name+' must be #RRGGBB');
  Result:=StrToInt('$'+Copy(S,2,6));
end;
function Hex(C:Cardinal):string;
begin Result:='#'+LowerCase(IntToHex(C,6)) end;
function Geo(J:TJSONData):TLatLon;
var A:TJSONArray; Lon,Lat:Double;
begin
  A:=Arr(J,2);Check(A.Count=2,'start/end must be [longitude, latitude]');
  Check((A[0].JSONType=jtNumber) and (A[1].JSONType=jtNumber),'numeric coordinates required');
  Lon:=A[0].AsFloat;Lat:=A[1].AsFloat;
  Check(not IsNan(Lon) and not IsNan(Lat) and (Abs(Lon)<=180) and (Abs(Lat)<=85),'invalid coordinate');
  Result:=TLatLon.Make(Lat,Lon);
end;

function ArchitectureCapabilities:TJSONObject;
var A:TJSONArray; K:TArchComponentKind;
begin
  A:=TJSONArray.Create;for K:=Low(K) to High(K) do A.Add(KindNames[K]);
  Result:=TJSONObject.Create(['version',1,'generator',ARCHITECTURE_GENERATOR,'components',A,
    'facades','start/end [lon,lat] in either order; local x along the supplied edge, y up, z outward. Exterior orientation is resolved from the footprint without moving openings. wall_color, wall_material plain/wood/brick, roughness, metallic, inset_m (0..6, recessed wall behind a portico, closed sides/floor/ceiling). Exact metre dimensions; no automatic stretching.',
    'rows','x_m = first opening centre; bottom_m, width_m, height_m, count, step_m; shape rectangle/round_arch, arch_rise_m; kind window/door; recess_m, frame_width_m, frame_depth_m, frame_color, pane_color, mullions_x/y (divider counts). Omitted rows means blank wall.',
    'cornices','Component cornice: x_m=center, bottom_m, width_m, height_m, depth_m, offset_m, color. Optional profile: 2..16 [height_fraction,projection_fraction] pairs in 0..1; nondecreasing heights, first 0, last 1. Repeat a height for a horizontal ledge. Default three-step moulding. Repeats use count/step_m.',
    'parts','components per facade; kind, x_m, bottom_m, offset_m, width_m, height_m, depth_m, color, roughness, metallic, anchor ground/eave/ridge, count/step_m, segments. Combine columns + canopy + pediment for a portico; drum + dome/spire for a roof landmark.',
    'decoration','capital: style doric/ionic/foliate (simplified leaf relief, not an exact sculptural copy), independent width/depth; column shaft_only=true omits its plain end blocks when adding a separate capital. pediment_frame: hollow triangular moulding; dentil_course: small blocks spaced horizontally by spacing_m; rosette: radial relief; wall_panel: raised rectangular frame with a recessed closed centre; quoins: alternating-width corner blocks spaced vertically by spacing_m. All use the same bounded component dimensions, colours and repetitions. Decoration stays in the building mesh.',
    'limits','16 facades, 32 row descriptions/facade, 512 expanded openings, 256 expanded parts/building; conservative cost budget 32768 triangles, 65536 for significance=landmark; rejects overlaps and excessive cost before activation.',
    'cache','Baked in ordinary building meshes with original OSM picking id; same material batch, culling, raster/RTX shadow geometry and compressed binary cache.',
    'ground','Optional ground_anchor [lon,lat] within 8 m of a confirmed facade, plus ground_offset_m (0..3, default 0). Samples the common terrain at a photographed entrance/forecourt to set the building base, instead of raising every floor to the highest ground under a rear wing. Record the evidence and uncertainty; no terrain flattening or absolute survey height is implied. Omit when the ground contact is unknown.',
    'passages','Optional passages array (max 8): kind through/recess; start/end [lon,lat] at the entry/exit centre or niche back; width_m, height_m, bottom_m (default 0); shape rectangle/round_arch, arch_rise_m; wall_color, floor_color, roughness. Straight constant-section cavities, within the existing OSM envelope and below the eave. Actual wall, plinth and decoration geometry is cut; sides and vault are baked once. Ground-level passages use the retained terrain/road as their floor, extend jambs below it and remove only the corridor from building obstacles. Raised openings (bottom_m > 0) have their own floor/sill with floor_color. OSM endpoints and dimensions must be photo/OSM justified.',
    'not_supported','Free-form sculpture, damaged topology and unseen rooms. An arch component is a frame; use passages for a real hole. Window/door openings have real recesses and closed panes.']);
  Result.Add('atlas',ArchitectureAtlasCatalog);
end;

function TArchFacade.LengthM:Single;
begin Result:=(B-A).Length end;
function TArchFacade.Axis:TVector3;
begin Result:=(B-A).Normalize end;
function TArchFacade.Normal:TVector3;
begin Result:=TVector3.CrossProduct(Axis,Vector3(0,1,0)) end;
function TArchFacade.Matches(const P,N:TVector3):Boolean;
var D:TVector3;X:Single;
begin
  D:=P-A;D.Y:=0;X:=TVector3.DotProduct(D,Axis);
  Result:=(TVector3.DotProduct(N,Normal)>0.995) and
    (Abs(TVector3.DotProduct(D,Normal))<0.25) and (X>=-0.25) and (X<=LengthM+0.25);
end;

function ParseExpandedArchitecture(J:TJSONData):TArchitectureRecipe;
var Root,F,O:TJSONObject; Faces,Rows,Parts,Profile,Point:TJSONArray; I,J0,K,C,V,T,Cost,OpenCount,PartCount:Integer;
    R:TArchOpening; P:TArchComponent; S:string; X,Step,L0,L1:Single; Proj:TLocalProjection; Delta:TVector3;
    Kind:TArchComponentKind; AnchorPoint,Edge,Nearest:TVector3; Distance,T0:Single;
begin
  Result:=Default(TArchitectureRecipe);Root:=Obj(J);Keys(Root,'|version|significance|facades|passages|ground_anchor|ground_offset_m|');
  Check(Int(Root,'version',0,1,1)=1,'version 1 required');
  S:=Str(Root,'significance','ordinary');Check((S='ordinary') or (S='landmark'),'invalid significance');
  Result.Landmark:=S='landmark';Faces:=Arr(Root.Find('facades'),16);
  Result.Passages:=ParseArchitecturePassages(Root.Find('passages'));
  Result.HasGroundAnchor:=Root.Find('ground_anchor')<>nil;
  if Result.HasGroundAnchor then begin
    Result.GroundAnchor:=Geo(Root.Find('ground_anchor'));
    Result.GroundOffset:=Num(Root,'ground_offset_m',0,0,3);
    Check(Faces.Count>0,'ground_anchor needs a confirmed facade');
  end else Check(Root.Find('ground_offset_m')=nil,'ground_offset_m requires ground_anchor');
  Check((Faces.Count>0) or (Length(Result.Passages)>0),'at least one facade or passage is required');
  SetLength(Result.Facades,Faces.Count);
  Cost:=Length(Result.Passages)*2000;OpenCount:=0;PartCount:=0;
  for I:=0 to Faces.Count-1 do with Result.Facades[I] do begin
    F:=Obj(Faces[I]);Keys(F,'|start|end|wall_color|wall_material|roughness|metallic|inset_m|rows|components|');
    Start:=Geo(F.Find('start'));Finish:=Geo(F.Find('end'));
    Proj:=TLocalProjection.Create(Result.Facades[0].Start,Result.Facades[0].Start.Lat);
    try A:=Proj.Project(Start,0);B:=Proj.Project(Finish,0) finally Proj.Free end;
    Check((LengthM>=1) and (LengthM<=300),'facade must be 1..300 m');
    for J0:=0 to I-1 do if Abs(TVector3.DotProduct(Normal,Result.Facades[J0].Normal))>0.995 then begin
      Delta:=A-Result.Facades[J0].A;
      if Abs(TVector3.DotProduct(Delta,Normal))<0.2 then begin
        L0:=TVector3.DotProduct(Delta,Result.Facades[J0].Axis);
        L1:=TVector3.DotProduct(B-Result.Facades[J0].A,Result.Facades[J0].Axis);
        Check(Min(Max(L0,L1),Result.Facades[J0].LengthM)-Max(Min(L0,L1),0)<0.2,'authored facades overlap');
      end;
    end;
    WallColor:=Color(F,'wall_color','#bdb7a7');Roughness:=Num(F,'roughness',0.85,0.15,1);
    Metallic:=Num(F,'metallic',0,0,1);
    S:=Str(F,'wall_material','plain');Check((S='plain') or (S='wood') or (S='brick'),'wall_material must be plain, wood or brick');
    if S='wood' then MaterialKind:=2;
    if S='brick' then MaterialKind:=3;
    Inset:=Num(F,'inset_m',0,0,6);
    if F.Find('rows')<>nil then begin
      Rows:=Arr(F.Find('rows'),32);
      for K:=0 to Rows.Count-1 do begin
        O:=Obj(Rows[K]);Keys(O,'|x_m|bottom_m|width_m|height_m|count|step_m|kind|shape|arch_rise_m|recess_m|frame_width_m|frame_depth_m|frame_color|pane_color|mullions_x|mullions_y|transom_at|glazed|');
        R:=Default(TArchOpening);X:=Num(O,'x_m',0,0,300);R.Y:=Num(O,'bottom_m',1,0,200);
        R.W:=Num(O,'width_m',1.4,0.3,12);R.H:=Num(O,'height_m',1.8,0.3,15);
        S:=Str(O,'kind','window');Check((S='window') or (S='door'),'invalid opening kind');R.Door:=S='door';
        R.Glazed:=not R.Door;
        if O.Find('glazed')<>nil then begin
          Check(O.Find('glazed').JSONType=jtBoolean,'glazed must be boolean');R.Glazed:=O.Booleans['glazed'];
        end;
        S:=Str(O,'shape','rectangle');Check((S='rectangle') or (S='round_arch'),'invalid opening shape');
        if S='round_arch' then R.Rise:=Num(O,'arch_rise_m',Min(R.W*0.5,R.H*0.5),0.1,Min(R.H-0.1,R.W));
        if S='rectangle' then Check(O.Find('arch_rise_m')=nil,'arch_rise_m requires round_arch');
        R.Recess:=Num(O,'recess_m',0.16,0.02,0.8);R.FrameWidth:=Num(O,'frame_width_m',0.07,0.02,0.4);
        R.FrameDepth:=Num(O,'frame_depth_m',0.045,0.008,0.25);
        R.FrameColor:=Color(O,'frame_color','#ded9cc');R.PaneColor:=Color(O,'pane_color','#26353d');
        R.MullionsX:=Int(O,'mullions_x',1,0,4);R.MullionsY:=Int(O,'mullions_y',0,0,4);
        R.Transom:=Num(O,'transom_at',0,0,0.9);
        Check((R.Transom=0) or ((R.Transom>=0.15) and (R.MullionsY=0)),'transom_at requires zero mullions_y and position 0.15..0.9');
        C:=Int(O,'count',1,1,64);Step:=Num(O,'step_m',R.W+1,0.4,100);
        Check((C=1) or (Step>R.W+2*R.FrameWidth+0.02),'row openings overlap');
        for V:=0 to C-1 do begin
          R.X:=X+V*Step;
          Check((R.X-R.W*0.5-R.FrameWidth>=-0.01) and (R.X+R.W*0.5+R.FrameWidth<=LengthM+0.01),'opening outside facade');
          for T:=0 to High(Openings) do Check(
            (Abs(R.X-Openings[T].X)>=(R.W+Openings[T].W)*0.5+R.FrameWidth+Openings[T].FrameWidth+0.005) or
            (R.Y>=Openings[T].Y+Openings[T].H+Openings[T].FrameWidth+R.FrameWidth+0.005) or
            (Openings[T].Y>=R.Y+R.H+R.FrameWidth+Openings[T].FrameWidth+0.005),'opening rectangles overlap');
          T:=Length(Openings);SetLength(Openings,T+1);Openings[T]:=R;
          Inc(OpenCount);Inc(Cost,90+12*(R.MullionsX+R.MullionsY));
          Check(OpenCount<=512,'more than 512 openings');
          if R.Rise>0 then Inc(Cost,160+32*Rows.Count);
        end;
      end;
    end;
    if F.Find('components')<>nil then begin
      Parts:=Arr(F.Find('components'),64);SetLength(Components,Parts.Count);
      for K:=0 to Parts.Count-1 do begin
        O:=Obj(Parts[K]);Keys(O,'|kind|x_m|bottom_m|offset_m|width_m|height_m|depth_m|color|roughness|metallic|anchor|count|step_m|segments|profile|style|spacing_m|shaft_only|');
        P:=Default(TArchComponent);S:=Str(O,'kind','');C:=-1;
        for Kind:=Low(Kind) to High(Kind) do if S=KindNames[Kind] then C:=Ord(Kind);
        Check(C>=0,'unknown component '+S);P.Kind:=TArchComponentKind(C);
        P.X:=Num(O,'x_m',LengthM*0.5,-8,LengthM+8);P.Y:=Num(O,'bottom_m',0,-1,200);
        P.Z:=Num(O,'offset_m',0,-200,6);P.W:=Num(O,'width_m',1,0.05,300);
        P.H:=Num(O,'height_m',1,0.05,100);P.D:=Num(O,'depth_m',0.2,0.025,200);
        P.Color:=Color(O,'color','#d8d3c4');P.Roughness:=Num(O,'roughness',0.8,0.05,1);P.Metallic:=Num(O,'metallic',0,0,1);
        P.Count:=Int(O,'count',1,1,64);P.Step:=Num(O,'step_m',P.W+1,0.1,300);
        P.Segments:=Int(O,'segments',16,4,32);S:=Str(O,'anchor','ground');
        Check((S='ground') or (S='eave') or (S='ridge'),'invalid anchor');
        if S='eave' then P.Anchor:=1 else if S='ridge' then P.Anchor:=2;
        Check((P.X-P.W*0.5>=-8) and (P.X+(P.Count-1)*P.Step+P.W*0.5<=LengthM+8),'component outside facade span');
        Check(P.Z+P.D<=8,'component projects more than 8 m beyond OSM envelope');
        if P.Kind=acArch then Check(P.H>P.W*0.5,'arch must have positive-height piers');
        if P.Kind=acBalcony then Check((P.H>=0.5) and (P.D>=0.3),'balcony needs a usable railing and slab');
        if P.Kind=acRailing then Check((P.W>=0.25) and (P.H>=0.35),'railing is too small');
        if P.Kind=acDownpipe then Check((P.H>=0.6) and (P.W<=0.4) and (P.D>=P.W*1.6),'downpipe needs room for bends');
        if P.Kind=acGutter then Check((P.W>=0.2) and (P.H<=0.8),'invalid gutter dimensions');
        if P.Kind in [acShutter,acVent] then Check((P.W>=0.2) and (P.H>=0.2),'panel is too small');
        if P.Kind=acEntrance then Check((P.W>=0.8) and (P.H>=1.8) and (P.D>=0.2),'entrance accessory is too small');
        if O.Find('shaft_only')<>nil then begin
          Check((P.Kind=acColumn) and (O.Find('shaft_only').JSONType=jtBoolean),'shaft_only is a column boolean');
          P.ShaftOnly:=O.Booleans['shaft_only'];
        end;
        if O.Find('style')<>nil then begin
          Check(ComponentStyles(P.Kind)<>'','style unsupported for '+KindNames[P.Kind]);
          S:=Str(O,'style','');V:=0;
          while (ComponentStyleName(P.Kind,V)<>'') and (ComponentStyleName(P.Kind,V)<>S) do Inc(V);
          Check(ComponentStyleName(P.Kind,V)=S,'invalid component style '+S);P.Style:=V;
        end;
        if O.Find('spacing_m')<>nil then Check(P.Kind in [acDentilCourse,acQuoins],'spacing_m requires dentil_course or quoins');
        if P.Kind in [acDentilCourse,acQuoins] then begin
          P.Spacing:=Num(O,'spacing_m',0.65,0.1,4);
          X:=P.W;if P.Kind=acQuoins then X:=P.H;
          Check(Ceil(X/P.Spacing)<=96,'decorative course exceeds 96 blocks');
        end;
        if O.Find('profile')<>nil then begin
          Check(P.Kind=acCornice,'profile is only supported by cornice');Profile:=Arr(O.Find('profile'),16);
          Check(Profile.Count>=2,'profile needs at least two stations');SetLength(P.Profile,Profile.Count);
          for V:=0 to Profile.Count-1 do begin
            Point:=Arr(Profile[V],2);Check(Point.Count=2,'profile station is [height,projection]');
            for T:=0 to 1 do begin
              Check(Point[T].JSONType=jtNumber,'profile station must be numeric');X:=Point[T].AsFloat;
              Check(not IsNan(X) and not IsInfinite(X) and (X>=0) and (X<=1),'profile fractions must be 0..1');
              P.Profile[V].Data[T]:=X;
            end;
            if V>0 then Check((P.Profile[V].X>=P.Profile[V-1].X) and
              ((P.Profile[V]-P.Profile[V-1]).Length>0.00001),'profile stations must progress upward');
          end;
          Check((P.Profile[0].X=0) and (P.Profile[High(P.Profile)].X=1),'profile must cover height 0..1');
        end;
        Components[K]:=P;Inc(PartCount,P.Count);Inc(Cost,P.Count*(160+P.Segments*16));
        if P.Kind in [acDentilCourse,acQuoins] then Inc(Cost,P.Count*Ceil(X/P.Spacing)*12);
        if P.Kind in [acBalcony,acRailing] then Inc(Cost,P.Count*12*(Min(64,Ceil(P.W/0.18))+2*Min(64,Ceil(P.D/0.18))+12));
        if P.Kind in [acDownpipe,acShutter,acVent] then Inc(Cost,P.Count*1536);
        Check(PartCount<=256,'more than 256 expanded components');
      end;
    end;
    Inc(Cost,2+Length(Openings)*4);
  end;
  Check(OpenCount<=512,'more than 512 openings');Check(PartCount<=256,'more than 256 expanded components');
  if Result.Landmark then Check(Cost<=65536,'landmark geometry cost exceeds budget')
  else Check(Cost<=32768,'geometry cost exceeds budget; reduce repetition or mark a real landmark');
  if Result.HasGroundAnchor then begin
    Proj:=TLocalProjection.Create(Result.Facades[0].Start,Result.Facades[0].Start.Lat);
    try AnchorPoint:=Proj.Project(Result.GroundAnchor,0) finally Proj.Free end;
    Distance:=1e20;
    for I:=0 to High(Result.Facades) do with Result.Facades[I] do begin
      Edge:=B-A;T0:=EnsureRange(TVector3.DotProduct(AnchorPoint-A,Edge)/Edge.LengthSqr,0,1);
      Nearest:=A+Edge*T0;Distance:=Min(Distance,(AnchorPoint-Nearest).Length);
    end;
    Check(Distance<=8,'ground_anchor must be within 8 m of a facade');
  end;
end;

function ParseArchitecture(J:TJSONData):TArchitectureRecipe;
var Expanded:TJSONObject;
begin
  Expanded:=ExpandArchitectureAtlas(J);
  try Result:=ParseExpandedArchitecture(Expanded) finally Expanded.Free end;
end;

function CanonicalArchitecture(J:TJSONData):string;
var R:TArchitectureRecipe; Root,F,O,SourceRow:TJSONObject; Faces,Rows,Parts,SourceRows,ProfileJSON:TJSONArray;
    I,K,V,Expanded,RepeatCount:Integer; RepeatStep:Single; S:string; Resolved:TJSONObject;
begin
  Resolved:=ExpandArchitectureAtlas(J);
  try
  J:=Resolved;
  R:=ParseExpandedArchitecture(J);Faces:=TJSONArray.Create;S:='ordinary';if R.Landmark then S:='landmark';
  Root:=TJSONObject.Create(['version',1,'significance',S,'facades',Faces]);
  try
    if R.HasGroundAnchor then begin
      Root.Add('ground_anchor',TJSONArray.Create([R.GroundAnchor.Lon,R.GroundAnchor.Lat]));
      Root.Add('ground_offset_m',Double(R.GroundOffset));
    end;
    if Length(R.Passages)>0 then Root.Add('passages',CanonicalArchitecturePassages(Obj(J).Find('passages')));
    for I:=0 to High(R.Facades) do with R.Facades[I] do begin
      Rows:=TJSONArray.Create;Parts:=TJSONArray.Create;
      F:=TJSONObject.Create(['start',TJSONArray.Create([Start.Lon,Start.Lat]),'end',TJSONArray.Create([Finish.Lon,Finish.Lat]),
        'wall_color',Hex(WallColor),'roughness',Double(Roughness),'inset_m',Double(Inset),'rows',Rows,'components',Parts]);Faces.Add(F);
      if Metallic<>0 then F.Add('metallic',Double(Metallic));
      if MaterialKind=2 then F.Add('wall_material','wood');
      if MaterialKind=3 then F.Add('wall_material','brick');
      { Preserve compact repetitions in canonical JSON. Validate above has
        expanded them only for bounds/budget/overlap checks. Normalize each
        supplied row through its first expanded opening. }
      SourceRows:=nil;Expanded:=0;
      if Obj(Arr(Obj(J).Find('facades'),16)[I]).Find('rows')<>nil then
        SourceRows:=Arr(Obj(Arr(Obj(J).Find('facades'),16)[I]).Find('rows'),32);
      if SourceRows<>nil then for K:=0 to SourceRows.Count-1 do with Openings[Expanded] do begin
        SourceRow:=Obj(SourceRows[K]);RepeatCount:=Int(SourceRow,'count',1,1,64);
        RepeatStep:=Num(SourceRow,'step_m',W+1,0.4,100);
        S:='window';if Door then S:='door';
        O:=TJSONObject.Create(['x_m',Double(X),'bottom_m',Double(Y),'width_m',Double(W),'height_m',Double(H),
          'count',RepeatCount,'step_m',Double(RepeatStep),
          'kind',S,'recess_m',Double(Recess),'frame_width_m',Double(FrameWidth),'frame_depth_m',Double(FrameDepth),
          'frame_color',Hex(FrameColor),'pane_color',Hex(PaneColor),'mullions_x',MullionsX,'mullions_y',MullionsY]);
        if Rise>0 then begin O.Add('shape','round_arch');O.Add('arch_rise_m',Double(Rise)) end;
        if Transom>0 then O.Add('transom_at',Double(Transom));
        if Glazed=Door then O.Add('glazed',Glazed);
        Rows.Add(O);Inc(Expanded,RepeatCount);
      end;
      for K:=0 to High(Components) do with Components[K] do begin
        S:='ground';if Anchor=1 then S:='eave' else if Anchor=2 then S:='ridge';
        O:=TJSONObject.Create(['kind',KindNames[Kind],'x_m',Double(X),'bottom_m',Double(Y),'offset_m',Double(Z),
          'width_m',Double(W),'height_m',Double(H),'depth_m',Double(D),'color',Hex(Color),
          'roughness',Double(Roughness),'metallic',Double(Metallic),'anchor',S,'count',Count,'step_m',Double(Step),'segments',Segments]);
        if ComponentStyles(Kind)<>'' then O.Add('style',ComponentStyleName(Kind,Style));
        if Kind in [acDentilCourse,acQuoins] then O.Add('spacing_m',Double(Spacing));
        if ShaftOnly then O.Add('shaft_only',True);
        if Length(Profile)>0 then begin
          ProfileJSON:=TJSONArray.Create;
          for V:=0 to High(Profile) do ProfileJSON.Add(TJSONArray.Create([Double(Profile[V].X),Double(Profile[V].Y)]));
          O.Add('profile',ProfileJSON);
        end;
        Parts.Add(O);
      end;
    end;
    Result:=Root.AsJSON;
  finally Root.Free end;
  finally Resolved.Free end;
end;

procedure ProjectArchitecture(var R:TArchitectureRecipe; P:TLocalProjection;
  const Footprint:array of TVector3;const InnerRings:TArchitectureVoidRings);
var I,J,K,C,V,Count:Integer; N,U,Q,MinP,MaxP:TVector3; Lo,Hi,X,Z:Single; Part:TArchComponent; Fits:Boolean;
    GeoPoint:TLatLon;
begin
  if Length(Footprint)<3 then begin R.Facades:=nil;R.Passages:=nil;R.HasGroundAnchor:=False;Exit end;
  MinP:=Footprint[0];MaxP:=MinP;
  for I:=1 to High(Footprint) do for J:=0 to 2 do begin
    MinP.Data[J]:=Min(MinP.Data[J],Footprint[I].Data[J]);MaxP.Data[J]:=Max(MaxP.Data[J],Footprint[I].Data[J]);
  end;
  K:=0;
  for I:=0 to High(R.Facades) do begin
    R.Facades[I].A:=P.Project(R.Facades[I].Start,0);R.Facades[I].B:=P.Project(R.Facades[I].Finish,0);
    { Photo coordinates can describe an edge in either direction. Align the
      local frame with the actual exterior, preserving world-space placement
      instead of silently dropping openings and decorative components. }
    for J:=0 to High(Footprint) do begin
      N:=TVector3.CrossProduct(Footprint[(J+1) mod Length(Footprint)]-Footprint[J],Vector3(0,1,0)).Normalize;
      if R.Facades[I].Matches(Footprint[J],-N) and
         R.Facades[I].Matches(Footprint[(J+1) mod Length(Footprint)],-N) then begin
        X:=R.Facades[I].LengthM;
        GeoPoint:=R.Facades[I].Start;R.Facades[I].Start:=R.Facades[I].Finish;R.Facades[I].Finish:=GeoPoint;
        Q:=R.Facades[I].A;R.Facades[I].A:=R.Facades[I].B;R.Facades[I].B:=Q;
        for C:=0 to High(R.Facades[I].Openings) do
          R.Facades[I].Openings[C].X:=X-R.Facades[I].Openings[C].X;
        for C:=0 to High(R.Facades[I].Components) do
          R.Facades[I].Components[C].X:=X-R.Facades[I].Components[C].X-
            (R.Facades[I].Components[C].Count-1)*R.Facades[I].Components[C].Step;
        Break;
      end;
    end;
    Lo:=1e20;Hi:=-1e20;U:=R.Facades[I].Axis;
    for J:=0 to High(Footprint) do begin
      N:=TVector3.CrossProduct(Footprint[(J+1) mod Length(Footprint)]-Footprint[J],Vector3(0,1,0)).Normalize;
      if R.Facades[I].Matches(Footprint[J],N) and R.Facades[I].Matches(Footprint[(J+1) mod Length(Footprint)],N) then begin
        Lo:=Min(Lo,TVector3.DotProduct(Footprint[J]-R.Facades[I].A,U));
        Hi:=Max(Hi,TVector3.DotProduct(Footprint[(J+1) mod Length(Footprint)]-R.Facades[I].A,U));
      end;
    end;
    if (Lo<=0.25) and (Hi>=R.Facades[I].LengthM-0.25) then begin
      { The recipe dependency hash covers the OSM envelope + 8 m. Reject
        detached parts outside it instead of polluting unrelated tile caches. }
      Count:=0;N:=R.Facades[I].Normal;
      for C:=0 to High(R.Facades[I].Components) do begin
        Part:=R.Facades[I].Components[C];Fits:=True;
        for V:=0 to 3 do begin
          X:=Part.X-Part.W*0.5;if (V and 1)<>0 then X:=Part.X+(Part.Count-1)*Part.Step+Part.W*0.5;
          Z:=Part.Z;if (V and 2)<>0 then Z:=Z+Part.D;Q:=R.Facades[I].A+U*X+N*Z;
          Fits:=Fits and (Q.X>=MinP.X-8) and (Q.X<=MaxP.X+8) and (Q.Z>=MinP.Z-8) and (Q.Z<=MaxP.Z+8);
        end;
        if Fits then begin R.Facades[I].Components[Count]:=Part;Inc(Count) end;
      end;
      SetLength(R.Facades[I].Components,Count);R.Facades[K]:=R.Facades[I];Inc(K);
    end;
  end;
  SetLength(R.Facades,K);
  if R.HasGroundAnchor then begin
    { Reject stale photo placement when its facade no longer matches OSM.
      Never use a distant terrain sample to shift an unrelated footprint. }
    Q:=P.Project(R.GroundAnchor,0);Lo:=1e20;
    for I:=0 to High(R.Facades) do with R.Facades[I] do begin
      U:=B-A;X:=EnsureRange(TVector3.DotProduct(Q-A,U)/U.LengthSqr,0,1);
      Lo:=Min(Lo,(Q-(A+U*X)).Length);
    end;
    R.HasGroundAnchor:=Lo<=8;
  end;
  ProjectArchitecturePassages(R.Passages,P,Footprint,InnerRings);
end;

function ArchitectureUV(Color:Cardinal; Roughness,Metallic:Single; Kind:Integer):TVector2;
begin Result:=Vector2(Color,ARCHITECTURE_UV_MARKER-Round(Roughness*255)-Round(Metallic*255)*256-Kind*65536) end;
function IsArchitectureUV(const UV:TVector2):Boolean;
begin Result:=UV.Y<=ARCHITECTURE_UV_MARKER end;
function TArchEmitter.World(X,Y,Z:Single):TVector3;
var I:Integer;
begin
  Result:=O+U*X+Vector3(0,Y,0)+N*Z;
  for I:=0 to 2 do begin MinP.Data[I]:=Min(MinP.Data[I],Result.Data[I]);MaxP.Data[I]:=Max(MaxP.Data[I],Result.Data[I]) end;
end;
procedure TArchEmitter.Tri(const A,B,C,Normal:TVector3);
var I,J,K:Integer; Cross:TVector3;
begin
  Cross:=TVector3.CrossProduct(B-A,C-A);if Cross.Length<1e-8 then Exit;
  I:=Mesh.AddVertex(A,Normal,UV);J:=Mesh.AddVertex(B,Normal,UV);K:=Mesh.AddVertex(C,Normal,UV);
  if TVector3.DotProduct(Cross,Normal)>0 then Mesh.AddTriangle(I,J,K) else Mesh.AddTriangle(I,K,J);
end;
procedure TArchEmitter.Quad(const A,B,C,D,Normal:TVector3);
var I,J,K,L:Integer;C0,C1:TVector3;
begin
  C0:=TVector3.CrossProduct(B-A,C-A);C1:=TVector3.CrossProduct(C-A,D-A);
  if (C0.Length<1e-8) or (C1.Length<1e-8) then begin Tri(A,B,C,Normal);Tri(A,C,D,Normal);Exit end;
  I:=Mesh.AddVertex(A,Normal,UV);J:=Mesh.AddVertex(B,Normal,UV);K:=Mesh.AddVertex(C,Normal,UV);L:=Mesh.AddVertex(D,Normal,UV);
  if TVector3.DotProduct(C0,Normal)>0 then Mesh.AddQuad(I,J,K,L) else Mesh.AddQuad(I,L,K,J);
end;
procedure TArchEmitter.Panel(const P:TPoints2; Z:Single; Front:Boolean);
var I:Integer; NN:TVector3;
begin NN:=N;if not Front then NN:=-NN;
  for I:=1 to High(P)-1 do Tri(World(P[0].X,P[0].Y,Z),World(P[I].X,P[I].Y,Z),World(P[I+1].X,P[I+1].Y,Z),NN);
end;
procedure TArchEmitter.Prism(const P:TPoints2; Z0,Z1:Single);
var I,J:Integer; E:TVector2; NN:TVector3;
begin
  Panel(P,Z0,False);Panel(P,Z1,True);
  for I:=0 to High(P) do begin
    J:=(I+1) mod Length(P);E:=P[J]-P[I];NN:=(U*E.Y-Vector3(0,E.X,0)).Normalize;
    Quad(World(P[I].X,P[I].Y,Z0),World(P[J].X,P[J].Y,Z0),World(P[J].X,P[J].Y,Z1),World(P[I].X,P[I].Y,Z1),NN);
  end;
end;
procedure TArchEmitter.Box(X0,Y0,X1,Y1,Z0,Z1:Single);
var P:TPoints2;
begin
  if (X1-X0<0.00001) or (Y1-Y0<0.00001) or (Z1-Z0<0.00001) then Exit;
  SetLength(P,4);P[0]:=Vector2(X0,Y0);P[1]:=Vector2(X1,Y0);P[2]:=Vector2(X1,Y1);P[3]:=Vector2(X0,Y1);Prism(P,Z0,Z1);
end;
procedure TArchEmitter.Cornice(X,Y,Z,W,H,D:Single; const Profile:TArchProfile);
var P:TArchProfile; I:Integer; Y0,Y1,Z0,Z1:Single; NN:TVector3;
begin
  P:=Profile;
  if Length(P)=0 then begin
    SetLength(P,6);P[0]:=Vector2(0,1/3);P[1]:=Vector2(1/3,1/3);
    P[2]:=Vector2(1/3,2/3);P[3]:=Vector2(2/3,2/3);P[4]:=Vector2(2/3,1);P[5]:=Vector2(1,1);
  end;
  for I:=0 to High(P)-1 do begin
    Y0:=Y+P[I].X*H;Y1:=Y+P[I+1].X*H;Z0:=Z+P[I].Y*D;Z1:=Z+P[I+1].Y*D;
    NN:=(N*(Y1-Y0)-Vector3(0,Z1-Z0,0)).Normalize;
    Quad(World(X-W*0.5,Y0,Z0),World(X+W*0.5,Y0,Z0),World(X+W*0.5,Y1,Z1),World(X-W*0.5,Y1,Z1),NN);
    Quad(World(X-W*0.5,Y0,Z),World(X-W*0.5,Y0,Z0),World(X-W*0.5,Y1,Z1),World(X-W*0.5,Y1,Z),-U);
    Quad(World(X+W*0.5,Y0,Z),World(X+W*0.5,Y1,Z),World(X+W*0.5,Y1,Z1),World(X+W*0.5,Y0,Z0),U);
  end;
  Quad(World(X-W*0.5,Y,Z),World(X-W*0.5,Y+H,Z),World(X+W*0.5,Y+H,Z),World(X+W*0.5,Y,Z),-N);
  Quad(World(X-W*0.5,Y,Z),World(X+W*0.5,Y,Z),World(X+W*0.5,Y,Z+P[0].Y*D),World(X-W*0.5,Y,Z+P[0].Y*D),Vector3(0,-1,0));
  Quad(World(X-W*0.5,Y+H,Z),World(X-W*0.5,Y+H,Z+P[High(P)].Y*D),World(X+W*0.5,Y+H,Z+P[High(P)].Y*D),World(X+W*0.5,Y+H,Z),Vector3(0,1,0));
end;
procedure TArchEmitter.Revolve(X,Y,Z:Single; const Radius,Heights:array of Single; Segments:Integer; DepthScale:Single);
var I,J,A,B,C,D:Integer; T0,T1,Slope:Single; P0,P1,P2,P3,N0,N1:TVector3;
begin
  for I:=0 to High(Radius)-1 do begin
    Slope:=(Radius[I]-Radius[I+1])/Max(0.0001,Heights[I+1]-Heights[I]);
    for J:=0 to Segments-1 do begin
      T0:=J*2*Pi/Segments;T1:=(J+1)*2*Pi/Segments;
      P0:=World(X+Cos(T0)*Radius[I],Y+Heights[I],Z+Sin(T0)*Radius[I]*DepthScale);
      P1:=World(X+Cos(T1)*Radius[I],Y+Heights[I],Z+Sin(T1)*Radius[I]*DepthScale);
      P2:=World(X+Cos(T1)*Radius[I+1],Y+Heights[I+1],Z+Sin(T1)*Radius[I+1]*DepthScale);
      P3:=World(X+Cos(T0)*Radius[I+1],Y+Heights[I+1],Z+Sin(T0)*Radius[I+1]*DepthScale);
      N0:=(U*Cos(T0)+N*(Sin(T0)/DepthScale)+Vector3(0,Slope,0)).Normalize;
      N1:=(U*Cos(T1)+N*(Sin(T1)/DepthScale)+Vector3(0,Slope,0)).Normalize;
      A:=Mesh.AddVertex(P0,N0,UV);B:=Mesh.AddVertex(P1,N1,UV);C:=Mesh.AddVertex(P2,N1,UV);D:=Mesh.AddVertex(P3,N0,UV);
      if Radius[I]>0.00001 then Mesh.AddTriangle(A,C,B);
      if Radius[I+1]>0.00001 then Mesh.AddTriangle(A,D,C);
    end;
  end;
  for I:=0 to High(Radius) do if ((I=0) or (I=High(Radius))) and (Radius[I]>0.00001) then begin
    N0:=Vector3(0,1,0);if I=0 then N0:=-N0;
    for J:=0 to Segments-1 do Tri(World(X,Y+Heights[I],Z),
      World(X+Cos(J*2*Pi/Segments)*Radius[I],Y+Heights[I],Z+Sin(J*2*Pi/Segments)*Radius[I]*DepthScale),
      World(X+Cos((J+1)*2*Pi/Segments)*Radius[I],Y+Heights[I],Z+Sin((J+1)*2*Pi/Segments)*Radius[I]*DepthScale),N0);
  end;
end;

procedure TArchEmitter.Ring(const Outer,Inner:TPoints2; Z0,Z1:Single);
var I,J:Integer; Edge:TVector2; NN:TVector3;
begin
  for I:=0 to High(Outer) do begin
    J:=(I+1) mod Length(Outer);
    Quad(World(Outer[I].X,Outer[I].Y,Z1),World(Outer[J].X,Outer[J].Y,Z1),
      World(Inner[J].X,Inner[J].Y,Z1),World(Inner[I].X,Inner[I].Y,Z1),N);
    Quad(World(Outer[I].X,Outer[I].Y,Z0),World(Inner[I].X,Inner[I].Y,Z0),
      World(Inner[J].X,Inner[J].Y,Z0),World(Outer[J].X,Outer[J].Y,Z0),-N);
    Edge:=Outer[J]-Outer[I];NN:=(U*Edge.Y-Vector3(0,Edge.X,0)).Normalize;
    Quad(World(Outer[I].X,Outer[I].Y,Z0),World(Outer[J].X,Outer[J].Y,Z0),
      World(Outer[J].X,Outer[J].Y,Z1),World(Outer[I].X,Outer[I].Y,Z1),NN);
    Edge:=Inner[J]-Inner[I];NN:=(Vector3(0,Edge.X,0)-U*Edge.Y).Normalize;
    Quad(World(Inner[I].X,Inner[I].Y,Z0),World(Inner[I].X,Inner[I].Y,Z1),
      World(Inner[J].X,Inner[J].Y,Z1),World(Inner[J].X,Inner[J].Y,Z0),NN);
  end;
end;

procedure TArchEmitter.Medallion(X,Y,Z,W,H,D:Single; Segments,Lobes:Integer);
var I,J:Integer; A0,A1,R0,R1:Single; A,B,C,E,NN:TVector3;
  function Point(R,T:Single):TVector3;
  var Relief:Single;
  begin
    Relief:=0.12+0.68*(1-R)+0.20*Sin(Pi*R)*Cos(T*Lobes);
    Result:=World(X+Cos(T)*W*0.5*R,Y+H*0.5+Sin(T)*H*0.5*R,Z+D*Relief);
  end;
  procedure Surface(const P,Q,R:TVector3);
  var NN:TVector3;
  begin
    NN:=TVector3.CrossProduct(Q-P,R-P);
    if NN.Length<1e-8 then Exit;
    NN:=NN.Normalize;if TVector3.DotProduct(NN,N)<0 then NN:=-NN;
    Tri(P,Q,R,NN);
  end;
begin
  for J:=0 to 2 do begin
    R0:=J/3;R1:=(J+1)/3;
    for I:=0 to Segments-1 do begin
      A0:=I*2*Pi/Segments;A1:=(I+1)*2*Pi/Segments;
      A:=Point(R0,A0);B:=Point(R1,A0);C:=Point(R1,A1);E:=Point(R0,A1);
      Surface(A,B,C);if J>0 then Surface(A,C,E);
    end;
  end;
  for I:=0 to Segments-1 do begin
    A0:=I*2*Pi/Segments;A1:=(I+1)*2*Pi/Segments;
    A:=World(X+Cos(A0)*W*0.5,Y+H*0.5+Sin(A0)*H*0.5,Z);
    B:=World(X+Cos(A1)*W*0.5,Y+H*0.5+Sin(A1)*H*0.5,Z);
    NN:=(U*(Cos((A0+A1)*0.5)/W)+Vector3(0,Sin((A0+A1)*0.5)/H,0)).Normalize;
    Quad(A,B,Point(1,A1),Point(1,A0),NN);
    Tri(World(X,Y+H*0.5,Z),B,A,-N);
  end;
end;

procedure TArchEmitter.Decoration(const C:TArchComponent; X,Y,Z:Single);
var P,Q,NN2:TPoints2; I,J,K,L,Count:Integer;
    W,H,D,T,R,S,A0,Along,BlockW,Delta,Det,C0,C1:Single;
    Center,LP,RP,Tip,LeftMid,RightMid,Mid,Outward,NN:TVector3;
  procedure LeafFace(const A,B,C:TVector3);
  var Axis:Integer;
  begin
    for Axis:=0 to 2 do begin
      MinP.Data[Axis]:=Min(MinP.Data[Axis],Min(A.Data[Axis],Min(B.Data[Axis],C.Data[Axis])));
      MaxP.Data[Axis]:=Max(MaxP.Data[Axis],Max(A.Data[Axis],Max(B.Data[Axis],C.Data[Axis])));
    end;
    NN:=TVector3.CrossProduct(B-A,C-A);if NN.Length<1e-8 then Exit;
    NN:=NN.Normalize;if TVector3.DotProduct(NN,Outward)<0 then NN:=-NN;
    Tri(A,B,C,NN);
  end;
begin
  W:=C.W;H:=C.H;D:=C.D;
  case C.Kind of
    acCapital: begin
      R:=W*0.5;
      Revolve(X,Y,Z+D*0.5,[R*0.62,R*0.62,R*0.86,R],[0,H*0.18,H*0.62,H*0.82],C.Segments,D/W);
      Box(X-W*0.5,Y+H*0.82,X+W*0.5,Y+H,Z,Z+D);
      if C.Style=1 then begin
        Medallion(X-W*0.32,Y+H*0.36,Z+D*0.86,W*0.3,H*0.44,D*0.12,Min(16,C.Segments),1);
        Medallion(X+W*0.32,Y+H*0.36,Z+D*0.86,W*0.3,H*0.44,D*0.12,Min(16,C.Segments),1);
      end;
      if C.Style=2 then for J:=0 to 1 do for I:=0 to 7 do begin
        A0:=(I+J*0.5)*Pi/4;T:=H*(0.12+J*0.23);S:=H*0.42;
        Outward:=(U*(Cos(A0)/W)+N*(Sin(A0)/D)).Normalize;
        LP:=World(X+R*0.68*Cos(A0-0.16),Y+T,Z+D*0.5*(1+0.68*Sin(A0-0.16)));
        RP:=World(X+R*0.68*Cos(A0+0.16),Y+T,Z+D*0.5*(1+0.68*Sin(A0+0.16)));
        LeftMid:=World(X+R*0.83*Cos(A0-0.16),Y+T+S*0.55,Z+D*0.5*(1+0.83*Sin(A0-0.16)));
        RightMid:=World(X+R*0.83*Cos(A0+0.16),Y+T+S*0.55,Z+D*0.5*(1+0.83*Sin(A0+0.16)));
        Tip:=World(X+R*0.98*Cos(A0),Y+T+S,Z+D*0.5*(1+0.98*Sin(A0)));
        Mid:=World(X+R*0.98*Cos(A0),Y+T+S*0.5,Z+D*0.5*(1+0.98*Sin(A0)));
        LeafFace(LP,RP,Mid);LeafFace(RP,RightMid,Mid);LeafFace(RightMid,Tip,Mid);
        LeafFace(Tip,LeftMid,Mid);LeafFace(LeftMid,LP,Mid);
      end;
    end;
    acPedimentFrame,acWallPanel: begin
      if C.Kind=acPedimentFrame then begin
        SetLength(P,3);P[0]:=Vector2(X-W*0.5,Y);P[1]:=Vector2(X+W*0.5,Y);P[2]:=Vector2(X,Y+H);
      end else begin
        SetLength(P,4);P[0]:=Vector2(X-W*0.5,Y);P[1]:=Vector2(X+W*0.5,Y);
        P[2]:=Vector2(X+W*0.5,Y+H);P[3]:=Vector2(X-W*0.5,Y+H);
      end;
      SetLength(Q,Length(P));SetLength(NN2,Length(P));
      T:=Min(Min(W,H)*0.09,0.14);
      for K:=0 to 1 do begin
        for I:=0 to High(P) do begin
          J:=(I+1) mod Length(P);NN2[I]:=Vector2(-(P[J].Y-P[I].Y),P[J].X-P[I].X).Normalize;
        end;
        for I:=0 to High(P) do begin
          J:=(I+Length(P)-1) mod Length(P);
          C0:=NN2[J].X*P[I].X+NN2[J].Y*P[I].Y+T;
          C1:=NN2[I].X*P[I].X+NN2[I].Y*P[I].Y+T;
          Det:=NN2[J].X*NN2[I].Y-NN2[J].Y*NN2[I].X;
          Q[I]:=Vector2((C0*NN2[I].Y-C1*NN2[J].Y)/Det,(NN2[J].X*C1-NN2[I].X*C0)/Det);
        end;
        Ring(P,Q,Z,Z+D*(1-K*0.34));
        P:=Copy(Q,0,Length(Q));T:=T*0.65;
      end;
      if C.Kind=acWallPanel then Prism(P,Z,Z+D*0.22);
    end;
    acDentilCourse,acQuoins: begin
      Along:=W;if C.Kind=acQuoins then Along:=H;
      Count:=Max(1,Ceil(Along/C.Spacing));Delta:=Along/Count;
      for I:=0 to Count-1 do begin
        if C.Kind=acDentilCourse then begin
          BlockW:=Delta*0.56;T:=X-W*0.5+Delta*(I+0.5);
          Box(T-BlockW*0.5,Y,T+BlockW*0.5,Y+H,Z,Z+D);
        end else begin
          BlockW:=W;if Odd(I) then BlockW:=W*0.68;
          Box(X-BlockW*0.5,Y+Delta*I,X+BlockW*0.5,Y+Delta*(I+0.90),Z,Z+D);
        end;
      end;
    end;
    acRosette: Medallion(X,Y,Z,W,H,D,C.Segments,Min(8,C.Segments div 2));
  end;
end;

procedure TArchEmitter.Tube(const A,B:TVector3; Radius:Single; Sides:Integer);
var Axis,Tangent,Bitangent,N0,N1,P0,P1,Q0,Q1,NN:TVector3; I:Integer; A0,A1:Single;
begin
  if (B-A).Length<0.00001 then Exit;
  Axis:=(B-A).Normalize;Tangent:=Vector3(0,1,0);
  if Abs(Axis.Y)>0.9 then Tangent:=Vector3(1,0,0);
  Tangent:=TVector3.CrossProduct(Axis,Tangent).Normalize;
  Bitangent:=TVector3.CrossProduct(Axis,Tangent);
  for I:=0 to Sides-1 do begin
    A0:=2*Pi*I/Sides;A1:=2*Pi*(I+1)/Sides;
    N0:=Tangent*Cos(A0)+Bitangent*Sin(A0);N1:=Tangent*Cos(A1)+Bitangent*Sin(A1);
    P0:=A+N0*Radius;P1:=A+N1*Radius;Q0:=B+N0*Radius;Q1:=B+N1*Radius;
    NN:=(N0+N1).Normalize;NN:=U*NN.X+Vector3(0,NN.Y,0)+N*NN.Z;
    Quad(World(P0.X,P0.Y,P0.Z),World(P1.X,P1.Y,P1.Z),
      World(Q1.X,Q1.Y,Q1.Z),World(Q0.X,Q0.Y,Q0.Z),NN);
    NN:=U*Axis.X+Vector3(0,Axis.Y,0)+N*Axis.Z;
    Tri(World(A.X,A.Y,A.Z),World(P1.X,P1.Y,P1.Z),World(P0.X,P0.Y,P0.Z),-NN);
    Tri(World(B.X,B.Y,B.Z),World(Q0.X,Q0.Y,Q0.Z),World(Q1.X,Q1.Y,Q1.Z),NN);
  end;
end;

procedure TArchEmitter.Railing(X0,Z0,X1,Z1,Y,H:Single; Style:Integer; Color:Cardinal; Roughness:Single);
var I,Count:Integer; LengthM,Thickness,X,Z,T:Single; AlongX:Boolean;
  procedure Bar(A,B,Y0,Y1,Width:Single);
  var L,R,ZL,ZR:Single;
  begin
    if AlongX then begin L:=X0+A;R:=X0+B;ZL:=Z0-Width*0.5;ZR:=Z0+Width*0.5 end
    else begin L:=X0-Width*0.5;R:=X0+Width*0.5;ZL:=Z0+A;ZR:=Z0+B end;
    if (B-A<=Width+0.001) and (Y1-Y0>Width*2) then begin
      { Post ends are buried in the slab/ground and handrail. Four visible
        sides are sufficient; do not spend two invisible caps per bar. }
      Quad(World(L,Y0,ZR),World(R,Y0,ZR),World(R,Y1,ZR),World(L,Y1,ZR),N);
      Quad(World(R,Y0,ZL),World(L,Y0,ZL),World(L,Y1,ZL),World(R,Y1,ZL),-N);
      Quad(World(L,Y0,ZL),World(L,Y0,ZR),World(L,Y1,ZR),World(L,Y1,ZL),-U);
      Quad(World(R,Y0,ZR),World(R,Y0,ZL),World(R,Y1,ZL),World(R,Y1,ZR),U);
    end else Box(L,Y0,R,Y1,ZL,ZR);
  end;
begin
  AlongX:=Abs(X1-X0)>Abs(Z1-Z0);
  LengthM:=Abs(X1-X0)+Abs(Z1-Z0);if LengthM<0.02 then Exit;
  if AlongX and (X1<X0) then X0:=X1;
  if not AlongX and (Z1<Z0) then Z0:=Z1;
  Thickness:=0.035;if Style=4 then Thickness:=0.065;
  UV:=ArchitectureUV(Color,Roughness,0);
  Bar(0,LengthM,Y+H-0.045,Y+H,0.055);
  if Style in [2,3] then begin
    if Style=3 then UV:=ArchitectureUV($859597,0.24,0,4);
    Bar(0.035,LengthM-0.035,Y+0.06,Y+H-0.05,0.045);
    UV:=ArchitectureUV(Color,Roughness,0);
    Bar(0,0.045,Y,Y+H,0.06);Bar(LengthM-0.045,LengthM,Y,Y+H,0.06);
    Exit;
  end;
  if Style=1 then begin
    for I:=1 to 3 do Bar(0,LengthM,Y+H*I*0.22,Y+H*I*0.22+0.035,0.035);
    Count:=Max(1,Ceil(LengthM/1.2));
  end else begin
    Bar(0,LengthM,Y+0.08,Y+0.115,0.035);
    Count:=Min(64,Max(1,Ceil(LengthM/0.20)));
  end;
  for I:=0 to Count do begin
    T:=(LengthM-Thickness)*I/Count;
    Bar(T,T+Thickness,Y,Y+H-0.04,Thickness);
  end;
end;

procedure TArchEmitter.AtlasPart(const C:TArchComponent; X,Y,Z:Single);
var I,K,Count:Integer; W,H,D,T,A0,A1,Radius,PX,PY:Single; P:TPoints2;
  A,B,C0,D0,NN:TVector3; Section:array[0..4] of TVector2;
begin
  W:=C.W;H:=C.H;D:=C.D;
  case C.Kind of
    acRailing:Railing(X-W*0.5,Z+D*0.5,X+W*0.5,Z+D*0.5,Y,H,C.Style,C.Color,C.Roughness);
    acBalcony:begin
      UV:=ArchitectureUV($b4afa2,0.91,0);Box(X-W*0.5,Y,X+W*0.5,Y+0.14,Z,Z+D);
      Railing(X-W*0.5+0.025,Z+D-0.03,X+W*0.5-0.025,Z+D-0.03,Y+0.14,H-0.14,C.Style,C.Color,C.Roughness);
      Railing(X-W*0.5+0.025,Z+0.03,X-W*0.5+0.025,Z+D-0.03,Y+0.14,H-0.14,C.Style,C.Color,C.Roughness);
      Railing(X+W*0.5-0.025,Z+0.03,X+W*0.5-0.025,Z+D-0.03,Y+0.14,H-0.14,C.Style,C.Color,C.Roughness);
    end;
    acDownpipe:begin
      Radius:=W*0.5;T:=Min(H*0.15,0.25);
      if C.Style=1 then begin
        Box(X-Radius,Y,X+Radius,Y+H-T,Z+Radius,Z+3*Radius);
        Box(X-Radius,Y+H-T,X+Radius,Y+H,Z+Radius,Z+D);
        Box(X-Radius,Y,X+Radius,Y+T,Z+Radius,Z+D);
      end else begin
        Tube(Vector3(X,Y+T,Z+W),Vector3(X,Y+H-T,Z+W),Radius,6);
        Tube(Vector3(X,Y+H-T,Z+W),Vector3(X,Y+H-Radius,Z+D-Radius),Radius,6);
        Tube(Vector3(X,Y+T,Z+W),Vector3(X,Y+Radius,Z+D-Radius),Radius,6);
      end;
      Count:=Min(24,Max(1,Ceil(H/2.2)));
      for I:=0 to Count-1 do begin
        PY:=Y+H*(I+0.5)/Count;
        Box(X-Radius-0.015,PY-0.018,X+Radius+0.015,PY+0.018,Z+0.005,Z+W+Radius+0.015);
      end;
    end;
    acGutter:begin
      { An open trough, not a solid rectangular tube. A tiny inner skin closes
        the wall thickness, and end plates keep the silhouette watertight. }
      if C.Style=0 then begin
        Section[0]:=Vector2(0,H);Section[1]:=Vector2(0.05*D,0.35*H);
        Section[2]:=Vector2(0.5*D,0);Section[3]:=Vector2(0.95*D,0.35*H);Section[4]:=Vector2(D,H);
      end else begin
        Section[0]:=Vector2(0,H);Section[1]:=Vector2(0,0);
        Section[2]:=Vector2(0.5*D,0);Section[3]:=Vector2(D,0);Section[4]:=Vector2(D,H);
      end;
      for I:=0 to 3 do begin
        A:=World(X-W*0.5,Y+Section[I].Y,Z+Section[I].X);
        B:=World(X+W*0.5,Y+Section[I].Y,Z+Section[I].X);
        C0:=World(X+W*0.5,Y+Section[I+1].Y,Z+Section[I+1].X);
        D0:=World(X-W*0.5,Y+Section[I+1].Y,Z+Section[I+1].X);
        NN:=TVector3.CrossProduct(B-A,C0-A).Normalize;
        Quad(A,B,C0,D0,NN);
        Quad(D0+Vector3(0,0.006,0),C0+Vector3(0,0.006,0),B+Vector3(0,0.006,0),A+Vector3(0,0.006,0),-NN);
      end;
      Box(X-W*0.5,Y,X-W*0.5+0.012,Y+H,Z,Z+D);
      Box(X+W*0.5-0.012,Y,X+W*0.5,Y+H,Z,Z+D);
    end;
    acShutter,acVent:begin
      T:=Min(0.045,Min(W,H)*0.12);
      Box(X-W*0.5,Y,X-W*0.5+T,Y+H,Z,Z+D);Box(X+W*0.5-T,Y,X+W*0.5,Y+H,Z,Z+D);
      Box(X-W*0.5+T,Y,X+W*0.5-T,Y+T,Z,Z+D);Box(X-W*0.5+T,Y+H-T,X+W*0.5-T,Y+H,Z,Z+D);
      if (C.Kind=acShutter) and (C.Style=2) then begin
        Box(X-W*0.5+T,Y+T,X+W*0.5-T,Y+H-T,Z,Z+D*0.45);
        Box(X-W*0.5+T,Y+H*0.49,X+W*0.5-T,Y+H*0.52,Z,Z+D);
      end else if (C.Kind=acShutter) and (C.Style=1) then begin
        Count:=Min(20,Max(2,Ceil(W/0.14)));
        for I:=0 to Count-1 do Box(X-W*0.5+T+(W-2*T)*I/Count,Y+T,
          X-W*0.5+T+(W-2*T)*(I+1)/Count-0.008,Y+H-T,Z,Z+D*0.8);
      end else begin
        UV:=ArchitectureUV(C.Color,0.85,0);Box(X-W*0.5+T,Y+T,X+W*0.5-T,Y+H-T,Z,Z+0.008);
        Count:=Min(32,Max(2,Ceil((H-2*T)/0.12)));
        for I:=0 to Count-1 do begin
          PY:=Y+T+(H-2*T)*I/Count;
          A:=World(X-W*0.5+T,PY,Z+D);B:=World(X+W*0.5-T,PY,Z+D);
          C0:=World(X+W*0.5-T,PY+(H-2*T)/Count*0.8,Z+0.01);
          D0:=World(X-W*0.5+T,PY+(H-2*T)/Count*0.8,Z+0.01);
          NN:=TVector3.CrossProduct(B-A,C0-A).Normalize;Quad(A,B,C0,D0,NN);Quad(D0,C0,B,A,-NN);
        end;
        if (C.Kind=acVent) and (C.Style=1) then
          for I:=1 to 3 do begin PX:=X-W*0.5+W*I/4;Box(PX-0.014,Y+T,PX+0.014,Y+H-T,Z+D*0.9,Z+D+0.005) end;
      end;
    end;
    acEntrance:begin
      { Accessory group surrounds a separate, real door opening. No closed
        box may seal that doorway or imitate an interior behind glazing. }
      T:=Min(0.16,W*0.07);
      if C.Style=3 then begin
        Box(X-W*0.5,Y,X-W*0.5+T,Y+H,Z,Z+0.18);Box(X+W*0.5-T,Y,X+W*0.5,Y+H,Z,Z+0.18);
        Cornice(X,Y+H-0.20,Z,W,0.20,Min(D,0.35),nil);
      end else begin
        if C.Style=4 then UV:=ArchitectureUV($879b9e,0.22,0,4);
        if C.Style=1 then begin
          SetLength(P,4);P[0]:=Vector2(X-W*0.5,Y+H-0.2);P[1]:=Vector2(X+W*0.5,Y+H-0.2);
          P[2]:=Vector2(X+W*0.5,Y+H-0.12);P[3]:=Vector2(X,Y+H);
          Prism(P,Z,Z+D);
          SetLength(P,3);P[0]:=Vector2(X-W*0.5,Y+H-0.2);P[1]:=Vector2(X,Y+H);P[2]:=Vector2(X-W*0.5,Y+H-0.12);Prism(P,Z,Z+D);
        end else Box(X-W*0.5,Y+H-0.09,X+W*0.5,Y+H,Z,Z+D);
        UV:=ArchitectureUV(C.Color,C.Roughness,0);
        if C.Style=2 then begin
          Box(X-W*0.5,Y,X-W*0.5+0.11,Y+H-0.09,Z+D-0.11,Z+D);
          Box(X+W*0.5-0.11,Y,X+W*0.5,Y+H-0.09,Z+D-0.11,Z+D);
        end else begin
          Box(X-W*0.5+0.08,Y+H-0.24,X-W*0.5+0.14,Y+H-0.09,Z,Z+Min(0.45,D));
          Box(X+W*0.5-0.14,Y+H-0.24,X+W*0.5-0.08,Y+H-0.09,Z,Z+Min(0.45,D));
        end;
      end;
    end;
    acDamage:begin
      Z:=Z+0.003;
      if C.Style=3 then begin
        { One branching seam with metric width; not black noise everywhere. }
        for I:=0 to 5 do begin
          PX:=X+W*0.24*Sin(I*2.1);PY:=Y+H*I/6;
          SetLength(P,4);P[0]:=Vector2(PX-0.006,PY);P[1]:=Vector2(PX+0.006,PY);
          PX:=X+W*0.24*Sin((I+1)*2.1);P[2]:=Vector2(PX+0.006,Y+H*(I+1)/6);P[3]:=Vector2(PX-0.006,Y+H*(I+1)/6);
          Panel(P,Z,True);
        end;
      end else begin
        if C.Style=1 then UV:=ArchitectureUV(C.Color,C.Roughness,0,3);
        SetLength(P,12);
        for I:=0 to 11 do begin
          A0:=2*Pi*I/12;Radius:=0.85+0.15*Sin(I*7.1+X*0.13);
          P[I]:=Vector2(X+Cos(A0)*W*0.5*Radius,Y+H*0.5+Sin(A0)*H*0.5*Radius);
        end;
        Panel(P,Z,True);
      end;
    end;
  end;
end;

function OpeningPolygon(const R:TArchOpening; Expand:Single):TPoints2;
var I,S:Integer; RX,RY,Y:Single;
begin
  Result:=nil;
  RX:=R.W*0.5+Expand;RY:=R.Rise+Expand;
  if R.Rise<=0 then begin
    SetLength(Result,4);Result[0]:=Vector2(R.X-RX,R.Y-Expand);Result[1]:=Vector2(R.X+RX,R.Y-Expand);
    Result[2]:=Vector2(R.X+RX,R.Y+R.H+Expand);Result[3]:=Vector2(R.X-RX,R.Y+R.H+Expand);Exit;
  end;
  S:=12;SetLength(Result,S+3);Y:=R.Y+R.H-R.Rise;
  Result[0]:=Vector2(R.X-RX,R.Y-Expand);Result[1]:=Vector2(R.X+RX,R.Y-Expand);
  for I:=0 to S do Result[I+2]:=Vector2(R.X+Cos(I*Pi/S)*RX,Y+Sin(I*Pi/S)*RY);
end;
function HeadAt(const R:TArchOpening; X:Single):Single;
var P:TPoints2; I:Integer;
begin
  Result:=R.Y+R.H;if R.Rise<=0 then Exit;P:=OpeningPolygon(R,0);
  for I:=2 to High(P)-1 do if (X>=P[I+1].X-0.00001) and (X<=P[I].X+0.00001) then
    Exit(P[I].Y+(P[I+1].Y-P[I].Y)*(P[I].X-X)/Max(0.000001,P[I].X-P[I+1].X));
end;
procedure EmitOpening(E:TArchEmitter; const R:TArchOpening);
var P,Q:TPoints2; I,J:Integer; NN:TVector3; Edge:TVector2; X,Y,T:Single;
begin
  P:=OpeningPolygon(R,0);Q:=OpeningPolygon(R,R.FrameWidth);
  E.UV:=ArchitectureUV(R.FrameColor,0.65,0);
  for I:=0 to High(P) do begin
    J:=(I+1) mod Length(P);Edge:=P[J]-P[I];NN:=(E.U*Edge.Y-Vector3(0,Edge.X,0)).Normalize;
    { Reveal faces into the opening, not into the solid wall. }
    E.Quad(E.World(P[I].X,P[I].Y,-R.Recess),E.World(P[J].X,P[J].Y,-R.Recess),
      E.World(P[J].X,P[J].Y,R.FrameDepth),E.World(P[I].X,P[I].Y,R.FrameDepth),-NN);
    E.Quad(E.World(Q[I].X,Q[I].Y,R.FrameDepth),E.World(Q[J].X,Q[J].Y,R.FrameDepth),
      E.World(P[J].X,P[J].Y,R.FrameDepth),E.World(P[I].X,P[I].Y,R.FrameDepth),E.N);
    E.Quad(E.World(Q[I].X,Q[I].Y,0),E.World(Q[J].X,Q[J].Y,0),
      E.World(Q[J].X,Q[J].Y,R.FrameDepth),E.World(Q[I].X,Q[I].Y,R.FrameDepth),NN);
  end;
  T:=Min(0.045,R.FrameWidth*0.7);
  for I:=1 to R.MullionsX do begin
    X:=R.X-R.W*0.5+R.W*I/(R.MullionsX+1);
    E.Box(X-T*0.5,R.Y,X+T*0.5,Min(HeadAt(R,X-T*0.5),HeadAt(R,X+T*0.5)),-R.Recess,-R.Recess+0.045);
  end;
  for I:=1 to R.MullionsY do begin
    Y:=R.Y+R.H*I/(R.MullionsY+1);X:=R.W*0.5;
    if (R.Rise>0) and (Y>R.Y+R.H-R.Rise) then X:=X*Sqrt(Max(0,1-Sqr((Y-(R.Y+R.H-R.Rise))/R.Rise)));
    E.Box(R.X-X,Y-T*0.5,R.X+X,Y+T*0.5,-R.Recess,-R.Recess+0.045);
  end;
  if R.Transom>0 then begin
    Y:=R.Y+R.H*R.Transom;
    E.Box(R.X-R.W*0.5,Y-T*0.5,R.X+R.W*0.5,Y+T*0.5,-R.Recess,-R.Recess+0.045);
  end;
  if not R.Door then E.Box(R.X-R.W*0.5-R.FrameWidth-0.04,R.Y-0.055,
    R.X+R.W*0.5+R.FrameWidth+0.04,R.Y,0.003,R.FrameDepth+0.10);
  E.UV:=ArchitectureUV(R.PaneColor,0.13,0,1);if not R.Glazed then E.UV:=ArchitectureUV(R.PaneColor,0.6,0);
  E.Panel(P,-R.Recess,True);
  if R.Door then begin
    E.UV:=ArchitectureUV($92948f,0.4,0.6);
    X:=R.X+R.W*0.34;if R.MullionsX>0 then X:=R.X+0.07;
    E.Box(X-0.018,R.Y+R.H*0.44,X+0.018,R.Y+R.H*0.56,-R.Recess+0.018,-R.Recess+0.07);
    if R.MullionsX>0 then E.Box(R.X-0.088,R.Y+R.H*0.44,R.X-0.052,R.Y+R.H*0.56,-R.Recess+0.018,-R.Recess+0.07);
  end;
end;

function EmitArchitecturalWall(const Facades:TArchFacades; const A,B,N:TVector3;
  Top:Single; Mesh:TMesh):Boolean;
var F,I,J,K,T:Integer; E:TArchEmitter; Tmp:TMesh; Cuts:TFloats; Active:TArchOpenings;
    P:TPoints2; O:TArchOpening; L,R,U0,U1,Y0,Y1,Mid,V,H:Single;
  procedure Cut(X:Single);
  var Z:Integer;
  begin if (X<=U0) or (X>=U1) then Exit;Z:=Length(Cuts);SetLength(Cuts,Z+1);Cuts[Z]:=X end;
  procedure WallStrip(X0,X1,B0,B1,T0,T1:Single);
  begin
    E.Quad(E.World(X0,B0,0),E.World(X1,B1,0),E.World(X1,T1,0),E.World(X0,T0,0),N);
  end;
begin
  Result:=False;
  for F:=0 to High(Facades) do if Facades[F].Matches(A,N) and Facades[F].Matches(B,N) then begin
    H:=Top-A.Y;
    for I:=0 to High(Facades[F].Openings) do begin
      O:=Facades[F].Openings[I];
      if O.Y+O.H+O.FrameWidth>H+0.01 then Exit; { incompatible height retains original wall }
    end;
    E:=TArchEmitter.Create;Tmp:=TMesh.Create;
    try
      Tmp.CurrentOsmId:=Mesh.CurrentOsmId;E.Mesh:=Tmp;E.U:=Facades[F].Axis;E.N:=N;
      U0:=TVector3.DotProduct(A-Facades[F].A,E.U);U1:=U0+TVector3.DotProduct(B-A,E.U);
      if U1<=U0+0.0001 then Exit;E.O:=A-E.U*U0;
      E.O:=E.O-N*Facades[F].Inset;
      Cuts:=nil;SetLength(Cuts,2);Cuts[0]:=U0;Cuts[1]:=U1;
      for I:=0 to High(Facades[F].Openings) do begin
        P:=OpeningPolygon(Facades[F].Openings[I],0);for J:=0 to High(P) do Cut(P[J].X);
      end;
      for I:=1 to High(Cuts) do begin V:=Cuts[I];J:=I-1;while (J>=0) and (Cuts[J]>V) do begin Cuts[J+1]:=Cuts[J];Dec(J) end;Cuts[J+1]:=V end;
      E.UV:=ArchitectureUV(Facades[F].WallColor,Facades[F].Roughness,Facades[F].Metallic,Facades[F].MaterialKind);
      if Facades[F].Inset>0 then begin
        V:=Facades[F].Inset;
        if U0<0.25 then E.Quad(E.World(U0,0,0),E.World(U0,0,V),E.World(U0,H,V),E.World(U0,H,0),E.U);
        if U1>Facades[F].LengthM-0.25 then E.Quad(E.World(U1,0,0),E.World(U1,H,0),E.World(U1,H,V),E.World(U1,0,V),-E.U);
        E.Quad(E.World(U0,0,0),E.World(U1,0,0),E.World(U1,0,V),E.World(U0,0,V),Vector3(0,1,0));
        E.Quad(E.World(U0,H,0),E.World(U0,H,V),E.World(U1,H,V),E.World(U1,H,0),Vector3(0,-1,0));
      end;
      for I:=0 to High(Cuts)-1 do begin
        L:=Cuts[I];R:=Cuts[I+1];if R-L<0.00001 then Continue;Mid:=(L+R)*0.5;Active:=nil;
        for J:=0 to High(Facades[F].Openings) do begin
          O:=Facades[F].Openings[J];
          if (Mid>O.X-O.W*0.5) and (Mid<O.X+O.W*0.5) then begin
            T:=Length(Active);SetLength(Active,T+1);K:=T-1;
            while (K>=0) and (Active[K].Y>O.Y) do begin Active[K+1]:=Active[K];Dec(K) end;Active[K+1]:=O;
          end;
        end;
        Y0:=0;Y1:=0;
        for J:=0 to High(Active) do begin
          WallStrip(L,R,Y0,Y1,Active[J].Y,Active[J].Y);
          Y0:=HeadAt(Active[J],L);Y1:=HeadAt(Active[J],R);
        end;
        WallStrip(L,R,Y0,Y1,H,H);
      end;
      { A collinear OSM split owns an opening by its centre only. The pane and
        reveal stay whole; tile clipping subsequently splits all surfaces. }
      for I:=0 to High(Facades[F].Openings) do begin
        O:=Facades[F].Openings[I];if (O.X>=U0-0.00001) and (O.X<U1-0.00001) then EmitOpening(E,O);
      end;
      Mesh.AppendMesh(Tmp);Result:=True;
    finally E.Free;Tmp.Free end;
    Exit;
  end;
end;

procedure EmitArchitecturalParts(const R:TArchitectureRecipe; Base,Eave,Ridge:Single;
  Mesh:TMesh; out Casters:TArchCasters);
var E:TArchEmitter; F,I,J,K,L,V0:Integer; C:TArchComponent; P:TPoints2; Rads,Ys:TFloats;
    X,Y,Z,W,H,D,T,Rad,A0,A1:Single;
begin
  Casters:=nil;E:=TArchEmitter.Create;
  try
    E.Mesh:=Mesh;
    for F:=0 to High(R.Facades) do begin
      E.O:=R.Facades[F].A;E.O.Y:=Base;E.U:=R.Facades[F].Axis;E.N:=R.Facades[F].Normal;
      for I:=0 to High(R.Facades[F].Components) do begin
        C:=R.Facades[F].Components[I];
        for J:=0 to C.Count-1 do begin
          X:=C.X+J*C.Step;Y:=C.Y;Z:=C.Z;W:=C.W;H:=C.H;D:=C.D;
          if C.Anchor=1 then Y:=Y+Eave-Base else if C.Anchor=2 then Y:=Y+Ridge-Base;
          E.UV:=ArchitectureUV(C.Color,C.Roughness,C.Metallic);V0:=Mesh.VertexCount;
          E.MinP:=Vector3(1e20,1e20,1e20);E.MaxP:=Vector3(-1e20,-1e20,-1e20);
          case C.Kind of
            acBlock,acCanopy: E.Box(X-W*0.5,Y,X+W*0.5,Y+H,Z,Z+D);
            acPilaster: begin
              E.Box(X-W*0.4,Y,X+W*0.4,Y+H,Z,Z+D*0.75);
              E.Box(X-W*0.5,Y,X+W*0.5,Y+H*0.08,Z,Z+D);
              E.Box(X-W*0.5,Y+H*0.92,X+W*0.5,Y+H,Z,Z+D);
            end;
            acColumn: begin
              Rad:=Min(W,D)*0.5;
              if C.ShaftOnly then E.Revolve(X,Y,Z+Rad,[Rad*0.76,Rad*0.82,Rad*0.69],[0,H*0.38,H],C.Segments)
              else begin
                E.Box(X-Rad,Y,X+Rad,Y+H*0.06,Z,Z+2*Rad);
                E.Revolve(X,Y,Z+Rad,[Rad*0.76,Rad*0.82,Rad*0.69],[H*0.06,H*0.38,H*0.94],C.Segments);
                E.Box(X-Rad,Y+H*0.94,X+Rad,Y+H,Z,Z+2*Rad);
              end;
            end;
            acCornice: E.Cornice(X,Y,Z,W,H,D,C.Profile);
            acPediment,acGableRoof: begin
              SetLength(P,3);P[0]:=Vector2(X-W*0.5,Y);P[1]:=Vector2(X+W*0.5,Y);P[2]:=Vector2(X,Y+H);E.Prism(P,Z,Z+D);
            end;
            acSteps: begin
              L:=Min(24,Max(1,Ceil(H/0.17)));
              for K:=0 to L-1 do E.Box(X-W*0.5,Y,X+W*0.5,Y+H*(L-K)/L,Z+D*K/L,Z+D*(K+1)/L);
            end;
            acBalcony,acRailing,acDownpipe,acGutter,acShutter,acVent,acEntrance,acDamage:
              E.AtlasPart(C,X,Y,Z);
            acArch: begin
              T:=Min(W*0.13,H*0.15);Rad:=W*0.5-T;
              E.Box(X-W*0.5,Y,X-Rad,Y+H-W*0.5,Z,Z+D);E.Box(X+Rad,Y,X+W*0.5,Y+H-W*0.5,Z,Z+D);
              for K:=0 to C.Segments-1 do begin
                A0:=K*Pi/C.Segments;A1:=(K+1)*Pi/C.Segments;
                SetLength(P,4);P[0]:=Vector2(X+Cos(A0)*Rad,Y+H-W*0.5+Sin(A0)*Rad);
                P[1]:=Vector2(X+Cos(A0)*W*0.5,Y+H-W*0.5+Sin(A0)*W*0.5);
                P[2]:=Vector2(X+Cos(A1)*W*0.5,Y+H-W*0.5+Sin(A1)*W*0.5);
                P[3]:=Vector2(X+Cos(A1)*Rad,Y+H-W*0.5+Sin(A1)*Rad);
                E.Prism(P,Z,Z+D);
              end;
            end;
            acDrum: E.Revolve(X,Y,Z+D*0.5,[Min(W,D)*0.5,Min(W,D)*0.5],[0,H],C.Segments);
            acDome: begin
              SetLength(Rads,7);SetLength(Ys,7);
              for K:=0 to 6 do begin Rads[K]:=Cos(K*Pi/12)*Min(W,D)*0.5;Ys[K]:=Sin(K*Pi/12)*H end;
              Rads[6]:=0;E.Revolve(X,Y,Z+D*0.5,Rads,Ys,C.Segments);
            end;
            acSpire: E.Revolve(X,Y,Z+D*0.5,[Min(W,D)*0.5,0],[0,H],C.Segments);
            acCapital,acPedimentFrame,acDentilCourse,acRosette,acWallPanel,acQuoins:
              E.Decoration(C,X,Y,Z);
          end;
          { Legacy projected shadows use coarse envelopes; the normal shadow
            map / RTX use the same precise merged mesh as the colour pass. }
          if (Mesh.VertexCount>V0) and (C.Kind<>acDamage) then begin
            K:=Length(Casters);SetLength(Casters,K+1);
            Casters[K].Corners[0]:=Vector3(E.MinP.X,0,E.MinP.Z);Casters[K].Corners[1]:=Vector3(E.MinP.X,0,E.MaxP.Z);
            Casters[K].Corners[2]:=Vector3(E.MaxP.X,0,E.MaxP.Z);Casters[K].Corners[3]:=Vector3(E.MaxP.X,0,E.MinP.Z);
            Casters[K].BaseY:=E.MinP.Y;Casters[K].MaxY:=E.MaxP.Y;
            Casters[K].BlocksGround:=(Y<=0.4) and (C.Kind in [acBlock,acColumn,acPilaster,acDrum]);
          end;
        end;
      end;
    end;
  finally E.Free end;
end;
end.

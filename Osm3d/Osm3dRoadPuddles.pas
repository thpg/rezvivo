unit Osm3dRoadPuddles;
{$mode objfpc}{$H+}{$Q-}{$R-}
interface
uses CastleVectors, X3DNodes, Generics.Collections;
type
  TRoadPuddleSite = record
    Position, Normal, Along, Outward: TVector3;
    Radii: TVector2;
    Group: QWord;
  end;
  TRoadPuddleSites = array of TRoadPuddleSite;
  TPuddleEllipse = record
    Center, Radii: TVector2;
    Group, Key: QWord;
  end;
  { Same integer hash and metric layout as road_puddles.glsl.inc. These sparse
    landmarks do not render, collide, or retain the road geometry. }
  TPuddleEllipses = array[0..4] of TPuddleEllipse;
  TRoadPuddleCollector = class
  private
    FSeen: specialize TDictionary<QWord,Boolean>;
    FSites: TRoadPuddleSites;
    FCount: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Triangle(const A,B,C,NA,NB,NC:TVector3;
      const CA,CB,CC,Style:TVector4);
    function Sites:TRoadPuddleSites;
  end;
function RoadPuddleLayout(BlockX,BlockY:Integer;Seed:Cardinal;Width:Single;
  Area:Boolean;out Ellipses:TPuddleEllipses):Integer;
procedure RegisterRoadPuddles(Owner:TX3DNode;const Sites:TRoadPuddleSites);
function FindRoadPuddle(const Position,Forward:TVector3;MinAhead,MaxAhead,MaxSide:Single;
  ExcludeGroup:QWord;out Site:TRoadPuddleSite):Boolean;
function RoadPuddleSiteCount:Integer;
implementation
uses Math,SysUtils;

function Key(X,Y:Integer;Seed:Cardinal):TVector3;
var H:Cardinal;
begin
  H:=Cardinal(X)*$9E3779B9 xor Cardinal(Y)*$85EBCA6B xor Seed;
  H:=H xor(H shr 16);H:=H*$7FEB352D;H:=H xor(H shr 15);H:=H*$846CA68B;H:=H xor(H shr 16);
  Result:=Vector3(H and 1023,(H shr 10)and 1023,(H shr 20)and 1023)/1023;
end;

function RoadPuddleLayout(BlockX,BlockY:Integer;Seed:Cardinal;Width:Single;
  Area:Boolean;out Ellipses:TPuddleEllipses):Integer;
var G,H:TVector3;I:Integer;P:TPuddleEllipse;Side,Across:Single;Gutter:Boolean;Group:QWord;
begin
  Result:=0;
  if Area then begin
    G:=Key(BlockX,BlockY,173);if G.X>0.32 then Exit;
    Group:=(QWord(Cardinal(BlockX)) shl 32) xor Cardinal(BlockY) xor $B163FB119100001D;
  end else begin
    G:=Key(BlockX,713,Seed);if (G.X>0.24)or(Width<1) then Exit;
    Group:=(QWord(Seed) shl 32) xor Cardinal(BlockX) xor $129895FB8398000D;
  end;
  for I:=0 to 4 do begin
    if Area then begin
      if I=4 then Break;
      H:=Key(BlockX,BlockY,I+901);
      P.Center:=Vector2(BlockX*32+9+14*G.Y+(H.Y-0.5)*7,
                       BlockY*32+9+14*G.Z+(H.Z-0.5)*7);
      P.Radii:=Vector2(0.4+1.2*H.X,0.3+0.6*H.Y);
    end else begin
      H:=Key(BlockX,I+901,Seed);if (I>2)and(H.Z>0.55)then Continue;
      if G.Z>0.5 then Side:=1 else Side:=-1;
      Gutter:=G.Y<0.70;
      if Gutter then Across:=Side*(Width*0.5-0.48)else Across:=(G.Z-0.5)*Width*0.65;
      P.Center:=Vector2(BlockX*64+16+32*G.Y+(I-2)*2.1,Across+(H.Z-0.5)*0.9);
      P.Radii:=Vector2(0.32+1.10*H.X,0.18+0.48*H.Y);
      if (I=0)and Gutter then begin
        P.Center:=Vector2(BlockX*64+16+32*G.Y,Side*(Width*0.5-0.38));
        P.Radii:=Vector2(2.0+3.5*H.X,0.25+0.22*H.Y);
      end;
      if Abs(P.Center.Y)>Width*0.5-0.15 then Continue;
    end;
    P.Group:=Group;P.Key:=Group xor(QWord(I+1)*$9E3779B97F4A7C15);
    Ellipses[Result]:=P;Inc(Result);
  end;
end;

constructor TRoadPuddleCollector.Create;
begin inherited;FSeen:=specialize TDictionary<QWord,Boolean>.Create end;
destructor TRoadPuddleCollector.Destroy;
begin FSeen.Free;inherited end;
function TRoadPuddleCollector.Sites:TRoadPuddleSites;
begin SetLength(FSites,FCount);Result:=FSites end;

procedure TRoadPuddleCollector.Triangle(const A,B,C,NA,NB,NC:TVector3;
  const CA,CB,CC,Style:TVector4);
var X0,X1,Y0,Y1,X,Y,I,N:Integer;U,V,Q:TVector2;Det,WB,WC,WA,Scale:Single;
  Area:Boolean;E:TPuddleEllipses;S:TRoadPuddleSite;
begin
  if(CA.Z<1)or(CA.W< -1.5)or(Abs(CA.W-CB.W)>0.01)or(Abs(CA.W-CC.W)>0.01)then Exit;
  Area:=CA.W< -0.5;
  U:=Vector2(CB.X-CA.X,CB.Y-CA.Y);V:=Vector2(CC.X-CA.X,CC.Y-CA.Y);
  Det:=U.X*V.Y-U.Y*V.X;if Abs(Det)<0.000001 then Exit;
  if Area then Scale:=32 else Scale:=64;
  X0:=Floor(Min(CA.X,Min(CB.X,CC.X))/Scale);X1:=Floor(Max(CA.X,Max(CB.X,CC.X))/Scale);
  if Area then begin
    Y0:=Floor(Min(CA.Y,Min(CB.Y,CC.Y))/32);Y1:=Floor(Max(CA.Y,Max(CB.Y,CC.Y))/32);
  end else begin Y0:=0;Y1:=0 end;
  { Malformed or world-sized triangles must never stall tile loading. }
  if Int64(X1-X0+1)*(Y1-Y0+1)>16384 then Exit;
  for X:=X0 to X1 do for Y:=Y0 to Y1 do begin
    N:=RoadPuddleLayout(X,Y,Round(Style.W),CA.Z,Area,E);
    for I:=0 to N-1 do begin
      if FSeen.ContainsKey(E[I].Key)then Continue;
      Q:=E[I].Center-Vector2(CA.X,CA.Y);
      WB:=(Q.X*V.Y-Q.Y*V.X)/Det;WC:=(U.X*Q.Y-U.Y*Q.X)/Det;WA:=1-WB-WC;
      if(Min(WA,Min(WB,WC))< -0.0001)then Continue;
      S.Normal:=NA*WA+NB*WB+NC*WC;
      if S.Normal.LengthSqr<0.5 then Continue;
      S.Normal:=S.Normal.Normalize;if S.Normal.Y<0.998 then Continue;
      S.Position:=A*WA+B*WB+C*WC;
      S.Along:=((B-A)*V.Y-(C-A)*U.Y)/Det;S.Along.Y:=0;
      if S.Along.LengthSqr<0.001 then Continue;S.Along:=S.Along.Normalize;
      S.Outward:=TVector3.Zero;
      if not Area then begin
        S.Outward:=((C-A)*U.X-(B-A)*V.X)/Det;S.Outward.Y:=0;
        if S.Outward.LengthSqr>0.001 then S.Outward:=S.Outward.Normalize;
        if E[I].Center.Y<0 then S.Outward:=-S.Outward;
      end;
      S.Group:=E[I].Group;S.Radii:=E[I].Radii;
      if FCount=Length(FSites)then SetLength(FSites,Max(16,FCount*2));
      FSites[FCount]:=S;Inc(FCount);FSeen.Add(E[I].Key,True);
    end;
  end;
end;

type TPuddleBinding=class
  Next:TPuddleBinding;
  Sites:TRoadPuddleSites;
  MinX,MinZ,MaxX,MaxZ:Single;
  procedure Gone(const Node:TX3DNode);
end;
var Bindings:TPuddleBinding;Lock:TRTLCriticalSection;
procedure TPuddleBinding.Gone(const Node:TX3DNode);
var B:TPuddleBinding;
begin
  EnterCriticalSection(Lock);
  try
    if Bindings=Self then Bindings:=Next else begin
      B:=Bindings;while(B<>nil)and(B.Next<>Self)do B:=B.Next;
      if B<>nil then B.Next:=Next;
    end;
  finally LeaveCriticalSection(Lock)end;
  Free;
end;
procedure RegisterRoadPuddles(Owner:TX3DNode;const Sites:TRoadPuddleSites);
var B:TPuddleBinding;S:TRoadPuddleSite;
begin
  if(Owner=nil)or(Length(Sites)=0)then Exit;
  B:=TPuddleBinding.Create;B.Sites:=Sites;
  B.MinX:=1e20;B.MinZ:=1e20;B.MaxX:=-1e20;B.MaxZ:=-1e20;
  for S in Sites do begin
    B.MinX:=Min(B.MinX,S.Position.X);B.MaxX:=Max(B.MaxX,S.Position.X);
    B.MinZ:=Min(B.MinZ,S.Position.Z);B.MaxZ:=Max(B.MaxZ,S.Position.Z);
  end;
  Owner.AddDestructionNotification(@B.Gone);
  EnterCriticalSection(Lock);try B.Next:=Bindings;Bindings:=B finally LeaveCriticalSection(Lock)end;
end;
function FindRoadPuddle(const Position,Forward:TVector3;MinAhead,MaxAhead,MaxSide:Single;
  ExcludeGroup:QWord;out Site:TRoadPuddleSite):Boolean;
var B:TPuddleBinding;S:TRoadPuddleSite;Delta,Side:TVector3;Ahead,Lateral,Score,Best,R:Single;
begin
  Result:=False;Site:=Default(TRoadPuddleSite);Best:=1e20;R:=MaxAhead+MaxSide;
  Side:=TVector3.CrossProduct(Forward,Vector3(0,1,0));
  EnterCriticalSection(Lock);
  try
    B:=Bindings;while B<>nil do begin
      if(Position.X+R>=B.MinX)and(Position.X-R<=B.MaxX)and
        (Position.Z+R>=B.MinZ)and(Position.Z-R<=B.MaxZ)then
      for S in B.Sites do begin
        if S.Group=ExcludeGroup then Continue;
        Delta:=S.Position-Position;
        if Abs(Delta.Y)>2.0 then Continue;
        Ahead:=TVector3.DotProduct(Delta,Forward);Lateral:=Abs(TVector3.DotProduct(Delta,Side));
        { Include the near edge: otherwise a tiny satellite enters the search
          before its larger neighbour and steals the shot for the whole group. }
        if(Ahead<MinAhead)or(Ahead>MaxAhead+Max(S.Radii.X,S.Radii.Y))or(Lateral>MaxSide)then Continue;
        Score:=Ahead+Lateral*1.5-Min(4.0,S.Radii.X*S.Radii.Y)*2;
        if Score>=Best then Continue;
        Best:=Score;Site:=S;Result:=True;
      end;
      B:=B.Next;
    end;
  finally LeaveCriticalSection(Lock)end;
end;
function RoadPuddleSiteCount:Integer;
var B:TPuddleBinding;
begin
  Result:=0;EnterCriticalSection(Lock);
  try B:=Bindings;while B<>nil do begin Inc(Result,Length(B.Sites));B:=B.Next end
  finally LeaveCriticalSection(Lock)end;
end;
initialization InitCriticalSection(Lock);
end.

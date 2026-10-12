unit Osm3dMeasuredRoadHeight;
{$mode objfpc}{$H+}
{ Authored, datum-aligned road elevations. Build-time only: no ride/session
  state, network or per-frame work. The recipe hash owns cache invalidation. }
interface
uses SysUtils, fpjson, Generics.Collections, Osm3dGeoMath, Osm3dOsmData, Osm3dMeasuredAreaHeight;
const MEASURED_ROAD_HEIGHT_TAG='rezvivo:elevation_profile';
type
  TMeasuredStation=record AtM,Height:Double end;
  TMeasuredStations=array of TMeasuredStation;
  { Positive offset is left of the original OSM way, negative is right.
    Heights are relative to the road surface, not an absolute DEM datum. }
  TBankPoint=record Offset,Height:Double end;
  TBankPoints=array of TBankPoint;
  TBankStation=record AtM:Double; Points:TBankPoints end;
  TBankStations=array of TBankStation;
  TMeasuredProfile=record Stations:TMeasuredStations; Width,Feather:Double;
    Banks:TBankStations; MaxExtent:Double end;
  TMeasuredRoadHeight=class
  private
    type
      TSegment=record A,B:TLatLon; H0,H1,HalfWidth,Feather,CosLat,At0,At1:Double;
        ProfileIndex:Integer end;
      TSegments=array of TSegment;
      TIndices=specialize TList<Integer>;
      TCells=specialize TObjectDictionary<Int64,TIndices>;
    var FSegments:TSegments; FCount:Integer; FCells:TCells;
      FProfiles:array of TMeasuredProfile;
      FAreas:array of TMeasuredArea;
    procedure AddArea(const A:TMeasuredArea);
    procedure AddSegment(const A,B:TLatLon; H0,H1,At0,At1:Double;
      ProfileIndex:Integer; const P:TMeasuredProfile);
  public
    constructor Create(Dataset:TOSMDataset);
    destructor Destroy;override;
    function Empty:Boolean;
    function TargetGeo(const P:TLatLon;out Height,Weight:Single):Boolean;
    function ApplyGeo(const P:TLatLon; BaseHeight:Single):Single;
  end;
function CanonicalMeasuredRoadHeight(Value:TJSONData):string;
function MeasuredRoadHeightRadius(const Text:string):Double;
procedure ValidateMeasuredRoadHeight(const Text:string;Source:TJSONObject);
implementation
uses Math, jsonparser, Osm3dTileKnowledge;
const DEG_M=111195.080233533; CELL_DEG=2000.0;
procedure Need(B:Boolean;const S:string);
begin if not B then raise ETileKnowledge.Create('road.elevation_profile: '+S) end;
procedure Keys(O:TJSONObject;const Allowed:string);
var I:Integer;
begin for I:=0 to O.Count-1 do Need(Pos('|'+O.Names[I]+'|',Allowed)>0,'unknown field '+O.Names[I]) end;
function Num(O:TJSONObject;const Key:string;Lo,Hi:Double):Double;
var V:TJSONData;
begin
  V:=O.Find(Key);Need((V<>nil) and (V.JSONType=jtNumber),Key+' number required');
  Result:=V.AsFloat;Need(not IsNan(Result) and not IsInfinite(Result) and
    (Result>=Lo) and (Result<=Hi),Key+' out of range');
end;
function Decode(Value:TJSONData):TMeasuredProfile;
var O,S,C:TJSONObject;A,B,Q,XY:TJSONArray;I,K,N:Integer;D,X,Y,PrevX:Double;
  LeftEdge,RightEdge:Boolean;
begin
  Result:=Default(TMeasuredProfile);Need(Value is TJSONObject,'object required');O:=TJSONObject(Value);
  Keys(O,'|version|datum|width_m|feather_m|stations|terrain_sections|');
  D:=Num(O,'version',1,2);Need((D=1) or (D=2),'version 1 or 2 required');
  Need((O.Find('terrain_sections')=nil) or (D=2),'terrain sections require version 2');
  Need(O.Get('datum','')='dem_aligned','align the vertical datum before authoring');
  Result.Width:=Num(O,'width_m',1,30);Result.Feather:=Num(O,'feather_m',10,80);
  Need(O.Find('stations') is TJSONArray,'stations required');A:=TJSONArray(O.Find('stations'));
  Need((A.Count>=2) and (A.Count<=2048),'2..2048 stations required');SetLength(Result.Stations,A.Count);
  for I:=0 to A.Count-1 do begin
    Need(A[I] is TJSONObject,'station object required');S:=TJSONObject(A[I]);Keys(S,'|at_m|elevation_m|');
    Result.Stations[I].AtM:=Round(Num(S,'at_m',0,50000)*1000)*0.001;
    Result.Stations[I].Height:=Round(Num(S,'elevation_m',-500,9000)*1000)*0.001;
    if I>0 then begin
      D:=Result.Stations[I].AtM-Result.Stations[I-1].AtM;
      Need(D>=1,'stations must increase by at least 1 m');
      Need(Abs(Result.Stations[I].Height-Result.Stations[I-1].Height)<=D*0.6,'grade exceeds 60 percent');
    end;
  end;
  Result.MaxExtent:=Result.Width*0.5;
  if O.Find('terrain_sections')=nil then Exit;
  Need(O.Find('terrain_sections') is TJSONArray,'terrain_sections array required');
  B:=TJSONArray(O.Find('terrain_sections'));Need((B.Count>=2) and (B.Count<=256),'2..256 terrain sections required');
  SetLength(Result.Banks,B.Count);
  for I:=0 to B.Count-1 do begin
    Need(B[I] is TJSONObject,'terrain section object required');C:=TJSONObject(B[I]);
    Keys(C,'|at_m|points|');Result.Banks[I].AtM:=Round(Num(C,'at_m',0,50000)*1000)*0.001;
    Need((Result.Banks[I].AtM>=Result.Stations[0].AtM) and
      (Result.Banks[I].AtM<=Result.Stations[High(Result.Stations)].AtM),'terrain section outside height profile');
    if I>0 then Need(Result.Banks[I].AtM-Result.Banks[I-1].AtM>=1,'terrain sections must increase by at least 1 m');
    Need(C.Find('points') is TJSONArray,'terrain section points required');Q:=TJSONArray(C.Find('points'));
    Need((Q.Count>=2) and (Q.Count<=32),'2..32 cross-section points required');
    SetLength(Result.Banks[I].Points,Q.Count);LeftEdge:=False;RightEdge:=False;PrevX:=-1e100;
    for K:=0 to Q.Count-1 do begin
      Need(Q[K] is TJSONArray,'cross-section [offset_m,relative_height_m] required');XY:=TJSONArray(Q[K]);
      Need(XY.Count=2,'two cross-section coordinates required');
      for N:=0 to 1 do Need((XY[N].JSONType=jtNumber) and not IsNan(XY[N].AsFloat) and
        not IsInfinite(XY[N].AsFloat),'finite numeric cross-section required');
      X:=Round(XY[0].AsFloat*1000)*0.001;Y:=Round(XY[1].AsFloat*1000)*0.001;
      Need((Abs(X)<=60) and (Abs(Y)<=30),'cross-section exceeds local terrain bounds');
      Need(X-PrevX>=0.1,'cross-section offsets must increase by at least 0.1 m');
      if Abs(X)<=Result.Width*0.5+0.001 then Need(Abs(Y)<0.001,'cross-section must preserve flat road core');
      if Abs(X-Result.Width*0.5)<0.001 then LeftEdge:=True;
      if Abs(X+Result.Width*0.5)<0.001 then RightEdge:=True;
      if K>0 then Need(Abs(Y-Result.Banks[I].Points[K-1].Height)<=2*(X-PrevX),'terrain side slope exceeds 200 percent');
      Result.Banks[I].Points[K].Offset:=X;Result.Banks[I].Points[K].Height:=Y;
      Result.MaxExtent:=Max(Result.MaxExtent,Abs(X));PrevX:=X;
    end;
    Need(LeftEdge and RightEdge,'both road edges must be explicit zero-height knots');
  end;
  Need((Abs(Result.Banks[0].AtM-Result.Stations[0].AtM)<0.001) and
    (Abs(Result.Banks[High(Result.Banks)].AtM-Result.Stations[High(Result.Stations)].AtM)<0.001),
    'terrain sections must span the height profile; use flat sections for transitions');
end;
function MeasuredRoadHeightRadius(const Text:string):Double;
var J:TJSONData;P:TMeasuredProfile;
begin
  J:=GetJSON(Text);
  try P:=Decode(J);Result:=P.MaxExtent+P.Feather finally J.Free end;
end;
function CanonicalMeasuredRoadHeight(Value:TJSONData):string;
var P:TMeasuredProfile;O:TJSONObject;A,B,Q:TJSONArray;I,K:Integer;
begin
  P:=Decode(Value);A:=TJSONArray.Create;
  O:=TJSONObject.Create(['version',1,'datum','dem_aligned','width_m',P.Width,'feather_m',P.Feather,'stations',A]);
  try
    for I:=0 to High(P.Stations) do A.Add(TJSONObject.Create(['at_m',P.Stations[I].AtM,'elevation_m',P.Stations[I].Height]));
    if Length(P.Banks)>0 then begin
      O.Integers['version']:=2;B:=TJSONArray.Create;O.Add('terrain_sections',B);
      for I:=0 to High(P.Banks) do begin
        Q:=TJSONArray.Create;B.Add(TJSONObject.Create(['at_m',P.Banks[I].AtM,'points',Q]));
        for K:=0 to High(P.Banks[I].Points) do
          Q.Add(TJSONArray.Create([P.Banks[I].Points[K].Offset,P.Banks[I].Points[K].Height]));
      end;
    end;
    Result:=O.AsJSON;
  finally O.Free end;
end;
procedure ValidateMeasuredRoadHeight(const Text:string;Source:TJSONObject);
var P:TMeasuredProfile;J:TJSONData;Tags:TJSONObject;A:TJSONArray;I:Integer;Prev,LL:TLatLon;L:Double;
  function Enabled(const K:string):Boolean;
  var S:string;
  begin S:=LowerCase(Tags.Get(K,''));Result:=(S<>'') and (S<>'no') and (S<>'false') and (S<>'0') end;
begin
  J:=GetJSON(Text);try P:=Decode(J) finally J.Free end;
  Need((Source.Get('type','')='way') and Source.Get('geometry_complete',False),'complete OSM way required');
  Need(not Source.Get('closed',False),'split closed ways at a real OSM junction first');
  Tags:=TJSONObject(Source.Find('tags'));Need(Tags<>nil,'source tags required');
  Need(not Enabled('bridge') and not Enabled('tunnel') and not Enabled('area'),'ground-level roads only');
  Need(Source.Find('outline') is TJSONArray,'source outline required');A:=TJSONArray(Source.Find('outline'));L:=0;
  Need(A.Count>=2,'source has no segments');
  for I:=0 to A.Count-1 do begin
    LL:=TLatLon.Make(A[I].Items[1].AsFloat,A[I].Items[0].AsFloat);Need(Abs(LL.Lat)<85,'polar source unsupported');
    if I>0 then begin
      Need((Abs(LL.Lon-Prev.Lon)<1) and (Prev.DistanceTo(LL)<2000),'source segment too long');
      L+=Prev.DistanceTo(LL);
    end;Prev:=LL;
  end;
  Need(P.Stations[High(P.Stations)].AtM<=L+0.02,'station exceeds original way length');
end;
function CellKey(X,Y:Integer):Int64;
begin Result:=Int64(X)*1000000+Y end;
procedure TMeasuredRoadHeight.AddSegment(const A,B:TLatLon;H0,H1,At0,At1:Double;
  ProfileIndex:Integer;const P:TMeasuredProfile);
var I,X,Y,X0,X1,Y0,Y1:Integer;R,DX,DY:Double;K:Int64;List:TIndices;
begin
  if A.DistanceTo(B)<0.001 then Exit;
  I:=FCount;if I=Length(FSegments) then SetLength(FSegments,Max(64,I*2));Inc(FCount);
  FSegments[I].A:=A;FSegments[I].B:=B;
  FSegments[I].H0:=H0;FSegments[I].H1:=H1;
  FSegments[I].HalfWidth:=P.Width*0.5;FSegments[I].Feather:=P.Feather;
  FSegments[I].At0:=At0;FSegments[I].At1:=At1;FSegments[I].ProfileIndex:=ProfileIndex;
  FSegments[I].CosLat:=Cos((A.Lat+B.Lat)*Pi/360);
  R:=P.MaxExtent+P.Feather;DY:=R/DEG_M;DX:=DY/FSegments[I].CosLat;
  X0:=Floor((Min(A.Lon,B.Lon)-DX)*CELL_DEG);X1:=Floor((Max(A.Lon,B.Lon)+DX)*CELL_DEG);
  Y0:=Floor((Min(A.Lat,B.Lat)-DY)*CELL_DEG);Y1:=Floor((Max(A.Lat,B.Lat)+DY)*CELL_DEG);
  for X:=X0 to X1 do for Y:=Y0 to Y1 do begin
    K:=CellKey(X,Y);if not FCells.TryGetValue(K,List) then begin List:=TIndices.Create;FCells.Add(K,List) end;
    List.Add(I);
  end;
end;
procedure TMeasuredRoadHeight.AddArea(const A:TMeasuredArea);
var I,X,Y:Integer;B:TLatLonBox;K:Int64;List:TIndices;
begin
  I:=Length(FAreas);SetLength(FAreas,I+1);FAreas[I]:=A;B:=A.Box.ExpandMeters(A.Feather+1);
  for X:=Floor(B.MinLon*CELL_DEG) to Floor(B.MaxLon*CELL_DEG) do
    for Y:=Floor(B.MinLat*CELL_DEG) to Floor(B.MaxLat*CELL_DEG) do begin
      K:=CellKey(X,Y);if not FCells.TryGetValue(K,List) then begin List:=TIndices.Create;FCells.Add(K,List) end;
      List.Add(-I-1);
    end;
end;
constructor TMeasuredRoadHeight.Create(Dataset:TOSMDataset);
var W:TOSMWay;N:TOSMNode;P:TMeasuredProfile;J:TJSONData;I,K,ProfileIndex:Integer;
  Prev,LL,A,B:TLatLon;Along,L,Lo,Hi,T0,T1,H0,H1:Double;
begin
  inherited Create;FCells:=TCells.Create([doOwnsValues]);
  if Dataset=nil then Exit;
  for W in Dataset.Ways.Values do begin
    if W.Tags.Get(MEASURED_AREA_HEIGHT_TAG)<>'' then
      AddArea(ReadMeasuredAreaText(W.Tags.Get(MEASURED_AREA_HEIGHT_TAG)));
    if W.Tags.Get(MEASURED_ROAD_HEIGHT_TAG)='' then Continue;
    J:=GetJSON(W.Tags.Get(MEASURED_ROAD_HEIGHT_TAG));try P:=Decode(J) finally J.Free end;
    ProfileIndex:=Length(FProfiles);SetLength(FProfiles,ProfileIndex+1);FProfiles[ProfileIndex]:=P;
    Along:=0;K:=0;
    for I:=0 to High(W.NodeRefs) do begin
      N:=Dataset.FindNode(W.NodeRefs[I]);Need(N<>nil,'missing node during build');LL:=N.Position;
      if I>0 then begin
        L:=Prev.DistanceTo(LL);
        while (K<High(P.Stations)) and (P.Stations[K+1].AtM<Along-0.001) do Inc(K);
        while (L>0.001) and (K<High(P.Stations)) and (P.Stations[K].AtM<Along+L) do begin
          Lo:=Max(Along,P.Stations[K].AtM);Hi:=Min(Along+L,P.Stations[K+1].AtM);
          if Hi>Lo+0.001 then begin
            T0:=(Lo-Along)/L;T1:=(Hi-Along)/L;
            A:=TLatLon.Make(Prev.Lat+(LL.Lat-Prev.Lat)*T0,Prev.Lon+(LL.Lon-Prev.Lon)*T0);
            B:=TLatLon.Make(Prev.Lat+(LL.Lat-Prev.Lat)*T1,Prev.Lon+(LL.Lon-Prev.Lon)*T1);
            T0:=(Lo-P.Stations[K].AtM)/(P.Stations[K+1].AtM-P.Stations[K].AtM);
            T1:=(Hi-P.Stations[K].AtM)/(P.Stations[K+1].AtM-P.Stations[K].AtM);
            H0:=P.Stations[K].Height+(P.Stations[K+1].Height-P.Stations[K].Height)*T0;
            H1:=P.Stations[K].Height+(P.Stations[K+1].Height-P.Stations[K].Height)*T1;
            AddSegment(A,B,H0,H1,Lo,Hi,ProfileIndex,P);
          end;
          if P.Stations[K+1].AtM>=Along+L-0.001 then Break;Inc(K);
        end;
        Along+=L;
      end;Prev:=LL;
    end;
  end;
end;
destructor TMeasuredRoadHeight.Destroy;
begin FCells.Free;inherited end;
function TMeasuredRoadHeight.Empty:Boolean;
begin Result:=(FCount=0) and (Length(FAreas)=0) end;
function BankHeight(const P:TMeasuredProfile;AtM,Offset:Double;out Extent:Double):Double;
var Lo,Hi,M:Integer;T,E0,E1,H0,H1:Double;
  function CrossHeight(const S:TBankStation;out Edge:Double):Double;
  var K:Integer;X0,X1:Double;
  begin
    if Offset<0 then Edge:=-S.Points[0].Offset
    else Edge:=S.Points[High(S.Points)].Offset;
    if Offset<=S.Points[0].Offset then Exit(S.Points[0].Height);
    for K:=1 to High(S.Points) do if Offset<=S.Points[K].Offset then begin
      X0:=S.Points[K-1].Offset;X1:=S.Points[K].Offset;
      Exit(S.Points[K-1].Height+(S.Points[K].Height-S.Points[K-1].Height)*(Offset-X0)/(X1-X0));
    end;
    Result:=S.Points[High(S.Points)].Height;
  end;
begin
  Result:=0;Extent:=P.Width*0.5;
  if Length(P.Banks)=0 then Exit;
  Lo:=0;Hi:=High(P.Banks);
  while Hi-Lo>1 do begin M:=(Lo+Hi) div 2;if P.Banks[M].AtM<=AtM then Lo:=M else Hi:=M end;
  T:=EnsureRange((AtM-P.Banks[Lo].AtM)/(P.Banks[Hi].AtM-P.Banks[Lo].AtM),0,1);
  H0:=CrossHeight(P.Banks[Lo],E0);H1:=CrossHeight(P.Banks[Hi],E1);
  Result:=H0+(H1-H0)*T;Extent:=E0+(E1-E0)*T;
end;
function TMeasuredRoadHeight.TargetGeo(const P:TLatLon;out Height,Weight:Single):Boolean;
var List:TIndices;I:Integer;S:TSegment;AX,AZ,BX,BZ,T,D,Best,H:Double;
  Core:Boolean;U,W,SumW,SumH,SegmentHeight,Extent,Offset,Len,Envelope:Double;
  AreaW,AreaSumW,AreaSumH:Double;
begin
  Result:=False;Height:=0;Weight:=0;
  if not FCells.TryGetValue(CellKey(Floor(P.Lon*CELL_DEG),Floor(P.Lat*CELL_DEG)),List) then Exit;
  AreaW:=0;AreaSumW:=0;AreaSumH:=0;
  if Length(FAreas)>0 then for I in List do if I<0 then begin
    W:=MeasuredAreaWeight(FAreas[-I-1],P);
    AreaW:=Max(AreaW,W);AreaSumW+=W;AreaSumH+=W*FAreas[-I-1].Height;
  end;
  if AreaW>=1 then begin Height:=AreaSumH/AreaSumW;Weight:=1;Exit(True) end;
  Best:=1e100;H:=0;Core:=False;SumW:=0;SumH:=0;
  for I in List do begin
    if I<0 then Continue;
    S:=FSegments[I];AX:=(P.Lon-S.A.Lon)*DEG_M*S.CosLat;AZ:=(P.Lat-S.A.Lat)*DEG_M;
    BX:=(S.B.Lon-S.A.Lon)*DEG_M*S.CosLat;BZ:=(S.B.Lat-S.A.Lat)*DEG_M;
    T:=EnsureRange((AX*BX+AZ*BZ)/(BX*BX+BZ*BZ),0,1);D:=Hypot(AX-BX*T,AZ-BZ*T);
    if D>=FProfiles[S.ProfileIndex].MaxExtent+S.Feather then Continue;
    Len:=Hypot(BX,BZ);Offset:=(BX*AZ-BZ*AX)/Len;
    SegmentHeight:=S.H0+(S.H1-S.H0)*T;
    SegmentHeight+=BankHeight(FProfiles[S.ProfileIndex],S.At0+(S.At1-S.At0)*T,Offset,Extent);
    if D>=Extent+S.Feather then Continue;
    { A nearest-only target jumps across the bisector of two switchbacks.
      Outside the paved core, blend nearby longitudinal targets continuously.
      Segment length compensates for arbitrary OSM/station subdivision. The
      weight vanishes at the outer boundary and dominates near the road edge. }
    U:=EnsureRange((D-S.HalfWidth)/(Extent-S.HalfWidth+S.Feather),0.0001,1.0);
    W:=Sqr(Sqr(1-U))/(U*U)*Len;
    SumW+=W;SumH+=W*SegmentHeight;
    { Different banks have different lateral extents. The maximum of their
      continuous coverage functions stays continuous at a switchback bisector;
      taking coverage only from the nearest segment would jump there. }
    Envelope:=EnsureRange((Extent+S.Feather-D)/S.Feather,0,1);
    Envelope:=Envelope*Envelope*(3-2*Envelope);
    Weight:=Max(Weight,Envelope);
    if D>=Best then Continue;
    Best:=D;H:=SegmentHeight;Core:=D<=S.HalfWidth;
  end;
  if (not Core) and (SumW>0) then H:=SumH/SumW;
  if AreaW>0 then begin
    W:=AreaW+Weight*(1-AreaW);
    H:=(AreaSumH/AreaSumW*AreaW+H*Weight*(1-AreaW))/W;Weight:=W;
  end;
  Height:=H;Result:=Weight>0;
end;
function TMeasuredRoadHeight.ApplyGeo(const P:TLatLon;BaseHeight:Single):Single;
var H,W:Single;
begin
  Result:=BaseHeight;
  if TargetGeo(P,H,W) then Result:=BaseHeight+(H-BaseHeight)*W;
end;
end.

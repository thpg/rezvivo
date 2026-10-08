unit Osm3dFacadeLayout;
{$mode objfpc}{$H+}{$modeswitch advancedrecords}

{ Authored facade inputs are immutable, bounded and stored with the tile.
  X/Z are projected once at bake time. No JSON, geodesy or file I/O per frame. }
interface
uses Classes, SysUtils, Math, fpjson, CastleVectors, Osm3dGeoMath, Osm3dGeomMesh;
const
  FACADE_LAYOUT_TAG = 'rezvivo:facade_layout';
  FACADE_LAYOUT_GENERATOR = 1;
  FACADE_AUTHORED_BIT = 262144;
  MAX_FACADE_LAYOUTS = 4096;
type
  TBuildingTint=packed record OsmId:Int64; Color:Cardinal end;
  TBuildingTints=array of TBuildingTint;
  TFacadeBay = packed record
    Width, FloorShift: Single;
    BalconyFloors: LongWord; { bit 0 = ground floor; at most 24 storeys }
  end;
  TFacadeBays = array of TFacadeBay;
  TFacadeFloats = array of Single;
  TFacadeLayout = record
    OsmId: Int64;
    Start, Finish: TLatLon;
    A, B: TVector2; { tile-local X/Z }
    BalconyDepth, BalconyWidth: Single; { width as a fraction of a bay }
    Bays: TFacadeBays;
    Cornices: TFacadeFloats; { floor boundaries, ground = 0 }
    function Axis: TVector3;
    function Normal: TVector3;
    function LengthM: Single;
    function Matches(const P, N: TVector3; OffsetX:Single=0; OffsetZ:Single=0): Boolean;
    procedure BayAt(U: Single; out Bay: Integer; out BeginU, EndU: Single);
  end;
  TFacadeLayouts = array of TFacadeLayout;

function ParseFacadeLayouts(Value:TJSONData; Cached:Boolean=False):TFacadeLayouts;
function FacadeLayoutsJSON(const Layouts:TFacadeLayouts; Cached:Boolean=False):TJSONObject;
function CanonicalFacadeLayout(Value:TJSONData):string;
procedure ProjectFacadeLayouts(var Layouts:TFacadeLayouts; Projection:TLocalProjection; Id:Int64);
function ScaleFacadeLayouts(const Layouts:TFacadeLayouts; ScaleX:Double):TFacadeLayouts;
function EmitFacadeWall(const Layouts:TFacadeLayouts; const A,B,N:TVector3;
  Top, Floors:Single; Mesh:TMesh):Boolean;
procedure WriteFacadeLayouts(S:TStream; const Layouts:TFacadeLayouts);
function ReadFacadeLayouts(S:TStream):TFacadeLayouts;
function BuildingTintColor(const S:string):Cardinal;
function BuildingTintsJSON(const A:TBuildingTints):TJSONArray;
function ParseBuildingTints(J:TJSONData):TBuildingTints;
procedure WriteBuildingTints(S:TStream;const A:TBuildingTints);
function ReadBuildingTints(S:TStream):TBuildingTints;

implementation

procedure Check(B:Boolean; const Msg:string);
begin if not B then raise EConvertError.Create('facade.layout: '+Msg) end;
function Obj(J:TJSONData):TJSONObject;
begin Check((J<>nil) and (J.JSONType=jtObject),'object required'); Result:=TJSONObject(J) end;
function Arr(J:TJSONData; Lo,Hi:Integer):TJSONArray;
begin
  Check((J<>nil) and (J.JSONType=jtArray),'array required'); Result:=TJSONArray(J);
  Check((Result.Count>=Lo) and (Result.Count<=Hi),'array length out of range');
end;
function Num(J:TJSONData; Lo,Hi:Double):Double;
begin
  Check((J<>nil) and (J.JSONType=jtNumber),'number required'); Result:=J.AsFloat;
  Check(not IsNan(Result) and not IsInfinite(Result) and (Result>=Lo) and (Result<=Hi),'number out of range');
end;
procedure Keys(O:TJSONObject; const Allowed:string);
var I:Integer;
begin for I:=0 to O.Count-1 do Check(Pos('|'+O.Names[I]+'|',Allowed)>0,'unknown field '+O.Names[I]) end;
function Point(J:TJSONData; Geo:Boolean):TVector2;
var V:TJSONArray;
begin
  V:=Arr(J,2,2);
  if Geo then Result:=Vector2(Num(V[0],-180,180),Num(V[1],-85,85))
  else Result:=Vector2(Num(V[0],-2000000,2000000),Num(V[1],-2000000,2000000));
end;
procedure GeoPoint(J:TJSONData; out P:TLatLon);
var V:TJSONArray;
begin V:=Arr(J,2,2); P:=TLatLon.Make(Num(V[1],-85,85),Num(V[0],-180,180)) end;

function ParseFacadeLayouts(Value:TJSONData; Cached:Boolean):TFacadeLayouts;
var Root,F,B:TJSONObject; A,Bays,C,T:TJSONArray; I,J,K,N:Integer; P:TLocalProjection;
    V:Double; Previous:Single; IdText:string; Local:TVector3;
begin
  Result:=nil; Root:=Obj(Value); Keys(Root,'|version|facades|');
  Check(Num(Root.Find('version'),1,1)=1,'unsupported version');
  if Cached then N:=MAX_FACADE_LAYOUTS else N:=8;
  A:=Arr(Root.Find('facades'),1,N); SetLength(Result,A.Count);
  for I:=0 to A.Count-1 do begin
    F:=Obj(A[I]);
    if Cached then Keys(F,'|start|end|bays|cornice_floors|balcony_depth_m|balcony_width|osm_id|local_a|local_b|')
    else Keys(F,'|start|end|bays|cornice_floors|balcony_depth_m|balcony_width|');
    GeoPoint(F.Find('start'),Result[I].Start); GeoPoint(F.Find('end'),Result[I].Finish);
    P:=TLocalProjection.Create(Result[I].Start,Result[I].Start.Lat);
    try
      Result[I].A:=Vector2(0,0); Local:=P.Project(Result[I].Finish,0);
      Result[I].B:=Vector2(Local.X,Local.Z);
    finally P.Free end;
    Bays:=Arr(F.Find('bays'),1,32); SetLength(Result[I].Bays,Bays.Count);
    for J:=0 to Bays.Count-1 do begin
      B:=Obj(Bays[J]); Keys(B,'|width_m|floor_shift|balcony_floors|');
      Result[I].Bays[J].Width:=Num(B.Find('width_m'),1,7);
      if B.Find('floor_shift')<>nil then Result[I].Bays[J].FloorShift:=Num(B.Find('floor_shift'),-0.45,0.45);
      if B.Find('balcony_floors')<>nil then begin
        T:=Arr(B.Find('balcony_floors'),0,23);
        for K:=0 to T.Count-1 do begin
          V:=Num(T[K],1,23); Check(Frac(V)=0,'balcony floor must be integral'); N:=Round(V);
          Check((Result[I].Bays[J].BalconyFloors and (LongWord(1) shl N))=0,'duplicate balcony floor');
          Result[I].Bays[J].BalconyFloors:=Result[I].Bays[J].BalconyFloors or (LongWord(1) shl N);
        end;
      end;
    end;
    C:=Arr(F.Find('cornice_floors'),0,32); SetLength(Result[I].Cornices,C.Count); Previous:=-1;
    for J:=0 to C.Count-1 do begin
      Result[I].Cornices[J]:=Num(C[J],0,64);
      Check(Result[I].Cornices[J]>Previous,'cornices must be strictly increasing'); Previous:=Result[I].Cornices[J];
    end;
    Result[I].BalconyDepth:=0.8; Result[I].BalconyWidth:=0.8;
    if F.Find('balcony_depth_m')<>nil then Result[I].BalconyDepth:=Num(F.Find('balcony_depth_m'),0.25,1.5);
    if F.Find('balcony_width')<>nil then Result[I].BalconyWidth:=Num(F.Find('balcony_width'),0.4,0.95);
    if Cached then begin
      IdText:=F.Get('osm_id',''); Check(TryStrToInt64(IdText,Result[I].OsmId) and (Result[I].OsmId<>0),'osm_id required');
      Result[I].A:=Point(F.Find('local_a'),False); Result[I].B:=Point(F.Find('local_b'),False);
    end;
    Check((Result[I].LengthM>=1) and (Result[I].LengthM<=2000),'facade length must be 1..2000 m');
  end;
end;

function FacadeLayoutsJSON(const Layouts:TFacadeLayouts; Cached:Boolean):TJSONObject;
var Faces,BayList,C,T:TJSONArray; F,O:TJSONObject; I,J,K:Integer;
begin
  Faces:=TJSONArray.Create; Result:=TJSONObject.Create(['version',1,'facades',Faces]);
  for I:=0 to High(Layouts) do with Layouts[I] do begin
    BayList:=TJSONArray.Create; C:=TJSONArray.Create;
    F:=TJSONObject.Create(['start',TJSONArray.Create([Start.Lon,Start.Lat]),
      'end',TJSONArray.Create([Finish.Lon,Finish.Lat]),'bays',BayList,'cornice_floors',C,
      'balcony_depth_m',Double(BalconyDepth),'balcony_width',Double(BalconyWidth)]); Faces.Add(F);
    for J:=0 to High(Bays) do begin
      T:=TJSONArray.Create;
      for K:=1 to 23 do if (Bays[J].BalconyFloors and (LongWord(1) shl K))<>0 then T.Add(K);
      O:=TJSONObject.Create(['width_m',Double(Bays[J].Width),'floor_shift',Double(Bays[J].FloorShift),'balcony_floors',T]); BayList.Add(O);
    end;
    for J:=0 to High(Cornices) do C.Add(Double(Cornices[J]));
    if Cached then begin
      F.Add('osm_id',IntToStr(OsmId)); F.Add('local_a',TJSONArray.Create([Double(A.X),Double(A.Y)]));
      F.Add('local_b',TJSONArray.Create([Double(B.X),Double(B.Y)]));
    end;
  end;
end;

function CanonicalFacadeLayout(Value:TJSONData):string;
var F:TFacadeLayouts; J:TJSONObject;
begin F:=ParseFacadeLayouts(Value); J:=FacadeLayoutsJSON(F); try Result:=J.AsJSON finally J.Free end end;

procedure ProjectFacadeLayouts(var Layouts:TFacadeLayouts; Projection:TLocalProjection; Id:Int64);
var I:Integer; V:TVector3;
begin
  for I:=0 to High(Layouts) do begin
    V:=Projection.Project(Layouts[I].Start,0); Layouts[I].A:=Vector2(V.X,V.Z);
    V:=Projection.Project(Layouts[I].Finish,0); Layouts[I].B:=Vector2(V.X,V.Z); Layouts[I].OsmId:=Id;
  end;
end;
function TFacadeLayout.LengthM:Single;
begin Result:=(B-A).Length end;
function ScaleFacadeLayouts(const Layouts:TFacadeLayouts; ScaleX:Double):TFacadeLayouts;
var I,J:Integer; Ratio,Old:Single;
begin
  Result:=Copy(Layouts);
  if Abs(ScaleX-1)<1e-8 then Exit;
  for I:=0 to High(Result) do begin
    Old:=Result[I].LengthM; Result[I].A.X:=Result[I].A.X*ScaleX; Result[I].B.X:=Result[I].B.X*ScaleX;
    Ratio:=Result[I].LengthM/Old; Result[I].Bays:=Copy(Result[I].Bays);
    for J:=0 to High(Result[I].Bays) do Result[I].Bays[J].Width:=Result[I].Bays[J].Width*Ratio;
  end;
end;
function TFacadeLayout.Axis:TVector3;
begin Result:=Vector3(B.X-A.X,0,B.Y-A.Y).Normalize end;
function TFacadeLayout.Normal:TVector3;
begin Result:=TVector3.CrossProduct(Axis,Vector3(0,1,0)) end;
function TFacadeLayout.Matches(const P,N:TVector3; OffsetX:Single; OffsetZ:Single):Boolean;
var D:TVector3; U:Single;
begin
  D:=P-Vector3(A.X+OffsetX,P.Y,A.Y+OffsetZ); U:=TVector3.DotProduct(D,Axis);
  Result:=(TVector3.DotProduct(N,Normal)>0.995) and (Abs(TVector3.DotProduct(D,Normal))<0.20) and
    (U>=-0.25) and (U<=LengthM+0.25);
end;
procedure TFacadeLayout.BayAt(U:Single; out Bay:Integer; out BeginU,EndU:Single);
var Period,At:Single; I:Integer;
begin
  Period:=0; for I:=0 to High(Bays) do Period:=Period+Bays[I].Width;
  Check(Period>0,'empty bay pattern'); BeginU:=Floor(U/Period)*Period; At:=U-BeginU; Bay:=0;
  while (Bay<High(Bays)) and (At>=Bays[Bay].Width-0.00001) do begin
    At:=At-Bays[Bay].Width; BeginU:=BeginU+Bays[Bay].Width; Inc(Bay);
  end;
  EndU:=BeginU+Bays[Bay].Width;
end;

function EmitFacadeWall(const Layouts:TFacadeLayouts; const A,B,N:TVector3;
  Top,Floors:Single; Mesh:TMesh):Boolean;
var I,Bay,Q0,Q1,Q2,Q3,Guard:Integer; U0,U1,L,R,StartU,EndU,UV0,UV1:Single; P0,P1,Axis:TVector3;
begin
  Result:=False;
  for I:=0 to High(Layouts) do if Layouts[I].Matches(A,N) and Layouts[I].Matches(B,N) then begin
    Axis:=Layouts[I].Axis;
    U0:=TVector3.DotProduct(A-Vector3(Layouts[I].A.X,A.Y,Layouts[I].A.Y),Axis);
    U1:=U0+TVector3.DotProduct(B-A,Axis); L:=U0; Guard:=0;
    if U1<=U0 then Continue;
    while L<U1-0.0001 do begin
      Layouts[I].BayAt(L+0.00002,Bay,StartU,EndU); R:=Min(U1,EndU);
      Check(R>L,'non-progressing bay'); Inc(Guard); Check(Guard<=2002,'too many bays');
      { Preserve the actual OSM endpoints even when its nominally straight
        facade has centimetre deviations. UV projection must not open corners. }
      P0:=A+(B-A)*((L-U0)/(U1-U0)); P1:=A+(B-A)*((R-U0)/(U1-U0));
      UV0:=(L-StartU)/Layouts[I].Bays[Bay].Width; UV1:=(R-StartU)/Layouts[I].Bays[Bay].Width;
      Q0:=Mesh.AddVertex(P0,N,Vector2(UV0,Layouts[I].Bays[Bay].FloorShift));
      Q1:=Mesh.AddVertex(P1,N,Vector2(UV1,Layouts[I].Bays[Bay].FloorShift));
      P0.Y:=Top; P1.Y:=Top;
      Q2:=Mesh.AddVertex(P1,N,Vector2(UV1,Floors+Layouts[I].Bays[Bay].FloorShift));
      Q3:=Mesh.AddVertex(P0,N,Vector2(UV0,Floors+Layouts[I].Bays[Bay].FloorShift));
      Mesh.AddQuad(Q0,Q1,Q2,Q3); L:=R;
    end;
    Exit(True);
  end;
end;

type TFacadeWire=packed record
  Id:Int64; LatA,LonA,LatB,LonB:Double;
  A,B:TVector2; Depth,Width:Single; Bays,Cornices:LongWord;
end;
procedure WriteFacadeLayouts(S:TStream; const Layouts:TFacadeLayouts);
var I:Integer; N,V:LongWord; W:TFacadeWire;
begin
  V:=1; S.WriteBuffer(V,4); N:=Length(Layouts); S.WriteBuffer(N,4);
  for I:=0 to High(Layouts) do with Layouts[I] do begin
    W.Id:=OsmId; W.LatA:=Start.Lat; W.LonA:=Start.Lon; W.LatB:=Finish.Lat; W.LonB:=Finish.Lon;
    W.A:=A; W.B:=B; W.Depth:=BalconyDepth; W.Width:=BalconyWidth; W.Bays:=Length(Bays); W.Cornices:=Length(Cornices);
    S.WriteBuffer(W,SizeOf(W)); S.WriteBuffer(Bays[0],Length(Bays)*SizeOf(TFacadeBay));
    if Length(Cornices)>0 then S.WriteBuffer(Cornices[0],Length(Cornices)*4);
  end;
end;
function ReadFacadeLayouts(S:TStream):TFacadeLayouts;
var I:Integer; N,V:LongWord; W:TFacadeWire; J:TJSONObject;
begin
  Result:=nil; S.ReadBuffer(V,4); Check(V=1,'unsupported binary layout version');
  S.ReadBuffer(N,4); Check((N>0) and (N<=MAX_FACADE_LAYOUTS),'invalid binary facade count'); SetLength(Result,N);
  for I:=0 to High(Result) do with Result[I] do begin
    S.ReadBuffer(W,SizeOf(W)); Check((W.Bays>=1) and (W.Bays<=32) and (W.Cornices<=32),'invalid binary facade arrays');
    OsmId:=W.Id; Start:=TLatLon.Make(W.LatA,W.LonA); Finish:=TLatLon.Make(W.LatB,W.LonB);
    A:=W.A; B:=W.B; BalconyDepth:=W.Depth; BalconyWidth:=W.Width;
    SetLength(Bays,W.Bays); SetLength(Cornices,W.Cornices); S.ReadBuffer(Bays[0],W.Bays*SizeOf(TFacadeBay));
    if W.Cornices>0 then S.ReadBuffer(Cornices[0],W.Cornices*4);
    for V:=0 to W.Bays-1 do Check((Bays[V].BalconyFloors<$1000000) and
      ((Bays[V].BalconyFloors and 1)=0),'invalid balcony floor bits');
  end;
  { One shared semantic validator for external text and compressed tile data. }
  J:=FacadeLayoutsJSON(Result,True); try Result:=ParseFacadeLayouts(J,True) finally J.Free end;
end;
function BuildingTintColor(const S:string):Cardinal;
var I:Integer;
begin
  Check((Length(S)=7) and (S[1]='#'),'tint must be #RRGGBB');
  for I:=2 to 7 do Check(S[I] in ['0'..'9','a'..'f','A'..'F'],'invalid tint');
  Result:=StrToInt('$'+Copy(S,2,6));
end;
function BuildingTintsJSON(const A:TBuildingTints):TJSONArray;
var I:Integer;
begin
  Result:=TJSONArray.Create;
  for I:=0 to High(A) do Result.Add(TJSONObject.Create(['osm_id',IntToStr(A[I].OsmId),
    'color','#'+IntToHex(A[I].Color,6)]));
end;
function ParseBuildingTints(J:TJSONData):TBuildingTints;
var A:TJSONArray; O:TJSONObject; I:Integer; Seen:TStringList; Id:string;
begin
  A:=Arr(J,0,8192); SetLength(Result,A.Count); Seen:=TStringList.Create;
  try
    Seen.Sorted:=True;
    for I:=0 to A.Count-1 do begin
      O:=Obj(A[I]); Keys(O,'|osm_id|color|');
      Check((O.Find('osm_id')<>nil) and (O.Find('osm_id').JSONType=jtString),'tint id must be a string');
      Id:=O.Get('osm_id',''); Check(TryStrToInt64(Id,Result[I].OsmId) and
        (Result[I].OsmId<>0) and (IntToStr(Result[I].OsmId)=Id),'invalid tint id');
      Check(Seen.IndexOf(Id)<0,'duplicate tint id'); Seen.Add(Id);
      Result[I].Color:=BuildingTintColor(O.Get('color',''));
    end;
  finally Seen.Free end;
end;
procedure WriteBuildingTints(S:TStream;const A:TBuildingTints);
var V,N:LongWord;
begin
  V:=1; N:=Length(A); Check(N<=8192,'too many building tints');
  S.WriteBuffer(V,4); S.WriteBuffer(N,4);
  if N>0 then S.WriteBuffer(A[0],N*SizeOf(TBuildingTint));
end;
function ReadBuildingTints(S:TStream):TBuildingTints;
var V,N:LongWord; J:TJSONArray;
begin
  S.ReadBuffer(V,4); S.ReadBuffer(N,4);
  Check((V=1) and (N<=8192) and (S.Size-S.Position=N*SizeOf(TBuildingTint)),'invalid tint chunk');
  SetLength(Result,N); if N>0 then S.ReadBuffer(Result[0],N*SizeOf(TBuildingTint));
  J:=BuildingTintsJSON(Result); try Result:=ParseBuildingTints(J) finally J.Free end;
end;
end.

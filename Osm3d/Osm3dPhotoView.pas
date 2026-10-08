unit Osm3dPhotoView;
{$mode objfpc}{$H+}

{ Geographic photo cameras and bounded landmark fitting. No scene, network or GL. }
interface
uses Classes, SysUtils, fpjson, CastleVectors;

procedure ValidatePhotoView(View: TJSONObject; Sources: TStrings = nil; Objects: TStrings = nil);
procedure ValidatePhotoCamera(Camera: TJSONObject);
procedure PhotoCameraBasis(Camera: TJSONObject; out Direction, Up: TVector3);
function PhotoCameraFromVectors(Lat, Lon, Elevation, ScaleLat, FovY, Aspect: Double;
  const Direction, Up: TVector3): TJSONObject;
function ProjectPhotoView(View: TJSONObject): TJSONObject;
function SolvePhotoView(Request: TJSONObject; Cancel: TThread = nil): TJSONObject;

implementation
uses Math, Osm3dGeoMath;

const CameraFields: array[0..6] of string = ('longitude','latitude','elevation_m',
  'heading_deg','pitch_deg','roll_deg','vertical_fov_deg');
type TParams = array[0..6] of Double;
  TResiduals = array of Double;

function Num(O:TJSONObject; const K:string; Lo,Hi:Double):Double;
var D:TJSONData;
begin
  D:=O.Find(K);
  if (D=nil) or (D.JSONType<>jtNumber) then raise Exception.Create('Photo view: number required: '+K);
  Result:=D.AsFloat;
  if IsNan(Result) or IsInfinite(Result) or (Result<Lo) or (Result>Hi) then
    raise Exception.Create('Photo view: out of range: '+K);
end;

function Text(O:TJSONObject; const K:string):string;
var D:TJSONData;
begin
  D:=O.Find(K);
  if (D=nil) or (D.JSONType<>jtString) or (Trim(D.AsString)='') or (Length(D.AsString)>4096) then
    raise Exception.Create('Photo view: text required: '+K);
  Result:=D.AsString;
end;

function Obj(O:TJSONObject; const K:string):TJSONObject;
var D:TJSONData;
begin
  D:=O.Find(K); if not (D is TJSONObject) then raise Exception.Create('Photo view: object required: '+K);
  Result:=TJSONObject(D);
end;

function Arr(O:TJSONObject; const K:string; MaxCount:Integer):TJSONArray;
var D:TJSONData;
begin
  D:=O.Find(K); if not (D is TJSONArray) then raise Exception.Create('Photo view: array required: '+K);
  Result:=TJSONArray(D);
  if Result.Count>MaxCount then raise Exception.Create('Photo view: too many '+K);
end;

procedure Fields(O:TJSONObject; const Allowed:string);
var I,J:Integer;
begin
  for I:=0 to O.Count-1 do begin
    if Pos('|'+O.Names[I]+'|','|'+Allowed+'|')=0 then raise Exception.Create('Unknown photo view field: '+O.Names[I]);
    for J:=0 to I-1 do if O.Names[I]=O.Names[J] then raise Exception.Create('Duplicate photo view field: '+O.Names[I]);
  end;
end;

procedure Enum(O:TJSONObject; const K,Allowed:string);
begin if Pos('|'+Text(O,K)+'|','|'+Allowed+'|')=0 then raise Exception.Create('Photo view: invalid '+K) end;

procedure UV(A:TJSONArray; Count:Integer);
var I:Integer; V:Double;
begin
  if A.Count<>Count then raise Exception.Create('Photo view: invalid coordinate array');
  for I:=0 to Count-1 do begin
    if A.Items[I].JSONType<>jtNumber then raise Exception.Create('Photo view: numeric image coordinate required');
    V:=A.Floats[I];
    if IsNan(V) or IsInfinite(V) or (V<0) or (V>1) then raise Exception.Create('Photo view: image coordinate outside 0..1');
  end;
end;

procedure ValidatePhotoCamera(Camera:TJSONObject);
begin
  Fields(Camera,'latitude|longitude|elevation_m|scale_latitude_deg|heading_deg|pitch_deg|roll_deg|vertical_fov_deg|aspect_ratio|ground_elevation_m|height_above_ground_m');
  Num(Camera,'latitude',-85,85); Num(Camera,'longitude',-180,180); Num(Camera,'elevation_m',-1000,15000);
  Num(Camera,'scale_latitude_deg',-85,85); Num(Camera,'heading_deg',0,360);
  Num(Camera,'pitch_deg',-89,89); Num(Camera,'roll_deg',-180,180);
  Num(Camera,'vertical_fov_deg',5,140); Num(Camera,'aspect_ratio',0.1,10);
  if (Camera.Find('ground_elevation_m')<>nil) or (Camera.Find('height_above_ground_m')<>nil) then
    if Abs(Num(Camera,'ground_elevation_m',-1000,15000)+Num(Camera,'height_above_ground_m',-100,15000)-Camera.Get('elevation_m',0.0))>0.01 then
      raise Exception.Create('Photo view: absolute and relative heights disagree');
end;

procedure ValidatePhotoView(View:TJSONObject; Sources:TStrings; Objects:TStrings);
var C,I,A,O,R:TJSONObject; Anchors,Regions,Points,Known,Crop:TJSONArray;
  Ids:TStringList; J,K:Integer; S:string; N:Int64; W,H:Double;
begin
  if Length(View.AsJSON)>256*1024 then raise Exception.Create('Photo view exceeds 256 KiB');
  Fields(View,'id|source_id|label|note|status|confidence|camera|image|anchors|regions|known_parameters');
  Text(View,'id'); S:=Text(View,'source_id');
  if (Sources<>nil) and (Sources.IndexOf(S)<0) then raise Exception.Create('Photo view: unknown source '+S);
  Text(View,'label'); Enum(View,'status','draft|matched|ambiguous|rejected'); Num(View,'confidence',0,1);
  C:=Obj(View,'camera'); ValidatePhotoCamera(C);
  I:=Obj(View,'image'); Fields(I,'width_px|height_px|projection|crop|frame_time_s|panorama_view');
  Enum(I,'projection','perspective');
  W:=Num(I,'width_px',16,32768); H:=Num(I,'height_px',16,32768);
  if (W<>Trunc(W)) or (H<>Trunc(H)) then raise Exception.Create('Photo view: integer image size required');
  Crop:=Arr(I,'crop',4); UV(Crop,4);
  if (Crop.Floats[2]<=Crop.Floats[0]) or (Crop.Floats[3]<=Crop.Floats[1]) then raise Exception.Create('Photo view: empty crop');
  if Abs(W*(Crop.Floats[2]-Crop.Floats[0])/(H*(Crop.Floats[3]-Crop.Floats[1]))-C.Get('aspect_ratio',0.0))>0.001 then
    raise Exception.Create('Photo view: camera aspect does not match the image crop');
  if I.Find('frame_time_s')<>nil then Num(I,'frame_time_s',0,1e8);
  if I.Find('panorama_view')<>nil then begin
    O:=Obj(I,'panorama_view'); Fields(O,'heading_deg|pitch_deg|vertical_fov_deg');
    Num(O,'heading_deg',0,360); Num(O,'pitch_deg',-89,89); Num(O,'vertical_fov_deg',5,140);
  end;
  Known:=Arr(View,'known_parameters',7); Ids:=TStringList.Create; Ids.CaseSensitive:=True;
  try
    for J:=0 to Known.Count-1 do begin
      if Known.Items[J].JSONType<>jtString then raise Exception.Create('Photo view: known parameter must be text');
      S:=Known.Strings[J];
      if (Pos('|'+S+'|','|longitude|latitude|elevation_m|heading_deg|pitch_deg|roll_deg|vertical_fov_deg|')=0) or (Ids.IndexOf(S)>=0) then
        raise Exception.Create('Photo view: invalid/duplicate known parameter');
      Ids.Add(S);
    end;
    Ids.Clear; Anchors:=Arr(View,'anchors',128);
    for J:=0 to Anchors.Count-1 do begin
      if not (Anchors.Items[J] is TJSONObject) then raise Exception.Create('Photo view: invalid anchor');
      A:=TJSONObject(Anchors.Items[J]);
      Fields(A,'id|description|osm_ref|latitude|longitude|elevation_m|image_uv|role|basis|weight|uncertainty_m');
      S:=Text(A,'id'); if Ids.IndexOf(S)>=0 then raise Exception.Create('Photo view: duplicate anchor'); Ids.Add(S);
      Text(A,'description'); Num(A,'latitude',-85,85); Num(A,'longitude',-180,180); Num(A,'elevation_m',-1000,15000);
      if Abs(A.Get('latitude',0.0)-C.Get('latitude',0.0))>0.2 then raise Exception.Create('Photo view: anchor too far away');
      if Abs(A.Get('longitude',0.0)-C.Get('longitude',0.0))*Cos(DegToRad(C.Get('latitude',0.0)))>0.2 then raise Exception.Create('Photo view: anchor too far away');
      UV(Arr(A,'image_uv',2),2); Enum(A,'role','fit|check');
      Enum(A,'basis','osm_footprint|surveyed|terrain|assumed_geometry');
      if (A.Get('role','')='fit') and (A.Get('basis','')='assumed_geometry') then
        raise Exception.Create('Photo view: unverified geometry may be checked, not used to fit the camera');
      if A.Find('weight')<>nil then Num(A,'weight',0.01,100);
      if A.Find('uncertainty_m')<>nil then Num(A,'uncertainty_m',0,1000);
      R:=Obj(A,'osm_ref'); Fields(R,'type|id|fingerprint'); Enum(R,'type','node|way|relation'); S:=Text(R,'id');
      if not TryStrToInt64(S,N) or (N<=0) or (IntToStr(N)<>S) then raise Exception.Create('Photo view: invalid OSM ID');
    end;
    Regions:=Arr(View,'regions',128);
    for J:=0 to Regions.Count-1 do begin
      if not (Regions.Items[J] is TJSONObject) then raise Exception.Create('Photo view: invalid region');
      O:=TJSONObject(Regions.Items[J]); Fields(O,'object_id|role|polygon'); S:=Text(O,'object_id');
      if (Objects<>nil) and (Objects.IndexOf(S)<0) then raise Exception.Create('Photo view: unknown region object');
      Enum(O,'role','visible|occluded|ignore'); Points:=Arr(O,'polygon',128);
      if Points.Count<3 then raise Exception.Create('Photo view: region needs 3 points');
      for K:=0 to Points.Count-1 do begin
        if not (Points.Items[K] is TJSONArray) then raise Exception.Create('Photo view: invalid polygon'); UV(TJSONArray(Points.Items[K]),2);
      end;
    end;
  finally Ids.Free end;
end;

procedure PhotoCameraBasis(Camera:TJSONObject; out Direction,Up:TVector3);
var H,P,R:Double; Right,BaseUp:TVector3;
begin
  H:=DegToRad(Camera.Get('heading_deg',0.0)); P:=DegToRad(Camera.Get('pitch_deg',0.0)); R:=DegToRad(Camera.Get('roll_deg',0.0));
  Direction:=Vector3(-Sin(H)*Cos(P),Sin(P),Cos(H)*Cos(P));
  Right:=Vector3(-Cos(H),0,-Sin(H)); BaseUp:=TVector3.CrossProduct(Right,Direction);
  Up:=BaseUp*Cos(R)+Right*Sin(R);
end;

function PhotoCameraFromVectors(Lat,Lon,Elevation,ScaleLat,FovY,Aspect:Double; const Direction,Up:TVector3):TJSONObject;
var D,U,R,B:TVector3; H,P,Roll:Double;
begin
  D:=Direction.Normalize; R:=TVector3.CrossProduct(D,Up).Normalize; U:=TVector3.CrossProduct(R,D);
  H:=RadToDeg(ArcTan2(-D.X,D.Z)); if H<0 then H:=H+360;
  P:=RadToDeg(ArcSin(EnsureRange(D.Y,-1.0,1.0)));
  R:=Vector3(-Cos(DegToRad(H)),0,-Sin(DegToRad(H))); B:=TVector3.CrossProduct(R,D);
  Roll:=RadToDeg(ArcTan2(TVector3.DotProduct(U,R),TVector3.DotProduct(U,B)));
  Result:=TJSONObject.Create(['latitude',Lat,'longitude',Lon,'elevation_m',Elevation,'scale_latitude_deg',ScaleLat,
    'heading_deg',H,'pitch_deg',P,'roll_deg',Roll,'vertical_fov_deg',FovY,'aspect_ratio',Aspect]);
end;

function ProjectInternal(View:TJSONObject; out Residual:TResiduals; FitOnly:Boolean):TJSONObject;
var Camera,Anchor,Row:TJSONObject; Anchors,Rows,Crop:TJSONArray;
  D,U,R,Q:TVector3; Proj:TLocalProjection; K,Count,Visible:Integer;
  Depth,X,Y,E,Total,MaxError,Weight,W,H,T:Double;
begin
  Camera:=Obj(View,'camera'); PhotoCameraBasis(Camera,D,U); R:=TVector3.CrossProduct(D,U);
  Proj:=TLocalProjection.Create(TLatLon.Make(Camera.Get('latitude',0.0),Camera.Get('longitude',0.0)),Camera.Get('scale_latitude_deg',0.0));
  Rows:=TJSONArray.Create; Result:=TJSONObject.Create(['points',Rows]);
  Anchors:=Arr(View,'anchors',128); SetLength(Residual,Anchors.Count*2); Count:=0; Visible:=0; Total:=0; MaxError:=0;
  Crop:=Arr(Obj(View,'image'),'crop',4);
  W:=Obj(View,'image').Get('width_px',0.0)*(Crop.Floats[2]-Crop.Floats[0]);
  H:=Obj(View,'image').Get('height_px',0.0)*(Crop.Floats[3]-Crop.Floats[1]);
  T:=Tan(DegToRad(Camera.Get('vertical_fov_deg',45.0))/2);
  try try
    for K:=0 to Anchors.Count-1 do begin
      Anchor:=TJSONObject(Anchors.Items[K]);
      if FitOnly and (Anchor.Get('role','')<>'fit') then Continue;
      Q:=Proj.Project(TLatLon.Make(Anchor.Get('latitude',0.0),Anchor.Get('longitude',0.0)),Anchor.Get('elevation_m',0.0)-Camera.Get('elevation_m',0.0));
      Depth:=TVector3.DotProduct(Q,D);
      if Depth>0.05 then begin
        X:=0.5+TVector3.DotProduct(Q,R)/(2*Depth*T*Camera.Get('aspect_ratio',1.0));
        Y:=0.5-TVector3.DotProduct(Q,U)/(2*Depth*T); Inc(Visible);
      end else begin X:=1e3; Y:=1e3 end;
      Row:=TJSONObject.Create(['id',Anchor.Get('id',''),'role',Anchor.Get('role',''),'in_front',Depth>0.05,'depth_m',Depth]); Rows.Add(Row);
      Row.Add('projected_uv',TJSONArray.Create([X,Y]));
      X:=(X-Arr(Anchor,'image_uv',2).Floats[0])*W; Y:=(Y-Arr(Anchor,'image_uv',2).Floats[1])*H;
      E:=Sqrt(Sqr(X)+Sqr(Y)); Weight:=Anchor.Get('weight',1.0);
      Residual[Count*2]:=X*Sqrt(Weight); Residual[Count*2+1]:=Y*Sqrt(Weight);
      Inc(Count); Total:=Total+Sqr(E); MaxError:=Max(MaxError,E); Row.Add('error_px',E);
    end;
    SetLength(Residual,Count*2); Result.Add('count',Count); Result.Add('in_front',Visible);
    Result.Add('rms_px',Sqrt(Total/Max(1,Count))); Result.Add('max_error_px',MaxError);
  except Result.Free; raise end;
  finally Proj.Free end;
end;

function ProjectPhotoView(View:TJSONObject):TJSONObject;
var R:TResiduals;
begin ValidatePhotoView(View); Result:=ProjectInternal(View,R,False) end;

function SolvePhotoView(Request:TJSONObject; Cancel:TThread):TJSONObject;
const DerivativeStep:TParams=(0.02,0.02,0.02,0.005,0.005,0.005,0.005);
var View,Camera,Initial,Seed,Report,BestView:TJSONObject; Seeds,Candidates,Known:TJSONArray;
  Values,Trial,Start,LowBound,HighBound,Delta:TParams;
  FreeParam:array[0..6]of Boolean; Jacobian:array[0..6]of TResiduals;
  R,R2:TResiduals; Normal:array[0..6,0..7]of Double;
  I,J,K,N,It,SeedIndex,FitCount,FreeCount,MaxIt,BestIndex:Integer;
  OriginLat,OriginLon,MpdLat,MpdLon,Radius,AngleRadius,FovRadius,Lambda,Cost,TrialCost,V,Pivot,F,Bias,BestCost,MaxSpread:Double;
  AllFront,AtBound,Improved:Boolean;
  function CostOf(const A:TResiduals):Double;
  var L:Integer; E:Double;
  begin Result:=0; for L:=0 to High(A) do begin E:=Abs(A[L]); if E<=8 then Result:=Result+E*E else Result:=Result+16*E-64 end end;
  procedure SetCamera(const P:TParams);
  var H:Double; L:Integer;
  begin
    Camera.Floats['longitude']:=OriginLon+P[0]/MpdLon; Camera.Floats['latitude']:=OriginLat+P[1]/MpdLat;
    for L:=2 to 6 do Camera.Floats[CameraFields[L]]:=P[L];
    H:=P[3]-Floor(P[3]/360)*360; Camera.Floats['heading_deg']:=H;
    { Preserve measured/locked values verbatim, without numerical fitting or wrapping. }
    for L:=0 to 6 do if not FreeParam[L] then begin
      Camera.Delete(CameraFields[L]); Camera.Add(CameraFields[L],Initial.Find(CameraFields[L]).Clone);
    end;
    if Camera.Find('ground_elevation_m')<>nil then Camera.Floats['height_above_ground_m']:=P[2]-Camera.Get('ground_elevation_m',0.0);
  end;
  procedure ReadCamera(C:TJSONObject; out P:TParams);
  var L:Integer;
  begin
    ValidatePhotoCamera(C); P[0]:=(C.Get('longitude',0.0)-OriginLon)*MpdLon; P[1]:=(C.Get('latitude',0.0)-OriginLat)*MpdLat;
    for L:=2 to 6 do P[L]:=C.Get(CameraFields[L],0.0);
    if Abs(C.Get('scale_latitude_deg',0.0)-Initial.Get('scale_latitude_deg',0.0))>1e-9 then raise Exception.Create('Photo fit: all seeds must use the same map scale');
  end;
  procedure Evaluate(const P:TParams; out Res:TResiduals; out C:Double);
  var D:TJSONObject;
  begin
    SetCamera(P); D:=ProjectInternal(View,Res,True);
    try C:=CostOf(Res) finally D.Free end;
  end;
begin
  Initial:=Obj(Obj(Request,'view'),'camera'); ValidatePhotoView(Obj(Request,'view'));
  Known:=Arr(Obj(Request,'view'),'known_parameters',7); FreeCount:=0;
  for I:=0 to 6 do begin
    FreeParam[I]:=True; for J:=0 to Known.Count-1 do if Known.Strings[J]=CameraFields[I] then FreeParam[I]:=False;
    if FreeParam[I] then Inc(FreeCount);
  end;
  if FreeCount=0 then raise Exception.Create('Photo fit: every camera parameter is fixed');
  FitCount:=0; Seeds:=Arr(Obj(Request,'view'),'anchors',128); MaxSpread:=0;
  for I:=0 to Seeds.Count-1 do if TJSONObject(Seeds.Items[I]).Get('role','')='fit' then Inc(FitCount);
  if (FitCount<4) or (FitCount*2<FreeCount+2) then raise Exception.Create('Photo fit requires at least four independent fit anchors');
  { At least one non-collinear image triple. Repeated/collinear points cannot constrain a camera. }
  for I:=0 to Seeds.Count-1 do if TJSONObject(Seeds.Items[I]).Get('role','')='fit' then
    for J:=I+1 to Seeds.Count-1 do if TJSONObject(Seeds.Items[J]).Get('role','')='fit' then
      for K:=J+1 to Seeds.Count-1 do if TJSONObject(Seeds.Items[K]).Get('role','')='fit' then begin
        V:=(Obj(Request,'view').Arrays['anchors'].Objects[J].Arrays['image_uv'].Floats[0]-Seeds.Objects[I].Arrays['image_uv'].Floats[0])*
          (Seeds.Objects[K].Arrays['image_uv'].Floats[1]-Seeds.Objects[I].Arrays['image_uv'].Floats[1])-
          (Seeds.Objects[J].Arrays['image_uv'].Floats[1]-Seeds.Objects[I].Arrays['image_uv'].Floats[1])*
          (Seeds.Objects[K].Arrays['image_uv'].Floats[0]-Seeds.Objects[I].Arrays['image_uv'].Floats[0]); MaxSpread:=Max(MaxSpread,Abs(V));
      end;
  if MaxSpread<0.0001 then raise Exception.Create('Photo fit: image anchors are collinear or occupy too little area');
  Radius:=30; AngleRadius:=30; FovRadius:=20;
  if Request.Find('position_radius_m')<>nil then Radius:=Num(Request,'position_radius_m',0.01,500);
  if Request.Find('angle_radius_deg')<>nil then AngleRadius:=Num(Request,'angle_radius_deg',0.01,180);
  if Request.Find('fov_radius_deg')<>nil then FovRadius:=Num(Request,'fov_radius_deg',0.01,60);
  MaxIt:=80;
  if Request.Find('max_iterations')<>nil then begin
    V:=Num(Request,'max_iterations',1,120);
    if V<>Trunc(V) then raise Exception.Create('Photo fit: iterations must be an integer');
    MaxIt:=Trunc(V);
  end;
  Seeds:=TJSONArray.Create; View:=nil; BestView:=nil; Result:=nil;
  try try
    Seeds.Add(Initial.Clone);
    if Request.Find('seeds')<>nil then begin
      for I:=0 to Arr(Request,'seeds',7).Count-1 do begin
        if not (Request.Arrays['seeds'].Items[I] is TJSONObject) then raise Exception.Create('Photo fit: seed must be a camera');
        Seeds.Add(Request.Arrays['seeds'].Items[I].Clone);
      end;
    end else if FreeParam[3] then begin
      for I:=0 to 1 do begin
        Seed:=TJSONObject(Initial.Clone); V:=Seed.Get('heading_deg',0.0)+(I*2-1)*Min(10,AngleRadius);
        Seed.Floats['heading_deg']:=V-Floor(V/360)*360; Seeds.Add(Seed);
      end;
    end;
    View:=TJSONObject(Obj(Request,'view').Clone); Camera:=Obj(View,'camera');
    OriginLat:=Initial.Get('latitude',0.0); OriginLon:=Initial.Get('longitude',0.0);
    MpdLat:=EARTH_RADIUS_M*Pi/180; MpdLon:=MpdLat*Cos(DegToRad(Initial.Get('scale_latitude_deg',OriginLat)));
    Candidates:=TJSONArray.Create; Result:=TJSONObject.Create(['saved',False,'geometry_applied',False,'candidates',Candidates]);
    BestCost:=1e300; BestIndex:=-1;
    for SeedIndex:=0 to Seeds.Count-1 do begin
      if (Cancel<>nil) and Cancel.CheckTerminated then raise EAbort.Create('cancelled');
      ReadCamera(TJSONObject(Seeds.Items[SeedIndex]),Values); ReadCamera(Initial,Start);
      while Values[3]-Start[3]>180 do Values[3]:=Values[3]-360;
      while Values[3]-Start[3]<-180 do Values[3]:=Values[3]+360;
      for I:=0 to 6 do begin
        if I<3 then V:=Radius else if I=6 then V:=FovRadius else V:=AngleRadius;
        LowBound[I]:=Start[I]-V; HighBound[I]:=Start[I]+V;
        if not FreeParam[I] then begin LowBound[I]:=Start[I]; HighBound[I]:=Start[I] end;
      end;
      LowBound[2]:=Max(-1000,LowBound[2]); HighBound[2]:=Min(15000,HighBound[2]);
      LowBound[4]:=Max(-89,LowBound[4]); HighBound[4]:=Min(89,HighBound[4]);
      LowBound[5]:=Max(-180,LowBound[5]); HighBound[5]:=Min(180,HighBound[5]);
      LowBound[6]:=Max(5,LowBound[6]); HighBound[6]:=Min(140,HighBound[6]);
      for I:=0 to 6 do Values[I]:=EnsureRange(Values[I],LowBound[I],HighBound[I]);
      Evaluate(Values,R,Cost); Lambda:=0.001;
      for It:=1 to MaxIt do begin
        if (Cancel<>nil) and Cancel.CheckTerminated then raise EAbort.Create('cancelled');
        for I:=0 to 6 do if FreeParam[I] then begin
          Trial:=Values; Trial[I]:=Trial[I]+DerivativeStep[I]; Evaluate(Trial,R2,TrialCost);
          SetLength(Jacobian[I],Length(R)); for J:=0 to High(R) do Jacobian[I][J]:=(R2[J]-R[J])/DerivativeStep[I];
        end;
        FillChar(Normal,SizeOf(Normal),0);
        for I:=0 to 6 do if FreeParam[I] then begin
          for J:=0 to High(R) do begin
            F:=Min(1.0,8/Max(0.00001,Abs(R[J])));
            Normal[I,7]:=Normal[I,7]-Jacobian[I][J]*R[J]*F;
            for K:=0 to 6 do if FreeParam[K] then Normal[I,K]:=Normal[I,K]+Jacobian[I][J]*Jacobian[K][J]*F;
          end;
          Normal[I,I]:=Normal[I,I]+Lambda*Max(1.0,Normal[I,I]);
        end else Normal[I,I]:=1;
        for I:=0 to 6 do begin
          N:=I; for J:=I+1 to 6 do if Abs(Normal[J,I])>Abs(Normal[N,I]) then N:=J;
          for J:=I to 7 do begin V:=Normal[I,J]; Normal[I,J]:=Normal[N,J]; Normal[N,J]:=V end;
          Pivot:=Normal[I,I]; if Abs(Pivot)<1e-12 then Break;
          for J:=I to 7 do Normal[I,J]:=Normal[I,J]/Pivot;
          for K:=0 to 6 do if K<>I then begin F:=Normal[K,I]; for J:=I to 7 do Normal[K,J]:=Normal[K,J]-F*Normal[I,J] end;
        end;
        if Abs(Pivot)<1e-12 then Break;
        Bias:=0; for I:=0 to 6 do begin Delta[I]:=Normal[I,7]; Trial[I]:=EnsureRange(Values[I]+Delta[I],LowBound[I],HighBound[I]); Bias:=Bias+Sqr(Trial[I]-Values[I]) end;
        Evaluate(Trial,R2,TrialCost); Improved:=TrialCost<Cost;
        if Improved then begin Values:=Trial; R:=R2; Cost:=TrialCost; Lambda:=Max(1e-9,Lambda/3) end
        else Lambda:=Min(1e12,Lambda*8);
        if (Bias<1e-10) or (Lambda>=1e12) then Break;
      end;
      SetCamera(Values); Report:=ProjectInternal(View,R,True); AllFront:=Report.Get('in_front',0)=FitCount;
      AtBound:=False; for I:=0 to 6 do if FreeParam[I] and ((Abs(Values[I]-LowBound[I])<0.01) or (Abs(Values[I]-HighBound[I])<0.01)) then AtBound:=True;
      Seed:=TJSONObject.Create(['camera',Camera.Clone,'fit',Report,'at_bounds',AtBound,'all_in_front',AllFront,'cost',Cost]);
      Candidates.Add(Seed);
      if AllFront and (Cost<BestCost) then begin BestCost:=Cost; BestIndex:=SeedIndex; FreeAndNil(BestView); BestView:=TJSONObject(View.Clone) end;
    end;
    Result.Add('best_index',BestIndex); Result.Add('solved',BestIndex>=0);
    Result.Add('note','Landmark fit is a camera hypothesis, not proof of photo identity or correct building geometry. Review held-out check points and alternative candidates.');
    if BestView<>nil then begin
      BestView.Strings['status']:='draft'; BestView.Floats['confidence']:=Min(BestView.Get('confidence',0.0),0.5);
      Result.Add('projection',ProjectPhotoView(BestView)); Result.Add('view',BestView); BestView:=nil;
    end;
  except Result.Free; Result:=nil; raise end;
  finally BestView.Free; View.Free; Seeds.Free end;
end;
end.

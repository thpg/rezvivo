unit Osm3dPhotoRouteScope;
{$mode objfpc}{$H+}
{ Optional authoring scope. Reuses route coverage clipping; never changes the
  source OSM cache or the geometry of an ordinary tile. }
interface
uses SysUtils,Math,fpjson,Osm3dGeoMath,Osm3dMapUtils;
type
  TPhotoRouteScope=class
  private
    FPoints:TRouteLatLonArray;
    FSegments:array of record A,B:TLatLon end;
    FEnabled:Boolean;
    FRadius:Double;
    FId:string;
  public
    constructor Create(J:TJSONData);
    procedure LimitTo(const Box:TLatLonBox);
    function HitsBox(const Box:TLatLonBox):Boolean;
    function Contains(Lat,Lon:Double):Boolean;
    function QueryBox(const Box:TLatLonBox):TLatLonBox;
    function Summary:TJSONObject;
    function ToJSON:TJSONObject;
    property Enabled:Boolean read FEnabled;
  end;
implementation
uses Osm3dRouteCoverage;
procedure Check(OK:Boolean;const Msg:string);
begin if not OK then raise EConvertError.Create('route_scope: '+Msg) end;
function Number(J:TJSONData;Lo,Hi:Double):Double;
begin
  Check((J<>nil) and (J.JSONType=jtNumber),'numeric value required'); Result:=J.AsFloat;
  Check(not IsNan(Result) and not IsInfinite(Result) and (Result>=Lo) and (Result<=Hi),'number out of range');
end;
constructor TPhotoRouteScope.Create(J:TJSONData);
var O:TJSONObject;A,P:TJSONArray;I:Integer;
begin
  inherited Create; if J=nil then Exit;
  Check(J.JSONType=jtObject,'object required'); O:=TJSONObject(J);
  for I:=0 to O.Count-1 do Check(Pos('|'+O.Names[I]+'|','|enabled|route_id|radius_m|points|')>0,'unknown field '+O.Names[I]);
  if O.Find('enabled')<>nil then Check(O.Find('enabled').JSONType=jtBoolean,'enabled must be boolean');
  FEnabled:=O.Get('enabled',True); if not FEnabled then Exit;
  FRadius:=150; if O.Find('radius_m')<>nil then FRadius:=Number(O.Find('radius_m'),10,1000);
  if O.Find('route_id')<>nil then Check(O.Find('route_id').JSONType=jtString,'route_id must be a string');
  FId:=O.Get('route_id',''); Check(Length(FId)<=200,'route_id too long');
  J:=O.Find('points'); Check((J<>nil) and (J.JSONType=jtArray),'points [lon,lat] required'); A:=TJSONArray(J);
  Check((A.Count>=2) and (A.Count<=20000),'2..20000 route points required'); SetLength(FPoints,A.Count);
  for I:=0 to A.Count-1 do begin
    Check((A[I].JSONType=jtArray) and (A[I].Count=2),'point must be [lon,lat]'); P:=TJSONArray(A[I]);
    FPoints[I]:=TLatLon.Make(Number(P[1],-85,85),Number(P[0],-180,180));
    if I>0 then Check(Abs(FPoints[I].Lon-FPoints[I-1].Lon)<=180,'split a dateline-crossing route into local sections');
  end;
  SetLength(FSegments,Length(FPoints)-1);
  for I:=0 to High(FSegments) do begin FSegments[I].A:=FPoints[I]; FSegments[I].B:=FPoints[I+1] end;
end;
procedure TPhotoRouteScope.LimitTo(const Box:TLatLonBox);
var I,N:Integer; A,B:TLatLon; Bound:TLatLonBox;
begin
  if not FEnabled then Exit; Bound:=Box.ExpandMeters(FRadius); N:=0;
  SetLength(FSegments,Length(FPoints)-1);
  for I:=0 to High(FPoints)-1 do
    if ClipRouteSegment(FPoints[I],FPoints[I+1],Bound,A,B) then begin
      FSegments[N].A:=A; FSegments[N].B:=B; Inc(N);
    end;
  SetLength(FSegments,N);
end;
function TPhotoRouteScope.HitsBox(const Box:TLatLonBox):Boolean;
var I:Integer; A,B:TLatLon; Expanded:TLatLonBox;
    Lat0,Lon0,KX,KY,X0,Y0,X1,Y1,LoX,LoY,HiX,HiY,R2:Double;
  function PointSeg(X,Y:Double):Double;
  var DX,DY,T,D:Double;
  begin
    DX:=X1-X0; DY:=Y1-Y0; D:=DX*DX+DY*DY; T:=0;
    if D>1e-12 then T:=Max(0.0,Min(1.0,((X-X0)*DX+(Y-Y0)*DY)/D));
    Result:=Sqr(X-X0-T*DX)+Sqr(Y-Y0-T*DY);
  end;
  function PointBox(X,Y:Double):Double;
  begin Result:=Sqr(Max(LoX-X,Max(0.0,X-HiX)))+Sqr(Max(LoY-Y,Max(0.0,Y-HiY))) end;
begin
  if not FEnabled then Exit(True);
  Result:=False; if Box.IsEmpty then Exit;
  Expanded:=Box.ExpandMeters(FRadius);
  Lat0:=(Box.MinLat+Box.MaxLat)*0.5; Lon0:=(Box.MinLon+Box.MaxLon)*0.5;
  KY:=111319.49079327358; KX:=KY*Cos(DegToRad(Lat0)); R2:=Sqr(FRadius);
  LoX:=(Box.MinLon-Lon0)*KX; HiX:=(Box.MaxLon-Lon0)*KX;
  LoY:=(Box.MinLat-Lat0)*KY; HiY:=(Box.MaxLat-Lat0)*KY;
  for I:=0 to High(FSegments) do begin
    if not ClipRouteSegment(FSegments[I].A,FSegments[I].B,Expanded,A,B) then Continue;
    if ClipRouteSegment(A,B,Box,A,B) then Exit(True);
    X0:=(FSegments[I].A.Lon-Lon0)*KX; Y0:=(FSegments[I].A.Lat-Lat0)*KY;
    X1:=(FSegments[I].B.Lon-Lon0)*KX; Y1:=(FSegments[I].B.Lat-Lat0)*KY;
    if (PointBox(X0,Y0)<=R2) or (PointBox(X1,Y1)<=R2) or
       (PointSeg(LoX,LoY)<=R2) or (PointSeg(LoX,HiY)<=R2) or
       (PointSeg(HiX,LoY)<=R2) or (PointSeg(HiX,HiY)<=R2) then Exit(True);
  end;
end;
function TPhotoRouteScope.Contains(Lat,Lon:Double):Boolean;
begin Result:=HitsBox(TLatLonBox.Make(Lat,Lon,Lat,Lon)) end;
function TPhotoRouteScope.QueryBox(const Box:TLatLonBox):TLatLonBox;
var I:Integer; A,B:TLatLon; Bound:TLatLonBox;
begin
  if not FEnabled then Exit(Box);
  Result:=TLatLonBox.Empty; Bound:=Box.ExpandMeters(FRadius);
  for I:=0 to High(FSegments) do if ClipRouteSegment(FSegments[I].A,FSegments[I].B,Bound,A,B) then
    Result:=Result.Include(A).Include(B);
  if Result.IsEmpty then Exit;
  Result:=Result.ExpandMeters(FRadius);
  if Result.MinLat<Box.MinLat then Result.MinLat:=Box.MinLat;
  if Result.MinLon<Box.MinLon then Result.MinLon:=Box.MinLon;
  if Result.MaxLat>Box.MaxLat then Result.MaxLat:=Box.MaxLat;
  if Result.MaxLon>Box.MaxLon then Result.MaxLon:=Box.MaxLon;
end;
function TPhotoRouteScope.Summary:TJSONObject;
begin
  Result:=TJSONObject.Create(['enabled',FEnabled]);
  if FEnabled then begin
    Result.Add('route_id',FId); Result.Add('radius_m',FRadius); Result.Add('point_count',Length(FPoints));
    Result.Add('local_segments',Length(FSegments)); Result.Add('coverage','route corridor only; not the whole tile');
  end;
end;
function TPhotoRouteScope.ToJSON:TJSONObject;
var A:TJSONArray; I:Integer;
begin
  Result:=TJSONObject.Create(['enabled',FEnabled]); if not FEnabled then Exit;
  Result.Add('route_id',FId); Result.Add('radius_m',FRadius); A:=TJSONArray.Create; Result.Add('points',A);
  for I:=0 to High(FPoints) do A.Add(TJSONArray.Create([FPoints[I].Lon,FPoints[I].Lat]));
end;
end.

program PhotoRouteScopeTests;
{$mode objfpc}{$H+}
uses SysUtils,fpjson,jsonparser,Osm3dGeoMath,Osm3dPhotoRouteScope;
var J:TJSONData; S:TPhotoRouteScope; B:TLatLonBox; Failed:Boolean;
procedure Check(B:Boolean;const Msg:string);
begin if not B then raise Exception.Create(Msg) end;
begin
 try
  J:=GetJSON('{"route_id":"closed","radius_m":100,"points":[[0,0],[0.02,0],[0.02,0.02],[0,0.02],[0,0]]}');
  S:=TPhotoRouteScope.Create(J); J.Free;
  try
    Check(S.Contains(0,0.01),'segment interior, not just route points');
    Check(S.Contains(0.0008,0.01),'within 100 metres');
    Check(not S.Contains(0.0011,0.01),'outside 100 metres');
    Check(not S.Contains(0.01,0.01),'closed route interior must not be included');
    Check(S.HitsBox(TLatLonBox.Make(-0.001,0.009,0.001,0.011)),'building crossing the corridor');
    Check(not S.Contains(-0.0007,-0.0007),'rounded endpoint, not inflated square');
    B:=TLatLonBox.Make(-0.01,-0.01,0.01,0.01); S.LimitTo(B);
    Check(S.Contains(0,0.005),'clipped route still includes crossed tile');
    Check(not S.Contains(0.02,0.019),'segments outside tile removed');
    Check(S.QueryBox(TLatLonBox.Make(40,30,41,31)).IsEmpty,'remote tile query is empty');
  finally S.Free end;
  S:=TPhotoRouteScope.Create(nil);
  try Check(S.Contains(50,50),'default remains unrestricted') finally S.Free end;
  J:=GetJSON('{"enabled":false}'); S:=TPhotoRouteScope.Create(J); J.Free;
  try Check(S.Contains(50,50),'explicit disable does not require points') finally S.Free end;
  J:=GetJSON('{"radius_m":-1,"points":[[0,0],[1,1]]}'); Failed:=False;
  try try S:=TPhotoRouteScope.Create(J); S.Free except on E:EConvertError do Failed:=True end finally J.Free end;
  Check(Failed,'invalid scope rejected');
  WriteLn('PASS: 12 route corridor checks');
 except on E:Exception do begin WriteLn('FAIL: ',E.Message); Halt(1) end end;
end.

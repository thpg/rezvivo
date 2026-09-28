unit GameOsmAccess;
{$mode objfpc}{$H+}
interface
implementation
uses VeloSiteAPI, Osm3dOsmAccess;

function AccessToken: string;
begin
  Result := '';
  if VeloSite <> nil then Result := VeloSite.GetOsmAccessToken;
end;

initialization
  OsmAccessTokenProvider := @AccessToken;
finalization
  OsmAccessTokenProvider := nil;
end.

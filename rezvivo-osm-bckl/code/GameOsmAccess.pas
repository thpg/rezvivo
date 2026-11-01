unit GameOsmAccess;
{$mode objfpc}{$H+}
interface
implementation
uses VeloSiteAPI, Osm3dOsmAccess, GameBuildInfo;

function AccessToken: string;
begin
  Result := '';
  if VeloSite <> nil then Result := VeloSite.GetOsmAccessToken;
end;

initialization
  OsmMapClientBuild := ClientBuild;
  OsmAccessTokenProvider := @AccessToken;
finalization
  OsmAccessTokenProvider := nil;
end.

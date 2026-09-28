unit Osm3dDetourTypes;
{$mode objfpc}{$H+}
interface
uses CastleVectors;
type
  TDetourPoints = array of TVector3;
  TDetourResult = (drClear, drFound, drTargetBlocked, drUnavailable);
implementation
end.

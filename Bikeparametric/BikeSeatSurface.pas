unit BikeSeatSurface;
{$mode objfpc}{$H+}
interface
uses CastleVectors;
const SeatSurfaceCount=9;
type
  { Longitudinal sections in bike metres: x, top y, half width, edge fall.
    Relative to saddle_contact. Fitted once when bicycle geometry changes. }
  TSeatSurface=array[0..SeatSurfaceCount-1] of TVector4;
implementation
end.

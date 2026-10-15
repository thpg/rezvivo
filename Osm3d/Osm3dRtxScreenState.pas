unit Osm3dRtxScreenState;
{$mode objfpc}{$H+}
interface
uses CastleVectors;
{ Render-thread state only. Each viewport clears this before its own capture;
  secondary/avatar previews must never borrow another camera's screen mask. }
var
  RtxScreenTexture: Cardinal = 0;
  RtxScreenView: TVector4;
  RtxScreenFocus: TVector4;
  RtxScreenCapturing: Boolean = False;
  RtxScreenExclusive: Boolean = False;
  { MCP comparison overrides only. Normal rendering follows shadow softness. }
  RtxScreenSunRadiusOverride: Single = -1;
  RtxScreenSamplesOverride: Integer = 0;
  { Conservative broad phase, built from the actual posed GPU vertices. }
  RtxScreenReceiverBounds: Boolean = True;
procedure ClearRtxScreenShadow;
implementation
procedure ClearRtxScreenShadow;
begin RtxScreenTexture:=0;RtxScreenView:=Vector4(0,0,1,1);RtxScreenFocus:=Vector4(0,0,0,1);end;
initialization
  ClearRtxScreenShadow;
end.

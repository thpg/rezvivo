unit GameGlobeCoverage;
{$mode objfpc}{$H+}
interface
uses Osm3dGeoMath, GameGlobeMath;
type
  TGlobeTextureInfo=record Tile:TTileXY;Quality:Integer;end;
  TGlobeTextureInfos=array of TGlobeTextureInfo;
  TGlobeCoveragePiece=record Tile:TTileXY;Source:Integer;end;
  TGlobeCoveragePieces=array of TGlobeCoveragePiece;
function GlobeContainsTile(const OuterTile,InnerTile:TTileXY):Boolean;
function GlobeCoverage(const Wanted:TGlobeTiles;const Available:TGlobeTextureInfos):TGlobeCoveragePieces;
implementation
uses Math;
function GlobeContainsTile(const OuterTile,InnerTile:TTileXY):Boolean;
var D:Integer;
begin
  D:=InnerTile.Zoom-OuterTile.Zoom;
  if D<0 then Exit(False);
  Result:=(OuterTile.X=InnerTile.X shr D)and(OuterTile.Y=InnerTile.Y shr D);
end;
function GlobeCoverage(const Wanted:TGlobeTiles;const Available:TGlobeTextureInfos):TGlobeCoveragePieces;
var Count,Budget,I:Integer;
  procedure Visit(const Region:TTileXY;TargetZoom,Depth:Integer);
  var Best,Q,K,X,Y,Expected:Integer;Split:Boolean;
  begin
    Best:=-1;Q:=-1;
    for K:=0 to High(Available)do if GlobeContainsTile(Available[K].Tile,Region)then
      if(Available[K].Quality>Q)or((Available[K].Quality=Q)and(Best>=0)and
        (Available[K].Tile.Zoom<Available[Best].Tile.Zoom))then begin Best:=K;Q:=Available[K].Quality;end;
    Expected:=TargetZoom;
    Split:=False;
    { Retain finer cached areas while their replacement loads. Splitting the
      target region keeps coverage disjoint; no overlapping sphere layers. }
    if(Q<Expected)and(Depth<4)and(Budget>=3)then
      for K:=0 to High(Available)do if(Available[K].Quality>Q)and
        (Available[K].Tile.Zoom<=TargetZoom+4)and GlobeContainsTile(Region,Available[K].Tile)then begin Split:=True;Break;end;
    if Split then begin
      Dec(Budget,3);
      for Y:=0 to 1 do for X:=0 to 1 do Visit(TTileXY.Make(Region.X*2+X,Region.Y*2+Y,Region.Zoom+1),TargetZoom,Depth+1);
    end else begin
      if Count=Length(Result)then SetLength(Result,Max(64,Count*2));
      Result[Count].Tile:=Region;Result[Count].Source:=Best;Inc(Count);
    end;
  end;
begin
  Result:=nil;Count:=0;Budget:=Max(0,256-Length(Wanted));
  for I:=0 to High(Wanted)do Visit(Wanted[I],Wanted[I].Zoom,0);
  SetLength(Result,Count);
end;
end.

unit Osm3dMapWorld;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses Osm3dGeoMath,Osm3dVectorMap,Osm3dCacheHTTPFetcher;
{ Immutable install-time gazetteer, including physical geography. No HTTP at
  continent scales. Full-resolution OSM remains the source for close views. }
function BuildWorldMapVectors(Http:THTTPFetcherWithCache;const Tile:TTileXY;
  MaxZoom:Integer):TMapVectorData;
implementation
uses Classes,SysUtils,SyncObjs,fpjson,jsonparser,CastleDownload;
type TPlace=record
  Point:TLatLon;Name:string;Zoom,Population,Priority:Integer;Kind:TMapFeatureKind;
end;
var Guard:TCriticalSection;Places:array of TPlace;Loaded:Boolean;

procedure LoadPlaces;
var Stream:TStream;Doc,A:TJSONData;O:TJSONObject;I:Integer;Kind:string;
begin
  if Loaded then Exit;
  Loaded:=True;Stream:=nil;Doc:=nil;
  try
   try
    Stream:=Download('castle-data:/map-overview/labels.json');
    Doc:=GetJSON(Stream);A:=Doc.FindPath('labels');
    if not(A is TJSONArray)or(A.Count>20000)then Exit;
    SetLength(Places,A.Count);
    for I:=0 to A.Count-1 do begin
      O:=TJSONObject(A.Items[I]);
      with Places[I]do begin
        Name:=O.Get('name','');Point:=TLatLon.Make(O.Get('lat',0.0),O.Get('lon',0.0));
        Zoom:=O.Get('zoom',7);Priority:=O.Get('priority',100);Population:=O.Get('population',0);
      end;
      Kind:=O.Get('kind','place');Places[I].Kind:=mfPlace;
      if Kind='region' then Places[I].Kind:=mfRegion
      else if Kind='water' then Places[I].Kind:=mfMarineLabel;
    end;
   except Places:=nil end;
  finally Doc.Free;Stream.Free end;
end;

function BuildWorldMapVectors(Http:THTTPFetcherWithCache;const Tile:TTileXY;
  MaxZoom:Integer):TMapVectorData;
var I:Integer;P:TPlace;Box:TLatLonBox;F:TMapVectorFeature;
begin
  Result:=nil;
  Guard.Enter;
  try LoadPlaces;finally Guard.Leave end;
  { Read-only after LoadPlaces; workers can select their tile concurrently. }
  if(Http<>nil)and Http.Aborted then Exit;
  Result:=TMapVectorData.Create(Tile);Result.MaxZoom:=MaxZoom;
  Box:=TTileMath.TileToLatLonBox(Tile);
  for I:=0 to High(Places)do begin
    P:=Places[I];
    if(P.Zoom>MaxZoom)or(P.Name='')or(P.Point.Lat<Box.MinLat)or
      (P.Point.Lat>=Box.MaxLat)or(P.Point.Lon<Box.MinLon)or(P.Point.Lon>=Box.MaxLon)then Continue;
    F:=TMapVectorFeature.Create;F.Key:='ne:'+IntToStr(I);F.Caption:=P.Name;
    F.Kind:=P.Kind;F.MinZoom:=P.Zoom;F.LabelZoom:=P.Zoom;
    F.Population:=P.Population;F.LabelPriority:=P.Priority;
    SetLength(F.Points,1);F.Points[0]:=P.Point;F.SetBounds;
    Result.Features.Add(F);Inc(Result.Bytes,F.InstanceSize+SizeOf(TLatLon)+Length(F.Caption)+Length(F.Key));
  end;
end;
initialization Guard:=TCriticalSection.Create;
finalization Places:=nil;Guard.Free;
end.

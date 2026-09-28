unit Osm3dRouteSnapCache;
{$mode objfpc}{$H+}
interface
uses Osm3dGeoMath, Osm3dGeoTileGrid, Osm3dGeoTileCache, Osm3dMapUtils;
{ Bump the namespace when the snapping algorithm/parameters change.
  Route coordinates (not a filename), projection and road bytes identify inputs. }
function RouteSnapCachePath(Cache: TGeoTileCache; const Tiles: TGeoTileIdArray;
  const Route: TRouteLatLonArray; const Origin: TLatLon; ScaleLat: Double): String;
function LoadRouteSnapCache(const Path: String; Count: Integer;
  out Route, Centers: TRouteLatLonArray; out Widths: TRouteWidthArray;
  out Ways: TRouteWayIdArray): Boolean;
function SaveRouteSnapCache(const Path: String; const Route, Centers: TRouteLatLonArray;
  const Widths: TRouteWidthArray; const Ways: TRouteWayIdArray): Boolean;
implementation
uses Classes, SysUtils, Math, md5;
const MAGIC: array[0..7] of Char = 'RZSNAP01';
  MAX_POINTS = 2000000;
type TPoint = packed record
  Lat, Lon, CenterLat, CenterLon: Double;
  Width: Single;
  Way: Int64;
end;
  TPoints = array of TPoint;
{$IFDEF MSWINDOWS}
function SnapMoveFile(OldName, NewName: PWideChar; Flags: LongWord): LongBool;
  stdcall; external 'kernel32' name 'MoveFileExW';
{$ENDIF}
function RouteSnapCachePath(Cache: TGeoTileCache; const Tiles: TGeoTileIdArray;
  const Route: TRouteLatLonArray; const Origin: TLatLon; ScaleLat: Double): String;
var C: TMD5Context; D: TMD5Digest; I, N: Integer; S: String; O: TLatLon;
begin
  Result := '';
  if (Cache=nil) or (Length(Tiles)=0) or (Length(Route)<2) then Exit;
  try
    MD5Init(C);
    N := Length(Route); MD5Update(C,N,SizeOf(N));
    MD5Update(C,Route[0],N*SizeOf(TLatLon));
    O := Origin; MD5Update(C,O,SizeOf(O)); MD5Update(C,ScaleLat,SizeOf(ScaleLat));
    for I := 0 to High(Tiles) do
    begin
      S := Tiles[I].ToString;
      N := Length(S); MD5Update(C,N,SizeOf(N)); MD5Update(C,S[1],N);
      S := Cache.RoadFingerprint(Tiles[I]);
      { No complete road dependency => no hit, including a cleared tile cache. }
      if S = '' then Exit;
      N := Length(S); MD5Update(C,N,SizeOf(N)); MD5Update(C,S[1],N);
    end;
    MD5Final(C,D);
    Result := IncludeTrailingPathDelimiter(Cache.RootDir)+'route-snap-v9'+
      PathDelim+MD5Print(D)+'.snap';
  except Result := '' end; { cache I/O must never block the normal snap path }
end;
function ValidPoint(const P: TPoint): Boolean;
begin
  Result := not (IsNan(P.Lat) or IsNan(P.Lon) or IsNan(P.CenterLat) or
    IsNan(P.CenterLon) or IsNan(P.Width)) and
    (Abs(P.Lat)<=90) and (Abs(P.Lon)<=180) and
    (Abs(P.CenterLat)<=90) and (Abs(P.CenterLon)<=180) and
    (P.Width>=0) and (P.Width<=1000);
end;
function LoadRouteSnapCache(const Path: String; Count: Integer;
  out Route, Centers: TRouteLatLonArray; out Widths: TRouteWidthArray;
  out Ways: TRouteWayIdArray): Boolean;
var F: TFileStream; Header: array[0..7] of Char; N: LongWord;
  Expected, Actual: TMD5Digest; P: TPoints; I: Integer;
begin
  Result := False; Route := nil; Centers := nil; Widths := nil; Ways := nil;
  if (Path='') or (Count<2) or (Count>MAX_POINTS) then Exit;
  try
    F := TFileStream.Create(Path,fmOpenRead or fmShareDenyWrite);
    try
      if F.Size<>8+4+16+Int64(Count)*SizeOf(TPoint) then Exit;
      F.ReadBuffer(Header,8); if Header<>MAGIC then Exit;
      F.ReadBuffer(N,4); if N<>LongWord(Count) then Exit;
      F.ReadBuffer(Expected,16);
      SetLength(P,Count); F.ReadBuffer(P[0],Count*SizeOf(TPoint));
    finally F.Free end;
    Actual := MD5Buffer(P[0],Count*SizeOf(TPoint));
    if not CompareMem(@Expected,@Actual,16) then Exit;
    for I := 0 to Count-1 do if not ValidPoint(P[I]) then Exit;
    SetLength(Route,Count); SetLength(Centers,Count);
    SetLength(Widths,Count); SetLength(Ways,Count);
    for I := 0 to Count-1 do
    begin
      Route[I] := TLatLon.Make(P[I].Lat,P[I].Lon);
      Centers[I] := TLatLon.Make(P[I].CenterLat,P[I].CenterLon);
      Widths[I] := P[I].Width; Ways[I] := P[I].Way;
    end;
    Result := True;
  except
    Route := nil; Centers := nil; Widths := nil; Ways := nil;
  end;
end;
function SaveRouteSnapCache(const Path: String; const Route, Centers: TRouteLatLonArray;
  const Widths: TRouteWidthArray; const Ways: TRouteWayIdArray): Boolean;
var F: TFileStream; P: TPoints; I: Integer; N: LongWord;
  D: TMD5Digest; Tmp: String; G: TGUID;
begin
  Result := False; Tmp := '';
  N := Length(Route);
  if (Path='') or (N<2) or (N>MAX_POINTS) or (Length(Centers)<>N) or
    (Length(Widths)<>N) or (Length(Ways)<>N) then Exit;
  try
    SetLength(P,N);
    for I := 0 to N-1 do
    begin
      P[I].Lat := Route[I].Lat; P[I].Lon := Route[I].Lon;
      P[I].CenterLat := Centers[I].Lat; P[I].CenterLon := Centers[I].Lon;
      P[I].Width := Widths[I]; P[I].Way := Ways[I];
      if not ValidPoint(P[I]) then Exit;
    end;
    D := MD5Buffer(P[0],N*SizeOf(TPoint));
    if not ForceDirectories(ExtractFileDir(Path)) then Exit;
    CreateGUID(G); Tmp := Path+'.'+GUIDToString(G)+'.tmp';
    F := TFileStream.Create(Tmp,fmCreate);
    try
      F.WriteBuffer(MAGIC,8); F.WriteBuffer(N,4); F.WriteBuffer(D,16);
      F.WriteBuffer(P[0],N*SizeOf(TPoint));
    finally F.Free end;
    {$IFDEF MSWINDOWS}
    Result := SnapMoveFile(PWideChar(UTF8Decode(Tmp)),PWideChar(UTF8Decode(Path)),1);
    {$ELSE}
    Result := RenameFile(Tmp,Path);
    {$ENDIF}
  except Result := False end;
  if (Tmp<>'') and FileExists(Tmp) then DeleteFile(Tmp);
end;
end.

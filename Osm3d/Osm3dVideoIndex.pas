unit Osm3dVideoIndex;
{$mode objfpc}{$H+}{$codepage UTF8}

interface
uses Classes, SysUtils, fpjson, Osm3dGeoMath;
function VideoCsvRow(const S: RawByteString; var Offset: Integer; Fields: TStrings): Boolean;
function BuildVideoCsvIndex(const S, Provider: RawByteString): TJSONObject;
function VideoCell(Lat, Lon: Double): string;
function VideoIndexRows(Index: TJSONObject; const Box: TLatLonBox): TJSONArray;
function VideoEcefTrack(const Positions, Times: TBytes): TJSONArray;
function NormalizeVideoManifestRecord(const Provider: string; Item: TJSONObject): TJSONObject;
function VideoRecordMatches(Item: TJSONObject; const Box: TLatLonBox;
  RegionalRadiusM: Double; out MatchTime: Double): Boolean;
function VideoFrameLocation(Item: TJSONObject; TimeS: Double): TJSONObject;

implementation
uses Math, Osm3dPhotoApi, Osm3dPhotoSources, Osm3dVideoSources;

function VideoCsvRow(const S: RawByteString; var Offset: Integer; Fields: TStrings): Boolean;
var Quoted: Boolean; Start: Integer; C: Char; Field: RawByteString;
begin
  Fields.Clear; Result:=Offset<=Length(S); if not Result then Exit;
  Quoted:=False; Field:=''; Start:=Offset;
  while Offset<=Length(S) do begin
    C:=S[Offset]; Inc(Offset);
    if C='"' then begin
      if Quoted and (Offset<=Length(S)) and (S[Offset]='"') then begin Field:=Field+'"'; Inc(Offset) end
      else Quoted:=not Quoted;
    end else if not Quoted and (C=',') then begin Fields.Add(Field); Field:='' end
    else if not Quoted and (C in [#10,#13]) then begin
      if (C=#13) and (Offset<=Length(S)) and (S[Offset]=#10) then Inc(Offset);
      Fields.Add(Field); Exit;
    end else Field:=Field+C;
    if Offset-Start>1024*1024 then raise Exception.Create('CSV row is too large');
  end;
  if Quoted then raise Exception.Create('Unclosed CSV quote');
  Fields.Add(Field);
end;

function VideoCell(Lat, Lon: Double): string;
begin Result:=IntToStr(Floor(Lon))+'/'+IntToStr(Floor(Lat)) end;

function BuildVideoCsvIndex(const S, Provider: RawByteString): TJSONObject;
var Header, Row: TStringList; Cells: TJSONObject; A: TJSONArray; F: TFormatSettings;
  Offset,Start,LatI,LonI,XYI,N: Integer; Lat,Lon: Double; XY: TJSONData; K,T: string;
begin
  Result:=TJSONObject.Create; Cells:=TJSONObject.Create; Result.Add('cells',Cells);
  Header:=TStringList.Create; Row:=TStringList.Create;
  try
    try
      Offset:=1; if not VideoCsvRow(S,Offset,Header) then raise Exception.Create('Empty video CSV');
      LatI:=Header.IndexOf('lat'); LonI:=Header.IndexOf('lon'); XYI:=Header.IndexOf('lat/lon');
      if ((Provider='crowd') and ((LatI<0) or (LonI<0) or (Header.IndexOf('videos')<0))) or
        ((Provider='walking') and ((XYI<0) or (Header.IndexOf('video_url')<0))) then
        raise Exception.Create('Unexpected video CSV schema');
      F:=DefaultFormatSettings; F.DecimalSeparator:='.'; F.ThousandSeparator:=#0; N:=0;
      while Offset<=Length(S) do begin
        Start:=Offset; if not VideoCsvRow(S,Offset,Row) then Break;
        if Row.Count<>Header.Count then Continue;
        if Provider='crowd' then begin
          if not TryStrToFloat(Row[LatI],Lat,F) or not TryStrToFloat(Row[LonI],Lon,F) then Continue;
        end else begin
          XY:=nil;
          try
            T:=StringReplace(Row[XYI],'''','"',[rfReplaceAll]); XY:=ParsePhotoJson(T);
            { The misleading lat/lon column is stored in GeoJSON order: lon,lat. }
            if (XY.JSONType<>jtArray) or (XY.Count<>2) or
              not TryStrToFloat(XY.Items[0].AsString,Lon,F) or not TryStrToFloat(XY.Items[1].AsString,Lat,F) then Continue;
          finally XY.Free end;
        end;
        if IsNan(Lat) or IsNan(Lon) or IsInfinite(Lat) or IsInfinite(Lon) or (Abs(Lat)>90) or (Abs(Lon)>180) then Continue;
        K:=VideoCell(Lat,Lon); A:=TJSONArray(Cells.Find(K));
        if A=nil then begin A:=TJSONArray.Create; Cells.Add(K,A) end;
        A.Add(TJSONArray.Create([Start,Offset-Start,Lat,Lon])); Inc(N);
      end;
      Result.Add('row_count',N); Result.Add('source_bytes',Length(S));
      A:=TJSONArray.Create; for N:=0 to Header.Count-1 do A.Add(Header[N]); Result.Add('header',A);
    except Result.Free; raise end;
  finally Header.Free; Row.Free end;
end;

function VideoIndexRows(Index: TJSONObject; const Box: TLatLonBox): TJSONArray;
var X,Y,I,XX,YMin,YMax: Integer; Cells: TJSONData; A: TJSONArray;
begin
  Result:=TJSONArray.Create; Cells:=Index.Find('cells'); if Cells=nil then Exit;
  YMin:=Floor(Box.MinLat); if YMin< -90 then YMin:=-90;
  YMax:=Floor(Box.MaxLat); if YMax>89 then YMax:=89;
  for X:=Floor(Box.MinLon) to Floor(Box.MaxLon) do begin
    XX:=((X+180) mod 360+360) mod 360-180;
    for Y:=YMin to YMax do begin
      A:=TJSONArray(TJSONObject(Cells).Find(IntToStr(XX)+'/'+IntToStr(Y)));
      if A<>nil then for I:=0 to A.Count-1 do Result.Add(A.Items[I].Clone);
    end;
  end;
end;

function NpyDoubleOffset(const B: TBytes; Columns: Integer; out Count: Integer): Integer;
var N,H,P,Q: Integer; Header,Shape: string; Dims: TStringList;
begin
  if (Length(B)<12) or (B[0]<>$93) or (B[1]<>Ord('N')) or (B[2]<>Ord('U')) or
    (B[3]<>Ord('M')) or (B[4]<>Ord('P')) or (B[5]<>Ord('Y')) then raise Exception.Create('Invalid NPY signature');
  case B[6] of
    1: begin H:=10; N:=B[8]+256*B[9] end;
    2,3: begin H:=12; N:=B[8]+256*B[9]+65536*B[10]+16777216*B[11] end;
    else raise Exception.Create('Unsupported NPY version');
  end;
  if (N<1) or (N>65536) or (H+N>Length(B)) then raise Exception.Create('Invalid NPY header');
  SetString(Header,PAnsiChar(@B[H]),N); Result:=H+N;
  if (Pos('''descr'': ''<f8''',Header)=0) or (Pos('''fortran_order'': False',Header)=0) then
    raise Exception.Create('NPY must be little endian float64, C order');
  if (Length(B)-Result) mod (8*Columns)<>0 then raise Exception.Create('Invalid NPY array length');
  Count:=(Length(B)-Result) div (8*Columns);
  if (Count<1) or (Count>100000) then raise Exception.Create('NPY array exceeds camera track limits');
  P:=Pos('''shape''',Header); if P=0 then raise Exception.Create('NPY shape missing');
  Shape:=Copy(Header,P,MaxInt); P:=Pos('(',Shape); Q:=Pos(')',Shape);
  if (P=0) or (Q<=P) then raise Exception.Create('Invalid NPY shape');
  Shape:=Copy(Shape,P+1,Q-P-1); Dims:=TStringList.Create;
  try
    Dims.StrictDelimiter:=True; Dims.Delimiter:=','; Dims.DelimitedText:=Shape;
    while (Dims.Count>0) and (Trim(Dims[Dims.Count-1])='') do Dims.Delete(Dims.Count-1);
    if (Dims.Count<1) or (StrToIntDef(Trim(Dims[0]),-1)<>Count) then raise Exception.Create('NPY shape/length mismatch');
    if Columns=1 then begin if Dims.Count<>1 then raise Exception.Create('NPY timestamps must be one-dimensional') end
    else if (Dims.Count<>2) or (StrToIntDef(Trim(Dims[1]),-1)<>Columns) then raise Exception.Create('NPY camera positions must be Nx3');
  finally Dims.Free end;
end;

function VideoEcefTrack(const Positions, Times: TBytes): TJSONArray;
var P,T,N,M,I,J: Integer; X,Y,Z,Lat,Lon,R,V,SampleTime,First: Double;
begin
  P:=NpyDoubleOffset(Positions,3,N); T:=NpyDoubleOffset(Times,1,M);
  if N<>M then raise Exception.Create('Camera positions and timestamps differ in length');
  Result:=TJSONArray.Create; Move(Times[T],First,8);
  try
    for I:=0 to N-1 do begin
      Move(Positions[P+I*24],X,8); Move(Positions[P+I*24+8],Y,8); Move(Positions[P+I*24+16],Z,8);
      Move(Times[T+I*8],SampleTime,8); SampleTime:=SampleTime-First;
      if IsNan(X) or IsNan(Y) or IsNan(Z) or IsNan(SampleTime) or IsInfinite(SampleTime) or
        (Abs(X)>1e7) or (Abs(Y)>1e7) or (Abs(Z)>1e7) then raise Exception.Create('Invalid camera pose');
      R:=Sqrt(X*X+Y*Y); if R<1 then raise Exception.Create('Invalid ECEF position');
      Lat:=ArcTan2(Z,R*(1-0.00669437999014));
      for J:=1 to 8 do begin V:=6378137/Sqrt(1-0.00669437999014*Sqr(Sin(Lat))); Lat:=ArcTan2(Z+0.00669437999014*V*Sin(Lat),R) end;
      Lon:=ArcTan2(Y,X)*180/Pi; Lat:=Lat*180/Pi;
      Result.Add(TJSONObject.Create(['time_s',SampleTime,'latitude',Lat,'longitude',Lon,'frame_index',I]));
    end;
  except Result.Free; raise end;
end;

function NormalizeVideoManifestRecord(const Provider: string; Item: TJSONObject): TJSONObject;
var A: TJSONArray; I,J: Integer; Lat,Lon,T,Prev,Frame: Double; HasLocation: Boolean; K,Role,Id,Hash: string; P: TJSONData;
const Copied: array[0..15] of string = ('title','source_url','catalog_url','author','captured_at','license',
  'license_url','permission_reference','required_attribution','video_url','preview_url','container','duration_s',
  'frame_rate','position_uncertainty_m','locality');
begin
  Result:=nil;
  Id:=Item.Get('video_id',''); Hash:='';
  if Provider='yli_geo' then begin
    Hash:=Item.Get('media_hash','');
    if (Length(Hash)<20) or (Length(Hash)>32) then Hash:='';
    for I:=1 to Length(Hash) do if not (Hash[I] in ['0'..'9','a'..'f']) then begin Hash:=''; Break end;
    if Id='' then Id:=Hash;
  end;
  if Id='' then Exit;
  Role:=Item.Get('coordinate_role','video_geotag');
  if (Role<>'camera_track') and (Role<>'video_geotag') and (Role<>'locality') then Exit;
  HasLocation:=Num(Item,'latitude',Lat) and Num(Item,'longitude',Lon) and (Abs(Lat)<=90) and (Abs(Lon)<=180);
  if Role='camera_track' then begin
    HasLocation:=False;
    for J:=0 to 1 do begin
      if J=0 then K:='track' else K:='frames'; A:=ArrayAt(Item,K);
      if A=nil then Continue;
      if A.Count>100000 then Exit;
      Prev:=-1;
      for I:=0 to A.Count-1 do begin
        P:=A.Items[I];
        if (P.JSONType<>jtObject) or not Num(P,'time_s',T) or (T<0) or (T<=Prev) or
          not Num(P,'latitude',Lat) or not Num(P,'longitude',Lon) or (Abs(Lat)>90) or (Abs(Lon)>180) then Exit;
        if (J=1) and not VideoDirectURL(PhotoJsonString(P,'url')) then Exit;
        if P.FindPath('frame_index')<>nil then
          if not Num(P,'frame_index',Frame) or (Frame<0) or (Frame>High(Integer)) or (Frac(Frame)<>0) then Exit;
        Prev:=T; HasLocation:=True;
      end;
    end;
  end;
  if not HasLocation then Exit;
  Result:=TJSONObject.Create(['id',Provider+':'+Id,'provider',Provider,
    'video_id',Id,'media_type','video','coordinate_role',Role]);
  for I:=0 to High(Copied) do begin P:=Item.Find(Copied[I]); if P<>nil then Result.Add(Copied[I],P.Clone) end;
  if Num(Item,'latitude',Lat) and Num(Item,'longitude',Lon) and (Abs(Lat)<=90) and (Abs(Lon)<=180) then
    begin Result.Add('latitude',Lat); Result.Add('longitude',Lon) end;
  for J:=0 to 2 do begin
    case J of 0: K:='track'; 1: K:='frames'; else K:='segments' end;
    A:=ArrayAt(Item,K); if A<>nil then Result.Add(K,A.Clone);
  end;
  if (Hash<>'') and (Result.Get('video_url','')='') then Result.Strings['video_url']:=
    'https://multimedia-commons.s3-us-west-2.amazonaws.com/data/videos/mp4/'+Copy(Hash,1,3)+'/'+Copy(Hash,4,3)+'/'+Hash+'.mp4';
  if Provider='zod' then begin
    if Result.Get('license','')='' then Result.Strings['license']:='CC-BY-SA-4.0';
    if Result.Get('license_url','')='' then Result.Strings['license_url']:='https://creativecommons.org/licenses/by-sa/4.0/';
    if Result.Get('author','')='' then Result.Strings['author']:='Zenseact AB';
    Result.Strings['required_attribution']:='Zenseact Open Dataset, copyright 2022 Zenseact AB. '+
      'For this dataset, Zenseact AB has taken all reasonable measures to remove all personally identifiable information, '+
      'including faces and license plates. To the extent that you like to request removal of specific images from the dataset, '+
      'please contact privacy@zenseact.com.';
  end;
  Result.Add('download_allowed',PhotoLicenseReusable(Result.Get('license',''),Result.Get('license_url','')) or
    (Result.Get('permission_reference','')<>''));
  if (Result.Find('video_url')<>nil) and not VideoDirectURL(Result.Get('video_url','')) then Result.Delete('video_url');
  if (Provider='crowd') or (Provider='walking') or (Provider='youtube') then Result.Booleans['download_allowed']:=False;
end;

function VideoRecordMatches(Item: TJSONObject; const Box: TLatLonBox;
  RegionalRadiusM: Double; out MatchTime: Double): Boolean;
var A: TJSONArray; I,J: Integer; Lat,Lon,D: Double; P: TLatLon; K: string;
begin
  Result:=False; MatchTime:=0;
  if Item.Get('coordinate_role','')='camera_track' then begin
    for J:=0 to 1 do begin
      if J=0 then K:='track' else K:='frames'; A:=ArrayAt(Item,K); if A=nil then Continue;
      for I:=0 to A.Count-1 do
        if Num(A.Items[I],'latitude',Lat) and Num(A.Items[I],'longitude',Lon) and VideoPointInside(TLatLon.Make(Lat,Lon),Box) then begin
          Num(A.Items[I],'time_s',MatchTime); Exit(True);
        end;
    end;
  end else if Num(Item,'latitude',Lat) and Num(Item,'longitude',Lon) then begin
    P:=TLatLon.Make(Lat,Lon); Result:=VideoPointInside(P,Box);
    if not Result and (Item.Get('coordinate_role','')='locality') then begin
      { Radius is a search policy, NOT a claim about coordinate uncertainty. }
      D:=Box.Center.DistanceTo(P); Result:=D<=RegionalRadiusM;
    end;
  end;
end;

function VideoFrameLocation(Item: TJSONObject; TimeS: Double): TJSONObject;
var A: TJSONArray; I: Integer; T,U,Lat,Lon,Lat2,Lon2,Q: Double;
begin
  Result:=TJSONObject.Create(['coordinate_role','unknown','camera_position_known',False]);
  A:=ArrayAt(Item,'track'); if A=nil then A:=ArrayAt(Item,'frames');
  if A<>nil then begin
    for I:=0 to A.Count-1 do begin
      if not Num(A.Items[I],'time_s',T) then Continue;
      if Abs(T-TimeS)<0.001 then begin
        Result.Strings['coordinate_role']:='camera'; Result.Booleans['camera_position_known']:=True;
        Result.Add('latitude',A.Items[I].FindPath('latitude').Clone);
        Result.Add('longitude',A.Items[I].FindPath('longitude').Clone);
        Result.Add('position_method','camera_sample'); Break;
      end;
      if (T<TimeS) and (I<A.Count-1) and Num(A.Items[I+1],'time_s',U) and (U>=TimeS) and (U-T<=2) then begin
        Num(A.Items[I],'latitude',Lat); Num(A.Items[I],'longitude',Lon);
        Num(A.Items[I+1],'latitude',Lat2); Num(A.Items[I+1],'longitude',Lon2);
        if TLatLon.Make(Lat,Lon).DistanceTo(TLatLon.Make(Lat2,Lon2))>80*(U-T) then Break;
        Q:=(TimeS-T)/(U-T); if Lon2-Lon>180 then Lon2:=Lon2-360 else if Lon2-Lon< -180 then Lon2:=Lon2+360;
        Lon:=Lon+(Lon2-Lon)*Q; if Lon>180 then Lon:=Lon-360 else if Lon< -180 then Lon:=Lon+360;
        Result.Strings['coordinate_role']:='camera'; Result.Booleans['camera_position_known']:=True;
        Result.Add('latitude',Lat+(Lat2-Lat)*Q); Result.Add('longitude',Lon);
        Result.Add('position_method','interpolated_camera_samples'); Break;
      end;
    end;
  end;
  if not Result.Get('camera_position_known',False) and (Item.Find('latitude')<>nil) then begin
    Result.Strings['coordinate_role']:=Item.Get('coordinate_role','video_geotag');
    Result.Add('reference_latitude',Item.Find('latitude').Clone); Result.Add('reference_longitude',Item.Find('longitude').Clone);
  end;
  if Item.Find('position_uncertainty_m')<>nil then Result.Add('position_uncertainty_m',Item.Find('position_uncertainty_m').Clone)
  else Result.Add('position_uncertainty_m',TJSONNull.Create);
end;

end.

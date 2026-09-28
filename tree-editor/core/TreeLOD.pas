unit TreeLOD;
{$mode objfpc}{$H+}
interface
uses SysUtils, TreeMath, TreeModel;
const
  TREE_LOD_VERSION = 1;
  LOD_SIZE = 256;
  LOD_VIEWS = 4;
  LOD_AGES = 3;
  LOD_DEFAULT_SAMPLES = 8;
type
  TTreeProfiles = array[TTreeSpecies] of TTreeParams;
  TLODPixels = array of Single; { linear RGB premultiplied by coverage, then alpha }
  TLODFrames = array[0..LOD_AGES-1] of TTreeVec3; { width, bottom, top / resolved height }
function LODProfileKey(const Profile: TTreeParams): string;
function LODAge(Species: TTreeSpecies; Group: Integer): Integer;
function LODInstance(Species: TTreeSpecies; Group, Sample: Integer): TTreeInstance;
procedure AddLODSample(var Sum: TLODPixels; const Pixels: TLODPixels);
procedure FinishLODMean(var Sum: TLODPixels; Samples: Integer);
procedure SaveLODPng(const Path: string; const Pixels: TLODPixels; W,H: Integer);
function LoadLODPng(const Path: string; W,H: Integer): TLODPixels;
function ReadLODMetadata(const Path: string; const Profile: TTreeParams; out Frames: TLODFrames): Boolean;
function ReadLODSeasonMetadata(const Path: string): Boolean;
implementation
uses Math, Classes, TreeRecipe, TreeFoliageLOD, FPImage, FPWritePNG, FPReadPNG, fpjson, jsonparser;
function LODProfileKey(const Profile: TTreeParams): string;
var S: string; I: Integer; H: LongWord;
begin
  S:=TreeToJSON(Profile); H:=Hash32(TREE_LOD_VERSION);
  if IsConifer(Profile.Species) then H:=Hash32(H xor (NEEDLE_COVERAGE_VERSION shl 24));
  if Profile.Species=tsBirch then H:=Hash32(H xor (TREE_BIRCH_GEOMETRY_VERSION shl 16));
  if HasTreeFruit(Profile.Species) then H:=Hash32(H xor (TREE_FRUIT_GEOMETRY_VERSION shl 12));
  if Profile.Species=tsRowan then H:=Hash32(H xor (TREE_ROWAN_GEOMETRY_VERSION shl 8));
  if Profile.Species>=tsBamboo then H:=Hash32(H xor (TREE_REGIONAL_GEOMETRY_VERSION shl 16));
  for I:=1 to Length(S) do H:=Hash32(H xor Ord(S[I]));
  Result:=IntToHex(H,8);
end;
function LODAge(Species: TTreeSpecies; Group: Integer): Integer;
const Ratios: array[0..2] of Single = (0.18,1,3);
begin
  if (Group<0) or (Group>=LOD_AGES) then raise ERangeError.Create('Invalid LOD age group');
  Result:=Max(1,Round(MatureTreeAge(Species)*Ratios[Group]));
end;
function LODInstance(Species: TTreeSpecies; Group, Sample: Integer): TTreeInstance;
begin
  Result:=Default(TTreeInstance);
  Result.TypeCode:=PackTreeType(Species,LODAge(Species,Group),0);
  Result.Position.X:=193.125+Sample*173.375;
  Result.Position.Z:=-417.75+Sample*317.625;
end;
procedure AddLODSample(var Sum: TLODPixels; const Pixels: TLODPixels);
var I: Integer;
begin
  if Length(Sum)=0 then SetLength(Sum,Length(Pixels));
  if Length(Sum)<>Length(Pixels) then raise EArgumentException.Create('LOD sample size mismatch');
  for I:=0 to High(Sum) do Sum[I]:=Sum[I]+Pixels[I];
end;
procedure FinishLODMean(var Sum: TLODPixels; Samples: Integer);
var I: Integer;
begin
  if Samples<1 then raise EArgumentException.Create('LOD mean needs samples');
  for I:=0 to High(Sum) do Sum[I]:=Sum[I]/Samples;
end;
procedure SaveLODPng(const Path: string; const Pixels: TLODPixels; W,H: Integer);
var Img: TFPMemoryImage; Writer: TFPWriterPNG; X,Y,I: Integer; C: TFPColor; A: Single; RGB: TTreeVec3;
begin
  if Length(Pixels)<>W*H*4 then raise EArgumentException.Create('Invalid LOD image size');
  Img:=TFPMemoryImage.Create(W,H); Writer:=TFPWriterPNG.Create;
  try
    Writer.UseAlpha:=True; Writer.WordSized:=False;
    for Y:=0 to H-1 do for X:=0 to W-1 do begin
      I:=((H-1-Y)*W+X)*4; A:=Pixels[I+3]; RGB:=Vec(0,0,0);
      if A>0.000001 then RGB:=ColorToDisplay(Vec(Pixels[I]/A,Pixels[I+1]/A,Pixels[I+2]/A));
      C.Red:=Round(RGB.X*65535); C.Green:=Round(RGB.Y*65535); C.Blue:=Round(RGB.Z*65535);
      C.Alpha:=Round(Clamp(A,0,1)*65535); Img.Colors[X,Y]:=C;
    end;
    Img.SaveToFile(Path,Writer);
  finally Writer.Free; Img.Free; end;
end;
function LoadLODPng(const Path: string; W,H: Integer): TLODPixels;
var Img: TFPMemoryImage; Reader: TFPReaderPNG; X,Y,I: Integer; C: TFPColor; A: Single; RGB: TTreeVec3;
begin
  Result:=nil; Img:=TFPMemoryImage.Create(0,0); Reader:=TFPReaderPNG.Create;
  try
    Img.LoadFromFile(Path,Reader);
    if (Img.Width<>W) or (Img.Height<>H) then raise EArgumentException.Create('Invalid LOD atlas dimensions');
    SetLength(Result,W*H*4);
    for Y:=0 to H-1 do for X:=0 to W-1 do begin
      C:=Img.Colors[X,H-1-Y]; I:=(Y*W+X)*4; A:=C.Alpha/65535;
      RGB:=ColorToLinear(Vec(C.Red/65535,C.Green/65535,C.Blue/65535));
      Result[I]:=RGB.X*A; Result[I+1]:=RGB.Y*A; Result[I+2]:=RGB.Z*A; Result[I+3]:=A;
    end;
  finally Reader.Free; Img.Free; end;
end;
function ReadLODMetadata(const Path: string; const Profile: TTreeParams; out Frames: TLODFrames): Boolean;
var Lines: TStringList; Data: TJSONData; J: TJSONObject; A,F: TJSONArray; I: Integer;
begin
  Result:=False; if not FileExists(Path) then Exit;
  Lines:=TStringList.Create; Data:=nil;
  try
    Lines.LoadFromFile(Path); Data:=GetJSON(Lines.Text);
    if not (Data is TJSONObject) then Exit;
    J:=TJSONObject(Data);
    if (J.Get('format','')<>'rezvivo.tree-lod') or (J.Get('version',0)<>TREE_LOD_VERSION) or
       (J.Get('profile_key','')<>LODProfileKey(Profile)) or (J.Get('size',0)<>LOD_SIZE) or
       (J.Get('views',0)<>LOD_VIEWS) or (J.Get('ages',0)<>LOD_AGES) then Exit;
    A:=J.Arrays['frames']; if A.Count<>LOD_AGES then Exit;
    for I:=0 to LOD_AGES-1 do begin
      F:=TJSONArray(A.Items[I]); if F.Count<>3 then Exit;
      Frames[I]:=Vec(F.Floats[0],F.Floats[1],F.Floats[2]);
      if IsNan(Frames[I].X) or IsInfinite(Frames[I].X) or (Frames[I].X<=0) or (Frames[I].X>100) or
        IsNan(Frames[I].Y) or IsInfinite(Frames[I].Y) or (Abs(Frames[I].Y)>100) or
        IsNan(Frames[I].Z) or IsInfinite(Frames[I].Z) or (Frames[I].Z<=Frames[I].Y) or (Frames[I].Z>100) then Exit;
    end;
    Result:=True;
  finally Data.Free; Lines.Free; end;
end;
function ReadLODSeasonMetadata(const Path: string): Boolean;
var Lines: TStringList; Data: TJSONData;
begin
  Result:=False; if not FileExists(Path) then Exit;
  Lines:=TStringList.Create; Data:=nil;
  try
    Lines.LoadFromFile(Path); Data:=GetJSON(Lines.Text);
    if Data is TJSONObject then Result:=TJSONObject(Data).Get('seasonal_version',0)=1;
  finally Data.Free; Lines.Free; end;
end;
end.

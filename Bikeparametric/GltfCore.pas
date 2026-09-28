{
  GltfCore — shared glTF / GLB low-level parsing primitives.

  Extracted from TripoRig and GlbRigInspect, which each carried a
  byte-for-byte copy of these helpers. This unit is the single source of
  truth for:
    • the little-endian u32 reader over a TBytes buffer,
    • GLB container extraction (locate the JSON + BIN chunks),
    • nil-safe glTF JSON navigation,
    • glTF accessor component metadata (size / count / name).

  Intentionally Castle-free: depends only on SysUtils, Classes and fpjson,
  so it stays unit-testable and reusable by any loader (TripoRig runtime
  loader, GlbRigInspect diagnostics, future importers). Vector/typed
  decoding stays in the consuming units — this layer only deals in raw
  bytes and JSON primitives.
}
unit GltfCore;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpjson;

const
  GLB_MAGIC      = LongWord($46546C67);  { 'glTF' }
  GLB_CHUNK_JSON = LongWord($4E4F534A);  { 'JSON' }
  GLB_CHUNK_BIN  = LongWord($004E4942);  { 'BIN\0' }

{ Little-endian unsigned 32-bit read from a byte buffer. }
function U32(const B: TBytes; Ofs: Integer): LongWord; inline;

{ Read an entire file into a byte buffer (empty result on missing/empty). }
function LoadFileBytes(const FN: string): TBytes;

{ Pull the glTF JSON text out of a GLB container and locate the BIN chunk.
  A buffer without the GLB magic is treated as a raw .gltf text file, in
  which case JsonStr is the whole buffer and BinOfs/BinLen are 0.
  Returns False only when no JSON could be recovered. }
function ExtractGltfJson(const B: TBytes; out JsonStr: string;
  out BinOfs, BinLen: Integer): Boolean;

{ ── nil-safe JSON navigation ─────────────────────────────────────────── }
function ObjOf(O: TJSONObject; const Name: string): TJSONObject;
function ArrOf(O: TJSONObject; const Name: string): TJSONArray;
function ObjAt(A: TJSONArray; I: Integer): TJSONObject;
function CountOf(A: TJSONArray): Integer;
function HasKey(O: TJSONObject; const Name: string): Boolean;
function IntOf(O: TJSONObject; const Name: string; Def: Integer): Integer;
function StrOf(O: TJSONObject; const Name, Def: string): string;
function ArrInt(A: TJSONArray; I, Def: Integer): Integer;
function ArrFloat(A: TJSONArray; I: Integer; Def: Double): Double;

{ ── glTF accessor component metadata ─────────────────────────────────── }
function CompSize(Ct: Integer): Integer;       { bytes per component }
function TypeCount(const T: string): Integer;  { components per element }
function CompTypeName(C: Integer): string;     { human-readable, for diagnostics }

implementation

function U32(const B: TBytes; Ofs: Integer): LongWord; inline;
begin
  Result :=  LongWord(B[Ofs])
          or (LongWord(B[Ofs + 1]) shl 8)
          or (LongWord(B[Ofs + 2]) shl 16)
          or (LongWord(B[Ofs + 3]) shl 24);
end;

function LoadFileBytes(const FN: string): TBytes;
var FS: TFileStream;
begin
  Result := nil;
  FS := TFileStream.Create(FN, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, FS.Size);
    if FS.Size > 0 then FS.ReadBuffer(Result[0], FS.Size);
  finally
    FS.Free;
  end;
end;

function ExtractGltfJson(const B: TBytes; out JsonStr: string;
  out BinOfs, BinLen: Integer): Boolean;
var
  P: Integer;
  ChunkLen, ChunkType, Total: LongWord;
  SeenJson, SeenBin: Boolean;
begin
  Result := False; JsonStr := ''; BinOfs := 0; BinLen := 0;
  if Length(B) < 12 then Exit;

  if U32(B, 0) <> GLB_MAGIC then  { not 'glTF' → assume .gltf text }
  begin
    SetString(JsonStr, PAnsiChar(@B[0]), Length(B));
    Result := JsonStr <> '';
    Exit;
  end;

  Total := U32(B, 8);
  if (U32(B, 4) <> 2) or (Total <> QWord(Length(B))) or
     (Total < 20) or (Total > High(Integer)) then Exit;
  SeenJson := False;
  SeenBin := False;
  P := 12;
  while P < Integer(Total) do
  begin
    if Integer(Total) - P < 8 then Exit;
    ChunkLen  := U32(B, P);
    ChunkType := U32(B, P + 4);
    Inc(P, 8);
    { Compare unsigned lengths before narrowing or advancing the cursor. }
    if (ChunkLen > Total - LongWord(P)) or (ChunkLen mod 4 <> 0) then Exit;
    if not SeenJson and (ChunkType <> GLB_CHUNK_JSON) then Exit;
    if ChunkType = GLB_CHUNK_JSON then
    begin
      if SeenJson or (ChunkLen = 0) then Exit;
      SetString(JsonStr, PAnsiChar(@B[P]), ChunkLen);
      SeenJson := True;
    end
    else if ChunkType = GLB_CHUNK_BIN then
    begin
      if SeenBin then Exit;
      BinOfs := P; BinLen := ChunkLen;
      SeenBin := True;
    end;
    Inc(P, Integer(ChunkLen));
  end;
  Result := JsonStr <> '';
end;

function ObjOf(O: TJSONObject; const Name: string): TJSONObject;
var D: TJSONData;
begin
  Result := nil;
  if O = nil then Exit;
  D := O.Find(Name);
  if (D <> nil) and (D.JSONType = jtObject) then Result := TJSONObject(D);
end;

function ArrOf(O: TJSONObject; const Name: string): TJSONArray;
var D: TJSONData;
begin
  Result := nil;
  if O = nil then Exit;
  D := O.Find(Name);
  if (D <> nil) and (D.JSONType = jtArray) then Result := TJSONArray(D);
end;

function ObjAt(A: TJSONArray; I: Integer): TJSONObject;
begin
  Result := nil;
  if (A = nil) or (I < 0) or (I >= A.Count) then Exit;
  if A.Items[I].JSONType = jtObject then Result := TJSONObject(A.Items[I]);
end;

function CountOf(A: TJSONArray): Integer;
begin
  if A = nil then Result := 0 else Result := A.Count;
end;

function HasKey(O: TJSONObject; const Name: string): Boolean;
begin
  Result := (O <> nil) and (O.Find(Name) <> nil);
end;

function IntOf(O: TJSONObject; const Name: string; Def: Integer): Integer;
var D: TJSONData;
begin
  Result := Def;
  if O = nil then Exit;
  D := O.Find(Name);
  if (D <> nil) and (D.JSONType = jtNumber) then Result := D.AsInteger;
end;

function StrOf(O: TJSONObject; const Name, Def: string): string;
var D: TJSONData;
begin
  Result := Def;
  if O = nil then Exit;
  D := O.Find(Name);
  if (D <> nil) and (D.JSONType = jtString) then Result := D.AsString;
end;

function ArrInt(A: TJSONArray; I, Def: Integer): Integer;
begin
  Result := Def;
  if (A = nil) or (I < 0) or (I >= A.Count) then Exit;
  if A.Items[I].JSONType = jtNumber then Result := A.Items[I].AsInteger;
end;

function ArrFloat(A: TJSONArray; I: Integer; Def: Double): Double;
begin
  Result := Def;
  if (A = nil) or (I < 0) or (I >= A.Count) then Exit;
  if A.Items[I].JSONType = jtNumber then Result := A.Items[I].AsFloat;
end;

function CompSize(Ct: Integer): Integer;
begin
  case Ct of
    5120, 5121: Result := 1;
    5122, 5123: Result := 2;
    5125, 5126: Result := 4;
  else          Result := 0;
  end;
end;

function TypeCount(const T: string): Integer;
begin
  if      T = 'SCALAR' then Result := 1
  else if T = 'VEC2'   then Result := 2
  else if T = 'VEC3'   then Result := 3
  else if T = 'VEC4'   then Result := 4
  else if T = 'MAT4'   then Result := 16
  else                      Result := 0;
end;

function CompTypeName(C: Integer): string;
begin
  case C of
    5120: Result := 'BYTE';
    5121: Result := 'UNSIGNED_BYTE';
    5122: Result := 'SHORT';
    5123: Result := 'UNSIGNED_SHORT';
    5125: Result := 'UNSIGNED_INT';
    5126: Result := 'FLOAT';
  else    Result := 'comp#' + IntToStr(C);
  end;
end;

end.

unit RiderCorrectiveData;

{$mode objfpc}{$H+}

{ Storage only, shared by the editor and renderer. Atlas data is indexed by
  mesh vertex, not by the serialized GLB size. Node/contact/material edits
  and JSON formatting do not invalidate it. }
interface

uses Classes, SysUtils, fpjson;

function OpenRiderCorrectiveData(const ModelPath: string;
  out Metadata: TJSONObject): TMemoryStream;
procedure EmbedRiderCorrectiveData(Root: TJSONObject; var Bin: TBytes;
  const SourcePath: string);

implementation

uses jsonparser, GltfCore;

const AtlasKey = 'riderPoseAtlas';

function ReadMetadata(const Path: string): TJSONObject;
var S: TStringList; D: TJSONData;
begin
  S := TStringList.Create;
  try
    S.LoadFromFile(Path);
    D := GetJSON(S.Text);
  finally S.Free end;
  if not (D is TJSONObject) then
  begin
    D.Free;
    raise EReadError.Create('Invalid avatar corrective metadata');
  end;
  Result := TJSONObject(D);
end;

function OpenSidecar(const ModelPath: string;
  out Metadata: TJSONObject): TMemoryStream;
begin
  Result := nil;
  Metadata := nil;
  if not FileExists(ChangeFileExt(ModelPath, '.pose.json')) then Exit;
  Metadata := ReadMetadata(ChangeFileExt(ModelPath, '.pose.json'));
  try
    Result := TMemoryStream.Create;
    Result.LoadFromFile(ChangeFileExt(ModelPath, '.pose.bin'));
  except
    FreeAndNil(Result);
    FreeAndNil(Metadata);
    raise;
  end;
end;

function OpenRiderCorrectiveData(const ModelPath: string;
  out Metadata: TJSONObject): TMemoryStream;
var
  F: TFileStream;
  Header: array[0..2] of LongWord;
  Chunk: array[0..1] of LongWord;
  Json: RawByteString;
  D: TJSONData;
  Root, Atlas, View: TJSONObject;
  BinOffset, BinLength, Offset, Size: Int64;
begin
  Result := nil; Metadata := nil;
  F := TFileStream.Create(ModelPath, fmOpenRead or fmShareDenyNone);
  D := nil;
  try
    if F.Size < SizeOf(Header) then Exit;
    F.ReadBuffer(Header, SizeOf(Header));
    if (Header[0] <> GLB_MAGIC) or (Header[1] <> 2) or
       (Header[2] <> F.Size) then Exit;
    BinOffset := 0; BinLength := 0; Json := '';
    while F.Position < F.Size do
    begin
      F.ReadBuffer(Chunk, SizeOf(Chunk));
      if Int64(Chunk[0]) > F.Size - F.Position then
        raise EReadError.Create('Invalid avatar GLB chunk');
      case Chunk[1] of
        GLB_CHUNK_JSON:
          begin
            SetLength(Json, Chunk[0]);
            if Chunk[0] > 0 then F.ReadBuffer(Json[1], Chunk[0]);
          end;
        GLB_CHUNK_BIN:
          begin
            BinOffset := F.Position; BinLength := Chunk[0];
            F.Seek(Chunk[0], soCurrent);
          end;
        else F.Seek(Chunk[0], soCurrent);
      end;
    end;
    if Json = '' then Exit;
    D := GetJSON(Json);
    if not (D is TJSONObject) then Exit;
    Root := TJSONObject(D);
    Atlas := ObjOf(ObjOf(Root, 'extras'), AtlasKey);
    if Atlas = nil then
    begin
      { Do not apply abandoned sidecars to an unrelated replacement avatar. }
      if ObjOf(ObjOf(Root, 'extras'), 'poseCorrectives') <> nil then
        Result := OpenSidecar(ModelPath, Metadata);
      Exit;
    end;
    View := ObjAt(ArrOf(Root, 'bufferViews'), IntOf(Atlas, 'bufferView', -1));
    Offset := IntOf(View, 'byteOffset', 0);
    Size := IntOf(View, 'byteLength', -1);
    if (View = nil) or (IntOf(View, 'buffer', -1) <> 0) or
       (Offset < 0) or (Size <= 0) or (Offset > BinLength) or
       (Size > BinLength - Offset) or (BinOffset = 0) then
      raise EReadError.Create('Invalid embedded avatar corrective buffer');
    Metadata := TJSONObject(Atlas.Clone);
    try
      Result := TMemoryStream.Create;
      F.Position := BinOffset + Offset;
      Result.CopyFrom(F, Size);
      Result.Position := 0;
    except
      FreeAndNil(Result); FreeAndNil(Metadata);
      raise;
    end;
  finally
    D.Free; F.Free;
  end;
end;

procedure EmbedRiderCorrectiveData(Root: TJSONObject; var Bin: TBytes;
  const SourcePath: string);
var
  Extras, Metadata, View, Buffer: TJSONObject;
  Views, Buffers: TJSONArray;
  Data: TMemoryStream;
  Offset, N: Integer;
begin
  Extras := ObjOf(Root, 'extras');
  if (Extras = nil) or (ObjOf(Extras, AtlasKey) <> nil) or
     (ObjOf(Extras, 'poseCorrectives') = nil) then Exit;
  Data := OpenSidecar(SourcePath, Metadata);
  if Data = nil then Exit;
  try
    if (Data.Size <= 0) or (Data.Size > High(Integer) - Length(Bin) - 4) then
      raise EReadError.Create('Invalid avatar corrective data size');
    Views := ArrOf(Root, 'bufferViews');
    Buffers := ArrOf(Root, 'buffers');
    Buffer := ObjAt(Buffers, 0);
    if (Views = nil) or (Buffer = nil) then
      raise EReadError.Create('Missing avatar GLB buffers');
    Offset := (Length(Bin) + 3) and not 3;
    N := Data.Size;
    SetLength(Bin, Offset + N);
    Move(Data.Memory^, Bin[Offset], N);
    View := TJSONObject.Create;
    View.Add('buffer', 0); View.Add('byteOffset', Offset); View.Add('byteLength', N);
    Metadata.Delete('glb_bytes');
    Metadata.Add('bufferView', Views.Count);
    Views.Add(View);
    Buffer.Delete('byteLength'); Buffer.Add('byteLength', Length(Bin));
    Extras.Add(AtlasKey, Metadata); Metadata := nil;
  finally
    Metadata.Free; Data.Free;
  end;
end;

end.

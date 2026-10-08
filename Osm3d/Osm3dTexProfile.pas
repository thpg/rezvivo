unit Osm3dTexProfile;

{ Texture-size profiler (diagnostic, gated behind TEX_SIZE_PROFILE). One shared sink: call
  ProfileTexNode(node, tag) right after a texture node's image/URL is set; it logs the texture's REAL
  dimensions, format and GPU bytes (full mip chain) to osm3d_texture_sizes.log (fresh per run,
  thread-safe). De-duplicated (by URL for file textures, by tag+dimensions for embedded-pixel
  textures) since most nodes are rebuilt per block/tile, so the running total is the true unique GPU
  footprint. Pixel textures read dimensions in-node; URL textures are loaded once on first sight.
  With the define off the unit body and every call site (same IFDEF) compile to nothing. }

{$mode objfpc}{$H+}

interface

uses
  X3DNodes;

{ Log one texture node's real size (deduplicated). ATag is a short category
  label, e.g. 'surf', 'atlas', 'halo', 'distf', 'plate', 'glow'. }
procedure ProfileTexNode(ANode: TX3DNode; const ATag: string);

{ Log a texture by file/URL directly (deduplicated by path). }
procedure ProfileTexFile(const ATag, AFileName: string);

implementation

uses
  SysUtils, Classes, CastleImages;

var
  gCS:    TRTLCriticalSection;
  gSeen:  TStringList;
  gBytes: Int64   = 0;
  gCount: Integer = 0;
  gOpen:  Boolean = False;
  gInit:  Boolean = False;

procedure EnsureInit;
begin
  if gInit then Exit;
  InitCriticalSection(gCS);
  gSeen := TStringList.Create;
  gSeen.Sorted := True;                 { O(log n) lookups }
  gSeen.Duplicates := dupIgnore;
  gInit := True;
end;

{ Core: record one texture under a dedup key. Returns having logged iff new. }
procedure RecordTex(const ATag, AKey, AName: string; W, H, PixBytes: Integer);
var f: TextFile; b: Int64;
begin
  if (W <= 0) or (H <= 0) or (PixBytes <= 0) then Exit;
  EnterCriticalSection(gCS);
  try
    if gSeen.IndexOf(AKey) >= 0 then Exit;   { already counted }
    gSeen.Add(AKey);
    b := Round(Int64(W) * Int64(H) * PixBytes * 4 / 3);   { + full mip chain }
    Inc(gCount);
    gBytes := gBytes + b;
    AssignFile(f, 'osm3d_texture_sizes.log');
    try
      if gOpen then Append(f) else begin Rewrite(f); gOpen := True; end;
      WriteLn(f, Format('%-6s %5d x %-5d  %dB/tx -> %8.2f MB GPU(+mips)  | %s   '
                      + '[unique %d, %.1f MB]',
        [ATag, W, H, PixBytes, b / (1024 * 1024), AName,
         gCount, gBytes / (1024 * 1024)]));
      CloseFile(f);
    except end;
  finally
    LeaveCriticalSection(gCS);
  end;
end;

function SeenKey(const AKey: string): Boolean;
begin
  EnterCriticalSection(gCS);
  try Result := gSeen.IndexOf(AKey) >= 0;
  finally LeaveCriticalSection(gCS); end;
end;

procedure ProfileTexFile(const ATag, AFileName: string);
var Img: TCastleImage;
begin
  EnsureInit;
  if AFileName = '' then Exit;
  if SeenKey(AFileName) then Exit;          { don't reload known files }
  try
    Img := LoadImage(AFileName);
    try
      RecordTex(ATag, AFileName, AFileName, Img.Width, Img.Height,
                Integer(Img.PixelSize));
    finally
      Img.Free;
    end;
  except end;
end;

procedure ProfileTexNode(ANode: TX3DNode; const ATag: string);
var
  Img: TCastleImage;
  Url, Key: string;
begin
  EnsureInit;
  if ANode = nil then Exit;

  if ANode is TPixelTextureNode then
  begin
    Img := TPixelTextureNode(ANode).FdImage.Value;
    if Img = nil then Exit;
    { Per-block rebuilt pixel nodes share a tag and dimensions -> one entry. }
    Key := 'px:' + ATag + ':' + IntToStr(Img.Width) + 'x'
           + IntToStr(Img.Height) + 'x' + IntToStr(Integer(Img.PixelSize));
    RecordTex(ATag, Key, ATag + ' (embedded pixels)',
              Img.Width, Img.Height, Integer(Img.PixelSize));
  end
  else if ANode is TImageTextureNode then
  begin
    if TImageTextureNode(ANode).FdUrl.Count = 0 then Exit;
    Url := TImageTextureNode(ANode).FdUrl.Items[0];
    ProfileTexFile(ATag, Url);
  end;
end;

initialization
  { EnsureInit is lazy so this unit is safe regardless of uses-clause order. }

finalization
  if gInit then
  begin
    gSeen.Free;
    DoneCriticalSection(gCS);
  end;

end.

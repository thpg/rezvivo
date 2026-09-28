unit GrassRenderer;
{$mode objfpc}{$H+}
interface
uses SysUtils, Classes, Math, GL, GLExt, TreeMath, TreeLOD, GrassModel;
type
  TGrassPatchRenderer = class
  private
    FProgram,FVAO,FAtlas: GLuint;
    FIndices:array[0..1,0..2,0..1]of GLuint;
    FIndexCounts:array[0..1,0..2,0..1]of Integer;
    FWeedIndices:array[0..1]of GLuint;
    FLastBuffer,FLastIndex:GLuint;
    FLastFirst,FLastGrid,FLastMode,FLastDetail:Integer;
    FPixelScale:Single;
    FPerspective,FAdaptiveDetail:Boolean;
    FTriangles:Int64;
    FProj,FView,FModel,FCamera,FSun,FTime,FWind,FMode,FBake,FDistance,FGrid,FSlice,FProfile,FColors,FSampler: GLint;
    FLodDistances,FTopDistances,FBladeViewGain,FGrowth,FVariation,FWeeds: GLint;
    FProfiles: TGrassProfiles;
    FLodSettings:TGrassLodSettings;
    FDensityDistances:GLint;
    FGeometryDetail:GLint;
    FAtlasReady: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Initialize(const ShaderDir: string; const ShadowLibrary: string='');
    procedure LoadAtlas(const Directory: string;Rebuild:Boolean=False);
    procedure BeginFrame(const Projection,View,Model: TTreeMat4;
      const Camera,Sun: TTreeVec3; Seconds,Wind: Single; Bake: Integer=0; DistanceOverride: Single=-1);
    function DrawSignature(Distant:Boolean;Kind:Integer;NearestDepth,RadialDistance:Single;GroundOnly:Boolean=False):Integer;
    procedure Draw(Buffer: GLuint; First,Count: Integer; Distant: Boolean; Kind:Integer=-1; NearestDepth:Single=0; GroundOnly:Boolean=False;RadialDistance:Single=-1);
    procedure EndFrame;
    function BladeDistance(Kind:Integer):Single;
    procedure BakeKind(const Directory: string; Kind: Integer);
    procedure SaveProfiles(const Path: string);
    procedure LoadProfiles(const Path: string);
    property Profiles:TGrassProfiles read FProfiles write FProfiles;
    property LodSettings:TGrassLodSettings read FLodSettings write FLodSettings;
    property AtlasReady:Boolean read FAtlasReady;
    property ProgramHandle:GLuint read FProgram;
    property AdaptiveDetail:Boolean read FAdaptiveDetail write FAdaptiveDetail;
    property Triangles:Int64 read FTriangles;
  end;
function UploadGrassPatches(const Patches: TGrassPatches): GLuint;
{ Runtime diagnostic switches; not stored in quality settings or profiles. }
var GrassDrawBlades:Boolean=True;
    GrassDrawCards:Boolean=True;
    GrassDrawCarpet:Boolean=True;
implementation
uses fpjson, jsonparser;
const GrassReferenceLight:array[0..2]of Single=((0.55+2.55*0.68)*0.55,(0.64+0.96*2.55*0.68)*0.55,(0.50+0.9*2.55*0.68)*0.55);
function GrassHeadIndexCount(Grid,Detail:Integer):Integer;
begin
  if Detail=2 then Result:=60+(Grid-2)*12 else Result:=Grid*30;
end;
function GrassHeadVertexIndex(Grid,Detail,Index:Integer):Word;
var Row,Part:Integer;
begin
  if (Detail<>2)or(Index<60)then Exit(Grid*Grid*7+Index);
  Row:=2+(Index-60)div 12;Part:=(Index-60)mod 12;
  { Keep petals/seed planes 1 and 4, including the highest seed level.
    The first two slots hold whole weeds and always retain all vertices. }
  if Part<6 then Inc(Part,6)else Inc(Part,18);
  Result:=Grid*Grid*7+Row*30+Part;
end;
function ReadText(const Path:string):string;
var S:TStringList;
begin S:=TStringList.Create;try S.LoadFromFile(Path);Result:=S.Text;finally S.Free;end;end;
function Shader(Kind:GLenum;const Source:string):GLuint;
var P:PChar;OK:GLint;Log:array[0..8191]of Char;
begin
  Result:=glCreateShader(Kind);P:=PChar(Source);glShaderSource(Result,1,@P,nil);glCompileShader(Result);
  glGetShaderiv(Result,GL_COMPILE_STATUS,@OK);
  if OK=0 then begin glGetShaderInfoLog(Result,SizeOf(Log),nil,@Log[0]);glDeleteShader(Result);raise Exception.Create('Grass shader: '+string(PChar(@Log[0])));end;
end;
function UploadGrassPatches(const Patches: TGrassPatches): GLuint;
begin
  Result:=0;if Length(Patches)=0 then Exit;
  glGenBuffers(1,@Result);glBindBuffer(GL_ARRAY_BUFFER,Result);
  glBufferData(GL_ARRAY_BUFFER,Length(Patches)*SizeOf(TGrassPatch),@Patches[0],GL_STATIC_DRAW);
  glBindBuffer(GL_ARRAY_BUFFER,0);
end;
constructor TGrassPatchRenderer.Create;
var K:Integer;
begin inherited Create;FAdaptiveDetail:=True;FLodSettings:=DefaultGrassLod;for K:=0 to 7 do FProfiles[K]:=DefaultGrassProfile(K);end;
destructor TGrassPatchRenderer.Destroy;
begin
  if FProgram<>0 then glDeleteProgram(FProgram);
  if FVAO<>0 then glDeleteVertexArrays(1,@FVAO);
  glDeleteBuffers(12,@FIndices[0,0,0]);
  glDeleteBuffers(2,@FWeedIndices[0]);
  if FAtlas<>0 then glDeleteTextures(1,@FAtlas);
  inherited Destroy;
end;
procedure TGrassPatchRenderer.Initialize(const ShaderDir,ShadowLibrary:string);
const Tri:array[0..14]of Word=(0,1,2,1,3,2,2,3,4,3,5,4,4,5,6);
      MediumTri:array[0..8]of Word=(0,1,4,1,5,4,4,5,6);
      SmallTri:array[0..2]of Word=(0,1,6);
var VS,FS:GLuint;OK:GLint;Log:array[0..8191]of Char;
    Indices:array of Word;L,Detail,Sparse,Grid,B,J,N,BladeIndices:Integer;FragmentSource:string;
begin
  if FProgram<>0 then Exit;
  if not Load_GL_version_3_3_CORE then raise Exception.Create('OpenGL 3.3 is required for grass');
  VS:=Shader(GL_VERTEX_SHADER,ReadText(IncludeTrailingPathDelimiter(ShaderDir)+'grass.vert'));
  try
    FragmentSource:=StringReplace(ReadText(IncludeTrailingPathDelimiter(ShaderDir)+'grass.frag'),
      '/*__GRASS_SHADOW_LIBRARY__*/',ShadowLibrary,[rfReplaceAll]);
    FragmentSource:=StringReplace(FragmentSource,'/*__GRASS_SURFACE_LIBRARY__*/',GrassSurfaceGLSL,[rfReplaceAll]);
    FS:=Shader(GL_FRAGMENT_SHADER,FragmentSource);
    try
      FProgram:=glCreateProgram();glAttachShader(FProgram,VS);glAttachShader(FProgram,FS);glLinkProgram(FProgram);
      glGetProgramiv(FProgram,GL_LINK_STATUS,@OK);
      if OK=0 then begin glGetProgramInfoLog(FProgram,SizeOf(Log),nil,@Log[0]);glDeleteProgram(FProgram);FProgram:=0;raise Exception.Create('Grass link: '+string(PChar(@Log[0])));end;
    finally glDeleteShader(FS);end;
  finally glDeleteShader(VS);end;
  glGenVertexArrays(1,@FVAO);glBindVertexArray(FVAO);glGenBuffers(12,@FIndices[0,0,0]);
  for L:=0 to 1 do for Detail:=0 to 2 do for Sparse:=0 to 1 do begin
    Grid:=16;if L=1 then Grid:=32;
    BladeIndices:=15;if Detail=1 then BladeIndices:=9 else if Detail=2 then BladeIndices:=3;
    SetLength(Indices,Grid*Grid*BladeIndices+GrassHeadIndexCount(Grid,Detail));N:=0;
    { All levels reuse the same shader vertex IDs: roots, seed, tip, wind and
      density stay identical. Only subpixel bends lose intermediate vertices. }
    for B:=0 to Grid*Grid-1 do begin
      if (Sparse<>0)and((GrassHash(LongWord(B) xor $68bc21eb)and 3)<>0)then Continue;
      for J:=0 to BladeIndices-1 do begin
      case Detail of
        0:Indices[N]:=B*7+Tri[J];
        1:Indices[N]:=B*7+MediumTri[J];
        2:Indices[N]:=B*7+SmallTri[J];
      end;
      Inc(N);
      end;
    end;
    for J:=0 to GrassHeadIndexCount(Grid,Detail)-1 do begin
      Indices[N]:=GrassHeadVertexIndex(Grid,Detail,J);Inc(N);
    end;
    FIndexCounts[L,Detail,Sparse]:=N;
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER,FIndices[L,Detail,Sparse]);glBufferData(GL_ELEMENT_ARRAY_BUFFER,N*SizeOf(Word),@Indices[0],GL_STATIC_DRAW);
  end;
  glGenBuffers(2,@FWeedIndices[0]);
  for L:=0 to 1 do begin
    Grid:=16;if L=1 then Grid:=32;
    SetLength(Indices,60);
    for J:=0 to 59 do Indices[J]:=Grid*Grid*7+J;
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER,FWeedIndices[L]);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER,60*SizeOf(Word),@Indices[0],GL_STATIC_DRAW);
  end;
  glBindVertexArray(0);
  FProj:=glGetUniformLocation(FProgram,'uProjection');FView:=glGetUniformLocation(FProgram,'uView');FModel:=glGetUniformLocation(FProgram,'uModel');
  FCamera:=glGetUniformLocation(FProgram,'uCamera');FSun:=glGetUniformLocation(FProgram,'uSun');FTime:=glGetUniformLocation(FProgram,'uTime');
  FWind:=glGetUniformLocation(FProgram,'uWind');FMode:=glGetUniformLocation(FProgram,'uMode');FBake:=glGetUniformLocation(FProgram,'uBake');
  FDistance:=glGetUniformLocation(FProgram,'uDistanceOverride');
  FLodDistances:=glGetUniformLocation(FProgram,'uLodDistances');
  FDensityDistances:=glGetUniformLocation(FProgram,'uDensityDistances');
  FGeometryDetail:=glGetUniformLocation(FProgram,'uGeometryDetail');
  FTopDistances:=glGetUniformLocation(FProgram,'uTopDistances');
  FBladeViewGain:=glGetUniformLocation(FProgram,'uBladeViewGain');
  FGrowth:=glGetUniformLocation(FProgram,'uGrowth');FVariation:=glGetUniformLocation(FProgram,'uVariation');
  FWeeds:=glGetUniformLocation(FProgram,'uWeeds');
  FGrid:=glGetUniformLocation(FProgram,'uGrid');FSlice:=glGetUniformLocation(FProgram,'uSlice');
  FProfile:=glGetUniformLocation(FProgram,'uProfile');FColors:=glGetUniformLocation(FProgram,'uColors');FSampler:=glGetUniformLocation(FProgram,'uAtlas');
end;
procedure TGrassPatchRenderer.LoadAtlas(const Directory:string;Rebuild:Boolean);
const Header:array[0..4]of LongWord=($47535A52,GRASS_MODEL_VERSION,GRASS_BAKE_SIZE,GRASS_ATLAS_LAYERS,2);
var K,I,Slice,Offset:Integer;Pixels:TLODPixels;Path,BinaryPath:string;
    Raw:array of Byte;CheckHeader:array[0..4]of LongWord;Stream:TFileStream;Loaded:Boolean;Alpha,Lit:Single;
    Background:TTreeVec3;Weight:Double;MaxAnisotropy:GLfloat;
begin
  FAtlasReady:=False;Loaded:=False;BinaryPath:=IncludeTrailingPathDelimiter(Directory)+'grass.rgba';
  SetLength(Raw,GRASS_BAKE_SIZE*GRASS_BAKE_SIZE*GRASS_ATLAS_LAYERS*4);
  if not Rebuild and FileExists(BinaryPath)then begin
    Stream:=TFileStream.Create(BinaryPath,fmOpenRead or fmShareDenyWrite);
    try
      if Stream.Size=Length(Raw)+SizeOf(Header)then begin
        Stream.ReadBuffer(CheckHeader,SizeOf(CheckHeader));
        Loaded:=CompareMem(@Header[0],@CheckHeader[0],SizeOf(Header));
        if Loaded then Stream.ReadBuffer(Raw[0],Length(Raw));
      end;
    finally Stream.Free;end;
  end;
  if not Loaded then begin
    for K:=0 to GRASS_SPECIES_COUNT-1 do for Slice:=0 to GRASS_ATLAS_VIEWS-1 do begin
      Path:=IncludeTrailingPathDelimiter(Directory)+GrassName(K);
      if Slice=3 then Path:=Path+'-top' else if Slice<>1 then Path:=Path+'-'+IntToStr(Slice);
      Path:=Path+'.png';
      if not FileExists(Path)then Exit;
      Pixels:=LoadLODPng(Path,GRASS_BAKE_SIZE,GRASS_BAKE_SIZE);Offset:=(K*GRASS_ATLAS_VIEWS+Slice)*GRASS_BAKE_SIZE*GRASS_BAKE_SIZE*4;
      if Slice=3 then begin
        { The top view is a continuous ground surface, not a cutout card.
          Fill its few uncovered samples just like TGroundAtlas does. Alpha
          testing those gaps exposed bright terrain pixels during movement. }
        Background:=Vec(0,0,0);Weight:=0;
        for I:=0 to Length(Pixels) div 4-1 do begin
          Background:=Add(Background,Vec(Pixels[I*4],Pixels[I*4+1],Pixels[I*4+2]));
          Weight:=Weight+Pixels[I*4+3];
        end;
        Background:=Scale(Background,0.5/Max(0.00001,Weight));
        for I:=0 to Length(Pixels) div 4-1 do begin
          Alpha:=1-Pixels[I*4+3];
          Pixels[I*4]:=Pixels[I*4]+Background.X*Alpha;
          Pixels[I*4+1]:=Pixels[I*4+1]+Background.Y*Alpha;
          Pixels[I*4+2]:=Pixels[I*4+2]+Background.Z*Alpha;Pixels[I*4+3]:=1;
        end;
      end;
      { The live blade shader and this conversion use the same canopy light.
        Cache the final premultiplied display color: no per-pixel tone mapping
        at runtime, and dark albedo no longer loses precision in linear RGBA8. }
      for I:=0 to High(Pixels)do begin
        if I mod 4=3 then Lit:=Pixels[I]
        else begin
          Alpha:=Pixels[(I div 4)*4+3];Lit:=Pixels[I]/Max(0.00001,Alpha)*GrassReferenceLight[I mod 4];
          Lit:=Power(Lit/(1+Lit),1/2.2)*Alpha;
        end;
        Raw[Offset+I]:=Round(EnsureRange(Lit,0.0,1.0)*255);
      end;
    end;
    if Rebuild then begin
      Stream:=TFileStream.Create(BinaryPath,fmCreate);
      try Stream.WriteBuffer(Header,SizeOf(Header));Stream.WriteBuffer(Raw[0],Length(Raw));finally Stream.Free;end;
    end;
  end;
  if FAtlas=0 then glGenTextures(1,@FAtlas);glBindTexture(GL_TEXTURE_2D_ARRAY,FAtlas);
  glTexImage3D(GL_TEXTURE_2D_ARRAY,0,GL_RGBA8,GRASS_BAKE_SIZE,GRASS_BAKE_SIZE,GRASS_ATLAS_LAYERS,0,GL_RGBA,GL_UNSIGNED_BYTE,@Raw[0]);
  glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_MIN_FILTER,GL_LINEAR_MIPMAP_LINEAR);
  glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
  if Load_GL_EXT_texture_filter_anisotropic then begin
    glGetFloatv(GL_MAX_TEXTURE_MAX_ANISOTROPY_EXT,@MaxAnisotropy);
    glTexParameterf(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_MAX_ANISOTROPY_EXT,Min(8,MaxAnisotropy));
  end;
  glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
  glGenerateMipmap(GL_TEXTURE_2D_ARRAY);glBindTexture(GL_TEXTURE_2D_ARRAY,0);FAtlasReady:=True;
end;
procedure TGrassPatchRenderer.BeginFrame(const Projection,View,Model:TTreeMat4;const Camera,Sun:TTreeVec3;Seconds,Wind:Single;Bake:Integer;DistanceOverride:Single);
var K,J:Integer;P,Growth:array[0..31]of Single;Variation:array[0..7]of Single;Weeds:array[0..15]of Single;
    Colors:array[0..23]of Single;ViewGain:array[0..95]of Single;Viewport:array[0..3]of GLint;
    VerticalX,VerticalY,UpLength:Single;
begin
  FTriangles:=0;glGetIntegerv(GL_VIEWPORT,@Viewport[0]);
  UpLength:=Sqrt(Sqr(Model[4])+Sqr(Model[5])+Sqr(Model[6]));
  VerticalX:=View[0]*Model[4]+View[4]*Model[5]+View[8]*Model[6];
  VerticalY:=View[1]*Model[4]+View[5]*Model[5]+View[9]*Model[6];
  { From above, blade height barely projects onto the screen. Keep a floor
    for the lateral bend and width, rather than using full vertical height. }
  FPixelScale:=Max(1,Viewport[3])*Abs(Projection[5])*0.5*
    Max(UpLength*0.35,Sqrt(Sqr(VerticalX)+Sqr(VerticalY)));
  FPerspective:=Abs(Projection[15])<0.5;
  glUseProgram(FProgram);glBindVertexArray(FVAO);
  for J:=0 to 3 do begin glEnableVertexAttribArray(J);glVertexAttribDivisor(J,1);end;
  FLastBuffer:=0;FLastIndex:=0;FLastFirst:=-1;FLastGrid:=-1;FLastMode:=-1;FLastDetail:=-1;
  glUniformMatrix4fv(FProj,1,GL_FALSE,@Projection);glUniformMatrix4fv(FView,1,GL_FALSE,@View);glUniformMatrix4fv(FModel,1,GL_FALSE,@Model);
  glUniform3fv(FCamera,1,@Camera);glUniform3fv(FSun,1,@Sun);glUniform1f(FTime,Seconds);glUniform1f(FWind,Wind);glUniform1i(FBake,Bake);glUniform1f(FDistance,DistanceOverride);glUniform1i(FSlice,-1);
  glUniform4f(FLodDistances,FLodSettings.BladeStart,FLodSettings.BladeEnd,FLodSettings.ViewFade,FLodSettings.ViewEnd);
  glUniform2f(FTopDistances,FLodSettings.TopStart,FLodSettings.TopEnd);
  glUniform2f(FDensityDistances,FLodSettings.DensityStart,FLodSettings.DensityEnd);
  for K:=0 to 7 do begin
    P[K*4]:=FProfiles[K].Height;P[K*4+1]:=FProfiles[K].Width;P[K*4+2]:=FProfiles[K].Density;P[K*4+3]:=FProfiles[K].Flowers;
    Growth[K*4]:=FProfiles[K].Broadleaf;Growth[K*4+1]:=FProfiles[K].Rosettes;
    Growth[K*4+2]:=FProfiles[K].SeedHeads;Growth[K*4+3]:=FProfiles[K].Dryness;
    Variation[K]:=FProfiles[K].Variation;
    Weeds[K*2]:=FProfiles[K].Weeds;Weeds[K*2+1]:=FProfiles[K].WeedHeight;
    Colors[K*3]:=FProfiles[K].Color.X;Colors[K*3+1]:=FProfiles[K].Color.Y;Colors[K*3+2]:=FProfiles[K].Color.Z;
    for J:=0 to 3 do begin
      ViewGain[(K*4+J)*3]:=FProfiles[K].BladeViewGain[J].X;ViewGain[(K*4+J)*3+1]:=FProfiles[K].BladeViewGain[J].Y;ViewGain[(K*4+J)*3+2]:=FProfiles[K].BladeViewGain[J].Z;
    end;
  end;
  glUniform4fv(FProfile,8,@P[0]);glUniform3fv(FColors,8,@Colors[0]);
  glUniform4fv(FGrowth,8,@Growth[0]);glUniform1fv(FVariation,8,@Variation[0]);
  glUniform2fv(FWeeds,8,@Weeds[0]);
  glUniform3fv(FBladeViewGain,32,@ViewGain[0]);
  glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D_ARRAY,FAtlas);glUniform1i(FSampler,0);
  glEnable(GL_DEPTH_TEST);glDepthMask(GL_TRUE);glDisable(GL_CULL_FACE);glDisable(GL_BLEND);
end;
function TGrassPatchRenderer.DrawSignature(Distant:Boolean;Kind:Integer;NearestDepth,RadialDistance:Single;GroundOnly:Boolean):Integer;
var Detail,Sparse,Mode:Integer;Pixels,BaseEnd:Single;
begin
  if RadialDistance<0 then RadialDistance:=NearestDepth;
  Detail:=0;Sparse:=0;Mode:=0;
  if Distant then begin
    Mode:=2;
    if GroundOnly then Mode:=4
    else if RadialDistance>=FLodSettings.TopEnd+2 then Mode:=3;
    if (not GrassDrawCards) then Mode:=3;
    if ((Mode in [3,4]) and not GrassDrawCarpet) or
       (not GrassDrawCards and not GrassDrawCarpet) then Exit(-1);
  end else if (Kind>=0)and(Kind<GRASS_SPECIES_COUNT) then begin
    if not GrassDrawBlades then Exit(-1);
    BaseEnd:=FLodSettings.BladeEnd*GrassLodHeightScale(FProfiles[Kind].Height);
    { Tall weeds do not extend thousands of ordinary low blades. Both draw
      paths retain the original radius of their own visible plant height. }
    if RadialDistance>BaseEnd+2 then begin
      if FProfiles[Kind].Weeds<=0 then Exit(-1);
      Mode:=1;
    end;
    Sparse:=Ord(FAdaptiveDetail and (RadialDistance>=FLodSettings.DensityEnd));
    if FAdaptiveDetail and (NearestDepth>0) then begin
    { Mean bent canopy height, not the maximum unbent stalk length. The rare
      tall plants use independent geometry and do not need these bend rows. }
    Pixels:=FPixelScale*FProfiles[Kind].Height*0.70;
    if FPerspective then Pixels:=Pixels/NearestDepth;
    if Pixels<8 then Detail:=2 else if Pixels<18 then Detail:=1;
    { grass.vert keeps the width of broad leaves in its one-triangle form;
      the old tiny root pair erased them and forced three triangles forever. }
    end;
    if Mode=1 then begin Detail:=0;Sparse:=0 end;
  end;
  Result:=Mode+5*(Detail+3*(Sparse+2*EnsureRange(Kind,0,7)));
end;
procedure TGrassPatchRenderer.Draw(Buffer:GLuint;First,Count:Integer;Distant:Boolean;Kind:Integer;NearestDepth:Single;GroundOnly:Boolean;RadialDistance:Single);
var I,Grid,Detail,Sparse,IndexCount,Signature,Mode,ShaderMode:Integer;Index:GLuint;
begin
  if (Count=0)or(Buffer=0)or(Distant and not FAtlasReady) then Exit;
  Signature:=DrawSignature(Distant,Kind,NearestDepth,RadialDistance,GroundOnly);
  if Signature<0 then Exit;
  Mode:=Signature mod 5;Detail:=(Signature div 5)mod 3;Sparse:=(Signature div 15)mod 2;
  Grid:=16;if Kind in [4,6]then Grid:=32;
  if Grid<>FLastGrid then begin glUniform1i(FGrid,Grid);FLastGrid:=Grid end;
  ShaderMode:=Ord(Distant)+Ord(GroundOnly);
  if ShaderMode<>FLastMode then begin glUniform1i(FMode,ShaderMode);FLastMode:=ShaderMode end;
  if Detail<>FLastDetail then begin glUniform1i(FGeometryDetail,Detail);FLastDetail:=Detail end;
  if (Buffer<>FLastBuffer)or(First<>FLastFirst)then begin
    if Buffer<>FLastBuffer then glBindBuffer(GL_ARRAY_BUFFER,Buffer);
    for I:=0 to 3 do glVertexAttribPointer(I,4,GL_FLOAT,GL_FALSE,SizeOf(TGrassPatch),Pointer(PtrUInt(First*SizeOf(TGrassPatch)+I*16)));
    FLastBuffer:=Buffer;FLastFirst:=First;
  end;
  if Distant then begin
    if Mode in [3,4]then begin glDrawArraysInstanced(GL_TRIANGLES,6*GRASS_CARDS,6,Count);Inc(FTriangles,Int64(2)*Count);end
    else if not GrassDrawCarpet then begin glDrawArraysInstanced(GL_TRIANGLES,0,6*GRASS_CARDS,Count);Inc(FTriangles,Int64(2*GRASS_CARDS)*Count);end
    else begin glDrawArraysInstanced(GL_TRIANGLES,0,6*(GRASS_CARDS+1),Count);Inc(FTriangles,Int64(2*(GRASS_CARDS+1))*Count);end;
  end else begin
    if Mode=1 then begin Index:=FWeedIndices[Ord(Grid=32)];IndexCount:=60 end
    else begin
    Index:=FIndices[Ord(Grid=32),Detail,Sparse];
    IndexCount:=FIndexCounts[Ord(Grid=32),Detail,Sparse];
    { Species without flowers never need the extra flower vertices. }
    if FAdaptiveDetail and (Kind>=0) and (Kind<GRASS_SPECIES_COUNT) and
      (FProfiles[Kind].Flowers<=0) and (FProfiles[Kind].SeedHeads<=0) then begin
      Dec(IndexCount,GrassHeadIndexCount(Grid,Detail));
      if FProfiles[Kind].Weeds>0 then Inc(IndexCount,60);
    end;
    end;
    if Index<>FLastIndex then begin glBindBuffer(GL_ELEMENT_ARRAY_BUFFER,Index);FLastIndex:=Index end;
    glDrawElementsInstanced(GL_TRIANGLES,IndexCount,GL_UNSIGNED_SHORT,nil,Count);
    Inc(FTriangles,Int64(IndexCount div 3)*Count);
  end;
end;
procedure TGrassPatchRenderer.EndFrame;
begin glBindVertexArray(0);glBindBuffer(GL_ARRAY_BUFFER,0);glBindTexture(GL_TEXTURE_2D_ARRAY,0);glUseProgram(0);end;
function TGrassPatchRenderer.BladeDistance(Kind:Integer):Single;
var H:Single;
begin
  Kind:=EnsureRange(Kind,0,7);H:=FProfiles[Kind].Height;
  if FProfiles[Kind].Weeds>0 then H:=Max(H,FProfiles[Kind].WeedHeight);
  Result:=FLodSettings.BladeEnd*GrassLodHeightScale(H);
end;
procedure TGrassPatchRenderer.SaveProfiles(const Path:string);
var Root,Item:TJSONObject;K,J:Integer;S:TStringList;Gains:TJSONArray;
begin
  Root:=TJSONObject.Create;S:=TStringList.Create;
  try
    Root.Add('version',GRASS_MODEL_VERSION);
    for K:=0 to 7 do begin Item:=TJSONObject.Create;Root.Add(GrassName(K),Item);
      Item.Add('height',FProfiles[K].Height);Item.Add('width',FProfiles[K].Width);Item.Add('density',FProfiles[K].Density);Item.Add('flowers',FProfiles[K].Flowers);
      Item.Add('broadleaf',FProfiles[K].Broadleaf);Item.Add('rosettes',FProfiles[K].Rosettes);
      Item.Add('seed_heads',FProfiles[K].SeedHeads);Item.Add('dryness',FProfiles[K].Dryness);Item.Add('variation',FProfiles[K].Variation);
      Item.Add('weeds',FProfiles[K].Weeds);Item.Add('weed_height',FProfiles[K].WeedHeight);
      Item.Add('red',FProfiles[K].Color.X);Item.Add('green',FProfiles[K].Color.Y);Item.Add('blue',FProfiles[K].Color.Z);
      Gains:=TJSONArray.Create;Item.Add('blade_view_gain',Gains);
      for J:=0 to 3 do with FProfiles[K].BladeViewGain[J] do begin Gains.Add(X);Gains.Add(Y);Gains.Add(Z);end;
    end;
    S.Text:=Root.FormatJSON;S.SaveToFile(Path);
  finally S.Free;Root.Free;end;
end;
procedure TGrassPatchRenderer.LoadProfiles(const Path:string);
var Root,Gains:TJSONData;Item:TJSONObject;K,J:Integer;
begin
  if not FileExists(Path) then Exit;Root:=GetJSON(ReadText(Path));
  try for K:=0 to 7 do begin
    Item:=TJSONObject(Root.FindPath(GrassName(K)));if Item=nil then Continue;
    FProfiles[K].Height:=EnsureRange(Item.Get('height',Double(FProfiles[K].Height)),0.025,1.5);
    FProfiles[K].Width:=EnsureRange(Item.Get('width',Double(FProfiles[K].Width)),0.002,0.06);
    FProfiles[K].Density:=EnsureRange(Item.Get('density',Double(FProfiles[K].Density)),0.2,1.0);
    FProfiles[K].Flowers:=EnsureRange(Item.Get('flowers',Double(FProfiles[K].Flowers)),0.0,0.25);
    if (K=0) and (TJSONObject(Root).Get('version',0)<7) and (FProfiles[K].Flowers=0) then
      FProfiles[K].Flowers:=DefaultGrassProfile(K).Flowers;
    FProfiles[K].Broadleaf:=EnsureRange(Item.Get('broadleaf',Double(FProfiles[K].Broadleaf)),0.0,1.0);
    FProfiles[K].Rosettes:=EnsureRange(Item.Get('rosettes',Double(FProfiles[K].Rosettes)),0.0,1.0);
    FProfiles[K].SeedHeads:=EnsureRange(Item.Get('seed_heads',Double(FProfiles[K].SeedHeads)),0.0,1.0);
    FProfiles[K].Dryness:=EnsureRange(Item.Get('dryness',Double(FProfiles[K].Dryness)),0.0,1.0);
    FProfiles[K].Variation:=EnsureRange(Item.Get('variation',Double(FProfiles[K].Variation)),0.0,1.0);
    FProfiles[K].Weeds:=EnsureRange(Item.Get('weeds',Double(FProfiles[K].Weeds)),0.0,1.0);
    FProfiles[K].WeedHeight:=EnsureRange(Item.Get('weed_height',Double(FProfiles[K].WeedHeight)),0.15,1.5);
    FProfiles[K].Color:=Vec(Item.Get('red',Double(FProfiles[K].Color.X)),Item.Get('green',Double(FProfiles[K].Color.Y)),Item.Get('blue',Double(FProfiles[K].Color.Z)));
    Gains:=Item.Find('blade_view_gain');
    if (Gains<>nil)and(Gains.JSONType=jtArray)and(Gains.Count=12)then
      for J:=0 to 3 do FProfiles[K].BladeViewGain[J]:=Vec(EnsureRange(Gains.Items[J*3].AsFloat,0.5,1.6),EnsureRange(Gains.Items[J*3+1].AsFloat,0.5,1.6),EnsureRange(Gains.Items[J*3+2].AsFloat,0.5,1.6));
  end;finally Root.Free;end;
end;
procedure TGrassPatchRenderer.BakeKind(const Directory:string;Kind:Integer);
const S=GRASS_BAKE_SIZE*2; TOP_LAYERS=32;
var FBO,Color,Depth,Buffer:GLuint;OldFBO,OldViewport:array[0..3]of GLint;
    Patches:TGrassPatches;Pixels,Small:TLODPixels;Projection,View:TTreeMat4;Eye:TTreeVec3;
    Pass,X,Z,I,C,DX,DZ,N,Layer:Integer;Path:string;Coverage:Double;
    Elevation:Single;TargetColor,AtlasColor,Gain:TTreeVec3;ViewColors:array[0..3]of TTreeVec3;
  function MeanDisplay(const Data:TLODPixels;AlreadyDisplay:Boolean):TTreeVec3;
  var I,C:Integer;Sum:array[0..2]of Double;Alpha,Weight,V:Double;
  begin
    FillChar(Sum,SizeOf(Sum),0);Weight:=0;
    for I:=0 to Length(Data)div 4-1 do begin
      Alpha:=Data[I*4+3];if Alpha<0.00001 then Continue;Weight:=Weight+Alpha;
      for C:=0 to 2 do begin
        V:=Data[I*4+C];
        if not AlreadyDisplay then begin V:=V/Alpha*GrassReferenceLight[C];V:=Power(V/(1+V),1/2.2)*Alpha;end;
        Sum[C]:=Sum[C]+V;
      end;
    end;
    Result:=Vec(Sum[0]/Max(Weight,0.00001),Sum[1]/Max(Weight,0.00001),Sum[2]/Max(Weight,0.00001));
  end;
  function DisplayGain(Target,Source:Single):Single;
  var T,S:Double;
  begin
    T:=Power(EnsureRange(Target,0.0,0.99),2.2);S:=Power(EnsureRange(Source,0.0,0.99),2.2);
    Result:=EnsureRange((T/(1-T))/Max(0.000001,S/(1-S)),0.25,4.0);
  end;
begin
  Path:=IncludeTrailingPathDelimiter(Directory);ForceDirectories(Path);
  glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING,@OldFBO[0]);glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING,@OldFBO[1]);glGetIntegerv(GL_VIEWPORT,@OldViewport[0]);
  FBO:=0;Color:=0;Depth:=0;Buffer:=0;
  try
    glGenFramebuffers(1,@FBO);glBindFramebuffer(GL_FRAMEBUFFER,FBO);
    glGenTextures(1,@Color);glBindTexture(GL_TEXTURE_2D,Color);glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA16F,S,S,0,GL_RGBA,GL_FLOAT,nil);
    glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,Color,0);
    glGenRenderbuffers(1,@Depth);glBindRenderbuffer(GL_RENDERBUFFER,Depth);glRenderbufferStorage(GL_RENDERBUFFER,GL_DEPTH_COMPONENT24,S,S);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER,GL_DEPTH_ATTACHMENT,GL_RENDERBUFFER,Depth);
    glDrawBuffer(GL_COLOR_ATTACHMENT0);glReadBuffer(GL_COLOR_ATTACHMENT0);
    if glCheckFramebufferStatus(GL_FRAMEBUFFER)<>GL_FRAMEBUFFER_COMPLETE then raise Exception.Create('Grass bake framebuffer incomplete');
    glViewport(0,0,S,S);glDisable(GL_SCISSOR_TEST);glDisable($8DB9);glDepthFunc(GL_LESS);
    TargetColor:=Vec(0,0,0);Gain:=Vec(1,1,1);
    for Pass:=-4 to 4 do begin
      if Pass<0 then begin
        { Measure the actual blade canopy from riding to overhead views.
          A dense overhead bake sees mostly tips, while the live carpet also
          shows shaded stems. Match each profile's displayed mean instead of
          applying a fixed darkening factor to every top texture. }
        SetLength(Patches,28*28);N:=0;
        for Z:=-12 to 15 do for X:=-12 to 15 do begin Patches[N]:=WholeGrassPatch(X,Z,Kind);Inc(N);end;
        Elevation:=GRASS_VIEW_ELEVATIONS[Pass+4];
        Eye:=Vec(2,20*Elevation,2+20*Sqrt(1-Sqr(Elevation)));View:=LookAt(Eye,Vec(2,0,2));
        Projection:=Orthographic(-2,2,-2*Elevation,2*Elevation,0.01,50);glClearColor(0,0,0,0);
      end else if Pass<3 then begin
        SetLength(Patches,1);Patches[0]:=WholeGrassPatch(0,0,Kind);Patches[0].Base:=Vec(0,0,0);
        Elevation:=FProfiles[Kind].Height;
        if FProfiles[Kind].Weeds>0 then Elevation:=Max(Elevation,FProfiles[Kind].WeedHeight);
        Projection:=Orthographic(-0.9,0.9,0,Elevation*1.12,0.01,10);Eye:=Vec(0,0,4);View:=LookAt(Eye,Vec(0,0,0));
        glClearColor(0,0,0,0);
      end else begin
        { Dense overhead carpet, baked only. Preserve the four-metre period
          across every layer and the guard patches outside the capture. The
          live blade grid, draw calls and atlas size do not grow. }
        SetLength(Patches,36*TOP_LAYERS);N:=0;
        for Layer:=0 to TOP_LAYERS-1 do
          for Z:=-1 to 4 do for X:=-1 to 4 do begin
            Patches[N]:=WholeGrassPatch(X,Z,Kind);
            Patches[N].Seed:=GrassCellSeed((X+4)mod 4+Layer*4,(Z+4)mod 4);
            Patches[N].Reserved:=Layer+1; { bake-only canopy / flower layer }
            Inc(N);
          end;
        Projection:=Orthographic(-2,2,-2,2,0.01,15);Eye:=Vec(2,10,2.001);View:=LookAt(Eye,Vec(2,0,2));
        if Pass=3 then glClearColor(0,0,0,0)
        else with FProfiles[Kind].Color do glClearColor(X*0.42,Y*0.42,Z*0.42,1);
      end;
      Buffer:=UploadGrassPatches(Patches);glDepthMask(GL_TRUE);glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT);
      BeginFrame(Projection,View,Identity,Eye,Vec(-0.4,-0.8,-0.3),0,0,1+Ord(Pass<0));
      if (Pass>=0)and(Pass<3) then glUniform1i(FSlice,Pass);
      Draw(Buffer,0,Length(Patches),False,Kind);EndFrame;
      SetLength(Pixels,S*S*4);glReadPixels(0,0,S,S,GL_RGBA,GL_FLOAT,@Pixels[0]);
      if glGetError()<>GL_NO_ERROR then raise Exception.Create('Grass bake OpenGL error');
      if Pass<0 then begin
        ViewColors[Pass+4]:=MeanDisplay(Pixels,True);
        if Pass=-1 then begin
          TargetColor:=Scale(Add(ViewColors[0],ViewColors[1]),0.5);
          for I:=0 to 3 do FProfiles[Kind].BladeViewGain[I]:=Vec(
            EnsureRange(TargetColor.X/Max(0.000001,ViewColors[I].X),0.5,1.6),
            EnsureRange(TargetColor.Y/Max(0.000001,ViewColors[I].Y),0.5,1.6),
            EnsureRange(TargetColor.Z/Max(0.000001,ViewColors[I].Z),0.5,1.6));
        end;
        glDeleteBuffers(1,@Buffer);Buffer:=0;Continue;
      end;
      Small:=nil;SetLength(Small,GRASS_BAKE_SIZE*GRASS_BAKE_SIZE*4);Coverage:=0;
      for Z:=0 to GRASS_BAKE_SIZE-1 do for X:=0 to GRASS_BAKE_SIZE-1 do begin
        I:=(Z*GRASS_BAKE_SIZE+X)*4;
        for DZ:=0 to 1 do for DX:=0 to 1 do for C:=0 to 3 do Small[I+C]:=Small[I+C]+Pixels[((Z*2+DZ)*S+X*2+DX)*4+C]*0.25;
        Coverage:=Coverage+Small[I+3];
      end;
      if Coverage<100 then raise Exception.Create('Empty grass bake: '+GrassName(Kind));
      if (Pass=3) and (Coverage<GRASS_BAKE_SIZE*GRASS_BAKE_SIZE*0.98) then
        raise Exception.Create('Sparse overhead grass bake: '+GrassName(Kind));
      if Pass=3 then begin
        AtlasColor:=MeanDisplay(Small,False);
        Gain:=Vec(DisplayGain(TargetColor.X,AtlasColor.X),DisplayGain(TargetColor.Y,AtlasColor.Y),DisplayGain(TargetColor.Z,AtlasColor.Z));
      end;
      if Pass>=3 then for I:=0 to Length(Small)div 4-1 do begin
        Small[I*4]:=Small[I*4]*Gain.X;Small[I*4+1]:=Small[I*4+1]*Gain.Y;Small[I*4+2]:=Small[I*4+2]*Gain.Z;
      end;
      if Pass=1 then SaveLODPng(Path+GrassName(Kind)+'.png',Small,GRASS_BAKE_SIZE,GRASS_BAKE_SIZE)
      else if Pass<3 then SaveLODPng(Path+GrassName(Kind)+'-'+IntToStr(Pass)+'.png',Small,GRASS_BAKE_SIZE,GRASS_BAKE_SIZE)
      else if Pass=3 then SaveLODPng(Path+GrassName(Kind)+'-top.png',Small,GRASS_BAKE_SIZE,GRASS_BAKE_SIZE)
      else SaveLODPng(Path+GrassName(Kind)+'-ground.png',Small,GRASS_BAKE_SIZE,GRASS_BAKE_SIZE);
      glDeleteBuffers(1,@Buffer);Buffer:=0;
    end;
    SaveProfiles(Path+'profiles.json');
  finally
    if Buffer<>0 then glDeleteBuffers(1,@Buffer);
    if Depth<>0 then glDeleteRenderbuffers(1,@Depth);if Color<>0 then glDeleteTextures(1,@Color);if FBO<>0 then glDeleteFramebuffers(1,@FBO);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER,OldFBO[0]);glBindFramebuffer(GL_READ_FRAMEBUFFER,OldFBO[1]);
    glViewport(OldViewport[0],OldViewport[1],OldViewport[2],OldViewport[3]);
  end;
end;
end.

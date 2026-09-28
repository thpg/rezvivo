unit Osm3dGpuAccount;

{ Учёт GL-ресурсов, создаваемых проектом напрямую (трава, деревья, профайлер).
  Тонкие обёртки над glGen*/glDelete* считают живые объекты по типам (текстуры,
  буферы, VAO) для ДЕТЕКТА УТЕЧКИ: при неподвижной камере live-счётчики не должны расти.
  Обёртки зовутся всегда, но СЧЁТ — только под {$IFDEF TILE_MEM_PROFILE}; без дефайна
  тело = прямой inline gl*-вызов, нулевой оверхед. Отчёт печатает Osm3dMemCensus.
  Не покрывает ресурсы CGE (тайловые VBO/текстуры) — те видны через NVX VRAM-запрос. }

{$mode objfpc}{$H+}

interface

uses
  CastleGL;     { glGen*/glDelete*, GLsizei, PGLuint }

{$IFDEF TILE_MEM_PROFILE}
var
  { Трогаются только в GL-потоке (главном) — блокировка не нужна. }
  GpuTexLive: Int64 = 0;  GpuTexCreated: Int64 = 0;  GpuTexDeleted: Int64 = 0;
  GpuBufLive: Int64 = 0;  GpuBufCreated: Int64 = 0;  GpuBufDeleted: Int64 = 0;
  GpuVaoLive: Int64 = 0;  GpuVaoCreated: Int64 = 0;  GpuVaoDeleted: Int64 = 0;
  { Road distance-field: текстуры grayscale, создаются на блок и уходят в сцену
    тайла. Считаем КУМУЛЯТИВНО загруженные байты + число (per-block churn). }
  GpuDistFieldBytes: Int64 = 0;
  GpuDistFieldCount: Int64 = 0;
procedure GpuDistFieldAdd(W, H: Integer);
{$ENDIF}

procedure AccGenTextures(n: GLsizei; p: PGLuint); inline;
procedure AccDeleteTextures(n: GLsizei; p: PGLuint); inline;
procedure AccGenBuffers(n: GLsizei; p: PGLuint); inline;
procedure AccDeleteBuffers(n: GLsizei; p: PGLuint); inline;
procedure AccGenVertexArrays(n: GLsizei; p: PGLuint); inline;
procedure AccDeleteVertexArrays(n: GLsizei; p: PGLuint); inline;

implementation

procedure AccGenTextures(n: GLsizei; p: PGLuint);
begin
  glGenTextures(n, p);
  {$IFDEF TILE_MEM_PROFILE}Inc(GpuTexLive, n); Inc(GpuTexCreated, n);{$ENDIF}
end;

procedure AccDeleteTextures(n: GLsizei; p: PGLuint);
begin
  glDeleteTextures(n, p);
  {$IFDEF TILE_MEM_PROFILE}Dec(GpuTexLive, n); Inc(GpuTexDeleted, n);{$ENDIF}
end;

procedure AccGenBuffers(n: GLsizei; p: PGLuint);
begin
  glGenBuffers(n, p);
  {$IFDEF TILE_MEM_PROFILE}Inc(GpuBufLive, n); Inc(GpuBufCreated, n);{$ENDIF}
end;

procedure AccDeleteBuffers(n: GLsizei; p: PGLuint);
begin
  glDeleteBuffers(n, p);
  {$IFDEF TILE_MEM_PROFILE}Dec(GpuBufLive, n); Inc(GpuBufDeleted, n);{$ENDIF}
end;

procedure AccGenVertexArrays(n: GLsizei; p: PGLuint);
begin
  glGenVertexArrays(n, p);
  {$IFDEF TILE_MEM_PROFILE}Inc(GpuVaoLive, n); Inc(GpuVaoCreated, n);{$ENDIF}
end;

procedure AccDeleteVertexArrays(n: GLsizei; p: PGLuint);
begin
  glDeleteVertexArrays(n, p);
  {$IFDEF TILE_MEM_PROFILE}Dec(GpuVaoLive, n); Inc(GpuVaoDeleted, n);{$ENDIF}
end;

{$IFDEF TILE_MEM_PROFILE}
procedure GpuDistFieldAdd(W, H: Integer);
begin
  Inc(GpuDistFieldBytes, Int64(W) * H);   { grayscale, 1 байт/тексель }
  Inc(GpuDistFieldCount);
end;
{$ENDIF}

end.

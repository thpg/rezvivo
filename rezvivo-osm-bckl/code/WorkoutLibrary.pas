{ WorkoutLibrary — сканер папок data/workouts/<категория>/*.zwo.

  Использует CastleFindFiles.FindFiles в рекурсивном режиме —
  он подходит для любого URL-протокола CGE (включая castle-data:/),
  а имя категории извлекается из пути файла.

  Структура:
    data/workouts/
      Beginner/
        30-15-s-4.zwo
      FTP/
        ...

  Папки в data/workouts/ создавать не нужно — они находятся
  автоматически по результатам поиска *.zwo.

  HandleFoundFile обёрнут в try/except: даже если конкретный .zwo
  бросает что-то, что внутренний хендлер в TWorkoutFile.LoadFromUrl
  пропустил, это не должно сломать рекурсивный обход FindFiles —
  мы просто логируем проблему и переходим к следующему файлу.

  Refresh — повторный полный скан с тем же RootUrl. Зовётся редактором
  тренировок после успешного Save, чтобы список плашек подхватил
  новый/изменённый файл (при Save As может появиться новая категория). }
unit WorkoutLibrary;

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses
  Classes, SysUtils, fgl,
  CastleFindFiles,
  WorkoutFile;

type
  TWorkoutCategory = class
  private
    FName:     String;
    FWorkouts: TWorkoutFileList;
  public
    constructor Create(const AName: String);
    destructor Destroy; override;

    property Name:     String           read FName;
    property Workouts: TWorkoutFileList read FWorkouts;
  end;

  TWorkoutCategoryList = specialize TFPGObjectList<TWorkoutCategory>;

  TWorkoutLibrary = class
  private
    FCategories: TWorkoutCategoryList;
    FRootUrl:    String;

    function FindOrCreateCategory(const AName: String): TWorkoutCategory;
    procedure HandleFoundFile(const FileInfo: TFileInfo; var StopSearch: Boolean);
  public
    constructor Create;
    destructor Destroy; override;

    procedure Scan(const ARootUrl: String = 'castle-data:/workouts/rezvivo/');

    { Перезапустить скан с тем же RootUrl. Очищает текущий список
      категорий и читает заново. Зовётся редактором после Save. }
    procedure Refresh;

    function FindCategory(const AName: String): TWorkoutCategory;

    property Categories: TWorkoutCategoryList read FCategories;
    property RootUrl:    String               read FRootUrl;
  end;

var
  WorkoutLib: TWorkoutLibrary;

implementation

uses
  CastleUriUtils, CastleLog;

{ ── TWorkoutCategory ───────────────────────────────────────────────── }

constructor TWorkoutCategory.Create(const AName: String);
begin
  inherited Create;
  FName := AName;
  FWorkouts := TWorkoutFileList.Create(True);
end;

destructor TWorkoutCategory.Destroy;
begin
  FreeAndNil(FWorkouts);
  inherited;
end;

{ ── TWorkoutLibrary ────────────────────────────────────────────────── }

constructor TWorkoutLibrary.Create;
begin
  inherited;
  FCategories := TWorkoutCategoryList.Create(True);
end;

destructor TWorkoutLibrary.Destroy;
begin
  FreeAndNil(FCategories);
  inherited;
end;

function TWorkoutLibrary.FindOrCreateCategory(
  const AName: String): TWorkoutCategory;
var
  I: Integer;
begin
  for I := 0 to FCategories.Count - 1 do
    if SameText(FCategories[I].Name, AName) then
      Exit(FCategories[I]);

  Result := TWorkoutCategory.Create(AName);
  FCategories.Add(Result);
end;

function CategoryFromUrl(const AFileUrl, ARootUrl: String): String;
const
  Marker = '/workouts/';
var
  P, P2: Integer;
  Tail, Sub, ResolvedRoot: String;
begin
  Result := '';
  ResolvedRoot:=ResolveCastleDataUrl(ARootUrl);
  if Pos(ResolvedRoot,AFileUrl)=1 then
    Tail:=Copy(AFileUrl,Length(ResolvedRoot)+1,MaxInt)
  else begin
    P := Pos(Marker, AFileUrl);
    if P <= 0 then Exit;
    Tail := Copy(AFileUrl, P + Length(Marker), MaxInt);
  end;

  P2 := Pos('/', Tail);
  if P2 <= 0 then
    Sub := ''
  else
    Sub := Copy(Tail, 1, P2 - 1);

  Result := StringReplace(Sub, '%20', ' ', [rfReplaceAll]);
end;

procedure TWorkoutLibrary.HandleFoundFile(
  const FileInfo: TFileInfo; var StopSearch: Boolean);
var
  WF: TWorkoutFile;
  CatName: String;
  Cat: TWorkoutCategory;
  Loaded: Boolean;
begin
  CatName := CategoryFromUrl(FileInfo.Url, FRootUrl);
  if CatName = '' then
    CatName := 'Other';

  WF := TWorkoutFile.Create;
  WF.Category := CatName;

  Loaded := False;
  try
    Loaded := WF.LoadFromUrl(FileInfo.Url);
  except
    on E: Exception do
    begin
      WritelnWarning('WorkoutLib',
        'Исключение при загрузке %s [%s]: %s',
        [FileInfo.Url, E.ClassName, E.Message]);
      Loaded := False;
    end;
  end;

  if Loaded then
  begin
    Cat := FindOrCreateCategory(CatName);
    Cat.Workouts.Add(WF);
  end
  else
  begin
    WritelnWarning('WorkoutLib', 'битый файл %s', [FileInfo.Url]);
    WF.Free;
  end;
end;

procedure TWorkoutLibrary.Scan(const ARootUrl: String);
var
  I, N: Integer;
begin
  FRootUrl := ARootUrl;
  if (FRootUrl <> '') and (FRootUrl[Length(FRootUrl)] <> '/') then
    FRootUrl := FRootUrl + '/';

  FCategories.Clear;

  if UriExists(FRootUrl) <> ueDirectory then
  begin
    WritelnWarning('WorkoutLib', 'Корень не найден: %s', [FRootUrl]);
    Exit;
  end;

  FindFiles(FRootUrl, '*.zwo', False,
    {$ifdef FPC}@{$endif} HandleFoundFile, [ffRecursive]);

  N := 0;
  for I := 0 to FCategories.Count - 1 do
    Inc(N, FCategories[I].Workouts.Count);
  WritelnLog('WorkoutLib', 'Загружено: %d тренировок, %d категорий',
    [N, FCategories.Count]);
end;

procedure TWorkoutLibrary.Refresh;
begin
  if FRootUrl = '' then
  begin
    WritelnLog('WorkoutLib', 'Refresh: RootUrl ещё не задан, пропускаю');
    Exit;
  end;
  Scan(FRootUrl);
end;

function TWorkoutLibrary.FindCategory(
  const AName: String): TWorkoutCategory;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to FCategories.Count - 1 do
    if SameText(FCategories[I].Name, AName) then
      Exit(FCategories[I]);
end;

end.

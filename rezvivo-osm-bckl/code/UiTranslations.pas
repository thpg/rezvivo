unit UiTranslations;
{$mode objfpc}{$H+}{$codepage UTF8}

interface

uses Classes, SysUtils;

function UiText(const Source: String): String;
function UiLanguage: String;
procedure SetUiLanguage(const Language, CatalogDirectory: String);
procedure InitializeEditorTranslations;
{ Bind only application-owned text, never user input, filenames or model names.
  Bindings die with their target and refresh only on an actual language change. }
procedure BindUiText(Target: TComponent; const Source: String;
  const PropName: String = 'Caption');
procedure LocalizeDesignedUi(Root: TComponent);
function BoundUiSource(Target: TComponent; const PropName: String = 'Caption'): String;
procedure ObserveUiLanguage(Owner: TComponent; Callback: TNotifyEvent);

implementation

uses AppRuntimePaths, fpjson, jsonparser, fgl, SyncObjs, TypInfo;

type
  TCatalog = specialize TFPGMap<String, String>;
  TTextBinding = class(TComponent)
  private
    FTarget: TComponent;
    FSource, FProperty, FLast: String;
  public
    destructor Destroy; override;
    procedure Refresh;
  end;
  TLanguageObserver = class(TComponent)
  public
    Callback: TNotifyEvent;
    destructor Destroy; override;
  end;

var
  Catalog: TCatalog;
  CatalogLock: TCriticalSection;
  LanguageCode: String = 'en';
  Bindings: TList;
  Observers: TList;

function UiLanguage: String;
begin
  CatalogLock.Acquire;
  try Result := LanguageCode; finally CatalogLock.Release; end;
end;

function UiText(const Source: String): String;
var I: Integer;
begin
  CatalogLock.Acquire;
  try
    I := Catalog.IndexOf(Source);
    if (I >= 0) and (Catalog.Data[I] <> '') then Result := Catalog.Data[I]
    else Result := Source;
  finally CatalogLock.Release; end;
end;

procedure SetUiLanguage(const Language, CatalogDirectory: String);
var Next, Old: TCatalog; Data: TJSONData; Obj: TJSONObject;
    Stream: TFileStream; I: Integer; FileName: String; Snapshot: TList;
begin
  Next := TCatalog.Create;
  Next.Sorted := True;
  try
    FileName := IncludeTrailingPathDelimiter(CatalogDirectory) + Language + '.json';
    if (Language <> 'en') and FileExists(FileName) then
    begin
      Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
      try Data := GetJSON(Stream); finally Stream.Free; end;
      try
        if not (Data is TJSONObject) then
          raise Exception.Create('Translation catalog must be a JSON object: ' + FileName);
        Obj := TJSONObject(Data);
        for I := 0 to Obj.Count - 1 do
          if Obj.Items[I].JSONType = jtString then
            Next.AddOrSetData(Obj.Names[I], Obj.Items[I].AsString);
      finally Data.Free; end;
    end;
    CatalogLock.Acquire;
    try
      Old := Catalog;
      Catalog := Next;
      Next := nil;
      LanguageCode := Language;
      Old.Free;
    finally CatalogLock.Release; end;
  finally Next.Free; end;
  { UI language changes are made on the main thread. Worker lookups above
    see either the complete old catalog or the complete new catalog. }
  for I := 0 to Bindings.Count - 1 do TTextBinding(Bindings[I]).Refresh;
  Snapshot := TList.Create;
  try
    Snapshot.Assign(Observers);
    for I := 0 to Snapshot.Count - 1 do
      if Observers.IndexOf(Snapshot[I]) >= 0 then
        with TLanguageObserver(Snapshot[I]) do Callback(Owner);
  finally Snapshot.Free; end;
end;

destructor TLanguageObserver.Destroy;
begin
  if Observers <> nil then Observers.Remove(Self);
  inherited;
end;

procedure ObserveUiLanguage(Owner: TComponent; Callback: TNotifyEvent);
var Observer: TLanguageObserver;
begin
  Observer := TLanguageObserver.Create(Owner);
  Observer.Callback := Callback;
  Observers.Add(Observer);
end;

destructor TTextBinding.Destroy;
begin
  if Bindings <> nil then Bindings.Remove(Self);
  inherited;
end;

procedure TTextBinding.Refresh;
var Current: String;
begin
  Current := GetStrProp(FTarget, FProperty);
  { A status may have been replaced since it was bound. Do not restore
    stale text over a newer status, user selection or live measurement. }
  if Current <> FLast then Exit;
  FLast := UiText(FSource);
  SetStrProp(FTarget, FProperty, FLast);
end;

procedure BindUiText(Target: TComponent; const Source, PropName: String);
var I: Integer; B: TTextBinding; Original: String;
begin
  if (Target = nil) or (GetPropInfo(Target, PropName) = nil) then Exit;
  B := nil;
  for I := 0 to Target.ComponentCount - 1 do
    if (Target.Components[I] is TTextBinding) and
      (TTextBinding(Target.Components[I]).FProperty = PropName) then
    begin B := TTextBinding(Target.Components[I]); Break; end;
  if B = nil then
  begin
    B := TTextBinding.Create(Target);
    B.FTarget := Target;
    B.FProperty := PropName;
    Bindings.Add(B);
  end;
  if (B.FSource = Source) and (GetStrProp(Target, PropName) = B.FLast) then Exit;
  Original := Source;
  { Existing UI factories can receive an already translated T(...) caption.
    Recover its source only at this explicit application-text boundary. }
  CatalogLock.Acquire;
  try
    if Catalog.IndexOf(Source) < 0 then
      for I := 0 to Catalog.Count - 1 do
        if Catalog.Data[I] = Source then
        begin Original := Catalog.Keys[I]; Break; end;
  finally CatalogLock.Release; end;
  B.FSource := Original;
  B.FLast := UiText(Original);
  SetStrProp(Target, PropName, B.FLast);
end;

function BoundUiSource(Target: TComponent; const PropName: String): String;
var I: Integer; B: TTextBinding;
begin
  Result := '';
  if (Target = nil) or (GetPropInfo(Target, PropName) = nil) then Exit;
  Result := GetStrProp(Target, PropName);
  for I := 0 to Target.ComponentCount - 1 do
    if Target.Components[I] is TTextBinding then
    begin
      B := TTextBinding(Target.Components[I]);
      if (B.FProperty = PropName) and (B.FLast = Result) then Exit(B.FSource);
    end;
end;

procedure LocalizeDesignedUi(Root: TComponent);
const Properties: array[0..4] of String = ('Caption', 'Hint', 'Placeholder', 'Tooltip', 'SimpleText');
var I, J, N: Integer; S: String;
begin
  if Root = nil then Exit;
  N := Root.ComponentCount;
  for I := 0 to N - 1 do
    if not (Root.Components[I] is TTextBinding) then
      LocalizeDesignedUi(Root.Components[I]);
  for J := Low(Properties) to High(Properties) do
    if GetPropInfo(Root, Properties[J]) <> nil then
    begin
      S := GetStrProp(Root, Properties[J]);
      if S <> '' then BindUiText(Root, S, Properties[J]);
    end;
end;

procedure InitializeEditorTranslations;
var Dir, Lang, SettingsPath: String; I: Integer; Data: TJSONData;
    Stream: TFileStream; UI: TJSONData;
begin
  Dir := IncludeTrailingPathDelimiter(AppDirectory) + 'data/translations';
  if not DirectoryExists(Dir) then
    Dir := ExpandFileName(AppDirectory + '../rezvivo-osm-bckl/data/translations');
  Lang := 'en';
  SettingsPath := IncludeTrailingPathDelimiter(GetEnvironmentVariable('LOCALAPPDATA')) +
    'third_person_navigation/settings.json';
  if FileExists(SettingsPath) then
  try
    Stream := TFileStream.Create(SettingsPath, fmOpenRead or fmShareDenyNone);
    try Data := GetJSON(Stream); finally Stream.Free; end;
    try
      UI := Data.FindPath('ui.language');
      if (UI <> nil) and (UI.AsString <> '') then Lang := UI.AsString;
    finally Data.Free; end;
  except { A corrupt game preference must not prevent an editor from opening. }
  end;
  if GetEnvironmentVariable('REZVIVO_LANGUAGE') <> '' then
    Lang := GetEnvironmentVariable('REZVIVO_LANGUAGE');
  for I := 1 to AppParamCount do
    if Copy(AppParamStr(I), 1, 11) = '--language=' then Lang := Copy(AppParamStr(I), 12, MaxInt);
  if (Pos('/', Lang) > 0) or (Pos('\', Lang) > 0) or (Pos('..', Lang) > 0) then Lang := 'en';
  SetUiLanguage(Lang, Dir);
end;

initialization
  CatalogLock := TCriticalSection.Create;
  Catalog := TCatalog.Create;
  Catalog.Sorted := True;
  Bindings := TList.Create;
  Observers := TList.Create;
finalization
  while Observers.Count > 0 do TObject(Observers[Observers.Count - 1]).Free;
  FreeAndNil(Observers);
  while Bindings.Count > 0 do TObject(Bindings[Bindings.Count - 1]).Free;
  FreeAndNil(Bindings);
  Catalog.Free;
  CatalogLock.Free;
end.

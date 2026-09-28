{ GameLocalization — единая точка работы с языком игрового UI.

  Связывает три источника предпочтения языка в один эффективный язык:

    1. AppSettings.Language  — локальный явный выбор пользователя в игре
                                (из ViewProfile.LanguagePicker). Высший
                                приоритет. Хранится в settings.json.
                                ПУСТАЯ строка = «не задано в игре».

    2. VeloSite profile.Locale — язык, заданный пользователем на сайте
                                  VeloSite. Используется только если в
                                  игре язык не выбран явно (п.1 пуст).

    3. DefaultLanguage = 'en' — fallback, когда ни локально, ни в
                                 профиле не задан или нет соединения.

  Применяется через CGE-механизмы CastleLocalizationGetText:
    • TranslateAllDesigns(MoUrl)        — для всех .castle-user-interface
    • CastleTranslateResourceStrings(MoUrl) — для resourcestring'ов

  MO-файлы ожидаются в data/translations/ui_<lang>.mo и game_<lang>.mo.
  Если для какого-то языка MO-файла нет — UI остаётся на исходном тексте
  из дизайна (английском).

  ВАЖНОЕ ПРАВИЛО ПОЛИТИКИ:
    Выбор языка в игровом UI меняет ТОЛЬКО локальную настройку
    (AppSettings.SetLanguage). Он НЕ отправляется на сайт. Если игрок
    хочет изменить «свой» язык на сайте — он делает это через сайт.
    Это позволяет, например, использовать игру на английском,
    оставаясь на сайте на русском (или наоборот).

  Threading: ApplyEffectiveLanguage вызывается только из главного
  потока (как и весь CGE UI). VeloSite-обновление профиля приходит
  с фонового потока через ApplicationProperties.OnUpdate, поэтому
  юнит экспортирует процедуру для маршалинга в главный поток. }
unit GameLocalization;

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

const
  { Дефолтный язык, если не задан явно нигде. По требованию проекта — 'en'. }
  DefaultLanguage = 'en';

{ Поддерживаемые языки игры. Должны соответствовать языкам сайта VeloSite
  (см. velosite/locales/*.json). Если для конкретного языка нет MO-файла,
  он отображается всё равно в селекторе — UI просто останется на исходном
  английском (это нормальный fallback CGE). }
type
  TSupportedLanguage = record
    Code:        String;     { BCP-47: 'en', 'ru', 'ja', 'zh-Hans', ... }
    NativeName:  String;     { 'English', 'Русский', '日本語' — для UI-селектора }
  end;

const
  SupportedLanguages: array[0..11] of TSupportedLanguage = (
    (Code: 'en';      NativeName: 'English'),
    (Code: 'ru';      NativeName: 'Русский'),
    (Code: 'de';      NativeName: 'Deutsch'),
    (Code: 'fr';      NativeName: 'Français'),
    (Code: 'es';      NativeName: 'Español'),
    (Code: 'it';      NativeName: 'Italiano'),
    (Code: 'pt';      NativeName: 'Português'),
    (Code: 'ja';      NativeName: '日本語'),
    (Code: 'ko';      NativeName: '한국어'),
    (Code: 'zh-Hans'; NativeName: '简体中文'),
    (Code: 'zh-Hant'; NativeName: '繁體中文'),
    (Code: 'ar';      NativeName: 'العربية')
  );

{ Вычислить эффективный язык по описанной выше политике. Никогда не
  возвращает пустую строку. }
function EffectiveLanguage: String;

{ Применить эффективный язык к UI: загрузить MO-файлы и переключить
  все designs + resourcestring'и. Если для языка нет файлов перевода —
  ничего страшного: TranslateAllDesigns с пустой строкой просто отключит
  предыдущую активную локаль, оставив дизайн в исходном (английском)
  виде. Безопасно вызывать многократно. }
procedure ApplyEffectiveLanguage;

{ Удобная обёртка для GameViewProfile: запомнить выбор пользователя и
  немедленно применить. }
procedure SetUserLanguage(const ALang: String);

{ True, если код есть в SupportedLanguages. Проверка регистра-зависимая. }
function IsSupportedLanguage(const ACode: String): Boolean;

{ Текущий применённый язык (то, что вернул EffectiveLanguage при последнем
  ApplyEffectiveLanguage). Используется UI, чтобы подсветить выбранный
  пункт в селекторе. До первого Apply — пустая строка. }
function CurrentAppliedLanguage: String;

{ Подключить фоновое отслеживание прихода профиля. Вызывается один раз
  на старте приложения (после ApplicationInitialize) — подписывается на
  ApplicationProperties.OnUpdate и каждые ~секунду проверяет, не изменился
  ли кэш профиля VeloSite. Если да и эффективный язык отличается от
  применённого — переключает UI. Это устраняет необходимость править
  VeloSiteAPI ради OnProfileLoaded callback'а. }
procedure InstallProfileWatcher;

{ ── Translation lookup ────────────────────────────────────────────────

  T(EnglishText) — простой helper для перевода UI-литералов в Pascal-коде.
  Возвращает локализованную строку для текущего эффективного языка, или
  EnglishText без изменения, если перевода нет (или текущий язык = 'en').

  Пример:
      LabelTitle.Caption := T('Profile');
      ButtonSave.Caption := T('Save');

  Каталоги: data/translations/<lang>.json — flat map [en_text -> native_text].
  Подгружаются лениво при первом запросе нужного языка, кэшируются в памяти.
  Не зависит от GetText/msgfmt — простой JSON. }
function T(const EnglishText: String): String;

{ Вызывается из ApplyEffectiveLanguage — сбрасывает кэш активного каталога,
  чтобы T() в следующий раз перечитал нужный JSON под новый язык. }
procedure ReloadTranslations;

implementation

uses
  SysUtils, Classes, UiTranslations,
  fpjson, jsonparser,
  CastleLocalizationGetText, CastleURIUtils, CastleApplicationProperties,
  CastleDownload,
  AppSettings, VeloSiteAPI, DebugLog;

type
  { Wrapper-объект для подписки на ApplicationProperties.OnUpdate
    (требуется TNotifyEvent — method-of-object). Хранит timestamp
    последнего полла, чтобы не дёргать EffectiveLanguage 60 раз/сек. }
  TLocalizationWatcher = class
  private
    FLastPoll:           TDateTime;
    FProfileWasCached:   Boolean;
    FLastProfileLocale:  String;
    procedure Tick(Sender: TObject);
  public
    constructor Create;
  end;

var
  GAppliedLanguage: String = '';
  GWatcher: TLocalizationWatcher = nil;
  { Кэш текущего активного каталога переводов. Ключ — английский текст,
    значение — локализованный. Заполняется лениво в T() при первом
    обращении после смены языка. }

function IsSupportedLanguage(const ACode: String): Boolean;
var
  I: Integer;
begin
  for I := Low(SupportedLanguages) to High(SupportedLanguages) do
    if SupportedLanguages[I].Code = ACode then
      Exit(True);
  Result := False;
end;

function CurrentAppliedLanguage: String;
begin
  Result := GAppliedLanguage;
end;

function EffectiveLanguage: String;
var
  Local, FromProfile: String;
begin
  { 1. Local override }
  Local := Settings.GetLanguage;
  if (Local <> '') and IsSupportedLanguage(Local) then
    Exit(Local);

  { 2. Profile (только если игрок залогинен и есть кэш) }
  if VeloSite.HasCachedProfile then
  begin
    FromProfile := VeloSite.CachedProfile.Locale;
    if (FromProfile <> '') and IsSupportedLanguage(FromProfile) then
      Exit(FromProfile);
  end;

  { 3. Default }
  Result := DefaultLanguage;
end;

procedure ApplyEffectiveLanguage;
var
  Lang: String;
  UiMo, GameMo: String;
  UiExists, GameExists: Boolean;
begin
  Lang := EffectiveLanguage;

  { Если язык не сменился с прошлого Apply — ничего не делать.
    Это важно при частых вызовах из ApplicationProperties.OnUpdate. }
  if Lang = GAppliedLanguage then Exit;

  Logger.Info('[Localization] Applying language: ' + Lang
    + ' (was: ' + GAppliedLanguage + ')');

  { Английский — это исходный язык в .castle-user-interface файлах.
    Передача '' в TranslateAllDesigns отключает текущую активную локаль,
    возвращая дизайны к исходному виду — то, что нам нужно для 'en'. }
  if Lang = DefaultLanguage then
  begin
    TranslateAllDesigns('');
    GAppliedLanguage := Lang;
    ReloadTranslations;
    Exit;
  end;

  { Для остальных языков ищем MO-файлы. Имена согласованы с генерацией:
      data/translations/ui_<lang>.mo
      data/translations/game_<lang>.mo                                  }
  UiMo   := 'castle-data:/translations/ui_'   + Lang + '.mo';
  GameMo := 'castle-data:/translations/game_' + Lang + '.mo';

  UiExists   := URIFileExists(UiMo);
  GameExists := URIFileExists(GameMo);

  if UiExists then
  begin
    try
      TranslateAllDesigns(UiMo);
    except
      on E: Exception do
      begin
        Logger.Warning('[Localization] TranslateAllDesigns failed for '
          + UiMo + ': ' + E.Message);
        TranslateAllDesigns('');     { откат к исходному }
      end;
    end;
  end
  else
  begin
    Logger.Info('[Localization] UI MO not found: ' + UiMo
      + ' - falling back to English');
    TranslateAllDesigns('');
  end;

  if GameExists then
  begin
    try
      CastleTranslateResourceStrings(GameMo);
    except
      on E: Exception do
        Logger.Warning('[Localization] CastleTranslateResourceStrings'
          + ' failed for ' + GameMo + ': ' + E.Message);
    end;
  end
  else
    Logger.Info('[Localization] Game MO not found: ' + GameMo
      + ' - resourcestrings stay in English');

  GAppliedLanguage := Lang;
  ReloadTranslations;
end;

procedure SetUserLanguage(const ALang: String);
begin
  { Пустая строка очищает локальный override (вернёт «авто из профиля»).
    Любое непустое значение должно быть из SupportedLanguages — иначе
    игнорируем (защита от мусора в settings.json от старой версии). }
  if (ALang <> '') and (not IsSupportedLanguage(ALang)) then
  begin
    Logger.Warning('[Localization] Unsupported language code: ' + ALang
      + ' - ignored');
    Exit;
  end;
  Settings.SetLanguage(ALang);
  ApplyEffectiveLanguage;
end;

{ ── Profile watcher ──────────────────────────────────────────────── }

constructor TLocalizationWatcher.Create;
begin
  inherited;
  FLastPoll := 0;
  FProfileWasCached := False;
  FLastProfileLocale := '';
end;

procedure TLocalizationWatcher.Tick(Sender: TObject);
const
  PollIntervalSec = 1.0;
var
  HasCache: Boolean;
  ProfileLocale: String;
  CacheChanged: Boolean;
  NowT: TDateTime;
begin
  { Throttle: проверяем не чаще 1 раза в секунду — наша задача дешёвая,
    но не нужна каждый кадр. SecsPerDay = 86400, поэтому
    1s == 1/86400 в TDateTime. }
  NowT := Now;
  if (FLastPoll <> 0) and ((NowT - FLastPoll) * 86400 < PollIntervalSec) then
    Exit;
  FLastPoll := NowT;

  HasCache := VeloSite.HasCachedProfile;
  if HasCache then
    ProfileLocale := VeloSite.CachedProfile.Locale
  else
    ProfileLocale := '';

  { Перевычисляем эффективный язык только если что-то значимое
    изменилось — иначе тратим CPU зря. }
  CacheChanged := (HasCache <> FProfileWasCached)
               or (ProfileLocale <> FLastProfileLocale);
  if (not CacheChanged) and (EffectiveLanguage = GAppliedLanguage) then Exit;

  FProfileWasCached := HasCache;
  FLastProfileLocale := ProfileLocale;
  ApplyEffectiveLanguage;     { сам сравнит с GAppliedLanguage и no-op'нет если совпало }
end;

procedure InstallProfileWatcher;
begin
  if Assigned(GWatcher) then Exit;     { idempotent — повторные вызовы безопасны }
  GWatcher := TLocalizationWatcher.Create;
  ApplicationProperties.OnUpdate.Add(@GWatcher.Tick);
  Logger.Info('[Localization] Profile watcher installed');
end;

{ ── Translation catalog ──────────────────────────────────────────────── }

function T(const EnglishText: String): String;
begin
  Result := UiText(EnglishText);
end;

procedure ReloadTranslations;
begin
  try
    SetUiLanguage(GAppliedLanguage,
      URIToFilenameSafe('castle-data:/translations/'));
  except
    on E: Exception do
    begin
      Logger.Warning('[Localization] ' + E.Message);
      SetUiLanguage(DefaultLanguage, '');
    end;
  end;
end;

initialization

finalization
  if Assigned(GWatcher) then
  begin
    { ApplicationProperties уничтожается раньше, явное Remove не нужно. }
    FreeAndNil(GWatcher);
  end;

end.

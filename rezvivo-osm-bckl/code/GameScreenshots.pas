unit GameScreenshots;
{$mode objfpc}{$H+}{$codepage UTF8}

interface

uses Classes, CastleUIControls;

{ Window-owned shortcut and non-modal feedback, shared by menus and rides. }
function CreateGameScreenshotControl(AOwner: TComponent): TCastleUserInterface;

implementation

uses SysUtils, CastleKeysMouse, CastleNotifications, CastleURIUtils,
  AppRuntimePaths, UiTranslations, DebugLog;

type
  TGameScreenshotControl = class(TCastleUserInterface)
  private
    FSaving: Boolean;
    FNotification: TCastleNotifications;
    procedure SaveScreenshot;
  public
    constructor Create(AOwner: TComponent); override;
    function Press(const Event: TInputPressRelease): Boolean; override;
  end;

constructor TGameScreenshotControl.Create(AOwner: TComponent);
begin
  inherited;
  Name := 'ScreenshotShortcut';
  FullSize := True;
  KeepInFront := True;
  FNotification := TCastleNotifications.Create(Self);
  FNotification.Name := 'ScreenshotNotification';
  FNotification.CapturesEvents := False;
  FNotification.Anchor(hpMiddle);
  FNotification.Anchor(vpTop, -120);
  FNotification.TextAlignment := hpMiddle;
  FNotification.FontSize := 18;
  FNotification.MaxMessages := 3;
  FNotification.Timeout := 4;
  InsertFront(FNotification);
end;

procedure TGameScreenshotControl.SaveScreenshot;
var
  Directory, BaseName, FileName: String;
  Suffix: Integer;
begin
  if FSaving or (Container = nil) then Exit;
  FSaving := True;
  try
    { Hide the previous notification before CGE redraws the captured frame. }
    FNotification.Clear;
    try
      Directory := IncludeTrailingPathDelimiter(AppDirectory + 'screenshots');
      if not ForceDirectories(Directory) then
        raise Exception.Create(Directory);
      BaseName := Directory + 'REZVIVO_' + FormatDateTime('yyyy-mm-dd_hh-nn-ss-zzz', Now);
      FileName := BaseName + '.png';
      Suffix := 0;
      while FileExists(FileName) do
      begin
        Inc(Suffix);
        FileName := BaseName + '_' + IntToStr(Suffix) + '.png';
      end;
      { Same CGE capture as MCP: redraw with the current GL context, then
        read the complete back buffer, including the current interface. }
      Container.SaveScreen(FilenameToUriSafe(FileName));
      FNotification.Timeout := 4;
      FNotification.Show(Format(UiText('Screenshot saved: %s'), [FileName]));
      Logger.Info('[Screenshot] ' + FileName);
    except
      on E: Exception do
      begin
        FNotification.Timeout := 8;
        FNotification.Show(Format(UiText('Could not save screenshot: %s'), [E.Message]));
        Logger.Warning('[Screenshot] ' + E.Message);
      end;
    end;
  finally
    FSaving := False;
  end;
end;

function TGameScreenshotControl.Press(const Event: TInputPressRelease): Boolean;
begin
  if Event.IsKey(keyF5, []) then
  begin
    { Holding F5 must not fill the disk with repeated captures. }
    if not Event.KeyRepeated then SaveScreenshot;
    Exit(True);
  end;
  Result := inherited Press(Event);
end;

function CreateGameScreenshotControl(AOwner: TComponent): TCastleUserInterface;
begin
  Result := TGameScreenshotControl.Create(AOwner);
end;

end.

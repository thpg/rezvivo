unit GameCacheUI;

{$mode objfpc}{$H+}

interface

uses Classes, CastleUIControls, CastleControls, GameMenuTheme, GameCacheMaintenance;

type
  TDiskCachePanel = class(TCastleUserInterface)
  private
    FTitle, FSize, FHint, FStatus: TCastleLabel;
    FClearButton: TMenuButton;
    FRow: TMenuFlow;
    FJob: TDiskCacheJob;
    FSnapshot: TDiskCacheState;
    FActive, FClearPending, FPausedGlobe, FHaveSize, FWasClear: Boolean;
    FPoll: Single;
    procedure ClickClear(Sender: TObject);
    procedure StartJob(Clear: Boolean);
    procedure ResumeGlobe;
    procedure Refresh;
    procedure Arrange;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SetActive(Value: Boolean);
    procedure Update(const SecondsPassed: Single; var HandleInput: Boolean); override;
  end;

implementation

uses Math, SysUtils, UiTranslations, Osm3dStudioSettings, GameViewMenu, GameViewPlay
  {$ifdef ANDROID}, CastleFilesUtils, CastleURIUtils{$endif};

function CacheSizeText(Bytes: Int64): string;
const Units: array[0..4] of string = ('B', 'KiB', 'MiB', 'GiB', 'TiB');
var Value: Double; Index: Integer;
begin
  Value := Bytes; Index := 0;
  while (Value >= 1024) and (Index < High(Units)) do
  begin Value := Value / 1024; Inc(Index) end;
  if Index = 0 then Result := IntToStr(Bytes)
  else Result := FormatFloat('0.0', Value);
  Result := Result + ' ' + UiText(Units[Index]);
end;

function RideUsesCache: Boolean;
begin
  Result := (ViewPlay <> nil) and ViewPlay.SessionAlive;
end;

constructor TDiskCachePanel.Create(AOwner: TComponent);
begin
  inherited;
  Name := 'DiskCacheSettings';
  Width := 800;
  FTitle := TMenuLabel.Create(Self);
  BindUiText(FTitle, 'Map cache'); FTitle.FontSize := 26;
  FTitle.Anchor(hpLeft); FTitle.Anchor(vpTop); InsertFront(FTitle);
  FRow := TMenuFlow.Create(Self); FRow.Spacing := 20;
  FRow.WidthFraction := 0; InsertFront(FRow);
  FSize := TMenuLabel.Create(Self); FSize.Name := 'DiskCacheSize'; FSize.FontSize := 20;
  FRow.InsertFront(FSize);
  FClearButton := TMenuButton.Create(Self);
  FClearButton.Name := 'ClearMapCache'; FClearButton.AutoIcon := False;
  BindUiText(FClearButton, 'Clear cache'); FClearButton.FontSize := 17;
  FClearButton.OnClick := @ClickClear; FRow.InsertFront(FClearButton);
  FHint := TMenuLabel.Create(Self); FHint.Color := MenuMuted; FHint.FontSize := 14;
  BindUiText(FHint, 'Maps, elevation data and generated tiles. Cleared data is downloaded or rebuilt when needed.');
  InsertFront(FHint);
  FStatus := TMenuLabel.Create(Self); FStatus.Name := 'DiskCacheStatus';
  FStatus.FontSize := 14; FStatus.Color := MenuMuted; InsertFront(FStatus);
  Refresh; Arrange;
end;

destructor TDiskCachePanel.Destroy;
begin
  SetActive(False);
  FJob.Free;
  inherited;
end;

procedure TDiskCachePanel.ResumeGlobe;
begin
  if FPausedGlobe and (ViewMenu <> nil) and (ViewMenu.Globe <> nil) then
    ViewMenu.Globe.PauseTileLoading(False);
  FPausedGlobe := False;
end;

procedure TDiskCachePanel.StartJob(Clear: Boolean);
begin
  { Only a finished worker is freed here; no disk/network waits in the UI. }
  FreeAndNil(FJob);
  FJob := TDiskCacheJob.Create(DefaultCacheRoot, Clear,
    {$ifdef ANDROID}URIToFilenameSafe(ApplicationConfig('shader-cache')));
    {$else}
    IncludeTrailingPathDelimiter(GetAppConfigDir(False)) + 'shader-cache');
    {$endif}
  FWasClear := Clear; FHaveSize := False;
  FSnapshot := Default(TDiskCacheState);
  FJob.Start;
end;

procedure TDiskCachePanel.SetActive(Value: Boolean);
begin
  if FActive = Value then Exit;
  FActive := Value;
  if Value then
  begin
    FPoll := 0;
    if (FJob = nil) or FJob.Snapshot.Done then StartJob(False);
  end else
  begin
    FClearPending := False;
    if FJob <> nil then FJob.Terminate;
    ResumeGlobe;
  end;
end;

procedure TDiskCachePanel.ClickClear(Sender: TObject);
begin
  if not FActive or RideUsesCache or (FJob <> nil) or not FHaveSize then Exit;
  FClearPending := True;
  if (ViewMenu <> nil) and (ViewMenu.Globe <> nil) and
     not ViewMenu.Globe.TileLoadingPaused then
  begin
    FPausedGlobe := True;
    ViewMenu.Globe.PauseTileLoading(True);
  end;
  Refresh;
end;

procedure TDiskCachePanel.Refresh;
var Busy: Boolean;
begin
  Busy := (FJob <> nil) or FClearPending;
  if not Busy and (FSnapshot.Error <> '') then
    FSize.Caption := UiText('Size unavailable')
  else if FHaveSize then
    FSize.Caption := Format(UiText('On disk: %s'), [CacheSizeText(FSnapshot.Bytes)])
  else if FClearPending or (Busy and FWasClear) then
    FSize.Caption := UiText('Clearing cache...')
  else FSize.Caption := UiText('Calculating size...');
  FClearButton.Enabled := not Busy and not RideUsesCache and FHaveSize and
    (FSnapshot.Bytes > 0);
  if RideUsesCache then FStatus.Caption := UiText('Finish the ride to clear the cache.')
  else if FClearPending then FStatus.Caption := UiText('Stopping background map downloads...')
  else if (FJob <> nil) and FWasClear then
    FStatus.Caption := Format(UiText('Freed: %s'), [CacheSizeText(FSnapshot.DeletedBytes)])
  else if not Busy and (FSnapshot.Error <> '') then
    FStatus.Caption := UiText('Could not access the cache directory.')
  else if not Busy and (FSnapshot.Issues > 0) then
  begin
    if FWasClear then FStatus.Caption := UiText('Some cache files could not be cleared. Try again after downloads finish.')
    else FStatus.Caption := UiText('Some files are unavailable. The size includes accessible files only.');
  end
  else if FHaveSize and FWasClear then
    FStatus.Caption := Format(UiText('Freed: %s'), [CacheSizeText(FSnapshot.DeletedBytes)])
  else FStatus.Caption := '';
end;

procedure TDiskCachePanel.Arrange;
var W, Y: Single;
begin
  W := Max(200, EffectiveWidth);
  FRow.Width := W; FRow.Anchor(hpLeft); FRow.Anchor(vpTop, -42); FRow.Arrange;
  Y := 42 + FRow.EffectiveHeight + 10;
  FHint.MaxWidth := W; FHint.Anchor(hpLeft); FHint.Anchor(vpTop, -Y);
  Y := Y + FHint.EffectiveHeight + 8;
  FStatus.MaxWidth := W; FStatus.Anchor(hpLeft); FStatus.Anchor(vpTop, -Y);
  Height := Y + FStatus.EffectiveHeight;
end;

procedure TDiskCachePanel.Update(const SecondsPassed: Single; var HandleInput: Boolean);
begin
  inherited;
  if not FActive then Exit;
  FPoll := FPoll - SecondsPassed;
  if FPoll <= 0 then
  begin
    FPoll := 0.2;
    if FJob <> nil then
    begin
      FSnapshot := FJob.Snapshot;
      if FSnapshot.Done then
      begin
        FreeAndNil(FJob);
        if FSnapshot.Cancelled then StartJob(False)
        else FHaveSize := FSnapshot.Error = '';
        ResumeGlobe;
      end;
    end;
    if FClearPending then
    begin
      if RideUsesCache then
      begin FClearPending := False; ResumeGlobe end
      else if (ViewMenu = nil) or (ViewMenu.Globe = nil) or ViewMenu.Globe.TileLoadingIdle then
      begin FClearPending := False; StartJob(True) end;
    end;
    Refresh;
  end;
  Arrange;
end;

end.

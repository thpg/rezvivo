unit Osm3dStudioEndpointPanel;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses UiTranslations,
  Classes,
  SysUtils,
  Controls,
  ExtCtrls,
  StdCtrls,
  Graphics,
  Osm3dStudioUtils
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

type
  TEndpointRole = (erOverpass, erTerrarium, erOther);

  TEndpointIndicator = (eiIdle, eiActive, eiOk, eiFail, eiCache);

  TEndpointStatusPanel = class(TPanel)
  private
    FHost:        string;
    FRole:        TEndpointRole;

    FAttempts:    Integer;
    FOkCount:     Integer;
    FFailCount:   Integer;
    FCacheHits:   Integer;
    FBytesTotal:  Int64;

    FIndicator:   TShape;
    FLblHost:     TLabel;
    FLblCounters: TLabel;
    FLblCurrent:  TLabel;
    FLblLast:     TLabel;
    FLblError:    TLabel;

    procedure BuildLayout;
    procedure SetIndicator(AKind: TEndpointIndicator);
    procedure RefreshCounters;
  public
    constructor Create(AOwner: TComponent; const AHost: string;
                       ARole: TEndpointRole); reintroduce;

    { Apply* are called from the main thread only. }

    procedure ApplyRequestStarted(const URLShort: string);
    procedure ApplyProgress(BytesReceived, BytesTotal: Int64;
                            ElapsedMs: Int64);

    { Use ApplyHttpSuccess/Error for plain HTTP. For Overpass use
      ApplyOsmAttempt instead — it has correct per-attempt counters and
      both would double-count. }
    procedure ApplyHttpSuccess(StatusCode: Integer; BytesTotal: Int64;
                               ElapsedMs: Int64);
    procedure ApplyHttpError(const ErrMsg: string; ElapsedMs: Int64);

    procedure ApplyCacheHit(BytesTotal: Int64);

    procedure ApplyOsmAttempt(const Tile: string; TileIndex, TileTotal: Integer;
                              Success: Boolean; BytesTotal, ElapsedMs: Int64;
                              const ErrMsg: string);

    { Final outcome after possible retries on other mirrors. }
    procedure ApplyTileFinal(Success: Boolean);

    property Host: string         read FHost;
    property Role: TEndpointRole  read FRole;
    property Attempts: Integer    read FAttempts;
    property OkCount:  Integer    read FOkCount;
    property FailCount: Integer   read FFailCount;
  end;

implementation

constructor TEndpointStatusPanel.Create(AOwner: TComponent;
  const AHost: string; ARole: TEndpointRole);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1271);{$ENDIF}
  inherited Create(AOwner);
  FHost := AHost;
  FRole := ARole;
  FAttempts := 0; FOkCount := 0; FFailCount := 0; FCacheHits := 0;
  FBytesTotal := 0;

  Self.BevelOuter := bvNone;
  Self.BorderSpacing.Around := 2;
  Self.BorderStyle := bsSingle;
  Self.Color := clWindow;
  Self.Height := 70;
  Self.Align := alTop;
  BuildLayout;
  SetIndicator(eiIdle);
end;

procedure TEndpointStatusPanel.BuildLayout;
const
  IndSize  = 12;
  PadLeft  = 6;
  TextLeft = PadLeft + IndSize + 6;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(868);{$ENDIF}
  FIndicator := TShape.Create(Self);
  FIndicator.Parent := Self;
  FIndicator.Shape := stCircle;
  FIndicator.SetBounds(PadLeft, 6, IndSize, IndSize);
  FIndicator.Pen.Style := psClear;

  FLblHost := TLabel.Create(Self);
  FLblHost.Parent := Self;
  FLblHost.SetBounds(TextLeft, 4, 220, 16);
  FLblHost.Caption := FHost;
  FLblHost.Font.Style := [fsBold];

  FLblCounters := TLabel.Create(Self);
  FLblCounters.Parent := Self;
  FLblCounters.SetBounds(TextLeft, 4, 100, 16);
  FLblCounters.Anchors := [akTop, akRight];
  FLblCounters.AnchorSideRight.Control := Self;
  FLblCounters.AnchorSideRight.Side := asrBottom;
  FLblCounters.BorderSpacing.Right := 6;
  FLblCounters.Alignment := taRightJustify;
  FLblCounters.AutoSize := False;
  FLblCounters.Width := 180;
  FLblCounters.Caption := '';
  FLblCounters.Font.Color := clGrayText;

  FLblCurrent := TLabel.Create(Self);
  FLblCurrent.Parent := Self;
  FLblCurrent.SetBounds(TextLeft, 22, Self.Width - TextLeft - 4, 16);
  FLblCurrent.AutoSize := False;
  FLblCurrent.Anchors := [akLeft, akTop, akRight];
  FLblCurrent.Caption := UiText('— idle —');

  FLblLast := TLabel.Create(Self);
  FLblLast.Parent := Self;
  FLblLast.SetBounds(TextLeft, 40, 160, 16);
  FLblLast.AutoSize := False;
  FLblLast.Caption := '';

  FLblError := TLabel.Create(Self);
  FLblError.Parent := Self;
  FLblError.SetBounds(TextLeft + 165, 40, Self.Width - TextLeft - 165 - 4, 16);
  FLblError.AutoSize := False;
  FLblError.Anchors := [akLeft, akTop, akRight];
  FLblError.Font.Color := clMaroon;
  FLblError.Caption := '';
  FLblError.ShowHint := True;
end;

procedure TEndpointStatusPanel.SetIndicator(AKind: TEndpointIndicator);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(869);{$ENDIF}
  case AKind of
    eiIdle:   FIndicator.Brush.Color := clSilver;
    eiActive: FIndicator.Brush.Color := clBlue;
    eiOk:     FIndicator.Brush.Color := clGreen;
    eiFail:   FIndicator.Brush.Color := clRed;
    eiCache:  FIndicator.Brush.Color := clOlive;
  end;
end;

procedure TEndpointStatusPanel.RefreshCounters;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(870);{$ENDIF}
  FLblCounters.Caption := Format(UiText('att:%d  ok:%d  fail:%d  cache:%d'),
    [FAttempts, FOkCount, FFailCount, FCacheHits]);
end;

procedure TEndpointStatusPanel.ApplyRequestStarted(const URLShort: string);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(871);{$ENDIF}
  SetIndicator(eiActive);
  FLblCurrent.Caption := UTF8Decode('→ ' + URLShort);
end;

procedure TEndpointStatusPanel.ApplyProgress(BytesReceived, BytesTotal: Int64;
                                              ElapsedMs: Int64);
var
  KbPerSec: Double;
  Tail: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(872);{$ENDIF}
  if ElapsedMs > 0 then
    KbPerSec := (BytesReceived / 1024.0) / (ElapsedMs / 1000.0)
  else
    KbPerSec := 0;
  if BytesTotal > 0 then
    Tail := Format('%s / %s (%.0f%%) · %.0f KB/s',
      [FormatBytes(BytesReceived), FormatBytes(BytesTotal),
       (BytesReceived / BytesTotal) * 100.0, KbPerSec])
  else
    Tail := Format('%s · %.0f KB/s',
      [FormatBytes(BytesReceived), KbPerSec]);
  FLblCurrent.Caption := Tail;
end;

procedure TEndpointStatusPanel.ApplyHttpSuccess(StatusCode: Integer;
  BytesTotal: Int64; ElapsedMs: Int64);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(873);{$ENDIF}
  SetIndicator(eiOk);
  FBytesTotal := FBytesTotal + BytesTotal;
  FLblLast.Caption := Format(UiText('last: ✓ %d (%s, %d ms)'),
    [StatusCode, FormatBytes(BytesTotal), ElapsedMs]);
  FLblError.Caption := '';
  RefreshCounters;
end;

procedure TEndpointStatusPanel.ApplyHttpError(const ErrMsg: string;
  ElapsedMs: Int64);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(874);{$ENDIF}
  SetIndicator(eiFail);
  FLblLast.Caption := Format(UiText('last: ✗ (%d ms)'), [ElapsedMs]);
  FLblError.Caption := UiText('err: ') + ErrMsg;
  FLblError.Hint    := ErrMsg;
end;

procedure TEndpointStatusPanel.ApplyCacheHit(BytesTotal: Int64);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(875);{$ENDIF}
  SetIndicator(eiCache);
  Inc(FCacheHits);
  FLblLast.Caption := Format(UiText('last: ● cache (%s)'),
    [FormatBytes(BytesTotal)]);
  RefreshCounters;
end;

procedure TEndpointStatusPanel.ApplyOsmAttempt(const Tile: string;
  TileIndex, TileTotal: Integer; Success: Boolean;
  BytesTotal, ElapsedMs: Int64; const ErrMsg: string);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(876);{$ENDIF}
  Inc(FAttempts);
  if Success then
  begin
    SetIndicator(eiOk);
    FBytesTotal := FBytesTotal + BytesTotal;
    FLblCurrent.Caption := Format(UiText('tile %s · #%d/%d · %s · %d ms'),
      [Tile, TileIndex, TileTotal, FormatBytes(BytesTotal), ElapsedMs]);
    FLblLast.Caption := Format(UiText('last: ✓ %d ms'), [ElapsedMs]);
    FLblError.Caption := '';
  end
  else
  begin
    SetIndicator(eiFail);
    FLblCurrent.Caption := Format(UiText('tile %s · #%d/%d · FAIL · %d ms'),
      [Tile, TileIndex, TileTotal, ElapsedMs]);
    FLblLast.Caption := Format(UiText('last: ✗ %d ms'), [ElapsedMs]);
    FLblError.Caption := UiText('err: ') + ErrMsg;
    FLblError.Hint    := ErrMsg;
  end;
  RefreshCounters;
end;

procedure TEndpointStatusPanel.ApplyTileFinal(Success: Boolean);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(877);{$ENDIF}
  if Success then
    Inc(FOkCount)
  else
    Inc(FFailCount);
  RefreshCounters;
end;

end.

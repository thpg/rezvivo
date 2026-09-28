unit GameInputUI;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses Classes,CastleUIControls,CastleControls,CastleKeysMouse,GameMenuTheme,GameRideCommands;
type
  TInputPanel=class(TCastleUserInterface)
  private
    FTitle,FHint,FScaleTitle:TCastleLabel;
    FRows:array[TRideCommand]of TMenuFlow;
    FButtons:array[TRideCommand]of TMenuButton;
    FScaleRow:TMenuFlow;
    FScaleButtons:array[0..2]of TMenuButton;
    FReset:TMenuButton;
    FWaiting:Boolean;FCommand:TRideCommand;
    procedure Choose(Sender:TObject);
    procedure ChooseScale(Sender:TObject);
    procedure Reset(Sender:TObject);
    procedure Refresh;
  public
    constructor Create(AOwner:TComponent);override;
    function Press(const Event:TInputPressRelease):Boolean;override;
    procedure Update(const SecondsPassed:Single;var HandleInput:Boolean);override;
  end;
implementation
uses SysUtils,Math,UiTranslations,GameUserData;
constructor TInputPanel.Create(AOwner:TComponent);
var C:TRideCommand;L:TCastleLabel;I:Integer;
begin
  inherited;Name:='RideInputSettings';Width:=800;Height:=420;
  FTitle:=TMenuLabel.Create(Self);BindUiText(FTitle,'Controls and readability');FTitle.FontSize:=26;
  FTitle.Anchor(vpTop);InsertFront(FTitle);
  FHint:=TMenuLabel.Create(Self);FHint.FontSize:=15;FHint.Color:=MenuMuted;
  FHint.Anchor(vpTop,-38);InsertFront(FHint);
  for C:=Low(C)to High(C)do begin
    FRows[C]:=TMenuFlow.Create(Self);InsertFront(FRows[C]);
    L:=TMenuLabel.Create(Self);L.FontSize:=18;BindUiText(L,RideCommandTitles[C]);FRows[C].InsertFront(L);
    FButtons[C]:=TMenuButton.Create(Self);FButtons[C].AutoIcon:=False;
    FButtons[C].Name:='RideKey'+IntToStr(Ord(C));FButtons[C].Tag:=Ord(C);
    FButtons[C].MinWidth:=130;FButtons[C].MinHeight:=44;FButtons[C].OnClick:=@Choose;FRows[C].InsertFront(FButtons[C]);
  end;
  FScaleTitle:=TMenuLabel.Create(Self);BindUiText(FScaleTitle,'Interface size');FScaleTitle.FontSize:=18;InsertFront(FScaleTitle);
  FScaleRow:=TMenuFlow.Create(Self);InsertFront(FScaleRow);
  for I:=0 to 2 do begin
    FScaleButtons[I]:=TMenuButton.Create(Self);FScaleButtons[I].AutoIcon:=False;
    FScaleButtons[I].Caption:=IntToStr(100+I*25)+'%';FScaleButtons[I].Tag:=100+I*25;
    FScaleButtons[I].OnClick:=@ChooseScale;FScaleButtons[I].MinHeight:=44;FScaleRow.InsertFront(FScaleButtons[I]);
  end;
  FReset:=TMenuButton.Create(Self);BindUiText(FReset,'Reset shortcuts');FReset.OnClick:=@Reset;InsertFront(FReset);
  Refresh;
end;
procedure TInputPanel.Refresh;
var C:TRideCommand;I:Integer;
begin
  for C:=Low(C)to High(C)do FButtons[C].Caption:=KeyToStr(RideCommandKey(C));
  for I:=0 to 2 do SelectMenuButton(FScaleButtons[I],FScaleButtons[I].Tag=UserPreferences.Get('interface_scale',100));
  BindUiText(FHint,'Tab / arrows / Enter to choose. Click a shortcut to change it.');
end;
procedure TInputPanel.Choose(Sender:TObject);
begin
  FCommand:=TRideCommand(TComponent(Sender).Tag);FWaiting:=True;
  if Container<>nil then Container.ForceCaptureInput:=Self;
  BindUiText(FHint,'Press a key · Esc cancels');
end;
procedure TInputPanel.ChooseScale(Sender:TObject);
begin
  UserPreferences.Integers['interface_scale']:=TComponent(Sender).Tag;SaveUserPreferences;
  ApplyUserInterfaceScale(Container);Refresh;
end;
procedure TInputPanel.Reset(Sender:TObject);
begin ResetRideCommandKeys;Refresh;end;
function TInputPanel.Press(const Event:TInputPressRelease):Boolean;
begin
  if FWaiting and(Event.EventType=itKey)then begin
    if Event.IsKey(keyEscape)then begin FWaiting:=False;Refresh;end
    else if SetRideCommandKey(FCommand,Event.Key)then begin FWaiting:=False;Refresh;end
    else BindUiText(FHint,'Key is reserved or already used. Choose another.');
    if not FWaiting and(Container<>nil)and(Container.ForceCaptureInput=Self)then Container.ForceCaptureInput:=nil;
    Exit(True);
  end;
  Result:=inherited;
end;
procedure TInputPanel.Update(const SecondsPassed:Single;var HandleInput:Boolean);
var C:TRideCommand;W,Y:Single;
begin
  inherited;W:=Max(200,EffectiveWidth);FHint.MaxWidth:=W;Y:=38+FHint.EffectiveHeight+18;
  for C:=Low(C)to High(C)do begin
    FRows[C].Width:=W;FRows[C].Anchor(vpTop,-Y);FRows[C].Arrange;Y:=Y+FRows[C].Height+10;
  end;
  FScaleTitle.Anchor(vpTop,-Y);Y:=Y+32;FScaleRow.Width:=W;FScaleRow.Anchor(vpTop,-Y);FScaleRow.Arrange;
  Y:=Y+FScaleRow.Height+16;FReset.Anchor(vpTop,-Y);Height:=Y+FReset.Height+16;
end;
end.

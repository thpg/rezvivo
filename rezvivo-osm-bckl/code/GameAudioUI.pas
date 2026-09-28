unit GameAudioUI;
{$mode objfpc}{$H+}
interface
uses Classes,CastleUIControls,CastleControls,GameMenuTheme,GameAudioOptions;
type
  TAudioPanel=class(TCastleUserInterface)
  private
    FTitle,FHint:TCastleLabel;
    FLabels:array[TAudioOption]of TCastleLabel;
    FRows:array[TAudioOption]of TMenuFlow;
    FButtons:array[TAudioOption,0..4]of TMenuButton;
    FRevision:Cardinal;
    procedure Choose(Sender:TObject);
  public
    constructor Create(AOwner:TComponent);override;
    procedure Update(const SecondsPassed:Single;var HandleInput:Boolean);override;
  end;
implementation
uses SysUtils,Math,AppSettings,UiTranslations;
constructor TAudioPanel.Create(AOwner:TComponent);
var O:TAudioOption;I:Integer;B:TMenuButton;
begin
  inherited;Name:='AudioSettings';Width:=800;Height:=360;FRevision:=High(Cardinal);
  FTitle:=TMenuLabel.Create(Self);BindUiText(FTitle,'Sound');FTitle.FontSize:=26;
  FTitle.Anchor(hpLeft);FTitle.Anchor(vpTop);InsertFront(FTitle);
  FHint:=TMenuLabel.Create(Self);BindUiText(FHint,'Changes apply immediately. Set a channel to Off to mute it.');
  FHint.FontSize:=15;FHint.Color:=MenuMuted;FHint.Anchor(hpLeft);FHint.Anchor(vpTop,-36);InsertFront(FHint);
  for O:=Low(O)to High(O)do begin
    FLabels[O]:=TMenuLabel.Create(Self);FLabels[O].FontSize:=18;
    BindUiText(FLabels[O],AudioTitles[O]);InsertFront(FLabels[O]);
    FRows[O]:=TMenuFlow.Create(Self);FRows[O].Spacing:=7;InsertFront(FRows[O]);
    for I:=0 to 4 do begin
      B:=TMenuButton.Create(Self);FButtons[O,I]:=B;B.AutoIcon:=False;
      B.Name:='Audio_'+AudioKeys[O]+'_'+IntToStr(I*25);B.FontSize:=16;
      if I=0 then BindUiText(B,'Off')else B.Caption:=IntToStr(I*25)+'%';
      B.PaddingHorizontal:=12;B.PaddingVertical:=8;B.MinWidth:=50;
      B.Tag:=Ord(O)*5+I;B.OnClick:=@Choose;FRows[O].InsertFront(B);
    end;
  end;
end;
procedure TAudioPanel.Choose(Sender:TObject);
var TagValue:Integer;
begin TagValue:=(Sender as TMenuButton).Tag;Settings.SetAudioOption(TagValue div 5,(TagValue mod 5)*25);end;
procedure TAudioPanel.Update(const SecondsPassed:Single;var HandleInput:Boolean);
var O:TAudioOption;I,V:Integer;W,Y,X,Top:Single;
begin
  inherited;
  if FRevision<>Settings.AudioRevision then begin
    for O:=Low(O)to High(O)do begin
      V:=Settings.GetAudioOption(Ord(O));
      for I:=0 to 4 do SelectMenuButton(FButtons[O,I],V=I*25);
    end;
    FRevision:=Settings.AudioRevision;
  end;
  W:=Max(200,EffectiveWidth);FHint.MaxWidth:=W;Y:=36+FHint.EffectiveHeight+20;
  for O:=Low(O)to High(O)do begin
    if W>=680 then begin X:=240;Top:=0;end else begin X:=0;Top:=32;end;
    FLabels[O].MaxWidth:=IfThen(X>0,X-12,W);
    FLabels[O].Anchor(hpLeft);FLabels[O].Anchor(vpTop,-Y-7);
    FRows[O].Width:=W-X;FRows[O].Anchor(hpLeft,X);FRows[O].Anchor(vpTop,-Y-Top);FRows[O].Arrange;
    Y:=Y+Top+FRows[O].EffectiveHeight+16;
  end;
  Height:=Y;
end;
end.

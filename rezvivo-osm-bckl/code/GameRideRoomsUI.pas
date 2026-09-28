unit GameRideRoomsUI;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses Classes,CastleUIControls,CastleControls,CastleKeysMouse,GameMenuTheme,GameUiNavigation;
type
  TViewRideRooms=class(TCastleView)
  private
    FKeyboard:TUiKeyboardNavigation;
    FCode:TCastleEdit;
    FStatus, FSource:TCastleLabel;
    FCreate,FJoin,FRide,FLeave,FSignIn,FCopy:TMenuButton;
    procedure ClickCreate(Sender:TObject);
    procedure ClickJoin(Sender:TObject);
    procedure ClickRide(Sender:TObject);
    procedure ClickLeave(Sender:TObject);
    procedure ClickSignIn(Sender:TObject);
    procedure ClickClose(Sender:TObject);
    procedure ClickCopy(Sender:TObject);
  public
    SourceKind,SourceFile,SourceTitle:string;
    OnRide,OnSignIn,OnRoomChanged:TNotifyEvent;
    procedure Start;override;
    procedure Stop;override;
    procedure Update(const SecondsPassed:Single;var HandleInput:Boolean);override;
    function PreviewPress(const Event:TInputPressRelease):Boolean;override;
    function Press(const Event:TInputPressRelease):Boolean;override;
  end;
implementation
uses SysUtils,CastleVectors,GameRideRooms,UiTranslations,VeloSiteAPI;
procedure TViewRideRooms.Start;
var Bg:TCastleRectangleControl;Panel:TMenuPanel;L:TCastleLabel;
  function Button(const Name,Key:string;X,Y:Single;Handler:TNotifyEvent):TMenuButton;
  begin
    Result:=TMenuButton.Create(FreeAtStop);Result.Name:=Name;Result.AutoIcon:=False;
    Result.FontSize:=18;BindUiText(Result,Key);Result.Anchor(hpLeft,X);Result.Anchor(vpTop,-Y);
    Result.OnClick:=Handler;Panel.InsertFront(Result);
  end;
begin
  inherited;
  Bg:=TCastleRectangleControl.Create(FreeAtStop);Bg.FullSize:=True;Bg.Color:=Vector4(0.01,0.025,0.04,0.94);InsertBack(Bg);
  Panel:=TMenuPanel.Create(FreeAtStop);Panel.Width:=650;Panel.Height:=520;Panel.Anchor(hpMiddle);Panel.Anchor(vpMiddle);InsertFront(Panel);
  L:=TMenuLabel.Create(FreeAtStop);BindUiText(L,'Ride with a friend');L.FontSize:=28;L.Anchor(hpLeft,24);L.Anchor(vpTop,-24);Panel.InsertFront(L);
  FSource:=TMenuLabel.Create(FreeAtStop);FSource.FontSize:=17;FSource.MaxWidth:=600;FSource.Anchor(hpLeft,24);FSource.Anchor(vpTop,-74);Panel.InsertFront(FSource);
  FSource.Caption:=UiText('Selected world')+': '+SourceTitle;
  FCreate:=Button('RoomCreate','Create room',24,120,@ClickCreate);
  FCode:=TCastleEdit.Create(FreeAtStop);FCode.Name:='RoomCode';FCode.Width:=310;FCode.Height:=44;FCode.FontSize:=20;
  FCode.Anchor(hpLeft,24);FCode.Anchor(vpTop,-181);Panel.InsertFront(FCode);
  L:=TMenuLabel.Create(FreeAtStop);BindUiText(L,'Room code');L.FontSize:=15;L.Anchor(hpLeft,24);L.Anchor(vpTop,-161);Panel.InsertFront(L);
  FJoin:=Button('RoomJoin','Join room',360,182,@ClickJoin);
  FCopy:=Button('RoomCopy','Copy code',360,182,@ClickCopy);
  FStatus:=TMenuLabel.Create(FreeAtStop);FStatus.Name:='RoomStatus';FStatus.FontSize:=18;FStatus.MaxWidth:=600;FStatus.Anchor(hpLeft,24);FStatus.Anchor(vpTop,-255);Panel.InsertFront(FStatus);
  FRide:=Button('RoomRide','Ride together',24,377,@ClickRide);FRide.Style:=mbPrimary;
  FLeave:=Button('RoomLeave','Leave room',360,377,@ClickLeave);
  FSignIn:=Button('RoomSignIn','Sign in',24,377,@ClickSignIn);
  Button('RoomClose','Close',24,454,@ClickClose);
  FKeyboard:=TUiKeyboardNavigation.Create(FreeAtStop);InsertFront(FKeyboard);
end;
procedure TViewRideRooms.Stop;
begin if FKeyboard<>nil then FKeyboard.Clear;inherited;FKeyboard:=nil;end;
procedure TViewRideRooms.Update(const SecondsPassed:Single;var HandleInput:Boolean);
var RoomActive,Busy,Authorized:Boolean;S:string;I:TRideRoomInfo;
begin
  inherited;RideRooms.Update;RoomActive:=RideRooms.Active;Busy:=RideRooms.Busy;
  Authorized:=VeloSite.IsAuthorized;I:=RideRooms.Info;
  FCreate.Enabled:=Authorized and not Busy and not RoomActive and(SourceFile<>'');
  FJoin.Enabled:=Authorized and not Busy and not RoomActive;
  FJoin.Exists:=not RoomActive;FCopy.Exists:=RoomActive;FCopy.Enabled:=not Busy;
  FCode.Enabled:=not Busy and not RoomActive;
  FRide.Exists:=RoomActive;FRide.Enabled:=not Busy;FLeave.Exists:=RoomActive;FLeave.Enabled:=not Busy;
  FSignIn.Exists:=not Authorized;
  if Busy then S:=UiText('Connecting to room...')
  else if RideRooms.ErrorText<>''then S:=UiText(RideRooms.ErrorText)
  else if RoomActive then begin
    S:=UiText('Room code')+': '+I.Code+#10+I.Title+#10+UiText('Share this code with your friend.');
    if RideRooms.RelayError<>''then S:=S+#10+UiText('Connection lost. Reconnecting...');
    if FCode.Text<>I.Code then FCode.Text:=I.Code;
  end else if not Authorized then S:=UiText('Sign in to ride with a friend.')
  else S:=UiText('Create a room for the selected world, or enter your friend''s code.');
  if S<>FStatus.Caption then FStatus.Caption:=S;
end;
procedure TViewRideRooms.ClickCreate(Sender:TObject);
begin RideRooms.CreateRoom(SourceKind,SourceFile);end;
procedure TViewRideRooms.ClickCopy(Sender:TObject);
begin if RideRooms.Active then Clipboard.AsText:=RideRooms.Info.Code;end;
procedure TViewRideRooms.ClickJoin(Sender:TObject);
begin RideRooms.Join(FCode.Text);end;
procedure TViewRideRooms.ClickRide(Sender:TObject);
begin
  if not RideRooms.Active or RideRooms.Busy then Exit;
  Container.PopView(Self);if Assigned(OnRide)then OnRide(Self);
end;
procedure TViewRideRooms.ClickLeave(Sender:TObject);
begin RideRooms.Leave;if Assigned(OnRoomChanged)then OnRoomChanged(Self);end;
procedure TViewRideRooms.ClickSignIn(Sender:TObject);
begin Container.PopView(Self);if Assigned(OnSignIn)then OnSignIn(Self);end;
procedure TViewRideRooms.ClickClose(Sender:TObject);
begin RideRooms.Cancel;Container.PopView(Self);end;
function TViewRideRooms.PreviewPress(const Event:TInputPressRelease):Boolean;
begin Result:=inherited;if not Result and(FKeyboard<>nil)then Result:=FKeyboard.Handle(Event,Self);end;
function TViewRideRooms.Press(const Event:TInputPressRelease):Boolean;
begin Result:=inherited;if not Result and Event.IsKey(keyEscape)then ClickClose(nil);Result:=True;end;
end.

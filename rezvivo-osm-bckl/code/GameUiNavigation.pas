unit GameUiNavigation;
{$mode objfpc}{$H+}
interface
uses Classes,CastleUIControls,CastleKeysMouse;
type
  TUiKeyboardNavigation=class(TCastleUserInterface)
  private
    FSelected:TCastleUserInterface;
    function Available(C:TCastleUserInterface):Boolean;
    procedure SelectControl(C:TCastleUserInterface);
  protected
    procedure Notification(AComponent:TComponent;Operation:TOperation);override;
  public
    constructor Create(AOwner:TComponent);override;
    function Handle(const Event:TInputPressRelease;Root:TCastleUserInterface):Boolean;
    procedure Clear;
    procedure Render;override;
  end;
implementation
uses SysUtils,Math,CastleControls,CastleRectangles,CastleGLUtils,GameMenuTheme,GameRideCarousel;
constructor TUiKeyboardNavigation.Create(AOwner:TComponent);
begin inherited;FullSize:=True;CapturesEvents:=False;end;
procedure TUiKeyboardNavigation.Notification(AComponent:TComponent;Operation:TOperation);
begin inherited;if(Operation=opRemove)and(AComponent=FSelected)then FSelected:=nil;end;
function TUiKeyboardNavigation.Available(C:TCastleUserInterface):Boolean;
begin
  Result:=False;if C=nil then Exit;
  if(C is TCastleButton)and not TCastleButton(C).Enabled then Exit;
  if(C is TCastleEdit)and not TCastleEdit(C).Enabled then Exit;
  while C<>nil do begin if not C.Exists then Exit;C:=C.Parent;end;
  Result:=True;
end;
procedure TUiKeyboardNavigation.Clear;
begin
  if FSelected<>nil then begin
    if(Container<>nil)and(Container.ForceCaptureInput=FSelected)then Container.ForceCaptureInput:=nil;
    FSelected.RemoveFreeNotification(Self);FSelected:=nil;
  end;
end;
procedure TUiKeyboardNavigation.SelectControl(C:TCastleUserInterface);
var P:TCastleUserInterface;R,V:TFloatRectangle;Scroll:TCastleScrollView;
begin
  if(Container<>nil)and(Container.ForceCaptureInput is TCastleEdit)then Container.ForceCaptureInput:=nil;
  Clear;FSelected:=C;if C=nil then Exit;
  C.FreeNotification(Self);C.Focused:=True;
  if(C is TCastleEdit)and(Container<>nil)then Container.ForceCaptureInput:=C;
  P:=C.Parent;
  while P<>nil do begin
    if P is TCastleScrollView then begin
      Scroll:=TCastleScrollView(P);R:=C.RenderRect;V:=Scroll.RenderRect;
      if R.Bottom<V.Bottom+8 then Scroll.Scroll:=Scroll.Scroll+(V.Bottom+8-R.Bottom)/Max(0.01,C.UIScale)
      else if R.Top>V.Top-8 then Scroll.Scroll:=Scroll.Scroll-(R.Top-V.Top+8)/Max(0.01,C.UIScale);
    end;
    P:=P.Parent;
  end;
end;
function TUiKeyboardNavigation.Handle(const Event:TInputPressRelease;Root:TCastleUserInterface):Boolean;
var Items:TList;I,J,Index,Step:Integer;C,T:TCastleUserInterface;
  procedure Collect(N:TCastleUserInterface);
  var K:Integer;
  begin
    if not N.Exists or(N=Self)then Exit;
    if N is TCastleButton then begin
      if not TCastleButton(N).Enabled then Exit;
      if(TCastleButton(N).Caption<>'')or(N.ControlsCount=0)then Items.Add(N);
    end;
    if N is TCastleEdit then begin if TCastleEdit(N).Enabled then Items.Add(N);Exit;end;
    if(N is TRideCarousel)or(N is TCastleCheckbox)then begin Items.Add(N);Exit;end;
    for K:=0 to N.ControlsCount-1 do Collect(N.Controls[K]);
  end;
begin
  Result:=False;
  if Event.EventType=itMouseButton then begin Clear;Exit;end;
  if Event.EventType<>itKey then Exit;
  if not Available(FSelected)then Clear;
  if FSelected<>nil then begin
    C:=FSelected;while(C<>nil)and(C<>Root)do C:=C.Parent;
    if C=nil then Clear;
  end;
  if(Container<>nil)and(Container.ForceCaptureInput<>nil)and
    not(Container.ForceCaptureInput is TCastleEdit)then Exit;
  if Event.IsKey(keyEscape)then begin Clear;Exit;end;
  if(FSelected is TRideCarousel)then begin
    if Event.IsKey(keyArrowUp)or Event.IsKey(keyArrowLeft)then begin TRideCarousel(FSelected).MoveBy(-1);Exit(True);end;
    if Event.IsKey(keyArrowDown)or Event.IsKey(keyArrowRight)then begin TRideCarousel(FSelected).MoveBy(1);Exit(True);end;
    if Event.IsKey(keyEnter)then begin TRideCarousel(FSelected).SelectCentered;Exit(True);end;
  end;
  if Event.IsKey(keyEnter)and(FSelected<>nil)then begin
    if FSelected is TCastleButton then begin TCastleButton(FSelected).DoClick;Exit(True);end;
    if FSelected is TCastleCheckbox then begin
      TCastleCheckbox(FSelected).Checked:=not TCastleCheckbox(FSelected).Checked;
      if Assigned(TCastleCheckbox(FSelected).OnChange)then TCastleCheckbox(FSelected).OnChange(FSelected);
      Exit(True);
    end;
  end;
  if not Event.IsKey(keyTab)and not((FSelected<>nil)and not(FSelected is TCastleEdit)and
    (Event.IsKey(keyArrowUp)or Event.IsKey(keyArrowDown)or Event.IsKey(keyArrowLeft)or Event.IsKey(keyArrowRight)))then Exit;
  Items:=TList.Create;
  try
    Collect(Root);
    { Geometric reading order, independent of InsertFront / creation order. }
    for I:=1 to Items.Count-1 do begin
      C:=TCastleUserInterface(Items[I]);J:=I;
      while J>0 do begin
        T:=TCastleUserInterface(Items[J-1]);
        if(T.RenderRect.Top>C.RenderRect.Top+8)or
          ((Abs(T.RenderRect.Top-C.RenderRect.Top)<=8)and(T.RenderRect.Left<=C.RenderRect.Left))then Break;
        Items[J]:=Items[J-1];Dec(J);
      end;
      Items[J]:=C;
    end;
    if Items.Count=0 then Exit;
    Step:=1;
    if Event.IsKey(keyArrowUp)or Event.IsKey(keyArrowLeft)or
      (Event.IsKey(keyTab)and(mkShift in Event.ModifiersDown))then Step:=-1;
    Index:=Items.IndexOf(FSelected);
    if(Index<0)and(Container<>nil)and(Container.ForceCaptureInput is TCastleEdit)then
      Index:=Items.IndexOf(Container.ForceCaptureInput);
    if Index<0 then begin if Step>0 then Index:=0 else Index:=Items.Count-1;end
    else Index:=(Index+Step+Items.Count)mod Items.Count;
    SelectControl(TCastleUserInterface(Items[Index]));Result:=True;
  finally Items.Free;end;
end;
procedure TUiKeyboardNavigation.Render;
begin
  inherited;
  if Available(FSelected)then DrawRectangleOutline(FSelected.RenderRect.Grow(3),MenuAccent,3);
end;
end.

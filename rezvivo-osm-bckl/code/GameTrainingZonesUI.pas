unit GameTrainingZonesUI;

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses GameMenuTheme, Classes, SysUtils, CastleUIControls, CastleControls, fpjson;

type
  TTrainingZonesEditor = class(TCastleUserInterface)
  private
    FRowsOwner: TComponent;
    FScroll: TCastleScrollView;
    FNames, FMax: array[0..1, 0..9] of TCastleEdit;
    FRanges: array[0..1, 0..9] of TCastleLabel;
    FCount: array[0..1] of Integer;
    FData: TJSONObject;
    FFtp: TCastleEdit;
    FOriginal: String;
    procedure BuildRows;
    procedure ChangeCount(Sender: TObject);
    procedure Capture;
    procedure Changed(Sender: TObject);
    procedure InputEdited(Sender:TObject);
  public
    OnEdited:TNotifyEvent;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Load(const AJSON: String; AFtp: TCastleEdit);
    function ReadChanges: String;
    procedure Update(const SecondsPassed: Single; var HandleInput: Boolean); override;
  end;

implementation

uses UiTranslations, Math, jsonparser, CastleColors;

const Keys: array[0..1] of String = ('heart_rate', 'power');

constructor TTrainingZonesEditor.Create(AOwner: TComponent);
begin
  inherited;
  Width := 800;
  Height := 360;
  FScroll := TMenuScrollView.Create(Self);
  FScroll.FullSize := True;
  InsertFront(FScroll);
end;

destructor TTrainingZonesEditor.Destroy;
begin
  FreeAndNil(FData);
  inherited;
end;

procedure TTrainingZonesEditor.Load(const AJSON: String; AFtp: TCastleEdit);
var G: Integer;
begin
  FreeAndNil(FData);
  if AJSON <> '' then FData := GetJSON(AJSON) as TJSONObject
  else FData := TJSONObject.Create;
  for G := 0 to 1 do
    if not (FData.Find(Keys[G]) is TJSONArray) then
    begin
      FData.Delete(Keys[G]);
      FData.Add(Keys[G], TJSONArray.Create);
    end;
  FFtp := AFtp;
  BuildRows;
  Capture;
  FOriginal := FData.AsJSON;
end;

procedure TTrainingZonesEditor.BuildRows;
var
  G,I,N: Integer;
  A: TJSONArray;
  O: TJSONObject;
  L: TCastleLabel;
  B: TCastleButton;
  X,Y: Single;
  procedure LabelAt(const Text: String; AX,AY: Single; Scale: Single = 0.8);
  begin
    L := TMenuLabel.Create(FRowsOwner);
    BindUiText(L, Text);
    L.Color := White;
    L.FontScale := Scale;
    L.Anchor(hpLeft,AX);
    L.Anchor(vpTop,-AY);
    FScroll.ScrollArea.InsertFront(L);
  end;
begin
  FScroll.ScrollArea.ClearControls;
  FreeAndNil(FRowsOwner);
  FRowsOwner := TComponent.Create(Self);
  FillChar(FNames,SizeOf(FNames),0);
  FillChar(FMax,SizeOf(FMax),0);
  FillChar(FRanges,SizeOf(FRanges),0);
  N := 0;
  for G := 0 to 1 do
  begin
    X := G*400;
    A := FData.Arrays[Keys[G]];
    FCount[G] := Min(A.Count,10);
    N := Max(N,FCount[G]);
    if G=0 then LabelAt(UiText('Heart rate zones · up to, bpm'),X,0,0.95)
    else LabelAt(UiText('Power zones · up to, % FTP'),X,0,0.95);
    for I := 0 to FCount[G]-1 do
    begin
      O := A.Objects[I];
      Y := 38+I*40;
      LabelAt('Z'+IntToStr(I+1),X,Y+5);
      FNames[G,I] := TMenuEdit.Create(FRowsOwner);
      FNames[G,I].Name := 'ZoneName'+IntToStr(G)+'_'+IntToStr(I+1);
      FNames[G,I].Width := 166;
      FNames[G,I].FontScale := 0.8;
      FNames[G,I].Text := O.Get('name','Z'+IntToStr(I+1));
      FNames[G,I].Anchor(hpLeft,X+30);
      FNames[G,I].Anchor(vpTop,-Y);
      FScroll.ScrollArea.InsertFront(FNames[G,I]);
      FMax[G,I] := TMenuEdit.Create(FRowsOwner);
      FMax[G,I].Name := 'ZoneMax'+IntToStr(G)+'_'+IntToStr(I+1);
      FMax[G,I].Width := 62;
      FMax[G,I].FontScale := 0.8;
      FMax[G,I].Text := IntToStr(O.Get('max',0));
      if (G=1) and (I=FCount[G]-1) then
      begin
        FMax[G,I].Text := '∞';
        FMax[G,I].Enabled := False;
      end;
      FMax[G,I].Anchor(hpLeft,X+204);
      FMax[G,I].Anchor(vpTop,-Y);
      FScroll.ScrollArea.InsertFront(FMax[G,I]);
      LabelAt('',X+275,Y+5,0.72);
      FRanges[G,I] := L;FNames[G,I].OnChange:=@InputEdited;FMax[G,I].OnChange:=@InputEdited;
    end;
    if FCount[G]=0 then LabelAt(UiText('No zones configured yet'),X,40);
    for I := 0 to 1 do
    begin
      B := TMenuButton.Create(FRowsOwner);
      B.Name := 'ZoneCount'+IntToStr(G)+'_'+IntToStr(I);
      B.Tag := G*2+I;
      if I=0 then BindUiText(B, '+ Zone') else BindUiText(B, '− Last');
      B.FontScale := 0.8;
      B.PaddingHorizontal := 10;
      B.PaddingVertical := 5;
      B.Enabled := ((I=0) and (FCount[G]<10)) or ((I=1) and (FCount[G]>0));
      B.OnClick := @ChangeCount;
      B.Anchor(hpLeft,X+I*110);
      B.Anchor(vpTop,-(48+Max(1,FCount[G])*40));
      FScroll.ScrollArea.InsertFront(B);
    end;
  end;
  FScroll.ScrollArea.Height := 88+Max(N,1)*40;
  Changed(nil);
end;

procedure TTrainingZonesEditor.Capture;
var G,I,V: Integer; A: TJSONArray;
begin
  for G:=0 to 1 do
  begin
    A := FData.Arrays[Keys[G]];
    A.Clear;
    for I:=0 to FCount[G]-1 do
    begin
      if (G=1) and (I=FCount[G]-1) then V:=0
      else V:=StrToIntDef(Trim(FMax[G,I].Text),-1);
      A.Add(TJSONObject.Create(['name',Trim(FNames[G,I].Text),'max',V]));
    end;
  end;
end;

procedure TTrainingZonesEditor.ChangeCount(Sender: TObject);
var G,Op,N,V: Integer; A: TJSONArray;
begin
  Capture;
  G := (Sender as TCastleButton).Tag div 2;
  Op := (Sender as TCastleButton).Tag mod 2;
  A := FData.Arrays[Keys[G]];
  N := A.Count;
  if Op=1 then
  begin
    if N<=2 then A.Clear else A.Delete(N-1);
    if (G=1) and (A.Count>0) then A.Objects[A.Count-1].Integers['max']:=0;
  end
  else if N<10 then
  begin
    if N=0 then
    begin
      if G=0 then V:=100 else V:=55;
      A.Add(TJSONObject.Create(['name','Z1','max',V]));
      N:=1;
    end;
    if G=1 then
    begin
      if N>1 then A.Objects[N-1].Integers['max']:=A.Objects[N-2].Get('max',55)+10;
      V:=0;
    end
    else V:=A.Objects[N-1].Get('max',100)+10;
    A.Add(TJSONObject.Create(['name','Z'+IntToStr(N+1),'max',V]));
  end;
  BuildRows;if Assigned(OnEdited)then OnEdited(Self);
end;

procedure TTrainingZonesEditor.Changed(Sender: TObject);
var G,I,Prev,V,Ftp: Integer; S: String;
begin
  if FFtp=nil then Exit;
  Ftp:=StrToIntDef(FFtp.Text,0);
  for G:=0 to 1 do
  begin
    Prev:=0;
    for I:=0 to FCount[G]-1 do
    begin
      V:=StrToIntDef(FMax[G,I].Text,0);
      if G=1 then V:=Floor(Ftp*V/100);
      if (G=1) and (I=FCount[G]-1) then S:=IntToStr(Prev+1)+'+'
      else begin
        if I=0 then S:='0' else S:=IntToStr(Prev+1);
        S:=S+'–'+IntToStr(V);
      end;
      if G=1 then begin
        if Ftp<=0 then S:='FTP?'
        else S:=S+UiText(' W');
      end;
      FRanges[G,I].Caption:=S;
      Prev:=V;
    end;
  end;
end;

function TTrainingZonesEditor.ReadChanges: String;
var G,I,Prev,V,Limit: Integer;
begin
  Capture;
  for G:=0 to 1 do
  begin
    Prev:=0;
    if G=0 then Limit:=250 else Limit:=1000;
    for I:=0 to FCount[G]-1 do
    begin
      if Trim(FNames[G,I].Text)='' then raise Exception.Create(UiText('Enter a name for each zone.'));
      if (G=1) and (I=FCount[G]-1) then Continue;
      V:=FData.Arrays[Keys[G]].Objects[I].Get('max',-1);
      if (V<=Prev) or (V>Limit) then
        raise Exception.Create(UiText('Zone limits must increase. Maximum: ')+IntToStr(Limit)+'.');
      Prev:=V;
    end;
  end;
  Result:=FData.AsJSON;
  if Result=FOriginal then Result:='';
end;

procedure TTrainingZonesEditor.Update(const SecondsPassed: Single; var HandleInput: Boolean);
begin
  inherited;
  Changed(nil);
end;

procedure TTrainingZonesEditor.InputEdited(Sender:TObject);
begin Changed(Sender);if Assigned(OnEdited)then OnEdited(Self);end;

end.

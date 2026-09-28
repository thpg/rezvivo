unit Osm3dLodTree;

{$Q-}{$R-}
{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  Math, Osm3dTileSlotGrid;

type
  TLodCellId = record
    CX, CY: Integer;   { base-tile coords }
  end;

  { One base-tile cell. Abstract: the host subclasses it to build the real
    tile scene. The tree only drives visibility through SetVisible. }
  TLodCell = class
  protected
    FId:      TLodCellId;
    FVisible: Boolean;
    procedure DoSetVisible(AOn: Boolean); virtual; abstract;
  public
    constructor Create(const AId: TLodCellId); virtual;
    procedure SetVisible(AOn: Boolean);
    property Id:      TLodCellId read FId;
    property Visible: Boolean    read FVisible;
  end;

  TLodCellFactory = function(const AId: TLodCellId): TLodCell of object;

  { Owns the single ring and shows every cell in it. }
  TLodTree = class
  private
    FRing:    TLodRing;
    FFactory: TLodCellFactory;
    procedure RingEnter(Sender: TObject; Slot: PTileSlot);
    procedure RingLeave(Sender: TObject; Slot: PTileSlot);
  public
    constructor Create(AFactory: TLodCellFactory; ARadius: Integer);
    destructor Destroy; override;
    { Recenter the ring on the camera (fractional base-tile units) and show
      every resident cell. }
    procedure Update(ACamX, ACamY: Double);
  end;

implementation

constructor TLodCell.Create(const AId: TLodCellId);
begin
  inherited Create;
  FId      := AId;
  FVisible := False;
end;

procedure TLodCell.SetVisible(AOn: Boolean);
begin
  if AOn = FVisible then Exit;
  FVisible := AOn;
  DoSetVisible(AOn);
end;

constructor TLodTree.Create(AFactory: TLodCellFactory; ARadius: Integer);
begin
  inherited Create;
  FFactory := AFactory;
  if ARadius < 1 then ARadius := 1;
  FRing := TLodRing.Create(ARadius, 1);
  FRing.OnSlotEnter := @RingEnter;
  FRing.OnSlotLeave := @RingLeave;
end;

destructor TLodTree.Destroy;
begin
  if FRing <> nil then
  begin
    FRing.Clear;            { fires OnSlotLeave -> frees the cells }
    FRing.Free;
  end;
  inherited Destroy;
end;

procedure TLodTree.RingEnter(Sender: TObject; Slot: PTileSlot);
var
  Id: TLodCellId;
begin
  Id.CX := Slot^.TX;
  Id.CY := Slot^.TY;
  if Assigned(FFactory) then
    Slot^.Data := FFactory(Id);
end;

procedure TLodTree.RingLeave(Sender: TObject; Slot: PTileSlot);
begin
  if Slot^.Data <> nil then
  begin
    Slot^.Data.Free;        { TLodCell destructor releases its scene }
    Slot^.Data := nil;
  end;
end;

procedure TLodTree.Update(ACamX, ACamY: Double);
var
  GX, GY: Integer;
  P:      PTileSlot;
begin
  FRing.Recenter(Floor(ACamX), Floor(ACamY));
  for GY := 0 to FRing.Size - 1 do
    for GX := 0 to FRing.Size - 1 do
    begin
      P := FRing.Slot(GX, GY);
      if (P <> nil) and (P^.Data <> nil) then
        TLodCell(P^.Data).SetVisible(True);
    end;
end;

end.

unit Osm3dTileSlotGrid;

{$Q-}{$R-}
{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

type
  TSlotState = (ssEmpty, ssWanted, ssLoaded);

  TTileSlot = record
    State:  TSlotState;
    TX, TY: Integer;   { absolute CELL coordinates (tile = cell * Span) }
    Data:   TObject;   { opaque payload owned by the caller }
  end;
  PTileSlot = ^TTileSlot;

  TSlotEvent = procedure(Sender: TObject; Slot: PTileSlot) of object;

  { Camera-centred odd x odd ring of LOD cells of a single Span. }
  TLodRing = class
  private
    FRadius:  Integer;
    FSize:    Integer;              { N = 2R+1 }
    FSpan:    Integer;              { tiles per cell side: 1/4/16/64 }
    FSlots:   array of TTileSlot;   { N*N, row-major [gy*N + gx] }
    FCamTX:   Integer;
    FCamTY:   Integer;
    FCentred: Boolean;
    FOnEnter: TSlotEvent;
    FOnLeave: TSlotEvent;
    procedure FillSlotFresh(P: PTileSlot; GX, GY: Integer);
    procedure ReleaseSlot(P: PTileSlot);
    procedure ScrollSlots(DX, DY: Integer);
  public
    constructor Create(ARadius: Integer; ASpan: Integer = 1);
    destructor Destroy; override;

    { Move the window centre onto cell (ACamTX,ACamTY). First call fills
      all slots (OnSlotEnter each); same cell is a no-op returning False;
      otherwise scrolls and fires leave/enter for the edges. Cheap per
      frame. Returns True if anything changed. }
    function Recenter(ACamTX, ACamTY: Integer): Boolean;
    { OnSlotLeave for every non-empty slot, reset to un-centred. Call
      before Free so the caller can release Slot^.Data; the destructor
      raises no events. }
    procedure Clear;

    function Slot(GX, GY: Integer): PTileSlot;
    function SlotOfTile(ATX, ATY: Integer): PTileSlot;

    property Radius:  Integer read FRadius;
    property Size:    Integer read FSize;
    property Span:    Integer read FSpan;
    property Centred: Boolean read FCentred;
    property CamTX:   Integer read FCamTX;
    property CamTY:   Integer read FCamTY;

    property OnSlotEnter: TSlotEvent read FOnEnter write FOnEnter;
    property OnSlotLeave: TSlotEvent read FOnLeave write FOnLeave;
  end;

  { Compatibility alias: the original ground-tile grid is a Span=1 ring. }
  TTileSlotGrid = TLodRing;

implementation

uses
  Math;

constructor TLodRing.Create(ARadius: Integer; ASpan: Integer);
var
  I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1780);{$ENDIF}
  inherited Create;
  if ARadius < 1 then ARadius := 1;
  if ASpan   < 1 then ASpan   := 1;
  FRadius  := ARadius;
  FSize    := 2 * ARadius + 1;
  FSpan    := ASpan;
  FCentred := False;
  FCamTX   := 0;
  FCamTY   := 0;
  SetLength(FSlots, FSize * FSize);
  for I := 0 to High(FSlots) do
  begin
    FSlots[I].State := ssEmpty;
    FSlots[I].TX    := 0;
    FSlots[I].TY    := 0;
    FSlots[I].Data  := nil;
  end;
end;

destructor TLodRing.Destroy;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1781);{$ENDIF}
  SetLength(FSlots, 0);
  inherited Destroy;
end;

procedure TLodRing.FillSlotFresh(P: PTileSlot; GX, GY: Integer);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1782);{$ENDIF}
  P^.TX    := FCamTX - FRadius + GX;
  P^.TY    := FCamTY - FRadius + GY;
  P^.State := ssWanted;
  P^.Data  := nil;
  if Assigned(FOnEnter) then FOnEnter(Self, P);
end;

procedure TLodRing.ReleaseSlot(P: PTileSlot);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1783);{$ENDIF}
  if P^.State = ssEmpty then Exit;
  if Assigned(FOnLeave) then FOnLeave(Self, P);
  P^.State := ssEmpty;
  P^.Data  := nil;
end;

{ Destination cell (gx,gy) receives source (gx+DX, gy+DY): the cell that
  was DX,DY away now sits here. Cells whose source is off the old grid are
  the freshly exposed edge — left for Recenter to fill. }
procedure TLodRing.ScrollSlots(DX, DY: Integer);
var
  GX0, GX1, GY0, GY1, W, H, GY: Integer;
  Elem: PtrUInt;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1784);{$ENDIF}
  Elem := SizeOf(TTileSlot);
  GX0 := Max(0, -DX);  GX1 := Min(FSize - 1, FSize - 1 - DX);
  GY0 := Max(0, -DY);  GY1 := Min(FSize - 1, FSize - 1 - DY);
  W := GX1 - GX0 + 1;
  H := GY1 - GY0 + 1;
  if (W <= 0) or (H <= 0) then Exit;

  if DX = 0 then
  begin
    Move(FSlots[(GY0 + DY) * FSize],
         FSlots[GY0 * FSize],
         PtrUInt(H) * PtrUInt(FSize) * Elem);
    Exit;
  end;

  { One Move per row, ordered so a row is consumed as source before it can
    be overwritten as destination. }
  if DY >= 0 then
    for GY := GY0 to GY1 do
      Move(FSlots[(GY + DY) * FSize + (GX0 + DX)],
           FSlots[GY * FSize + GX0],
           PtrUInt(W) * Elem)
  else
    for GY := GY1 downto GY0 do
      Move(FSlots[(GY + DY) * FSize + (GX0 + DX)],
           FSlots[GY * FSize + GX0],
           PtrUInt(W) * Elem);
end;

function TLodRing.Recenter(ACamTX, ACamTY: Integer): Boolean;
var
  DX, DY, GX, GY, SX, SY: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1785);{$ENDIF}
  if not FCentred then
  begin
    FCamTX   := ACamTX;
    FCamTY   := ACamTY;
    FCentred := True;
    for GY := 0 to FSize - 1 do
      for GX := 0 to FSize - 1 do
        FillSlotFresh(@FSlots[GY * FSize + GX], GX, GY);
    Result := True;
    Exit;
  end;

  DX := ACamTX - FCamTX;
  DY := ACamTY - FCamTY;
  if (DX = 0) and (DY = 0) then
  begin
    Result := False;
    Exit;
  end;
  Result := True;

  { Jump too large for any overlap: unload all, refill all. }
  if (Abs(DX) >= FSize) or (Abs(DY) >= FSize) then
  begin
    for GY := 0 to FSize - 1 do
      for GX := 0 to FSize - 1 do
        ReleaseSlot(@FSlots[GY * FSize + GX]);
    FCamTX := ACamTX;
    FCamTY := ACamTY;
    for GY := 0 to FSize - 1 do
      for GX := 0 to FSize - 1 do
        FillSlotFresh(@FSlots[GY * FSize + GX], GX, GY);
    Exit;
  end;

  { Leave pass: an old slot survives iff its new home stays in-grid. }
  for SY := 0 to FSize - 1 do
    for SX := 0 to FSize - 1 do
      if (SX - DX < 0) or (SX - DX >= FSize) or
         (SY - DY < 0) or (SY - DY >= FSize) then
        ReleaseSlot(@FSlots[SY * FSize + SX]);

  ScrollSlots(DX, DY);

  FCamTX := ACamTX;
  FCamTY := ACamTY;
  for GY := 0 to FSize - 1 do
    for GX := 0 to FSize - 1 do
      if (GX + DX < 0) or (GX + DX >= FSize) or
         (GY + DY < 0) or (GY + DY >= FSize) then
        FillSlotFresh(@FSlots[GY * FSize + GX], GX, GY);
end;

procedure TLodRing.Clear;
var
  I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1786);{$ENDIF}
  for I := 0 to High(FSlots) do
    ReleaseSlot(@FSlots[I]);
  FCentred := False;
end;

function TLodRing.Slot(GX, GY: Integer): PTileSlot;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1787);{$ENDIF}
  if (GX < 0) or (GX >= FSize) or (GY < 0) or (GY >= FSize) then
    Result := nil
  else
    Result := @FSlots[GY * FSize + GX];
end;

function TLodRing.SlotOfTile(ATX, ATY: Integer): PTileSlot;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1788);{$ENDIF}
  if not FCentred then
    Result := nil
  else
    Result := Slot(ATX - (FCamTX - FRadius), ATY - (FCamTY - FRadius));
end;

end.

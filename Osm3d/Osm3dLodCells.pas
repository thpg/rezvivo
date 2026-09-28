unit Osm3dLodCells;

{$Q-}{$R-}
{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  Osm3dLodTree;

type
  TLodHostCallbacks = record
    ShowBase:    procedure(const AId: TLodCellId; AOn: Boolean) of object;
    ReleaseBase: procedure(const AId: TLodCellId) of object;
  end;

  { Detailed ground tile: shown whenever the ring holds it; the host lights
    the real detail when the streamer has mounted it. }
  TBaseTileCell = class(TLodCell)
  protected
    FCb: TLodHostCallbacks;
    procedure DoSetVisible(AOn: Boolean); override;
  public
    constructor Create(const AId: TLodCellId;
      const ACb: TLodHostCallbacks); reintroduce;
    destructor Destroy; override;
  end;

  function MakeLodCell(const AId: TLodCellId;
    const ACb: TLodHostCallbacks): TLodCell;

implementation

function MakeLodCell(const AId: TLodCellId;
  const ACb: TLodHostCallbacks): TLodCell;
begin
  Result := TBaseTileCell.Create(AId, ACb);
end;

constructor TBaseTileCell.Create(const AId: TLodCellId;
  const ACb: TLodHostCallbacks);
begin
  inherited Create(AId);
  FCb := ACb;
end;

destructor TBaseTileCell.Destroy;
begin
  if Assigned(FCb.ReleaseBase) then FCb.ReleaseBase(FId);
  inherited Destroy;
end;

procedure TBaseTileCell.DoSetVisible(AOn: Boolean);
begin
  if Assigned(FCb.ShowBase) then FCb.ShowBase(FId, AOn);
end;

end.

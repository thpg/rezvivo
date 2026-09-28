unit Osm3dChunk;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$codepage UTF8}
{ Suppress FPC false-positives on managed types reported as 'not initialized'. }
{$WARN 5060 OFF}{$WARN 5091 OFF}

interface

uses
  SysUtils,
  Osm3dGeoMath,
  Osm3dHeightmap,
  Osm3dOsmData
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

type
  { Owns heap-allocated THeightmap/TOSMDataset pointers; destructor frees them. }
  TOsm3dChunkData = class
  private
    FHeightmap:    THeightmap;
    FFarHeightmap: THeightmap;
    FDataset:      TOSMDataset;
  public
    Origin: TLatLon;
    Box:    TLatLonBox;
    { Latitude (deg) whose cos sets the metres-per-degree-LONGITUDE scale for the
      builder's projection. 0 (default) = use Origin.Lat. The block generator sets
      this to the SESSION latitude so a block built at a block-LOCAL Origin keeps
      the render frame's east/west scale and its tiles weld seamlessly. }
    ScaleLat: Double;
    { Origin СЕССИИ (рендер-кадра). Якорь мировой int-решётки 1/64 м
      (Osm3dIntGeo.TLatticeProjection): один и тот же OSM-узел в halo
      разных блоков получает решёточные координаты, отличающиеся ровно
      на целый сдвиг блока — плановая геометрия совпадает побитно.
      (0,0) = не задан (легаси-хост): билдер заякорится на Origin блока. }
    SessionOrigin: TLatLon;

    constructor Create;
    destructor Destroy; override;

    procedure SetHeightmap(AHm: THeightmap);
    procedure SetFarHeightmap(AHm: THeightmap);
    procedure SetDataset(ADs: TOSMDataset);

    property Heightmap:    THeightmap  read FHeightmap;
    property FarHeightmap: THeightmap  read FFarHeightmap;
    property Dataset:      TOSMDataset read FDataset;
  end;

implementation

constructor TOsm3dChunkData.Create;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1034);{$ENDIF}
  inherited;
end;

destructor TOsm3dChunkData.Destroy;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1035);{$ENDIF}
  FreeAndNil(FHeightmap);
  FreeAndNil(FFarHeightmap);
  FreeAndNil(FDataset);
  inherited;
end;

procedure TOsm3dChunkData.SetHeightmap(AHm: THeightmap);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(86);{$ENDIF}
  if FHeightmap <> AHm then FreeAndNil(FHeightmap);
  FHeightmap := AHm;
end;

procedure TOsm3dChunkData.SetFarHeightmap(AHm: THeightmap);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(87);{$ENDIF}
  if FFarHeightmap <> AHm then FreeAndNil(FFarHeightmap);
  FFarHeightmap := AHm;
end;

procedure TOsm3dChunkData.SetDataset(ADs: TOSMDataset);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(88);{$ENDIF}
  if FDataset <> ADs then FreeAndNil(FDataset);
  FDataset := ADs;
end;

end.

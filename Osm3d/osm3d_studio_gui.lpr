{ osm3d_studio_gui — главный исполняемый файл GUI Studio.

  Wires LCL Application + StudioMainForm + (на стороне пользователя)
  TCastleControl. Запуск:
    lazbuild osm3d_studio.lpi  &&  ./osm3d_studio_gui }
program osm3d_studio_gui;

{$mode objfpc}{$H+}
{$codepage UTF8}

{$DEFINE OSM3D_WITH_FITFILE}


uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces,
  Osm3dOSHeap,          // <-- ВОТ ЭТО (ставит ОС-менеджер в initialization)
  Forms, SysUtils, UiTranslations, castle_engine_lcl, castle_engine_base,
  Osm3dStudioMainForm, PBRTextureUnit,
  McpStdio, Osm3dMcp;

{$R *.res}
{$R app_icon.rc}

begin
  RequireDerivedFormResource := True;
  Application.Scaled:=True;
  { MCP (--mcp-stdio): глушим Pascal Output до любого возможного WriteLn,
    чтобы случайный вывод не испортил JSON-RPC поток в stdout. }
  if Osm3dMcpRequested then McpSilenceStdOut;
  Application.Initialize;
  if Osm3dMcpRequested and (GetEnvironmentVariable('REZVIVO_TEST_HIDDEN')='1') then
    Application.ShowMainForm := False;
  InitializeEditorTranslations;
  Application.CreateForm(TStudioMainForm, StudioMainForm);
  if not Application.ShowMainForm then StudioMainForm.InitializeHiddenRender;
  Osm3dMcpInit(StudioMainForm);   { no-op без --mcp-stdio }
  Application.Run;
  Osm3dMcpShutdown;               { no-op без --mcp-stdio }
end.

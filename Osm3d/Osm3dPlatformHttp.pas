unit Osm3dPlatformHttp;
{$mode objfpc}{$H+}
interface
uses Classes;
type
  { Platform transport changes I/O only; retry policy, cache keys and cache
    ownership stay in the existing OSM HTTP fetcher. }
  TOsmPlatformHttpRequest = class abstract
    NoRedirects: Boolean;
    MaxResponseBytes: Int64;
    procedure Execute(const Method, Url: String; Headers: TStrings; Body: TStream;
      ConnectMs, ReadMs: Integer; Response: TStream; out Status: Integer;
      ResponseHeaders: TStrings); virtual; abstract;
    procedure Cancel; virtual; abstract;
  end;
  TOsmPlatformHttpFactory = function: TOsmPlatformHttpRequest;
var
  OsmPlatformHttpFactory: TOsmPlatformHttpFactory = nil;
function TryPlatformHttp(const Method, Url: String; Headers: TStrings; Body: TStream;
  ConnectMs, ReadMs: Integer; Response: TStream; out Status: Integer;
  ResponseHeaders: TStrings): Boolean;
implementation
function TryPlatformHttp(const Method, Url: String; Headers: TStrings; Body: TStream;
  ConnectMs, ReadMs: Integer; Response: TStream; out Status: Integer;
  ResponseHeaders: TStrings): Boolean;
var Request: TOsmPlatformHttpRequest;
begin
  Result := Assigned(OsmPlatformHttpFactory);
  if not Result then Exit;
  Request := OsmPlatformHttpFactory();
  try Request.Execute(Method, Url, Headers, Body, ConnectMs, ReadMs, Response, Status, ResponseHeaders);
  finally Request.Free end;
end;
end.

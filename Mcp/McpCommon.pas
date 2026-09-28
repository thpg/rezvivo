{ Shared MCP (Model Context Protocol) library — common definitions.

  Transport-agnostic core: JSON-RPC 2.0 + RTTI-based object inspection.
  Transports: McpStdio (stdin/stdout, primary), McpServer (HTTP, later).

  Threading model: transports run in background threads; any access to
  application objects goes through McpBridge.McpRunTask. }
unit McpCommon;

{$mode objfpc}{$H+}

interface

uses SysUtils;

type
  { Raised for any user-facing MCP failure (unknown object/property,
    type mismatch, command error...). Transport layer converts it into
    a JSON-RPC error / tool error result. }
  EMcpError = class(Exception);
  { Registry misuse (nil object/handler at registration). }
  EMcpRegistryError = class(EMcpError);

const
  MCP_PROTOCOL_VERSION = '2024-11-05';
  MCP_LIB_VERSION = '0.1.0';

implementation

end.

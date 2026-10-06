{ ANTPlusLibusb0 — реализация TANTUsbBackend поверх libusb-win32 (libusb 0.1).

  libusb-win32 — старая ветка libusb (0.1 API), использует драйвер libusb0.sys
  и экспортирует функции через libusb0.dll. Стик enumerates как USB-устройство
  с VID 0x0FCF и PID:
    - 0x1008 / 0x1009 — Garmin/Dynastream ANT USB-m (синий цилиндр)
    - 0x1004 — Garmin ANT USB-2 (старый серый)

  Этот юнит:
    - Динамически загружает libusb0.dll (gracefully fail если нет).
    - Открывает первый найденный ANT-стик от Dynastream.
    - Реализует контракт TANTUsbBackend (Open/Close/WriteMessage/ReadMessage)
      через usb_bulk_write / usb_bulk_read на endpoint 0x01 (out) / 0x81 (in).
    - Делает RESET_SYSTEM + ожидание STARTUP + NETWORK_KEY handshake.
    - Регистрирует себя как ANT backend в initialization-секции,
      что включает ANT+ в GameDeviceService без ручной регистрации.

  Зависимость: libusb0.dll должна быть доступна (либо рядом с exe, либо в
  System32/SysWOW64 — куда libusb-win32 installer её кладёт). Если DLL нет,
  Open() возвращает False и в логе появится '[ANTPlus/libusb0] DLL not found'. }
unit ANTPlusLibusb0;

{$mode objfpc}{$H+}

interface

{$ifdef MSWINDOWS}

uses
  Classes, SysUtils, syncobjs,
  ANTPlus, DebugLog;

type
  // Полная реализация ANT USB backend через libusb-win32.
  TANTLibusb0Backend = class(TANTUsbBackend)
  private
    FDevHandle: Pointer;          // usb_dev_handle*
    FIoLock: TCriticalSection;    // serializes bulk_read/bulk_write на одном handle
    FProductDesc: string;         // строка для ProductDescription (из iProduct USB descriptor)
    FRxBuffer: TBytes;            // несгруппированные байты между bulk-read'ами
                                  // (USB-стик может отдать несколько ANT-фреймов
                                  //  в одном transfer — ANTDecodeMessage режет
                                  //  буфер по одному, остаток ждёт в FRxBuffer).
    FLastReadWarningTick: QWord;
    function ResetAndInitialize: Boolean;
    function TryDecodeFromBuffer(out AMsg: TANTMessage): Boolean;
    function RawBulkWrite(const ABytes: TBytes; ATimeoutMs: Cardinal): Boolean;
    procedure DrainStaleData;
  public
    constructor Create; override;
    destructor Destroy; override;

    function Open: Boolean; override;
    procedure Close; override;
    function WriteMessage(const AMsg: TANTMessage): Boolean; override;
    function ReadMessage(out AMsg: TANTMessage; ATimeoutMs: Cardinal): Boolean; override;
    function ProductDescription: string; override;
  end;

{$endif}

implementation

{$ifdef MSWINDOWS}

uses
  DynLibs;

const
  LIBUSB_DLL = 'libusb0.dll';

  // Dynastream / Garmin VID
  ANT_USB_VID = $0FCF;

  // Поддерживаемые PID-ы ANT-стиков
  ANT_USB_PID_USB_M_1 = $1008;  // ANT USB-m
  ANT_USB_PID_USB_M_2 = $1009;  // ANT USB-m (вторая ревизия)
  ANT_USB_PID_USB_2   = $1004;  // ANT USB-2 (старый)

  // ANT USB endpoints (стандартные для всех Dynastream-стиков)
  EP_BULK_OUT = $01;  // host → stick (commands)
  EP_BULK_IN  = $81;  // stick → host (broadcasts, responses)

  // libusb-win32 path-max (sizeof filename в struct usb_device)
  LIBUSB_PATH_MAX = 512;

type
  PUsbBus = ^TUsbBus;
  PUsbDevice = ^TUsbDevice;

  // 18 байт стандартного USB device descriptor
  TUsbDeviceDescriptor = packed record
    bLength: Byte;
    bDescriptorType: Byte;
    bcdUSB: Word;
    bDeviceClass: Byte;
    bDeviceSubClass: Byte;
    bDeviceProtocol: Byte;
    bMaxPacketSize0: Byte;
    idVendor: Word;
    idProduct: Word;
    bcdDevice: Word;
    iManufacturer: Byte;
    iProduct: Byte;
    iSerialNumber: Byte;
    bNumConfigurations: Byte;
  end;

  // struct usb_device (libusb-win32). Нам нужны только descriptor и devnum;
  // остальные поля объявлены для правильного выравнивания, к ним мы не лезем.
  TUsbDevice = record
    next: PUsbDevice;
    prev: PUsbDevice;
    filename: array[0..LIBUSB_PATH_MAX - 1] of AnsiChar;
    bus: PUsbBus;
    descriptor: TUsbDeviceDescriptor;
    config: Pointer;            // struct usb_config_descriptor*
    dev: Pointer;               // platform-specific
    devnum: Byte;
    num_children: Byte;
    children: ^PUsbDevice;
  end;

  TUsbBus = record
    next: PUsbBus;
    prev: PUsbBus;
    dirname: array[0..LIBUSB_PATH_MAX - 1] of AnsiChar;
    devices: PUsbDevice;
    location: Cardinal;
    root_dev: PUsbDevice;
  end;

  // libusb-win32 экспортирует все функции с C calling convention (cdecl)
  // как на 32-bit, так и на 64-bit Windows.
  Tusb_init             = procedure; cdecl;
  Tusb_find_busses      = function: Integer; cdecl;
  Tusb_find_devices     = function: Integer; cdecl;
  Tusb_get_busses       = function: PUsbBus; cdecl;
  Tusb_open             = function(dev: PUsbDevice): Pointer; cdecl;
  Tusb_close            = function(handle: Pointer): Integer; cdecl;
  Tusb_set_configuration = function(handle: Pointer; configuration: Integer): Integer; cdecl;
  Tusb_claim_interface  = function(handle: Pointer; iface: Integer): Integer; cdecl;
  Tusb_release_interface = function(handle: Pointer; iface: Integer): Integer; cdecl;
  Tusb_bulk_write       = function(handle: Pointer; ep: Integer;
                                    buf: Pointer; size: Integer;
                                    timeout: Integer): Integer; cdecl;
  Tusb_bulk_read        = function(handle: Pointer; ep: Integer;
                                    buf: Pointer; size: Integer;
                                    timeout: Integer): Integer; cdecl;
  Tusb_get_string_simple = function(handle: Pointer; index: Integer;
                                     buf: Pointer; buflen: Integer): Integer; cdecl;
  Tusb_strerror         = function: PAnsiChar; cdecl;

var
  GLibUsb: TLibHandle = NilHandle;
  GLoadAttempted: Boolean = False;
  GLastLoadAttempt: QWord = 0;
  Gusb_init: Tusb_init = nil;
  Gusb_find_busses: Tusb_find_busses = nil;
  Gusb_find_devices: Tusb_find_devices = nil;
  Gusb_get_busses: Tusb_get_busses = nil;
  Gusb_open: Tusb_open = nil;
  Gusb_close: Tusb_close = nil;
  Gusb_set_configuration: Tusb_set_configuration = nil;
  Gusb_claim_interface: Tusb_claim_interface = nil;
  Gusb_release_interface: Tusb_release_interface = nil;
  Gusb_bulk_write: Tusb_bulk_write = nil;
  Gusb_bulk_read: Tusb_bulk_read = nil;
  Gusb_get_string_simple: Tusb_get_string_simple = nil;
  Gusb_strerror: Tusb_strerror = nil;

// ═══════════════════════════════════════════════════════════════
// Динамическая загрузка libusb0.dll
// ═══════════════════════════════════════════════════════════════

function LoadLibusb0: Boolean;

  function ResolveProc(const AName: string): Pointer;
  begin
    Result := GetProcAddress(GLibUsb, PChar(AName));
    if Result = nil then
      Logger.Warning('[ANTPlus/libusb0] Symbol not found: ' + AName);
  end;

begin
  Result := False;
  if GLibUsb <> NilHandle then Exit(True);
  if GLoadAttempted and (GetTickCount64-GLastLoadAttempt<30000) then Exit;
  GLoadAttempted := True; GLastLoadAttempt:=GetTickCount64;

  GLibUsb := LoadLibrary(LIBUSB_DLL);
  if GLibUsb = NilHandle then
  begin
    Logger.Warning('[ANTPlus/libusb0] ' + LIBUSB_DLL +
      ' not found (place it next to the exe or install libusb-win32)');
    Exit;
  end;
  Logger.Info('[ANTPlus/libusb0] ' + LIBUSB_DLL + ' loaded');

  Pointer(Gusb_init)              := ResolveProc('usb_init');
  Pointer(Gusb_find_busses)       := ResolveProc('usb_find_busses');
  Pointer(Gusb_find_devices)      := ResolveProc('usb_find_devices');
  Pointer(Gusb_get_busses)        := ResolveProc('usb_get_busses');
  Pointer(Gusb_open)              := ResolveProc('usb_open');
  Pointer(Gusb_close)             := ResolveProc('usb_close');
  Pointer(Gusb_set_configuration) := ResolveProc('usb_set_configuration');
  Pointer(Gusb_claim_interface)   := ResolveProc('usb_claim_interface');
  Pointer(Gusb_release_interface) := ResolveProc('usb_release_interface');
  Pointer(Gusb_bulk_write)        := ResolveProc('usb_bulk_write');
  Pointer(Gusb_bulk_read)         := ResolveProc('usb_bulk_read');
  Pointer(Gusb_get_string_simple) := ResolveProc('usb_get_string_simple');
  Pointer(Gusb_strerror)          := ResolveProc('usb_strerror');

  Result := Assigned(Gusb_init) and Assigned(Gusb_find_busses) and
            Assigned(Gusb_find_devices) and Assigned(Gusb_get_busses) and
            Assigned(Gusb_open) and Assigned(Gusb_close) and
            Assigned(Gusb_set_configuration) and Assigned(Gusb_claim_interface) and
            Assigned(Gusb_release_interface) and Assigned(Gusb_bulk_write) and
            Assigned(Gusb_bulk_read);

  if not Result then
  begin
    Logger.Warning('[ANTPlus/libusb0] Required symbols missing in DLL');
    FreeLibrary(GLibUsb);
    GLibUsb := NilHandle;
  end
  else
    Logger.Info('[ANTPlus/libusb0] All required symbols resolved');
end;

function LastErrorText: string;
begin
  if Assigned(Gusb_strerror) then
    Result := string(AnsiString(Gusb_strerror()))
  else
    Result := '?';
end;

// ═══════════════════════════════════════════════════════════════
// TANTLibusb0Backend
// ═══════════════════════════════════════════════════════════════

constructor TANTLibusb0Backend.Create;
begin
  inherited Create;
  FDevHandle := nil;
  FIoLock := TCriticalSection.Create;
  FProductDesc := '';
  SetLength(FRxBuffer, 0);
end;

destructor TANTLibusb0Backend.Destroy;
begin
  if FOpened then Close;
  FreeAndNil(FIoLock);
  inherited;
end;

function TANTLibusb0Backend.ProductDescription: string;
begin
  if FProductDesc <> '' then
    Result := FProductDesc
  else
    Result := 'ANT USB stick (libusb-win32)';
end;

function TANTLibusb0Backend.RawBulkWrite(const ABytes: TBytes;
  ATimeoutMs: Cardinal): Boolean;
var
  Sent: Integer;
begin
  Result := False;
  if FDevHandle = nil then Exit;
  if Length(ABytes) = 0 then Exit;
  FIoLock.Enter;
  try
    Sent := Gusb_bulk_write(FDevHandle, EP_BULK_OUT, @ABytes[0],
      Length(ABytes), Integer(ATimeoutMs));
  finally
    FIoLock.Leave;
  end;
  if Sent = Length(ABytes) then
    Result := True
  else
    Logger.Warning(Format('[ANTPlus/libusb0] bulk_write returned %d (expected %d): %s',
      [Sent, Length(ABytes), LastErrorText]));
end;

function TANTLibusb0Backend.TryDecodeFromBuffer(out AMsg: TANTMessage): Boolean;
var
  Consumed: Integer;
  L: Integer;
  Decoded: Boolean;
begin
  Result := False;
  // Re-вход цикла на каждой итерации полезен потому что ANTDecodeMessage может
  // вернуть Decoded=False с Consumed=1 (пропуск garbage-байта до следующего
  // SYNC). Тогда крутимся дальше, пока либо распакуем фрейм, либо упрёмся в
  // отсутствие данных (Consumed=0).
  while Length(FRxBuffer) > 0 do
  begin
    Decoded := ANTDecodeMessage(FRxBuffer, 0, AMsg, Consumed);
    if Consumed = 0 then Exit;  // нужно ещё байт, нет прогресса
    L := Length(FRxBuffer);
    if Consumed >= L then
      SetLength(FRxBuffer, 0)
    else
    begin
      Move(FRxBuffer[Consumed], FRxBuffer[0], L - Consumed);
      SetLength(FRxBuffer, L - Consumed);
    end;
    if Decoded then Exit(True);
  end;
end;

procedure TANTLibusb0Backend.DrainStaleData;
const
  CHUNK = 64;
var
  TempBuf: array[0..CHUNK - 1] of Byte;
  Got, Total, I: Integer;
  HexDump: string;
begin
  // После Open() в стике могут быть байты от прошлой сессии — например, если
  // приложение убили без CLOSE_CHANNEL. Делаем 2-3 быстрых ReadPipe с маленьким
  // timeout чтобы вычистить буфер прежде чем посылать RESET_SYSTEM.
  Total := 0;
  HexDump := '';
  if FDevHandle = nil then Exit;
  repeat
    FIoLock.Enter;
    try
      Got := Gusb_bulk_read(FDevHandle, EP_BULK_IN, @TempBuf[0], CHUNK, 50);
    finally
      FIoLock.Leave;
    end;
    if Got > 0 then
    begin
      Inc(Total, Got);
      // Дампим первые ~32 байта для диагностики — больше не имеет смысла.
      for I := 0 to Got - 1 do
        if Length(HexDump) < 96 then
          HexDump := HexDump + IntToHex(TempBuf[I], 2) + ' ';
    end;
  until Got <= 0;
  if Total > 0 then
    Logger.Info(Format('[ANTPlus/libusb0] Drained %d stale bytes: %s',
      [Total, Trim(HexDump)]));
end;

function TANTLibusb0Backend.ResetAndInitialize: Boolean;
var
  Msg: TANTMessage;
  Bytes: TBytes;
  I: Integer;
  GotResponse: Boolean;
begin
  Result := False;

  // Step 1: RESET_SYSTEM. Сразу после write начинаем читать — libusb-win32
  // не буферизует данные в pipe пока bulk_read не активен, поэтому Sleep
  // здесь терял бы ответы стика. Пишем команду, и тут же 6×100мс readов
  // вычитывают всё что прилетит (STARTUP/RESPONSE_EVENT/мусор).
  FillChar(Msg, SizeOf(Msg), 0);
  Msg.MessageID := ANT_MSG_RESET_SYSTEM;
  Msg.PayloadLen := 1;
  Msg.Data[0] := 0;
  Bytes := ANTEncodeMessage(Msg);
  if not RawBulkWrite(Bytes, 200) then
  begin
    Logger.Error('[ANTPlus/libusb0] RESET_SYSTEM write failed');
    Exit;
  end;
  Logger.Info('[ANTPlus/libusb0] RESET_SYSTEM sent, draining response (up to 600ms)');

  // Step 2: вычитываем всё что прилетит за время reset'а. Стик может прислать:
  //   - STARTUP message ($6F) на новых ревизиях
  //   - RESPONSE_EVENT по reset на старых
  //   - старые остатки от предыдущей сессии
  // Мы это ВСЁ читаем (а не slепо drain'им через Sleep), что 1) не теряет
  // следующие ответы из-за пустого pipe и 2) даёт диагностику в логе.
  for I := 0 to 5 do
  begin
    if ReadMessage(Msg, 100) then
      Logger.Info(Format('[ANTPlus/libusb0] Post-reset msg: ID=$%.2X len=%d data[0..3]=%.2X %.2X %.2X %.2X',
        [Msg.MessageID, Msg.PayloadLen,
         Msg.Data[0], Msg.Data[1], Msg.Data[2], Msg.Data[3]]));
  end;

  // Step 3: NETWORK_KEY на network 0
  FillChar(Msg, SizeOf(Msg), 0);
  Msg.MessageID := ANT_MSG_NETWORK_KEY;
  Msg.PayloadLen := 9;
  Msg.Data[0] := ANTPLUS_NETWORK_NUMBER;
  Move(ANTPLUS_NETWORK_KEY[0], Msg.Data[1], 8);
  Bytes := ANTEncodeMessage(Msg);
  if not RawBulkWrite(Bytes, 200) then
  begin
    Logger.Error('[ANTPlus/libusb0] NETWORK_KEY write failed');
    Exit;
  end;
  Logger.Info('[ANTPlus/libusb0] NETWORK_KEY sent');

  // Step 4: ловим RESPONSE_EVENT. КРИТИЧНО — начинаем читать СРАЗУ после
  // write, без Sleep'а. libusb-win32 не буферизует данные в pipe пока read
  // не активен, и если стик ответит за 5-10мс (типично) пока мы спим, ответ
  // потеряется. for-loop делает 15 чтений по 100мс = до 1.5с total.
  GotResponse := False;
  for I := 0 to 14 do
  begin
    if not ReadMessage(Msg, 100) then Continue;
    Logger.Info(Format('[ANTPlus/libusb0] Post-init msg: ID=$%.2X len=%d data[0..3]=%.2X %.2X %.2X %.2X',
      [Msg.MessageID, Msg.PayloadLen,
       Msg.Data[0], Msg.Data[1], Msg.Data[2], Msg.Data[3]]));
    if (Msg.MessageID = ANT_MSG_RESPONSE_EVENT) and
       (Msg.PayloadLen >= 3) and
       (Msg.Data[1] = ANT_MSG_NETWORK_KEY) then
    begin
      if Msg.Data[2] = 0 then
        Logger.Info('[ANTPlus/libusb0] NETWORK_KEY accepted (RESPONSE_NO_ERROR)')
      else
        Logger.Warning(Format('[ANTPlus/libusb0] NETWORK_KEY response code=%d',
          [Msg.Data[2]]));
      GotResponse := True;
      Break;
    end;
  end;
  if not GotResponse then
    Logger.Warning('[ANTPlus/libusb0] No NETWORK_KEY ack seen — proceeding optimistically; '
      + 'real proof-of-life is when first FE-C broadcast arrives on a paired channel');

  Result := True;
end;

function TANTLibusb0Backend.Open: Boolean;
var
  Bus: PUsbBus;
  Dev, Found: PUsbDevice;
  vid, pid: Word;
  cfgRes, claimRes: Integer;
  ProductBuf: array[0..127] of AnsiChar;
  Got: Integer;
begin
  Result := False;
  if FOpened then Exit(True);

  if not LoadLibusb0 then Exit;

  Logger.Info('[ANTPlus/libusb0] usb_init + enumerate');
  Gusb_init();
  Gusb_find_busses();
  Gusb_find_devices();

  // Перебираем все шины и устройства, ищем Dynastream VID + поддерживаемый PID.
  // Берём ПЕРВЫЙ найденный — multiple sticks одновременно не поддерживаем
  // (архитектура TANTProvider всё равно крутится вокруг одного backend).
  Found := nil;
  Bus := Gusb_get_busses();
  while Bus <> nil do
  begin
    Dev := Bus^.devices;
    while Dev <> nil do
    begin
      vid := Dev^.descriptor.idVendor;
      pid := Dev^.descriptor.idProduct;
      if vid = ANT_USB_VID then
      begin
        Logger.Info(Format('[ANTPlus/libusb0] USB device VID=$%.4X PID=$%.4X bus=%s addr=%d',
          [vid, pid, AnsiString(Bus^.dirname), Dev^.devnum]));
        if (pid = ANT_USB_PID_USB_M_1) or
           (pid = ANT_USB_PID_USB_M_2) or
           (pid = ANT_USB_PID_USB_2) then
        begin
          Found := Dev;
          Break;
        end;
      end;
      Dev := Dev^.next;
    end;
    if Found <> nil then Break;
    Bus := Bus^.next;
  end;

  if Found = nil then
  begin
    Logger.Warning('[ANTPlus/libusb0] No Dynastream/Garmin ANT stick found on USB');
    Exit;
  end;

  // Открываем устройство
  FDevHandle := Gusb_open(Found);
  if FDevHandle = nil then
  begin
    Logger.Error('[ANTPlus/libusb0] usb_open failed: ' + LastErrorText);
    Exit;
  end;
  Logger.Info('[ANTPlus/libusb0] usb_open ok');

  // Configuration 1 (у ANT-стика всего одна, но это must-do для libusb)
  cfgRes := Gusb_set_configuration(FDevHandle, 1);
  if cfgRes < 0 then
    // Не fatal — некоторые драйверы на Windows возвращают ошибку, если
    // конфигурация уже выбрана.
    Logger.Warning(Format('[ANTPlus/libusb0] set_configuration=%d (continuing): %s',
      [cfgRes, LastErrorText]))
  else
    Logger.Info('[ANTPlus/libusb0] set_configuration(1) ok');

  // Захватываем интерфейс 0 — на нём бaulk-эндпойнты 0x01/0x81
  claimRes := Gusb_claim_interface(FDevHandle, 0);
  if claimRes < 0 then
  begin
    Logger.Error(Format('[ANTPlus/libusb0] claim_interface(0) failed: %d (%s)',
      [claimRes, LastErrorText]));
    Gusb_close(FDevHandle);
    FDevHandle := nil;
    Exit;
  end;
  Logger.Info('[ANTPlus/libusb0] claim_interface(0) ok');

  // Читаем product string descriptor (для красивого имени в логе/UI)
  if Assigned(Gusb_get_string_simple) and (Found^.descriptor.iProduct <> 0) then
  begin
    Got := Gusb_get_string_simple(FDevHandle, Found^.descriptor.iProduct,
      @ProductBuf[0], SizeOf(ProductBuf));
    if Got > 0 then
    begin
      SetString(FProductDesc, ProductBuf, Got);
      Logger.Info('[ANTPlus/libusb0] Product: ' + FProductDesc);
    end;
  end;

  // Чистим возможные остатки от прежней сессии (если приложение убили грубо)
  DrainStaleData;

  // RESET_SYSTEM + NETWORK_KEY handshake
  if not ResetAndInitialize then
  begin
    Logger.Error('[ANTPlus/libusb0] Initialization handshake failed');
    Gusb_release_interface(FDevHandle, 0);
    Gusb_close(FDevHandle);
    FDevHandle := nil;
    Exit;
  end;

  FOpened := True;
  Result := True;
  Logger.Info('[ANTPlus/libusb0] Backend ready');
end;

procedure TANTLibusb0Backend.Close;
begin
  if FDevHandle <> nil then
  begin
    Logger.Info('[ANTPlus/libusb0] Releasing interface and closing device');
    Gusb_release_interface(FDevHandle, 0);
    Gusb_close(FDevHandle);
    FDevHandle := nil;
  end;
  FOpened := False;
  SetLength(FRxBuffer, 0);
end;

function TANTLibusb0Backend.WriteMessage(const AMsg: TANTMessage): Boolean;
var
  Bytes: TBytes;
begin
  Result := False;
  if not FOpened then Exit;
  Bytes := ANTEncodeMessage(AMsg);
  Result := RawBulkWrite(Bytes, 100);
end;

function TANTLibusb0Backend.ReadMessage(out AMsg: TANTMessage;
  ATimeoutMs: Cardinal): Boolean;
const
  CHUNK = 64;
var
  TempBuf: array[0..CHUNK - 1] of Byte;
  Got, OldLen: Integer;
begin
  // 1) Сначала пробуем выдать что-то из накопленного буфера — bulk-read
  // часто отдаёт несколько ANT-фреймов разом.
  Result := TryDecodeFromBuffer(AMsg);
  if Result then Exit;

  // 2) Если в буфере не хватает данных — читаем из стика. Проверяем именно
  // FDevHandle, а не FOpened: FOpened ставится в True только в конце Open()
  // ПОСЛЕ ResetAndInitialize, и проверка `not FOpened` блокировала бы все
  // read'ы во время init-handshake'а — то есть мы никогда не видели бы
  // ответы на RESET_SYSTEM и NETWORK_KEY. claim_interface уже сделан к
  // этому моменту, pipe готов, читать можно.
  if FDevHandle = nil then Exit;
  FIoLock.Enter;
  try
    Got := Gusb_bulk_read(FDevHandle, EP_BULK_IN, @TempBuf[0], CHUNK,
      Integer(ATimeoutMs));
  finally
    FIoLock.Leave;
  end;
  if Got < 0 then
  begin
    // libusb-win32 возвращает -116 (ETIMEDOUT) на каждый bulk_read когда нет
    // данных — это НЕ ошибка, это нормальный timeout (классический libusb
    // возвращает 0 в этом случае, а libusb-win32 — POSIX-style errno).
    // Все остальные негативные коды (-9 EPIPE/halted, -110 EIO и т.п.) —
    // настоящие проблемы, их логируем.
    if (Got <> -116) and (GetTickCount64-FLastReadWarningTick>=5000) then
    begin
      FLastReadWarningTick:=GetTickCount64;
      Logger.Warning(Format('[ANTPlus/libusb0] bulk_read returned %d: %s',
        [Got, LastErrorText]));
    end;
    if Got<>-116 then Sleep(10); { A removed USB stick must not busy-loop. }
    Exit;
  end;
  if Got = 0 then Exit;  // timeout — без шума в лог

  // 3) Дописываем в буфер и пробуем снова.
  OldLen := Length(FRxBuffer);
  SetLength(FRxBuffer, OldLen + Got);
  Move(TempBuf[0], FRxBuffer[OldLen], Got);
  Result := TryDecodeFromBuffer(AMsg);
end;

initialization
  // Регистрируем backend сразу при загрузке юнита. Если libusb0.dll отсутствует
  // или стик не воткнут, ANTPlusAvailable вернёт False и провайдер не создастся
  // — но регистрация безопасна, тестовый Open закроет всё за собой.
  RegisterANTUsbBackendClass(TANTLibusb0Backend);

finalization
  if GLibUsb <> NilHandle then
  begin
    FreeLibrary(GLibUsb);
    GLibUsb := NilHandle;
  end;

{$endif}

end.

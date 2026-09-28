{ GameThreadWatch — хлебные крошки шатдауна. Пишет в общий CastleLog. }
unit GameThreadWatch;

{$mode objfpc}{$H+}

interface

procedure ThreadWatch(const AMsg: string);

implementation

uses
  SysUtils, CastleLog;

procedure ThreadWatch(const AMsg: string);
begin
  try
    WritelnLog('ThreadWatch',
      '[tid ' + IntToStr(PtrUInt(GetCurrentThreadId)) + '] ' + AMsg);
  except
  end;
end;

end.

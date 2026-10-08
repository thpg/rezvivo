unit McpJsonString;
{$mode objfpc}{$H+}

{ A tool result contains JSON inside a JSON string. FPC 3.2.2 escapes every
  quote by appending to a growing string. With an OS large-block allocator
  this repeatedly maps/copies the entire megabyte response. Allocate once;
  keep the standard fpjson object tree and escaping rules. }
interface
uses fpjson;
type
  TMcpJSONString = class(TJSONString)
  protected
    function GetAsJSON: TJSONStringType; override;
  public
    function Clone: TJSONData; override;
  end;

implementation
uses SysUtils;

function TMcpJSONString.GetAsJSON: TJSONStringType;
const HexDigits = '0123456789ABCDEF';
var S:TJSONStringType; I,J,N:SizeInt; C:Char;
begin
  S:=AsString;N:=Length(S)+2;
  for I:=1 to Length(S) do begin
    C:=S[I];
    if N>High(SizeInt)-5 then raise ERangeError.Create('JSON string too large');
    case C of
      '"','\',#8,#9,#10,#12,#13: Inc(N);
      '/': if StrictEscaping then Inc(N);
      #0..#7,#11,#14..#31: Inc(N,5);
    end;
  end;
  SetLength(Result,N);Result[1]:='"';J:=2;
  for I:=1 to Length(S) do begin
    C:=S[I];
    case C of
      '"','\': begin Result[J]:='\';Result[J+1]:=C;Inc(J,2) end;
      '/': begin
        if StrictEscaping then begin Result[J]:='\';Inc(J) end;
        Result[J]:='/';Inc(J);
      end;
      #8,#9,#10,#12,#13: begin
        Result[J]:='\';
        case C of
          #8:Result[J+1]:='b'; #9:Result[J+1]:='t'; #10:Result[J+1]:='n';
          #12:Result[J+1]:='f'; #13:Result[J+1]:='r';
        end;
        Inc(J,2);
      end;
      #0..#7,#11,#14..#31: begin
        Result[J]:='\';Result[J+1]:='u';Result[J+2]:='0';Result[J+3]:='0';
        Result[J+4]:=HexDigits[(Ord(C) shr 4)+1];Result[J+5]:=HexDigits[(Ord(C) and 15)+1];
        Inc(J,6);
      end;
      else begin Result[J]:=C;Inc(J) end;
    end;
  end;
  Result[J]:='"';
  SetCodePage(RawByteString(Result),CP_UTF8,False);
end;

function TMcpJSONString.Clone:TJSONData;
begin Result:=TMcpJSONString.Create(AsString) end;

end.

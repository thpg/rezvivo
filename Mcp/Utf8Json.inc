{ Shared by stdio and source catalogs. No application/OSM dependency in MCP. }
function ParseUtf8Json(const S: RawByteString): TJSONData;
var T,E: RawByteString; I,N,J: SizeInt; V,W:Integer; U: UnicodeString;
begin
  { FPC 3.2.2 jsonscanner uses String[4] for TWO escaped UTF-16 code units.
    Two CJK characters require six UTF-8 bytes. Expand non-ASCII Unicode
    before that scanner; preserve JSON control and quote escapes. }
  if Pos('\u',S)=0 then Exit(GetJSON(S));
  { Decoding six/twelve ASCII escape bytes never grows the UTF-8 input.
    Reserve once: appending one byte at a time was quadratic under OSHeap. }
  SetLength(T,Length(S)); I:=1;J:=1;
  while I<=Length(S) do begin
    if (S[I]='\') and (I<Length(S)) then begin
      if (S[I+1]='u') and (I+5<=Length(S)) and TryStrToInt('$'+Copy(S,I+2,4),V) and (V>=128) then begin
        N:=6; U:=WideChar(V);
        if (V >= $D800) and (V <= $DBFF) then begin
          if (I+11>Length(S)) or (Copy(S,I+6,2)<>'\u') or
            not TryStrToInt('$'+Copy(S,I+8,4),W) or (W<$DC00) or (W>$DFFF) then
            raise Exception.Create('Invalid JSON surrogate pair');
          U:=U+WideChar(W); N:=12;
        end else if (V >= $DC00) and (V <= $DFFF) then raise Exception.Create('Invalid JSON surrogate');
        E:=UTF8Encode(U);Move(E[1],T[J],Length(E));Inc(J,Length(E));Inc(I,N);Continue;
      end;
      T[J]:=S[I];T[J+1]:=S[I+1];Inc(J,2);Inc(I,2);
    end else begin T[J]:=S[I];Inc(J);Inc(I) end;
  end;
  SetLength(T,J-1);
  SetCodePage(T,CP_UTF8,False);
  Result:=GetJSON(T);
end;

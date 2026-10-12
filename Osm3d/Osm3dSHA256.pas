unit Osm3dSHA256;
{$mode objfpc}{$H+}{$Q-}{$R-}
interface
uses SysUtils;
function SHA256Bytes(const Data: TBytes): string;
implementation
const K: array[0..63] of LongWord = (
  $428a2f98,$71374491,$b5c0fbcf,$e9b5dba5,$3956c25b,$59f111f1,$923f82a4,$ab1c5ed5,
  $d807aa98,$12835b01,$243185be,$550c7dc3,$72be5d74,$80deb1fe,$9bdc06a7,$c19bf174,
  $e49b69c1,$efbe4786,$0fc19dc6,$240ca1cc,$2de92c6f,$4a7484aa,$5cb0a9dc,$76f988da,
  $983e5152,$a831c66d,$b00327c8,$bf597fc7,$c6e00bf3,$d5a79147,$06ca6351,$14292967,
  $27b70a85,$2e1b2138,$4d2c6dfc,$53380d13,$650a7354,$766a0abb,$81c2c92e,$92722c85,
  $a2bfe8a1,$a81a664b,$c24b8b70,$c76c51a3,$d192e819,$d6990624,$f40e3585,$106aa070,
  $19a4c116,$1e376c08,$2748774c,$34b0bcb5,$391c0cb3,$4ed8aa4a,$5b9cca4f,$682e6ff3,
  $748f82ee,$78a5636f,$84c87814,$8cc70208,$90befffa,$a4506ceb,$bef9a3f7,$c67178f2);
function R(V: LongWord; N: Byte): LongWord; inline;
begin Result := (V shr N) or (V shl (32-N)) end;
function SHA256Bytes(const Data: TBytes): string;
var H: array[0..7] of LongWord; W: array[0..63] of LongWord;
  Block: array[0..63] of Byte;
  A,B,C,D,E,F,G,J,T1,T2: LongWord;
  Offset, N, Total: SizeInt; I: Integer; Bits: QWord;
begin
  H[0]:=$6a09e667;H[1]:=$bb67ae85;H[2]:=$3c6ef372;H[3]:=$a54ff53a;
  H[4]:=$510e527f;H[5]:=$9b05688c;H[6]:=$1f83d9ab;H[7]:=$5be0cd19;
  N:=Length(Data); Total:=((N+9+63) div 64)*64; Bits:=QWord(N)*8; Offset:=0;
  while Offset<Total do begin
    FillChar(Block,SizeOf(Block),0);
    for I:=0 to 63 do
      if Offset+I<N then Block[I]:=Data[Offset+I]
      else if Offset+I=N then Block[I]:=$80;
    if Offset+64=Total then
      for I:=0 to 7 do Block[63-I]:=Byte(Bits shr (I*8));
    for I:=0 to 15 do W[I]:=(LongWord(Block[I*4]) shl 24) or
      (LongWord(Block[I*4+1]) shl 16) or (LongWord(Block[I*4+2]) shl 8) or Block[I*4+3];
    for I:=16 to 63 do W[I]:=W[I-16]+(R(W[I-15],7) xor R(W[I-15],18) xor (W[I-15] shr 3))+
      W[I-7]+(R(W[I-2],17) xor R(W[I-2],19) xor (W[I-2] shr 10));
    A:=H[0];B:=H[1];C:=H[2];D:=H[3];E:=H[4];F:=H[5];G:=H[6];J:=H[7];
    for I:=0 to 63 do begin
      T1:=J+(R(E,6) xor R(E,11) xor R(E,25))+((E and F) xor ((not E) and G))+K[I]+W[I];
      T2:=(R(A,2) xor R(A,13) xor R(A,22))+((A and B) xor (A and C) xor (B and C));
      J:=G;G:=F;F:=E;E:=D+T1;D:=C;C:=B;B:=A;A:=T1+T2;
    end;
    H[0]:=H[0]+A;H[1]:=H[1]+B;H[2]:=H[2]+C;H[3]:=H[3]+D;
    H[4]:=H[4]+E;H[5]:=H[5]+F;H[6]:=H[6]+G;H[7]:=H[7]+J;
    Inc(Offset,64);
  end;
  Result:=''; for I:=0 to 7 do Result:=Result+LowerCase(IntToHex(H[I],8));
end;
end.

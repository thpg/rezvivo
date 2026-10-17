unit VegetationAtlas;
{$mode objfpc}{$H+}
interface
uses SysUtils,Math;
const VEGETATION_ENVELOPE_MIN_SIZE=16;
type
  TAtlasBytes=array of Byte;
  TAtlasLevel=record Size,Layers:Integer;Pixels:TAtlasBytes;end;
  TAtlasLevels=array of TAtlasLevel;
  TEnvelopePoint=packed record X,Y:Single;end;
  TCardEnvelope=packed record Points:array[0..7]of TEnvelopePoint;Area:Single;Enabled:Boolean;end;
function AtlasMipLevels(const Pixels:TAtlasBytes;Size,Layers:Integer;MinSize:Integer=1):TAtlasLevels;
function AtlasLevelBytes(const Levels:TAtlasLevels):Int64;
function EnvelopeMaxMip(Size:Integer):Integer;
function CardEnvelope(const Levels:TAtlasLevels;FirstLayer,LayerCount,Stride:Integer):TCardEnvelope;
function FullCardEnvelope:TCardEnvelope;
function EnvelopeContains(const E:TCardEnvelope;X,Y:Double;Tolerance:Double=1e-6):Boolean;
function CardEnvelopeGLSL:string;
implementation
function AtlasMipLevels(const Pixels:TAtlasBytes;Size,Layers,MinSize:Integer):TAtlasLevels;
var L,N,S,X,Y,Z,C,Offset,A,B:Integer;
begin
  Result:=nil;
  if(Size<1)or((Size and(Size-1))<>0)or(Layers<1)or(Length(Pixels)<>Size*Size*Layers*4)then raise EArgumentException.Create('Invalid atlas mip input');
  if(MinSize<1)or((MinSize and(MinSize-1))<>0)then raise EArgumentException.Create('Invalid atlas mip limit');
  N:=1;S:=Size;while S>MinSize do begin Inc(N);S:=Max(1,S div 2)end;
  SetLength(Result,N);Result[0].Size:=Size;Result[0].Layers:=Layers;Result[0].Pixels:=Pixels;
  for L:=1 to N-1 do begin
    S:=Result[L-1].Size;N:=Max(1,S div 2);Result[L].Size:=N;Result[L].Layers:=Layers;
    SetLength(Result[L].Pixels,N*N*Layers*4);
    { Average premultiplied RGBA, exactly as the existing UNORM mip chain;
      never unpremultiply or apply a second coverage/colour correction. }
    for Z:=0 to Layers-1 do for Y:=0 to N-1 do for X:=0 to N-1 do begin
      Offset:=((Z*N+Y)*N+X)*4;A:=((Z*S+Y*2)*S+X*2)*4;B:=A+S*4;
      for C:=0 to 3 do Result[L].Pixels[Offset+C]:=(Integer(Result[L-1].Pixels[A+C])+
        Result[L-1].Pixels[A+4+C]+Result[L-1].Pixels[B+C]+Result[L-1].Pixels[B+4+C]+2)div 4;
    end;
  end;
end;
function AtlasLevelBytes(const Levels:TAtlasLevels):Int64;
var L:Integer;
begin Result:=0;for L:=0 to High(Levels)do Inc(Result,Length(Levels[L].Pixels));end;
function EnvelopeMaxMip(Size:Integer):Integer;
begin Result:=0;while Size>VEGETATION_ENVELOPE_MIN_SIZE do begin Size:=Size div 2;Inc(Result)end;end;
function FullCardEnvelope:TCardEnvelope;
const P:array[0..7]of TEnvelopePoint=((X:0;Y:0),(X:0.5;Y:0),(X:1;Y:0),(X:1;Y:0.5),
  (X:1;Y:1),(X:0.5;Y:1),(X:0;Y:1),(X:0;Y:0.5));
begin Result:=Default(TCardEnvelope);Result.Points:=P;Result.Area:=1;end;
function CardEnvelope(const Levels:TAtlasLevels;FirstLayer,LayerCount,Stride:Integer):TCardEnvelope;
const NX:array[0..7]of Double=(1,1,0,-1,-1,-1,0,1);
      NY:array[0..7]of Double=(0,1,1,1,0,-1,-1,-1);
var Support:array[0..7]of Double;P,Q:array[0..15]of TEnvelopePoint;
    L,Z,X,Y,D,I,J,N,M,S,Layer:Integer;U,V,Padding,A,B,T,Area:Double;Any:Boolean;
begin
  Result:=FullCardEnvelope;if Length(Levels)=0 then Exit;
  for D:=0 to 7 do Support[D]:=-1e30;Any:=False;
  for L:=0 to Min(EnvelopeMaxMip(Levels[0].Size),High(Levels))do begin
    S:=Levels[L].Size;
    { Two texels cover bilinear support, quad helper derivatives and rounding.
      For trilinear sampling the next coarser mip is included in this union. }
    Padding:=2.0/S;
    for Z:=0 to LayerCount-1 do begin
      Layer:=FirstLayer+Z*Stride;if(Layer<0)or(Layer>=Levels[L].Layers)then raise ERangeError.Create('Envelope layer');
      for Y:=0 to S-1 do for X:=0 to S-1 do if Levels[L].Pixels[((Layer*S+Y)*S+X)*4+3]>0 then begin
        Any:=True;U:=(X+0.5)/S;V:=(Y+0.5)/S;
        for D:=0 to 7 do Support[D]:=Max(Support[D],NX[D]*U+NY[D]*V+Padding*(Abs(NX[D])+Abs(NY[D])));
      end;
    end;
  end;
  if not Any then Exit;
  P[0].X:=0;P[0].Y:=0;P[1].X:=1;P[1].Y:=0;P[2].X:=1;P[2].Y:=1;P[3].X:=0;P[3].Y:=1;N:=4;
  for D:=0 to 7 do begin
    M:=0;
    for I:=0 to N-1 do begin
      J:=(I+1)mod N;A:=NX[D]*P[I].X+NY[D]*P[I].Y-Support[D];B:=NX[D]*P[J].X+NY[D]*P[J].Y-Support[D];
      if A<=0 then begin Q[M]:=P[I];Inc(M)end;
      if(A<0)<>(B<0)then begin T:=A/(A-B);Q[M].X:=P[I].X+(P[J].X-P[I].X)*T;Q[M].Y:=P[I].Y+(P[J].Y-P[I].Y)*T;Inc(M)end;
    end;
    N:=M;P:=Q;
  end;
  if(N<3)or(N>8)then Exit;
  Area:=0;for I:=0 to N-1 do begin J:=(I+1)mod N;Area:=Area+P[I].X*P[J].Y-P[J].X*P[I].Y end;
  Result.Area:=Abs(Area)*0.5;Result.Enabled:=Result.Area<0.985;
  for I:=0 to 7 do Result.Points[I]:=P[Min(I,N-1)];
end;
function EnvelopeContains(const E:TCardEnvelope;X,Y:Double;Tolerance:Double):Boolean;
var I,J:Integer;
begin
  for I:=0 to 7 do begin J:=(I+1)mod 8;
    if(E.Points[J].X-E.Points[I].X)*(Y-E.Points[I].Y)-(E.Points[J].Y-E.Points[I].Y)*(X-E.Points[I].X)<-Tolerance then Exit(False);
  end;Result:=True;
end;
function CardEnvelopeGLSL:string;
begin
  Result:=
    'int envelopeIndex(int id){int t=id/3;return id%3==0?0:t+(id%3);}'#10+
    'vec2 fullEnvelopeUV(int id){const vec2 p[8]=vec2[8](vec2(0,0),vec2(.5,0),vec2(1,0),vec2(1,.5),vec2(1,1),vec2(.5,1),vec2(0,1),vec2(0,.5));return p[envelopeIndex(id)];}'#10+
    { Bound inverse projective Jacobian over the entire card. C0/Cu/Cv are
      clip coordinates for UV=(0,0), U direction, V direction. No depth-only
      radius approximation: grazing cards, near clipping and uncertain mips
      keep the full quad. Includes an extra safety factor for helper quads. }
    'bool envelopeFootprint(vec4 c0,vec4 cu,vec4 cv,vec2 viewport,float texSize){'#10+
    ' float wMax=0.0,wMin=1e30;vec4 a=vec4(0);'#10+
    ' float detH=dot(vec3(cu.x,cu.y,cu.w),cross(vec3(cv.x,cv.y,cv.w),vec3(c0.x,c0.y,c0.w)));'#10+
    ' if(abs(detH)<1e-12 || min(viewport.x,viewport.y)<1.0)return false;'#10+
    ' for(int i=0;i<4;i++){vec4 q=c0+cu*float(i&1)+cv*float(i>>1);wMax=max(wMax,q.w);wMin=min(wMin,q.w);'#10+
    ' a=max(a,abs(vec4(cv.y*q.w-q.y*cv.w,cv.x*q.w-q.x*cv.w,cu.y*q.w-q.y*cu.w,cu.x*q.w-q.x*cu.w)));}'#10+
    ' if(wMin<=0.0 || wMax>2.0*wMin)return false;'#10+
    ' vec2 d=vec2(length(a.xz)*2.0/viewport.x,length(a.yw)*2.0/viewport.y)*(wMax/abs(detH))*texSize;'#10+
    { Only mip levels down to 16x16 have a proven support envelope. Guard
      by 2 for helper lanes at the edge and FP roundoff. }
    ' return max(d.x,d.y)*2.0<=texSize/16.0;'#10+
    '}'#10;
end;
end.

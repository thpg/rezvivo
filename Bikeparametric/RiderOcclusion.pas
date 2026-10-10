unit RiderOcclusion;
{$mode objfpc}{$H+}
interface
uses SysUtils, Math, CastleVectors, X3DNodes, X3DFields, RiderBodyParameters;
type
  TRiderJointQuery = function(const Name: string; out P: TVector3): Boolean of object;
  TRiderSkinQuery = function(const Name:string;out M:TMatrix4):Boolean of object;
  TRiderOcclusion = class
  private
    FCapsules: TMFVec4f;
    FStrength: TSFFloat;
    FPrevious, FStart, FTarget: array[0..13] of TVector4;
    FElapsed: Single;
    FPoseSamples: QWord;
    FValid: Boolean;
    FValues: TVector4List;
    procedure SetStrength(const Value: Single);
    function GetStrength: Single;
  public
    constructor Create(Effect: TEffectNode);
    destructor Destroy; override;
    procedure Update(Query: TRiderJointQuery; const ParentToRig: TMatrix4;
      const Body: TRiderBodyParameters; const Dt: Single);
    procedure Invalidate;
    property Strength: Single read GetStrength write SetStrength;
    property PoseSamples: QWord read FPoseSamples;
  end;
const
  { Evaluated after deformation, including the engine's cached GPU skin path.
    Coordinates stay near the model origin, independent of distance travelled.
    Only position is interpolated here. Use the final material normal in the
    fragment stage: clothing can replace the geometric normal at pocket seams. }
  RiderOcclusionVS =
    '#ifndef GL_ES' + #10 + 'uniform mat4 castle_ModelViewMatrix;' + #10 + '#endif' + #10 +
    '#ifdef CASTLE_CACHE_DEFORMATION' + #10 +
    'varying vec3 castle_CachedPosition;' + #10 +
    '#endif' + #10 +
    'varying vec3 riderAoPosition;' + #10 +
    'void PLUG_vertex_eye_space(const vec4 v,const vec3 n){' + #10 +
    '#ifdef CASTLE_CACHE_DEFORMATION' + #10 +
    // Written by the engine before the eye-space hook, both when deforming
    // the original vertices and when drawing their transform-feedback cache.
    ' riderAoPosition=castle_CachedPosition;' + #10 +
    '#else' + #10 +
    ' riderAoPosition=(inverse(castle_ModelViewMatrix)*v).xyz;' + #10 +
    '#endif' + #10 +
    '}' + #10;
  RiderOcclusionFS =
    'uniform vec4 riderAoCapsules[14];uniform float riderAoStrength;' + #10 +
    'uniform mat4 castle_ModelViewMatrix;' + #10 +
    'varying vec3 riderAoPosition;float riderAoFade=0.0;' + #10 +
    'void PLUG_fragment_eye_space(const vec4 v,inout vec3 n){' + #10 +
    ' riderAoFade=riderAoStrength*(1.0-smoothstep(18.0,35.0,length(v.xyz)));' + #10 +
    '}' + #10 +
    'float riderIndirectVisibility(vec3 normalEye){' + #10 +
    ' if(riderAoFade<=0.0)return 1.0;' + #10 +
    ' vec3 n=normalize(transpose(mat3(castle_ModelViewMatrix))*normalEye);float visibility=1.0;' + #10 +
    ' for(int i=0;i<7;i++){' + #10 +
    '  vec4 ca=riderAoCapsules[i*2],cb=riderAoCapsules[i*2+1];' + #10 +
    '  vec3 a=ca.xyz,b=cb.xyz,ab=b-a;' + #10 +
    '  float t=clamp(dot(riderAoPosition-a,ab)/max(dot(ab,ab),1e-8),0.0,1.0);' + #10 +
    '  vec3 d=mix(a,b,t)-riderAoPosition;float invDistance=inversesqrt(max(dot(d,d),1e-10));' + #10 +
    '  float radius=mix(ca.w,cb.w,t);' + #10 +
    // Projected solid-angle estimate with a smooth horizon crossing. Capsules
    // are broad internal proxies, not a traced visibility solution. The own
    // convex part stays behind its normal and therefore does not darken itself.
    '  float aperture=clamp(radius*invDistance,0.0,1.0),c=dot(n,d)*invDistance;' + #10 +
    '  float horizon=clamp((c+aperture)/(1.0+aperture),0.0,1.0);' + #10 +
    '  float local=aperture*aperture*horizon;' + #10 +
    '  visibility*=1.0-clamp(local,0.0,0.75);' + #10 +
    ' }' + #10 +
    ' return mix(1.0,max(visibility,0.35),riderAoFade);' + #10 +
    '}' + #10;
implementation
constructor TRiderOcclusion.Create(Effect: TEffectNode);
var I: Integer; V: Single;
begin
  inherited Create;
  FCapsules:=TMFVec4f.Create(Effect,True,'riderAoCapsules',[]);
  for I:=0 to 13 do FCapsules.Items.Add(TVector4.Zero);
  Effect.AddCustomField(FCapsules);
  V:=0.75;if GetEnvironmentVariable('REZVIVO_RIDER_SELF_OCCLUSION')='0' then V:=0;
  FStrength:=TSFFloat.Create(Effect,True,'riderAoStrength',V);Effect.AddCustomField(FStrength);
  FValues:=TVector4List.Create;
end;
destructor TRiderOcclusion.Destroy;
begin FValues.Free;inherited end;
function TRiderOcclusion.GetStrength: Single;
begin Result:=FStrength.Value end;
procedure TRiderOcclusion.Invalidate;
begin FValid:=False end;
procedure TRiderOcclusion.SetStrength(const Value: Single);
begin
  if (Strength<=0) and (Value>0) then FValid:=False;
  FStrength.Send(EnsureRange(Value,0,1));
end;
procedure TRiderOcclusion.Update(Query: TRiderJointQuery; const ParentToRig: TMatrix4;
  const Body: TRiderBodyParameters; const Dt: Single);
const Interval = 1.0/30.0;
  Names: array[0..10] of string=('Pelvis','Spine01','Spine02',
  'L_Thigh','R_Thigh','L_Calf','R_Calf','L_Upperarm','R_Upperarm','L_Forearm','R_Forearm');
var P: array[0..10] of TVector3; A,B: array[0..6] of TVector4;
  I,Side,Hip,Knee,Shoulder,Elbow: Integer; V,Up,Across,ForwardDir,C: TVector3;
  Scale,Fat,Muscle,Lean,Thickness,Alpha: Single; Changed,Exact: Boolean;
  procedure Capsule(Index:Integer; const Start,Finish:TVector3;R0,R1:Single);
  begin A[Index]:=Vector4(Start.X,Start.Y,Start.Z,R0);B[Index]:=Vector4(Finish.X,Finish.Y,Finish.Z,R1) end;
begin
  if (Strength<=0) or not Assigned(Query) then Exit;
  { Soft indirect visibility does not need a second exact limb solve at every
    uncapped display frame. Interpolate 30 Hz joint samples, one sample behind.
    Dt=0 is an explicit pose/seek/editor sample and must remain exact. }
  Exact:=(not FValid) or (Dt<=0) or (Dt>0.2);
  FElapsed:=FElapsed+Max(Dt,0);
  if Exact or (FElapsed>=Interval) then
  begin
  for I:=0 to High(P) do begin
    if not Query(Names[I],V) then Exit;
    P[I]:=ParentToRig.MultPoint(V);
  end;
  Up:=P[1]-P[0];Across:=P[3]-P[4];
  if (Up.LengthSqr<1e-8) or (Across.LengthSqr<1e-8) then Exit;
  Inc(FPoseSamples);
  Up:=Up.Normalize;Across:=Across.Normalize;ForwardDir:=TVector3.CrossProduct(Across,Up).Normalize;
  Scale:=EnsureRange(((P[3]-P[5]).Length+(P[4]-P[6]).Length)/0.88,0.65,1.4);
  RiderBodyShapeWeights(Body,Fat,Muscle,Lean);
  Thickness:=1+0.22*Max(Fat,0)+0.12*Max(Muscle,0);
  Capsule(0,P[0]+Up*(0.10*Scale),P[2],0.105*Scale*Thickness,0.11*Scale*Thickness);
  for Side:=0 to 1 do begin
    Hip:=3+Side;Knee:=5+Side;Shoulder:=7+Side;Elbow:=9+Side;
    C:=P[Hip]-Across*((1-2*Side)*0.014*Scale);
    Capsule(1+Side,C-ForwardDir*(0.025*Scale)-Up*(0.005*Scale),
      C-ForwardDir*(0.050*Scale)+Up*(0.025*Scale),0.070*Scale*Thickness,0.075*Scale*Thickness);
    Capsule(3+Side,P[Hip]+(P[Knee]-P[Hip])*0.18,P[Hip]+(P[Knee]-P[Hip])*0.84,
      0.070*Scale*Thickness,0.047*Scale*Thickness);
    Capsule(5+Side,P[Shoulder]+(P[Elbow]-P[Shoulder])*0.12,P[Elbow],
      0.043*Scale*Thickness,0.029*Scale*Thickness);
  end;
  FStart:=FTarget;
  for I:=0 to 6 do begin FTarget[I]:=A[I];FTarget[7+I]:=B[I] end;
  if Exact then FStart:=FTarget;
  FElapsed:=0;
  end;
  if Exact then Alpha:=1 else Alpha:=Min(FElapsed/Interval,1);
  for I:=0 to 6 do begin
    A[I]:=FStart[I]+(FTarget[I]-FStart[I])*Alpha;
    B[I]:=FStart[7+I]+(FTarget[7+I]-FStart[7+I])*Alpha;
  end;
  Changed:=not FValid;
  for I:=0 to 6 do
    if ((A[I]-FPrevious[I]).LengthSqr>1e-10) or
       ((B[I]-FPrevious[7+I]).LengthSqr>1e-10) then Changed:=True;
  if not Changed then Exit;
  FValues.Clear;
  for I:=0 to 6 do begin
    FPrevious[I]:=A[I];FPrevious[7+I]:=B[I];FValues.Add(A[I]);FValues.Add(B[I]);
  end;
  FCapsules.Send(FValues);FValid:=True;
end;
end.

unit GameRideCarousel;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses Classes,SysUtils,fpjson,CastleUIControls,CastleControls,CastleKeysMouse,
  CastleVectors,CastleRectangles,CastleViewport,CastleScene,CastleGLImages,X3DNodes;
type
  TRideCarouselItem=class
    Title,Info,ImageUrl:string;
    Revision:Integer;
  end;
  TRideCarouselSlot=class
    Scene:TCastleScene;
    Border:TUnlitMaterialNode;
    Texture:TImageTextureNode;
    Picture:TSwitchNode;
    Title,Info:TTextNode;
    ItemIndex,Revision,Highlight:Integer;
    ImageUrl:string;
    Angle:Single;
    destructor Destroy;override;
  end;
  { Perspective cards tangent to a vertical wheel. Seven reusable render
    slots bound texture/geometry cost independently of the library size.
    Scrolling never changes the clicked selection. }
  TRideCarousel=class(TCastleUserInterfaceFont)
  private
    FItems:TList;
    FOrder,FOrderPosition:array of Integer;
    FFilterText:string;
    FDistanceFilter:Integer;
    procedure RebuildOrder;
  private
    FViewport:TCastleViewport;
    FImage:TDrawableImage;
    FMultisample:TGLRenderToTexture;
    FRenderSamples,FDepthBits:LongInt;
    FImageDirty:Boolean;
    FWheelRadius:Single;
    FImageRenderCount:QWord;
    FFrame:TCastleScene;
    FSlots:array[0..6]of TRideCarouselSlot;
    FSelected,FHovered,FPressedIndex:Integer;
    FPosition,FTarget,FVelocity,FDownY,FLastY,FDownPosition:Single;
    FDownPoint:TVector2;
    FDown,FDragged,FVisualDirty:Boolean;
    FLastTick:QWord;
    FOnChange:TNotifyEvent;
    function Wrap(Index:Integer):Integer;
    function Delta(Index:Integer):Single;
    function AngleStep:Single;
    function StepPixels:Single;
    function Inside(const P:TVector2):Boolean;
    function HitCard(const P:TVector2):Integer;
    function CardPoint(Slot:TRideCarouselSlot;X,Y:Single):TVector3;
    function ProjectPoint(const P:TVector3):TVector2;
    procedure CreateSlot(Slot:TRideCarouselSlot);
    procedure CreateFrame;
    procedure UpdateProjection;
    procedure FreeRenderImage;
    procedure RenderImage;
    procedure RefreshSlots;
    procedure SetHover(Index:Integer);
  public
    constructor Create(AOwner:TComponent);override;
    destructor Destroy;override;
    procedure Resize;override;
    procedure Clear;
    function AddItem(const Title,Info,ImagePath:string):Integer;
    procedure SetImage(Index:Integer;const ImagePath:string);
    procedure SetInfo(Index:Integer;const Info:string);
    procedure SetFilter(const Text:string;DistanceFilter:Integer=0);
    function ItemTitle(Index:Integer):string;
    function ItemInfo(Index:Integer):string;
    procedure Select(Index:Integer;Animate:Boolean=False;Notify:Boolean=False);
    procedure MoveBy(Steps:Integer);
    procedure SelectCentered;
    procedure CancelGesture;
    procedure Update(const SecondsPassed:Single;var HandleInput:Boolean);override;
    procedure Render;override;
    procedure GLContextOpen;override;
    procedure GLContextClose;override;
    function Press(const Event:TInputPressRelease):Boolean;override;
    function Release(const Event:TInputPressRelease):Boolean;override;
    function Motion(const Event:TInputMotion):Boolean;override;
    function Diagnostics:TJSONObject;
    property Selected:Integer read FSelected;
    property OnChange:TNotifyEvent read FOnChange write FOnChange;
  end;
implementation
uses Math,UiTranslations,CastleColors,CastleURIUtils,CastleCameras,CastleTransform,
  CastleImages,CastleFonts,CastleTextureImages,GameMenuTheme,
  CastleGL,CastleGLUtils,CastleRenderContext,GameAudio;
const CardWidth=3.40;CardHeight=1.80;CardFront=0.045;
  WheelDiameterRatio=1.20;CarouselRenderScale=2;

procedure FilterCardTexture(const Texture:TAbstractTexture2DNode);
var Props:TTexturePropertiesNode;
begin
  if Texture.TextureProperties<>nil then Exit;
  Props:=TTexturePropertiesNode.Create;
  Props.MinificationFilter:=minLinearMipmapLinear;
  Props.MagnificationFilter:=magLinear;Props.AnisotropicDegree:=8;
  Props.GenerateMipMaps:=True;Texture.TextureProperties:=Props;
end;

function Material(const Color:TVector3):TUnlitMaterialNode;
begin Result:=TUnlitMaterialNode.Create;Result.EmissiveColor:=Color;end;
function Quad(const X,Y,W,H,Z:Single;Mat:TUnlitMaterialNode;Texture:TImageTextureNode=nil):TShapeNode;
var C:TCoordinateNode;UV:TTextureCoordinateNode;G:TIndexedTriangleSetNode;A:TAppearanceNode;
begin
  C:=TCoordinateNode.Create;C.SetPoint([Vector3(X,Y,Z),Vector3(X+W,Y,Z),Vector3(X+W,Y+H,Z),Vector3(X,Y+H,Z)]);
  UV:=TTextureCoordinateNode.Create;UV.SetPoint([Vector2(0,0),Vector2(1,0),Vector2(1,1),Vector2(0,1)]);
  G:=TIndexedTriangleSetNode.Create;G.Coord:=C;G.TexCoord:=UV;G.SetIndex([0,1,2,0,2,3]);G.Solid:=True;
  A:=TAppearanceNode.Create;A.Material:=Mat;A.Texture:=Texture;
  Result:=TShapeNode.Create;Result.Appearance:=A;Result.Geometry:=G;
end;
destructor TRideCarouselSlot.Destroy;
begin Scene.Free;inherited;end;
constructor TRideCarousel.Create(AOwner:TComponent);
var I:Integer;
begin
  inherited;FItems:=TList.Create;FSelected:=-1;FHovered:=-1;FPressedIndex:=-1;
  Width:=380;Height:=620;FontSize:=15;CapturesEvents:=True;
  FViewport:=TCastleViewport.Create(Self);FViewport.EnableUIScaling:=False;
  FViewport.Transparent:=False;FViewport.BackgroundColor:=MenuBackground;FViewport.AutoCamera:=False;
  FViewport.CapturesEvents:=False;FViewport.Items.UseHeadlight:=hlOff;
  FViewport.Camera:=TCastleCamera.Create(FViewport);FViewport.Items.Add(FViewport.Camera);
  FViewport.Camera.Perspective.FieldOfView:=Pi/4;FViewport.Camera.Perspective.FieldOfViewAxis:=faVertical;
  FViewport.Camera.ProjectionNear:=0.1;FViewport.Camera.ProjectionFar:=50;
  { This viewport is rendered only into the cached supersampled image. }
  for I:=0 to High(FSlots)do begin FSlots[I]:=TRideCarouselSlot.Create;CreateSlot(FSlots[I]);end;
  FVisualDirty:=True;Resize;
end;
destructor TRideCarousel.Destroy;
var I:Integer;
begin
  Clear;for I:=0 to High(FSlots)do FreeAndNil(FSlots[I]);
  FreeRenderImage;FreeAndNil(FFrame);FreeAndNil(FItems);inherited;
end;

procedure TRideCarousel.GLContextOpen;
begin inherited;FViewport.GLContextOpen;FImageDirty:=True;end;
procedure TRideCarousel.GLContextClose;
begin
  FreeRenderImage;
  if FViewport<>nil then FViewport.GLContextClose;
  inherited;
end;
procedure TRideCarousel.CreateSlot(Slot:TRideCarouselSlot);
var Root:TX3DRootNode;Shape:TShapeNode;Box:TBoxNode;App:TAppearanceNode;
  function LabelNode(const Y,Size:Single;const Color:TVector3):TTextNode;
  var Style:TFontStyleNode;Sh:TShapeNode;Ap:TAppearanceNode;T:TTransformNode;
  begin
    Style:=TFontStyleNode.Create;Style.Family:=ffSans;Style.Size:=Size;Style.Justify:=fjBegin;
    Style.CustomFont:=TCastleFont(MenuFont(Size>0.15));
    Result:=TTextNode.Create;Result.FontStyle:=Style;Result.FdString.Send([' ']);
    FilterCardTexture(Result.FontTextureNode);
    Ap:=TAppearanceNode.Create;Ap.Material:=Material(Color);Sh:=TShapeNode.Create;Sh.Geometry:=Result;Sh.Appearance:=Ap;
    T:=TTransformNode.Create;T.Translation:=Vector3(-CardWidth/2+0.14,Y,CardFront+0.012);
    T.AddChildren(Sh);Root.AddChildren(T);
  end;
begin
  Root:=TX3DRootNode.Create;Slot.Border:=Material(Vector3(0.26,0.39,0.46));
  Root.AddChildren(Quad(-CardWidth/2,-CardHeight/2,CardWidth,CardHeight,CardFront,Slot.Border));
  Root.AddChildren(Quad(-CardWidth/2+0.04,-CardHeight/2+0.04,CardWidth-0.08,CardHeight-0.08,
    CardFront+0.004,Material(Vector3(0.055,0.085,0.12))));
  Box:=TBoxNode.Create;Box.Size:=Vector3(CardWidth,CardHeight,0.055);
  App:=TAppearanceNode.Create;App.Material:=Material(Vector3(0.025,0.043,0.060));
  Shape:=TShapeNode.Create;Shape.Geometry:=Box;Shape.Appearance:=App;Root.AddChildren(Shape);
  Root.AddChildren(Quad(-CardWidth/2+0.14,-0.24,CardWidth-0.28,0.99,CardFront+0.008,Material(Vector3(0.15,0.22,0.29))));
  Slot.Texture:=TImageTextureNode.Create;Slot.Texture.RepeatS:=False;Slot.Texture.RepeatT:=False;
  FilterCardTexture(Slot.Texture);
  Slot.Picture:=TSwitchNode.Create;Slot.Picture.WhichChoice:=-1;
  Slot.Picture.AddChildren(Quad(-CardWidth/2+0.14,-0.24,CardWidth-0.28,0.99,CardFront+0.010,
    Material(Vector3(1,1,1)),Slot.Texture));Root.AddChildren(Slot.Picture);
  Slot.Title:=LabelNode(-0.48,0.18,Vector3(0.94,0.97,1));Slot.Info:=LabelNode(-0.72,0.13,Vector3(0.61,0.74,0.83));
  Slot.Scene:=TCastleScene.Create(Self);Slot.Scene.Load(Root,True);
  Slot.Scene.ProcessEvents:=False;Slot.Scene.Collides:=False;Slot.Scene.Pickable:=False;
  Slot.Scene.Exists:=False;FViewport.Items.Add(Slot.Scene);
  Slot.ItemIndex:=-1;Slot.Revision:=-1;Slot.Highlight:=-1;
end;
procedure TRideCarousel.CreateFrame;
const Segments=192;Sides=8;
var P,C:array of TVector3;Index:array of LongInt;Ring,I,J,K,A,B,N:Integer;
  Theta,Phi,R,X,Shade:Single;Root:TX3DRootNode;Coords:TCoordinateNode;Colors:TColorNode;
  G:TIndexedTriangleSetNode;S:TShapeNode;Ap:TAppearanceNode;
begin
  FreeAndNil(FFrame);
  { Round rims expose the common depth and axis; one mesh for both rims. }
  SetLength(P,2*Segments*Sides);SetLength(C,Length(P));SetLength(Index,Length(P)*6);K:=0;
  for Ring:=0 to 1 do for I:=0 to Segments-1 do for J:=0 to Sides-1 do begin
    N:=(Ring*Segments+I)*Sides+J;Theta:=2*Pi*I/Segments;Phi:=2*Pi*J/Sides;
    R:=FWheelRadius+0.046*Sin(Phi);X:=(2*Ring-1)*(CardWidth/2+0.09)+0.046*Cos(Phi);
    P[N]:=Vector3(X,R*Sin(Theta),R*Cos(Theta)-FWheelRadius);
    Shade:=0.35+0.65*Max(0,Cos(Theta))*(0.72+0.28*Cos(Phi));C[N]:=Vector3(0.23,0.39,0.47)*Shade;
    A:=(Ring*Segments+(I+1)mod Segments)*Sides+J;B:=(Ring*Segments+I)*Sides+(J+1)mod Sides;
    Index[K]:=N;Index[K+1]:=A;Index[K+2]:=B;Index[K+3]:=B;Index[K+4]:=A;
    Index[K+5]:=(Ring*Segments+(I+1)mod Segments)*Sides+(J+1)mod Sides;Inc(K,6);
  end;
  Coords:=TCoordinateNode.Create;Coords.SetPoint(P);Colors:=TColorNode.Create;Colors.SetColor(C);
  G:=TIndexedTriangleSetNode.Create;G.Coord:=Coords;G.Color:=Colors;G.ColorPerVertex:=True;G.Solid:=False;G.SetIndex(Index);
  Ap:=TAppearanceNode.Create;Ap.Material:=Material(Vector3(1,1,1));S:=TShapeNode.Create;S.Geometry:=G;S.Appearance:=Ap;
  Root:=TX3DRootNode.Create;Root.AddChildren(S);FFrame:=TCastleScene.Create(Self);FFrame.Load(Root,True);
  FFrame.Collides:=False;FFrame.Pickable:=False;FViewport.Items.Add(FFrame);
end;
procedure TRideCarousel.Resize;
begin
  inherited;UpdateProjection;
end;
procedure TRideCarousel.UpdateProjection;
var Aspect,ViewHeight,Distance,K,Radius:Single;Eye:TVector3;W,H:Integer;
begin
  if(FViewport=nil)or(EffectiveHeight<1)or(EffectiveWidth<1)then Exit;
  W:=Max(1,Round(RenderRect.Width))*CarouselRenderScale;
  H:=Max(1,Round(RenderRect.Height))*CarouselRenderScale;
  if(FFrame<>nil)and(FViewport.Width=W)and(FViewport.Height=H)then Exit;
  FViewport.Width:=W;FViewport.Height:=H;
  Aspect:=FViewport.Width/FViewport.Height;ViewHeight:=(CardWidth+0.70)/Aspect;
  Distance:=ViewHeight/(2*Tan(Pi/8));Eye:=Vector3(0.68,0,Distance);
  { The wheel recedes behind the front card. Solve its perspective silhouette
    for a diameter 20% taller than the viewing area, rather than fitting it all. }
  K:=WheelDiameterRatio*Tan(Pi/8);
  Radius:=Distance*K*(K+Sqrt(1+K*K));
  if Abs(FWheelRadius-Radius)>0.001 then begin FWheelRadius:=Radius;CreateFrame;end;
  FViewport.Camera.ProjectionFar:=Distance+2*FWheelRadius+4;
  FViewport.Camera.SetWorldView(Eye,(-Eye).Normalize,Vector3(0,1,0));
  FVisualDirty:=True;FImageDirty:=True;
end;
procedure TRideCarousel.Clear;
var I:Integer;
begin
  CancelGesture;for I:=0 to FItems.Count-1 do TObject(FItems[I]).Free;
  FItems.Clear;FSelected:=-1;FHovered:=-1;FPosition:=0;FTarget:=0;FVisualDirty:=True;
  SetLength(FOrder,0);SetLength(FOrderPosition,0);
  for I:=0 to High(FSlots)do if FSlots[I]<>nil then begin
    FSlots[I].Scene.Exists:=False;FSlots[I].Texture.FdUrl.Send([]);FSlots[I].ImageUrl:='';FSlots[I].ItemIndex:=-1;
  end;
end;
function TRideCarousel.AddItem(const Title,Info,ImagePath:string):Integer;
var Item:TRideCarouselItem;
begin
  Item:=TRideCarouselItem.Create;Item.Title:=Title;Item.Info:=Info;
  Result:=FItems.Add(Item);SetImage(Result,ImagePath);RebuildOrder;FVisualDirty:=True;
end;
procedure TRideCarousel.SetImage(Index:Integer;const ImagePath:string);
var Item:TRideCarouselItem;
begin
  if(Index<0)or(Index>=FItems.Count)then Exit;Item:=TRideCarouselItem(FItems[Index]);
  if ImagePath=''then Item.ImageUrl:=''else Item.ImageUrl:=FilenameToURISafe(ImagePath);
  Inc(Item.Revision);FVisualDirty:=True;
end;
procedure TRideCarousel.SetInfo(Index:Integer;const Info:string);
var Item:TRideCarouselItem;
begin
  if(Index<0)or(Index>=FItems.Count)then Exit;Item:=TRideCarouselItem(FItems[Index]);
  if Item.Info=Info then Exit;Item.Info:=Info;Inc(Item.Revision);FVisualDirty:=True;
  if FDistanceFilter<>0 then RebuildOrder;
end;
function TRideCarousel.ItemTitle(Index:Integer):string;
begin
  Result:='';if(Index>=0)and(Index<FItems.Count)then Result:=TRideCarouselItem(FItems[Index]).Title;
end;
function TRideCarousel.ItemInfo(Index:Integer):string;
begin
  Result:='';if(Index>=0)and(Index<FItems.Count)then Result:=TRideCarouselItem(FItems[Index]).Info;
end;
procedure TRideCarousel.SetFilter(const Text:string;DistanceFilter:Integer);
var Query:string;
begin
  Query:=UTF8Encode(UnicodeLowerCase(UTF8Decode(Trim(Text))));
  if(FFilterText=Query)and(FDistanceFilter=DistanceFilter)then Exit;
  FFilterText:=Query;FDistanceFilter:=DistanceFilter;RebuildOrder;
end;
procedure TRideCarousel.RebuildOrder;
var NewOrder:array of Integer;I,J,N,Code:Integer;Item:TRideCarouselItem;
  Number,Haystack:string;Distance:Double;Changed,Match:Boolean;
begin
  SetLength(NewOrder,FItems.Count);N:=0;
  for I:=0 to FItems.Count-1 do begin
    Item:=TRideCarouselItem(FItems[I]);
    Haystack:=UTF8Encode(UnicodeLowerCase(UTF8Decode(Item.Title)));
    Match:=(FFilterText='')or(Pos(FFilterText,Haystack)>0);
    if Match and(FDistanceFilter<>0)then begin
      Number:='';J:=1;
      while(J<=Length(Item.Info))and not(Item.Info[J]in['0'..'9'])do Inc(J);
      while(J<=Length(Item.Info))and(Item.Info[J]in['0'..'9','.',','])do begin
        if Item.Info[J]=','then Number:=Number+'.'else Number:=Number+Item.Info[J];Inc(J);
      end;
      Val(Number,Distance,Code);
      Match:=(Code=0)and(((FDistanceFilter=1)and(Distance<=25))or
        ((FDistanceFilter=2)and(Distance>25)));
    end;
    if Match then begin NewOrder[N]:=I;Inc(N);end;
  end;
  Changed:=N<>Length(FOrder);
  if not Changed then for I:=0 to N-1 do if NewOrder[I]<>FOrder[I]then begin Changed:=True;Break;end;
  if not Changed then Exit;
  SetLength(NewOrder,N);FOrder:=NewOrder;SetLength(FOrderPosition,FItems.Count);
  for I:=0 to FItems.Count-1 do FOrderPosition[I]:=-1;
  for I:=0 to N-1 do FOrderPosition[FOrder[I]]:=I;
  CancelGesture;FPosition:=0;
  if(FSelected>=0)and(FSelected<FItems.Count)and(FOrderPosition[FSelected]>=0)then
    FPosition:=FOrderPosition[FSelected];
  FTarget:=FPosition;FVisualDirty:=True;
end;
function TRideCarousel.Wrap(Index:Integer):Integer;
begin if Length(FOrder)=0 then Exit(-1);Result:=((Index mod Length(FOrder))+Length(FOrder))mod Length(FOrder);end;
function TRideCarousel.Delta(Index:Integer):Single;
begin
  Result:=0;
  if(Index<0)or(Index>=Length(FOrderPosition))or(FOrderPosition[Index]<0)then Exit;
  Result:=FOrderPosition[Index]-FPosition;
  if Length(FOrder)>0 then Result:=Result-Floor(Result/Length(FOrder)+0.5)*Length(FOrder);
end;
function TRideCarousel.AngleStep:Single;
begin
  { Keep neighbouring cards visible when only a few worlds are in the list. }
  Result:=Min(0.55,Max(0.30,Max((CardHeight+0.20)/Max(1,FWheelRadius),
    1.8/Max(1,Length(FOrder)))));
end;
function TRideCarousel.StepPixels:Single;
var A,B:TVector2;
begin
  if(FViewport.EffectiveHeight<1)or(FViewport.EffectiveWidth<1)then Exit(100);
  A:=ProjectPoint(Vector3(0,0,CardFront));
  B:=ProjectPoint(Vector3(0,FWheelRadius*Sin(AngleStep),FWheelRadius*(Cos(AngleStep)-1)));
  Result:=Max(28,Abs(B.Y-A.Y));
end;
function TRideCarousel.Inside(const P:TVector2):Boolean;
var R:TFloatRectangle;
begin R:=RenderRect;Result:=(P.X>=R.Left)and(P.X<=R.Right)and(P.Y>=R.Bottom)and(P.Y<=R.Top);end;
function TRideCarousel.CardPoint(Slot:TRideCarouselSlot;X,Y:Single):TVector3;
begin
  Result:=Slot.Scene.Translation+Vector3(X,Y*Cos(Slot.Angle)+CardFront*Sin(Slot.Angle),
    -Y*Sin(Slot.Angle)+CardFront*Cos(Slot.Angle));
end;
function TRideCarousel.ProjectPoint(const P:TVector3):TVector2;
var Q:TVector2;R:TFloatRectangle;
begin
  Q:=FViewport.PositionFromWorld(P);R:=RenderRect;
  Result:=R.LeftBottom+Vector2(Q.X*R.Width/FViewport.Width,Q.Y*R.Height/FViewport.Height);
end;
function TRideCarousel.HitCard(const P:TVector2):Integer;
var O,D,N,C,H:TVector3;Den,T,Best,Y:Single;I:Integer;S:TRideCarouselSlot;R:TFloatRectangle;
  ViewProjection,InverseViewProjection:TMatrix4;ScreenPoint:TVector3;
begin
  Result:=-1;if not Inside(P)or(RenderRect.Width<1)or(RenderRect.Height<1)then Exit;
  R:=RenderRect;
  { Use the exact matrix of the rendered image. The viewport is detached from
    the on-screen hierarchy, so its container-space ray conversion is unsuitable. }
  ViewProjection:=FViewport.Camera.ProjectionMatrix*FViewport.Camera.Matrix;
  if not ViewProjection.TryInverse(InverseViewProjection)then Exit;
  ScreenPoint:=Vector3(2*(P.X-R.Left)/R.Width-1,2*(P.Y-R.Bottom)/R.Height-1,-1);
  O:=InverseViewProjection.MultPoint(ScreenPoint);ScreenPoint.Z:=1;
  D:=(InverseViewProjection.MultPoint(ScreenPoint)-O).Normalize;Best:=MaxSingle;
  for I:=0 to High(FSlots)do begin
    S:=FSlots[I];if not S.Scene.Exists then Continue;
    N:=Vector3(0,Sin(S.Angle),Cos(S.Angle));C:=CardPoint(S,0,0);
    Den:=TVector3.DotProduct(D,N);if Den>=-0.00001 then Continue;
    T:=TVector3.DotProduct(C-O,N)/Den;if(T<=0)or(T>=Best)then Continue;
    H:=O+D*T-C;Y:=H.Y*Cos(S.Angle)-H.Z*Sin(S.Angle);
    if(Abs(H.X)<=CardWidth/2)and(Abs(Y)<=CardHeight/2)then begin Result:=S.ItemIndex;Best:=T;end;
  end;
end;
procedure TRideCarousel.SetHover(Index:Integer);
begin
  if FHovered=Index then Exit;FHovered:=Index;FVisualDirty:=True;
  if Index>=0 then Cursor:=mcHand else Cursor:=mcDefault;
end;
procedure TRideCarousel.RefreshSlots;
var I,J,K,Index,Count,H:Integer;Angle:Single;Slot:TRideCarouselSlot;Item:TRideCarouselItem;Color:TVector3;
  Desired:array[0..6]of Integer;Keep:Boolean;
  procedure SetLabel(Node:TTextNode;const Value:string);
  const Ellipsis:UTF8String='…';
  var Style:TFontStyleNode;Limit:Single;U:UnicodeString;L,R,M,Cut:Integer;S:string;
  begin
    { CGE currently ignores Text.maxExtent. Fit the actual font metrics,
      shortening at a Unicode boundary instead of stretching the glyphs. }
    Style:=TFontStyleNode(Node.FontStyle);Limit:=(CardWidth-0.28)*Style.Font.Height/Style.Size;
    if Style.Font.TextWidth(Value)<=Limit then S:=Value else begin
      U:=UTF8Decode(Value);L:=0;R:=Length(U);
      while L<R do begin
        M:=(L+R+1)div 2;Cut:=M;
        if(Cut>0)and(Ord(U[Cut])>=$D800)and(Ord(U[Cut])<=$DBFF)then Dec(Cut);
        if Style.Font.TextWidth(UTF8Encode(Copy(U,1,Cut))+Ellipsis)<=Limit then L:=M else R:=M-1;
      end;
      if(L>0)and(Ord(U[L])>=$D800)and(Ord(U[L])<=$DBFF)then Dec(L);
      S:=UTF8Encode(Copy(U,1,L))+Ellipsis;
    end;
    Node.FdString.Send([S]);
  end;
begin
  if not FVisualDirty then Exit;FVisualDirty:=False;FImageDirty:=True;Count:=Min(Length(FOrder),Length(FSlots));
  if FFrame<>nil then FFrame.Exists:=Count>0;
  for I:=0 to Count-1 do Desired[I]:=FOrder[Wrap(Round(FPosition)+I-Count div 2)];
  for J:=0 to High(FSlots)do begin
    Keep:=False;
    for I:=0 to Count-1 do if FSlots[J].ItemIndex=Desired[I]then begin Keep:=True;Break;end;
    if not Keep then FSlots[J].Scene.Exists:=False;
  end;
  for I:=0 to Count-1 do begin
    Index:=Desired[I];Slot:=nil;
    for J:=0 to High(FSlots)do if FSlots[J].ItemIndex=Index then begin Slot:=FSlots[J];Break;end;
    if Slot=nil then for J:=0 to High(FSlots)do begin
      Keep:=False;
      for K:=0 to Count-1 do if FSlots[J].ItemIndex=Desired[K]then begin Keep:=True;Break;end;
      if not Keep then begin Slot:=FSlots[J];Break;end;
    end;
    if Slot=nil then Continue;
    Angle:=-Delta(Index)*AngleStep;Slot.Scene.Exists:=Abs(Angle)<1.43;
    Item:=TRideCarouselItem(FItems[Index]);Slot.Scene.BeginChangesSchedule;
    try
      if(Slot.ItemIndex<>Index)or(Slot.Revision<>Item.Revision)then begin
        SetLabel(Slot.Title,Item.Title);SetLabel(Slot.Info,Item.Info);
        if Slot.ImageUrl<>Item.ImageUrl then begin
          if Item.ImageUrl=''then Slot.Texture.FdUrl.Send([])else Slot.Texture.FdUrl.Send([Item.ImageUrl]);
          Slot.ImageUrl:=Item.ImageUrl;
        end;
        if Item.ImageUrl=''then Slot.Picture.WhichChoice:=-1 else Slot.Picture.WhichChoice:=0;
        Slot.ItemIndex:=Index;Slot.Revision:=Item.Revision;
      end;
      H:=Ord(Index=FSelected)+2*Ord(Index=FHovered);
      if H<>Slot.Highlight then begin
        case H of
          1:Color:=Vector3(0.333,0.851,0.918);2:Color:=Vector3(0.46,0.92,0.97);3:Color:=Vector3(0.64,0.97,1);
          else Color:=Vector3(0.26,0.39,0.46);
        end;
        Slot.Border.EmissiveColor:=Color;Slot.Highlight:=H;
      end;
    finally Slot.Scene.EndChangesSchedule;end;
    Slot.Angle:=Angle;Slot.Scene.Rotation:=Vector4(1,0,0,-Angle);
    Slot.Scene.Translation:=Vector3(0,FWheelRadius*Sin(Angle),FWheelRadius*(Cos(Angle)-1));
  end;
  VisibleChange([chRender]);
end;
procedure TRideCarousel.Select(Index:Integer;Animate:Boolean;Notify:Boolean);
var Changed:Boolean;
begin
  if(Index<0)or(Index>=FItems.Count)then begin FSelected:=-1;FVisualDirty:=True;Exit;end;
  Changed:=Index<>FSelected;
  { OnChange can echo Select back. Preserve the animation in that case;
    clicking the already selected card should still bring it to the centre. }
  if not Changed and not Notify then Exit;
  FSelected:=Index;FVisualDirty:=True;
  CancelGesture;FTarget:=FPosition+Delta(Index);if not Animate then FPosition:=FTarget;
  { An explicit click confirms the map even when this card was already selected.
    Programmatic restoration uses Notify=False. }
  if Notify then PlayMenuClick;
  if Notify and Assigned(FOnChange)then FOnChange(Self);
end;
procedure TRideCarousel.MoveBy(Steps:Integer);
begin
  if Length(FOrder)<2 then Exit;FDown:=False;FDragged:=False;FVelocity:=0;FTarget:=Round(FTarget)+Steps;
end;
procedure TRideCarousel.CancelGesture;
begin FDown:=False;FDragged:=False;FVelocity:=0;FTarget:=Round(FPosition);SetHover(-1);end;
procedure TRideCarousel.Update(const SecondsPassed:Single;var HandleInput:Boolean);
var Dt,OldPosition,Shift:Single;
begin
  inherited;Dt:=Min(SecondsPassed,0.05);OldPosition:=FPosition;
  if not FDown then begin
    if Abs(FVelocity)>0.12 then begin
      FPosition:=FPosition+FVelocity*Dt;FVelocity:=FVelocity*Exp(-7*Dt);FTarget:=Round(FPosition+FVelocity/7);
    end else begin
      FVelocity:=0;FPosition:=FPosition+(FTarget-FPosition)*(1-Exp(-18*Dt));
      if Abs(FPosition-FTarget)<0.002 then begin
        FPosition:=FTarget;
        if Length(FOrder)>0 then begin Shift:=Floor(FPosition/Length(FOrder))*Length(FOrder);FPosition:=FPosition-Shift;FTarget:=FTarget-Shift;end;
      end;
    end;
  end;
  if OldPosition<>FPosition then FVisualDirty:=True;RefreshSlots;
  { A stationary cursor also hot-tracks a wheel rotating with inertia. }
  if(Container<>nil)and HandleInput and not FDragged then SetHover(HitCard(Container.MousePosition))else SetHover(-1);
  RefreshSlots;
end;
function TRideCarousel.Press(const Event:TInputPressRelease):Boolean;
begin
  Result:=inherited;if not Inside(Event.Position)then Exit;
  if Event.IsMouseWheel(mwUp)then begin MoveBy(-1);Exit(True);end;
  if Event.IsMouseWheel(mwDown)then begin MoveBy(1);Exit(True);end;
  if Event.IsMouseButton(buttonLeft)then begin
    FDown:=True;FDragged:=False;FVelocity:=0;FTarget:=FPosition;FDownPoint:=Event.Position;
    FDownY:=Event.Position.Y;FLastY:=FDownY;FDownPosition:=FPosition;
    FPressedIndex:=HitCard(Event.Position);FLastTick:=GetTickCount64;Exit(True);
  end;
end;
procedure TRideCarousel.SelectCentered;
begin
  if Length(FOrder)>0 then Select(FOrder[Wrap(Round(FTarget))],True,True);
end;
function TRideCarousel.Motion(const Event:TInputMotion):Boolean;
var T:QWord;Dt,V:Single;
begin
  Result:=inherited;
  if not FDown then begin SetHover(HitCard(Event.Position));Exit(Inside(Event.Position));end;
  if(Event.Position-FDownPoint).Length>6*UIScale then FDragged:=True;
  if FDragged and(Length(FOrder)>1)then begin
    T:=GetTickCount64;Dt:=Max(0.008,(T-FLastTick)/1000);V:=(Event.Position.Y-FLastY)/StepPixels/Dt;
    FVelocity:=EnsureRange(FVelocity*0.45+V*0.55,-8,8);
    FPosition:=FDownPosition+(Event.Position.Y-FDownY)/StepPixels;FTarget:=FPosition;
    FLastTick:=T;FLastY:=Event.Position.Y;FVisualDirty:=True;SetHover(-1);RefreshSlots;
  end;
  Result:=True;
end;
function TRideCarousel.Release(const Event:TInputPressRelease):Boolean;
begin
  Result:=inherited;if not Event.IsMouseButton(buttonLeft)or not FDown then Exit;
  FDown:=False;Result:=True;
  if FDragged then begin
    if GetTickCount64-FLastTick>100 then FVelocity:=0;FTarget:=Round(FPosition+FVelocity/7);
  end else begin
    FVelocity:=0;FTarget:=FPosition;
    if(FPressedIndex>=0)and(FPressedIndex=HitCard(Event.Position))then Select(FPressedIndex,True,True);
  end;
  FDragged:=False;SetHover(HitCard(Event.Position));
end;
procedure TRideCarousel.FreeRenderImage;
begin
  FreeAndNil(FMultisample);FreeAndNil(FImage);
  FRenderSamples:=0;FDepthBits:=0;FImageDirty:=True;
end;
procedure TRideCarousel.RenderImage;
var W,H,MaxSamples,SourceFramebuffer:LongInt;OldViewport:TRectangle;
  WasMultisample:Boolean;
begin
  W:=Round(FViewport.Width);H:=Round(FViewport.Height);
  if (FImage<>nil)and((FImage.Width<>W)or(FImage.Height<>H))then FreeRenderImage;
  if FImage=nil then begin
    FImage:=TDrawableImage.Create(W,H,TRGBImage,True);FImageDirty:=True;
    { The window has no MSAA. Supersampling alone leaves long, shallow card
      edges visibly stepped. Give this small cached viewport its own samples. }
    if GLFeatures.FBOMultiSampling and GLFeatures.FramebufferBlit then begin
      glGetIntegerv(GL_MAX_SAMPLES,@MaxSamples);
      if MaxSamples>=2 then begin
        FMultisample:=TGLRenderToTexture.Create(W,H);
        FMultisample.Buffer:=tbNone;
        FMultisample.MultiSampling:=Min(4,MaxSamples);
        FMultisample.GLContextOpen;
      end;
    end;
  end;
  if not FImageDirty then Exit;
  TDrawableImage.BatchingFlush;
  if FMultisample<>nil then begin
    OldViewport:=RenderContext.Viewport;
    WasMultisample:=glIsEnabled(GL_MULTISAMPLE)<>0;
    glEnable(GL_MULTISAMPLE);
    FMultisample.RenderBegin;
    try
      if FRenderSamples=0 then begin
        glGetIntegerv(GL_SAMPLES,@FRenderSamples);glGetIntegerv(GL_DEPTH_BITS,@FDepthBits);
      end;
      Container.RenderControl(FViewport,Rectangle(0,0,W,H));
      { Resolve at the same size: OpenGL cannot scale during an MSAA resolve.
        The subsequent linear 2:1 reduction also smooths textures and text. }
      glGetIntegerv(GL_FRAMEBUFFER_BINDING,@SourceFramebuffer);
      FImage.RenderToImageBegin;
      try
        glBindFramebuffer(GL_READ_FRAMEBUFFER,SourceFramebuffer);
        glBlitFramebuffer(0,0,W,H,0,0,W,H,GL_COLOR_BUFFER_BIT,GL_NEAREST);
      finally FImage.RenderToImageEnd;end;
    finally
      FMultisample.RenderEnd;
      RenderContext.Viewport:=OldViewport;
      if not WasMultisample then glDisable(GL_MULTISAMPLE);
    end;
  end else begin
    FImage.RenderToImageBegin;
    try
      if FRenderSamples=0 then begin
        FRenderSamples:=1;glGetIntegerv(GL_DEPTH_BITS,@FDepthBits);
      end;
      Container.RenderControl(FViewport,Rectangle(0,0,W,H));
    finally FImage.RenderToImageEnd;end;
  end;
  FImageDirty:=False;Inc(FImageRenderCount);
end;
procedure TRideCarousel.Render;
var R:TFloatRectangle;
begin
  inherited;R:=RenderRect;
  if Length(FOrder)=0 then begin
    Font.Print(R.Left+12,R.Bottom+R.Height*0.5,White,UiText('No matching routes'));Exit;
  end;
  if (Container=nil)or(R.Width<1)or(R.Height<1)then Exit;
  { Parent layout and UI scale may finish changing after our Resize callback. }
  UpdateProjection;RefreshSlots;
  RenderImage;
  FImage.Draw(R);
end;
function TRideCarousel.Diagnostics:TJSONObject;
var A,Corners:TJSONArray;I,J:Integer;R:TFloatRectangle;S:TRideCarouselSlot;P:TVector2;L,B,RR,T,Angle:Single;
const CX:array[0..3]of Single=(-0.5,0.5,0.5,-0.5);CY:array[0..3]of Single=(-0.5,-0.5,0.5,0.5);
begin
  RefreshSlots;R:=RenderRect;Result:=TJSONObject.Create(['count',FItems.Count,'visible_count',Length(FOrder),'filter',FFilterText,'selected',FSelected,'hovered',FHovered,
    'position',FPosition,'target',FTarget,'dragging',FDown,'renderer','perspective-3d','orientation','vertical',
    'rect',TJSONArray.Create([R.Left,R.Bottom,R.Width,R.Height]),
    'antialiasing','2x2-ssaa','wheel_radius',FWheelRadius,'image_renders',Int64(FImageRenderCount),
    'msaa_samples',FRenderSamples,'depth_bits',FDepthBits,
    'render_size',TJSONArray.Create([Round(FViewport.Width),Round(FViewport.Height)])]);A:=TJSONArray.Create;
  if Container<>nil then begin
    Result.Add('mouse',TJSONArray.Create([Container.MousePosition.X,Container.MousePosition.Y]));
    Result.Add('mouse_hit',HitCard(Container.MousePosition));
  end;
  B:=MaxSingle;T:=-MaxSingle;
  for I:=0 to 1 do for J:=0 to 191 do begin
    Angle:=2*Pi*J/192;
    P:=ProjectPoint(Vector3((2*I-1)*(CardWidth/2+0.09),
      FWheelRadius*Sin(Angle),FWheelRadius*(Cos(Angle)-1)));
    B:=Min(B,P.Y);T:=Max(T,P.Y);
  end;
  Result.Add('wheel_projected_height',T-B);
  for I:=0 to High(FSlots)do begin
    S:=FSlots[I];if not S.Scene.Exists then Continue;
    L:=MaxSingle;B:=MaxSingle;RR:=-MaxSingle;T:=-MaxSingle;Corners:=TJSONArray.Create;
    for J:=0 to 3 do begin
      P:=ProjectPoint(CardPoint(S,CX[J]*CardWidth,CY[J]*CardHeight));
      Corners.Add(TJSONArray.Create([P.X,P.Y]));L:=Min(L,P.X);B:=Min(B,P.Y);RR:=Max(RR,P.X);T:=Max(T,P.Y);
    end;
    P:=ProjectPoint(CardPoint(S,0,0));
    A.Add(TJSONObject.Create(['index',S.ItemIndex,'title',TRideCarouselItem(FItems[S.ItemIndex]).Title,
      'visible',True,'angle',S.Angle,'corners',Corners,'center',TJSONArray.Create([P.X,P.Y]),
      'rect',TJSONArray.Create([L,B,RR-L,T-B])]));
  end;
  Result.Add('items',A);
end;
end.

program TreeTileClassificationTests;
{$mode objfpc}{$H+}
uses Classes,SysUtils,Math,TreeModel,Osm3dTileX3D,Osm3dTileBinary,
  Osm3dGeoMath,Osm3dGeoTileGrid,Osm3dProceduralTreeData,Osm3dDreamWorld;
procedure Check(OK:Boolean;const Msg:string);
begin if not OK then raise Exception.Create(Msg);end;
procedure CheckPhotoHeight;
var LL:TLatLon;A,B,C:TProceduralTreeTag;T:TTreeInstance;P:TTreeParams;H:Integer;
const Tags='{"natural":"tree","genus":"Betula"}';
begin
  LL:=TLatLon.Make(55.768,37.426);
  A:=ClassifyTreeTag(Tags,LL,False);
  B:=ClassifyTreeTag(Tags,LL,False,False,0,0);
  Check(A.TypePlusOne=B.TypePlusOne,'ordinary OSM growth stage unchanged');
  for H:=6 to 12 do begin
    B:=ClassifyTreeTag(Tags,LL,False,False,0,H);
    T:=Default(TTreeInstance);T.Position:=TreeIdentity(LL);T.TypeCode:=B.TypePlusOne-1;
    P:=ResolveTreeParams(T,DefaultTreeParams(T.Species));
    Check(Abs(P.Height-H)<0.7,'photo height must reach procedural tree and generated LOD');
    Check(T.Species=tsBirch,'photo growth retains species');
    Check(TreeTypeVariant(T.TypeCode)=TreeTypeVariant(A.TypePlusOne-1),'photo growth retains taxon');
    C:=ClassifyTreeTag(Tags,LL,False,False,0,H);
    Check(B.TypePlusOne=C.TypePlusOne,'photo growth deterministic');
  end;
  A:=ClassifyTreeTag('{"genus":"Betula","age":"40"}',LL,False,False,0,6);
  Check(TreeTypeAge(A.TypePlusOne-1)=40,'explicit age retained');
  A:=ClassifyTreeTag(Tags,LL,False,False,0,100);
  Check(TreeTypeAge(A.TypePlusOne-1)<=MatureTreeAge(tsBirch)*3,'unreachable height bounded');
end;
var A,B:TTileModel;Stream:TMemoryStream;Rec:TTileTreeRec;S:TTreeSpecies;I,J,Typed:Integer;
    Inst,Other:TTreeInstance;BinaryPath,Root:string;World:TDreamWorld;
begin
  CheckPhotoHeight;
  BinaryPath:=IncludeTrailingPathDelimiter(ParamStr(1))+'regional-tile-test.o3b';
  A:=TTileModel.Create;Stream:=TMemoryStream.Create;
  try
    A.TileId:=TGeoTileId.Make(31,True,0,0);A.GenHash:='regional-plants-test';
    A.Box.MinLat:=-1;A.Box.MinLon:=-1;A.Box.MaxLat:=1;A.Box.MaxLon:=1;
    for S:=Low(S) to High(S) do begin
      Rec:=Default(TTileTreeRec);Rec.X:=Ord(S)*13.5;Rec.Y:=3;Rec.Z:=-25;
      Rec.Scale:=1;Rec.IsShrub:=IsShrub(S);Rec.Procedural.TypePlusOne:=PackTreeType(S,123,255)+1;
      A.AddTree(Rec);
    end;
    TTileX3D.SaveStream(Stream,A);Stream.Position:=0;B:=TTileX3D.LoadStream(Stream);
    try
      Check(B.TreeCount=A.TreeCount,'text tree count');
      for I:=0 to A.TreeCount-1 do Check(B.Trees[I].Procedural.TypePlusOne=A.Trees[I].Procedural.TypePlusOne,'text packed species/age/variant');
    finally B.Free;end;
    TTileBinary.SaveFile(BinaryPath,A);B:=TTileBinary.LoadFile(BinaryPath);
    try
      for I:=0 to A.TreeCount-1 do Check(B.Trees[I].Procedural.TypePlusOne=A.Trees[I].Procedural.TypePlusOne,'binary packed species/age/variant');
    finally B.Free;DeleteFile(BinaryPath);end;
    Rec:=A.Trees[14];Inst:=ProceduralTreeInstance(Rec,nil);Rec.X:=Rec.X+1;
    Other:=ProceduralTreeInstance(Rec,nil);
    Check(SeedForTree(Inst)<>SeedForTree(Other),'Dream identity uses local position, not zero lat/lon');
  finally Stream.Free;A.Free;end;
  if ParamCount>1 then begin
    Root:=IncludeTrailingPathDelimiter(ParamStr(2));
    for I:=0 to 1 do begin
      if I=0 then World:=TDreamWorld.Create(Root+'neon-district/world.json')
      else World:=TDreamWorld.Create(Root+'red-canyon/world.json');
      try
        Typed:=0;
        for J:=0 to World.Tiles[0].Model.TreeCount-1 do
          if World.Tiles[0].Model.Trees[J].Procedural.TypePlusOne<>0 then Inc(Typed);
        Check(Typed=World.Tiles[0].Model.TreeCount,'all Dream plants retain type');
        Writeln(World.Id,' typed plants=',Typed,' route=',Round(World.LengthM),' m, validated against baked ground');
      finally World.Free;end;
    end;
  end;
  Writeln('PASS all 21 species in text/binary tile caches; local Dream identity');
end.

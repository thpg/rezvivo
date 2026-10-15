{ Topological repair of jumps between parallel carriageways. The point/window
  votes above are useful with noisy GPS, but cannot establish connectivity.
  Only revisit a neighbourhood where they selected a disconnected jump.
  Work is performed once during route preparation, never during riding. }
  procedure RepairRoadChain;
  const KMax=8; Infinity=1e25; Reach=240.0;
  type
    TNode=record X,Z:Single; Edge,Next:Integer end;
    TEdge=record Dest,Next:Integer; Len:Single end;
    TOptions=record Count:Integer; C:array[0..KMax-1]of TCandidate;
      Cost:array[0..KMax-1]of Double; Prev:array[0..KMax-1]of Integer end;
  var Nodes:array of TNode; Edges:array of TEdge;
    Ends:array of array[0..1]of Integer;
    Cells:specialize TDictionary<Int64,Integer>;
    Distances:specialize TDictionary<Int64,Single>;
    Built:array of Boolean; Dist:array of Single; Stamp,Queue:array of Integer;
    Opt:array of TOptions; Fix:array of Boolean;
    NodeCount,EdgeCount,Epoch,Head,Tail,I0,J0,A,B,L,H,P,Q,U,Pick:Integer;
    D0,Lateral,RawStep,Net,Score,BestCost:Double; C0,C1:TCandidate;

    function PairKey(X,Y:Integer):Int64; inline;
    begin Result:=(Int64(X) shl 32) or Int64(Cardinal(Y)) end;

    function NodeAt(X,Z:Single):Integer;
    var CX,CZ,DX,DZ,T:Integer; Key:Int64;
    begin
      CX:=Floor(X);CZ:=Floor(Z);
      for DX:=-1 to 1 do for DZ:=-1 to 1 do
        if Cells.TryGetValue(PairKey(CX+DX,CZ+DZ),T)then
          while T>=0 do begin
            if Sqr(Nodes[T].X-X)+Sqr(Nodes[T].Z-Z)<=0.0025 then Exit(T);
            T:=Nodes[T].Next;
          end;
      Result:=NodeCount;Inc(NodeCount);
      if NodeCount>Length(Nodes)then SetLength(Nodes,Max(256,NodeCount*2));
      Nodes[Result].X:=X;Nodes[Result].Z:=Z;Nodes[Result].Edge:=-1;
      Key:=PairKey(CX,CZ);
      if not Cells.TryGetValue(Key,T)then T:=-1;
      Nodes[Result].Next:=T;Cells.AddOrSetValue(Key,Result);
    end;

    procedure EdgeAdd(FromNode,ToNode:Integer; Len:Single);
    begin
      Edges[EdgeCount].Dest:=ToNode;Edges[EdgeCount].Len:=Len;
      Edges[EdgeCount].Next:=Nodes[FromNode].Edge;
      Nodes[FromNode].Edge:=EdgeCount;Inc(EdgeCount);
    end;

    procedure Enqueue(T:Integer);
    begin
      if Tail=Length(Queue)then SetLength(Queue,Max(256,Tail*2));
      Queue[Tail]:=T;Inc(Tail);
    end;

    function NodeDistance(FromNode,ToNode:Integer):Single;
    var T,E,V:Integer; D:Single;
    begin
      if FromNode=ToNode then Exit(0);
      if not Built[FromNode]then begin
        Built[FromNode]:=True;Inc(Epoch);Head:=0;Tail:=0;
        Stamp[FromNode]:=Epoch;Dist[FromNode]:=0;Enqueue(FromNode);
        while Head<Tail do begin
          T:=Queue[Head];Inc(Head);E:=Nodes[T].Edge;
          while E>=0 do begin
            V:=Edges[E].Dest;D:=Dist[T]+Edges[E].Len;
            if (D<=Reach) and ((Stamp[V]<>Epoch)or(D+0.001<Dist[V]))then begin
              Dist[V]:=D;Stamp[V]:=Epoch;Enqueue(V);
            end;
            E:=Edges[E].Next;
          end;
        end;
        for T:=0 to Tail-1 do
          Distances.AddOrSetValue(PairKey(FromNode,Queue[T]),Dist[Queue[T]]);
      end;
      if not Distances.TryGetValue(PairKey(FromNode,ToNode),Result)then Result:=Infinity;
    end;

    function Along(const C:TCandidate; EndIndex:Integer):Single;
    var T:Integer;
    begin T:=Ends[C.SegIdx][EndIndex];
      Result:=Sqrt(Sqr(C.FootX-Nodes[T].X)+Sqr(C.FootZ-Nodes[T].Z)) end;

    function NetworkDistance(const X,Y:TCandidate):Double;
    var E,F:Integer; D:Double;
    begin
      Result:=Infinity;
      if X.SegIdx=Y.SegIdx then
        Result:=Sqrt(Sqr(X.FootX-Y.FootX)+Sqr(X.FootZ-Y.FootZ));
      for E:=0 to 1 do for F:=0 to 1 do begin
        D:=Along(X,E)+Along(Y,F);
        if D>=Result then Continue;
        D:=D+NodeDistance(Ends[X.SegIdx][E],Ends[Y.SegIdx][F]);
        Result:=Min(Result,D);
      end;
    end;

    function CandidateAt(PointIndex,SegIndex:Integer):TCandidate;
    var S:^TSnapSegment; T,DX,DZ:Single;
    begin
      S:=@Segs[SegIndex];Result:=Default(TCandidate);
      T:=EnsureRange(((RouteLocal[PointIndex].X-S^.X0)*S^.DX+
        (RouteLocal[PointIndex].Z-S^.Z0)*S^.DZ)/S^.LenSq,0,1);
      Result.SegIdx:=SegIndex;Result.FootX:=S^.X0+T*S^.DX;Result.FootZ:=S^.Z0+T*S^.DZ;
      DX:=RouteLocal[PointIndex].X-Result.FootX;DZ:=RouteLocal[PointIndex].Z-Result.FootZ;
      Result.PerpDist:=Sqrt(DX*DX+DZ*DZ);
      Result.SignedPerp:=(DX*(-S^.DZ)+DZ*S^.DX)*S^.LenInv;
      Result.AngleDeg:=UndirectedAngleDeg(RouteTangents[PointIndex].X,
        RouteTangents[PointIndex].Z,S^.DX,S^.DZ);
      Result.WayId:=S^.WayId;Result.Width:=S^.Width;Result.IsBridge:=S^.IsBridge;
    end;

    function Emission(const C:TCandidate):Double;
    begin Result:=Sqr(C.PerpDist)*0.1+Sqr(C.AngleDeg)*0.003 end;

    procedure OptionsAt(PointIndex:Integer; Anchor:Boolean);
    var Around:TCellIndexArray; Ci,T,S,Slot,J:Integer; C:TCandidate; Value:Double;
    begin
      Opt[PointIndex].Count:=1;
      Opt[PointIndex].C[0]:=CandidateAt(PointIndex,ChosenSeg[PointIndex]);
      if Anchor then Exit;
      Around:=GridCellsAround(Grid,RouteLocal[PointIndex].X,RouteLocal[PointIndex].Z);
      for Ci:=0 to High(Around)do
        for T:=Grid.Starts[Around[Ci]]to Grid.Starts[Around[Ci]+1]-1 do begin
          S:=Grid.Indices[T];
          { A roadway correction must not invent a trip along a sidewalk.
            Leave recorded narrow-path branches to the original snapper. }
          if Segs[S].Width<=SNAP_WIDE_THRESHOLD_M then Continue;
          if Segs[ChosenSeg[PointIndex]].IsBridge and not Segs[S].IsBridge then Continue;
          C:=CandidateAt(PointIndex,S);
          if (C.PerpDist>SNAP_POINT_MAX_PERP_M)or(C.AngleDeg>45)then Continue;
          Slot:=0;
          while(Slot<Opt[PointIndex].Count)and(Opt[PointIndex].C[Slot].SegIdx<>S)do Inc(Slot);
          if Slot<Opt[PointIndex].Count then Continue;
          Value:=Emission(C);Slot:=1;
          while(Slot<Opt[PointIndex].Count)and(Emission(Opt[PointIndex].C[Slot])<=Value)do Inc(Slot);
          if Slot>=KMax then Continue;
          Opt[PointIndex].Count:=Min(KMax,Opt[PointIndex].Count+1);
          for J:=Opt[PointIndex].Count-1 downto Slot+1 do
            Opt[PointIndex].C[J]:=Opt[PointIndex].C[J-1];
          Opt[PointIndex].C[Slot]:=C;
        end;
    end;

  begin
    if (N<3)or(Length(Segs)=0)then Exit;
    Cells:=specialize TDictionary<Int64,Integer>.Create;
    Distances:=specialize TDictionary<Int64,Single>.Create;
    try
      NodeCount:=0;EdgeCount:=0;Epoch:=0;
      SetLength(Ends,Length(Segs));SetLength(Edges,2*Length(Segs));
      for I0:=0 to High(Segs)do begin
        A:=NodeAt(Segs[I0].X0,Segs[I0].Z0);B:=NodeAt(Segs[I0].X1,Segs[I0].Z1);
        Ends[I0][0]:=A;Ends[I0][1]:=B;
        { No shortcut through paths to a neighbouring carriageway. }
        if Segs[I0].Width>SNAP_WIDE_THRESHOLD_M then begin
          D0:=1/Segs[I0].LenInv;EdgeAdd(A,B,D0);EdgeAdd(B,A,D0);
        end;
      end;
      SetLength(Built,NodeCount);SetLength(Dist,NodeCount);SetLength(Stamp,NodeCount);
      SetLength(Fix,N);SetLength(Opt,N);
      for I0:=1 to N-1 do begin
        if(ChosenSeg[I0]<0)or(ChosenSeg[I0-1]<0)or
          (Widths[I0]<=SNAP_WIDE_THRESHOLD_M)or(Widths[I0-1]<=SNAP_WIDE_THRESHOLD_M)then Continue;
        C0:=CandidateAt(I0-1,ChosenSeg[I0-1]);C1:=CandidateAt(I0,ChosenSeg[I0]);
        if C0.SegIdx=C1.SegIdx then Continue;
        RawStep:=CumLen[I0]-CumLen[I0-1];
        D0:=Sqrt(Sqr(C0.FootX-C1.FootX)+Sqr(C0.FootZ-C1.FootZ));
        if D0<6 then Continue;
        Lateral:=Abs((C1.FootX-C0.FootX)*RouteTangents[I0].Z-
          (C1.FootZ-C0.FootZ)*RouteTangents[I0].X)/
          Max(0.001,Sqrt(Sqr(RouteTangents[I0].X)+Sqr(RouteTangents[I0].Z)));
        if(D0<=RawStep+3)and(Lateral<4)then Continue;
        Net:=NetworkDistance(C0,C1);
        if Net<=RawStep+15 then Continue;
        L:=I0-1;H:=I0;
        while(L>0)and(CumLen[I0]-CumLen[L]<600)and(ChosenSeg[L-1]>=0)and
          (Widths[L-1]>SNAP_WIDE_THRESHOLD_M)do Dec(L);
        while(H<N-1)and(CumLen[H]-CumLen[I0]<600)and(ChosenSeg[H+1]>=0)and
          (Widths[H+1]>SNAP_WIDE_THRESHOLD_M)do Inc(H);
        for J0:=L to H do Fix[J0]:=True;
      end;
      L:=0;
      while L<N do begin
        if not Fix[L]then begin Inc(L);Continue end;
        H:=L;while(H<N-1)and Fix[H+1]do Inc(H);
        for P:=L to H do OptionsAt(P,(P=L)or(P=H));
        Opt[L].Cost[0]:=0;
        for P:=L+1 to H do begin
          RawStep:=CumLen[P]-CumLen[P-1];
          for Q:=0 to Opt[P].Count-1 do begin
            BestCost:=Infinity;Pick:=-1;
            for U:=0 to Opt[P-1].Count-1 do begin
              if Opt[P-1].Cost[U]>=Infinity then Continue;
              Net:=NetworkDistance(Opt[P-1].C[U],Opt[P].C[Q]);
              if Net>Max(20,RawStep*2+10)then Continue;
              Score:=Opt[P-1].Cost[U]+Sqr(Net-RawStep)*0.7;
              if Score<BestCost then begin BestCost:=Score;Pick:=U end;
            end;
            Opt[P].Cost[Q]:=BestCost+Emission(Opt[P].C[Q])*Max(0.2,Min(2,RawStep/5));
            Opt[P].Prev[Q]:=Pick;
          end;
        end;
        { If no connected explanation exists, retain the original route;
          do not bridge missing data or alter a genuine off-road section. }
        if Opt[H].Cost[0]<Infinity then begin
          Pick:=0;
          for P:=H downto L do begin
            PlaceSnap(P,Opt[P].C[Pick]);
            if DbgOn then Note[P]:=Note[P]+' connected-road-chain';
            Pick:=Opt[P].Prev[Pick];
          end;
        end;
        if DbgOn and (Opt[H].Cost[0]>=Infinity)then Note[L]:=Note[L]+Format(' chain-unreachable[%d..%d]',[L,H]);
        L:=H+1;
      end;
    finally Distances.Free;Cells.Free end;
  end;

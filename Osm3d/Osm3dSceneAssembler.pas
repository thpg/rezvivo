unit Osm3dSceneAssembler;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$codepage UTF8}
{$WARN 6018 OFF}

interface

uses
  Classes,
  SysUtils,
  CastleVectors, Osm3dShadowReceiver, Osm3dGpuGround, Osm3dSoundscape,
  X3DNodes,
  Osm3dGeomMesh,
  Osm3dSceneMaterials,
  Math,
  Osm3dGroundComposite, Osm3dRiderShadow, Osm3dRoadMaterial, Osm3dRoadSurfaceBinding, Osm3dRoadCurbs,
  Osm3dWind, Osm3dManholeData, Osm3dManholeRender, Osm3dRoadFurniture,
  CastleImages,
  CastleRenderOptions,
  X3DFields,
  Osm3dGeoMath,
  Osm3dGeoTileGrid,
  Osm3dTileX3D,
  Osm3dTreeShadow,
  Osm3dTilePreview,    { общий набор альфа-масок деревьев + ShadowIntensityFor }
  Osm3dRoadDistField,
  Osm3dAccessoryAtlas,
  {$IFDEF TEX_SIZE_PROFILE}Osm3dTexProfile,{$ENDIF}
  Osm3dStudioSettings,
  Generics.Collections,
  Osm3dGeomSurface,
  Osm3dGeomRoads, Osm3dGeomBridges,
  Osm3dGeomBuildings,
  Osm3dBuildingObstacleIndex,  { BUILDING_OBSTACLE: CastersToObstacles }
  Osm3dGeomPOI,
  Osm3dGeomUtils,
  Osm3dSceneEffects,
  Osm3dWaterShader,
  Osm3dCompositeShader,
  Osm3dBuildingTextures,
  Osm3dBuildingComposite,
  Osm3dGeomFences,
  Osm3dFenceComposite,
  Osm3dGeomPlates,
  Osm3dPlateAtlas,
  PBRTextureUnit,
  Osm3dProfiler,
  Osm3dGlslLib           { DEFAULT_SUN_RAY_DIR / DEFAULT_SUN_TOWARD / SUN_INTENSITY_VALUE }
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

type
  TUVMode = (
    uvNone,             { no UV (default) }
    uvWallVertical,     { wall / landuse: copy Mesh.Vertices[*].UV directly }
    uvRoofPlanar,       { roof: (X,Z)/4 → (U,V); 4×4 m tile top-down }
    uvFromMesh          { alias for uvWallVertical: UV already in mesh —
                          kept for compatibility with existing callers }
  );

  TMeshToX3D = class
  public
    class function CreateGeometry(Mesh: TMesh; ASolid: Boolean = True): TIndexedFaceSetNode; overload;
    class function CreateGeometry(Mesh: TMesh; ASolid: Boolean;
      UVMode: TUVMode): TIndexedFaceSetNode; overload;

    class function CreateShape(Mesh: TMesh; MaterialKind: TSceneMaterialKind;
      ASolid: Boolean = True): TShapeNode; overload;
    class function CreateShape(Mesh: TMesh; MaterialKind: TSceneMaterialKind;
      ASolid: Boolean; UVMode: TUVMode;
      Texture: TAbstractTextureNode): TShapeNode; overload;
    { Extended form with a normal map. NormalMap is a tangent-space
      normal texture; CGE automatically generates tangent-space
      lighting in the shader when Material.NormalTexture is present.
      If NormalMap=nil — equivalent to the overload without a normal
      map. Texture may be nil — in that case the normal map is
      ignored (without a diffuse channel it cannot be applied
      correctly). }
    class function CreateShape(Mesh: TMesh; MaterialKind: TSceneMaterialKind;
      ASolid: Boolean; UVMode: TUVMode;
      Texture: TAbstractTextureNode;
      NormalMap: TAbstractTexture2DNode): TShapeNode; overload;

    { Landuse surface shape: textured ground for landuse kind KindIdx
      (Ord of a TLanduseMeshKind), falling back to a flat-colour shape
      in FlatMat when the surface PNG is absent. Shared by the chunk and
      cache assembly paths. nil if Mesh is empty. }
    class function CreateSurfaceShape(Mesh: TMesh; KindIdx: Integer;
      FlatMat: TSceneMaterialKind): TShapeNode;
  end;

type
  { One tile's slice of a plain TMesh. }
  TTileMesh = record
    CellX, CellZ: Integer;    { grid cell coordinates }
    CenterX, CenterZ: Single; { world-space XZ centre of cell }
    Mesh: TMesh;              { caller owns / must free }
  end;
  TTileMeshArray = array of TTileMesh;

  { One tile's slice of a TGroundCompositeMesh. }
  TTileCompositeMesh = record
    CellX, CellZ: Integer;
    CenterX, CenterZ: Single;
    CompositeMesh: TGroundCompositeMesh;  { caller owns / must free }
  end;
  TTileCompositeMeshArray = array of TTileCompositeMesh;

  { Splits meshes into spatial 2D tile slices using triangle centroids.
    All methods are class functions (no state). }
  TSceneTiler = class
  public
    { Split Mesh into XZ cells of TileSize metres.  Empty cells are
      omitted.  The returned TTileMesh.Mesh instances are owned by the
      caller and must be freed after use. }
    class function SplitMesh(Mesh: TMesh;
      TileSize: Single): TTileMeshArray;

    { Split a TGroundCompositeMesh into XZ cells, preserving the
      parallel MaterialIds stream.  The returned
      TTileCompositeMesh.CompositeMesh instances are owned by the caller
      and must be freed after use. }
    class function SplitCompositeMesh(Comp: TGroundCompositeMesh;
      TileSize: Single): TTileCompositeMeshArray;
  end;

type
  TGroundCompositeShape = class
  public
    { Build one TShapeNode rendering the entire ground (terrain, landuse, roads, building shadow
      polygons) via a custom shader effect that samples the atlas. ShaderVertexUrl/ShaderFragmentUrl
      are CGE data URLs for the GLSL source (e.g. 'castle-data:/Osm3d/shaders/ground_composite.vs');
      an empty URL falls back to the EmbeddedVertex/EmbeddedFragment strings — the path the project
      uses today (no separate shader files shipped). DebugTintAmount > 0 mixes the fallback colour
      into the albedo (0 = production, 1 = pure tints for debugging material assignment). LogProc
      receives one summary line. }
    class function CreateShape(
      Composite:    TGroundCompositeMesh;
      Atlas:        TGroundAtlas;
      { Direction TOWARD the sun in world space (= -lightRayDirection).
        Passed as uniform gc_SunDirToward to the fragment shader.
        Zero vector → falls back to Osm3dGlslLib.DEFAULT_SUN_TOWARD. }
      SunDirToward: TVector3;
      { Road distance-field for the streets-gl-style halo. May be nil —
        the FS branches on u_road_field_present=0 and skips the sample.
        Ownership: when non-nil, this method calls CreateTextureNode on
        the field (consuming the image) and attaches the resulting
        TPixelTextureNode to the X3D scene. Caller still owns the
        TRoadDistField metadata object (origin/size/halo). }
      RoadDistField: TRoadDistField = nil;
      const ShaderVertexUrl:    string = '';
      const ShaderFragmentUrl:  string = '';
      const EmbeddedVertex:     string = '';
      const EmbeddedFragment:   string = '';
      DebugTintAmount: Single = 0.0;
      AttachShaderEffect: Boolean = True;
      AttachMaterialIdAttribute: Boolean = True;
      LogProc: TLogProc = nil): TShapeNode;

    { Tiled-assembly helpers
 When splitting the ground composite into 200 m tiles, call
 BuildSharedTextureNodes ONCE to pre-build the atlas and road-halo
 texture nodes. Pass the results to CreateShapeTiled for each tile
 so all tiles reference the SAME TPixelTextureNode objects — the
 X3D renderer uploads each GPU texture only once (DEF/USE semantics). }

    { Build the two atlas texture nodes (diffuse + normal) and the road
      halo texture node. AAtlasTex/AAtlasNormTex receive new
      TPixelTextureNode instances (or nil if Atlas.Image is nil). Pass
      nil for ARoadHaloTex output if RoadDistField is nil / has no data. }
    class procedure BuildSharedTextureNodes(
      Atlas:         TGroundAtlas;
      RoadDistField: TRoadDistField;
      out AAtlasTex:     TPixelTextureNode;
      out AAtlasNormTex: TPixelTextureNode;
      out AAtlasMaskTex: TPixelTextureNode;
      out ARoadHaloTex:  TPixelTextureNode);

    { Like CreateShape but uses caller-supplied pre-built texture nodes.
      AtlasTex/AtlasNormTex must be non-nil (from BuildSharedTextureNodes).
      RoadHaloTex may be nil (road halo disabled for this tile).
      The pre-built nodes are NOT consumed — they are referenced (X3D
      node ref-count incremented) and their lifetime is managed by the
      X3D scene graph. }
    class function CreateShapeTiled(
      Composite:         TGroundCompositeMesh;
      Atlas:             TGroundAtlas;
      SunDirToward:      TVector3;
      RoadDistField:     TRoadDistField;
      AtlasTex:          TAbstractTexture2DNode;
      AtlasNormTex:      TAbstractTexture2DNode;
      AtlasMaskTex:      TAbstractTexture2DNode;
      RoadHaloTex:       TPixelTextureNode;
      const EmbeddedVertex:   string;
      const EmbeddedFragment: string;
      AttachShaderEffect:        Boolean;
      AttachMaterialIdAttribute: Boolean;
      LogProc: TLogProc = nil;
      SharedEffect: TEffectNode = nil): TShapeNode;
  end;

  { TProjTri / TProjTriArray / TShadowCardKind / TShadowTreeCard(Array) now
    live in Osm3dTileX3D (next to TTileModel); used from there so the model
    fields and the local rasteriser share one set of types. }

  { Maps a loaded tile to its shadow-mask overlay effect (per load pack). }
  TTileMaskEntry = record
    TileId: TGeoTileId;
    Effect: TEffectNode;
  end;

  { Persistent per-tile shadow silhouettes, kept in the assembly cache so
    a newly loaded tile can pull crossing shadows from neighbours loaded
    in earlier packs. Capped ring buffer — oldest entries are overwritten,
    so no explicit unload hook is needed (stale data ages out, and its
    geometry is correct anyway). }
  TTileShadowReg = record
    InUse:  Boolean;
    TileId: TGeoTileId;
    { TileId.ToString cached once at registration. The by-key lookups
      (GetTileMaskTexByKey/ByOwner) compare against this instead of calling
      TileId.ToString per entry per lookup — that materialised a fresh
      string for every one of the (up to SHADOW_REG_CAP) ring entries on
      every lookup. Set only in RegisterShadowReg (the sole place a slot is
      assigned a TileId). }
    KeyStr: string;
    Tris:   TProjTriArray;
    Ground: TShadowGroundTriangles;
    Trees:  TShadowTreeCardArray;   { tree silhouettes, same cross-tile /
                                      cross-pack treatment as the triangles }
    MinX, MinZ, MaxX, MaxZ: Single;
    { Live mask texture + its object-XZ window, set once the tile's mask
      is built — lets a later pack PUSH its crossing shadows into this
      already-rendered tile. Tex is nil before the mask exists and after
      the tile is unloaded (cleared by DetachTileMaskTexture). }
    Tex:    TPixelTextureNode;
    TexTree: TPixelTextureNode;   { parallel TREE mask texture node,
                                   uploaded independently (no PUSH swap) }
    { Opaque owner tag (the TCacheTile* the live Tex node belongs to). The
      registry ring and the resident-tile set have independent lifetimes: a
      tile can evict and a DIFFERENT tile reuse the same ring slot, or the
      same geo-tile can re-mount with a brand-new scene + Tex. An upload that
      was in flight across any of that must NOT be poked into whatever node
      the slot now holds. The streaming map stamps Owner at mount and only
      uploads when the slot still belongs to the same live tile, so a freed
      node is never touched. nil whenever Tex is nil. }
    Owner:  Pointer;
    { Mount-generation stamped together with Owner (StampTileMaskOwner).
      GetTileMaskTexByOwner requires the draining upload's generation to
      match this — so a result produced for a previous mount of the same
      geo-tile (which the re-mount bumped) is rejected even if the heap
      handed the new TCacheTile the same address as the freed old one.
      Reset to 0 whenever the slot is reused (RegisterShadowReg) or
      detached, so a stale generation can never spuriously match. }
    Gen:    QWord;
    MaskField: TSFNode;   { the effect's gc_shadow_mask field — lets PUSH
                            swap in a fresh texture node so CGE re-uploads
                            (FdImage.Changed does NOT re-upload a texture
                            bound only through an effect sampler field). }
    OX, OZ, SX, SZ: Single;
  end;
  TTileShadowRegArray = array of TTileShadowReg;

{ TCachedAssemblyResources — holds the tile-INDEPENDENT, expensive-to-build assembly resources
  (ground atlas + BuildImage/BuildNormalImage, the three shared atlas texture nodes, the 12
  per-palette building PBR appearances), depending only on settings, so they are reused across
  AssembleCachedTiles calls instead of rebuilt each time (image processing costs hundreds of ms to
  seconds per call). Build ONCE per session, pass to every call, free last. The owned X3D nodes are
  USE-shared into tile scenes and protected with KeepExistingBegin, so freeing a tile scene does NOT
  free them — only this object's destructor does (KeepExistingEnd + Free). }
  TCachedAssemblyResources = class
  private
    FBuilt:        Boolean;
    FAtlas:        TGroundAtlas;
    { Building facade/roof atlas — built alongside the ground atlas and
      written to the same cache dir. When its PNGs are saved (DiffuseUrl
      set), BuildTileRoot merges all wall/roof palette meshes of a tile
      into ONE building-composite shape (one draw call) instead of ~10
      per-palette shapes. nil / no URL → the legacy per-palette path. }
    FBuildAtlas:   TBuildingAtlas;
    { Fence/barrier atlas — diffuse(+alpha cutout) + normal + mask, no glow.
      When its PNGs are saved (DiffuseUrl set), BuildTileRoot merges all
      fence-material meshes of a tile into ONE fence-composite shape. }
    FFenceAtlas:   TFenceAtlas;
    { House-number plate glyph atlas (one cached grayscale PNG of the embedded
      CGE font). When its Url is set, BuildTileRoot merges all smkPlate meshes
      of a tile into ONE plate-composite shape. }
    FPlateAtlas:   TPlateGlyphAtlas;
    { Accessory sprite atlas (traffic-light states); diffuse-only, 256px cells.
      The traffic light bakes cell UVs into per-state meshes and switches them
      with a TSwitchNode (per batch), animated by the current tile. }
    FAccessoryAtlas: TAccessoryAtlas;
    { Atlas diffuse/normal may be URL-based (TImageTextureNode, cached PNG)
      or inline (TPixelTextureNode, fallback) — store as the common
      ancestor. FRoadHaloTex stays a small inline dummy. }
    FAtlasTex:     TAbstractTexture2DNode;
    FAtlasNormTex: TAbstractTexture2DNode;
    FAtlasMaskTex: TAbstractTexture2DNode;
    FRoadHaloTex:  TPixelTextureNode;
    { Directory for the session atlas PNGs (set by the host before the
      first AssembleCachedTiles). Empty → inline-pixel fallback path. }
    FAtlasCacheDir: string;
    { True when the atlas nodes were built from cached-PNG URLs. URL nodes
      are CGE-URL-cache-ref-counted, so they are NOT pinned and NOT listed
      as shared (no detach/unprepare hazard); the inline fallback still is. }
    FAtlasUrlMode:  Boolean;
    { Ground-composite shader effect — built ONCE and USE-shared by every
      tile appearance, exactly like the atlas nodes. All its uniforms are
      session-global (GlobalLODConfig, sun direction, atlas samplers), so
      one instance serves the whole session. Pinned with KeepExistingBegin
      so a tile scene's destruction never frees it. }
    FGroundEffect: TEffectNode;
    FWallApp:      array[0..BUILDING_PALETTE_SIZE-1] of TAppearanceNode;
    FRoofApp:      array[0..5] of TAppearanceNode;
    { Per-landuse-kind surface textures, shared (USE) across all tiles
      and pinned (KeepExistingBegin) so a tile scene's destruction never
      frees them. Indexed by Ord(TLanduseMeshKind). FSurfReady marks a
      slot as resolved (the texture may still be nil if its PNG is
      absent). }
    FSurfTex:      array[TLanduseMeshKind] of TImageTextureNode;
    FSurfNorm:     array[TLanduseMeshKind] of TImageTextureNode;
    FSurfReady:    array[TLanduseMeshKind] of Boolean;
    { Diagnostic log — when set, every texture node created here is
      reported (each is a point where CGE will start loading a PNG). }
    FLog:          TLogProc;
    { Persistent per-tile shadow silhouette registry (capped ring). }
    FShadowReg:    TTileShadowRegArray;
    FShadowCursor: Integer;
    FShadowLock:   TRTLCriticalSection;   { сериализует реестр теней: фон-ассемблер vs main }
    procedure LogTex(const AWhat, APath: string);
  public
    constructor Create;
    destructor Destroy; override;
    {$IFDEF TILE_MEM_PROFILE}
    { Оценка VRAM резидентных масок теней: R8 grayscale, res² на каждую
      живую маску (res = ShadowMaskRes окна тайла). Адрес метода идёт в
      MemProbeAdd как зонд 'shadow-mask~'. }
    function ShadowMaskBytes: Int64;
    {$ENDIF}
    property LogSink: TLogProc read FLog write FLog;
    procedure EnsureAtlas(LogProc: TLogProc);
    { Build (and pin) the session-shared ground-composite shader effect.
      Must be called after EnsureAtlas (it references the atlas nodes). }
    { Build (and pin) one landuse kind's surface textures up front, so
      the first tile that uses it does not trigger a load mid-stream. }
    { Build textures for every landuse kind at once — call at session
      start so tiles never load a surface texture themselves. }
    procedure WarmupSurfaces(LogProc: TLogProc);
    function SurfaceShape(Mesh: TMesh; LK: TLanduseMeshKind;
      FlatMat: TSceneMaterialKind): TShapeNode;

    { True if N is one of the session-shared, KeepExisting-pinned nodes
      this cache owns: the three atlas/road-halo textures, the ground
      shader effect, the 12 building appearance nodes, and the per-
      landuse surface textures. Pure pointer identity. }
    function IsShared(N: TX3DNode): Boolean;

    { Null every reference to an IsShared node found anywhere in the X3D
      graph rooted at Root (SFNode fields set to nil, MFNode entries
      removed). After this the graph reaches only tile-UNIQUE nodes, so
      freeing it — and the TCastleScene that Load'ed it — runs
      UnregisterScene / resource-unprepare over those alone: the shared
      atlas / effect / appearance nodes, and every still-resident
      sibling tile that USE-references them, are left completely
      untouched. The streaming map calls this on each root of a batch
      about to be evicted, immediately before the batch is freed, so a
      batch's geometry can be reclaimed mid-session without flickering
      the shared atlas on the tiles that remain. }
    procedure DetachSharedFrom(Root: TX3DNode);

    { Shadow-silhouette registry. RegisterTileShadow stores (a copy of) a
      tile's projected silhouettes; ApplyShadowsTo rasterizes every
      registered silhouette overlapping the given object-XZ window into
      the mask (so a tile pulls crossing shadows from neighbours loaded
      earlier). Returns True if anything was drawn. }
    procedure RegisterTileShadow(const T: TGeoTileId;
      const Tris: TProjTriArray; const TreeCards: TShadowTreeCardArray;
      AMinX, AMinZ, AMaxX, AMaxZ: Single;
      const Ground: TShadowGroundTriangles);
    function ApplyShadowsTo(Mask: TGrayscaleImage;
      const OriginV, SizeV: TVector2): Boolean;
    { Record a tile's live mask texture + window (call after its mask is
      built) so later packs can push crossing shadows into it. }
    procedure SetTileMaskTexture(const T: TGeoTileId;
      ATex: TPixelTextureNode; ATexTree: TPixelTextureNode; AField: TSFNode;
      AOX, AOZ, ASX, ASZ: Single; AOwner: Pointer = nil);
    { Stamp the live owner of a tile's mask slot once the streaming map has
      mounted the tile and knows its TCacheTile. Pairs with
      GetTileMaskTexByOwner to reject stale in-flight uploads. }
    procedure StampTileMaskOwner(const T: TGeoTileId; AOwner: Pointer;
      AGen: QWord);
    { Drop a tile's live mask texture reference (its scene — and that
      node — is about to be freed). Silhouettes are KEPT so neighbours
      still pull the shadow while this tile is hidden. Call from the
      streaming map on eviction. }
    procedure DetachTileMaskTexture(const T: TGeoTileId);

    { Off-thread shadow path (the worker lives in TTileStreamer)
 AnyShadowReaches: cheap AABB test — does any registered silhouette
 fall in this window (decides if a tile needs a mask node at all).
 CollectTileSnapshot: gather T's window + resolution + every silhouette
 (T + neighbours) overlapping it, as a self-contained snapshot for the
 shadow worker. Reads the persistent registry, so it works across load
 packs. False if T has no mask window yet.
 GetTileMaskTexByKey: the live placeholder texture node for a tile (by
 TileId.ToString), to upload a finished mask into. nil if gone.
 GetTileMaskTexByOwner: same, but only when the slot still belongs to
 AOwner — guards against a stale in-flight upload landing on a reused
 ring slot or a re-mounted tile's fresh node. }
    function CollectTileSnapshot(const T: TGeoTileId;
      out AOX, AOZ, ASX, ASZ: Single; out AW, AH: Integer;
      out Tris: TProjTriArray; out Trees: TShadowTreeCardArray;
      out Ground: TShadowGroundTriangles): Boolean;
    function SampleTileGroundShadow(AOwner: Pointer; AGen: QWord;
      SessionX, SessionZ: Single): Single;
    function GetTileMaskTexByKey(const AKey: string): TPixelTextureNode;
    function GetTileMaskTexByOwner(const AKey: string;
      AOwner: Pointer; AGen: QWord): TPixelTextureNode;
    { same owner+gen gate, but returns the TREE mask node. }
    function GetTileMaskTexTreeByOwner(const AKey: string;
      AOwner: Pointer; AGen: QWord): TPixelTextureNode;

    property Built:        Boolean read FBuilt;
    property Atlas:        TGroundAtlas    read FAtlas;
    property BuildAtlas:   TBuildingAtlas  read FBuildAtlas;
    property FenceAtlas:   TFenceAtlas     read FFenceAtlas;
    property PlateAtlas:   TPlateGlyphAtlas read FPlateAtlas;
    property AccessoryAtlas: TAccessoryAtlas read FAccessoryAtlas;
    property AtlasTex:     TAbstractTexture2DNode read FAtlasTex;
    property AtlasNormTex: TAbstractTexture2DNode read FAtlasNormTex;
    property AtlasMaskTex: TAbstractTexture2DNode read FAtlasMaskTex;
    property RoadHaloTex:  TPixelTextureNode read FRoadHaloTex;
    property GroundEffect: TEffectNode      read FGroundEffect;
    { Where to write the session atlas PNGs. Set once, before warm-up. }
    property AtlasCacheDir: string read FAtlasCacheDir write FAtlasCacheDir;
  end;

type

  TSceneInput = record
    Terrain:       TMesh;
    FarTerrain:    TMesh;

    Landuse:       TLanduseMeshes;

    WaterRivers:   TMesh;

    RoadMajor:     TMesh;
    RoadSecondary: TMesh;
    RoadMinor:     TMesh;
    RoadService:   TMesh;
    RoadFootway:   TMesh;
    RoadCycleway:  TMesh;
    RoadRailway:   TMesh;
    { Unpaved paths (highway with surface=dirt/ground/grass/.../sand).
      Same role as the asphalt road meshes above but with their own
      atlas slot (GROUND_MAT_ROAD_DIRT / GROUND_MAT_SAND). Width
      already includes streets-gl widthScale=1.7 (the ribbon is
      rendered 1.7× wider than nominal so alpha-feathered borders
      of dirt_road / sand_road textures fade into terrain). }
    RoadDirtPath:  TMesh;
    RoadSandPath:  TMesh;
    { RoadShoulders removed — sandy strip beside asphalt roads is now
      produced inside the ground composite shader from a road
      distance-field, not as a separate mesh.
      See Osm3dRoadDistField + GroundCompositeShaders heightblend. }

    BuildingWalls: array[0..BUILDING_PALETTE_SIZE-1] of TMesh;
    BuildingRoofs: array[0..BUILDING_PALETTE_SIZE-1] of TMesh;
    { One entry per building, recording which (Palette, range) slices of
      BuildingWalls[]/BuildingRoofs[] belong to it and its footprint XZ
      centroid. The tiled assembler uses these to keep all triangles of
      one building (walls + roofs) inside a single tile chosen by the
      anchor. When nil, the assembler falls back to per-triangle
      centroid binning (legacy behaviour). }
    BuildingTileAnchors: TBuildingTileAnchorArray;

    { Fences/barriers — one mesh per material (parallel to buildings'
      walls palette) plus a per-way anchor table for the same whole-into-
      one-tile binning. nil when GenerateFences is off. }
    Fences:           array[0..FENCE_PALETTE_SIZE-1] of TMesh;
    FenceTileAnchors: TFenceTileAnchorArray;

    { House-number plates — one global mesh (glyph UVs baked per-vertex,
      backplate verts flagged by sentinel UV) + per-building anchor table for
      the same whole-into-one-tile binning. nil when GeneratePlates is off. }
    Plates:           TMesh;
    PlateTileAnchors: TPlateTileAnchorArray;

    POI:           TMesh;
    { Per-instance list consumed by the tiled assembler. One shared
      TShapeNode is built per kind and referenced by N TTransformNode
      instances (X3D USE-style sharing — same node, multiple parents,
      single GPU upload per kind via CGE's node cache).
      The legacy non-tiled Assemble path still uses POI (baked mesh).
      Either field may be nil/empty. }
    POIInstances:  TPOIInstanceArray;
    LabelsRoot:    TGroupNode;

    { Road centerline segments (chunk-local projected XZ + width +
      way id), emitted by TRoadBuilder.BuildAll. SplitInputToTiles
      distributes them per geo-tile into TTileModel.RoadSegs; from the
      tile cache the route snapper reads them back. May be empty. }
    RoadSegments:  TRoadCenterlineSegArray;
    Manholes: TManholeArray;
    RoadFurniture: TMesh;

    { Ground composition (shader-merged landuse only). Composite covers all LANDUSE polygons; roads
      and shoulders stay separate shapes in both modes because road UV (oriented ribbon: U across
      width, V accumulated) is structurally different from landuse's world-XZ UV and didn't render
      correctly mixed into the same atlas shader. When GroundComposite is non-nil and has triangles
      the assembler emits ONE merged landuse shape with the custom shader (skipping per-kind
      AddSurfaceShape) but ALWAYS emits road shapes. Ownership: the assembler does NOT take these —
      caller keeps both alive for the scene's lifetime and frees them after. }
    GroundComposite: TGroundCompositeMesh;
    GroundAtlas:     TGroundAtlas;

    { Diagnostic isolator — see Osm3dStudioSettings.UseGroundCompositionShader.
      True = composite shape rendered with the full shader effect (production).
      False = composite shape rendered with a flat PBR grey material. }
    AttachGroundShader: Boolean;

    { Second isolator — see UseGroundCompositionMaterialIdAttribute.
      True = TFloatVertexAttributeNode "materialId" attached (production).
      False = vertex attribute not attached; shader sees materialId = 0 everywhere. }
    AttachGroundMaterialIdAttribute: Boolean;

    { Sun direction computed from geographic position + ride start UTC.
      Zero vector = use the hard-coded default (−0.5, −0.7, −0.5).
      Set by the caller (main form) after geometry is built; not touched
      by TGeometryBuilder. }
    SunDirection: TVector3;

    BuildingShadowCasters:  TBuildingShadowCasters;

    { Road distance-field for shader-side halo (streets-gl port)
 Rasterised once per chunk by Osm3dRoadDistField. The composite
 shader samples it (uniform u_road_dist_field) to blend
 sandy_soil over grass/terrain along road edges. May be nil —
 then the FS skips the halo via u_road_field_present = 0. The
 TPixelTextureNode is created at CreateShape time and ownership
 transfers to the X3D scene graph; the TRoadDistField object
 itself is still owned by the caller (it holds only metadata
 after CreateTextureNode). }
    RoadDistField:          TRoadDistField;

    { Geo-tile grid binding
 Origin is the chunk's local-projection origin (the same TLatLon
 used to build every mesh's local-metre coordinates). When Origin
 is non-empty the tiled assembler bins triangles by the shared
 geo-tile grid (UTM-zone planar cells, TileEdgeMeters wide) so
 that the tiles it emits are byte-for-byte the tiles the disk
 cache stores — one tiling for rendering and for caching.
 When Origin.IsEmpty (legacy callers), the assembler falls back
 to local Floor(centroid / TileEdgeMeters) binning.
 TileEdgeMeters = 0 means "use GEO_TILE_EDGE_M". }
    Origin:          TLatLon;
    TileEdgeMeters:  Double;
    { UTM zone (1..60) the geo-tile lattice is pinned to. 0 (default) =
      derive from Origin.Lon, the legacy behaviour. This exists so block
      generation can use a block-LOCAL Origin (vertices stay near 0 -> the
      composite's 1 mm proximity weld no longer collapses finely-tessellated
      triangles, which happens when generating hundreds of km from the
      session origin in single precision) while still filing tiles under the
      SESSION's zone so the streamer finds them. }
    TilingZone:      Integer;
    { Latitude (deg) whose cos sets the metres-per-degree-LONGITUDE scale.
      0 (default) = use Origin.Lat (legacy). Block generation passes the
      SESSION latitude here so a block built at a block-LOCAL Origin keeps
      the SAME east/west scale as the render frame — otherwise adjacent
      blocks at different latitudes project the same shared edge to
      slightly different X, opening cracks that grow with distance from
      the session origin. Pairs with TilingZone: local translation, shared
      scale. }
    ScaleLat:        Double;
    { Slippy zoom whose 256-px Terrarium lattice the ground tiles align to
      (= TStudioSettings.HeightmapZoom). The grid is built at this zoom +
      GEO_TILE_EDGE_PX so tile edges land on heightmap pixel lines and the
      per-triangle carve tag matches Grid.TileAt. Supersedes the vestigial
      TileEdgeMeters/TilingZone. }
    HeightmapZoom:   Integer;
  end;

  { Multi-scene result for CGE-native distance culling
 AssembleTiledScenes returns this. The caller (MainForm) creates
 one TCastleScene per tile and one for the global root, each
 loaded with OwnsRootNode=False, then sets TCastleScene.DistanceCulling
 on every tile scene. TAssembledScenes owns ALL the X3D nodes
 (global + tile + the shared texture nodes referenced from tile
 appearances/effects). On chunk reload the caller frees the
 TAssembledScenes instance, which walks every root and frees it;
 X3D's parent-field ref-counting then frees shared texture nodes
 exactly once at their last release point.

 Why a single owner instead of letting each TCastleScene own its
 root: shared TPixelTextureNode instances are attached as SFNode
 field values across multiple tile roots. With OwnsRootNode=True
 on each scene, two scenes would each try to free the same node
 on tear-down — double free. With one external owner we control
 teardown order explicitly. }
  TAssembledTileScene = record
    Soundscape: TSoundscapeField;
    CurbVertices: TCurbMesh; { baked faces for the common ground index }
    GpuGround: TGpuGroundTile;
    Root:             TX3DRootNode;
    CenterX, CenterZ: Single;
    { Geo-tile this scene corresponds to. Valid only when the scene
      was tiled by the geo-grid (TSceneInput.Origin set); HasTileId
      is False for the legacy local-binned path. When valid this is
      the exact key under which the tile is stored in the disk cache,
      so the render tiling and the cache subdivision are one and the
      same — no separate bake/re-split is needed. }
    TileId:           TGeoTileId;
    HasTileId:        Boolean;
  end;
  TAssembledTileSceneArray = array of TAssembledTileScene;

  TAssembledScenes = class
  public
    { Global content not subject to distance culling: lights, sky
      hints, FarTerrain shape, sun-disc sphere. }
    GlobalRoot: TX3DRootNode;

    { One root per non-empty tile.  Each holds the tile's ground
      composite shape + per-palette building wall/roof shapes + water
      + shadows + POI + label transforms.  Coordinates remain in
      world space — the tile scenes are added to the viewport with
      Translation=(0,0,0), and CGE measures DistanceCulling from
      camera to the scene's world bounding-box centre. }
    Tiles: TAssembledTileSceneArray;

    GroundWindTimeFields:  array of TSFFloat;   { per-tile uWindTime (host-pumped) }
    GroundWindBaseFields:  array of TSFFloat;   { per-tile uWindBase }
    GroundWindGustFields:  array of TSFFloat;   { per-tile uWindGustSpeed }

    { Accessory Switch nodes (one per batch that has traffic signals). References
      only — owned by the POI shape graph. The current tile flips their
      WhichChoice each phase (traffic cycle) via TCacheTile.AnimateAccessories. }
    AccessorySwitches: array of TSwitchNode;

    constructor Create;
    destructor Destroy; override;
  end;

  TSceneAssembler = class
  public

    { Split a TSceneInput into cache-ready per-geo-tile TTileModels,
      using the EXACT same geo-grid binning AssembleTiled uses — so the
      tiles produced here are byte-identical to the render tiles.

      ATrees — vegetation instances (tree + shrub) in the neutral
      TTileTreeRec form; distributed into their geo-tile by position so
      they are cached alongside geometry. Pass [] for none.

      Each TTileModel carries, for its geo-tile:
        • the ground-composite slice as ONE mesh with a per-vertex
          materialId stream (AddCompositeMesh), so the
          merged terrain/landuse/road/water geometry round-trips
          losslessly;
        • building wall/roof slices as plain meshes (one per palette);
        • separate water-river geometry when WaterShaders keeps it out
          of the composite;
        • POI instances (kind + position);
        • vegetation instances.
      FarTerrain is NOT tiled (global backdrop, never cached).
      Atlas / textures / shaders are NOT stored — they are rebuilt
      deterministically from settings at load time.

      Input.Origin must be set (geo-tiling). Returns [] if it is not.
      Caller owns every returned TTileModel and must Free them.
      AKeepTiles=nil keeps all tiles. Otherwise only the listed tile IDs are
      materialized, using the same boundary tags and whole-object anchors. }
    class function SplitInputToTiles(const Input: TSceneInput;
      const AGenHash: string;
      const ATrees: TTileTreeRecArray;
      LogProc: TLogProc = nil;
      const AKeepTiles: TGeoTileIdArray = nil): TTileModelArray;

    { Build TAssembledScenes DIRECTLY from cached geo tiles — the fast cache-hit path. Each cached
      TTileModel maps 1:1 to one TAssembledTileScene; there is NO merge into a TSceneInput and NO
      re-split of the composite (which would be seconds of wasted work on a large map). Each tile
      contributes one TX3DRootNode (ground composite shape with matId+shadow streams already in the
      cached mesh, per-palette building shapes, water, POI), built with the same shaders/atlas/PBR
      appearances a fresh assembly uses, so a cache hit renders identically. ATrees receives the
      collected vegetation (for SetupForestRenderers); atlas rebuilt from settings; FarTerrain not
      cached. Caller owns the result. ACache, when supplied, provides the ground atlas + per-palette
      PBR appearances so they are NOT rebuilt here — pass the same object to every call to amortise
      that work across the session; nil = build locally. }
    { When AWarmupOnly is True the call builds and pins every shared
      resource (atlas, all landuse surface textures, all 12 building
      PBR appearances) into ACache and returns an empty result without
      touching Models — call it once at session start so streamed
      tiles only ever reference already-loaded textures. }
    { AManualScaleLat — РУЧНАЯ фиксация широты масштаба (Settings.
      WorldScaleLatDeg), 0 = авто. Развилка обязана побитно повторять
      выпечку (Osm3dBlockGenerator.EffScaleLat):
        ручная → все тайлы испечены в этой метрике, кадр = она же, Kx=1;
        авто   → каждый тайл испечён в метрике СВОЕЙ полосы
                 (WorldScaleLatBand от широты центра тайла); кадр сессии —
                 полоса от широты AOrigin; тайлы чужой полосы получают
                 масштаб X: Kx = cos(кадр)/cos(полосы тайла). Внутри полосы
                 кадра Kx = 1.0 ровно — путь побитно прежний. }
    class function AssembleCachedTiles(const Models: TTileModelArray;
      const AOrigin: TLatLon; AHeightmapZoom: Integer;
      const ASunDir: TVector3;
      out ATrees: TTileTreeRecArray;
      const APreviews: array of TTilePreviewData;
      LogProc: TLogProc = nil;
      ACache: TCachedAssemblyResources = nil;
      AWarmupOnly: Boolean = False;
      AManualScaleLat: Double = 0.0): TAssembledScenes;
  end;

{ Six-light directional rig shared by all scene-assembly paths:
  key sun + sky/ground fill + two near-horizontal wall fills (needed for
  PBR facades that have no ambient floor). CastShadows applies only to
  the sun light. Zero SunDirection defaults to Osm3dGlslLib.DEFAULT_SUN_RAY_DIR. }
procedure AddSceneLights(Root: TX3DRootNode; const SunDirection: TVector3;
  CastShadows: Boolean = False);

implementation

uses Osm3dShadowSample, Osm3dStaticGeometry, Osm3dGeoTileBlock, Osm3dRtxMaterials,
  Osm3dGenerationProgress;

{ Off by default: per-texture load tracing (see TCachedAssemblyResources.LogTex)
  is thousands of lines per session and irrelevant to geometry-build perf.
  Flip to True to restore the trace. }
var
  LOG_TEXTURE_LOADS: Boolean = False;

{ Per-kind flat-colour fallback material for landuse surfaces. Used by
  both assembly paths so the kind->material mapping lives in one place. }
const
  LANDUSE_MAT: array[TLanduseMeshKind] of TSceneMaterialKind = (
    smkForest,                                  { lkForest }
    smkGrass,                                   { lkGrass }
    smkWater,                                   { lkWater }
    smkSand,                                    { lkSand }
    smkParking,                                 { lkParking }
    smkConstruction,                            { lkConstruction }
    smkFarmland, smkFarmland, smkFarmland,      { lkFarmland0..2 }
    smkIndustrial,                              { lkIndustrial }
    smkCemetery,                                { lkCemetery }
    smkScrub,                                   { lkScrub }
    smkGrass,                                   { lkManicuredGrass }
    smkGrass,                                   { lkGarden }
    smkSand,                                    { lkRock }
    smkSand,                                    { lkGravel }
    smkRoadFootway,                             { lkPavementArea }
    smkRoad,                                    { lkAsphaltArea }
    smkRoadFootway,                             { lkCobblestone }
    smkGrass,                                   { lkPitchGeneric }
    smkGrass,                                   { lkPitchFootball }
    smkParking,                                 { lkPitchBasketball }
    smkParking,                                 { lkPitchTennis }
    smkRoad);                                   { lkHelipad }

{ PBR texture processor (unit-scoped)
 PBRTextureUnit's processor converts streets-gl PNGs (DX→GL normals,
 mask→glTF metallic-roughness) and writes the results to temp files;
 the TImageTextureNode URLs point at those temp files, so the
 processor — and its temp files — must outlive scene upload, which
 happens AFTER AssembleTiled returns. Hence it is unit-scoped, not a
 local. RecyclePBRProcessor frees the PREVIOUS one (deleting its temp
 files — safe, that scene is gone) and makes a fresh one at the start
 of each assemble. GetPBRProcessor lazily creates on first use. }
var
  FPBRProc: TPBRTextureProcessor = nil;

{ Geo-tile binning context (unit-scoped)
 The tiling phase of AssembleTiled is single-threaded, so a unit
 global is the simplest way to give BuildSortedKeys / SplitMesh /
 SplitCompositeMesh / TileBuildingMeshesGrouped access to the
 projection + grid without changing their (public) signatures.
 AssembleTiled fills this from TSceneInput.Origin before the first
 split and clears it after the last, via Begin/EndGeoTiling.
 When Active is False the tiler falls back to the legacy local
 Floor(centroid / TileSize) binning. Proj/Grid are NOT owned here —
 BeginGeoTiling creates them, EndGeoTiling frees them. }
type
  TAsmGeoTiling = record
    Active: Boolean;
    Proj:   TLocalProjection;
    Grid:   TGeoTileGrid;
    KeepTiles: TGeoTileIdArray; { nil = all; read only on this worker }
  end;

{ Per-thread: each generation worker bins its OWN block on its own thread,
  so this tiling context must not be shared. With parallel gen workers the
  old unit-global raced — one worker freed Proj/Grid in EndGeoTiling while
  another was still binning against them via PointToCell -> use-after-free.
  A threadvar is zero-initialised per thread (Active=False/Proj=nil/Grid=nil,
  matching the old explicit initialiser). Begin/EndGeoTiling run on the same
  worker thread inside one SplitInputToTiles call (EndGeoTiling in a finally),
  so set-up and teardown stay paired per thread with no leak. }
threadvar
  AsmGeoTiling: TAsmGeoTiling;

{ Fold a TGeoTileId into the (CellX, CellZ) pair the tiler sorts on. The
  slippy grid has no UTM zones (Zone=0, North=True frozen), so the cell is
  just (TX, TY). TX/TY can exceed 16 bits (up to ~2^19 at z15), so NO 16-bit
  packing — they ride Int32 directly; TileKey's +100000 offset and TileKey64's
  24-bit fields both hold that range. }
procedure GeoTileToCell(const T: TGeoTileId; out CellX, CellZ: Integer); inline;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(738);{$ENDIF}
  CellX := Integer(T.TX);
  CellZ := Integer(T.TY);
end;

{ Inverse of GeoTileToCell. }
{ Filter only final ownership, after the existing seam/anchor decisions.
  Do not clip polygons or change the global lattice at tile boundaries. }
function KeepGeoCell(CellX, CellZ: Integer): Boolean; inline;
var I: Integer;
begin
  if (not AsmGeoTiling.Active) or (Length(AsmGeoTiling.KeepTiles) = 0) then Exit(True);
  for I := 0 to High(AsmGeoTiling.KeepTiles) do
    if (AsmGeoTiling.KeepTiles[I].TX = CellX) and
       (AsmGeoTiling.KeepTiles[I].TY = CellZ) then Exit(True);
  Result := False;
end;

function CellToGeoTile(CellX, CellZ: Integer): TGeoTileId;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(739);{$ENDIF}
  Result.Zone  := 0;
  Result.North := True;
  Result.TX    := Cardinal(CellX);
  Result.TY    := Cardinal(CellZ);
end;

{ World-space XZ centre of a (CellX, CellZ) tile. For geo-cells this
  is the geo-tile centre projected back into the chunk's local frame;
  callers must only use it while AsmGeoTiling is active. }
procedure GeoCellCentre(CellX, CellZ: Integer; out CX, CZ: Single);
var
  C: TVector3;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(740);{$ENDIF}
  C  := AsmGeoTiling.Proj.Project(
          AsmGeoTiling.Grid.TileCenter(CellToGeoTile(CellX, CellZ)));
  CX := C.X;
  CZ := C.Z;
end;

{ Begin/End a geo-tiling scope. Safe to call with an empty origin —
  then geo-tiling stays inactive and the legacy path is used. }
procedure BeginGeoTiling(const Origin: TLatLon; AHeightmapZoom: Integer;
  AZonePin: Integer = 0; AScaleLatDeg: Double = 0.0);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(741);{$ENDIF}
  AsmGeoTiling.KeepTiles := nil;
  AsmGeoTiling.Active := False;
  AsmGeoTiling.Proj   := nil;
  AsmGeoTiling.Grid   := nil;
  if (Origin.Lat = 0) and (Origin.Lon = 0) then Exit;   { unset origin }
  { AScaleLatDeg pins the metres-per-degree-lon scale to the SESSION
    latitude so a block-LOCAL Origin keeps the render frame's east/west
    scale (no inter-tile cracks). 0 / out of range = use Origin.Lat. }
  AsmGeoTiling.Proj   := TLocalProjection.Create(Origin, AScaleLatDeg);
  { Slippy lattice @ heightmap zoom — edges on heightmap pixel lines, no UTM
    zone to pin. EdgePx+zoom MUST equal the carve's tag computation
    (GEO_TILE_EDGE_PX, HeightmapZoom). AZonePin accepted but ignored. }
  AsmGeoTiling.Grid   := TGeoTileGrid.Create(AHeightmapZoom, GEO_TILE_EDGE_PX, AScaleLatDeg);
  AsmGeoTiling.Active := True;
end;

procedure EndGeoTiling;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(742);{$ENDIF}
  FreeAndNil(AsmGeoTiling.Grid);
  FreeAndNil(AsmGeoTiling.Proj);
  AsmGeoTiling.KeepTiles := nil;
  AsmGeoTiling.Active := False;
end;

function GetPBRProcessor: TPBRTextureProcessor;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(743);{$ENDIF}
  if FPBRProc = nil then
    FPBRProc := TPBRTextureProcessor.Create;
  Result := FPBRProc;
end;

class function TMeshToX3D.CreateGeometry(Mesh: TMesh; ASolid: Boolean): TIndexedFaceSetNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1240);{$ENDIF}
  Result := CreateGeometry(Mesh, ASolid, uvNone);
end;

class function TMeshToX3D.CreateGeometry(Mesh: TMesh; ASolid: Boolean;
  UVMode: TUVMode): TIndexedFaceSetNode;
{ Performance-critical: called once per tile during AssembleTiled for
  buildings, water, shadows, and POI. The previous version read Mesh.Vertices
  / Mesh.Indices via property getter on every per-vertex access — each call
  trims the underlying dynarray's length and bumps its ref-count. With dozens
  of mesh categories × hundreds of tiles that cost dominated CreateShape
  time.

  Optimised: cache Mesh.Vertices and Mesh.Indices once into locals, use
  a pointer into the vertex array, and merge the two vertex passes (copy
  + UV) into one loop. Output X3D fields still receive freshly built
  arrays — the win is purely in the source-side reads. }
var
  CoordNode:    TCoordinateNode;
  NormalNode:   TNormalNode;
  TexCoordNode: TTextureCoordinateNode;
  Positions:  array of TVector3;
  Normals:    array of TVector3;
  TexCoords:  array of TVector2;
  CoordIdx:   array of LongInt;
  I, TriIdx, VC, TriCount: Integer;
  VRef:       TMeshVertexArray;
  IRef:       TMeshIndexArray;
  PV:         ^TMeshVertex;
  WantUV:     Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1241);{$ENDIF}
  Result := nil;
  if (Mesh = nil) or (Mesh.VertexCount = 0) or (Mesh.TriangleCount = 0) then Exit;

  VRef     := Mesh.Vertices;
  IRef     := Mesh.Indices;
  VC       := Mesh.VertexCount;
  TriCount := Mesh.TriangleCount;
  WantUV   := UVMode <> uvNone;

  Positions := nil; Normals := nil; TexCoords := nil; CoordIdx := nil;
  SetLength(Positions, VC);
  SetLength(Normals,   VC);
  if WantUV then SetLength(TexCoords, VC);

  if WantUV and (UVMode = uvRoofPlanar) then
  begin
    for I := 0 to VC - 1 do
    begin
      PV := @VRef[I];
      Positions[I]   := PV^.Position;
      Normals[I]     := PV^.Normal;
      TexCoords[I].X := PV^.Position.X / 4.0;
      TexCoords[I].Y := PV^.Position.Z / 4.0;
    end;
  end
  else if WantUV then
  begin
    { uvWallVertical, uvFromMesh: UV already set by the builder — copy it. }
    for I := 0 to VC - 1 do
    begin
      PV := @VRef[I];
      Positions[I] := PV^.Position;
      Normals[I]   := PV^.Normal;
      TexCoords[I] := PV^.UV;
    end;
  end
  else
  begin
    for I := 0 to VC - 1 do
    begin
      PV := @VRef[I];
      Positions[I] := PV^.Position;
      Normals[I]   := PV^.Normal;
    end;
  end;

  SetLength(CoordIdx, TriCount * 4);
  for TriIdx := 0 to TriCount - 1 do
  begin
    CoordIdx[TriIdx * 4    ] := LongInt(IRef[TriIdx * 3    ]);
    CoordIdx[TriIdx * 4 + 1] := LongInt(IRef[TriIdx * 3 + 1]);
    CoordIdx[TriIdx * 4 + 2] := LongInt(IRef[TriIdx * 3 + 2]);
    CoordIdx[TriIdx * 4 + 3] := -1;
  end;

  CoordNode := TCoordinateNode.Create;
  AssignStaticField(CoordNode.FdPoint, Positions);

  NormalNode := TNormalNode.Create;
  AssignStaticField(NormalNode.FdVector, Normals);

  Result := TIndexedFaceSetNode.Create;
  Result.Coord           := CoordNode;
  Result.Normal          := NormalNode;
  Result.NormalPerVertex := True;
  Result.Solid           := ASolid;
  AssignStaticField(Result.FdCoordIndex, CoordIdx);

  if WantUV then
  begin
    TexCoordNode := TTextureCoordinateNode.Create;
    AssignStaticField(TexCoordNode.FdPoint, TexCoords);
    Result.TexCoord := TexCoordNode;
  end;
end;

class function TMeshToX3D.CreateShape(Mesh: TMesh; MaterialKind: TSceneMaterialKind;
  ASolid: Boolean): TShapeNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1242);{$ENDIF}
  Result := CreateShape(Mesh, MaterialKind, ASolid, uvNone, nil, nil);
end;

class function TMeshToX3D.CreateShape(Mesh: TMesh; MaterialKind: TSceneMaterialKind;
  ASolid: Boolean; UVMode: TUVMode;
  Texture: TAbstractTextureNode): TShapeNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1243);{$ENDIF}
  Result := CreateShape(Mesh, MaterialKind, ASolid, UVMode, Texture, nil);
end;

class function TMeshToX3D.CreateShape(Mesh: TMesh; MaterialKind: TSceneMaterialKind;
  ASolid: Boolean; UVMode: TUVMode;
  Texture: TAbstractTextureNode;
  NormalMap: TAbstractTexture2DNode): TShapeNode;
var
  Geo: TIndexedFaceSetNode;
  Mat: TMaterialNode;
  App: TAppearanceNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1244);{$ENDIF}
  Result := nil;
  Geo := CreateGeometry(Mesh, ASolid, UVMode);
  if Geo = nil then
  begin
    { If geometry was not built — free the passed textures;
      otherwise they would be leaked (caller transferred ownership). }
    if Texture   <> nil then Texture.Free;
    if NormalMap <> nil then NormalMap.Free;
    Exit;
  end;

  Mat := TSceneMaterials.CreateMaterialNode(MaterialKind);

  { Normal map — assigned to Material.NormalTexture (X3D 4.0 standard
    slot supported by CGE via TAbstractOneSidedMaterialNode).
    CGE generates tangent space + tangent-space normal mapping in
    the shader automatically. Applied only when Texture is also
    present (UV direction is ambiguous without a diffuse channel);
    otherwise the normal map is freed. }
  if (NormalMap <> nil) and (Texture <> nil) then
    Mat.NormalTexture := NormalMap
  else if NormalMap <> nil then
    NormalMap.Free;

  Result := TShapeNode.Create;
  Result.Geometry := Geo;

  App := TAppearanceNode.Create;
  App.Material := Mat;
  if Texture <> nil then
    App.Texture := Texture;
  Result.Appearance := App;
  CompactTileGeometry(Result);
end;

class function TMeshToX3D.CreateSurfaceShape(Mesh: TMesh; KindIdx: Integer;
  FlatMat: TSceneMaterialKind): TShapeNode;
var
  Tex, NTex: TImageTextureNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1245);{$ENDIF}
  Result := nil;
  if (Mesh = nil) or (Mesh.TriangleCount = 0) then Exit;

  Tex  := TSurfaceTextures.CreateForKind(KindIdx);
  NTex := TSurfaceTextures.CreateNormalForKind(KindIdx);
  if Tex <> nil then
    Result := CreateShape(Mesh, smkSurface, True, uvFromMesh, Tex, NTex)
  else
  begin
    if NTex <> nil then NTex.Free;
    Result := CreateShape(Mesh, FlatMat, True);
  end;
end;

{ Shared by the static batches and the diagnostic instance path. }
function TrafficSignalStateShape(Atlas: TAccessoryAtlas; Mesh: TMesh): TShapeNode;
var
  Geo: TIndexedFaceSetNode;
  Mat: TMaterialNode;
  App: TAppearanceNode;
  Tex: TAbstractTexture2DNode;
begin
  Result := nil;
  Geo := TMeshToX3D.CreateGeometry(Mesh, True, uvFromMesh);
  if Geo = nil then Exit;
  if Atlas.DiffuseUrl <> '' then Tex := Atlas.CreateTextureNodeUrl
  else Tex := Atlas.CreateTextureNode;
  Mat := TMaterialNode.Create;
  Mat.DiffuseColor := Vector3(0, 0, 0);
  Mat.EmissiveColor := Vector3(1, 1, 1);
  if Tex <> nil then Mat.EmissiveTexture := Tex;
  App := TAppearanceNode.Create;
  App.Material := Mat;
  Result := TShapeNode.Create;
  Result.Geometry := Geo;
  Result.Appearance := App;
  CompactTileGeometry(Result);
end;

{ Traffic-signal POI node: a plain (lit) pole + plain caps, plus a TSwitchNode
  over the 3 traffic states. Each Switch child is a "sides" shape whose mesh UVs
  are baked to one ACCESSORY-atlas cell (no TextureTransform), with an EMISSIVE
  atlas texture so the lamp is always at full brightness regardless of the sun.
  The Switch is returned via ASwitch; the current tile flips WhichChoice to run
  the cycle. No atlas -> just pole+caps, ASwitch = nil. }
function BuildTrafficSignalNode(Atlas: TAccessoryAtlas;
  out ASwitch: TSwitchNode): TAbstractChildNode;
var
  Grp:            TGroupNode;
  PoleM, CapsM:   TMesh;
  PoleSh, CapsSh: TShapeNode;
  SGreen, SYellow, SRed:  TShapeNode;
  Sw:             TSwitchNode;

  { One "sides" sub-shape whose mesh UVs point straight at atlas cell CellIndex
    (no TextureTransform). Emissive texture -> the lamp is always at full
    brightness, independent of the sun (diffuse black, emissive white x atlas). }
  function StateShape(PrimaryCell, PerpCell: Integer): TShapeNode;
  var M: TMesh;
  begin
    M := TPOIBuilderExt.BuildTrafficSignalBoxSidesMeshXZ(
      Atlas.CellUMin(PerpCell), Atlas.CellUMax(PerpCell),
      Atlas.CellUMin(PrimaryCell), Atlas.CellUMax(PrimaryCell));
    try
      Result := TrafficSignalStateShape(Atlas, M);
    finally
      M.Free;
    end;
  end;

begin
  ASwitch := nil;
  Grp := TGroupNode.Create;

  { pole — plain, lit POI material }
  PoleM := TPOIBuilderExt.BuildTrafficSignalPoleMesh;
  try
    PoleSh := TMeshToX3D.CreateShape(PoleM, smkPOI, True);
  finally
    PoleM.Free;
  end;
  if PoleSh <> nil then Grp.AddChildren(PoleSh);

  { head caps (top + bottom) — plain, lit; no signal on top }
  CapsM := TPOIBuilderExt.BuildTrafficSignalBoxCapsMesh;
  try
    CapsSh := TMeshToX3D.CreateShape(CapsM, smkPOI, True);
  finally
    CapsM.Free;
  end;
  if CapsSh <> nil then Grp.AddChildren(CapsSh);

  { sides — a Switch over the 3 traffic states; child index = phase order
    (0=green, 1=yellow, 2=red). The tile flips WhichChoice to run the cycle. }
  if Atlas <> nil then
  begin
    SGreen  := StateShape(Ord(asTrafficGreen),  Ord(asTrafficRed));
    SYellow := StateShape(Ord(asTrafficYellow), Ord(asTrafficRed));
    SRed    := StateShape(Ord(asTrafficRed),    Ord(asTrafficGreen));
    if (SGreen <> nil) and (SYellow <> nil) and (SRed <> nil) then
    begin
      Sw := TSwitchNode.Create;
      Sw.AddChildren(SGreen);
      Sw.AddChildren(SYellow);
      Sw.AddChildren(SRed);
      Sw.WhichChoice := 0;   { start GREEN }
      Grp.AddChildren(Sw);
      ASwitch := Sw;
    end
    else
    begin
      if SGreen <> nil then SGreen.Free;
      if SYellow <> nil then SYellow.Free;
      if SRed <> nil then SRed.Free;
    end;
  end;

  Result := Grp;
end;

{ Merge compatible POI once per tile. Keep coordinates tile-local so the
  compact static fields retain their precision far from the session origin.
  The signal states share a switch, but their emissive material stays separate
  from the ordinary lit material. No vertex data changes during riding. }
function BuildPoiBatchNode(Mdl: TTileModel; AKx: Double;
  Atlas: TAccessoryAtlas; out ASwitch: TSwitchNode;
  out InstanceCount: Integer): TAbstractChildNode;
const
  PrimaryCells: array[0..2] of TAccessorySprite =
    (asTrafficGreen, asTrafficYellow, asTrafficRed);
  PerpCells: array[0..2] of TAccessorySprite =
    (asTrafficRed, asTrafficRed, asTrafficGreen);
var
  Templates: array[TPOIKindExt] of TMesh;
  SignalTemplates, SignalBatches: array[0..2] of TMesh;
  Plain, Caps: TMesh;
  Grp: TGroupNode;
  Shape: TShapeNode;
  Sw: TSwitchNode;
  Kind: TPOIKindExt;
  I, State: Integer;
  Poi: TTilePOIRec;
  Position: TVector3;
begin
  Result := nil;
  ASwitch := nil;
  InstanceCount := 0;
  if Mdl.POICount = 0 then Exit;
  for Kind := Low(TPOIKindExt) to High(TPOIKindExt) do Templates[Kind] := nil;
  for State := 0 to 2 do
  begin SignalTemplates[State] := nil; SignalBatches[State] := nil end;
  Grp := nil;
  Plain := TMesh.Create('poi_material_batch');
  try
    for I := 0 to Mdl.POICount - 1 do
    begin
      Poi := Mdl.POIs[I];
      Kind := Poi.Kind;
      if Kind = pkxNone then Continue;
      if (Kind = pkxTrafficSignal) and not RenderTrafficSignalsActive then Continue;
      if Templates[Kind] = nil then
      begin
        if Kind = pkxTrafficSignal then
        begin
          Templates[Kind] := TPOIBuilderExt.BuildTrafficSignalPoleMesh;
          Caps := TPOIBuilderExt.BuildTrafficSignalBoxCapsMesh;
          try Templates[Kind].AppendMesh(Caps) finally Caps.Free end;
          if Atlas <> nil then
            for State := 0 to 2 do
            begin
              SignalTemplates[State] := TPOIBuilderExt.BuildTrafficSignalBoxSidesMeshXZ(
                Atlas.CellUMin(Ord(PerpCells[State])), Atlas.CellUMax(Ord(PerpCells[State])),
                Atlas.CellUMin(Ord(PrimaryCells[State])), Atlas.CellUMax(Ord(PrimaryCells[State])));
              SignalBatches[State] := TMesh.Create('poi_signal_batch');
            end;
        end
        else
          Templates[Kind] := TPOIBuilderExt.BuildKindMesh(Kind);
      end;
      { Match the old instance transform: scale the position's east coordinate
        between latitude bands, preserving the model's dimensions and yaw. }
      Position := Vector3(Poi.Position.X * AKx, Poi.Position.Y, Poi.Position.Z);
      TPOIBuilderExt.AppendInstance(Plain, Templates[Kind], Position, Poi.Rotation);
      Inc(InstanceCount);
      if (Kind = pkxTrafficSignal) and (Atlas <> nil) then
        for State := 0 to 2 do
          TPOIBuilderExt.AppendInstance(SignalBatches[State], SignalTemplates[State],
            Position, Poi.Rotation);
    end;

    Grp := TGroupNode.Create;
    Shape := TMeshToX3D.CreateShape(Plain, smkPOI, True);
    if Shape <> nil then
    begin
      Shape.X3DName := 'OsmPoiBatch';
      Grp.AddChildren(Shape);
    end;
    if SignalBatches[0] <> nil then
    begin
      Sw := TSwitchNode.Create;
      Grp.AddChildren(Sw);
      for State := 0 to 2 do
      begin
        Shape := TrafficSignalStateShape(Atlas, SignalBatches[State]);
        Shape.X3DName := 'OsmPoiSignalBatch';
        Sw.AddChildren(Shape);
      end;
      Sw.WhichChoice := 0;
      ASwitch := Sw;
    end;
    Result := Grp;
    Grp := nil;
  finally
    Grp.Free;
    Plain.Free;
    for Kind := Low(TPOIKindExt) to High(TPOIKindExt) do Templates[Kind].Free;
    for State := 0 to 2 do
    begin SignalTemplates[State].Free; SignalBatches[State].Free end;
  end;
end;

type
  TKeyedTri = record
    Key:    Int64;   { encoded (CellX, CellZ) for sorting }
    TriIdx: Integer; { original triangle index in source mesh }
    CellX:  Integer;
    CellZ:  Integer;
  end;
  TKeyedTriArr = array of TKeyedTri;

{ Pack two signed integers into one Int64 for comparison.
  Offset by 100 000 to handle negative cells without sign issues. }
function TileKey(CX, CZ: Integer): Int64; inline;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(745);{$ENDIF}
  Result := (Int64(CX + 100000) shl 32) or Int64(CZ + 100000);
end;

procedure QuickSortKT(var A: TKeyedTriArr; L, R: Integer);
{ Hardened: median-of-three pivot (so already-grouped spatial keys are not
  the O(n^2) worst case), an insertion-sort cutoff for short ranges, and
  tail-recursion elimination that always RECURSES into the smaller half and
  loops on the larger — bounding stack depth to O(log n) so a large mesh
  cannot blow the stack. Final order is identical to a plain quicksort. }
const
  INSERTION_CUTOFF = 16;
var
  I, J, K: Integer;
  P: Int64;
  T: TKeyedTri;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(746);{$ENDIF}
  while L < R do
  begin
    if R - L < INSERTION_CUTOFF then
    begin
      for I := L + 1 to R do
      begin
        T := A[I];
        J := I - 1;
        while (J >= L) and (A[J].Key > T.Key) do
        begin
          A[J + 1] := A[J];
          Dec(J);
        end;
        A[J + 1] := T;
      end;
      Exit;
    end;

    { Median-of-three: sort A[L], A[K], A[R] by key; median lands at A[K]. }
    K := (L + R) shr 1;
    if A[K].Key < A[L].Key then begin T := A[L]; A[L] := A[K]; A[K] := T; end;
    if A[R].Key < A[L].Key then begin T := A[L]; A[L] := A[R]; A[R] := T; end;
    if A[R].Key < A[K].Key then begin T := A[K]; A[K] := A[R]; A[R] := T; end;
    P := A[K].Key;

    I := L; J := R;
    repeat
      while A[I].Key < P do Inc(I);
      while A[J].Key > P do Dec(J);
      if I <= J then
      begin
        T := A[I]; A[I] := A[J]; A[J] := T;
        Inc(I); Dec(J);
      end;
    until I > J;

    { Recurse into the smaller partition, iterate on the larger. }
    if (J - L) < (R - I) then
    begin
      if L < J then QuickSortKT(A, L, J);
      L := I;
    end
    else
    begin
      if I < R then QuickSortKT(A, I, R);
      R := J;
    end;
  end;
end;

{ Compute per-triangle keys and sort.  Returns the number of triangles
  (= TriCount of source).  Sorted receives the keyed list. }
{ Bin one point (local-metre XZ) to its (CellX,CellZ). This is the
  single point->cell mapping the whole tiler agrees on; the centroid
  AND the three triangle vertices are all classified through it, so
  "border triangle" and "which cell" are decided in one coordinate
  system — the same local metres in which the centroid is computed. }
procedure PointToCell(const X, Z: Single; TileSize: Single; UseGeo: Boolean;
  out CellX, CellZ: Integer); inline;
var
  LL: TLatLon;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1625);{$ENDIF}
  if UseGeo then
  begin
    LL := AsmGeoTiling.Proj.Unproject(X, Z);
    GeoTileToCell(AsmGeoTiling.Grid.TileAt(LL), CellX, CellZ);
  end
  else
  begin
    CellX := Floor(X / TileSize);
    CellZ := Floor(Z / TileSize);
  end;
end;

{ Compute per-triangle keys and sort. Returns the triangle count.

  Tile assignment — centroid, with a border-triangle correction.
  A triangle is normally binned by its centroid's cell. But a triangle
  straddling a tile boundary is a BORDER triangle: its centroid can
  land in either neighbouring cell depending on tiny coordinate noise,
  and because adjacent blocks derive their bboxes independently, that
  noise differs block to block — so the same seam triangle can be
  assigned to opposite tiles by the two blocks, leaving a sliver gap.

  The fix is a deterministic tie-break: classify all three vertices
  with the SAME point->cell mapping as the centroid. If they do not
  all share the centroid's cell the triangle is a border triangle;
  then assign it to the cell holding the MAJORITY of its vertices
  (2 of 3). That majority is stable under small bbox differences — the
  error band no longer flips the result. Only when all three vertices
  fall in three different cells (a corner triangle, no majority) does
  it fall back to the centroid cell. No triangle is duplicated; every
  triangle still goes to exactly one tile. }
function BuildSortedKeys(const Verts: TMeshVertexArray;
  const Idxs: TMeshIndexArray; TriCount: Integer;
  TileSize: Single; out Sorted: TKeyedTriArr): Integer;
var
  T: Integer;
  I0, I1, I2: Cardinal;
  CX, CZ: Single;
  UseGeo: Boolean;
  CenX, CenZ:    Integer;                   { centroid cell }
  V0X, V0Z, V1X, V1Z, V2X, V2Z: Integer;    { the 3 vertex cells }
  ChX, ChZ: Integer;                        { chosen cell }
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(747);{$ENDIF}
  Result := 0;
  if TriCount = 0 then begin Sorted := nil; Exit; end;

  UseGeo := AsmGeoTiling.Active;

  SetLength(Sorted, TriCount);
  for T := 0 to TriCount - 1 do
  begin
    I0 := Idxs[T * 3];
    I1 := Idxs[T * 3 + 1];
    I2 := Idxs[T * 3 + 2];

    { Classify the three vertices first. The centroid is needed ONLY as
      the fallback when all three land in three different cells (a true
      corner triangle, no majority). For every interior or edge-straddling
      triangle a vertex pair decides the cell, so the 4th point->cell
      chain (Unproject+TileAt+UTMForward+...) is skipped — ~25% of the
      whole binning cost. Output is identical to the centroid-first form:
      a cell is convex, so if all three vertices share cell C the whole
      triangle (hence its centroid) is in C too. }
    PointToCell(Verts[I0].Position.X, Verts[I0].Position.Z,
                TileSize, UseGeo, V0X, V0Z);
    PointToCell(Verts[I1].Position.X, Verts[I1].Position.Z,
                TileSize, UseGeo, V1X, V1Z);
    PointToCell(Verts[I2].Position.X, Verts[I2].Position.Z,
                TileSize, UseGeo, V2X, V2Z);

    if (V0X = V1X) and (V0Z = V1Z) then
    begin
      { v0 and v1 share a cell — majority of 2. (Covers the
        all-three-equal case too.) }
      ChX := V0X;  ChZ := V0Z;
    end
    else if (V0X = V2X) and (V0Z = V2Z) then
    begin
      { v0 and v2 share a cell. }
      ChX := V0X;  ChZ := V0Z;
    end
    else if (V1X = V2X) and (V1Z = V2Z) then
    begin
      { v1 and v2 share a cell. }
      ChX := V1X;  ChZ := V1Z;
    end
    else
    begin
      { Three different cells — no majority; fall back to the centroid
        cell. Only here do we pay for the centroid classification. }
      CX := (Verts[I0].Position.X + Verts[I1].Position.X
           + Verts[I2].Position.X) * (1.0/3.0);
      CZ := (Verts[I0].Position.Z + Verts[I1].Position.Z
           + Verts[I2].Position.Z) * (1.0/3.0);
      PointToCell(CX, CZ, TileSize, UseGeo, CenX, CenZ);
      ChX := CenX;  ChZ := CenZ;
    end;

    if not KeepGeoCell(ChX, ChZ) then Continue;
    Sorted[Result].CellX  := ChX;
    Sorted[Result].CellZ  := ChZ;
    Sorted[Result].Key    := TileKey(ChX, ChZ);
    Sorted[Result].TriIdx := T;
    Inc(Result);
  end;
  SetLength(Sorted, Result);
  if Result > 1 then
    QuickSortKT(Sorted, 0, Result - 1);
end;

{ NOTE on dup with SplitCompositeMesh below: the two functions follow
  the identical sort-then-emit pattern; they differ only in the output
  type (TMesh vs TGroundCompositeMesh) and in what AddVert copies
  (vertex vs vertex+matId+shadow). On the hot path (~500 tiles × many
  meshes per build) a callback-based dedup would replace the inner
  AddVert call with a procedure-of-object indirection, eroding the
  cache locality that makes this loop fast — so the two stay parallel.
  Keep changes synchronised. }

class function TSceneTiler.SplitMesh(Mesh: TMesh;
  TileSize: Single): TTileMeshArray;
var
  Sorted:        TKeyedTriArr;
  N, TileCount:  Integer;
  Verts:         TMeshVertexArray;
  Idxs:          TMeshIndexArray;
  VertCount:     Integer;

  { GlobalToLocal: scratch remap array of size VertCount, all -1.
    We reset only touched entries after each tile, not the whole array. }
  GlobalToLocal: array of Integer;
  Touched:       array of Integer;
  TouchCount:    Integer;

  RunStart, RunEnd, T: Integer;
  CurKey: Int64;
  M: TMesh;
  TileIdx: Integer;
  TriIdx: Integer;
  I0, I1, I2: Cardinal;

  procedure AddVert(GIdx: Cardinal);
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(748);{$ENDIF}
    if GlobalToLocal[GIdx] < 0 then
    begin
      GlobalToLocal[GIdx] := M.AddVertex(Verts[GIdx]);
      Touched[TouchCount] := GIdx;
      Inc(TouchCount);
    end;
  end;

  procedure ResetTouched;
  var K: Integer;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(749);{$ENDIF}
    for K := 0 to TouchCount - 1 do
      GlobalToLocal[Touched[K]] := -1;
    TouchCount := 0;
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1246);{$ENDIF}
  Result := nil;
  if (Mesh = nil) or (Mesh.TriangleCount = 0) then Exit;

  Verts     := Mesh.Vertices;   { trims to live count once }
  Idxs      := Mesh.Indices;
  N         := Mesh.TriangleCount;
  VertCount := Mesh.VertexCount;

  Sorted := nil;
  N := BuildSortedKeys(Verts, Idxs, N, TileSize, Sorted);
  if N = 0 then Exit;

  { Count tiles. }
  TileCount := 0;
  T := 0;
  while T < N do
  begin
    CurKey := Sorted[T].Key;
    Inc(TileCount);
    while (T < N) and (Sorted[T].Key = CurKey) do Inc(T);
  end;
  SetLength(Result, TileCount);

  { Scratch arrays. }
  GlobalToLocal := nil; Touched := nil;
  SetLength(GlobalToLocal, VertCount);
  FillDWord(GlobalToLocal[0], VertCount, Cardinal(-1));
  SetLength(Touched, VertCount);
  TouchCount := 0;

  TileIdx  := 0;
  RunStart := 0;
  while RunStart < N do
  begin
    CurKey := Sorted[RunStart].Key;
    RunEnd := RunStart;
    while (RunEnd < N) and (Sorted[RunEnd].Key = CurKey) do Inc(RunEnd);

    M := TMesh.Create(
      Format('tile_%d_%d', [Sorted[RunStart].CellX, Sorted[RunStart].CellZ]));

    { Estimate vertex count = up to 3 × triangle count (worst case no sharing). }
    M.ReserveVertices((RunEnd - RunStart) * 3);
    M.ReserveIndices((RunEnd - RunStart) * 3);

    TouchCount := 0;
    for T := RunStart to RunEnd - 1 do
    begin
      TriIdx := Sorted[T].TriIdx;
      I0 := Idxs[TriIdx * 3];
      I1 := Idxs[TriIdx * 3 + 1];
      I2 := Idxs[TriIdx * 3 + 2];
      AddVert(I0); AddVert(I1); AddVert(I2);
      M.AddTriangle(GlobalToLocal[I0], GlobalToLocal[I1], GlobalToLocal[I2]);
    end;
    ResetTouched;

    Result[TileIdx].CellX   := Sorted[RunStart].CellX;
    Result[TileIdx].CellZ   := Sorted[RunStart].CellZ;
    if AsmGeoTiling.Active then
      GeoCellCentre(Sorted[RunStart].CellX, Sorted[RunStart].CellZ,
                    Result[TileIdx].CenterX, Result[TileIdx].CenterZ)
    else
    begin
      Result[TileIdx].CenterX := (Sorted[RunStart].CellX + 0.5) * TileSize;
      Result[TileIdx].CenterZ := (Sorted[RunStart].CellZ + 0.5) * TileSize;
    end;
    Result[TileIdx].Mesh    := M;

    Inc(TileIdx);
    RunStart := RunEnd;
  end;
end;

{ Composite variant of BuildSortedKeys: identical binning, but reads vertex
  positions through the pooled composite's accessor (PositionOf) instead of a
  TMeshVertexArray — the composite no longer holds an inline vertex array.
  Kept as a structural dup of BuildSortedKeys for the same reason SplitMesh /
  SplitCompositeMesh are dups (see the note above SplitMesh). }
function BuildSortedKeysC(Comp: TGroundCompositeMesh;
  const Idxs: TMeshIndexArray; TriCount: Integer;
  TileSize: Single; out Sorted: TKeyedTriArr): Integer;
var
  T: Integer;
  I0, I1, I2: Cardinal;
  CX, CZ: Single;
  UseGeo: Boolean;
  CenX, CenZ:    Integer;                   { centroid cell }
  V0X, V0Z, V1X, V1Z, V2X, V2Z: Integer;    { the 3 vertex cells }
  ChX, ChZ: Integer;                        { chosen cell }
  P0, P1, P2: TVector3;                     { the 3 vertex positions }
  UseTags: Boolean;
  Keys:    TTriTileKeyArray;
  key:     Int64;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1626);{$ENDIF}
  Result := 0;
  if TriCount = 0 then begin Sorted := nil; Exit; end;

  UseGeo := AsmGeoTiling.Active;
  Keys    := Comp.TriTileKeys;
  UseTags := UseGeo and (Length(Keys) >= TriCount);

  SetLength(Sorted, TriCount);
  for T := 0 to TriCount - 1 do
  begin
    if UseTags then
    begin
      key := Keys[T];
      if key >= 0 then
      begin
        { tag fast path: cell = (TX,TY), no Unproject/TileAt, no majority }
        ChX := Integer(key shr 32);
        ChZ := Integer(key and $00000000FFFFFFFF);
        if not KeepGeoCell(ChX, ChZ) then Continue;
        Sorted[Result].CellX  := ChX;
        Sorted[Result].CellZ  := ChZ;
        Sorted[Result].Key    := TileKey(ChX, ChZ);
        Sorted[Result].TriIdx := T;
        Inc(Result);
        Continue;
      end;
    end;

    I0 := Idxs[T * 3];
    I1 := Idxs[T * 3 + 1];
    I2 := Idxs[T * 3 + 2];

    P0 := Comp.PositionOf(I0);
    P1 := Comp.PositionOf(I1);
    P2 := Comp.PositionOf(I2);

    PointToCell(P0.X, P0.Z, TileSize, UseGeo, V0X, V0Z);
    PointToCell(P1.X, P1.Z, TileSize, UseGeo, V1X, V1Z);
    PointToCell(P2.X, P2.Z, TileSize, UseGeo, V2X, V2Z);

    if (V0X = V1X) and (V0Z = V1Z) then
    begin
      ChX := V0X;  ChZ := V0Z;
    end
    else if (V0X = V2X) and (V0Z = V2Z) then
    begin
      ChX := V0X;  ChZ := V0Z;
    end
    else if (V1X = V2X) and (V1Z = V2Z) then
    begin
      ChX := V1X;  ChZ := V1Z;
    end
    else
    begin
      CX := (P0.X + P1.X + P2.X) * (1.0/3.0);
      CZ := (P0.Z + P1.Z + P2.Z) * (1.0/3.0);
      PointToCell(CX, CZ, TileSize, UseGeo, CenX, CenZ);
      ChX := CenX;  ChZ := CenZ;
    end;

    if not KeepGeoCell(ChX, ChZ) then Continue;
    Sorted[Result].CellX  := ChX;
    Sorted[Result].CellZ  := ChZ;
    Sorted[Result].Key    := TileKey(ChX, ChZ);
    Sorted[Result].TriIdx := T;
    Inc(Result);
  end;
  SetLength(Sorted, Result);
  if Result > 1 then
    QuickSortKT(Sorted, 0, Result - 1);
end;

{ See note above SplitMesh re: intentional structural dup. }

{ Parallel per-tile composite builder
 SplitCompositeMesh's per-tile mesh build is embarrassingly parallel: each
 output tile is an independent run of sorted triangles writing its own
 TGroundCompositeMesh into Res[tileIdx]. The source composite is read-only;
 the only shared mutable is NextIdx (an atomic tile cursor). Each worker
 keeps its OWN GlobalToLocal/Touched remap scratch (VertCount-sized, reset
 per tile). Geo-tile CENTRES are NOT done here — they need AsmGeoTiling (a
 threadvar live only on the caller thread), so they are filled serially. }
type
  PCompTileWork = ^TCompTileWork;
  TCompTileWork = record
    Comp:      TGroundCompositeMesh;    { source, read-only }
    Idxs:      TMeshIndexArray;         { read-only }
    MatIds:    TMaterialIdArray;        { read-only }
    Sorted:    TKeyedTriArr;            { read-only }
    RunStart:  array of Integer;        { per-tile run [start,end) }
    RunEnd:    array of Integer;
    VertCount: Integer;
    TileCount: Integer;
    NextIdx:   LongInt;                 { shared atomic tile cursor }
    Res:       TTileCompositeMeshArray; { shared output; disjoint writes }
  end;

  TCompTileWorker = class(TThread)
  public
    Work: PCompTileWork;
    constructor Create(AWork: PCompTileWork);
  protected
    procedure Execute; override;
  end;

constructor TCompTileWorker.Create(AWork: PCompTileWork);
begin
  Work := AWork;
  inherited Create(False);   { CreateSuspended=False -> starts at once }
end;

procedure TCompTileWorker.Execute;
var
  GlobalToLocal: array of Integer;
  Touched:       array of Integer;
  TouchCount, tileIdx, T, RS, RE, TriIdx: Integer;
  I0, I1, I2: Cardinal;
  C: TGroundCompositeMesh;
  V: TMeshVertex;

  procedure AddV(GIdx: Cardinal);
  begin
    if GlobalToLocal[GIdx] < 0 then
    begin
      V.Position := Work^.Comp.PositionOf(GIdx);
      V.Normal   := Work^.Comp.NormalOf(GIdx);
      V.UV       := Work^.Comp.UVOf(GIdx);
      V.OsmId    := Work^.Comp.OsmIdOf(GIdx);
      GlobalToLocal[GIdx] := C.AppendVertex(V, Work^.MatIds[GIdx]);
      Touched[TouchCount] := GIdx;
      Inc(TouchCount);
    end;
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1247);{$ENDIF}
  SetLength(GlobalToLocal, Work^.VertCount);
  if Work^.VertCount > 0 then
    FillDWord(GlobalToLocal[0], Work^.VertCount, Cardinal(-1));
  SetLength(Touched, Work^.VertCount);
  repeat
    tileIdx := InterlockedExchangeAdd(Work^.NextIdx, 1);
    if tileIdx >= Work^.TileCount then Break;
    RS := Work^.RunStart[tileIdx];
    RE := Work^.RunEnd[tileIdx];
    C := TGroundCompositeMesh.Create(
      Format('comp_tile_%d_%d',
        [Work^.Sorted[RS].CellX, Work^.Sorted[RS].CellZ]));
    C.ReserveForSlice((RE - RS) * 3, RE - RS);
    TouchCount := 0;
    for T := RS to RE - 1 do
    begin
      TriIdx := Work^.Sorted[T].TriIdx;
      I0 := Work^.Idxs[TriIdx * 3];
      I1 := Work^.Idxs[TriIdx * 3 + 1];
      I2 := Work^.Idxs[TriIdx * 3 + 2];
      AddV(I0); AddV(I1); AddV(I2);
      C.AppendTriangle(GlobalToLocal[I0], GlobalToLocal[I1], GlobalToLocal[I2]);
    end;
    for T := 0 to TouchCount - 1 do
      GlobalToLocal[Touched[T]] := -1;     { reset remap for the next tile }
    C.TrimArrays;
    Work^.Res[tileIdx].CompositeMesh := C;
  until False;
end;

class function TSceneTiler.SplitCompositeMesh(Comp: TGroundCompositeMesh;
  TileSize: Single): TTileCompositeMeshArray;
var
  Sorted:        TKeyedTriArr;
  N, TileCount:  Integer;
  Idxs:          TMeshIndexArray;
  MatIds:        TMaterialIdArray;
  VertCount:     Integer;
  RunStart, RunEnd, T, TileIdx: Integer;
  CurKey:        Int64;
  Work:          TCompTileWork;
  Workers:       array of TCompTileWorker;
  NumThreads, wI: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1247);{$ENDIF}
  Result := nil;
  if (Comp = nil) or (Comp.TriangleCount = 0) then Exit;

  Idxs      := Comp.Indices;
  MatIds    := Comp.MaterialIds;
  N         := Comp.TriangleCount;
  VertCount := Comp.VertexCount;

  Sorted := nil;
  N := BuildSortedKeysC(Comp, Idxs, N, TileSize, Sorted);
  if N = 0 then Exit;

  { Count tiles. }
  TileCount := 0;
  T := 0;
  while T < N do
  begin
    CurKey := Sorted[T].Key;
    Inc(TileCount);
    while (T < N) and (Sorted[T].Key = CurKey) do Inc(T);
  end;
  SetLength(Result, TileCount);

  { Serial pass: per-tile run bounds + cell + centre. The centre needs
    AsmGeoTiling (a threadvar live only on THIS thread), so it cannot run
    inside the worker pool — done here. }
  SetLength(Work.RunStart, TileCount);
  SetLength(Work.RunEnd,   TileCount);
  TileIdx  := 0;
  RunStart := 0;
  while RunStart < N do
  begin
    CurKey := Sorted[RunStart].Key;
    RunEnd := RunStart;
    while (RunEnd < N) and (Sorted[RunEnd].Key = CurKey) do Inc(RunEnd);
    Work.RunStart[TileIdx] := RunStart;
    Work.RunEnd[TileIdx]   := RunEnd;
    Result[TileIdx].CellX  := Sorted[RunStart].CellX;
    Result[TileIdx].CellZ  := Sorted[RunStart].CellZ;
    if AsmGeoTiling.Active then
      GeoCellCentre(Sorted[RunStart].CellX, Sorted[RunStart].CellZ,
                    Result[TileIdx].CenterX, Result[TileIdx].CenterZ)
    else
    begin
      Result[TileIdx].CenterX := (Sorted[RunStart].CellX + 0.5) * TileSize;
      Result[TileIdx].CenterZ := (Sorted[RunStart].CellZ + 0.5) * TileSize;
    end;
    Inc(TileIdx);
    RunStart := RunEnd;
  end;

  { Parallel pass: build every tile's composite mesh. Each worker holds its
    own VertCount-sized remap scratch, so cap the pool to bound memory. }
  Work.Comp      := Comp;
  Work.Idxs      := Idxs;
  Work.MatIds    := MatIds;
  Work.Sorted    := Sorted;
  Work.VertCount := VertCount;
  Work.TileCount := TileCount;
  Work.NextIdx   := 0;
  Work.Res       := Result;

  NumThreads := TThread.ProcessorCount;
  if NumThreads < 1 then NumThreads := 1;
  if NumThreads > 8 then NumThreads := 8;          { bound per-thread scratch RAM }
  if NumThreads > TileCount then NumThreads := TileCount;
  if NumThreads < 1 then NumThreads := 1;

  SetLength(Workers, NumThreads);
  for wI := 0 to NumThreads - 1 do Workers[wI] := TCompTileWorker.Create(@Work);
  for wI := 0 to NumThreads - 1 do Workers[wI].WaitFor;
  for wI := 0 to NumThreads - 1 do Workers[wI].Free;
end;

{ Build an IndexedFaceSet from the composite TMesh and attach a
  TFloatVertexAttributeNode("materialId", numComponents=1) with values
  taken from Composite.MaterialIds.

  Why we don't reuse Osm3dSceneMeshToX3D.CreateGeometry: that helper
  doesn't expose FdAttrib (it always emits position/normal/uv only and
  has no path for additional vertex attributes). Reimplementing here
  keeps the helper untouched. }

function BuildIndexedFaceSet(Composite: TGroundCompositeMesh;
  AttachMaterialIdAttribute: Boolean;
  LogProc: TLogProc): TIndexedFaceSetNode;
{ Performance-critical: called once per tile by CreateShapeTiled (~500 tiles × ~17M-vertex city
  composite). So: cache TMesh.Vertices/.Indices and TGroundCompositeMesh.MaterialIds into locals
  ONCE (direct array indexing, no property-getter ref-count bump per read), do all per-vertex copies
  in a single loop, and gate every diagnostic accumulator (bbox, materialId histogram, coordIndex
  min/max) behind DoLog := Assigned(LogProc) so a nil-LogProc tile caller skips the whole diagnostic
  block (~24 comparisons/vertex off the hot path). }
var
  EntRef:       TPoolVertexArray;
  VtRef:        TCompositeVertexArray;
  IRef:         TMeshIndexArray;
  MRef:         TMaterialIdArray;

  Positions:    array of TVector3;
  Normals:      array of TVector3;
  UVs:          array of TVector2;
  CoordIdx:     array of LongInt;
  MatIdValues:  array of Single;
  UVValues:     array of Single;     { interleaved: x0,y0, x1,y1, ... }
  NormalValues: array of Single;    { interleaved: x0,y0,z0, x1,y1,z1, ... }

  CoordNode:    TCoordinateNode;
  NormalNode:   TNormalNode;
  TexCoordNode: TTextureCoordinateNode;
  MatIdAttr, UVAttr, NormalAttr: TFloatVertexAttributeNode;

  I, TriIdx, TriCount, VC: Integer;
  DoLog:        Boolean;
  DoAttrs:      Boolean;
  KeepStandardUV: Boolean;
  PE:           ^TPoolVertex;        { pointer into EntRef — avoids per-access dynarray range check }
  UVI:          TVector2;            { this compVert's UV (lives on VtRef, not the pool) }
  Mid:          TGroundMaterialId;

  { Diagnostic accumulators — only valid when DoLog is True. }
  MinPos, MaxPos: TVector3;
  MinUV,  MaxUV:  TVector2;
  MinNormal, MaxNormal: TVector3;
  MinMatId, MaxMatId: Integer;
  MinIdx, MaxIdx: LongInt;
  ZeroMatCount: Integer;
  IdHistogram:  array[0..31] of Integer;
  K: Integer;
  HistLine: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(750);{$ENDIF}
  Result := nil;
  if (Composite = nil) or (Composite.VertexCount = 0) or
     (Composite.TriangleCount = 0) then
    Exit;

  { Cache the pooled streams once: pool entries (position+normal), the
    composite-vertex array (poolIdx+uv+osmid), the matId array, and the
    triangle indices. Per-vertex reads below are then direct indexing. }
  EntRef   := Composite.Pool.Entries;
  VtRef    := Composite.Verts;
  IRef     := Composite.Indices;
  MRef     := Composite.MaterialIds;
  VC       := Composite.VertexCount;
  TriCount := Composite.TriangleCount;
  DoLog    := Assigned(LogProc);
  DoAttrs  := AttachMaterialIdAttribute;
  KeepStandardUV := (not DoAttrs) or Osm3dStudioSettings.BuildingShadowsActive;

  Assert(Length(MRef) >= VC,
    'GroundComposite: materialIds size mismatch on shape build');

  { Allocate output arrays. Initialise managed dynarrays to nil so
 FPC's flow analysis (hint 5091) is silent. SetLength reallocates. }
  Positions    := nil; Normals     := nil; UVs       := nil;
  CoordIdx     := nil; MatIdValues := nil;
  UVValues     := nil; NormalValues := nil;

  SetLength(Positions,   VC);
  SetLength(Normals,     VC);
  if KeepStandardUV then SetLength(UVs, VC);
  if DoAttrs then SetLength(MatIdValues, VC);
  if DoAttrs then
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1628);{$ENDIF}
    SetLength(UVValues,     VC * 2);
    SetLength(NormalValues, VC * 3);
  end;

  if DoLog then
  begin
    MinPos    := EntRef[VtRef[0].PoolIdx].Position;  MaxPos    := MinPos;
    MinNormal := EntRef[VtRef[0].PoolIdx].Normal;    MaxNormal := MinNormal;
    MinUV     := VtRef[0].UV;                         MaxUV     := MinUV;
    MinMatId  := High(Integer);        MaxMatId  := Low(Integer);
    ZeroMatCount := 0;
    for K := 0 to High(IdHistogram) do IdHistogram[K] := 0;
  end;

  { ONE pass over vertices: copy pos/normal/UV/matId (+ attrs if needed)
 plus any diagnostic accumulators. The branch on DoAttrs and DoLog is
 constant for the whole loop and is reliably predicted; the body still
 streams the source array linearly so the CPU keeps the cache hot. }
  for I := 0 to VC - 1 do
  begin
    PE  := @EntRef[VtRef[I].PoolIdx];
    UVI := VtRef[I].UV;
    Mid := MRef[I];

    Positions[I]   := PE^.Position;
    Normals[I]     := PE^.Normal;
    if KeepStandardUV then UVs[I] := UVI;
    if DoAttrs then MatIdValues[I] := Mid;

    if DoAttrs then
    begin
      UVValues[I * 2]     := UVI.X;
      UVValues[I * 2 + 1] := UVI.Y;
      NormalValues[I * 3]     := PE^.Normal.X;
      NormalValues[I * 3 + 1] := PE^.Normal.Y;
      NormalValues[I * 3 + 2] := PE^.Normal.Z;
    end;

    if DoLog then
    begin
      if PE^.Position.X < MinPos.X then MinPos.X := PE^.Position.X
      else if PE^.Position.X > MaxPos.X then MaxPos.X := PE^.Position.X;
      if PE^.Position.Y < MinPos.Y then MinPos.Y := PE^.Position.Y
      else if PE^.Position.Y > MaxPos.Y then MaxPos.Y := PE^.Position.Y;
      if PE^.Position.Z < MinPos.Z then MinPos.Z := PE^.Position.Z
      else if PE^.Position.Z > MaxPos.Z then MaxPos.Z := PE^.Position.Z;

      if PE^.Normal.X < MinNormal.X then MinNormal.X := PE^.Normal.X
      else if PE^.Normal.X > MaxNormal.X then MaxNormal.X := PE^.Normal.X;
      if PE^.Normal.Y < MinNormal.Y then MinNormal.Y := PE^.Normal.Y
      else if PE^.Normal.Y > MaxNormal.Y then MaxNormal.Y := PE^.Normal.Y;
      if PE^.Normal.Z < MinNormal.Z then MinNormal.Z := PE^.Normal.Z
      else if PE^.Normal.Z > MaxNormal.Z then MaxNormal.Z := PE^.Normal.Z;

      if UVI.X < MinUV.X then MinUV.X := UVI.X
      else if UVI.X > MaxUV.X then MaxUV.X := UVI.X;
      if UVI.Y < MinUV.Y then MinUV.Y := UVI.Y
      else if UVI.Y > MaxUV.Y then MaxUV.Y := UVI.Y;

      if Mid < MinMatId then MinMatId := Mid;
      if Mid > MaxMatId then MaxMatId := Mid;
      if Mid = 0 then Inc(ZeroMatCount);
      if (Mid >= 0) and (Mid <= 31) then Inc(IdHistogram[Mid]);
    end;
  end;

  { Triangle indices: TMesh stores flat 3-per-tri, X3D wants
 face-terminator -1 between polys. Two specialised loops avoid a
 branch in the inner body. }
  SetLength(CoordIdx, TriCount * 4);
  if DoLog then
  begin
    MinIdx := MaxLongInt;
    MaxIdx := -MaxLongInt;
    for TriIdx := 0 to TriCount - 1 do
    begin
      CoordIdx[TriIdx * 4    ] := LongInt(IRef[TriIdx * 3    ]);
      CoordIdx[TriIdx * 4 + 1] := LongInt(IRef[TriIdx * 3 + 1]);
      CoordIdx[TriIdx * 4 + 2] := LongInt(IRef[TriIdx * 3 + 2]);
      CoordIdx[TriIdx * 4 + 3] := -1;
      if CoordIdx[TriIdx * 4    ] < MinIdx then MinIdx := CoordIdx[TriIdx * 4    ];
      if CoordIdx[TriIdx * 4    ] > MaxIdx then MaxIdx := CoordIdx[TriIdx * 4    ];
      if CoordIdx[TriIdx * 4 + 1] < MinIdx then MinIdx := CoordIdx[TriIdx * 4 + 1];
      if CoordIdx[TriIdx * 4 + 1] > MaxIdx then MaxIdx := CoordIdx[TriIdx * 4 + 1];
      if CoordIdx[TriIdx * 4 + 2] < MinIdx then MinIdx := CoordIdx[TriIdx * 4 + 2];
      if CoordIdx[TriIdx * 4 + 2] > MaxIdx then MaxIdx := CoordIdx[TriIdx * 4 + 2];
    end;
  end
  else
  begin
    for TriIdx := 0 to TriCount - 1 do
    begin
      CoordIdx[TriIdx * 4    ] := LongInt(IRef[TriIdx * 3    ]);
      CoordIdx[TriIdx * 4 + 1] := LongInt(IRef[TriIdx * 3 + 1]);
      CoordIdx[TriIdx * 4 + 2] := LongInt(IRef[TriIdx * 3 + 2]);
      CoordIdx[TriIdx * 4 + 3] := -1;
    end;
  end;

  { Brief diagnostic dump — only on demand. }
  if DoLog then
  begin
    LogProc(Format('  GroundComposite stats: %d vertices, %d triangles, ' +
      '%d total coordIndex entries (incl -1 terminators)',
      [VC, TriCount, Length(CoordIdx)]));
    LogProc(Format('    Position bbox: [%.2f .. %.2f] [%.2f .. %.2f] [%.2f .. %.2f]',
      [MinPos.X, MaxPos.X, MinPos.Y, MaxPos.Y, MinPos.Z, MaxPos.Z]));
    LogProc(Format('    Normal  range: [%.3f .. %.3f] [%.3f .. %.3f] [%.3f .. %.3f]',
      [MinNormal.X, MaxNormal.X, MinNormal.Y, MaxNormal.Y, MinNormal.Z, MaxNormal.Z]));
    LogProc(Format('    UV      range: [%.3f .. %.3f] [%.3f .. %.3f]',
      [MinUV.X, MaxUV.X, MinUV.Y, MaxUV.Y]));
    LogProc(Format('    MaterialId range: %d .. %d (zero-id count = %d)',
      [MinMatId, MaxMatId, ZeroMatCount]));
    LogProc(Format('    CoordIndex range: %d .. %d (expected 0..%d)',
      [MinIdx, MaxIdx, VC - 1]));
    if MaxIdx >= VC then
      LogProc(Format('    *** WARNING CoordIndex %d >= VertexCount %d — out of range, GPU will crash',
        [MaxIdx, VC]));
    HistLine := '';
    for K := 0 to High(IdHistogram) do
      if IdHistogram[K] > 0 then
        HistLine := HistLine + Format(' [%d]=%d', [K, IdHistogram[K]]);
    LogProc('    Per-material vertex counts:' + HistLine);
  end;

  { Assemble X3D nodes. Solid=True: ground is back-face culled like
 every other landuse / road shape — never viewed from below. }
  CoordNode := TCoordinateNode.Create;
  AssignStaticField(CoordNode.FdPoint, Positions);

  NormalNode := TNormalNode.Create;
  AssignStaticField(NormalNode.FdVector, Normals);

  TexCoordNode := nil;
  if KeepStandardUV then
  begin
    TexCoordNode := TTextureCoordinateNode.Create;
    AssignStaticField(TexCoordNode.FdPoint, UVs);
  end;

  Result := TIndexedFaceSetNode.Create;
  Result.Coord           := CoordNode;
  Result.Normal          := NormalNode;
  Result.NormalPerVertex := True;
  Result.Solid           := True;
  Result.TexCoord        := TexCoordNode;
  AssignStaticField(Result.FdCoordIndex, CoordIdx);

  if DoAttrs then
  begin
    MatIdAttr := TFloatVertexAttributeNode.Create;
    { NameField is the GLSL attribute name CGE binds the stream to via
      "attribute float materialId" — see castleinternalarraysgenerator.pas.
      Setting X3DName (DEF identifier) instead leaves NameField empty,
      causing the NVIDIA driver to crash on glBindAttribLocation. }
    MatIdAttr.NameField     := 'materialId';
    MatIdAttr.NumComponents := 1;
    AssignStaticField(MatIdAttr.FdValue, MatIdValues);

    { groundUV — custom vec2 attribute. We can't rely on the standard
      castle_MultiTexCoord0 / TTextureCoordinateNode path because CGE
      drops the texcoord stream when the appearance carries TUnlitMaterial
      with no .Material.texture. groundUV piggybacks on the same
      glBindAttribLocation mechanism that already works for materialId. }
    UVAttr := TFloatVertexAttributeNode.Create;
    UVAttr.NameField     := 'groundUV';
    UVAttr.NumComponents := 2;
    AssignStaticField(UVAttr.FdValue, UVValues);

    { groundNormal — custom vec3 attribute. Same reason as groundUV: with
      TUnlitMaterial CGE does no lighting and so never uploads the geometry
      normal stream; the shader's per-vertex normal (vGroundNormalOS) would
      then be constant and N·L flat, leaving slopes unshaded. The NormalNode
      attached the standard way above is kept (used if the material is ever
      lit) but ignored by CGE under unlit — this is the channel that works. }
    NormalAttr := TFloatVertexAttributeNode.Create;
    NormalAttr.NameField     := 'groundNormal';
    NormalAttr.NumComponents := 3;
    AssignStaticField(NormalAttr.FdValue, NormalValues);

    Result.SetAttrib([MatIdAttr, UVAttr, NormalAttr]);
    if DoLog then
      LogProc(Format('    materialId + groundUV + groundNormal attribs attached ' +
                     '(%d matId, %d UV-floats, %d normal-floats)',
                     [Length(MatIdValues), Length(UVValues), Length(NormalValues)]));
  end
  else
  begin
    if DoLog then
      LogProc('    materialId TFloatVertexAttributeNode SKIPPED — geometry built without it');
  end;
end;

{ Build per-material LUT uniforms: uv scales, fallback colours, roughness
  and metallic. (The per-material Y-bias LUT u_ground_z_bias and the
  per-frame u_camera_pos uniform were removed: the LUT was hard-zeroed —
  carved composite meets at terrain, no per-layer VS lift — so the whole
  camera-pump chain was dead weight.) }
procedure AttachLUTUniforms(Effect: TEffectNode; Atlas: TGroundAtlas;
  LogProc: TLogProc);
var
  UVScales:       TMFFloat;
  FallbackColors: TMFVec3f;
  RoughnessArr:   TMFFloat;
  MetallicArr:    TMFFloat;
  UVArr:          array of Single;
  ColArr:         array of TVector3;
  RArr:           array of Single;
  MArr:           array of Single;
  RndArr:         array of TVector3;
  RndField:       TMFVec3f;
  I:              Integer;
  AvgR,AvgG,AvgB:  Byte;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(752);{$ENDIF}
  AttachRtxGroundCaptureFlag(Effect);
  UVArr  := nil;
  ColArr := nil;
  RArr   := nil;
  MArr   := nil;
  RndArr := nil;
  SetLength(UVArr,  GROUND_MAT_COUNT);
  SetLength(ColArr, GROUND_MAT_COUNT);
  SetLength(RArr,   GROUND_MAT_COUNT);
  SetLength(MArr,   GROUND_MAT_COUNT);
  SetLength(RndArr, GROUND_MAT_COUNT);
  for I := 0 to GROUND_MAT_COUNT - 1 do
  begin
    UVArr[I]  := Atlas.UVScale(I);
    ColArr[I] := Atlas.FallbackColor(I);
    if Atlas.CellAverageRGB(I,AvgR,AvgG,AvgB)then
      ColArr[I]:=Vector3(AvgR/255.0,AvgG/255.0,AvgB/255.0);
    RArr[I]   := Atlas.Roughness(I);
    MArr[I]   := Atlas.Metallic(I);
    RndArr[I] := Atlas.TexRandom(I);
  end;

  UVScales := TMFFloat.Create(Effect, True, 'u_ground_uv_scale', UVArr);
  Effect.AddCustomField(UVScales);

  FallbackColors := TMFVec3f.Create(Effect, True, 'u_ground_fallback_rgb', ColArr);
  Effect.AddCustomField(FallbackColors);

  RoughnessArr := TMFFloat.Create(Effect, True, 'u_ground_roughness', RArr);
  Effect.AddCustomField(RoughnessArr);

  MetallicArr := TMFFloat.Create(Effect, True, 'u_ground_metallic', MArr);
  Effect.AddCustomField(MetallicArr);

  { PBR look knobs (single float uniforms; tune here, no shader rebuild)
 normal_strength: relief multiplier — 1.0 = raw map, 2..3 = pronounced.
 ambient: normal-INDEPENDENT flat fill — lower => sun/relief reads
 more (was 0.45). exposure: pre-Reinhard gain — lower =>
 less highlight wash so relief stops clipping (was 2.0). }
  Effect.AddCustomField(TSFFloat.Create(Effect, True, 'u_ground_normal_strength', 2.0));
  Effect.AddCustomField(TSFFloat.Create(Effect, True, 'u_ground_spec_boost',      1.0));
  Effect.AddCustomField(TSFFloat.Create(Effect, True, 'u_ground_ambient',         0.18));
  Effect.AddCustomField(TSFFloat.Create(Effect, True, 'u_ground_exposure',        1.0));

  { Per-material hash randomizer params (vec3: x=block-in-tiles, y=shift,
    z=rot-radians). Fed to GLSL u_ground_rnd[]. Zero => that material off. }
  RndField := TMFVec3f.Create(Effect, True, 'u_ground_rnd', RndArr);
  Effect.AddCustomField(RndField);

  if Assigned(LogProc) then
    LogProc(Format('  GroundCompositeShape LUTs attached (%d entries: u_ground_uv_scale / fallback_color / roughness / metallic)',
      [GROUND_MAT_COUNT]));
end;

{ Attach the diffuse atlas and the normal atlas as sampler2D uniforms,
  plus the grid layout ints. Both atlas textures must have been built
  (BuildImage / BuildNormalImage) before this call.
  If PreBuiltAtlas / PreBuiltNormalAtlas are non-nil the pre-built
  texture nodes are reused (shared across tiles); otherwise new nodes
  are created from Atlas. }
procedure AttachAtlasUniforms(Effect: TEffectNode; Atlas: TGroundAtlas;
  PreBuiltAtlas: TAbstractTexture2DNode; PreBuiltNormalAtlas: TAbstractTexture2DNode;
  PreBuiltMaskAtlas: TAbstractTexture2DNode;
  LogProc: TLogProc);
var
  AtlasField:       TSFNode;
  NormalAtlasField: TSFNode;
  MaskAtlasField:   TSFNode;
  GridCols, GridRows: TSFInt32;
  AtlasTex, NormalAtlasTex, MaskAtlasTex: TAbstractTexture2DNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(753);{$ENDIF}
  { Diffuse atlas — u_ground_atlas. Priority:
      1. a caller-supplied pre-built node (shared inline-fallback atlas);
      2. else a fresh URL node when the atlas was written to PNG — CGE
         deduplicates the GPU texture by URL, so a fresh node PER EFFECT
         costs one upload and keeps every effect independent (no shared
         X3D node to detach);
      3. else a fresh inline-pixel node (legacy, only when no PNG URL). }
  if PreBuiltAtlas <> nil then
    AtlasTex := PreBuiltAtlas
  else if Atlas.DiffuseUrl <> '' then
    AtlasTex := Atlas.CreateTextureNodeUrl
  else
    AtlasTex := Atlas.CreateTextureNode;
  AtlasField := TSFNode.Create(Effect, True, 'u_ground_atlas',
                               [TAbstractTexture2DNode], AtlasTex);
  Effect.AddCustomField(AtlasField);

  { Normal atlas — u_ground_normal_atlas (same priority order). }
  if PreBuiltNormalAtlas <> nil then
    NormalAtlasTex := PreBuiltNormalAtlas
  else if Atlas.NormalUrl <> '' then
    NormalAtlasTex := Atlas.CreateNormalTextureNodeUrl
  else
    NormalAtlasTex := Atlas.CreateNormalTextureNode;
  NormalAtlasField := TSFNode.Create(Effect, True, 'u_ground_normal_atlas',
                                     [TAbstractTexture2DNode], NormalAtlasTex);
  Effect.AddCustomField(NormalAtlasField);

  { Mask atlas — u_ground_mask_atlas (same priority order). R channel =
    per-texel roughness; maskless cells carry the constant roughness baked
    in, so the shader reads roughness from here for every material. }
  if PreBuiltMaskAtlas <> nil then
    MaskAtlasTex := PreBuiltMaskAtlas
  else if Atlas.MaskUrl <> '' then
    MaskAtlasTex := Atlas.CreateMaskTextureNodeUrl
  else
    MaskAtlasTex := Atlas.CreateMaskTextureNode;
  MaskAtlasField := TSFNode.Create(Effect, True, 'u_ground_mask_atlas',
                                   [TAbstractTexture2DNode], MaskAtlasTex);
  Effect.AddCustomField(MaskAtlasField);

  GridCols := TSFInt32.Create(Effect, True, 'u_ground_grid_cols',
                              Atlas.Layout.GridCols);
  Effect.AddCustomField(GridCols);

  GridRows := TSFInt32.Create(Effect, True, 'u_ground_grid_rows',
                              Atlas.Layout.GridRows);
  Effect.AddCustomField(GridRows);

  { Cell apron inset — must match GROUND_CELL_GUTTER. '/' is real division
    in Pascal, so 8/512 → 0.015625 (not integer 0). }
  Effect.AddCustomField(TSFFloat.Create(Effect, True, 'u_ground_cell_inset',
    GROUND_CELL_GUTTER / Atlas.Layout.TilePixels));

  if Assigned(LogProc) then
  begin
    LogProc('  GroundCompositeShape atlas uniforms attached:');
    LogProc(Format('    u_ground_atlas        : TSFNode → TPixelTextureNode (%s, %s)',
      [BoolToStr(AtlasTex <> nil, 'present', 'NIL'),
       BoolToStr(PreBuiltAtlas <> nil, 'shared', 'new')]));
    LogProc(Format('    u_ground_normal_atlas : TSFNode → TPixelTextureNode (%s, %s)',
      [BoolToStr(NormalAtlasTex <> nil, 'present', 'NIL'),
       BoolToStr(PreBuiltNormalAtlas <> nil, 'shared', 'new')]));
    LogProc(Format('    u_ground_grid_cols    : %d',  [Atlas.Layout.GridCols]));
    LogProc(Format('    u_ground_grid_rows    : %d',  [Atlas.Layout.GridRows]));
  end;
end;

{ Road-halo uniforms
 Streets-gl-style sandy edge along roads. Field may be nil — then
 u_road_field_present is 0 and the FS skips the sample entirely. A
 1×1 dummy texture is bound to u_road_dist_field so the sampler always
 has a valid binding (some drivers complain about unbound samplers
 even when never read from).
 If PreBuiltFieldTex is non-nil it is reused (shared across tiles)
 instead of calling Field.CreateTextureNode. }
procedure AttachRoadHaloUniforms(Effect: TEffectNode;
  Field: TRoadDistField; PreBuiltFieldTex: TPixelTextureNode;
  LogProc: TLogProc);
const
  DEFAULT_HALO_STRENGTH = 0.85;
var
  PresentField:   TSFInt32;
  TextureField:   TSFNode;
  OriginField:    TSFVec2f;
  SizeField:      TSFVec2f;
  StrengthField:  TSFFloat;
  TexNode:        TPixelTextureNode;
  DummyImg:       TGrayscaleImage;
  Present:        Integer;
  OriginV, SizeV: TVector2;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(754);{$ENDIF}
  Present := 0;
  OriginV := Vector2(0, 0);
  SizeV   := Vector2(1, 1);

  if PreBuiltFieldTex <> nil then
  begin
    { Reuse the pre-built texture node (shared across tiled shapes). }
    TexNode := PreBuiltFieldTex;
    if (Field <> nil) and (Field.SegmentCount > 0) then
    begin
      Present := 1;
      OriginV := Vector2(Field.OriginX, Field.OriginZ);
      SizeV   := Vector2(Field.SizeX,   Field.SizeZ);
    end;
  end
  else if (Field <> nil) and (Field.SegmentCount > 0) and
     (Field.Width > 0) and (Field.Height > 0) then
  begin
    TexNode := Field.CreateTextureNode;
    Present := 1;
    OriginV := Vector2(Field.OriginX, Field.OriginZ);
    SizeV   := Vector2(Field.SizeX,   Field.SizeZ);
  end
  else
  begin
    { Bind a 1×1 zero-filled R8 texture so the GLSL sampler is always
      valid even when no roads contribute. }
    DummyImg := TGrayscaleImage.Create(1, 1);
    DummyImg.Clear(Vector4Byte(0, 0, 0, 0));
    TexNode := TPixelTextureNode.Create;
    TexNode.FdImage.Value := DummyImg;
    TexNode.RepeatS := False;
    TexNode.RepeatT := False;
  end;

  TextureField := TSFNode.Create(Effect, True, 'u_road_dist_field',
                                 [TAbstractTexture2DNode], TexNode);
  Effect.AddCustomField(TextureField);

  PresentField := TSFInt32.Create(Effect, True, 'u_road_field_present', Present);
  Effect.AddCustomField(PresentField);

  OriginField := TSFVec2f.Create(Effect, True, 'u_road_field_origin', OriginV);
  Effect.AddCustomField(OriginField);

  SizeField := TSFVec2f.Create(Effect, True, 'u_road_field_size', SizeV);
  Effect.AddCustomField(SizeField);

  StrengthField := TSFFloat.Create(Effect, True, 'u_road_halo_strength',
                                   DEFAULT_HALO_STRENGTH);
  Effect.AddCustomField(StrengthField);

  if Assigned(LogProc) then
  begin
    LogProc('  GroundCompositeShape road halo uniforms attached:');
    LogProc(Format('    u_road_field_present : %d', [Present]));
    if Present = 1 then
    begin
      LogProc(Format('    u_road_field_origin  : (%.1f, %.1f) world XZ', [OriginV.X, OriginV.Y]));
      LogProc(Format('    u_road_field_size    : (%.1f × %.1f) m',       [SizeV.X,   SizeV.Y]));
      LogProc(Format('    raster               : %d × %d  (%.2f m/texel, halo %.1f m, %d segments)',
        [Field.Width, Field.Height, Field.MPerTexel,
         Field.HaloRadiusM, Field.SegmentCount]));
    end
    else
      LogProc('    (no roads — bound 1×1 zero texture; FS short-circuits)');
    LogProc(Format('    u_road_halo_strength : %.2f', [DEFAULT_HALO_STRENGTH]));
  end;
end;

{ Create the two shader parts (vertex + fragment) using either a URL
  or embedded source. Caller passes one of the two for each shader. }
function MakeEffectPart(AShaderType: TShaderType;
  const Url, Embedded: string): TEffectPartNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(755);{$ENDIF}
  Result := TEffectPartNode.Create;
  Result.ShaderType := AShaderType;
  if Url <> '' then
    Result.SetUrl([Url])
  else
    Result.Contents := Embedded;
end;

class function TGroundCompositeShape.CreateShape(
  Composite:    TGroundCompositeMesh;
  Atlas:        TGroundAtlas;
  SunDirToward: TVector3;
  RoadDistField: TRoadDistField;
  const ShaderVertexUrl:    string;
  const ShaderFragmentUrl:  string;
  const EmbeddedVertex:     string;
  const EmbeddedFragment:   string;
  DebugTintAmount: Single;
  AttachShaderEffect: Boolean;
  AttachMaterialIdAttribute: Boolean;
  LogProc: TLogProc): TShapeNode;
var
  Geo:          TIndexedFaceSetNode;
  Effect:       TEffectNode;
  EffectVert:   TEffectPartNode;
  EffectFrag:   TEffectPartNode;
  Mat:          TUnlitMaterialNode;
  App:          TAppearanceNode;
  TintField:    TSFFloat;
  SunDirField:  TSFVec3f;
  LodNearField,  LodHeightRefField, LodGroundRefYField: TSFFloat;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1248);{$ENDIF}
  Result := nil;
  if (Composite = nil) or (Composite.TriangleCount = 0) then
  begin
    if Assigned(LogProc) then
      LogProc('  GroundCompositeShape: empty composite, no shape produced');
    Exit;
  end;
  if Atlas = nil then
    raise EInvalidOperation.Create('TGroundCompositeShape.CreateShape: Atlas is nil');

  if AttachShaderEffect then
  begin
    { Sanity: at least one of (URL, embedded) must be set for each part. }
    if (ShaderVertexUrl   = '') and (EmbeddedVertex   = '') then
      raise EInvalidOperation.Create('TGroundCompositeShape: vertex shader not provided');
    if (ShaderFragmentUrl = '') and (EmbeddedFragment = '') then
      raise EInvalidOperation.Create('TGroundCompositeShape: fragment shader not provided');
  end;

  Geo := BuildIndexedFaceSet(Composite, AttachMaterialIdAttribute, LogProc);
  if Geo = nil then Exit;

  { Use TUnlitMaterialNode: CGE applies NO lighting to unlit materials, so what the fragment shader
    writes into fragment_color is the final on-screen colour (matching streets-gl's deferred model,
    where one lighting pass does sun + ambient + LINEARtoSRGB). PhysicalMaterialNode would apply
    CGE's own PBR lighting on top of PLUG_main_texture_apply → double exposure (grass clamped near
    1.0, asphalt washed out), so unlit lets the FS port of shading.frag be the authoritative colour. }
  Mat := TUnlitMaterialNode.Create;
  Mat.EmissiveColor := Vector3(1.0, 1.0, 1.0);     { multiplied with FS-emitted RGB; 1 keeps it intact }

  App := TAppearanceNode.Create;
  App.Material := Mat;

  if Assigned(LogProc) then
  begin
    LogProc('  GroundCompositeShape material setup:');
    LogProc(Format('    Appearance.Material   : %s', [Mat.ClassName]));
    LogProc(Format('    EmissiveColor         : (%.3f, %.3f, %.3f)',
      [Mat.EmissiveColor.X, Mat.EmissiveColor.Y, Mat.EmissiveColor.Z]));
    LogProc('    (UnlitMaterial disables CGE lighting; FS controls full pixel colour.)');
  end;

  if AttachShaderEffect then
  begin
    Effect := TEffectNode.Create;
    Effect.Language := slGLSL;

    { Provides position_eye_to_world_space() etc. used by the FS for LOD.
      Engine auto-passes the required view-inverse uniforms. }
    Effect.SetShaderLibraries(['castle-shader:/EyeWorldSpace.glsl']);

    EffectVert := MakeEffectPart(stVertex,   ShaderVertexUrl,   EmbeddedVertex);
    EffectFrag := MakeEffectPart(stFragment, ShaderFragmentUrl, EmbeddedFragment);
    Effect.SetParts([EffectVert, EffectFrag]);

    { Diagnostic: confirm the actual shader text reached the EffectPart.
      .Contents is a property that lazily fetches the URL on read; if we
      see 0 bytes here when a URL was passed, the file did not resolve
      and the EffectPart is empty. Empty parts cause silent driver-side
      link failure (nvoglv64 crash on first frame on NVIDIA). }
    if Assigned(LogProc) then
    begin
      LogProc(Format('  GroundCompositeShape: VS source = %d bytes (%s)',
        [Length(EffectVert.Contents),
         BoolToStr(ShaderVertexUrl <> '', 'from URL', 'embedded')]));
      LogProc(Format('  GroundCompositeShape: FS source = %d bytes (%s)',
        [Length(EffectFrag.Contents),
         BoolToStr(ShaderFragmentUrl <> '', 'from URL', 'embedded')]));
    end;

    AttachAtlasUniforms(Effect, Atlas, nil, nil, nil, LogProc);
    AttachLUTUniforms  (Effect, Atlas, LogProc);
    AttachRoadHaloUniforms(Effect, RoadDistField, nil, LogProc);

    TintField := TSFFloat.Create(Effect, True, 'u_ground_tint_amount',
                                 DebugTintAmount);
    Effect.AddCustomField(TintField);

    { Sun direction uniform — tells the fragment shader where the sun is.
      SunDirToward = direction FROM scene TOWARD sun (= -lightRayDir).
      Falls back to the shared default (Osm3dGlslLib.DEFAULT_SUN_TOWARD)
      when zero. }
    if (SunDirToward.X = 0) and (SunDirToward.Y = 0) and (SunDirToward.Z = 0) then
      SunDirToward := DEFAULT_SUN_TOWARD;
    SunDirField := TSFVec3f.Create(Effect, True, 'gc_SunDirToward', SunDirToward);
    Effect.AddCustomField(SunDirField);

    { LOD uniforms — values come from GlobalLODConfig.
 The TSFFloat is exposedField (3rd arg True) so a runtime
 field.Send(NewValue) would push an updated value to the
 shader, but we don't change these per-frame — they're set
 once at scene build time. }
    LodNearField := TSFFloat.Create(Effect, True, 'u_lod_near_base',
                                    GlobalLODConfig.GroundNearMeters);
    Effect.AddCustomField(LodNearField);

    LodHeightRefField := TSFFloat.Create(Effect, True, 'u_lod_height_ref',
                                         GlobalLODConfig.HeightScaleRef);
    Effect.AddCustomField(LodHeightRefField);

    LodGroundRefYField := TSFFloat.Create(Effect, True, 'u_lod_ground_ref_y',
                                          GlobalLODConfig.GroundReferenceY);
    Effect.AddCustomField(LodGroundRefYField);

    App.SetEffects([Effect]);

    if Assigned(LogProc) then
      LogProc('  GroundCompositeShape: shader effect attached');
  end
  else
  begin
    if Assigned(LogProc) then
      LogProc('  GroundCompositeShape: WARNING shader effect SKIPPED ' +
              '(AttachShaderEffect=False) — geometry only, flat PBR grey. ' +
              'If the render works in this mode but crashes with the ' +
              'shader on, the GLSL is the cause; if it still crashes, ' +
              'the merged vertex/index buffer is.');
  end;

  Result := TShapeNode.Create;
  Result.Geometry   := Geo;
  Result.Appearance := App;
  CompactTileGeometry(Result);

  { Per-fragment ground profiling counter (non-tiled / non-streaming path).
    Same FS plug compose + same early-Z caveat as the tiled path above. }
  if EnableShaderAtomicCounters then
  begin
    AttachCounterEffectFS(Result, PROF_COUNTER_GROUND);
    AttachCounterEffectVS(Result.Appearance as TAppearanceNode,
                          PROF_COUNTER_GROUND_VS);
  end;

  if Assigned(LogProc) then
    LogProc(Format('  GroundCompositeShape: 1 merged shape, %d v, %d t, atlas %dx%d',
      [Composite.VertexCount, Composite.TriangleCount,
       Atlas.Layout.GridCols * Atlas.Layout.TilePixels,
       Atlas.Layout.GridRows * Atlas.Layout.TilePixels]));
end;

class procedure TGroundCompositeShape.BuildSharedTextureNodes(
  Atlas:         TGroundAtlas;
  RoadDistField: TRoadDistField;
  out AAtlasTex:     TPixelTextureNode;
  out AAtlasNormTex: TPixelTextureNode;
  out AAtlasMaskTex: TPixelTextureNode;
  out ARoadHaloTex:  TPixelTextureNode);
var
  DummyImg: TGrayscaleImage;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1249);{$ENDIF}
  AAtlasTex     := Atlas.CreateTextureNode;
  AAtlasNormTex := Atlas.CreateNormalTextureNode;
  AAtlasMaskTex := Atlas.CreateMaskTextureNode;

  if (RoadDistField <> nil) and (RoadDistField.SegmentCount > 0) and
     (RoadDistField.Width > 0) and (RoadDistField.Height > 0) then
    ARoadHaloTex := RoadDistField.CreateTextureNode
  else
  begin
    { 1×1 stub so every tile has a valid sampler binding. }
    DummyImg := TGrayscaleImage.Create(1, 1);
    DummyImg.Clear(Vector4Byte(0, 0, 0, 0));
    ARoadHaloTex := TPixelTextureNode.Create;
    ARoadHaloTex.FdImage.Value := DummyImg;
    ARoadHaloTex.RepeatS := False;
    ARoadHaloTex.RepeatT := False;
  end;
end;

{ Bind the top-down building-shadow coverage mask sampler + its object-XZ
  mapping. MaskImg is taken over by the texture node (do NOT free it after).
  When MaskImg = nil a 1x1 black ("no shadow") texture is bound so the GLSL
  sampler is always valid on every ground effect / code path. }
procedure AttachShadowMaskUniforms(Effect: TEffectNode;
  MaskImg: TGrayscaleImage; MaskImgTree: TCastleImage;
  const OriginV, SizeV: TVector2; ALogRes: Integer;
  LogProc: TLogProc; out ATex: TPixelTextureNode; out AField: TSFNode;
  out ATexTree: TPixelTextureNode);
var
  TexNode:      TPixelTextureNode;
  Dummy:        TGrayscaleImage;
  TextureField: TSFNode;
  OriginField:  TSFVec2f;
  SizeField:    TSFVec2f;
  TexelField:   TSFFloat;
  TexDimField:  TSFFloat;
  TexNodeTree:      TPixelTextureNode;
  DummyTree:        TGrayscaleImage;
  TextureFieldTree: TSFNode;
  TexDimFieldTree:  TSFFloat;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1629);{$ENDIF}
  if MaskImg <> nil then
  begin
    TexNode := TPixelTextureNode.Create;
    TexNode.FdImage.Value := MaskImg;
    {$IFDEF TEX_SIZE_PROFILE}ProfileTexNode(TexNode, 'mask');{$ENDIF}
  end
  else
  begin
    Dummy := TGrayscaleImage.Create(1, 1);
    Dummy.Clear(Vector4Byte(0, 0, 0, 0));
    TexNode := TPixelTextureNode.Create;
    TexNode.FdImage.Value := Dummy;
  end;
  TexNode.RepeatS := False;
  TexNode.RepeatT := False;

  TextureField := TSFNode.Create(Effect, True, 'gc_shadow_mask',
                                 [TAbstractTexture2DNode], TexNode);
  Effect.AddCustomField(TextureField);

  OriginField := TSFVec2f.Create(Effect, True, 'gc_shadow_origin', OriginV);
  Effect.AddCustomField(OriginField);

  SizeField := TSFVec2f.Create(Effect, True, 'gc_shadow_size', SizeV);
  Effect.AddCustomField(SizeField);

  { LOGICAL mask side (texels) for the shader = packed image HEIGHT (the
    packed image is PackedW x LogRes; width shrinks with bit-depth, height
    stays = logical side). The shader indexes logical texels, unpacks, blurs. }
  TexelField := TSFFloat.Create(Effect, True, 'gc_shadow_texels',
    Single(Max(1, ALogRes)));
  Effect.AddCustomField(TexelField);
  { packed SQUARE texture side (bytes laid out row-major); shader uses it to
    turn a linear byte index into (x,y). }
  TexDimField := TSFFloat.Create(Effect, True, 'gc_shadow_texdim',
    Single(Max(1, Integer(TexNode.FdImage.Value.Width))));
  Effect.AddCustomField(TexDimField);

  { TREE mask sampler — shares gc_shadow_texels (same LogRes), own texdim. }
  if MaskImgTree <> nil then
  begin
    TexNodeTree := TPixelTextureNode.Create;
    TexNodeTree.FdImage.Value := MaskImgTree;
  end
  else
  begin
    DummyTree := TGrayscaleImage.Create(1, 1);
    DummyTree.Clear(Vector4Byte(0, 0, 0, 0));
    TexNodeTree := TPixelTextureNode.Create;
    TexNodeTree.FdImage.Value := DummyTree;
  end;
  TexNodeTree.RepeatS := False;
  TexNodeTree.RepeatT := False;
  TextureFieldTree := TSFNode.Create(Effect, True, 'gc_shadow_mask_tree',
                                     [TAbstractTexture2DNode], TexNodeTree);
  Effect.AddCustomField(TextureFieldTree);
  TexDimFieldTree := TSFFloat.Create(Effect, True, 'gc_shadow_texdim_tree',
    Single(Max(1, Integer(TexNodeTree.FdImage.Value.Width))));
  Effect.AddCustomField(TexDimFieldTree);

  ATex := TexNode;
  AField := TextureField;
  ATexTree := TexNodeTree;


  if Assigned(LogProc) then
    LogProc(Format('  shadow mask: %s, origin (%.1f, %.1f), size (%.1f x %.1f)',
      [BoolToStr(MaskImg <> nil, 'present', '1x1 black'),
       OriginV.X, OriginV.Y, SizeV.X, SizeV.Y]));
end;

{ Project one building (wall/roof) vertex straight down the sun ray onto
  the ground plane Y=GroundY. P is the tile-local vertex (Y already world-
  absolute); Ctr is the tile centre (= Delta) baked into XZ to reach world
  space. Height above the ground datum drives the slide; Sy is the (already
  clamped) sun elevation. SunToward = scene->sun direction (= -ASunDir).
  The union of every projected building+roof triangle is the shadow — no
  silhouette/skirt, so the mask reflects the true roof shape. }
function ProjectVertToGround(const P, Ctr: TVector3; GroundY: Single;
  const SunToward: TVector3; Sy: Single; out ASlideLen: Single;
  AKx: Single = 1.0): TVector3;
var
  h, k, sx, sz, L: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1630);{$ENDIF}
  h := P.Y - GroundY;
  if h < 0 then h := 0;
  k := h / Sy;
  sx := -SunToward.X * k;
  sz := -SunToward.Z * k;
  L := Sqrt(sx * sx + sz * sz);
  if L > 200.0 then
  begin
    sx := sx * 200.0 / L;
    sz := sz * 200.0 / L;
    L  := 200.0;
  end;
  ASlideLen := L;
  { AKx — метрика тайла → метрика кадра по востоку (см. Kx монтирования):
    вершина ЛОКАЛЬНАЯ и требует того же масштаба, что видимый меш; сдвиг
    солнца sx/sz уже мировой, его не трогаем. }
  Result.X := P.X * AKx + Ctr.X + sx;
  Result.Y := GroundY;
  Result.Z := P.Z + Ctr.Z + sz;
end;

{ ShadowIntensityFor — в Osm3dTreeShadow. }

{ Texel resolution for a mask window of the given object-XZ size: one texel
  per M_PER_TEXEL metres, floor RES_MIN. The CEILING follows the tile size:
  the mask window is ~one tile (+pads/exit margins), so the old hard literal
  (1024), tuned for the 16-px lattice, collapsed texel density several-fold
  once the tile grew to 256 px. SHADOW_TEXELS_PER_HPX_MAX texels per heightmap
  pixel keeps the density stable across lattice changes (256 px -> 2048); the
  legacy 1024 stays as the ceiling's FLOOR so small lattices behave exactly as
  before, and ABS_RES_MAX bounds single-texture practicality. VRAM: R8 2048^2
  = 4 MB a tile, and larger tiles mean quadratically fewer of them resident,
  so the TOTAL mask budget is roughly lattice-invariant. SINGLE source of
  truth — the phase-2 placeholder image and the worker job
  (CollectTileSnapshot) MUST agree on this, or Update's in-place byte copy
  silently skips on a size mismatch. }
function ShadowMaskRes(ASX, ASZ: Single): Integer;
const
  { ===== EXPERIMENT KNOBS — only these three; all old limiters removed ===== }
  SHADOW_CELL_M          = 30.0;   { reference cell size, metres ("~30 m")        }
  SHADOW_TEXELS_PER_CELL = 120;      { texels per SHADOW_CELL_M -> texel = 30/this m }
  SHADOW_MAX_TEX_SIDE    = 8192;   { GL_MAX_TEXTURE_SIZE per side (verify on GPU!) }
var
  dim: Single;
  N, maxLog: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1631);{$ENDIF}
  dim := ASX;
  if ASZ > dim then dim := ASZ;
  { LOGICAL side = window / texel; texel = SHADOW_CELL_M / SHADOW_TEXELS_PER_CELL }
  Result := Round(dim * SHADOW_TEXELS_PER_CELL / SHADOW_CELL_M);
  if Result < 1 then Result := 1;
  { ONLY cap: the SQUARE packed texture (side = sqrt(LogRes^2 / N)) must fit the
    GPU limit -> LogRes <= SHADOW_MAX_TEX_SIDE * sqrt(N), N = 8 div bits. This is
    what row-packing could not do (its tall texture hit the side limit early). }
  N := 8 div ShadowMaskBitsActive;
  if N < 1 then N := 1;
  maxLog := Trunc(SHADOW_MAX_TEX_SIDE * Sqrt(N));
  if Result > maxLog then Result := maxLog;
  { shader linearises li = ly*LogRes+lx in a 32-bit int -> LogRes^2 < 2^31 }
  if Result > 46340 then Result := 46340;
end;

{ TREE_SHADOW_FILE / tree-shadow alpha state — в Osm3dTreeShadow. }

{ Rasterize one tree billboard's silhouette into the coverage mask. The card
  is a vertical quad of width W standing at BaseXZ, facing the sun horizontally
  (RightXZ is unit, perpendicular to the sun azimuth); its top edge is slid by
  SlideXZ along -sun. For each ground pixel we invert the affine (ux,vy) map,
  sample the tree texture's alpha, and where opaque write the length-graded
  intensity (union via max — darkest wins). Returns True if anything drew. }
function RasterizeTreeCardToMask(Mask, Alpha: TGrayscaleImage;
  const BaseXZ, RightXZ, SlideXZ: TVector2; W: Single;
  const OriginV, SizeV: TVector2): Boolean;
var
  resW, resH, aw, ah, x, y, minx, maxx, miny, maxy, ax, ay, inten, ap: Integer;
  Ox, Oz, EuX, EuZ, EvX, EvZ, det, wx, wz, dx, dz, ux, vy, sl: Single;
  invRW, invRH, invDet, sxRW, syRH: Single;   { hoisted loop invariants }
  c0x, c0y, c1x, c1y, c2x, c2y, c3x, c3y: Single;
  p: PByte;

  function PixX(const VX: Single): Single; inline;
  begin Result := MaskPixCoord(VX, OriginV.X, SizeV.X, resW); end;
  function PixY(const VZ: Single): Single; inline;
  begin Result := MaskPixCoord(VZ, OriginV.Y, SizeV.Y, resH); end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1632);{$ENDIF}
  Result := False;
  if (Mask = nil) or (Alpha = nil) then Exit;
  resW := Mask.Width;  resH := Mask.Height;
  aw := Alpha.Width;   ah := Alpha.Height;
  if (aw < 2) or (ah < 2) then Exit;
  EuX := W * RightXZ.X;  EuZ := W * RightXZ.Y;   { width edge  (ux 0->1) }
  EvX := SlideXZ.X;      EvZ := SlideXZ.Y;        { height edge (vy 0->1) }
  Ox := BaseXZ.X - 0.5 * EuX;  Oz := BaseXZ.Y - 0.5 * EuZ;  { base-left corner }
  det := EuX * EvZ - EuZ * EvX;
  if Abs(det) < 1e-9 then Exit;
  invDet := 1.0 / det;

  c0x := PixX(Ox);             c0y := PixY(Oz);
  c1x := PixX(Ox + EuX);       c1y := PixY(Oz + EuZ);
  c2x := PixX(Ox + EvX);       c2y := PixY(Oz + EvZ);
  c3x := PixX(Ox + EuX + EvX); c3y := PixY(Oz + EuZ + EvZ);
  minx := Max(0,        Floor(Min(Min(c0x, c1x), Min(c2x, c3x))));
  maxx := Min(resW - 1, Ceil (Max(Max(c0x, c1x), Max(c2x, c3x))));
  miny := Max(0,        Floor(Min(Min(c0y, c1y), Min(c2y, c3y))));
  maxy := Min(resH - 1, Ceil (Max(Max(c0y, c1y), Max(c2y, c3y))));

  sl := Sqrt(SlideXZ.X * SlideXZ.X + SlideXZ.Y * SlideXZ.Y);

  invRW := 1.0 / (resW - 1);  sxRW := SizeV.X * invRW;
  invRH := 1.0 / (resH - 1);  syRH := SizeV.Y * invRH;

  for y := miny to maxy do
  begin
    wz := OriginV.Y + y * syRH;   { invariant across the x-row }
    dz := wz - Oz;
    for x := minx to maxx do
    begin
      wx := OriginV.X + x * sxRW;
      dx := wx - Ox;
      ux := ( EvZ * dx - EvX * dz) * invDet;
      vy := (-EuZ * dx + EuX * dz) * invDet;
      if (ux < 0.0) or (ux > 1.0) or (vy < 0.0) or (vy > 1.0) then Continue;
      ax := Trunc(ux * (aw - 1));
      ay := Trunc(vy * (ah - 1));   { CGE images are bottom-up: row 0 = tree
                                      base, so vy (0 at foot) maps directly }
      if ax < 0 then ax := 0 else if ax > aw - 1 then ax := aw - 1;
      if ay < 0 then ay := 0 else if ay > ah - 1 then ay := ah - 1;
      ap := PByte(Alpha.PixelPtr(ax, ay))^;
      if ap < 128 then Continue;            { transparent texel -> no shadow }
      inten := ShadowIntensityFor(vy * sl);
      p := PByte(Mask.PixelPtr(x, y));
      if inten > p^ then p^ := inten;
      Result := True;
    end;
  end;
end;

{ Rasterize a round shrub shadow blob: a disc of radius R centered at the
  slid center, with a soft radial edge (the blur pass softens further). }
function RasterizeShrubBlobToMask(Mask: TGrayscaleImage;
  const CenterXZ: TVector2; R, SlideLen: Single;
  const OriginV, SizeV: TVector2): Boolean;
var
  resW, resH, x, y, minx, maxx, miny, maxy, baseInt, inten: Integer;
  cxp, czp, rxp, rzp, wx, wz, dx, dz, d, f, R2: Single;
  sxRW, syRH, inv04R, outerR: Single;   { hoisted loop invariants }
  dz2: Single;                          { dz*dz, invariant across the x-row }
  p: PByte;

  function PixX(const VX: Single): Single; inline;
  begin Result := MaskPixCoord(VX, OriginV.X, SizeV.X, resW); end;
  function PixY(const VZ: Single): Single; inline;
  begin Result := MaskPixCoord(VZ, OriginV.Y, SizeV.Y, resH); end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1633);{$ENDIF}
  Result := False;
  if (Mask = nil) or (R <= 0.01) then Exit;
  resW := Mask.Width;  resH := Mask.Height;
  R2 := R * R;
  cxp := PixX(CenterXZ.X);  czp := PixY(CenterXZ.Y);
  rxp := (R / SizeV.X) * (resW - 1);
  rzp := (R / SizeV.Y) * (resH - 1);
  minx := Max(0,        Floor(cxp - rxp));
  maxx := Min(resW - 1, Ceil (cxp + rxp));
  miny := Max(0,        Floor(czp - rzp));
  maxy := Min(resH - 1, Ceil (czp + rzp));
  baseInt := ShadowIntensityFor(SlideLen);
  sxRW   := SizeV.X / (resW - 1);
  syRH   := SizeV.Y / (resH - 1);
  outerR := 0.6 * R;
  inv04R := 1.0 / (0.4 * R);
  for y := miny to maxy do
  begin
    wz  := OriginV.Y + y * syRH;   { invariant across the x-row }
    dz  := wz - CenterXZ.Y;
    dz2 := dz * dz;
    for x := minx to maxx do
    begin
      wx := OriginV.X + x * sxRW;
      dx := wx - CenterXZ.X;
      d  := dx * dx + dz2;
      if d > R2 then Continue;
      d := Sqrt(d);
      f := 1.0;
      if d > outerR then f := (R - d) * inv04R;   { soft outer ring }
      if f <= 0.0 then Continue;
      inten := Round(baseInt * f);
      p := PByte(Mask.PixelPtr(x, y));
      if inten > p^ then p^ := inten;
      Result := True;
    end;
  end;
end;

{ World-XZ bounding box of a tree card's projected silhouette (base edge of
  width W centered at base, plus the slid top edge). }
procedure TreeCardBBox(const C: TShadowTreeCard;
  out MinX, MinZ, MaxX, MaxZ: Single);
var
  hx, hz, x0, z0, x1, z1, x2, z2, x3, z3, cx, cz: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1634);{$ENDIF}
  if C.Kind = sckShrubBlob then
  begin
    cx := C.BaseX + C.SlideX;  cz := C.BaseZ + C.SlideZ;   { disc center }
    MinX := cx - C.W;  MaxX := cx + C.W;
    MinZ := cz - C.W;  MaxZ := cz + C.W;
    Exit;
  end;
  hx := 0.5 * C.W * C.RightX;  hz := 0.5 * C.W * C.RightZ;
  x0 := C.BaseX - hx;             z0 := C.BaseZ - hz;            { base left  }
  x1 := C.BaseX + hx;             z1 := C.BaseZ + hz;            { base right }
  x2 := x0 + C.SlideX;            z2 := z0 + C.SlideZ;           { top  left  }
  x3 := x1 + C.SlideX;            z3 := z1 + C.SlideZ;           { top  right }
  MinX := Min(Min(x0, x1), Min(x2, x3));
  MaxX := Max(Max(x0, x1), Max(x2, x3));
  MinZ := Min(Min(z0, z1), Min(z2, z3));
  MaxZ := Max(Max(z0, z1), Max(z2, z3));
end;

{ Rasterize a registry tree card into a mask, looking up its alpha layer.
  No-op if the layer is unavailable. }
function RasterizeTreeCardReg(const C: TShadowTreeCard; Mask: TGrayscaleImage;
  const OriginV, SizeV: TVector2): Boolean;
var
  sl: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1635);{$ENDIF}
  if C.Kind = sckShrubBlob then
  begin
    sl := Sqrt(C.SlideX * C.SlideX + C.SlideZ * C.SlideZ);
    Result := RasterizeShrubBlobToMask(Mask,
      Vector2(C.BaseX + C.SlideX, C.BaseZ + C.SlideZ), C.W, sl, OriginV, SizeV);
    Exit;
  end;
  Result := False;
  if (C.TexId > 4) or (TreeShadowAlpha(C.TexId) = nil) then Exit;
  Result := RasterizeTreeCardToMask(Mask, TreeShadowAlpha(C.TexId),
    Vector2(C.BaseX, C.BaseZ), Vector2(C.RightX, C.RightZ),
    Vector2(C.SlideX, C.SlideZ), C.W, OriginV, SizeV);
end;

{ Collect a tile's TREE billboards as shadow cards (world XZ), to be stored
  in the shadow registry next to the building triangles so they get the exact
  same cross-tile pull and cross-pack push. Shrubs are skipped (tiny). Tree
  XZ are tile-local -> +Ctr to world (same as buildings). Each card's bbox is
  filled. Returns the trimmed array (may be empty). }
function CollectTreeCardsForModel(M: TTileModel;
  const Ctr, SunToward: TVector3;
  AKx: Single = 1.0): TShadowTreeCardArray;
var
  k, n, texId: Integer;
  tr: TTileTreeRec;
  sy, H, az, rX, rZ: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1636);{$ENDIF}
  SetLength(Result, 0);
  if M = nil then Exit;
  EnsureTreeShadowAlpha;
  sy := SunToward.Y;  if sy < 0.001 then sy := 0.001;
  az := Sqrt(SunToward.X * SunToward.X + SunToward.Z * SunToward.Z);
  if az < 1e-6 then Exit;                  { sun straight overhead -> no shadow }
  rX := SunToward.Z / az;  rZ := -SunToward.X / az;   { unit, ⟂ sun azimuth }
  SetLength(Result, M.TreeCount);
  n := 0;
  for k := 0 to M.TreeCount - 1 do
  begin
    tr := M.Trees[k];
    H := tr.Scale;
    if H <= 0.1 then Continue;
    Result[n].BaseY := tr.Y;
    Result[n].SourceHeight := H;
    Result[n].SunSlope := Vector2(SunToward.X/sy,SunToward.Z/sy);
    if tr.IsShrub then
    begin
      { round blob matching the visible crossquad mesh (XZ half-span 2.5*Scale;
        0.5*Scale is only the ground-probe footprint and is sub-pixel here).
        Center slid by ~Scale (blob center height) along -sun. }
      Result[n].Kind   := sckShrubBlob;
      Result[n].BaseX  := tr.X * AKx + Ctr.X;  Result[n].BaseZ := tr.Z + Ctr.Z;
      Result[n].RightX := rX;            Result[n].RightZ := rZ;
      Result[n].SlideX := -SunToward.X * (H / sy);
      Result[n].SlideZ := -SunToward.Z * (H / sy);
      Result[n].W      := 2.5 * H;
      Result[n].TexId  := 0;
    end
    else
    begin
      texId := Round(tr.Seed);
      if (texId < 0) or (texId > 4) then texId := 0;
      if TreeShadowAlpha(texId) = nil then Continue;
      Result[n].Kind   := sckTreeTex;
      Result[n].BaseX  := tr.X * AKx + Ctr.X;  Result[n].BaseZ := tr.Z + Ctr.Z;
      Result[n].RightX := rX;            Result[n].RightZ := rZ;
      Result[n].SlideX := -SunToward.X * (H / sy);
      Result[n].SlideZ := -SunToward.Z * (H / sy);
      Result[n].W      := H;
      Result[n].TexId  := texId;
    end;
    TreeCardBBox(Result[n], Result[n].MinX, Result[n].MinZ,
      Result[n].MaxX, Result[n].MaxZ);
    Inc(n);
  end;
  SetLength(Result, n);
end;

{ Rasterize one (object-XZ) triangle into the coverage mask, writing a
  per-vertex interpolated intensity (255 = darkest at the wall base, lower
  toward the projected tip). Union via max: overlaps keep the darkest, never
  accumulate. A,B,C are (x,z); OriginV/SizeV map object XZ -> [0,1]. }
procedure RasterizeTriToMask(Mask: TGrayscaleImage;
  const A, B, C, OriginV, SizeV: TVector2; IA, IB, IC: Byte);
var
  resW, resH, x, y, minx, maxx, miny, maxy, inten: Integer;
  ax, ay, bx, by, cx, cy, d, w0, w1, w2: Single;
  e0a, e0b, e1a, e1b, invD: Single;       { edge coefficients (invariant) }
  k0x, k1x, k0y, k1y, w0row, w1row: Single;
  p: PByte;

  function PixX(const VX: Single): Single; inline;
  begin Result := MaskPixCoord(VX, OriginV.X, SizeV.X, resW); end;
  function PixY(const VZ: Single): Single; inline;
  begin Result := MaskPixCoord(VZ, OriginV.Y, SizeV.Y, resH); end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1637);{$ENDIF}
  resW := Mask.Width;
  resH := Mask.Height;
  ax := PixX(A.X); ay := PixY(A.Y);
  bx := PixX(B.X); by := PixY(B.Y);
  cx := PixX(C.X); cy := PixY(C.Y);
  e0a := by - cy;  e0b := cx - bx;
  e1a := cy - ay;  e1b := ax - cx;
  d := e0a * (ax - cx) + e0b * (ay - cy);
  if Abs(d) < 1e-9 then Exit;
  invD := 1.0 / d;
  { Barycentrics are affine in (x,y). Precompute the per-x slopes and the
    per-row (y) offsets once, so the inner loop is two MULs + ADDs and no
    division. Evaluated (not accumulated), so there is no along-row drift. }
  k0x := e0a * invD;  k1x := e1a * invD;
  k0y := e0b * invD;  k1y := e1b * invD;
  minx := Max(0,        Floor(Min(ax, Min(bx, cx))));
  maxx := Min(resW - 1, Ceil (Max(ax, Max(bx, cx))));
  miny := Max(0,        Floor(Min(ay, Min(by, cy))));
  maxy := Min(resH - 1, Ceil (Max(ay, Max(by, cy))));
  for y := miny to maxy do
  begin
    w0row := k0y * (y - cy);
    w1row := k1y * (y - cy);
    for x := minx to maxx do
    begin
      w0 := k0x * (x - cx) + w0row;
      w1 := k1x * (x - cx) + w1row;
      w2 := 1.0 - w0 - w1;
      if (w0 >= -0.001) and (w1 >= -0.001) and (w2 >= -0.001) then
      begin
        inten := Round(w0 * IA + w1 * IB + w2 * IC);
        if inten < 0 then inten := 0 else if inten > 255 then inten := 255;
        p := PByte(Mask.PixelPtr(x, y));
        if inten > p^ then p^ := inten;   { union: darkest wins }
      end;
    end;
  end;
end;

const
  SHADOW_REG_CAP = 512;   { max tiles kept in the persistent silhouette ring }

{ Store (a copy of) a tile's projected silhouettes in the ring registry.
  Replaces an existing entry for the same tile; else fills a free slot;
  else overwrites the oldest (ring cursor). }
procedure RegisterShadowReg(var Reg: TTileShadowRegArray; var Cursor: Integer;
  const T: TGeoTileId; const Tris: TProjTriArray;
  const TreeCards: TShadowTreeCardArray;
  AMinX, AMinZ, AMaxX, AMaxZ: Single; Cap: Integer;
  const Ground: TShadowGroundTriangles);
var
  i, slot: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1638);{$ENDIF}
  if Length(Reg) < Cap then SetLength(Reg, Cap);
  slot := -1;
  for i := 0 to High(Reg) do
    if Reg[i].InUse and Reg[i].TileId.Equals(T) then begin slot := i; Break; end;
  if slot < 0 then
    for i := 0 to High(Reg) do
      if not Reg[i].InUse then begin slot := i; Break; end;
  if slot < 0 then
  begin
    slot := Cursor;
    Cursor := (Cursor + 1) mod Cap;
  end;
  Reg[slot].InUse  := True;
  Reg[slot].TileId := T;
  Reg[slot].KeyStr := T.ToString;   { cached for the by-key lookups }
  Reg[slot].Ground := Ground; { immutable snapshot, managed lifetime }
  Reg[slot].Tris   := Copy(Tris, 0, Length(Tris));
  Reg[slot].Trees  := Copy(TreeCards, 0, Length(TreeCards));
  Reg[slot].MinX := AMinX; Reg[slot].MinZ := AMinZ;
  Reg[slot].MaxX := AMaxX; Reg[slot].MaxZ := AMaxZ;
  Reg[slot].Tex  := nil;   { mask not built yet for this (re)registration }
  Reg[slot].TexTree := nil;
  { Clear the owner identity too — without this a reused ring slot keeps
    the PREVIOUS occupant's Owner pointer, which (together with TCacheTile
    address reuse) was how a stale upload slipped past the owner gate onto
    a freed node. Gen is likewise reset; StampTileMaskOwner sets both when
    the live tile is known. }
  Reg[slot].Owner := nil;
  Reg[slot].Gen   := 0;
end;

{ Rasterize every registered silhouette triangle overlapping the mask
  window into the mask. Returns True if at least one triangle was drawn. }
function RasterizeRegInto(const Reg: TTileShadowRegArray; Mask: TGrayscaleImage;
  const OriginV, SizeV: TVector2): Boolean;
var
  i, t: Integer;
  wnx, wnz, wxx, wxz: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1639);{$ENDIF}
  Result := False;
  wnx := OriginV.X;            wnz := OriginV.Y;
  wxx := OriginV.X + SizeV.X;  wxz := OriginV.Y + SizeV.Y;
  for i := 0 to High(Reg) do
    if Reg[i].InUse and (Reg[i].MaxX >= wnx) and (Reg[i].MinX <= wxx)
       and (Reg[i].MaxZ >= wnz) and (Reg[i].MinZ <= wxz) then
    begin
      for t := 0 to High(Reg[i].Tris) do
        if (Reg[i].Tris[t].MaxX >= wnx) and (Reg[i].Tris[t].MinX <= wxx)
           and (Reg[i].Tris[t].MaxZ >= wnz) and (Reg[i].Tris[t].MinZ <= wxz) then
        begin
          RasterizeTriToMask(Mask, Reg[i].Tris[t].A, Reg[i].Tris[t].B,
            Reg[i].Tris[t].C, OriginV, SizeV,
            Reg[i].Tris[t].IA, Reg[i].Tris[t].IB, Reg[i].Tris[t].IC);
          Result := True;
        end;
      for t := 0 to High(Reg[i].Trees) do
        if (Reg[i].Trees[t].MaxX >= wnx) and (Reg[i].Trees[t].MinX <= wxx)
           and (Reg[i].Trees[t].MaxZ >= wnz) and (Reg[i].Trees[t].MinZ <= wxz) then
          if RasterizeTreeCardReg(Reg[i].Trees[t], Mask, OriginV, SizeV) then
            Result := True;
    end;
end;

{ Build the ground-composite shader TEffectNode. All uniforms are
  session-global, so this is normally called ONCE (via
  TCachedAssemblyResources.EnsureGroundEffect) and the result USE-shared
  by every tile appearance. }
function BuildGroundCompositeEffect(
  Atlas:        TGroundAtlas;
  RoadDistField: TRoadDistField;
  AtlasTex:     TAbstractTexture2DNode;
  AtlasNormTex: TAbstractTexture2DNode;
  AtlasMaskTex: TAbstractTexture2DNode;
  RoadHaloTex:  TPixelTextureNode;
  SunDirToward: TVector3;
  const EmbeddedVertex, EmbeddedFragment: string): TEffectNode;
var
  EffectVert, EffectFrag: TEffectPartNode;
  TintField:   TSFFloat;
  SunDirField: TSFVec3f;
  LodNearField,  LodHeightRefField, LodGroundRefYField: TSFFloat;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1640);{$ENDIF}
  Result := TRoadGroundEffect.Create;
  Result.Language := slGLSL;
  Result.SetShaderLibraries(['castle-shader:/EyeWorldSpace.glsl']);

  EffectVert := MakeEffectPart(stVertex,   '', EmbeddedVertex);
  { BuildingShadows on: output plain LINEAR albedo so CGE lights it with its
    native shadow (building shadows land on the ground); CGE gamma-corrects
    afterwards. albedoLin is in scope in the ground FS PLUG_main_texture_apply.
    Flag off: the ground FS original self-lit sRGB output. }
  if Osm3dStudioSettings.BuildingShadowsActive then
    EffectFrag := MakeEffectPart(stFragment, '',
      '#define GC_GRASS_NATIVE_LIGHTING' + #10 + StringReplace(EmbeddedFragment,
        '    fragment_color.rgb = gc_LINEARtoSRGB(colorTM);',
        '    fragment_color.rgb = albedoLin;', []))
  else
    EffectFrag := MakeEffectPart(stFragment, '', EmbeddedFragment);
  { Water and the optional legacy masks share the wind field. Its shader
    and uniforms belong to the ground, even when CPU shadows are disabled. }
  EffectFrag.Contents := WIND_GLSL + #10 + EffectFrag.Contents;
  Result.SetParts([EffectVert, EffectFrag]);
  TRiderShadowGroundEffect(Result).SetGroundFragment(EffectFrag);
  Result.AddCustomField(TSFVec2f.Create(Result, True, 'uWindDir', GlobalWind.Direction));
  Result.AddCustomField(TSFFloat.Create(Result, True, 'uWindTime', WindNow));
  Result.AddCustomField(TSFFloat.Create(Result, True, 'uWindBase', WindCurrentBaseSpeed));
  Result.AddCustomField(TSFFloat.Create(Result, True, 'uWindGustMin', GlobalWind.GustSpeedMin));
  Result.AddCustomField(TSFFloat.Create(Result, True, 'uWindGustMax', GlobalWind.GustSpeedMax));
  Result.AddCustomField(TSFFloat.Create(Result, True, 'uWindGustSpeed', WindCurrentBaseSpeed));
  Result.AddCustomField(TSFFloat.Create(Result, True, 'uWindRepeat', GlobalWind.RepeatLength));


  AttachAtlasUniforms(Result, Atlas, AtlasTex, AtlasNormTex, AtlasMaskTex, nil);
  AttachLUTUniforms(Result, Atlas, nil);
  AttachRoadHaloUniforms(Result, RoadDistField, RoadHaloTex, nil);

  TintField := TSFFloat.Create(Result, True, 'u_ground_tint_amount', 0.0);
  Result.AddCustomField(TintField);

  if (SunDirToward.X = 0) and (SunDirToward.Y = 0) and (SunDirToward.Z = 0) then
    SunDirToward := DEFAULT_SUN_TOWARD;
  ProfilerLog(Format('GROUND SUN: gc_SunDirToward=(%.3f, %.3f, %.3f) [Y>0 = sun above horizon; Y<=0 means flat ground gets NO direct sun -> ambient-only, no PBR relief]',
    [SunDirToward.X, SunDirToward.Y, SunDirToward.Z]));
  SunDirField := TSFVec3f.Create(Result, True, 'gc_SunDirToward', SunDirToward);
  Result.AddCustomField(SunDirField);

  LodNearField := TSFFloat.Create(Result, True, 'u_lod_near_base',
                                  GlobalLODConfig.GroundNearMeters);
  Result.AddCustomField(LodNearField);
  LodHeightRefField := TSFFloat.Create(Result, True, 'u_lod_height_ref',
                                       GlobalLODConfig.HeightScaleRef);
  Result.AddCustomField(LodHeightRefField);
  LodGroundRefYField := TSFFloat.Create(Result, True, 'u_lod_ground_ref_y',
                                        GlobalLODConfig.GroundReferenceY);
  Result.AddCustomField(LodGroundRefYField);
end;

{ Per-chunk shadow-mask overlay effect. Layered as a SECOND effect on a
  composite appearance (after the shared ground effect), it darkens the
  lit colour where the coverage mask says shadow. MaskImg is taken over
  by the texture node. }
function BuildShadowMaskEffect(MaskImg: TGrayscaleImage; MaskImgTree: TCastleImage;
  const OriginV, SizeV: TVector2; ALogRes: Integer; out ATex: TPixelTextureNode;
  out AField: TSFNode; out ATexTree: TPixelTextureNode): TEffectNode;
var
  EffVert, EffFrag: TEffectPartNode;
  FSTxt: string;
  bN, bBits, bLevels, bMax: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1641);{$ENDIF}
  Result := TEffectNode.Create;
  Result.Language := slGLSL;
  EffVert := MakeEffectPart(stVertex,   '', SHADOW_MASK_VS);
  { Specialise the unpack GLSL for the chosen bit-depth by baking N/BITS/
    LEVELS/MAXVAL as literals -> NO runtime branch in the shader. }
  bBits := ShadowMaskBitsActive;
  if bBits >= 8 then bBits := 8 else if bBits >= 4 then bBits := 4
  else if bBits >= 2 then bBits := 2 else bBits := 1;
  bN := 8 div bBits;  bLevels := 1 shl bBits;  bMax := bLevels - 1;
  FSTxt := SHADOW_MASK_FS;
  FSTxt := StringReplace(FSTxt, '@N@',      IntToStr(bN),      [rfReplaceAll]);
  FSTxt := StringReplace(FSTxt, '@BITS@',   IntToStr(bBits),   [rfReplaceAll]);
  FSTxt := StringReplace(FSTxt, '@LEVELS@', IntToStr(bLevels), [rfReplaceAll]);
  FSTxt := StringReplace(FSTxt, '@MAXVAL@', IntToStr(bMax),    [rfReplaceAll]);
  { TREE unpack: inject the R4x2 or R8x2 gc_unpackMaskTree per bit depth. }
  if ShadowMaskBitsTree >= 8 then
    FSTxt := StringReplace(FSTxt, '@TREE_UNPACK@', TREE_UNPACK_R8x2, [rfReplaceAll])
  else
    FSTxt := StringReplace(FSTxt, '@TREE_UNPACK@', TREE_UNPACK_R4x2, [rfReplaceAll]);
  { The ground effect owns the wind implementation and its uniforms. }
  FSTxt := StringReplace(FSTxt, '@WIND_FUNCS@',
    'uniform vec2 uWindDir;' + #10 + 'uniform float uWindTime;' + #10 +
    'float windBend(vec2 xz);', [rfReplaceAll]);
  EffFrag := MakeEffectPart(stFragment, '', FSTxt);
  Result.SetParts([EffVert, EffFrag]);
  AttachShadowMaskUniforms(Result, MaskImg, MaskImgTree, OriginV, SizeV, ALogRes,
    nil, ATex, AField, ATexTree);
end;

class function TGroundCompositeShape.CreateShapeTiled(
  Composite:         TGroundCompositeMesh;
  Atlas:             TGroundAtlas;
  SunDirToward:      TVector3;
  RoadDistField:     TRoadDistField;
  AtlasTex:          TAbstractTexture2DNode;
  AtlasNormTex:      TAbstractTexture2DNode;
  AtlasMaskTex:      TAbstractTexture2DNode;
  RoadHaloTex:       TPixelTextureNode;
  const EmbeddedVertex:   string;
  const EmbeddedFragment: string;
  AttachShaderEffect:        Boolean;
  AttachMaterialIdAttribute: Boolean;
  LogProc: TLogProc;
  SharedEffect: TEffectNode): TShapeNode;
var
  Geo:          TIndexedFaceSetNode;
  Effect:       TEffectNode;
  Mat:          TUnlitMaterialNode;
  MatP:         TPhysicalMaterialNode;
  App:          TAppearanceNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1250);{$ENDIF}
  Result := nil;
  if (Composite = nil) or (Composite.TriangleCount = 0) then Exit;
  if Atlas = nil then
    raise EInvalidOperation.Create('TGroundCompositeShape.CreateShapeTiled: Atlas is nil');

  Geo := BuildIndexedFaceSet(Composite, AttachMaterialIdAttribute, LogProc);
  if Geo = nil then Exit;

  App := TAppearanceNode.Create;
  { Ground receives the rider depth map, but must not enter that map itself.
    Scene.CastShadows only affects shadow volumes in this CGE version.
    With a moving projector, ground self-shadowing exposes the map rectangle. }
  App.ShadowCaster := False;
  { BuildingShadows: lit white matte so CGE lights + shadows the GROUND — its
    shadow map is what building shadows fall onto (far more visible than
    building self-shadows). The FS below outputs albedo; CGE does the sun +
    shadow. Flag off: the original unlit emissive-passthrough path. }
  if Osm3dStudioSettings.BuildingShadowsActive then
  begin
    MatP := TPhysicalMaterialNode.Create;
    MatP.BaseColor := Vector3(1.0, 1.0, 1.0);
    MatP.Metallic  := 0.0;
    MatP.Roughness := 0.85;
    App.Material := MatP;
    { Ground RECEIVES shadows but must NOT cast: its mesh (footprint + the
      far silhouette skirt) spans ~km, so leaving it a caster blows up the
      light's ShadowCastersBox -> huge projection + depth range -> building
      shadows go sub-pixel AND sub-precision (their 10-50 m height is <0.5%
      of a ~9 km depth range). Excluding it shrinks the box to the buildings
      so shadows actually resolve. }
    App.ShadowCaster := False;
  end
  else
  begin
    Mat := TUnlitMaterialNode.Create;
    Mat.EmissiveColor := Vector3(1.0, 1.0, 1.0);
    App.Material := Mat;
  end;

  if AttachShaderEffect then
  begin
    if SharedEffect <> nil then
      Effect := SharedEffect
    else
      Effect := BuildGroundCompositeEffect(Atlas, RoadDistField,
        AtlasTex, AtlasNormTex, AtlasMaskTex, RoadHaloTex, SunDirToward,
        EmbeddedVertex, EmbeddedFragment);
    App.SetEffects([Effect]);
  end;

  Result := TShapeNode.Create;
  Result.Geometry   := Geo;
  Result.Appearance := App;
  CompactTileGeometry(Result);

  { Per-fragment ground profiling counter. Composes onto the ground's own
    PLUG_main_texture_apply (the ground FS is plug-based, same as water).
    This is the STREAMING path, so it covers the tiles you actually see.
    WARNING: the ground composite is the largest fill surface on screen, so
    an FS atomic counter here is the heaviest of all categories (early-Z is
    disabled on the whole ground while the flag is on). Gated; production
    runs with EnableShaderAtomicCounters = False, so no cost there. }
  if EnableShaderAtomicCounters then
  begin
    AttachCounterEffectFS(Result, PROF_COUNTER_GROUND);                       { fragments }
    AttachCounterEffectVS(Result.Appearance as TAppearanceNode,
                          PROF_COUNTER_GROUND_VS);                            { vertices  }
  end;

  if Assigned(LogProc) then
    LogProc(Format('  GroundCompositeShape tile: %d v, %d t (shared atlas)',
      [Composite.VertexCount, Composite.TriangleCount]));
end;

{ Lighting + sun-sphere helpers — shared by Assemble and AssembleTiled

 AmbientIntensity on the sun light adds a direction-independent warm
 floor to ALL surfaces regardless of normal — fixes surfaces being
 completely black when the camera faces away from the sun. }

procedure AddSceneLights(Root: TX3DRootNode; const SunDirection: TVector3;
  CastShadows: Boolean);
var
  Sun, SkyA, SkyB, Ground: TDirectionalLightNode;
  Dir: TVector3;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(758);{$ENDIF}
  if (SunDirection.X <> 0) or (SunDirection.Y <> 0) or (SunDirection.Z <> 0) then
    Dir := SunDirection
  else
    Dir := DEFAULT_SUN_RAY_DIR;

  Sun := TDirectionalLightNode.Create;
  Sun.Direction        := Dir;
  Sun.Intensity        := 1.10;
  Sun.AmbientIntensity := 0.35;
  Sun.Color            := Vector3(1.00, 0.97, 0.90);
  Sun.Global           := True;
  if CastShadows then Sun.Shadows := True;
  Root.AddChildren(Sun);

  SkyA := TDirectionalLightNode.Create;
  SkyA.Direction := Vector3(-0.408, -0.816, -0.408);
  SkyA.Intensity := 0.45;
  SkyA.Color     := Vector3(0.65, 0.79, 1.00);
  SkyA.Global    := True;
  Root.AddChildren(SkyA);

  SkyB := TDirectionalLightNode.Create;
  SkyB.Direction := Vector3(0.408, -0.816, 0.408);
  SkyB.Intensity := 0.35;
  SkyB.Color     := Vector3(0.68, 0.80, 1.00);
  SkyB.Global    := True;
  Root.AddChildren(SkyB);

  Ground := TDirectionalLightNode.Create;
  Ground.Direction := Vector3(0.0, 1.0, 0.0);
  Ground.Intensity := 0.18;
  Ground.Color     := Vector3(0.88, 0.84, 0.70);
  Ground.Global    := True;
  Root.AddChildren(Ground);

  { Horizontal sky-fill — two opposed near-horizontal lights aimed
    almost parallel to the ground so they actually graze VERTICAL
    surfaces. SkyA/SkyB above point steeply down (Dir.Y ≈ -0.82) and
    barely touch walls; on a physical (metallic-roughness) material,
    which ignores a light's AmbientIntensity floor, that left building
    facades near-black while sunlit roofs stayed bright. These two add
    the missing side illumination so PBR walls read correctly while
    keeping shape (unlike a flat emissive fill). }
  SkyA := TDirectionalLightNode.Create;
  SkyA.Direction := Vector3(-0.94, -0.18, -0.30);
  SkyA.Intensity := 0.40;
  SkyA.Color     := Vector3(0.66, 0.79, 1.00);
  SkyA.Global    := True;
  Root.AddChildren(SkyA);

  SkyB := TDirectionalLightNode.Create;
  SkyB.Direction := Vector3(0.94, -0.18, 0.30);
  SkyB.Intensity := 0.40;
  SkyB.Color     := Vector3(0.66, 0.79, 1.00);
  SkyB.Global    := True;
  Root.AddChildren(SkyB);
end;

{
 TAssembledScenes — multi-scene container for CGE-native distance
 culling. Owns every X3D node it produced; the caller's TCastleScene
 instances merely reference these roots with OwnsRootNode=False.
 }

constructor TAssembledScenes.Create;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1253);{$ENDIF}
  inherited Create;
  GlobalRoot := nil;
  Tiles := nil;
end;

destructor TAssembledScenes.Destroy;
var I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1254);{$ENDIF}
  { Free tile roots first.  Each FdChildren reference to a shared
    texture node decrements the node's ParentFields counter on Free;
    only the LAST tile root to release a shared node triggers its
    actual destruction.  X3D handles this internally. }
  for I := 0 to High(Tiles) do begin
    FreeAndNil(Tiles[I].GpuGround);FreeAndNil(Tiles[I].Soundscape);
  end;
  for I := 0 to High(Tiles) do
    if Tiles[I].Root <> nil then
    begin
      Tiles[I].Root.Free;
      Tiles[I].Root := nil;
    end;
  Tiles := nil;
  FreeAndNil(GlobalRoot);
  inherited;
end;

class function TSceneAssembler.SplitInputToTiles(const Input: TSceneInput;
  const AGenHash: string; const ATrees: TTileTreeRecArray;
  LogProc: TLogProc; const AKeepTiles: TGeoTileIdArray): TTileModelArray;
var
  Proj:   TLocalProjection;
  Grid:   TGeoTileGrid;
  { tile_id -> index into Models, so all pieces of one geo-tile land
    in the same TTileModel. }
  Index:  specialize TDictionary<Int64, Integer>;
  Models: TTileModelArray;
  Count:  Integer;

  { Stable 64-bit key for a geo-tile (zone+hemi+TX+TY). }
  function TileKey64(const T: TGeoTileId): Int64;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(786);{$ENDIF}
    Result := (Int64(T.Zone) shl 56)
           or (Int64(Ord(T.North)) shl 55)
           or (Int64(T.TX and $FFFFFF) shl 24)
           or  Int64(T.TY and $FFFFFF);
  end;

  { Return the TTileModel for tile T, creating it on first touch. }
  function ModelFor(const T: TGeoTileId): TTileModel;
  var
    K:   Int64;
    Idx: Integer;
    M:   TTileModel;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(787);{$ENDIF}
    K := TileKey64(T);
    if Index.TryGetValue(K, Idx) then
      Exit(Models[Idx]);
    M := TTileModel.Create;
    M.TileId  := T;
    { Conventional frame: the tile's own UTM-derived centre, NOT the
      chunk origin. Vertices are rebased to this in the final pass, so
      the tile file is identical no matter which chunk baked it and is
      shareable across overlapping maps. }
    M.Origin  := Grid.TileCenter(T);
    M.Box     := Grid.TileBox(T);
    M.GenHash := AGenHash;
    if Count >= Length(Models) then
      SetLength(Models, (Count + 1) * 2);
    Models[Count] := M;
    Index.Add(K, Count);
    Inc(Count);
    ModelFor := M;
  end;

  { Split one plain mesh and file every slice as a plain tile mesh. }
  procedure DistributePlain(Mesh: TMesh; Mat: TSceneMaterialKind;
    Solid: Boolean; const NamePrefix: string);
  var
    Tiles: TTileMeshArray;
    I:     Integer;
    T:     TGeoTileId;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1328);{$ENDIF}
    if (Mesh = nil) or (Mesh.TriangleCount = 0) then Exit;
    Tiles := TSceneTiler.SplitMesh(Mesh, GEO_TILE_EDGE_M);
    for I := 0 to High(Tiles) do
    begin
      T := CellToGeoTile(Tiles[I].CellX, Tiles[I].CellZ);
      ModelFor(T).AddMesh(
        Format('%s_%d_%d', [NamePrefix, Tiles[I].CellX, Tiles[I].CellZ]),
        Mat, Tiles[I].Mesh, Solid);
      { Mesh ownership transfers into the TTileModel. }
    end;
  end;

  { Distribute building meshes WHOLE per geo-tile, keyed by each
    building's footprint anchor — the cache-side equivalent of
    TileBuildingMeshesGrouped. A building straddling a tile edge goes
    entirely into ONE tile (the anchor's), so the cached + rendered
    geometry is never split mid-building. Falls back to per-triangle
    DistributePlain when no anchors are available. }
  { Общий аппендер диапазонов: добавляет треугольники [TriS,TriE) меша Src
    в аккумулятор материала MKind внутри модели тайла Tile (создаёт меш по
    имени DstName при отсутствии, флаг Shared → в AddMesh). Раньше это тело
    дублировалось в AppendRange для зданий / заборов / табличек. }
  procedure AppendRangeToTile(const Tile: TGeoTileId;
    MKind: TSceneMaterialKind; const DstName: string; Shared: Boolean;
    Src: TMesh; VS, VE, TriS, TriE: Integer);
  var
    M:     TTileModel;
    K, B, R, Remap: Integer;
    Acc:   TMesh;
    SV:    TMeshVertexArray;
    SI:    TMeshIndexArray;
  begin
    if (Src = nil) or (TriE <= TriS) then Exit;
    if not KeepGeoCell(Tile.TX, Tile.TY) then Exit;
    M := ModelFor(Tile);
    Acc := nil;
    for K := 0 to M.MeshCount - 1 do
      if (M.Meshes[K].Material = MKind)
      and (Length(M.Meshes[K].MatIds) = 0) then
      begin
        Acc := M.Meshes[K].Mesh;
        Break;
      end;
    if Acc = nil then
    begin
      Acc := TMesh.Create(DstName);
      M.AddMesh(DstName, MKind, Acc, Shared);
    end;
    SV := Src.Vertices;
    SI := Src.Indices;
    B  := Acc.VertexCount;
    for R := VS to VE - 1 do
      Acc.AddVertex(SV[R]);
    Remap := B - VS;
    for R := TriS to TriE - 1 do
      Acc.AddTriangle(
        Integer(SI[R*3])     + Remap,
        Integer(SI[R*3 + 1]) + Remap,
        Integer(SI[R*3 + 2]) + Remap);
  end;

  procedure DistributeBuildingsByAnchor;
  var
    A:      TBuildingTileAnchor;
    I:      Integer;
    LL:     TLatLon;
    T:      TGeoTileId;
    SrcW, SrcR: TMesh;

    { Append triangle range [TriS,TriE) of Src into a per-(tile,palette,
      roof) accumulator mesh inside the tile model. The accumulator is
      found/created by a stable name so all of one building's slices
      and other buildings of the same palette in the same tile merge. }
    procedure AppendRange(const Tile: TGeoTileId; ARoof: Boolean;
      Palette: Integer; Src: TMesh; VS, VE, TriS, TriE: Integer;
      ANoShadow: Boolean = False);
    var
      MKind:   TSceneMaterialKind;
      DstName: string;
    begin
      {$IFDEF IAM_LIVE}IamLiveTrack(790);{$ENDIF}
      if ARoof then
      begin
        if Palette > 5 then
        begin
          MKind   := smkBuildingRoof0;
          DstName := 'roof_p0';
        end
        else
        begin
          MKind   := TSceneMaterialKind(Ord(smkBuildingRoof0) + Palette);
          DstName := Format('roof_p%d', [Palette]);
        end;
      end
      else if ANoShadow then
      begin
        { труба туннеля: отдельный вид материала -> отдельный шейп без
          отбрасывания тени (см. dispatch smkTunnelWall) }
        MKind   := smkTunnelWall;
        DstName := 'wall_tunnel';
      end
      else
      begin
        MKind   := TSceneMaterialKind(Ord(smkBuildingWall0) + Palette);
        DstName := Format('wall_p%d', [Palette]);
      end;
      AppendRangeToTile(Tile, MKind, DstName, False, Src, VS, VE, TriS, TriE);
    end;

  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(789);{$ENDIF}
    if Length(Input.BuildingTileAnchors) = 0 then
    begin
      { Older builder / no anchors — per-triangle fallback. }
      for I := 0 to BUILDING_PALETTE_SIZE - 1 do
      begin
        DistributePlain(Input.BuildingWalls[I],
          TSceneMaterialKind(Ord(smkBuildingWall0) + I), False,
          Format('wall_p%d', [I]));
        if I <= 5 then
          DistributePlain(Input.BuildingRoofs[I],
            TSceneMaterialKind(Ord(smkBuildingRoof0) + I), False,
            Format('roof_p%d', [I]))
        else
          DistributePlain(Input.BuildingRoofs[I],
            smkBuildingRoof0, False, 'roof_p0');
      end;
      Exit;
    end;

    for I := 0 to High(Input.BuildingTileAnchors) do
    begin
      A := Input.BuildingTileAnchors[I];
      if (A.Palette < 0) or (A.Palette >= BUILDING_PALETTE_SIZE) then Continue;
      { Whole building → the tile its anchor centroid falls in. }
      LL := Proj.Unproject(A.AnchorX, A.AnchorZ);
      T  := Grid.TileAt(LL);

      SrcW := Input.BuildingWalls[A.Palette];
      SrcR := Input.BuildingRoofs[A.Palette];
      if (SrcW <> nil) and (A.WallsTriEnd > A.WallsTriStart) then
        AppendRange(T, False, A.Palette, SrcW,
          A.WallsVertStart, A.WallsVertEnd,
          A.WallsTriStart,  A.WallsTriEnd, A.NoShadowCast);
      if (SrcR <> nil) and (A.RoofsTriEnd > A.RoofsTriStart) then
        AppendRange(T, True, A.Palette, SrcR,
          A.RoofsVertStart, A.RoofsVertEnd,
          A.RoofsTriStart,  A.RoofsTriEnd);
    end;
  end;

  { Fences — each way whole into the tile of its centroid (like buildings
    by anchor), one accumulator mesh per (tile, material). Simpler than
    buildings: a single ribbon, so one range pair, no wall/roof split. }
  procedure DistributeFencesByAnchor;
  var
    A:   TFenceTileAnchor;
    I:   Integer;
    LL:  TLatLon;
    T:   TGeoTileId;
    Src: TMesh;

    procedure AppendRange(const Tile: TGeoTileId; FenceMat: Integer;
      ASrc: TMesh; VS, VE, TriS, TriE: Integer);
    var
      MKind:   TSceneMaterialKind;
      DstName: string;
    begin
      {$IFDEF IAM_LIVE}IamLiveTrack(1644);{$ENDIF}
      MKind   := TSceneMaterialKind(Ord(smkFence0) + FenceMat);
      DstName := Format('fence_p%d', [FenceMat]);
      AppendRangeToTile(Tile, MKind, DstName, False, ASrc, VS, VE, TriS, TriE);
    end;

  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1645);{$ENDIF}
    if Length(Input.FenceTileAnchors) = 0 then
    begin
      { No anchors — per-triangle fallback (as buildings do). }
      for I := 0 to FENCE_PALETTE_SIZE - 1 do
        DistributePlain(Input.Fences[I],
          TSceneMaterialKind(Ord(smkFence0) + I), False,
          Format('fence_p%d', [I]));
      Exit;
    end;

    for I := 0 to High(Input.FenceTileAnchors) do
    begin
      A := Input.FenceTileAnchors[I];
      if (A.Material < 0) or (A.Material >= FENCE_PALETTE_SIZE) then Continue;
      LL  := Proj.Unproject(A.AnchorX, A.AnchorZ);
      T   := Grid.TileAt(LL);
      Src := Input.Fences[A.Material];
      if (Src <> nil) and (A.TriEnd > A.TriStart) then
        AppendRange(T, A.Material, Src,
          A.VertStart, A.VertEnd, A.TriStart, A.TriEnd);
    end;
  end;

  { Plates — each building's whole plate into the tile of its centroid.
    Single material (smkPlate), single global mesh; glyph UVs are baked in the
    mesh, so plates ride the normal mesh serialisation (no new tile-cache
    record type). One accumulator mesh per tile. }
  procedure DistributePlatesByAnchor;
  var
    A:   TPlateTileAnchor;
    I:   Integer;
    LL:  TLatLon;
    T:   TGeoTileId;
    Src: TMesh;

    procedure AppendRange(const Tile: TGeoTileId;
      ASrc: TMesh; VS, VE, TriS, TriE: Integer);
    begin
      AppendRangeToTile(Tile, smkPlate, 'plates', True, ASrc, VS, VE, TriS, TriE);
    end;

  begin
    if (Input.Plates = nil) or (Length(Input.PlateTileAnchors) = 0) then Exit;
    Src := Input.Plates;
    for I := 0 to High(Input.PlateTileAnchors) do
    begin
      A  := Input.PlateTileAnchors[I];
      LL := Proj.Unproject(A.AnchorX, A.AnchorZ);
      T  := Grid.TileAt(LL);
      if A.TriEnd > A.TriStart then
        AppendRange(T, Src, A.VertStart, A.VertEnd, A.TriStart, A.TriEnd);
    end;
  end;

  { Split the ground composite and file every slice as a composite tile
    mesh carrying the per-vertex materialId stream. }
  procedure DistributeComposite;
  var
    Tiles:  TTileCompositeMeshArray;
    I, V:   Integer;
    T:      TGeoTileId;
    Comp:   TGroundCompositeMesh;
    MeshCp: TMesh;
    MatIds: TTileMatIdArray;
    MV:     TMeshVertex;
    TIdx:   TMeshIndexArray;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(791);{$ENDIF}
    if (Input.GroundComposite = nil)
    or (Input.GroundComposite.TriangleCount = 0) then Exit;
    Tiles := TSceneTiler.SplitCompositeMesh(
               Input.GroundComposite, GEO_TILE_EDGE_M);
    for I := 0 to High(Tiles) do
    begin
      Comp := Tiles[I].CompositeMesh;
      T    := CellToGeoTile(Tiles[I].CellX, Tiles[I].CellZ);

      { Move the slice's TMesh out of the composite wrapper — the
        TTileModel will own it; copy the parallel materialId stream. }
      MeshCp := TMesh.Create(Format('composite_%d_%d',
                  [Tiles[I].CellX, Tiles[I].CellZ]));

      { Expand the pooled tile composite into a plain TMesh — the TTileModel
        stores TMesh + a parallel matId stream. Position/normal resolve via
        the pool; UV/osmId come from the composite vertex; matId rides
        MaterialIds. The tile model and X3D codec stay byte-compatible. }
      MeshCp.ReserveVertices(Comp.VertexCount);
      MeshCp.ReserveIndices(Comp.TriangleCount * 3);
      SetLength(MatIds, Comp.VertexCount);
      for V := 0 to Comp.VertexCount - 1 do
      begin
        MV.Position := Comp.PositionOf(V);
        MV.Normal   := Comp.NormalOf(V);
        MV.UV       := Comp.UVOf(V);
        MV.OsmId    := Comp.OsmIdOf(V);
        MeshCp.AddVertex(MV);
        MatIds[V]   := Comp.MaterialIds[V];
      end;
      TIdx := Comp.Indices;
      for V := 0 to Comp.TriangleCount - 1 do
        MeshCp.AddTriangle(TIdx[V * 3], TIdx[V * 3 + 1], TIdx[V * 3 + 2]);

      ModelFor(T).AddCompositeMesh(MeshCp.Name, smkSurface,
        MeshCp, MatIds, True);

      Comp.Free;   { slice wrapper no longer needed }
    end;
  end;

  { File POI instances into their geo-tile. }
  procedure DistributePOI;
  var
    I:  Integer;
    LL: TLatLon;
    T:  TGeoTileId;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(792);{$ENDIF}
    for I := 0 to High(Input.POIInstances) do
    begin
      LL := Proj.Unproject(Input.POIInstances[I].Position.X,
                            Input.POIInstances[I].Position.Z);
      T  := Grid.TileAt(LL);
      if not KeepGeoCell(T.TX, T.TY) then Continue;
      ModelFor(T).AddPOI(Input.POIInstances[I].Kind,
                         Input.POIInstances[I].Position,
                         Input.POIInstances[I].Rotation);
    end;
  end;

  { File vegetation instances into their geo-tile by XZ position. }
  procedure DistributeTrees;
  var
    I:  Integer;
    LL: TLatLon;
    T:  TGeoTileId;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(793);{$ENDIF}
    for I := 0 to High(ATrees) do
    begin
      LL := Proj.Unproject(ATrees[I].X, ATrees[I].Z);
      T  := Grid.TileAt(LL);
      if not KeepGeoCell(T.TX, T.TY) then Continue;
      ModelFor(T).AddTree(ATrees[I]);
    end;
  end;

  procedure DistributeManholes;
  var I,N:Integer; T:TGeoTileId; M:TTileModel;
  begin
    for I:=0 to High(Input.Manholes) do begin
      T:=Grid.TileAt(Proj.Unproject(Input.Manholes[I].Position.X,Input.Manholes[I].Position.Z));
      if not KeepGeoCell(T.TX,T.TY) then Continue;
      M:=ModelFor(T);N:=Length(M.Manholes);SetLength(M.Manholes,N+1);
      M.Manholes[N]:=Input.Manholes[I];
    end;
  end;

  { File road centerline segments into their geo-tile(s). A segment is
    placed in the tile of each endpoint and, when those differ, of the
    midpoint too — so a segment straddling a boundary lands whole in
    every tile it crosses (node-to-node segments are short relative to
    a tile, so three samples cover them). Stored chunk-local here;
    RebaseTileToConventional shifts them to the tile frame afterwards. }
  procedure DistributeRoadSegments;
  var
    I:        Integer;
    Seg:      TTileRoadSeg;
    T0, T1, TM: TGeoTileId;
    MidX, MidZ: Single;

    procedure PlaceIn(const ATile: TGeoTileId);
    begin
      {$IFDEF IAM_LIVE}IamLiveTrack(1646);{$ENDIF}
      if not KeepGeoCell(ATile.TX, ATile.TY) then Exit;
      ModelFor(ATile).AddRoadSeg(Seg);
    end;

  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1647);{$ENDIF}
    for I := 0 to High(Input.RoadSegments) do
    begin
      Seg.X0    := Input.RoadSegments[I].X0;
      Seg.Z0    := Input.RoadSegments[I].Z0;
      Seg.X1    := Input.RoadSegments[I].X1;
      Seg.Z1    := Input.RoadSegments[I].Z1;
      Seg.Width := Input.RoadSegments[I].Width;
      Seg.WayId := Input.RoadSegments[I].WayId;
      { BRIDGE_SNAP: keep deck flag through tile cache for the route snapper. }
      Seg.IsBridge := Input.RoadSegments[I].IsBridge;
      Seg.Surface := Input.RoadSegments[I].Surface;

      T0 := Grid.TileAt(Proj.Unproject(Seg.X0, Seg.Z0));
      T1 := Grid.TileAt(Proj.Unproject(Seg.X1, Seg.Z1));
      PlaceIn(T0);
      if not T1.Equals(T0) then
      begin
        PlaceIn(T1);
        MidX := (Seg.X0 + Seg.X1) * 0.5;
        MidZ := (Seg.Z0 + Seg.Z1) * 0.5;
        TM := Grid.TileAt(Proj.Unproject(MidX, MidZ));
        if (not TM.Equals(T0)) and (not TM.Equals(T1)) then
          PlaceIn(TM);
      end;
    end;
  end;

  { BUILDING_OBSTACLE: bin solid foundation footprints into geo-tiles by
    footprint centroid (same whole-into-one-tile policy as buildings).
    KeepGroundUnder casters are filtered by CastersToObstacles. }
  procedure DistributeBuildingObstacles;
  var
    All: TBuildingObstacleArray;
    I, J, K: Integer;
    CX, CZ: Single;
    T: TGeoTileId;
    M: TTileModel;
  begin
    All := CastersToObstacles(Input.BuildingShadowCasters);
    for I := 0 to High(All) do
    begin
      if Length(All[I].Footprint) < 3 then Continue;
      CX := 0; CZ := 0;
      for J := 0 to High(All[I].Footprint) do
      begin
        CX := CX + All[I].Footprint[J].X;
        CZ := CZ + All[I].Footprint[J].Z;
      end;
      CX := CX / Length(All[I].Footprint);
      CZ := CZ / Length(All[I].Footprint);
      T := Grid.TileAt(Proj.Unproject(CX, CZ));
      if not KeepGeoCell(T.TX, T.TY) then Continue;
      M := ModelFor(T);
      K := Length(M.BuildingObstacles);
      SetLength(M.BuildingObstacles, K + 1);
      M.BuildingObstacles[K] := All[I];
    end;
  end;

  { Distribute every landuse mesh (grass, farmland, water polygons,
    pitches, ...) that was NOT folded into the ground composite. When
    WaterShaders is on, lkWater stays here too. Without this the cache
    path silently dropped all such geometry — present only on the chunk
    path's per-kind shapes. }
  procedure DistributeLanduse;
  var
    LK: TLanduseMeshKind;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(794);{$ENDIF}
    for LK := Low(TLanduseMeshKind) to High(TLanduseMeshKind) do
      DistributePlain(Input.Landuse.Items[LK], LANDUSE_MAT[LK], True,
        'landuse_' + IntToStr(Ord(LK)));
  end;

  { Shift one tile model from chunk-local coords into its own
    conventional (tile-centre) frame. Delta is the chunk-local XYZ of
    the tile centre; subtracting it makes every coordinate relative to
    that centre. The tile centre comes purely from TGeoTileId, so the
    result is chunk-independent. }
  procedure RebaseTileToConventional(M: TTileModel);
  var
    Delta: TVector3;
    K, V:  Integer;
    Msh:   TMesh;
    VRef:  TMeshVertexArray;
    PRec:  TTilePOIRec;
    TRec:  TTileTreeRec;
    RSeg:  TTileRoadSeg;
    HalfX, HalfZ: Double;       { tile-local half-extents (slippy: per-tile) }
    TBox: TLatLonBox;
    cNE, cSW: TVector3;
    BN:    Integer;             { счётчик граничных вершин }
    BIdx:  TTileMatIdArray;     { индексы граничных вершин текущего меша }
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(795);{$ENDIF}
    if M = nil then Exit;
    { M.Origin was set to the tile centre by ModelFor. }
    Delta := Proj.Project(M.Origin);   { chunk-local XYZ of tile centre }

    { Slippy tiles are NOT constant-metre squares and not symmetric in metres
      (Web-Mercator), so the boundary in tile-local is per-tile: project the
      box corners and halve the span. The rebase puts the tile centre at (0,0),
      so the edges sit at ±HalfX / ±HalfZ. }
    TBox := Grid.TileBox(M.TileId);
    cNE  := Proj.Project(TLatLon.Make(TBox.MaxLat, TBox.MaxLon));
    cSW  := Proj.Project(TLatLon.Make(TBox.MinLat, TBox.MinLon));
    HalfX := 0.5 * Abs(cNE.X - cSW.X);
    HalfZ := 0.5 * Abs(cNE.Z - cSW.Z);

    for K := 0 to M.MeshCount - 1 do
    begin
      Msh := M.Meshes[K].Mesh;
      if Msh = nil then Continue;
      { Cache the vertex array once and write straight into it. The old
        loop called the .Vertices property (TMesh.GetVertices) on every
        read and TMesh.SetVertexPosition on every write; VRef aliases
        the mesh storage, so a direct element write does both jobs. }
      VRef := Msh.Vertices;
      for V := 0 to High(VRef) do
      begin
        VRef[V].Position.X := VRef[V].Position.X - Delta.X;
        VRef[V].Position.Z := VRef[V].Position.Z - Delta.Z;
        { Y is absolute elevation — left as is. }
      end;

      { Захват граничных вершин (только композит земли)
 Координаты теперь tile-local (центр тайла = 0,0). Вершина граничная,
 если по X ИЛИ по Z она ближе TILE_BORDER_BAND_M к ребру
 (|coord| >= HalfEdge - band). Композит распознаём как и остальной
 код: длина MatIds равна числу вершин. Индексы — в том же per-vertex
 списке, что MatIds/OsmId, поэтому переживают сериализацию один-в-один.
 Пере-флагирование безопасно: при монтаже сварка срабатывает только
 на реальном совпадении точек. }
      if WELD_TILE_BORDERS and (Length(M.Meshes[K].MatIds) = Length(VRef)) then
      begin
        SetLength(BIdx, Length(VRef));
        BN := 0;
        for V := 0 to High(VRef) do
          if (Abs(VRef[V].Position.X) >= HalfX - TILE_BORDER_BAND_M)
          or (Abs(VRef[V].Position.Z) >= HalfZ - TILE_BORDER_BAND_M) then
          begin
            BIdx[BN] := V;
            Inc(BN);
          end;
        SetLength(BIdx, BN);
        M.SetBorderIdx(K, BIdx);
      end;
    end;

    for K := 0 to M.POICount - 1 do
    begin
      PRec := M.POIs[K];
      PRec.Position.X := PRec.Position.X - Delta.X;
      PRec.Position.Z := PRec.Position.Z - Delta.Z;
      M.SetPOI(K, PRec);
    end;

    for K := 0 to M.TreeCount - 1 do
    begin
      TRec := M.Trees[K];
      TRec.X := TRec.X - Delta.X;
      TRec.Z := TRec.Z - Delta.Z;
      M.SetTree(K, TRec);
    end;

    for K:=0 to High(M.Manholes) do begin
      M.Manholes[K].Position.X:=M.Manholes[K].Position.X-Delta.X;
      M.Manholes[K].Position.Z:=M.Manholes[K].Position.Z-Delta.Z;
    end;
    for K := 0 to M.RoadSegCount - 1 do
    begin
      RSeg := M.RoadSegs[K];
      RSeg.X0 := RSeg.X0 - Delta.X;  RSeg.Z0 := RSeg.Z0 - Delta.Z;
      RSeg.X1 := RSeg.X1 - Delta.X;  RSeg.Z1 := RSeg.Z1 - Delta.Z;
      M.SetRoadSeg(K, RSeg);
    end;

    { BUILDING_OBSTACLE: footprints follow the same conventional rebase as
      meshes (chunk-local → tile-local XZ). Y stays absolute. }
    for K := 0 to High(M.BuildingObstacles) do
    begin
      for V := 0 to High(M.BuildingObstacles[K].Footprint) do
      begin
        M.BuildingObstacles[K].Footprint[V].X :=
          M.BuildingObstacles[K].Footprint[V].X - Delta.X;
        M.BuildingObstacles[K].Footprint[V].Z :=
          M.BuildingObstacles[K].Footprint[V].Z - Delta.Z;
      end;
      RebuildObstacleAABB(M.BuildingObstacles[K]);
    end;
  end;

var
  P: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1256);{$ENDIF}
  Result := nil;
  Models := nil;
  if (Input.Origin.Lat = 0) and (Input.Origin.Lon = 0) then
  begin
    if Assigned(LogProc) then
      LogProc('SplitInputToTiles: Origin unset — no tiles produced');
    Exit;
  end;

  Proj  := TLocalProjection.Create(Input.Origin, Input.ScaleLat);
  { Slippy lattice @ heightmap zoom — edges on heightmap pixel lines, no zone
    to pin. SAME zoom+EdgePx as the carve tag (else composite tags won't match
    Grid.TileAt for buildings/trees). }
  Grid  := TGeoTileGrid.Create(Input.HeightmapZoom, GEO_TILE_EDGE_PX, Input.ScaleLat);
  Index := specialize TDictionary<Int64, Integer>.Create;
  Count := 0;
  { Activate the same geo-binning AssembleTiled uses, so the tiles cut
    here are byte-identical to the render tiles. }
  BeginGeoTiling(Input.Origin, Input.HeightmapZoom, 0, Input.ScaleLat);
  try
    AsmGeoTiling.KeepTiles := AKeepTiles;
    GenerationProgress('Splitting tiles', 0, 12);
    DistributeComposite;
    GenerationProgress('Splitting tiles', 1, 12);

    { Buildings — whole per geo-tile by footprint anchor, so a building
      on a tile boundary is cached entirely in one tile (never split). }
    DistributeBuildingsByAnchor;
    GenerationProgress('Splitting tiles', 2, 12);

    { Fences/barriers — same whole-into-one-tile anchor binning. }
    DistributeFencesByAnchor;
    GenerationProgress('Splitting tiles', 3, 12);

    { Plates — same anchor binning, single smkPlate material. }
    DistributePlatesByAnchor;
    GenerationProgress('Splitting tiles', 4, 12);

    { Landuse meshes not in the composite. Вода — всегда в композите. }
    DistributeLanduse;
    GenerationProgress('Splitting tiles', 5, 12);

    DistributePOI;
    GenerationProgress('Splitting tiles', 6, 12);
    DistributeTrees;
    GenerationProgress('Splitting tiles', 7, 12);
    DistributeManholes;
    GenerationProgress('Splitting tiles', 8, 12);
    DistributePlain(Input.RoadFurniture, smkRoadFurniture, True, 'road_furniture');
    GenerationProgress('Splitting tiles', 9, 12);
    DistributeRoadSegments;
    GenerationProgress('Splitting tiles', 10, 12);

    { BUILDING_OBSTACLE: store solid foundation footprints on each tile
      (from BuildingShadowCasters). KeepGroundUnder skipped inside
      CastersToObstacles. Chunk-local XZ here; rebased below. }
    DistributeBuildingObstacles;
    GenerationProgress('Splitting tiles', 11, 12);

    { Rebase every tile from chunk-local coords into its own
      conventional frame: vertices/POI/trees become relative to the
      tile centre (Model.Origin, set by ModelFor to Grid.TileCenter).
      After this the tile file is identical regardless of which chunk
      baked it — overlapping maps share the very same files.
      Y (elevation) is absolute and left untouched; only the XZ ground
      offset between the chunk origin and the tile centre is removed. }
    for P := 0 to Count - 1 do
      if Models[P] <> nil then
      begin
        RebaseTileToConventional(Models[P]);
      end;

    SetLength(Models, Count);
    GenerationProgress('Splitting tiles', 12, 12);
    Result := Models;
    Models := nil; { ownership transferred; finally handles failed partial splits }
    if Assigned(LogProc) then
      LogProc(Format('SplitInputToTiles: %d geo-tiles', [Count]));
  finally
    for P := 0 to High(Models) do Models[P].Free;
    EndGeoTiling;
    Index.Free;
    Grid.Free;
    Proj.Free;
  end;
end;

constructor TCachedAssemblyResources.Create;
begin
  inherited Create;
  InitCriticalSection(FShadowLock);
end;

destructor TCachedAssemblyResources.Destroy;
var
  I:  Integer;
  LK: TLanduseMeshKind;

  procedure ReleaseNode(N: TX3DNode);
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(798);{$ENDIF}
    if N = nil then Exit;
    { Balance the KeepExistingBegin done when the resource was built,
      then free explicitly — by now every tile scene that USE-d it is
      already gone, so the ref-count is back to zero. }
    N.KeepExistingEnd;
    N.FreeIfUnused;
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1258);{$ENDIF}
  for I := 0 to BUILDING_PALETTE_SIZE - 1 do
  begin
    ReleaseNode(FWallApp[I]);  FWallApp[I] := nil;
  end;
  for I := 0 to 5 do
  begin
    ReleaseNode(FRoofApp[I]);  FRoofApp[I] := nil;
  end;
  for LK := Low(TLanduseMeshKind) to High(TLanduseMeshKind) do
  begin
    ReleaseNode(FSurfTex[LK]);   FSurfTex[LK]  := nil;
    ReleaseNode(FSurfNorm[LK]);  FSurfNorm[LK] := nil;
  end;
  { Atlas diffuse/normal. URL-mode nodes were never pinned and are owned
    by the shared effect's SFNode fields, so releasing FGroundEffect (last)
    frees them — here we only drop our references. Inline-mode nodes were
    pinned, so unpin + free them as before. }
  if FAtlasUrlMode then
  begin
    FAtlasTex     := nil;
    FAtlasNormTex := nil;
    FAtlasMaskTex := nil;
  end
  else
  begin
    ReleaseNode(FAtlasTex);     FAtlasTex     := nil;
    ReleaseNode(FAtlasNormTex); FAtlasNormTex := nil;
    ReleaseNode(FAtlasMaskTex); FAtlasMaskTex := nil;
  end;
  ReleaseNode(FRoadHaloTex);  FRoadHaloTex  := nil;
  ReleaseNode(FGroundEffect); FGroundEffect := nil;
  FreeAndNil(FAtlas);
  FreeAndNil(FBuildAtlas);
  FreeAndNil(FFenceAtlas);
  FreeAndNil(FPlateAtlas);
  FreeAndNil(FAccessoryAtlas);
  DoneCriticalSection(FShadowLock);
  inherited Destroy;
end;

procedure TCachedAssemblyResources.LogTex(const AWhat, APath: string);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(799);{$ENDIF}
  { Off by default: per-building/per-material texture-load lines are thousands
    of entries per session and irrelevant to geometry-build perf. Set
    LOG_TEXTURE_LOADS := True to restore the trace. }
  if not LOG_TEXTURE_LOADS then Exit;
  if Assigned(FLog) and (APath <> '') then
    FLog('texture load: ' + AWhat + ' ' + ExtractFileName(APath));
end;

function TCachedAssemblyResources.IsShared(N: TX3DNode): Boolean;
var
  I:  Integer;
  LK: TLanduseMeshKind;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1329);{$ENDIF}
  Result := False;
  if N = nil then Exit;
  if (N = FRoadHaloTex) or (N = FGroundEffect) then
    Exit(True);
  { URL-mode atlas nodes are CGE-URL-cache ref-counted and owned by the
    shared effect's SFNode fields — they are never reached by the detach
    walk (it stops at the effect) and freeing them is always safe, so they
    are NOT shared in the pin/detach sense. Inline-fallback nodes still are. }
  if (not FAtlasUrlMode) and ((N = FAtlasTex) or (N = FAtlasNormTex) or (N = FAtlasMaskTex)) then
    Exit(True);
  for I := 0 to BUILDING_PALETTE_SIZE - 1 do
    if N = FWallApp[I] then
      Exit(True);
  for I := 0 to 5 do
    if N = FRoofApp[I] then
      Exit(True);
  for LK := Low(TLanduseMeshKind) to High(TLanduseMeshKind) do
    if (N = FSurfTex[LK]) or (N = FSurfNorm[LK]) then
      Exit(True);
end;

procedure TCachedAssemblyResources.DetachSharedFrom(Root: TX3DNode);
{ Recursive field walk. A shared node found in an SFNode/MFNode field is
  unlinked there and NOT recursed into (its own interior — e.g. the PBR
  textures inside a shared building appearance — belongs to other tiles
  too and must stay intact). Seen-set guards against the DAG being
  walked more than once; the graph is acyclic so the walk terminates. }
var
  Seen: specialize TDictionary<Pointer, Boolean>;

  procedure Walk(N: TX3DNode);
  var
    FI, MI: Integer;
    Fld:    TX3DField;
    SF:     TSFNode;
    MF:     TMFNode;
    Child:  TX3DNode;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1648);{$ENDIF}
    if (N = nil) or Seen.ContainsKey(Pointer(N)) then Exit;
    Seen.Add(Pointer(N), True);
    for FI := 0 to N.FieldsCount - 1 do
    begin
      Fld := N.Fields[FI];
      if Fld is TSFNode then
      begin
        SF    := TSFNode(Fld);
        Child := SF.Value;
        if Child <> nil then
        begin
          if IsShared(Child) then
            SF.Value := nil               { unlink — do not recurse }
          else
            Walk(Child);
        end;
      end
      else if Fld is TMFNode then
      begin
        MF := TMFNode(Fld);
        for MI := MF.Count - 1 downto 0 do
        begin
          Child := MF.Items[MI];
          if Child <> nil then
          begin
            if IsShared(Child) then
              MF.Delete(MI)               { unlink — do not recurse }
            else
              Walk(Child);
          end;
        end;
      end;
    end;
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1330);{$ENDIF}
  if (Root = nil) or (not FBuilt) then Exit;
  Seen := specialize TDictionary<Pointer, Boolean>.Create;
  try
    Walk(Root);
  finally
    Seen.Free;
  end;
end;

procedure TCachedAssemblyResources.EnsureAtlas(LogProc: TLogProc);
var
  AvgI: Integer;
  AvgR, AvgG, AvgB: Byte;
  DummyImg: TGrayscaleImage;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(800);{$ENDIF}
  if FBuilt then Exit;

  ProfilerLog('ATLAS: building ground atlas (diffuse + normal + mask images)...');
  FAtlas := TGroundAtlas.Create(DefaultGroundAtlasLayout);
  if (FAtlasCacheDir <> '') and FAtlas.TryLoadFromCache(FAtlasCacheDir, LogProc) then
    FAtlasUrlMode := True   { переиспользовали кэш — без пересборки в этот запуск }
  else
  begin
    FAtlas.BuildChannelsParallel(LogProc);
    FAtlasUrlMode := (FAtlasCacheDir <> '')
                     and FAtlas.SaveToCache(FAtlasCacheDir, LogProc);
  end;
  { Превью-цвета земли: из живой диффузки (путь сборки) или из кэша средних в
    манифесте (путь переиспользования) — CellAverageRGB обрабатывает оба. }
  for AvgI := 0 to GROUND_MAT_COUNT - 1 do
    if FAtlas.CellAverageRGB(AvgI, AvgR, AvgG, AvgB) then
      SetPreviewGroundColor(AvgI, AvgR, AvgG, AvgB);
  if FAtlasUrlMode then
  begin
    { Per-tile effects build their OWN atlas + road-halo nodes (URL-deduped
      by CGE). Nothing is shared here, so there is nothing to pin and
      nothing for DetachSharedFrom to handle — leave the slots nil. }
    FAtlasTex     := nil;
    FAtlasNormTex := nil;
    FAtlasMaskTex := nil;
    FRoadHaloTex  := nil;
  end
  else
  begin
    { Inline fallback (no writable cache / write failed). Without a URL,
      a fresh inline atlas PER tile would multiply RAM by the resident
      tile count, so build ONE shared inline atlas node and one shared
      road-halo dummy, pin them, and let every per-tile effect reference
      them. These remain shared X3D objects handled by DetachSharedFrom. }
    FAtlasTex     := FAtlas.CreateTextureNode;
    FAtlasNormTex := FAtlas.CreateNormalTextureNode;
    FAtlasMaskTex := FAtlas.CreateMaskTextureNode;
    if FAtlasTex     <> nil then FAtlasTex.KeepExistingBegin;
    if FAtlasNormTex <> nil then FAtlasNormTex.KeepExistingBegin;
    if FAtlasMaskTex <> nil then FAtlasMaskTex.KeepExistingBegin;

    DummyImg := TGrayscaleImage.Create(1, 1);
    DummyImg.Clear(Vector4Byte(0, 0, 0, 0));
    FRoadHaloTex := TPixelTextureNode.Create;
    FRoadHaloTex.FdImage.Value := DummyImg;
    FRoadHaloTex.RepeatS := False;
    FRoadHaloTex.RepeatT := False;
    FRoadHaloTex.KeepExistingBegin;
  end;

  FBuilt := True;
  ProfilerLog(Format('ATLAS: built (mode=%s) — atlasTex=%p normTex=%p roadHalo=%p',
    [BoolToStr(FAtlasUrlMode, 'URL/per-tile', 'inline-shared-pinned'),
     Pointer(FAtlasTex), Pointer(FAtlasNormTex), Pointer(FRoadHaloTex)]));

  { Building facade/roof atlas. Built into the same cache dir; on
 success its PNGs back URL-deduped per-tile nodes (one GPU texture each
 for the whole session) and BuildTileRoot switches to the one-shape-per-
 tile composite path. If no writable cache dir, the atlas images stay in
 RAM and BuildTileRoot keeps the legacy per-palette path (the building
 composite needs URL nodes to be shareable across tiles). }
  ProfilerLog('ATLAS: building facade/roof atlas (diffuse + normal + mask + glow)...');
  FBuildAtlas := TBuildingAtlas.Create(DefaultBuildingAtlasLayout);
  if not ((FAtlasCacheDir <> '')
          and FBuildAtlas.TryLoadFromCache(FAtlasCacheDir, LogProc)) then
  begin
    FBuildAtlas.BuildChannelsParallel(LogProc);
    if FAtlasCacheDir <> '' then
      FBuildAtlas.SaveToCache(FAtlasCacheDir, LogProc);
  end;
  { Превью-цвет зданий: живая диффузка (сборка) или кэш средних (переиспользование). }
  if FBuildAtlas.ImageAverageRGB(AvgR, AvgG, AvgB) then
    SetPreviewBuildingColor(AvgR, AvgG, AvgB);
  ProfilerLog(Format('ATLAS: building atlas %s',
    [BoolToStr(FBuildAtlas.DiffuseUrl <> '', 'URL/per-tile composite', 'RAM (per-palette fallback)')]));

  { Fence/barrier atlas. Same cache dir; on success its PNGs back
 URL-deduped per-tile nodes and BuildTileRoot switches to the
 one-fence-shape-per-tile composite path. No writable cache dir →
 images stay in RAM and fences are skipped (the fence composite has no
 per-palette legacy fallback). diffuse + normal + mask, no glow. }
  ProfilerLog('ATLAS: building fence atlas (diffuse + normal + mask)...');
  FFenceAtlas := TFenceAtlas.Create(DefaultFenceAtlasLayout);
  if not ((FAtlasCacheDir <> '')
          and FFenceAtlas.TryLoadFromCache(FAtlasCacheDir, LogProc)) then
  begin
    FFenceAtlas.BuildChannelsParallel(LogProc);
    if FAtlasCacheDir <> '' then
      FFenceAtlas.SaveToCache(FAtlasCacheDir, LogProc);
  end;
  ProfilerLog(Format('ATLAS: fence atlas %s',
    [BoolToStr(FFenceAtlas.DiffuseUrl <> '', 'URL/per-tile composite', 'RAM (fallback)')]));

  { House-number plate glyph atlas — one cached grayscale PNG of the embedded
    CGE font (DejaVu Sans, with Cyrillic). No writable cache dir → no URL and
    plates are skipped (the plate composite has no legacy fallback). Idempotent:
    SaveToCache skips an existing PNG. }
  ProfilerLog('ATLAS: building plate glyph atlas...');
  FPlateAtlas := TPlateGlyphAtlas.Create;
  if not ((FAtlasCacheDir <> '')
          and FPlateAtlas.TryLoadFromCache(FAtlasCacheDir)) then
    if FAtlasCacheDir <> '' then
      FPlateAtlas.SaveToCache(FAtlasCacheDir, LogProc);
  ProfilerLog(Format('ATLAS: plate atlas %s',
    [BoolToStr(FPlateAtlas.Url <> '', 'URL/per-tile composite', 'RAM (skipped)')]));

  { Accessory sprite atlas — traffic-light states (red/yellow/green/off/undefined),
    one 256px cell each, diffuse only. Same cache path as the others; without a
    writable cache dir it stays in RAM (a one-shot pixel node), which is fine for
    the single shared accessory shape. }
  ProfilerLog('ATLAS: building accessory atlas (traffic-light states)...');
  FAccessoryAtlas := TAccessoryAtlas.Create;
  if not ((FAtlasCacheDir <> '')
          and FAccessoryAtlas.TryLoadFromCache(FAtlasCacheDir, LogProc)) then
  begin
    FAccessoryAtlas.BuildImage(LogProc);
    if FAtlasCacheDir <> '' then
      FAccessoryAtlas.SaveToCache(FAtlasCacheDir, LogProc);
  end;
  ProfilerLog(Format('ATLAS: accessory atlas %s',
    [BoolToStr(FAccessoryAtlas.DiffuseUrl <> '', 'URL', 'RAM')]));
end;

procedure TCachedAssemblyResources.RegisterTileShadow(const T: TGeoTileId;
  const Tris: TProjTriArray; const TreeCards: TShadowTreeCardArray;
  AMinX, AMinZ, AMaxX, AMaxZ: Single;
      const Ground: TShadowGroundTriangles);
begin
  EnterCriticalSection(FShadowLock);
  try
  {$IFDEF IAM_LIVE}IamLiveTrack(1650);{$ENDIF}
  RegisterShadowReg(FShadowReg, FShadowCursor, T, Tris, TreeCards,
    AMinX, AMinZ, AMaxX, AMaxZ, SHADOW_REG_CAP, Ground);
  finally
    LeaveCriticalSection(FShadowLock);
  end;
end;

function TCachedAssemblyResources.ApplyShadowsTo(Mask: TGrayscaleImage;
  const OriginV, SizeV: TVector2): Boolean;
begin
  EnterCriticalSection(FShadowLock);
  try
  {$IFDEF IAM_LIVE}IamLiveTrack(1651);{$ENDIF}
  Result := RasterizeRegInto(FShadowReg, Mask, OriginV, SizeV);
  finally
    LeaveCriticalSection(FShadowLock);
  end;
end;

procedure TCachedAssemblyResources.StampTileMaskOwner(const T: TGeoTileId;
  AOwner: Pointer; AGen: QWord);
var
  i: Integer;
begin
  EnterCriticalSection(FShadowLock);
  try
  {$IFDEF IAM_LIVE}IamLiveTrack(1652);{$ENDIF}
  for i := 0 to High(FShadowReg) do
    if FShadowReg[i].InUse and (FShadowReg[i].Tex <> nil)
       and FShadowReg[i].TileId.Equals(T) then
    begin
      FShadowReg[i].Owner := AOwner;
      FShadowReg[i].Gen   := AGen;
      Exit;
    end;
  finally
    LeaveCriticalSection(FShadowLock);
  end;
end;

procedure TCachedAssemblyResources.SetTileMaskTexture(const T: TGeoTileId;
  ATex: TPixelTextureNode; ATexTree: TPixelTextureNode; AField: TSFNode;
  AOX, AOZ, ASX, ASZ: Single; AOwner: Pointer);
var
  i: Integer;
begin
  EnterCriticalSection(FShadowLock);
  try
  {$IFDEF IAM_LIVE}IamLiveTrack(1653);{$ENDIF}
  for i := 0 to High(FShadowReg) do
    if FShadowReg[i].InUse and FShadowReg[i].TileId.Equals(T) then
    begin
      FShadowReg[i].Tex := ATex;
      FShadowReg[i].TexTree := ATexTree;
      FShadowReg[i].Owner := AOwner;
      FShadowReg[i].MaskField := AField;
      FShadowReg[i].OX := AOX; FShadowReg[i].OZ := AOZ;
      FShadowReg[i].SX := ASX; FShadowReg[i].SZ := ASZ;
      Exit;
    end;
  finally
    LeaveCriticalSection(FShadowLock);
  end;
end;

procedure TCachedAssemblyResources.DetachTileMaskTexture(const T: TGeoTileId);
var
  i: Integer;
begin
  EnterCriticalSection(FShadowLock);
  try
  {$IFDEF IAM_LIVE}IamLiveTrack(1654);{$ENDIF}
  { The tile's scene (and its mask texture node) is about to be freed, so
    drop the live texture reference — a later PUSH must never touch a freed
    node. But KEEP the silhouette triangles: the building still exists in
    the world, only its tile is hidden for performance, so its shadow must
    persist on neighbouring tiles. Keeping the tris means a neighbour that
    rebuilds its mask still PULLs this shadow; the capped ring ages the
    entry out eventually, and a reload replaces it in place. }
  for i := 0 to High(FShadowReg) do
    if FShadowReg[i].InUse and FShadowReg[i].TileId.Equals(T) then
    begin
      FShadowReg[i].Ground := nil;
      FShadowReg[i].Tex := nil;
      FShadowReg[i].TexTree := nil;
      FShadowReg[i].Owner := nil;
      FShadowReg[i].Gen := 0;
      FShadowReg[i].MaskField := nil;
      Exit;
    end;
  finally
    LeaveCriticalSection(FShadowLock);
  end;
end;

{$IFDEF TILE_MEM_PROFILE}
function TCachedAssemblyResources.ShadowMaskBytes: Int64;
var
  i, res: Integer;
begin
  EnterCriticalSection(FShadowLock);
  try
  Result := 0;
  for i := 0 to High(FShadowReg) do
    if FShadowReg[i].InUse and (FShadowReg[i].Tex <> nil) then
    begin
      res := ShadowMaskRes(FShadowReg[i].SX, FShadowReg[i].SZ);
      Result := Result + Int64(res) * res;   { grayscale R8, 1 байт/тексель }
    end;
  finally
    LeaveCriticalSection(FShadowLock);
  end;
end;
{$ENDIF}

function TCachedAssemblyResources.CollectTileSnapshot(const T: TGeoTileId;
  out AOX, AOZ, ASX, ASZ: Single; out AW, AH: Integer;
  out Tris: TProjTriArray; out Trees: TShadowTreeCardArray;
      out Ground: TShadowGroundTriangles): Boolean;
var
  i, g, nT, nC, res: Integer;
  wnx, wnz, wxx, wxz: Single;
begin
  EnterCriticalSection(FShadowLock);
  try
  {$IFDEF IAM_LIVE}IamLiveTrack(1656);{$ENDIF}
  Result := False;
  SetLength(Tris, 0);  SetLength(Trees, 0); Ground := nil;
  AOX := 0; AOZ := 0; ASX := 0; ASZ := 0; AW := 0; AH := 0;
  { T's mask window — stored on its registry entry by SetTileMaskTexture }
  for i := 0 to High(FShadowReg) do
    if FShadowReg[i].InUse and FShadowReg[i].TileId.Equals(T)
       and (FShadowReg[i].Tex <> nil) then
    begin
      Ground := FShadowReg[i].Ground;
      AOX := FShadowReg[i].OX;  AOZ := FShadowReg[i].OZ;
      ASX := FShadowReg[i].SX;  ASZ := FShadowReg[i].SZ;
      Result := True;
      Break;
    end;
  if not Result then Exit;
  { resolution — single source of truth (must match the phase-2 placeholder) }
  res := ShadowMaskRes(ASX, ASZ);
  AW := res;  AH := res;
  wnx := AOX;        wnz := AOZ;
  wxx := AOX + ASX;  wxz := AOZ + ASZ;
  { gather every silhouette overlapping the window (T + neighbours). The
    registry is persistent across packs, so this covers neighbours loaded
    in earlier packs — the same cross-tile reach the old pull/push had. }
  nT := 0; nC := 0;
  for i := 0 to High(FShadowReg) do
    if FShadowReg[i].InUse
       and not ((FShadowReg[i].MaxX < wnx) or (FShadowReg[i].MinX > wxx) or
                (FShadowReg[i].MaxZ < wnz) or (FShadowReg[i].MinZ > wxz)) then
    begin
      Inc(nT, Length(FShadowReg[i].Tris));
      Inc(nC, Length(FShadowReg[i].Trees));
    end;
  SetLength(Tris, nT);  SetLength(Trees, nC);
  nT := 0; nC := 0;
  for i := 0 to High(FShadowReg) do
    if FShadowReg[i].InUse
       and not ((FShadowReg[i].MaxX < wnx) or (FShadowReg[i].MinX > wxx) or
                (FShadowReg[i].MaxZ < wnz) or (FShadowReg[i].MinZ > wxz)) then
    begin
      for g := 0 to High(FShadowReg[i].Tris) do
      begin Tris[nT] := FShadowReg[i].Tris[g];  Inc(nT); end;
      for g := 0 to High(FShadowReg[i].Trees) do
      begin Trees[nC] := FShadowReg[i].Trees[g];  Inc(nC); end;
    end;
  finally
    LeaveCriticalSection(FShadowLock);
  end;
end;

function TCachedAssemblyResources.SampleTileGroundShadow(AOwner: Pointer;
  AGen: QWord; SessionX, SessionZ: Single): Single;
var I: Integer; B,T: TCastleImage;
begin
  Result := 0;
  if (AOwner=nil) or (AGen=0) then Exit;
  EnterCriticalSection(FShadowLock);
  try
    for I := 0 to High(FShadowReg) do
      with FShadowReg[I] do
        if InUse and (Owner=AOwner) and (Gen=AGen) then
        begin
          B := nil; T := nil;
          if Tex<>nil then B := Tex.FdImage.Value;
          if TexTree<>nil then T := TexTree.FdImage.Value;
          Exit(GroundMaskCoverage(B,T,ShadowMaskRes(SX,SZ),ShadowMaskBitsActive,
            ShadowMaskBitsTree,Vector2(OX,OZ),Vector2(SX,SZ),Vector2(SessionX,SessionZ)));
        end;
  finally LeaveCriticalSection(FShadowLock) end;
end;

function TCachedAssemblyResources.GetTileMaskTexByKey(
  const AKey: string): TPixelTextureNode;
var
  i: Integer;
begin
  EnterCriticalSection(FShadowLock);
  try
  {$IFDEF IAM_LIVE}IamLiveTrack(1657);{$ENDIF}
  Result := nil;
  for i := 0 to High(FShadowReg) do
    if FShadowReg[i].InUse and (FShadowReg[i].Tex <> nil)
       and (FShadowReg[i].KeyStr = AKey) then
      Exit(FShadowReg[i].Tex);
  finally
    LeaveCriticalSection(FShadowLock);
  end;
end;

function TCachedAssemblyResources.GetTileMaskTexByOwner(const AKey: string;
  AOwner: Pointer; AGen: QWord): TPixelTextureNode;
var
  i: Integer;
begin
  EnterCriticalSection(FShadowLock);
  try
  {$IFDEF IAM_LIVE}IamLiveTrack(1658);{$ENDIF}
  { Only hand back the node when the ring slot STILL belongs to AOwner AND
    carries the SAME mount-generation the caller's upload was tagged with.
    The generation is the authoritative check: a re-mount of the same
    geo-tile bumps it, so a result produced for the previous mount is
    rejected even when the heap reuses the old TCacheTile address and the
    raw Owner pointer happens to match. If the slot was detached
    (Owner=nil / Gen=0), reused by another tile, or re-mounted, the node
    the caller remembers is gone; return nil so the upload is dropped
    instead of poking a freed object. }
  Result := nil;
  if (AOwner = nil) or (AGen = 0) then Exit;
  for i := 0 to High(FShadowReg) do
    if FShadowReg[i].InUse and (FShadowReg[i].Tex <> nil)
       and (FShadowReg[i].Owner = AOwner)
       and (FShadowReg[i].Gen = AGen)
       and (FShadowReg[i].KeyStr = AKey) then
      Exit(FShadowReg[i].Tex);
  finally
    LeaveCriticalSection(FShadowLock);
  end;
end;

function TCachedAssemblyResources.GetTileMaskTexTreeByOwner(const AKey: string;
  AOwner: Pointer; AGen: QWord): TPixelTextureNode;
var
  i: Integer;
begin
  EnterCriticalSection(FShadowLock);
  try
  Result := nil;
  if (AOwner = nil) or (AGen = 0) then Exit;
  for i := 0 to High(FShadowReg) do
    if FShadowReg[i].InUse and (FShadowReg[i].TexTree <> nil)
       and (FShadowReg[i].Owner = AOwner)
       and (FShadowReg[i].Gen = AGen)
       and (FShadowReg[i].KeyStr = AKey) then
      Exit(FShadowReg[i].TexTree);
  finally
    LeaveCriticalSection(FShadowLock);
  end;
end;

procedure TCachedAssemblyResources.WarmupSurfaces(LogProc: TLogProc);
var
  LK: TLanduseMeshKind;
  N:  Integer;
  T:  TImageTextureNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(802);{$ENDIF}
  { Per-tile URL surfaces need no shared pre-build; CGE loads each PNG
    once and caches the GPU texture by URL on the first tile prepare.
    This now only reports how many kinds actually have a texture, by
    building a throwaway node per kind (cheap — no GPU work) and freeing
    it immediately. }
  N := 0;
  for LK := Low(TLanduseMeshKind) to High(TLanduseMeshKind) do
  begin
    T := TSurfaceTextures.CreateForKind(Ord(LK));
    if T <> nil then
    begin
      Inc(N);
      T.Free;
    end;
  end;
  if Assigned(LogProc) then
    LogProc(Format('  Warmup: %d landuse surface kinds have textures', [N]));
end;

function TCachedAssemblyResources.SurfaceShape(Mesh: TMesh;
  LK: TLanduseMeshKind; FlatMat: TSceneMaterialKind): TShapeNode;
var
  Geo:     TIndexedFaceSetNode;
  Mat:     TMaterialNode;
  App:     TAppearanceNode;
  DiffTex: TImageTextureNode;   { per-tile, URL-deduped by CGE }
  NormTex: TImageTextureNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(803);{$ENDIF}
  Result := nil;
  if (Mesh = nil) or (Mesh.TriangleCount = 0) then Exit;

  { Per-tile diffuse texture, built fresh from its PNG URL. CGE loads each
    PNG only once and ref-counts the GPU texture by URL, so a brand-new
    node per tile costs only the tiny node object — no shared node, no
    KeepExisting pinning, nothing for DetachSharedFrom to unlink. When the
    tile scene is freed the node is freed with it; sibling tiles keep the
    URL-cached GPU texture alive. }
  DiffTex := TSurfaceTextures.CreateForKind(Ord(LK));

  { No texture for this kind — plain flat-colour shape. }
  if DiffTex = nil then
  begin
    Result := TMeshToX3D.CreateShape(Mesh, FlatMat, True);
    Exit;
  end;

  Geo := TMeshToX3D.CreateGeometry(Mesh, True, uvFromMesh);
  if Geo = nil then
  begin
    DiffTex.Free;   { geometry failed — free the unused per-tile node }
    Exit;
  end;

  NormTex := TSurfaceTextures.CreateNormalForKind(Ord(LK));

  Mat := TSceneMaterials.CreateMaterialNode(smkSurface);
  if NormTex <> nil then
    Mat.NormalTexture := NormTex;

  App := TAppearanceNode.Create;
  App.Material := Mat;
  App.Texture  := DiffTex;

  Result := TShapeNode.Create;
  Result.Geometry   := Geo;
  Result.Appearance := App;
  CompactTileGeometry(Result);
end;

{ Flat on-screen colour for the LOD box-buildings (levels B/C). CGE applies
  NO lighting to TUnlitMaterialNode, so EmissiveColor IS the final pixel —
  it must be a display-space (already gamma-encoded) value, same convention
  as the composite shaders. To keep the SAME wall brightness as level A
  (whose shader self-lights: sun 8.0 + ambient 0.45 + exposure 2.0 +
  Reinhard + sRGB), the average atlas colour is run through that very
  pipeline at a representative wall angle. Without this the boxes fall back
  to the scene's much weaker light rig (sun ~1.1) and go dark. Raise
  BOX_REP_NDOTL for brighter boxes, lower for darker. }
function BoxUnlitColor(const AlbedoSRGB: TVector3): TVector3;
const
  { Зеркала GLSL-констант шейдера зданий — единый источник в Osm3dGlslLib
    (SUN_INTENSITY_VALUE / AMBIENT_FACTOR_VALUE = GLSL_SUN_CONSTS,
    BLD_EXPOSURE_VALUE = BLD_EXPOSURE в BUILDING_COMPOSITE_FS). }
  BOX_SUN_INTENSITY  = SUN_INTENSITY_VALUE;
  BOX_AMBIENT_FACTOR = AMBIENT_FACTOR_VALUE;
  BOX_EXPOSURE       = BLD_EXPOSURE_VALUE;
  BOX_REP_NDOTL      = 0.55;    { representative lit-wall angle (tune) }

  function Encode(SRGB: Single): Single;
  var
    ALin, Direct, C, Tm: Single;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1659);{$ENDIF}
    ALin   := Power(SRGB, 2.2);                          { sRGB -> linear }
    Direct := BOX_REP_NDOTL * ALin / Pi * BOX_SUN_INTENSITY;
    C      := (Direct + ALin * BOX_AMBIENT_FACTOR) * BOX_EXPOSURE;
    Tm     := C / (C + 1.0);                             { Reinhard }
    Result := Power(Tm, 1.0 / 2.2);                      { linear -> sRGB }
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1660);{$ENDIF}
  Result := Vector3(Encode(AlbedoSRGB.X),
                    Encode(AlbedoSRGB.Y),
                    Encode(AlbedoSRGB.Z));
end;

{ LOD-обёртка тайла (этап II): A — полная геометрия как собрана (PBR по
  настройке), B — те же ноды геометрии, здания с простым материалом,
  C — земля+вода+здания-плэйн, D — пусто (заменяет UpdateDistanceCulling).
  Геометрия в VRAM одна на все уровни (USE-шаринг нод). }
procedure WrapTileLOD(Root: TX3DRootNode; const ACenter: TVector3;
  AKx: Double;
  AGround: TAbstractChildNode;
  const ABld: array of TShapeNode; const AWater: array of TAbstractChildNode;
  ANearBuildingDetails: TAbstractChildNode;
  APbrM, AFullM: Single; APrev: TTilePreviewData);
var
  LOD: TLODNode;
  A, B, C: TGroupNode;
  Kids: array of TAbstractChildNode;
  PlainApp: TAppearanceNode;
  PlainMat: TUnlitMaterialNode;
  Plains: array of TShapeNode;
  I, J: Integer;
  Ch: TAbstractChildNode;
  IsBld: Boolean;
  IsWater: Boolean;

  { Размещённый превью-меш земли для уровней B/C. PreviewGroup отдаёт
    тайл-локальную ноду (центр в 0), а геометрия тайла уже в session-frame
    (меши сдвинуты на ACenter в BuildTileRoot), поэтому сдвигаем превью так
    же. Простой материал превью НЕ несёт shadow-mask шейдера земли -> теней
    на нём нет (это и требовалось). }
  function PlacedPreview(Step: Integer): TTransformNode;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1661);{$ENDIF}
    Result := TTransformNode.Create;
    Result.Translation := Vector3(ACenter.X, 0, ACenter.Z);
    { Метрика тайла → метрика кадра, как у полноразмерных мешей (AKx в
      BuildTileRoot); внутри полосы кадра AKx = 1.0 — нода без масштаба. }
    if AKx <> 1.0 then
      Result.Scale := Vector3(AKx, 1, 1);
    { Только ТЕКСТУРНЫЙ превью-меш земли. Безтекстурный (одноцветный) убран —
      его зону перекрывает дальний клипмап, отдельный зелёный меш не нужен. }
    if (APrev <> nil) and APrev.HasTex then
      Result.AddChildren(PreviewGroup(APrev, Step));
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1831);{$ENDIF}
  if Root.FdChildren.Count = 0 then Exit;
  SetLength(Kids, Root.FdChildren.Count);
  for I := 0 to High(Kids) do
  begin
    Kids[I] := Root.FdChildren[I] as TAbstractChildNode;
    Kids[I].KeepExistingBegin;
  end;
  Root.FdChildren.Clear;

  A := TGroupNode.Create;
  for I := 0 to High(Kids) do
    A.AddChildren(Kids[I]);

  { Unlit boxes (LOD levels B/C): CGE applies no lighting, EmissiveColor is
    the final pixel. Brightness matched to level A (see BoxUnlitColor) so the
    A->B switch keeps light walls light instead of darkening under the scene
    light rig. }
  PlainMat := TUnlitMaterialNode.Create;
  PlainMat.EmissiveColor := BoxUnlitColor(PreviewBuildingColor);
  PlainApp := TAppearanceNode.Create;
  PlainApp.Material := PlainMat;
  SetLength(Plains, Length(ABld));
  for I := 0 to High(ABld) do
  begin
    Plains[I] := TShapeNode.Create;
    Plains[I].Geometry   := ABld[I].Geometry;
    Plains[I].Appearance := PlainApp;
  end;

  B := TGroupNode.Create;
  { Preview ground = the coarse "supertile" surface (base ground + roads +
    landuse + water baked into one texture) shown at far LOD. It is emitted
    independently of AGround, so gate it with the SAME ground-render condition
    as the composite — disabling ground rendering then also removes the
    far-LOD supertiles. }
  if (APrev <> nil) and RenderRoadsActive and RenderLanduseActive then
    B.AddChildren(PlacedPreview(1));   { меш земли + prev-текстура (полный грид), без теней }
  for I := 0 to High(Kids) do
  begin
    Ch := Kids[I];
    if Ch = ANearBuildingDetails then Continue;
    if (APrev <> nil) and (Ch = AGround) then Continue;  { землю-композит заменило превью }
    { Шейдерная вода — только на уровне A (вблизи). На B/C воду рисует
      запечённая prev-текстура, поэтому водные ноды сюда не кладём. }
    IsWater := False;
    for J := 0 to High(AWater) do
      if Ch = AWater[J] then
      begin
        IsWater := True;
        Break;
      end;
    if IsWater then Continue;
    IsBld := False;
    for J := 0 to High(ABld) do
      if Ch = ABld[J] then
      begin
        B.AddChildren(Plains[J]);
        IsBld := True;
        Break;
      end;
    if not IsBld then
      B.AddChildren(Ch);
  end;

  C := TGroupNode.Create;
  if RenderRoadsActive and RenderLanduseActive then
  begin
    if APrev <> nil then
      { Та же prev-текстура и ТА ЖЕ плотность сетки, что на уровне B.
        Раньше здесь был Step=4: LOD переключается по-тайлово по дистанции,
        и на кольце смены сосед B (Step=1, все вершины кромки) стыковался
        с соседом C (Step=4, каждая 4-я вершина + хорды между ними) —
        T-стыки, видимые разрывы на склонах. Диагностика подтвердила, что
        сами ДАННЫЕ кромок соседних превью побитно равны (координаты и
        CRC высот в [preview]-логе), т.е. единственным источником шва
        между двумя превью оставалась разница плотностей. Экономия
        Step=4 — ~1.9k треугольников на дальний тайл (сетка 33x33 — это
        ~16 КБ вершин) — не стоит дефекта. }
      C.AddChildren(PlacedPreview(1))
    else if AGround <> nil then
      C.AddChildren(AGround);
  end;
  { Вода только на уровне A — на C её даёт prev-текстура (см. RasterizeComposite). }
  for I := 0 to High(Plains) do
    C.AddChildren(Plains[I]);

  { No empty far level. The atomic LOD cut can keep a BASE tile visible past
    ABoxesM — a super refine is decided on the parent's NEAREST edge, but its
    base children reach further, and camera altitude adds to CGE's 3D LOD
    distance (an XZ-near tile can be 3D-far). The old 4th level D was an EMPTY
    group, so such a tile rendered NOTHING past ABoxesM -> sky hole (which the
    streaming-map repair then masked with a coarse stub: the "stub with trees
    on top" case). Keep the coarse level C (preview mesh, or full ground when
    no preview) active for everything past AFullM, so a far-but-still-shown
    base tile always lands on ground. ABoxesM is no longer a cut-to-nothing. }
  LOD := TLODNode.Create;
  { вершины тайла в session-frame, Owner батча без Translation — центр
    LOD обязан быть центром ТАЙЛА, иначе дистанция меряется от точки
    старта сессии и все тайлы переключают уровни синхронно }
  LOD.FdCenter.Send(Vector3(ACenter.X, 0, ACenter.Z));
  LOD.AddChildren(A);
  LOD.AddChildren(B);
  LOD.AddChildren(C);
  LOD.FdRange.Send([APbrM, AFullM]);
  Root.AddChildren(LOD);

  for I := 0 to High(Kids) do
    Kids[I].KeepExistingEnd;
end;

{ Walk the tile root's direct shapes for a named TSFFloat (wind uniforms on
  the tile's shadow-mask effect). nil when absent. }
function FindGroundEffectFloat(Root: TX3DRootNode; const AName: string): TSFFloat;
var
  Scope: TX3DNode;
  I, E:  Integer;
  Sh:    TShapeNode;
  App:   TAppearanceNode;
  Eff:   TEffectNode;
  Fld:   TX3DField;
begin
  Result := nil;
  if Root = nil then Exit;
  Scope := TX3DNode(Root);
  if (Root.FdChildren.Count = 1) and (Root.FdChildren[0] is TLODNode)
     and (TLODNode(Root.FdChildren[0]).FdChildren.Count > 0) then
    Scope := TLODNode(Root.FdChildren[0]).FdChildren[0];
  if not (Scope is TAbstractGroupingNode) then Exit;
  for I := 0 to TAbstractGroupingNode(Scope).FdChildren.Count - 1 do
    begin
      Sh := nil;
      if TAbstractGroupingNode(Scope).FdChildren[I] is TShapeNode then
        Sh := TShapeNode(TAbstractGroupingNode(Scope).FdChildren[I])
      else if TAbstractGroupingNode(Scope).FdChildren[I] is TTransformNode then
        with TTransformNode(TAbstractGroupingNode(Scope).FdChildren[I]) do
          if (FdChildren.Count=1) and (FdChildren[0] is TShapeNode) then
            Sh:=TShapeNode(FdChildren[0]);
      if Sh=nil then Continue;
      if not (Sh.Appearance is TAppearanceNode) then Continue;
      App := TAppearanceNode(Sh.Appearance);
      for E := 0 to App.FdEffects.Count - 1 do
        if App.FdEffects[E] is TEffectNode then
        begin
          Eff := TEffectNode(App.FdEffects[E]);
          Fld := Eff.Field(AName);
          if (Fld <> nil) and (Fld is TSFFloat) then
            Exit(TSFFloat(Fld));
        end;
    end;
end;

{ Find all 3 wind uniforms in ONE tree walk (they share one effect). }
function FindGroundWindFields(Root: TX3DRootNode; out FT, FB, FG: TSFFloat): Boolean;
var
  Scope: TX3DNode;
  I, E:  Integer;
  Sh:    TShapeNode;
  App:   TAppearanceNode;
  Eff:   TEffectNode;
  Fld:   TX3DField;
begin
  Result := False;  FT := nil;  FB := nil;  FG := nil;
  if Root = nil then Exit;
  Scope := TX3DNode(Root);
  if (Root.FdChildren.Count = 1) and (Root.FdChildren[0] is TLODNode)
     and (TLODNode(Root.FdChildren[0]).FdChildren.Count > 0) then
    Scope := TLODNode(Root.FdChildren[0]).FdChildren[0];
  if not (Scope is TAbstractGroupingNode) then Exit;
  for I := 0 to TAbstractGroupingNode(Scope).FdChildren.Count - 1 do
    begin
      Sh := nil;
      if TAbstractGroupingNode(Scope).FdChildren[I] is TShapeNode then
        Sh := TShapeNode(TAbstractGroupingNode(Scope).FdChildren[I])
      else if TAbstractGroupingNode(Scope).FdChildren[I] is TTransformNode then
        with TTransformNode(TAbstractGroupingNode(Scope).FdChildren[I]) do
          if (FdChildren.Count=1) and (FdChildren[0] is TShapeNode) then
            Sh:=TShapeNode(FdChildren[0]);
      if Sh=nil then Continue;
      if not (Sh.Appearance is TAppearanceNode) then Continue;
      App := TAppearanceNode(Sh.Appearance);
      for E := 0 to App.FdEffects.Count - 1 do
        if App.FdEffects[E] is TEffectNode then
        begin
          Eff := TEffectNode(App.FdEffects[E]);
          Fld := Eff.Field('uWindTime');
          if (Fld <> nil) and (Fld is TSFFloat) then
          begin
            FT := TSFFloat(Fld);
            Fld := Eff.Field('uWindBase');       if Fld is TSFFloat then FB := TSFFloat(Fld);
            Fld := Eff.Field('uWindGustSpeed');  if Fld is TSFFloat then FG := TSFFloat(Fld);
            Result := True;  Exit;
          end;
        end;
    end;
end;

{ Широта метрики КАДРА сессии: ручная фиксация или полоса от широты origin. }
function FrameScaleLat(AManualScaleLat, AOriginLat: Double): Double; inline;
begin
  if (AManualScaleLat > -90.0) and (AManualScaleLat < 90.0)
     and (AManualScaleLat <> 0.0) then
    Result := AManualScaleLat
  else
    Result := WorldScaleLatBand(AOriginLat);
end;

class function TSceneAssembler.AssembleCachedTiles(
  const Models: TTileModelArray; const AOrigin: TLatLon;
  AHeightmapZoom: Integer;
  const ASunDir: TVector3; out ATrees: TTileTreeRecArray;
  const APreviews: array of TTilePreviewData;
  LogProc: TLogProc; ACache: TCachedAssemblyResources;
  AWarmupOnly: Boolean; AManualScaleLat: Double): TAssembledScenes;
var
  Proj:  TLocalProjection;
  Grid:  TGeoTileGrid;
  FrameLat: Double;      { широта метрики кадра сессии }
  Kx: Double;            { масштаб X текущего тайла: cos(кадр)/cos(полосы тайла) }
  Atlas: TGroundAtlas;
  SharedAtlasTex, SharedAtlasNormTex, SharedAtlasMaskTex: TAbstractTexture2DNode;
  SharedRoadHaloTex: TPixelTextureNode;
  TmpAtlasTex, TmpAtlasNormTex, TmpAtlasMaskTex: TPixelTextureNode;  { non-cached out-params }
  SharedGroundEffect: TEffectNode;
  { Per-palette PBR appearance cache — one per wall/roof palette,
    shared (X3D USE) by every cached tile, built lazily. Effects are
    attached once here, never per shape. }
  PBRWallApp: array[0..BUILDING_PALETTE_SIZE-1] of TAppearanceNode;
  PBRRoofApp: array[0..5] of TAppearanceNode;
  { PER-TILE appearance cache. Reset at the start of every BuildTileRoot so
    each tile gets its OWN appearance nodes (built from the same cached-PNG
    URL textures -> single deduped GPU upload). NOT pinned: they are owned by
    the tile's scene and freed with it. This replaces USE-sharing the FWallApp/
    FRoofApp nodes across scenes, which made every building flicker whenever
    one tile ran ChangedAll. }
  TilePBRWall: array[0..BUILDING_PALETTE_SIZE-1] of TAppearanceNode;
  TilePBRRoof: array[0..5] of TAppearanceNode;
  T, M, P, TileCount, TreeCount, TreeCap: Integer;
  wFT, wFB, wFG: TSFFloat;   { per-tile wind fields (one walk) }
  wCnt: Integer;
  PoiK: TPOIKindExt;
  TmpSw: TSwitchNode;   { accessory (traffic-light) Switch to register }
  AccSwList: array of TSwitchNode;   { collected in nested build -> Result.AccessorySwitches (outer body) }
  TileCtr: TVector3;
  PrevT:   TTilePreviewData;
  TotComposite, TotBuilding, TotWater, TotPOI: Integer;
  { Per-kind POI shape, built once and shared (X3D USE) across every
    tile — same template-sharing TilePOIInstances uses. }
  POIKindShape: array[TPOIKindExt] of TAbstractChildNode;   { TShapeNode, or a TGroupNode for the textured traffic signal }

  { Static building-shadow coverage mask, CPU-rasterized at load from the
    projected silhouettes (the composite's skirt tris). Sampled per ground
    fragment in the composite FS -> the real material darkens in place. }
  ShadowMaskImg:        TGrayscaleImage;
  ShadowMaskImgTree:    TCastleImage;
  SunToward:            TVector3;
  MaskOrigin, MaskSize: TVector2;
  smMinX, smMinZ, smMaxX, smMaxZ, smHalf, smMarg, smPad: Single;
  smAny:                Boolean;
  smRes, sT, sMi, sTi, si0, si1, si2, sVi: Integer;
  sSy, gMinY:           Single;
  gWy:                  Single;
  sRec:                 TTileMeshRec;
  sCtr, sPA, sPB, sPC:  TVector3;
  sLA, sLB, sLC:        Single;
  sV:                   TMeshVertexArray;
  sI:                   TMeshIndexArray;
  sP0, sP1, sP2:        TVector3;
  TileTris:             TProjTriArray;
  TileGround: TShadowGroundTriangles;
  GroundTri: TShadowGroundTriangle;
  GroundCount: Integer;
  TileTreeCards:        TShadowTreeCardArray;
  tci:                  Integer;
  nTileTris, nTileMask, LocalCursor: Integer;
  LocalReg:             TTileShadowRegArray;
  tmnx, tmnz, tmxx, tmxz: Single;
  { Per-tile ground FOOTPRINT bbox (non-skirt vertices), parallel to
    Models — the composite can overhang the nominal tile cell, so the
    mask window must cover the real geometry, not center +/- half-edge. }
  FootMinX, FootMinZ, FootMaxX, FootMaxZ: array of Single;
  FootHas:              array of Boolean;
  fmnx, fmnz, fmxx, fmxz: Single;
  fHasFp:               Boolean;
  fpx, fpz:             Single;
  TileMasks:            array of TTileMaskEntry;
  MaskTex:              TPixelTextureNode;
  MaskTexTree:          TPixelTextureNode;
  MaskField:            TSFNode;
  PackIds:              TGeoTileIdArray;
  nPack:                Integer;

  { Build the heavy PBR appearance for one palette slot. Mirrors the
    nested BuildPBRAppearance of AssembleTiled — duplicated rather than
    shared so the fresh-assembly path is not disturbed. }
  function BuildPBRApp(PaletteIdx: Integer; IsRoof: Boolean): TAppearanceNode;
  var
    Proc: TPBRTextureProcessor;
    PMat: TPhysicalMaterialNode;
    Dir, Base, FDiffuse, FNormal, FMask: string;
    FNormalGL, FMaskMR, FGlow, FWinEmis, FDiffuseLift: string;
    CachedPng: string;
    WantTex, WantPBR: Boolean;   { gates from the global Building* settings }
    { Classic (Phong) material path, used when WantPBR is off. Mirrors the
      TMaterialNode + Appearance.Texture + Material.NormalTexture wiring of
      TMeshToX3D.CreateShape / TCachedAssemblyResources.SurfaceShape. }
    MatC:    TMaterialNode;
    ClassicMK: TSceneMaterialKind;
    DiffC, NormC: TAbstractTexture2DNode;

    { Stable per-material PNG path under the session cache dir for a
      processed building texture, mirroring TGroundAtlas. Returns '' when
      no writable cache is configured, in which case CreateImageTexturePersisted
      falls back to the embedded-pixel node. Base must be set (below)
      before this is called. }
    function BldCachePath(const ASuffix: string): string;
    begin
      {$IFDEF IAM_LIVE}IamLiveTrack(1662);{$ENDIF}
      if (ACache = nil) or (ACache.AtlasCacheDir = '') then Exit('');
      Result := IncludeTrailingPathDelimiter(
                  IncludeTrailingPathDelimiter(ACache.AtlasCacheDir) + 'buildings')
                + Base + '_' + ASuffix + '.png';
    end;

    { Per-palette flat colour for the textureless (BuildingTextures=False)
      mode. ЕДИНЫЙ источник —
      BUILDING_WALL_BASE / BUILDING_ROOF_BASE в Osm3dSceneMaterials: те же
      значения видят материалы сцены и фолбэк композита зданий; ручной
      копии-зеркала здесь больше нет. }
    function PaletteBaseColor(P: Integer; Roof: Boolean): TVector3;
    begin
      {$IFDEF IAM_LIVE}IamLiveTrack(1663);{$ENDIF}
      if Roof then
      begin
        if (P < 0) or (P > 5) then P := 0;
        Result := BUILDING_ROOF_BASE[P];
      end
      else
      begin
        if (P < 0) or (P > High(BUILDING_WALL_BASE)) then P := 5;
        Result := BUILDING_WALL_BASE[P];
      end;
    end;

  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(804);{$ENDIF}
    if IsRoof then
    begin
      Dir  := ROOF_TEX_DIR;
      Base := RoofMaterialName(PaletteIdx);
    end
    else
    begin
      Dir  := FACADE_TEX_DIR;
      Base := WallMaterialName(PaletteIdx) + '_window';
    end;
    FDiffuse := Dir + Base + '_diffuse.png';
    FNormal  := Dir + Base + '_normal.png';
    FMask    := Dir + Base + '_mask.png';
    if not FileExists(FDiffuse) then FDiffuse := '';
    if not FileExists(FNormal)  then FNormal  := '';
    if not FileExists(FMask)    then FMask    := '';

    if ACache <> nil then
    begin
      ACache.LogTex('building diffuse', FDiffuse);
      ACache.LogTex('building normal',  FNormal);
      ACache.LogTex('building mask',    FMask);
    end;

    { Cost gates — live globals, set by ApplyStudioSettingsToGlobals:
        BuildingTextures=False -> WantTex=False: flat per-palette colour,
          NO maps at all (diffuse/normal/mask/emissive) and no glass
          reflection — the cheapest building material (no per-fragment
          texture taps, no bump). NB this is a flat colour, not the old
          procedural FillWall pattern.
        BuildingPBR=False (textures on) -> WantPBR=False: diffuse + normal
          only; skip the metallic-roughness + emissive taps and the glass
          reflection effect ("materials stay simple"). Bump is kept.
      Neither gate is part of ComputeGenHash: tile GEOMETRY is identical,
      only the appearance built at mount changes, so toggling them is
      picked up by a re-assemble with NO on-disk tile-cache invalidation. }
    WantTex := BuildingTexturesActive;
    WantPBR := BuildingTexturesActive and BuildingPBRActive;

    { Classic (Phong) material when PBR is off
 With BuildingPBR=False the building no longer needs the physical
 (Cook-Torrance) lighting model, so build a classic TMaterialNode
 instead of TPhysicalMaterialNode. CGE compiles a classic material to
 a lighter fragment shader (no metallic/roughness response, no
 image-based environment term). Two tiers, matching WantTex:
 WantTex=False — flat per-palette colour, no maps (CreateMaterialNode
 already carries the palette diffuse + specular).
 WantTex=True — diffuse texture + tangent-space normal map, reusing
 the SAME processed/cached PNGs the PBR path emits, so
 the GPU upload is deduped by URL (no extra work).
 Glass reflection is deliberately absent — it is a full-PBR-only extra.
 Returns before the TPhysicalMaterialNode path below. }
    if not WantPBR then
    begin
      if IsRoof then
        ClassicMK := TSceneMaterialKind(Ord(smkBuildingRoof0) + PaletteIdx)
      else
        ClassicMK := TSceneMaterialKind(Ord(smkBuildingWall0) + PaletteIdx);
      MatC := TSceneMaterials.CreateMaterialNode(ClassicMK);

      DiffC := nil;
      NormC := nil;
      if WantTex then
      begin
        Proc := GetPBRProcessor;
        { Diffuse: roofs use the raw atlas diffuse; walls use the
          black-lifted + glass-composited diffuse, cached exactly as the
          PBR path does so the same PNG (and GPU texture) is reused. }
        if IsRoof then
        begin
          if FDiffuse <> '' then
            DiffC := Proc.CreateImageTexture(FDiffuse, True, True);
        end
        else
        begin
          CachedPng := BldCachePath('diffuse_proc');
          if (CachedPng <> '') and FileExists(CachedPng) then
            DiffC := Proc.CreateImageTexture(CachedPng, True, True)
          else if FDiffuse <> '' then
          begin
            FDiffuseLift := Proc.LiftBlacks(FDiffuse, 0.80, 0.80, 0.80, 0.30);
            FGlow := FACADE_TEX_DIR + WallGlowFile(PaletteIdx);
            if FileExists(FGlow) then
              FDiffuseLift := Proc.CompositeGlassBase(FDiffuseLift, FGlow,
                0.12, 0.13, 0.15);
            DiffC := Proc.CreateImageTexturePersisted(
              FDiffuseLift, CachedPng, True, True);
          end;
        end;

        { Normal map (GL convention), cached like the PBR path. }
        CachedPng := BldCachePath('normal_gl');
        if (CachedPng <> '') and FileExists(CachedPng) then
          NormC := Proc.CreateImageTexture(CachedPng, True, True)
        else if FNormal <> '' then
        begin
          FNormalGL := Proc.ConvertNormalDXtoGL(FNormal);
          NormC := Proc.CreateImageTexturePersisted(
            FNormalGL, CachedPng, True, True);
        end;

        { With a diffuse texture present, drop the palette tint so the
          texture shows at full colour (matches the PBR BaseColor=white). }
        if DiffC <> nil then
          MatC.DiffuseColor := Vector3(1, 1, 1);
      end;

      { Normal map needs a diffuse channel for an unambiguous tangent
        direction (same guard as TMeshToX3D.CreateShape) — else free it. }
      if (NormC <> nil) and (DiffC <> nil) then
        MatC.NormalTexture := NormC
      else if NormC <> nil then
        NormC.Free;

      Result := TAppearanceNode.Create;
      Result.Material := MatC;
      if DiffC <> nil then
        Result.Texture := DiffC;

      { Per-building profiling counter. The VS variant (counts vertices,
        keeps early-Z) reads 0 on GPUs without vertex-stage atomic counters
        — which is the case here — so use the FRAGMENT-stage counter, which
        is the only stage that actually increments on this hardware. It
        composes onto the building FS like the water counter does. NOTE:
        atomicCounterIncrement in the FS is a shader side-effect, so early-Z
        is disabled on tracked buildings while the flag is on — a real fill
        cost in a dense city, but gated and off in production. }
      if EnableShaderAtomicCounters then
      begin
        AttachCounterEffectApp(Result, PROF_COUNTER_HOUSES);      { fragments }
        AttachCounterEffectVS (Result, PROF_COUNTER_HOUSES_VS);   { vertices  }
      end;
      Exit;
    end;

    Proc := GetPBRProcessor;
    PMat := TPhysicalMaterialNode.Create;
    PMat.BaseColor := Vector3(1, 1, 1);
    PMat.Metallic  := 1.0;
    PMat.Roughness := 1.0;

    if not WantTex then
    begin
      { Cheapest path: matte per-palette colour, no maps. }
      PMat.BaseColor := PaletteBaseColor(PaletteIdx, IsRoof);
      PMat.Metallic  := 0.0;
      PMat.Roughness := 0.85;
    end
    else
    begin
      { For each PROCESSED texture: if its cached PNG already exists (built on
        a prior call — e.g. the warmup pass), load it straight as a URL node and
        SKIP the expensive pixel processing. This makes repeat calls cheap, so
        every tile can own a fresh appearance (URL nodes dedup the GPU upload by
        filename) instead of all tiles X3D-USE-sharing one appearance — a shared
        appearance gets re-prepared whenever ANY tile's scene runs ChangedAll
        (e.g. a shadow-mask swap), which momentarily drops its textures and makes
        every building flicker. Per-tile nodes confine that to the one tile. }
      if IsRoof then
      begin
        if FDiffuse <> '' then
          PMat.BaseTexture := Proc.CreateImageTexture(FDiffuse, True, True);
      end
      else
      begin
        CachedPng := BldCachePath('diffuse_proc');
        if (CachedPng <> '') and FileExists(CachedPng) then
          PMat.BaseTexture := Proc.CreateImageTexture(CachedPng, True, True)
        else if FDiffuse <> '' then
        begin
          FDiffuseLift := Proc.LiftBlacks(FDiffuse, 0.80, 0.80, 0.80, 0.30);
          FGlow := FACADE_TEX_DIR + WallGlowFile(PaletteIdx);
          if FileExists(FGlow) then
            FDiffuseLift := Proc.CompositeGlassBase(FDiffuseLift, FGlow,
              0.12, 0.13, 0.15);
          PMat.BaseTexture := Proc.CreateImageTexturePersisted(
            FDiffuseLift, CachedPng, True, True);
        end;
      end;

      { Normal/bump — kept in both textured tiers (diffuse + normal). }
      CachedPng := BldCachePath('normal_gl');
      if (CachedPng <> '') and FileExists(CachedPng) then
        PMat.NormalTexture := Proc.CreateImageTexture(CachedPng, True, True)
      else if FNormal <> '' then
      begin
        FNormalGL := Proc.ConvertNormalDXtoGL(FNormal);
        PMat.NormalTexture := Proc.CreateImageTexturePersisted(
          FNormalGL, CachedPng, True, True);
      end;

      if WantPBR then
      begin
        CachedPng := BldCachePath('mask_mr');
        if (CachedPng <> '') and FileExists(CachedPng) then
          PMat.MetallicRoughnessTexture := Proc.CreateImageTexture(CachedPng, True, True)
        else if FMask <> '' then
        begin
          FMaskMR := Proc.PackStreetsGLMask(FMask, not IsRoof);
          PMat.MetallicRoughnessTexture :=
            Proc.CreateImageTexturePersisted(FMaskMR, CachedPng, True, True);
        end
        else
        begin
          PMat.Roughness := 0.7;
          PMat.Metallic  := 0.0;
        end;
        if not IsRoof then
        begin
          CachedPng := BldCachePath('emissive');
          if (CachedPng <> '') and FileExists(CachedPng) then
          begin
            PMat.EmissiveTexture := Proc.CreateImageTexture(CachedPng, True, True);
            PMat.EmissiveColor := Vector3(0.03, 0.04, 0.05);
          end
          else
          begin
            FGlow := FACADE_TEX_DIR + WallGlowFile(PaletteIdx);
            if FileExists(FGlow) then
            begin
              FWinEmis := Proc.BuildWindowEmissive(FGlow, 1.0, 1.0, 1.0);
              if FWinEmis <> '' then
              begin
                PMat.EmissiveTexture := Proc.CreateImageTexturePersisted(
                  FWinEmis, CachedPng, True, True);
                PMat.EmissiveColor := Vector3(0.03, 0.04, 0.05);
              end;
            end;
          end;
        end;
      end
      else
      begin
        { diffuse + normal only — no specular/metallic response, no emissive. }
        PMat.Roughness := 0.8;
        PMat.Metallic  := 0.0;
      end;
    end;

    Result := TAppearanceNode.Create;
    Result.Material := PMat;
    { No per-fragment building LOD here. The old ApplyBuildingLODEffectApp
      injected a "discard" into the building FS for distance fade, but any
      discard marks the shader as having side effects, which makes the GPU
      DISABLE early-Z on every building — so all occluded wall fragments ran
      the full shader (a large fill cost in dense city, and it also blunted
      the Solid=True backface-cull win). Distance culling of far buildings is
      handled per-tile on the CPU (UpdateDistanceCulling / Scene.Exists),
      which is cheaper and keeps early-Z intact. }
    { Glass reflection is a full-PBR-only extra (expensive screen/cube
      reflection shader); skip it when PBR or textures are off. }
    if WantPBR and (not IsRoof)
       and FileExists(FACADE_TEX_DIR + WallGlowFile(PaletteIdx)) then
      ApplyGlassReflectEffectApp(Result, ASunDir,
        FACADE_TEX_DIR + WallGlowFile(PaletteIdx));
    if EnableShaderAtomicCounters then
    begin
      { FS counts building FRAGMENTS (early-Z disabled while on); VS counts
        building VERTICES into its own slot. VS reads non-zero only if the
        GPU supports vertex-stage atomic counters. }
      AttachCounterEffectApp(Result, PROF_COUNTER_HOUSES);
      AttachCounterEffectVS (Result, PROF_COUNTER_HOUSES_VS);
    end;
  end;

  function PBRAppFor(PaletteIdx: Integer; IsRoof: Boolean): TAppearanceNode;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(805);{$ENDIF}
    if IsRoof then
    begin
      if (PaletteIdx < 0) or (PaletteIdx > 5) then PaletteIdx := 0;
    end
    else if (PaletteIdx < 0) or (PaletteIdx >= BUILDING_PALETTE_SIZE) then
      PaletteIdx := 5;

    { With a session cache: build each palette appearance once, pin it
      (KeepExistingBegin) so a tile scene's destruction does not free
      it, and reuse it across every AssembleCachedTiles call. Without a
      cache: fall back to the per-call locals as before. }
    if ACache <> nil then
    begin
      if IsRoof then
      begin
        if ACache.FRoofApp[PaletteIdx] = nil then
        begin
          ACache.FRoofApp[PaletteIdx] := BuildPBRApp(PaletteIdx, True);
          if ACache.FRoofApp[PaletteIdx] <> nil then
            ACache.FRoofApp[PaletteIdx].KeepExistingBegin;
        end;
        Result := ACache.FRoofApp[PaletteIdx];
      end
      else
      begin
        if ACache.FWallApp[PaletteIdx] = nil then
        begin
          ACache.FWallApp[PaletteIdx] := BuildPBRApp(PaletteIdx, False);
          if ACache.FWallApp[PaletteIdx] <> nil then
            ACache.FWallApp[PaletteIdx].KeepExistingBegin;
        end;
        Result := ACache.FWallApp[PaletteIdx];
      end;
      Exit;
    end;

    if IsRoof then
    begin
      if PBRRoofApp[PaletteIdx] = nil then
        PBRRoofApp[PaletteIdx] := BuildPBRApp(PaletteIdx, True);
      Result := PBRRoofApp[PaletteIdx];
    end
    else
    begin
      if PBRWallApp[PaletteIdx] = nil then
        PBRWallApp[PaletteIdx] := BuildPBRApp(PaletteIdx, False);
      Result := PBRWallApp[PaletteIdx];
    end;
  end;

  { Per-tile appearance: a FRESH appearance node for THIS tile, cached only
    within the current BuildTileRoot (the Tile* arrays are reset there). The
    textures resolve to the same cached-PNG URLs as every other tile, so the
    GPU upload is deduped by filename and costs no extra VRAM; the win is that
    the NODE is private to this tile's scene, so another tile's ChangedAll
    cannot churn it. Not pinned — freed with the tile. BuildPBRApp is cheap
    here because the warmup already wrote the processed PNGs. }
  function PBRAppForTile(PaletteIdx: Integer; IsRoof: Boolean): TAppearanceNode;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1664);{$ENDIF}
    if IsRoof then
    begin
      if (PaletteIdx < 0) or (PaletteIdx > 5) then PaletteIdx := 0;
    end
    else if (PaletteIdx < 0) or (PaletteIdx >= BUILDING_PALETTE_SIZE) then
      PaletteIdx := 5;
    if IsRoof then
    begin
      if TilePBRRoof[PaletteIdx] = nil then
        TilePBRRoof[PaletteIdx] := BuildPBRApp(PaletteIdx, True);
      Result := TilePBRRoof[PaletteIdx];
    end
    else
    begin
      if TilePBRWall[PaletteIdx] = nil then
        TilePBRWall[PaletteIdx] := BuildPBRApp(PaletteIdx, False);
      Result := TilePBRWall[PaletteIdx];
    end;
  end;

  { Build one building shape from a cached tile mesh slice — PBR with
    the shared per-palette appearance. }
  function BuildBuildingShapeCached(Mesh: TMesh; MK: TSceneMaterialKind;
    UVMode: TUVMode; PaletteIdx: Integer; IsRoof: Boolean): TShapeNode;
  var
    Geo: TIndexedFaceSetNode;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(806);{$ENDIF}
    Result := nil;
    if (Mesh = nil) or (Mesh.TriangleCount = 0) then Exit;
    { Solid=True: single-sided rendering (backface-culled), halving wall
      fragment cost vs the old double-sided path. Safe because
      TBuildingBuilderExt.BuildAll now runs MakeWindingMatchNormals on the
      wall/roof meshes, so every face is wound outward — no inward faces to
      show through. }
    Geo := TMeshToX3D.CreateGeometry(Mesh, True, UVMode);
    if Geo = nil then Exit;
    Result := TShapeNode.Create;
    Result.Geometry   := Geo;
    Result.Appearance := PBRAppForTile(PaletteIdx, IsRoof);
    Result.X3DName := 'AtlasBuilding_' + IntToStr(Ord(MK));
  end;

  { Rebuild a per-tile TGroundCompositeMesh from a cached mesh record's
    geometry + matId stream, shifting vertices from the tile's
    conventional frame into this chunk's local frame (Delta). }
  function RebuildComposite(const Rec: TTileMeshRec;
    const Delta: TVector3; AKx: Double): TGroundCompositeMesh;
  var
    Verts: TMeshVertexArray;
    Idxs:  TMeshIndexArray;
    V, Tri: Integer;
    Vtx:   TMeshVertex;
    MatId: TGroundMaterialId;
    PI:    Integer;       { post-weld pool translate }
    PP:    TVector3;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(807);{$ENDIF}
    Result := TGroundCompositeMesh.Create('cached_composite');
    Verts := Rec.Mesh.Vertices;
    Idxs  := Rec.Mesh.Indices;
    Result.ReserveForSlice(Length(Verts), Rec.Mesh.TriangleCount);
    { Weld at the cached TILE-LOCAL coordinates. Cached composite vertices are
      tile-centre-relative (a few hundred metres at most). Delta is the tile
      centre in the SESSION-origin frame — hundreds of km out when the camera
      is far from where the session started. Adding Delta BEFORE the pool weld
      (AppendVertex -> FPool.Add, 1 mm tolerance) would snap distinct verts
      onto the same ~3 cm single-precision grid step out there and collapse
      finely-tessellated triangles into zero area: the "sky-hole" gaps. So
      append unshifted (weld where coords are small), then translate the
      welded pool by Delta below. }
    for V := 0 to High(Verts) do
    begin
      Vtx := Verts[V];
      if Length(Rec.MatIds) = Length(Verts) then
        MatId := Rec.MatIds[V]
      else
        MatId := 0;
      Result.AppendVertex(Vtx, MatId);
    end;
    for Tri := 0 to Rec.Mesh.TriangleCount - 1 do
      Result.AppendTriangle(
        Integer(Idxs[Tri*3]), Integer(Idxs[Tri*3+1]), Integer(Idxs[Tri*3+2]));
    Result.TrimArrays;
    { Now shift the (already welded, topology-final) shared vertices into the
      session-origin frame. Post-weld, so the weld never saw the large coords;
      render callers use zero Delta and keep the GPU geometry tile-local. }
    for PI := 0 to Result.Pool.Count - 1 do
    begin
      PP := Result.Pool.PositionOf(PI);
      PP.X := PP.X * AKx + Delta.X;   { восток: метрика тайла → метрика кадра }
      PP.Z := PP.Z + Delta.Z;
      Result.Pool.SetPosition(PI, PP);
    end;
  end;

  { Copy a cached plain mesh, shifting vertices by Delta into chunk
    space. Returns a new TMesh the caller owns. }
  function ShiftedMeshCopy(Src: TMesh; const Delta: TVector3;
    AKx: Double): TMesh;
  var
    Verts: TMeshVertexArray;
    Idxs:  TMeshIndexArray;
    V, Tri: Integer;
    Vtx:   TMeshVertex;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(808);{$ENDIF}
    Result := TMesh.Create(Src.Name);
    Verts := Src.Vertices;
    Idxs  := Src.Indices;
    Result.ReserveVertices(Length(Verts));
    for V := 0 to High(Verts) do
    begin
      Vtx := Verts[V];
      Vtx.Position.X := Vtx.Position.X * AKx + Delta.X;  { восток: метрика тайла → кадра }
      Vtx.Position.Z := Vtx.Position.Z + Delta.Z;
      Result.AddVertex(Vtx);
    end;
    Result.ReserveIndices(Src.TriangleCount * 3);
    for Tri := 0 to Src.TriangleCount - 1 do
      Result.AddTriangle(Integer(Idxs[Tri*3]),
        Integer(Idxs[Tri*3+1]), Integer(Idxs[Tri*3+2]));
  end;

  { Assemble one cached tile into its TX3DRootNode. }
  function BuildTileRoot(Mdl: TTileModel; const Delta: TVector3;
    APrev: TTilePreviewData; AKx: Double; var CurbVertices:TCurbMesh; var GpuGround:TGpuGroundTile): TX3DRootNode;
  var
    Mi,BridgeI,BridgeN,CurbStart:Integer;
    BridgeWays:array of Int64;
    Underside:TMesh;
    Rec:  TTileMeshRec;
    Comp: TGroundCompositeMesh;
    CompShape, BShape: TShapeNode;
    PlainCopy: TMesh;
    Pal:  Integer;
    LKIdx: Integer;
    PoiKind:  TPOIKindExt;
    PoiMesh:  TMesh;
    PoiXform: TTransformNode;
    PoiBatch: TAbstractChildNode;
    PoiInstanceCount: Integer;
    Mk:       Integer;
    Pk:       Integer;   { reset loop for the per-tile appearance cache }
    TileEff:  TEffectNode;      { this tile's shadow-mask overlay (or nil) }
    { Building composite accumulation: all wall/roof palette meshes of this
      tile merge into ONE shape (one draw call) when the building atlas is
      URL-ready. nil builder → legacy per-palette emission below. }
    BldBuilder:    TGroundCompositeBuilder;
    BldComp:       TGroundCompositeMesh;
    BldShape: TShapeNode;
    BldDetailCollision: TCollisionNode;
    UseBldComp:    Boolean;
    BVRef:         TMeshVertexArray;
    Bvi:           Integer;
    RoofPhaseX,RoofPhaseZ:Single;
    { Трубы туннелей: та же бетонная геометрия стен, но в СВОЙ композит/
      шейп с ShadowCaster=False — подземная труба не отбрасывает тень на
      композит земли (маршрутка Material=smkTunnelWall из якорей). }
    BldTunBuilder: TGroundCompositeBuilder;
    BldTunComp:    TGroundCompositeMesh;
    BldTunShape:   TShapeNode;
    { Fence composite accumulation: all fence-material meshes of this tile
      merge into ONE shape when the fence atlas is URL-ready. }
    FncBuilder:    TGroundCompositeBuilder;
    FncComp:       TGroundCompositeMesh;
    FncShape:      TShapeNode;
    UseFncComp:    Boolean;
    FncPal:        Integer;
    FncPlain:      TMesh;
    { Plate composite accumulation — same pattern, single material. }
    PltBuilder:    TGroundCompositeBuilder;
    PltComp:       TGroundCompositeMesh;
    PltShape:      TShapeNode;
    UsePltComp:    Boolean;
    PltPlain:      TMesh;
    LodGround: TAbstractChildNode;
    GroundPlacement:TTransformNode;
    GroundOriginEffect:TEffectNode;
    GroundOriginPart:TEffectPartNode;
    GroundGridOrigins: array[0..GROUND_MAT_COUNT-1] of TVector4;
    GroundGridX, GroundGridZ, GroundCellSize: Double;
    GroundMat: Integer;
    ShiftI:Integer; ShiftP:TVector3;
    LodBld:   array of TShapeNode;
    LodWater: array of TAbstractChildNode;
    LodBldN, LodWaterN: Integer;
    procedure PushLod(var Arr: array of TShapeNode; var N: Integer;
      Sh: TShapeNode); inline;
    begin
      {$IFDEF IAM_LIVE}IamLiveTrack(1666);{$ENDIF}
      if N <= High(Arr) then begin Arr[N] := Sh; Inc(N); end;
    end;
    procedure PushLodN(var Arr: array of TAbstractChildNode; var N: Integer;
      Nd: TAbstractChildNode); inline;
    begin
      {$IFDEF IAM_LIVE}IamLiveTrack(1667);{$ENDIF}
      if N <= High(Arr) then begin Arr[N] := Nd; Inc(N); end;
    end;
  begin
    RoofPhaseX:=Frac(-Mdl.Origin.Lon*Proj.MetersPerDegreeLon/4.0);
    RoofPhaseZ:=Frac(Mdl.Origin.Lat*Proj.MetersPerDegreeLat/4.0);
    LodGround := nil;
    SetLength(LodBld, 64);  LodBldN := 0;
    BldDetailCollision := nil;
    SetLength(LodWater, 16); LodWaterN := 0;
    {$IFDEF IAM_LIVE}IamLiveTrack(809);{$ENDIF}
    Result := TX3DRootNode.Create;

    { Start this tile with an EMPTY appearance cache: nil the pointers (the
      previous tile's appearances stay owned by its own root). Every building
      shape in this tile then builds/reuses appearances private to this tile. }
    for Pk := 0 to BUILDING_PALETTE_SIZE - 1 do
      TilePBRWall[Pk] := nil;
    for Pk := 0 to 5 do
      TilePBRRoof[Pk] := nil;

    TileEff := nil;
    for Mk := 0 to High(TileMasks) do
      if TileMasks[Mk].TileId.Equals(Mdl.TileId) then
      begin
        TileEff := TileMasks[Mk].Effect;
        Break;
      end;

    { Decide the building path once for this tile. Composite requires the
      atlas to have cached PNGs (URL nodes are shareable across tiles; the
      single-use pixel nodes would break after the first tile). }
    UseBldComp := (ACache <> nil) and (ACache.BuildAtlas <> nil)
                  and (ACache.BuildAtlas.DiffuseUrl <> '');
    BldBuilder := nil;
    if UseBldComp then
      BldBuilder := TGroundCompositeBuilder.Create('building_composite', 0.999);
    BldTunBuilder := nil;   { лениво — только если в тайле есть трубы туннелей }

    UseFncComp := (ACache <> nil) and (ACache.FenceAtlas <> nil)
                  and (ACache.FenceAtlas.DiffuseUrl <> '');
    FncBuilder := nil;
    if UseFncComp then
      FncBuilder := TGroundCompositeBuilder.Create('fence_composite', 0.999);

    UsePltComp := (ACache <> nil) and (ACache.PlateAtlas <> nil)
                  and (ACache.PlateAtlas.Url <> '');
    PltBuilder := nil;
    if UsePltComp then
      PltBuilder := TGroundCompositeBuilder.Create('plate_composite', 0.999);

    for Mi := 0 to Mdl.MeshCount - 1 do
    begin
      Rec := Mdl.Meshes[Mi];
      if (Rec.Mesh = nil) or (Rec.Mesh.TriangleCount = 0) then Continue;

      { Render-visualisation toggles (Osm3dStudioSettings.Render*Active)
 Skip CREATING the shape — and therefore its shader/effect and all the
 per-scene GPU state — for any category whose visualisation is off.
 Removal at code-creation level, NOT a runtime branch inside a shader.
 The category test mirrors the real dispatch below. NOTE: base ground +
 landuse + roads are BAKED into ONE ground composite (single shape, one
 shared effect) and cannot be separated at render time, so the composite
 is the whole ground surface — it is dropped when EITHER road or landuse
 rendering is off (i.e. shown only when BOTH are on). }
      if Length(Rec.MatIds) = Rec.Mesh.VertexCount then
      begin
        if not (RenderRoadsActive and RenderLanduseActive) then Continue;
      end
      else if ((Rec.Material >= smkBuildingWall0)
          and (Rec.Material <= smkBuildingRoof5))
          or (Rec.Material = smkTunnelWall) then
      begin
        if not RenderBuildingsActive then Continue;
      end
      else if (Rec.Material >= smkFence0)
          and (Rec.Material <= smkFence5) then
      begin
        if not RenderFencesActive then Continue;
      end
      else if Rec.Material = smkRoadFurniture then
      begin
        if not RenderRoadsActive then Continue;
      end
      else if Rec.Material = smkPOI then
      begin
        if not RenderPOIActive then Continue;
      end
      else if Rec.Material = smkPlate then
      begin
        if not RenderPlatesActive then Continue;
      end;

      if Length(Rec.MatIds) = Rec.Mesh.VertexCount then
      begin
        { Ground composite slice. }
        Comp := RebuildComposite(Rec, Vector3(0,0,0), AKx);
        try
          CurbStart:=Comp.TriangleCount;
          AppendUrbanRoadCurbs(Comp, Mdl, Vector3(0,0,0), AKx, CurbVertices,
            -Mdl.Origin.Lon*Proj.MetersPerDegreeLon, Mdl.Origin.Lat*Proj.MetersPerDegreeLat);
          CompShape := TGroundCompositeShape.CreateShapeTiled(
            Comp, Atlas, -ASunDir, nil,
            SharedAtlasTex, SharedAtlasNormTex, SharedAtlasMaskTex, SharedRoadHaloTex,
            GROUND_COMPOSITE_VS, GROUND_COMPOSITE_FS,
            True, True, nil, SharedGroundEffect);
          if (GpuGroundMode<>ggCpu) or RenderBuildingsActive then begin
            if GpuGround=nil then GpuGround:=TGpuGroundTile.Create;
            GpuGround.Add(CompShape.Geometry as TIndexedFaceSetNode,CurbStart);
          end;
          { X3D has copied the local geometry. Only worker-side page priorities
            and bridge builders below still need a session-space mesh. }
          for ShiftI:=0 to Comp.Pool.Count-1 do
          begin
            ShiftP:=Comp.Pool.PositionOf(ShiftI);
            Comp.Pool.SetPosition(ShiftI,ShiftP+Delta);
          end;
          SetLength(BridgeWays,Mdl.RoadSegCount); BridgeN:=0;
          for BridgeI:=0 to Mdl.RoadSegCount-1 do
            if Mdl.RoadSegs[BridgeI].IsBridge then
            begin BridgeWays[BridgeN]:=Mdl.RoadSegs[BridgeI].WayId; Inc(BridgeN) end;
          SetLength(BridgeWays,BridgeN);
          Underside:=TBridgeBuilder.BuildUnderside(Comp,BridgeWays);
          try
            if Underside<>nil then
              if UseBldComp then
                BldBuilder.Append(Underside,MaterialIdForBuilding(2,False))
              else
              begin
                BShape:=BuildBuildingShapeCached(Underside,smkBuildingWall2,uvWallVertical,2,False);
                if BShape<>nil then begin Result.AddChildren(BShape); PushLod(LodBld,LodBldN,BShape) end;
              end;
          finally Underside.Free end;

          if CompShape <> nil then
          begin
            AttachRoadSurface(CompShape.Geometry as TIndexedFaceSetNode, Comp, Mdl, Delta, AKx);
            if WaterShadersActive then
              AttachWaterScale(CompShape, Rec, Comp.VertexCount,
                -Mdl.Origin.Lon*Proj.MetersPerDegreeLon,
                Mdl.Origin.Lat*Proj.MetersPerDegreeLat, AKx);
            if TileEff <> nil then
              (CompShape.Appearance as TAppearanceNode).FdEffects.Add(TileEff);
            { Единая генерация: вода теперь ВСЕГДА в композите. Анимированный
              водный шейдер (гейт по matId==вода внутри самого эффекта) вешаем на
              shape композита — только в шейдерном режиме; иначе вода остаётся
              плоской. Отдельного smkWater-меша больше нет. }
            if WaterShadersActive
               and (GROUND_MATERIALS[GROUND_MAT_WATER].ShaderClass <> nil) then
              GROUND_MATERIALS[GROUND_MAT_WATER].ShaderClass.Instance.ApplyToShape(CompShape);
            GroundOriginEffect:=TEffectNode.Create; GroundOriginEffect.Language:=slGLSL;
            GroundOriginPart:=TEffectPartNode.Create; GroundOriginPart.ShaderType:=stVertex;
            GroundOriginPart.Contents:='// Static world origin for a tile-local ground mesh';
            GroundOriginEffect.SetParts([GroundOriginPart]);
            GroundOriginEffect.AddCustomField(TSFVec3f.Create(GroundOriginEffect,True,'gc_ground_origin',Delta));
            GroundOriginEffect.AddCustomField(TSFVec4f.Create(GroundOriginEffect,True,
              'gc_ground_origin_low',Vector4(
                -(Mdl.Origin.Lon-AOrigin.Lon)*Proj.MetersPerDegreeLon-Double(Delta.X),
                0,
                (Mdl.Origin.Lat-AOrigin.Lat)*Proj.MetersPerDegreeLat-Double(Delta.Z),1)));
            { Split the exact session translation before conversion to Single.
              All adjacent tiles use the same texture grid, including those
              hundreds of kilometres from the session origin. No large UV
              coordinates are interpolated or rotated in the fragment shader. }
            for GroundMat:=0 to GROUND_MAT_COUNT-1 do
            begin
              GroundGridOrigins[GroundMat]:=Vector4(0,0,0,0);
              GroundCellSize:=GROUND_MATERIALS[GroundMat].TexRandom.BlockTiles;
              if GroundCellSize<=0 then Continue;
              GroundGridX:=-(Mdl.Origin.Lon-AOrigin.Lon)*Proj.MetersPerDegreeLon/GroundCellSize;
              GroundGridZ:=(Mdl.Origin.Lat-AOrigin.Lat)*Proj.MetersPerDegreeLat/GroundCellSize;
              GroundGridOrigins[GroundMat]:=Vector4(Floor(GroundGridX),Floor(GroundGridZ),
                GroundGridX-Floor(GroundGridX),GroundGridZ-Floor(GroundGridZ));
            end;
            GroundOriginEffect.AddCustomField(TMFVec4f.Create(GroundOriginEffect,True,
              'gc_ground_grid_origin',GroundGridOrigins));
            (CompShape.Appearance as TAppearanceNode).FdEffects.Add(GroundOriginEffect);
            CompactTileGeometry(CompShape);
            GroundPlacement:=TTransformNode.Create;
            GroundPlacement.Translation:=Delta; GroundPlacement.AddChildren(CompShape);
            Result.AddChildren(GroundPlacement);
            LodGround := GroundPlacement;
            Inc(TotComposite);
          end;
        finally
          Comp.Free;
        end;
      end
      else if Rec.Material = smkTunnelWall then
      begin
        { Труба туннеля: бетон стен (палитра 2, как в Osm3dGeomTunnels),
          но шейп с ShadowCaster=False — труба под землёй, её тень на
          композите — артефакт-полоса вдоль трассы туннеля. }
        PlainCopy := ShiftedMeshCopy(Rec.Mesh, Delta, AKx);
        try
          if UseBldComp then
          begin
            if BldTunBuilder = nil then
              BldTunBuilder := TGroundCompositeBuilder.Create('building_composite_tunnel', 0.999);
            BldTunBuilder.Append(PlainCopy, MaterialIdForBuilding(2, False));
            Inc(TotBuilding);
          end
          else
          begin
            BShape := BuildBuildingShapeCached(PlainCopy,
              smkBuildingWall2, uvWallVertical, 2, False);
            if BShape <> nil then
            begin
              (BShape.Geometry as TIndexedFaceSetNode).Solid:=False;
              (BShape.Appearance as TAppearanceNode).ShadowCaster := False;
              Result.AddChildren(BShape);
              PushLod(LodBld, LodBldN, BShape);
              Inc(TotBuilding);
            end;
          end;
        finally
          PlainCopy.Free;
        end;
      end
      else if (Rec.Material >= smkBuildingWall0)
          and (Rec.Material <= smkBuildingWall9) then
      begin
        Pal := Ord(Rec.Material) - Ord(smkBuildingWall0);
        PlainCopy := ShiftedMeshCopy(Rec.Mesh, Delta, AKx);
        try
          if UseBldComp then
          begin
            { Walls carry window/floor UV in the mesh (uvWallVertical copies
              it verbatim), and the building FS uses the stored UV directly —
              no UV bake needed. Append copies the mesh into the composite
              pool, so PlainCopy can be freed right after. }
            BldBuilder.Append(PlainCopy, MaterialIdForBuilding(Pal, False));
            Inc(TotBuilding);
          end
          else
          begin
            BShape := BuildBuildingShapeCached(PlainCopy,
              Rec.Material, uvWallVertical, Pal, False);
            if BShape <> nil then
            begin
              Result.AddChildren(BShape);
              PushLod(LodBld, LodBldN, BShape);
              Inc(TotBuilding);
            end;
          end;
        finally
          PlainCopy.Free;
        end;
      end
      else if (Rec.Material >= smkBuildingRoof0)
          and (Rec.Material <= smkBuildingRoof5) then
      begin
        Pal := Ord(Rec.Material) - Ord(smkBuildingRoof0);
        PlainCopy := ShiftedMeshCopy(Rec.Mesh, Delta, AKx);
        try
          if UseBldComp then
          begin
            { Roofs have no per-vertex UV in the mesh — the legacy path
              derived it as (X,Z)/4 at shape-build time (uvRoofPlanar). The
              composite stores per-vertex UV. Use cached local metres plus a
              bounded geographic phase; world UVs lose mip/normal precision. }
            BVRef := Rec.Mesh.Vertices;
            for Bvi := 0 to High(BVRef) do
              PlainCopy.SetVertexUV(Bvi,
                MakeUV(BVRef[Bvi].Position.X * AKx / 4.0 + RoofPhaseX,
                       BVRef[Bvi].Position.Z / 4.0 + RoofPhaseZ));
            BldBuilder.Append(PlainCopy, MaterialIdForBuilding(Pal, True));
            Inc(TotBuilding);
          end
          else
          begin
            BShape := BuildBuildingShapeCached(PlainCopy,
              Rec.Material, uvRoofPlanar, Pal, True);
            if BShape <> nil then
            begin
              Result.AddChildren(BShape);
              PushLod(LodBld, LodBldN, BShape);
              Inc(TotBuilding);
            end;
          end;
        finally
          PlainCopy.Free;
        end;
      end
      else if (Rec.Material >= smkFence0)
          and (Rec.Material <= smkFence5) then
      begin
        FncPal := Ord(Rec.Material) - Ord(smkFence0);
        FncPlain := ShiftedMeshCopy(Rec.Mesh, Delta, AKx);
        try
          { Fences carry UV (length/uvWidth, height 0..1) in the mesh —
            the FS uses it verbatim, no bake. Append copies geometry into
            the pool, so FncPlain can be freed right after. With no atlas
            (UseFncComp=False) fences are simply skipped — the fence
            composite has no per-palette legacy fallback. }
          if UseFncComp then
            FncBuilder.Append(FncPlain, MaterialIdForFence(FncPal));
        finally
          FncPlain.Free;
        end;
      end
      else if Rec.Material = smkPlate then
      begin
        { Plates carry glyph UV (and sentinel UV on backplate verts) in the
          mesh — the FS uses it verbatim. Append copies geometry into the pool,
          so PltPlain can be freed right after. With no atlas URL
          (UsePltComp=False) plates are skipped (no legacy fallback). }
        PltPlain := ShiftedMeshCopy(Rec.Mesh, Delta, AKx);
        try
          if UsePltComp then
            PltBuilder.Append(PltPlain, 0);
        finally
          PltPlain.Free;
        end;
      end
      else if Rec.Material = smkRoadFurniture then
      begin
        PlainCopy:=ShiftedMeshCopy(Rec.Mesh,Delta,AKx);
        try
          BShape:=TShapeNode.Create('RoadFurniture');
          BShape.Geometry:=TMeshToX3D.CreateGeometry(PlainCopy,True,uvFromMesh);
          ApplyRoadFurnitureMaterial(BShape);
          Result.AddChildren(BShape);
        finally PlainCopy.Free end;
      end
      else if Copy(Rec.Name, 1, 8) = 'landuse_' then
      begin
        { Landuse surface not folded into the composite — name carries
          'landuse_<Ord(TLanduseMeshKind)>' (set by DistributeLanduse).
          With ACache the kind's textures are built once and USE-shared
          across all tiles; without it, per-shape (legacy callers). }
        LKIdx := StrToIntDef(Copy(Rec.Name, 9, MaxInt), -1);
        PlainCopy := ShiftedMeshCopy(Rec.Mesh, Delta, AKx);
        try
          if (ACache <> nil) and (LKIdx >= Ord(Low(TLanduseMeshKind)))
             and (LKIdx <= Ord(High(TLanduseMeshKind))) then
            BShape := ACache.SurfaceShape(PlainCopy,
              TLanduseMeshKind(LKIdx), Rec.Material)
          else
            BShape := TMeshToX3D.CreateSurfaceShape(PlainCopy, LKIdx,
              Rec.Material);
          if BShape <> nil then
          begin
            if TileEff <> nil then
              (BShape.Appearance as TAppearanceNode).FdEffects.Add(TileEff);
            Result.AddChildren(BShape);
            Inc(TotComposite);
          end;
        finally
          PlainCopy.Free;
        end;
      end;
    end;

    { Emit the merged building composite: ONE shape (one draw call) for
 every wall + roof of this tile, sampling the shared facade/roof atlas
 by per-vertex materialId. Skipped when the legacy per-palette path was
 taken (BldBuilder = nil) or nothing accumulated. Freeing BldComp after
 the shape is built is safe — BuildBuildingCompositeShape copies the
 geometry into X3D nodes (same lifetime pattern as the ground composite
 Comp.Free above). }
    if BldBuilder <> nil then
    begin
      BldComp := BldBuilder.Finalize(nil);
      FreeAndNil(BldBuilder);
      try
        if (BldComp <> nil) and (BldComp.TriangleCount > 0) then
        begin
          BldShape := BuildBuildingCompositeShape(BldComp,
            ACache.BuildAtlas, -ASunDir, BldDetailCollision, nil, GpuGround, Delta.X, Delta.Z);
          if BldShape <> nil then
          begin
            BldShape.X3DName := 'AtlasBuildingComposite';
            Result.AddChildren(BldShape);
            PushLod(LodBld, LodBldN, BldShape);
          end;
          if BldDetailCollision <> nil then
          begin
            { Visual trims never enter CPU collision/rider contact geometry. }
            Result.AddChildren(BldDetailCollision);
          end;
        end;
      finally
        BldComp.Free;
      end;
    end;

    { Трубы туннелей — свой композит-шейп с ShadowCaster=False (бетон тех
      же атласов, но без тени на композите земли). }
    if BldTunBuilder <> nil then
    begin
      BldTunComp := BldTunBuilder.Finalize(nil);
      FreeAndNil(BldTunBuilder);
      try
        if (BldTunComp <> nil) and (BldTunComp.TriangleCount > 0) then
        begin
          BldTunShape := BuildBuildingCompositeShape(BldTunComp,
            ACache.BuildAtlas, -ASunDir, nil);
          if BldTunShape <> nil then
          begin
            (BldTunShape.Geometry as TIndexedFaceSetNode).Solid:=False;
            (BldTunShape.Appearance as TAppearanceNode).ShadowCaster := False;
            Result.AddChildren(BldTunShape);
            PushLod(LodBld, LodBldN, BldTunShape);
          end;
        end;
      finally
        BldTunComp.Free;
      end;
    end;

    { One shape (one draw call) for all fences of this tile. Like the
      building composite, BuildFenceCompositeShape copies geometry into
      X3D nodes, so FncComp can be freed after the shape is built. }
    if FncBuilder <> nil then
    begin
      FncComp := FncBuilder.Finalize(nil);
      FreeAndNil(FncBuilder);
      try
        if (FncComp <> nil) and (FncComp.TriangleCount > 0) then
        begin
          FncShape := BuildFenceCompositeShape(FncComp,
            ACache.FenceAtlas, -ASunDir, nil);
          if FncShape <> nil then
            Result.AddChildren(FncShape);
        end;
      finally
        FncComp.Free;
      end;
    end;

    { One shape (one draw call) for all plates of this tile. Like the fence
      composite, BuildPlateCompositeShape copies geometry into X3D nodes, so
      PltComp can be freed after the shape is built. }
    if PltBuilder <> nil then
    begin
      PltComp := PltBuilder.Finalize(nil);
      FreeAndNil(PltBuilder);
      try
        if (PltComp <> nil) and (PltComp.TriangleCount > 0) then
        begin
          PltShape := BuildPlateCompositeShape(PltComp,
            ACache.PlateAtlas, -ASunDir, nil);
          if PltShape <> nil then
            Result.AddChildren(PltShape);
        end;
      finally
        PltComp.Free;
      end;
    end;

    if (RenderRoadsActive or RenderLanduseActive) and (Length(Mdl.Manholes)>0) then begin
      PoiBatch:=BuildManholeNode(Mdl.Manholes,AKx);
      if PoiBatch<>nil then begin
        PoiXform:=TTransformNode.Create;PoiXform.Translation:=Delta;
        PoiXform.AddChildren(PoiBatch);Result.AddChildren(PoiXform);
      end;
    end;

    { POI: static material batches by default. The template-instance path
      remains available for diagnostic A/B comparisons before starting a ride.
      RenderPOI gates both this path and legacy smkPOI meshes above. }
    if RenderPOIActive and RenderPOIBatchingActive then
    begin
      PoiBatch := BuildPoiBatchNode(Mdl, AKx, ACache.AccessoryAtlas, TmpSw, PoiInstanceCount);
      if PoiBatch <> nil then
      begin
        PoiXform := TTransformNode.Create;
        PoiXform.Translation := Delta;
        PoiXform.AddChildren(PoiBatch);
        Result.AddChildren(PoiXform);
      end;
      if TmpSw <> nil then
      begin
        SetLength(AccSwList, Length(AccSwList) + 1);
        AccSwList[High(AccSwList)] := TmpSw;
      end;
      Inc(TotPOI, PoiInstanceCount);
    end
    else if RenderPOIActive then
    for Mi := 0 to Mdl.POICount - 1 do
    begin
      PoiKind := Mdl.POIs[Mi].Kind;
      if PoiKind = pkxNone then Continue;
      if (PoiKind = pkxTrafficSignal) and not RenderTrafficSignalsActive then Continue;
      if POIKindShape[PoiKind] = nil then
      begin
        if PoiKind = pkxTrafficSignal then
        begin
          POIKindShape[PoiKind] :=
            BuildTrafficSignalNode(ACache.AccessoryAtlas, TmpSw);
          if TmpSw <> nil then
          begin
            SetLength(AccSwList, Length(AccSwList) + 1);
            AccSwList[High(AccSwList)] := TmpSw;
          end;
        end
        else
        begin
          PoiMesh := TPOIBuilderExt.BuildKindMesh(PoiKind);
          if (PoiMesh = nil) or (PoiMesh.TriangleCount = 0) then
          begin
            PoiMesh.Free;
            Continue;
          end;
          try
            POIKindShape[PoiKind] :=
              TMeshToX3D.CreateShape(PoiMesh, smkPOI, True);
          finally
            PoiMesh.Free;
          end;
        end;
        if POIKindShape[PoiKind] = nil then Continue;
      end;
      PoiXform := TTransformNode.Create;
      PoiXform.Translation := Vector3(
        Mdl.POIs[Mi].Position.X * AKx + Delta.X,
        Mdl.POIs[Mi].Position.Y,
        Mdl.POIs[Mi].Position.Z + Delta.Z);
      { face-the-road yaw for bus stops (0 for everything else). }
      if Mdl.POIs[Mi].Rotation <> 0 then
        PoiXform.Rotation := Vector4(0, 1, 0, Mdl.POIs[Mi].Rotation);
      PoiXform.AddChildren(POIKindShape[PoiKind]);
      Result.AddChildren(PoiXform);
      Inc(TotPOI);
    end;

    SetLength(LodBld, LodBldN);
    SetLength(LodWater, LodWaterN);
    WrapTileLOD(Result, Delta, AKx, LodGround, LodBld, LodWater, BldDetailCollision,
      GlobalLODConfig.LodPbrM, GlobalLODConfig.LodFullM, APrev);
    { CPU contact mode only borrows this assembly-time index for entrances. }
    if GpuGroundMode=ggCpu then FreeAndNil(GpuGround);
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1259);{$ENDIF}
  Result := TAssembledScenes.Create;
  ATrees := nil;
  TreeCount := 0;
  TotComposite := 0; TotBuilding := 0; TotWater := 0; TotPOI := 0;

  { МЕТРИКА РАССТАНОВКИ = МЕТРИКА ВЫПЕЧКИ. Оба Create раньше брали cos от
    широты AOrigin (1-арг. конструктор), и это совпадало с выпечкой, пока та
    тоже стояла на origin сессии. Как только выпечка переехала на широту
    МИРА (Settings.WorldScaleLatDeg / полоса), здесь образовался зазор — щель
    по востоку вылезла даже в Студии, где её отродясь не было. Масштаб
    приходит параметром от хоста, который знает настройки. }
  FrameLat := FrameScaleLat(AManualScaleLat, AOrigin.Lat);
  Proj  := TLocalProjection.Create(AOrigin, FrameLat);
  { Slippy grid for tile-centre placement — must match the cache's zoom/EdgePx. }
  Grid  := TGeoTileGrid.Create(AHeightmapZoom, GEO_TILE_EDGE_PX, FrameLat);
  for M := 0 to BUILDING_PALETTE_SIZE - 1 do
    PBRWallApp[M] := nil;
  for M := 0 to 5 do
    PBRRoofApp[M] := nil;
  for PoiK := Low(TPOIKindExt) to High(TPOIKindExt) do
    POIKindShape[PoiK] := nil;

  { Atlas + shared texture nodes. With a session cache: build once
    (EnsureAtlas) and reuse on every call — this is the expensive part
    (image decode + atlas pack), so amortising it is the whole point.
    Without a cache: build locally as before. The local Atlas is freed
    at the end; the cache's Atlas lives until the cache is freed. }
  if ACache <> nil then
  begin
    ACache.EnsureAtlas(LogProc);
    Atlas              := ACache.Atlas;
    { Per-tile ground effects (SharedEffect=nil): each tile builds its own
      TEffectNode — CGE shares the compiled GLSL program by source, so this
      adds no shader compiles, and it removes the last shared ground node
      from tile graphs (no DetachSharedFrom for the effect). In URL mode
      AtlasTex/RoadHaloTex are nil so each effect self-builds URL-deduped
      atlas + dummy nodes; in the inline fallback they are the shared
      pinned nodes every effect references. }
    SharedAtlasTex     := ACache.AtlasTex;
    SharedAtlasNormTex := ACache.AtlasNormTex;
    SharedAtlasMaskTex := ACache.AtlasMaskTex;
    SharedRoadHaloTex  := ACache.RoadHaloTex;
    SharedGroundEffect := nil;
  end
  else
  begin
    Atlas := TGroundAtlas.Create(DefaultGroundAtlasLayout);
    Atlas.BuildImage(LogProc);
    Atlas.BuildNormalImage(LogProc);
    { Маска обязательна так же, как в кэш-пути (TGroundAtlas.RunBuildPasses):
      BuildSharedTextureNodes ниже забирает канал acMask — без него там
      assert «channel image not built». }
    Atlas.BuildMaskImage(LogProc);
    TGroundCompositeShape.BuildSharedTextureNodes(
      Atlas, nil, TmpAtlasTex, TmpAtlasNormTex, TmpAtlasMaskTex, SharedRoadHaloTex);
    SharedAtlasTex     := TmpAtlasTex;
    SharedAtlasNormTex := TmpAtlasNormTex;
    SharedAtlasMaskTex := TmpAtlasMaskTex;
    SharedGroundEffect := nil;
  end;

  { Warmup: build & pin every shared resource up front (atlas above,
    all landuse surface textures, all 12 building PBR appearances) so a
    streamed tile only ever REFERENCES already-loaded textures and never
    triggers a load itself. Returns an empty result; Models untouched. }
  if AWarmupOnly then
  begin
    ATrees := nil;
    if ACache <> nil then
    begin
      ACache.WarmupSurfaces(LogProc);
      { Per-palette building PBR appearances (и запись их PNG в
        <cache>\atlas\buildings через BldCachePath) нужны только когда
        building-атлас в RAM-фоллбэке. При активном композитном атласе
        (DiffuseUrl<>'') тайлы идут композитным путём и эти аппирансы НЕ
        используются — не строим и не пишем их. }
      if (ACache.BuildAtlas = nil) or (ACache.BuildAtlas.DiffuseUrl = '') then
      begin
        for P := 0 to BUILDING_PALETTE_SIZE - 1 do
          PBRAppFor(P, False);
        for P := 0 to 5 do
          PBRAppFor(P, True);
        if Assigned(LogProc) then
          LogProc('  Warmup: building PBR appearances pre-loaded');
      end
      else if Assigned(LogProc) then
        LogProc('  Warmup: building atlas active — per-palette PBR appearances skipped');
    end;
    Proj.Free;
    Grid.Free;
    Exit;
  end;

  try
    { Global root — lights + sky only. Far terrain is not cached. }
    Result.GlobalRoot := TX3DRootNode.Create;
    AddSceneLights(Result.GlobalRoot, ASunDir, False);

    SetLength(Result.Tiles, Length(Models));
    TileCount := 0;

    { Pre-size ATrees once (sum of every model's tree count) so the collection loop never
      reallocates. The sum equals the final TreeCount exactly. }
    TreeCap := 0;
    for T := 0 to High(Models) do
      if Models[T] <> nil then
        Inc(TreeCap, Models[T].TreeCount);
    SetLength(ATrees, TreeCap);

    { ---- Per-tile building-shadow masks (streaming-friendly) ----
      Each loaded tile gets its OWN coverage mask, sized to the tile plus
      a 20% margin on the side(s) the shadow exits toward (derived from
      the sun azimuth), so cross-tile shadows have room. Phase 1 projects
      each tile's silhouettes and registers them in the persistent cache
      registry; phase 2 builds each tile's mask by pulling every
      registered silhouette overlapping it — its own, its pack siblings,
      and neighbours loaded in earlier packs. }
    SunToward := Vector3(-ASunDir.X, -ASunDir.Y, -ASunDir.Z);
    LocalCursor := 0;
    SetLength(FootMinX, Length(Models)); SetLength(FootMinZ, Length(Models));
    SetLength(FootMaxX, Length(Models)); SetLength(FootMaxZ, Length(Models));
    SetLength(FootHas,  Length(Models));

    { phase 1 — project each tile's building wall+roof polygons straight
      onto the ground and register the projected triangles. The shadow is
      the union of those projected polygons (no silhouette skirt). }
    if GroundShadowsActive then
    for sT := 0 to High(Models) do
    begin
      if Models[sT] = nil then Continue;
      sCtr := Proj.Project(Grid.TileCenter(Models[sT].TileId));
      { Тот же пер-тайловый масштаб востока, что у видимых мешей (Kx
        монтирования): силуэты читают СЫРЫЕ тайл-локальные вершины из кэша,
        и без него тень тайла чужой полосы отъезжала бы от здания на
        (Kx−1)·x — до ~1.5 м у кромки. Внутри полосы кадра Kx=1.0 ровно. }
      Kx := TileFrameScaleX(Models[sT].TileId, Grid, FrameLat, AManualScaleLat);
      SetLength(TileTris, 256);
      nTileTris := 0;
      tmnx := 0; tmnz := 0; tmxx := 0; tmxz := 0;
      fHasFp := False;
      fmnx := 0; fmnz := 0; fmxx := 0; fmxz := 0;

      { ---- pass A: ground FOOTPRINT bbox + lowest ground Y, from the
        tile's ground composite (every vertex). ---- }
      TileGround := nil; GroundCount := 0;
      gMinY := 0;
      for sMi := 0 to Models[sT].MeshCount - 1 do
      begin
        sRec := Models[sT].Meshes[sMi];
        if (sRec.Mesh = nil) or (sRec.Mesh.VertexCount = 0) then Continue;
        if Length(sRec.MatIds) <> sRec.Mesh.VertexCount then Continue;
        sV := sRec.Mesh.Vertices;
        sI := sRec.Mesh.Indices;
        SetLength(TileGround, GroundCount + sRec.Mesh.TriangleCount);
        for sTi := 0 to sRec.Mesh.TriangleCount - 1 do
        begin
          GroundTri.A := sV[sI[sTi*3]].Position;
          GroundTri.B := sV[sI[sTi*3+1]].Position;
          GroundTri.C := sV[sI[sTi*3+2]].Position;
          GroundTri.A.X := GroundTri.A.X*Kx+sCtr.X;
          GroundTri.B.X := GroundTri.B.X*Kx+sCtr.X;
          GroundTri.C.X := GroundTri.C.X*Kx+sCtr.X;
          GroundTri.A.Z := GroundTri.A.Z+sCtr.Z;
          GroundTri.B.Z := GroundTri.B.Z+sCtr.Z;
          GroundTri.C.Z := GroundTri.C.Z+sCtr.Z;
          TileGround[GroundCount] := GroundTri; Inc(GroundCount);
        end;
        for sVi := 0 to sRec.Mesh.VertexCount - 1 do
        begin
          fpx := sV[sVi].Position.X * Kx + sCtr.X;
          fpz := sV[sVi].Position.Z + sCtr.Z;
          gWy := sV[sVi].Position.Y;
          if not fHasFp then
          begin
            fmnx := fpx; fmxx := fpx; fmnz := fpz; fmxz := fpz;
            gMinY := gWy; fHasFp := True;
          end
          else
          begin
            if fpx < fmnx then fmnx := fpx;
            if fpx > fmxx then fmxx := fpx;
            if fpz < fmnz then fmnz := fpz;
            if fpz > fmxz then fmxz := fpz;
            if gWy < gMinY then gMinY := gWy;
          end;
        end;
      end;

      sSy := SunToward.Y;
      if sSy < 0.001 then sSy := 0.001;

      { Preserve raw wall/roof triangles for receiver-height rasterization.
        Flat projections are retained only for legacy callers and bounds. }
      for sMi := 0 to Models[sT].MeshCount - 1 do
      begin
        sRec := Models[sT].Meshes[sMi];
        if (sRec.Mesh = nil) or (sRec.Mesh.TriangleCount = 0) then Continue;
        if Length(sRec.MatIds) = sRec.Mesh.VertexCount then Continue;
        if not (((sRec.Material >= smkBuildingWall0) and (sRec.Material <= smkBuildingWall9))
             or ((sRec.Material >= smkBuildingRoof0) and (sRec.Material <= smkBuildingRoof5))) then
          Continue;

        sV := sRec.Mesh.Vertices;  sI := sRec.Mesh.Indices;
        for sTi := 0 to sRec.Mesh.TriangleCount - 1 do
        begin
          si0 := sI[sTi * 3];
          si1 := sI[sTi * 3 + 1];
          si2 := sI[sTi * 3 + 2];
          sP0 := sV[si0].Position;  sP1 := sV[si1].Position;  sP2 := sV[si2].Position;
          sPA := ProjectVertToGround(sP0, sCtr,
                   gMinY, SunToward, sSy, sLA, Kx);
          sPB := ProjectVertToGround(sP1, sCtr,
                   gMinY, SunToward, sSy, sLB, Kx);
          sPC := ProjectVertToGround(sP2, sCtr,
                   gMinY, SunToward, sSy, sLC, Kx);
          if nTileTris >= Length(TileTris) then
            SetLength(TileTris, Length(TileTris) * 2);
          TileTris[nTileTris].SourceA := Vector3(sP0.X*Kx+sCtr.X,sP0.Y,sP0.Z+sCtr.Z);
          TileTris[nTileTris].SourceB := Vector3(sP1.X*Kx+sCtr.X,sP1.Y,sP1.Z+sCtr.Z);
          TileTris[nTileTris].SourceC := Vector3(sP2.X*Kx+sCtr.X,sP2.Y,sP2.Z+sCtr.Z);
          TileTris[nTileTris].SunSlope := Vector2(SunToward.X/sSy,SunToward.Z/sSy);
          TileTris[nTileTris].HasSource := True;
          TileTris[nTileTris].A := Vector2(sPA.X, sPA.Z);
          TileTris[nTileTris].B := Vector2(sPB.X, sPB.Z);
          TileTris[nTileTris].C := Vector2(sPC.X, sPC.Z);
          TileTris[nTileTris].IA := ShadowIntensityFor(sLA);
          TileTris[nTileTris].IB := ShadowIntensityFor(sLB);
          TileTris[nTileTris].IC := ShadowIntensityFor(sLC);
          TileTris[nTileTris].MinX := Min(sPA.X, Min(sPB.X, sPC.X));
          TileTris[nTileTris].MaxX := Max(sPA.X, Max(sPB.X, sPC.X));
          TileTris[nTileTris].MinZ := Min(sPA.Z, Min(sPB.Z, sPC.Z));
          TileTris[nTileTris].MaxZ := Max(sPA.Z, Max(sPB.Z, sPC.Z));
          if nTileTris = 0 then
          begin
            tmnx := TileTris[0].MinX; tmxx := TileTris[0].MaxX;
            tmnz := TileTris[0].MinZ; tmxz := TileTris[0].MaxZ;
          end
          else
          begin
            if TileTris[nTileTris].MinX < tmnx then tmnx := TileTris[nTileTris].MinX;
            if TileTris[nTileTris].MaxX > tmxx then tmxx := TileTris[nTileTris].MaxX;
            if TileTris[nTileTris].MinZ < tmnz then tmnz := TileTris[nTileTris].MinZ;
            if TileTris[nTileTris].MaxZ > tmxz then tmxz := TileTris[nTileTris].MaxZ;
          end;
          Inc(nTileTris);
        end;
      end;

      { vegetation — collect this tile's tree silhouette cards and fold their
        world-XZ bbox into the tile bbox, so the registry entry (and its mask
        window) covers trees too. Stored next to the triangles -> identical
        cross-tile pull and cross-pack push. }
      TileTreeCards := CollectTreeCardsForModel(Models[sT], sCtr, SunToward, Kx);
      for tci := 0 to High(TileTreeCards) do
      begin
        if (nTileTris = 0) and (tci = 0) then
        begin
          tmnx := TileTreeCards[tci].MinX; tmxx := TileTreeCards[tci].MaxX;
          tmnz := TileTreeCards[tci].MinZ; tmxz := TileTreeCards[tci].MaxZ;
        end
        else
        begin
          if TileTreeCards[tci].MinX < tmnx then tmnx := TileTreeCards[tci].MinX;
          if TileTreeCards[tci].MaxX > tmxx then tmxx := TileTreeCards[tci].MaxX;
          if TileTreeCards[tci].MinZ < tmnz then tmnz := TileTreeCards[tci].MinZ;
          if TileTreeCards[tci].MaxZ > tmxz then tmxz := TileTreeCards[tci].MaxZ;
        end;
      end;

      { Keep receiver-only tiles too: a later neighbour can cast onto them.
        Conservative reach is for registry culling only, never texture sizing. }
      if fHasFp and (nTileTris=0) and (Length(TileTreeCards)=0) then
      begin
        tmnx := fmnx; tmxx := fmxx; tmnz := fmnz; tmxz := fmxz;
      end;
      if fHasFp then
      begin
        tmnx := Min(tmnx,fmnx); tmxx := Max(tmxx,fmxx);
        tmnz := Min(tmnz,fmnz); tmxz := Max(tmxz,fmxz);
      end;
      if SunToward.X > 0 then tmnx := tmnx-SHADOW_MAX_REACH
      else if SunToward.X < 0 then tmxx := tmxx+SHADOW_MAX_REACH;
      if SunToward.Z > 0 then tmnz := tmnz-SHADOW_MAX_REACH
      else if SunToward.Z < 0 then tmxz := tmxz+SHADOW_MAX_REACH;
      if (nTileTris > 0) or (Length(TileTreeCards) > 0) or fHasFp then
      begin
        SetLength(TileTris, nTileTris);
        { off-thread path: stash this tile's projected silhouettes on the
          model so the streaming map can snapshot them (+ its 1-ring) for
          the shadow worker. Transient — not serialised by TTileX3D. }
        Models[sT].ShadowTris      := Copy(TileTris, 0, nTileTris);
        Models[sT].ShadowTrees     := Copy(TileTreeCards, 0, Length(TileTreeCards));
        Models[sT].ShadowProjected := True;
        if ACache <> nil then
          ACache.RegisterTileShadow(Models[sT].TileId, TileTris, TileTreeCards,
            tmnx, tmnz, tmxx, tmxz, TileGround)
        else
          RegisterShadowReg(LocalReg, LocalCursor, Models[sT].TileId,
            TileTris, TileTreeCards, tmnx, tmnz, tmxx, tmxz, 4096, TileGround);
      end;
      FootHas[sT] := fHasFp;
      if fHasFp then
      begin
        FootMinX[sT] := fmnx; FootMinZ[sT] := fmnz;
        FootMaxX[sT] := fmxx; FootMaxZ[sT] := fmxz;
      end;
    end;

    { phase 2 — one mask + overlay effect per tile, pulled from the registry }
    SetLength(TileMasks, 0);
    nTileMask := 0;
    smHalf := Grid.EdgeMeters * 0.5;
    smMarg := Grid.EdgeMeters * 0.20;
    smPad  := 2.0;   { covers blur + small composite overhang past the cell }
    if GroundShadowsActive then
    for sT := 0 to High(Models) do
    begin
      if Models[sT] = nil then Continue;
      sCtr := Proj.Project(Grid.TileCenter(Models[sT].TileId));

      { Base window = the tile's real ground footprint (the composite can
        overhang the nominal cell, so center +/- half-edge would clip the
        edge strip). Fall back to the nominal cell if no footprint. }
      if FootHas[sT] then
      begin
        smMinX := FootMinX[sT] - smPad; smMaxX := FootMaxX[sT] + smPad;
        smMinZ := FootMinZ[sT] - smPad; smMaxZ := FootMaxZ[sT] + smPad;
      end
      else
      begin
        smMinX := sCtr.X - smHalf; smMaxX := sCtr.X + smHalf;
        smMinZ := sCtr.Z - smHalf; smMaxZ := sCtr.Z + smHalf;
      end;
      { 20% margin only on the side(s) the shadow exits (away from sun) }
      if SunToward.X < 0 then smMaxX := smMaxX + smMarg
      else if SunToward.X > 0 then smMinX := smMinX - smMarg;
      if SunToward.Z < 0 then smMaxZ := smMaxZ + smMarg
      else if SunToward.Z > 0 then smMinZ := smMinZ - smMarg;

      MaskOrigin := Vector2(smMinX, smMinZ);
      MaskSize   := Vector2(smMaxX - smMinX, smMaxZ - smMinZ);
      smRes := ShadowMaskRes(MaskSize.X, MaskSize.Y);

      { off-thread path: record the mask window + resolution on the model so
        the streaming map can size/place the worker-built mask. Set for every
        tile (even ones with no own caster — they may receive a neighbour's). }
      Models[sT].ShadowOX    := MaskOrigin.X;  Models[sT].ShadowOZ := MaskOrigin.Y;
      Models[sT].ShadowSX    := MaskSize.X;    Models[sT].ShadowSZ := MaskSize.Y;
      Models[sT].ShadowMaskW := ShadowTexW(smRes, ShadowMaskBitsActive);
      Models[sT].ShadowMaskH := ShadowTexH(smRes, ShadowMaskBitsActive);
      Models[sT].ShadowMaskTreeW := TreeShadowTexW(smRes, ShadowMaskBitsTree);
      Models[sT].ShadowMaskTreeH := TreeShadowTexH(smRes, ShadowMaskBitsTree);

      { Every tile gets a CPU shadow-mask node from birth (all-zero
        placeholder = no shadow yet), regardless of whether any silhouette
        currently reaches it. This is the RECEIVER for cross-tile shadows:
        the per-tile push in the streaming map can only re-upload into an
        existing mask node, so a tile built before its caster-neighbour
        arrives MUST already own a node — otherwise the push finds none
        (GetTileMaskTexByKey = nil) and the neighbour's shadow never lands.
        The mask shader (SHADOW_MASK_FS) early-returns on zero coverage and
        never discards, so an empty mask on every tile costs no early-Z and
        no visible change until the worker fills it. The worker rasterises
        the real coverage off-thread; Update uploads one mask per frame. }
      if (ACache <> nil) then
      begin
        ShadowMaskImg := TGrayscaleImage.Create(
          ShadowTexW(smRes, ShadowMaskBitsActive), ShadowTexH(smRes, ShadowMaskBitsActive));
        ShadowMaskImg.Clear(Vector4Byte(0, 0, 0, 0));
        if ShadowMaskBitsTree >= 8 then
          ShadowMaskImgTree := TGrayscaleAlphaImage.Create(
            TreeShadowTexW(smRes, ShadowMaskBitsTree), TreeShadowTexH(smRes, ShadowMaskBitsTree))
        else
          ShadowMaskImgTree := TGrayscaleImage.Create(
            TreeShadowTexW(smRes, ShadowMaskBitsTree), TreeShadowTexH(smRes, ShadowMaskBitsTree));
        ShadowMaskImgTree.Clear(Vector4Byte(0, 0, 0, 0));
        if nTileMask >= Length(TileMasks) then
          SetLength(TileMasks, Max(16, Length(TileMasks) * 2));
        TileMasks[nTileMask].TileId := Models[sT].TileId;
        TileMasks[nTileMask].Effect := BuildShadowMaskEffect(
          ShadowMaskImg, ShadowMaskImgTree, MaskOrigin, MaskSize, smRes,
          MaskTex, MaskField, MaskTexTree);
        ACache.SetTileMaskTexture(Models[sT].TileId, MaskTex, MaskTexTree, MaskField,
          MaskOrigin.X, MaskOrigin.Y, MaskSize.X, MaskSize.Y);
        Inc(nTileMask);
      end;
    end;
    SetLength(TileMasks, nTileMask);

    { No synchronous cross-pack push here: the streaming map enqueues a
      shadow-mask snapshot per mounted tile AND re-enqueues the 1-ring of
      each new pack (the reverse-order case — a caster mounted after its
      receiver), with a deferred re-request so a receiver busy with an
      older job is still corrected once it drains. The worker rasterises
      off the main thread; cross-tile reach comes from the persistent
      registry via CollectTileSnapshot. }

    if Assigned(LogProc) then
      LogProc(Format('  shadow masks: %d tiles', [nTileMask]));

    for T := 0 to High(Models) do
    begin
      if Models[T] = nil then Continue;

      { Chunk-local XYZ of the tile centre — cached tile vertices are
        in the tile's own conventional frame; this re-anchors them. }
      TileCtr := Proj.Project(Grid.TileCenter(Models[T].TileId));

      { Пер-тайловый масштаб ВОСТОКА: тайл испечён в метрике СВОЕЙ полосы,
        кадр сессии — в своей. Внутри полосы кадра Kx = 1.0 ровно (та же
        полоса → тот же cos → деление даёт единицу побитно, путь прежний);
        тайл соседней полосы растягивается/сжимается по X на e^±0.01 (~1%),
        чтобы его градусная ширина легла в шаг решётки кадра — иначе на
        границе полос была бы щель ~3 м. Z (север) от метрики не зависит. }
      Kx := TileFrameScaleX(Models[T].TileId, Grid, FrameLat, AManualScaleLat);

      { Collect vegetation. }
      for M := 0 to Models[T].TreeCount - 1 do
      begin
        ATrees[TreeCount] := Models[T].Trees[M];
        { tree coords are tile-local too — scale east + shift to chunk space }
        ATrees[TreeCount].X := ATrees[TreeCount].X * Kx + TileCtr.X;
        ATrees[TreeCount].Z := ATrees[TreeCount].Z + TileCtr.Z;
        Inc(TreeCount);
      end;

      PrevT := nil;
      if T <= High(APreviews) then PrevT := APreviews[T];
      Result.Tiles[TileCount].Root:=BuildTileRoot(Models[T],TileCtr,PrevT,Kx,Result.Tiles[TileCount].CurbVertices,Result.Tiles[TileCount].GpuGround);
      { Build alongside geometry in the existing assembly worker. Mounting
        a heavy city tile must not add an audio scan to the render thread. }
      Result.Tiles[TileCount].Soundscape:=TSoundscapeField.Create(Models[T],Kx,True,False);
      Result.Tiles[TileCount].CenterX   := TileCtr.X;
      Result.Tiles[TileCount].CenterZ   := TileCtr.Z;
      Result.Tiles[TileCount].TileId    := Models[T].TileId;
      Result.Tiles[TileCount].HasTileId := True;
      Inc(TileCount);
    end;
    SetLength(Result.Tiles, TileCount);

    { Accessory (traffic-light) Switch nodes gathered during POI-shape build
      (BuildTrafficSignalNode). Collected into a local to dodge the same nested
      Result-shadowing noted above, then handed to the assembled scenes here. }
    Result.AccessorySwitches := AccSwList;

    { Wind uniforms for the host per-frame push: ONE tree walk per tile (all 3
      fields), pre-sized to TileCount, then trimmed. No per-item realloc. }
    SetLength(Result.GroundWindTimeFields, TileCount);
    SetLength(Result.GroundWindBaseFields, TileCount);
    SetLength(Result.GroundWindGustFields, TileCount);
    wCnt := 0;
    for T := 0 to TileCount - 1 do
      if FindGroundWindFields(Result.Tiles[T].Root, wFT, wFB, wFG) then
      begin
        Result.GroundWindTimeFields[wCnt] := wFT;
        Result.GroundWindBaseFields[wCnt] := wFB;
        Result.GroundWindGustFields[wCnt] := wFG;
        Inc(wCnt);
      end;
    SetLength(Result.GroundWindTimeFields, wCnt);
    SetLength(Result.GroundWindBaseFields, wCnt);
    SetLength(Result.GroundWindGustFields, wCnt);

    if Assigned(LogProc) then
      LogProc(Format('AssembleCachedTiles: %d tiles direct ' +
        '(%d composite, %d building, %d water, %d POI, %d trees) — ' +
        'no merge, no re-split',
        [TileCount, TotComposite, TotBuilding, TotWater, TotPOI, TreeCount]));
  except
    Result.Free;
    raise;
  end;

  Proj.Free;
  Grid.Free;
end;

finalization
  { Release the last build's PBR processor + its temp files. }
  FreeAndNil(FPBRProc);

end.

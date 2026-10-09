unit Osm3dTileStreamer;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$modeswitch nestedprocvars}
{$codepage UTF8}

interface

uses
  Classes,
  SysUtils,
  SyncObjs,
  Math,
  Generics.Collections,
  CastleVectors, Osm3dShadowReceiver,
  Osm3dGeoMath,
  Osm3dGeoTileGrid,
  Osm3dGeoTileCache,
  Osm3dTileX3D,
  Osm3dTilePreview,
  Osm3dHeightmap,
  Osm3dCacheHTTPFetcher,
  Osm3dMemBudget,
  Osm3dStudioLog,
  Osm3dGeoTileBlock,
  Osm3dPrevTexFetcher,       { новый источник превью-текстур по блокам (.ptex.png) }
  Osm3dStudioSettings        { STREAM_*_RADIUS_M — consolidated streaming distances }
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
,
  crc;               { crc32 — подписи кромок превью в диагностическом логе }

type
  { Result of one block generation, returned by the OnGenerateBlock
    callback. On Success, Tiles holds the block's per-tile models with
    the block's halo geometry already discarded; ownership of every
    element passes to the streamer (it will Save and/or Free them). }
  TBlockGenResult = record
    Success: Boolean;
    Tiles:   TTileModelArray;
    Previews: array of TTilePreviewData;  { параллельно Tiles; nil-ы допустимы }
    Error:   string;
  end;

  { Block generation callback. Runs on a worker thread.
      ABlock   — which block to produce.
      AHaloBox — geographic bounds to fetch/build (block + halo margin);
                 build everything for this region, keep only the block's
                 own tiles.
      AOrigin  — local projection origin for the produced tile models.
      ACancel  — cooperative cancel flag; poll it during long work and
                 abort early when it becomes True.
    Must be thread-safe and must not mutate CGE scene/GL state. }
  TBlockGenerator = function(const ABlock: TBlockId;
    const AHaloBox: TLatLonBox; const AOrigin: TLatLon;
    ACancel: PBoolean): TBlockGenResult of object;

  { Shadow-mask worker plumbing
 A gen job is a self-contained snapshot — mask window + resolution +
 merged silhouettes of a tile and its 1-ring — that the shadow worker
 turns into raw mask bytes with NO access to any TTileModel. Built on the
 main thread (Osm3dTileX3D.CollectMaskSilhouettes), enqueued via
 EnqueueShadowGen; results applied on the main thread via PeekShadowUpload
 + CommitShadowUpload. Heap-allocated (PShadowGenJob/PShadowUpload) so the
 FIFO lists can drop entries by key when a tile is evicted. }
  TShadowGenJob = record
    Key:  string;                  { target tile key }
    Gen:  QWord;                   { mount-generation of the tile when this
                                     job was enqueued. Carried through to the
                                     upload so the main-thread drain can
                                     reject a result produced for a tile that
                                     has since evicted and re-mounted (the
                                     re-mount bumps the generation). Defeats
                                     TCacheTile address reuse, which a raw
                                     pointer identity check cannot. }
    OX, OZ, SX, SZ: Single;        { mask window origin + size (object XZ) }
    W, H: Integer;                 { mask resolution (texels) }
    Ground: TShadowGroundTriangles;
    Tris:  TProjTriArray;          { merged building/roof silhouettes }
    Trees: TShadowTreeCardArray;   { merged tree/shrub cards }
  end;
  PShadowGenJob = ^TShadowGenJob;

  TShadowUpload = record
    Key:   string;
    Gen:   QWord;                  { copied from the gen job — see above }
    Bytes:     TShadowMaskBytes;   { BUILDINGS packed mask }
    BytesTree: TShadowMaskBytes;   { TREES packed mask (darkness+sway) }
  end;
  PShadowUpload = ^TShadowUpload;

  { Actual completed work in the current block stage and its last advancement. }
  TBlockPhaseRec = record
    Phase: TBlockPhase;
    Stage: string;
    Completed, Total: Int64;
    Tick: QWord; { Last actual advancement, never an elapsed-time heartbeat. }
  end;

  { Фильтр «строить ли тайл?»: если назначен, keyhole в Pump ПРОПУСКАЕТ
    тайлы, для которых предикат вернул False (режим «геометрия только вдоль
    пути FIT» — потоковая карта отдаёт сюда проверку принадлежности коридору).
    nil (по умолчанию) — обычная камерная замочная скважина без фильтра.
    Вызывается на ГЛАВНОМ потоке (Pump). }
  TTileWantFilter = function(const AId: TGeoTileId): Boolean of object;

  TTileStreamer = class
  public type
    { Internal worker-thread entry point — public only so the worker
      class can reach it; host code never calls these. }
    TStreamJobFunc = function: Boolean of object;
    { Задание фон-сохранения: смонтированную модель пишем в кэш ПОСЛЕ монтажа
      (в отдельном потоке), затем освобождаем. Очередь владеет моделью. }
    TSaveJob = record
      TileId: TGeoTileId;
      Model:  TTileModel;
    end;
  private type
    TTileStreamState = (
      tssUnknown,        { not yet scheduled }
      tssQueuedIO,       { scheduled for a disk load (pending or in flight) }
      tssWaitingBlock,   { its block is scheduled for generation }
      tssReadyInRAM,     { model loaded/generated, not yet in CGE }
      tssUploaded,       { handed to the host and mounted in CGE }
      tssFailed);        { load/generation failed }

    TBlockGenState = (
      bgsIdle,           { never scheduled }
      bgsQueued,         { scheduled for generation (pending or in flight) }
      bgsDone,           { generation finished, all tile files on disk }
      bgsFailed);        { generation failed }

    TStreamResultKind = (srkTileLoaded, srkBlockDone, srkBlockFailed);

    TTileSlot = class
      Id:              TGeoTileId;
      State:           TTileStreamState;
      Model:           TTileModel;    { owned while <> nil }
      Priority:        Double;        { lock-guarded; read by workers }
      DesiredPriority: Double;        { Pump-only working value }
      WithinUpload:    Boolean;       { inside UploadRadius this frame }
      LastWantedFrame: Int64;
      QueuedForUpload: Boolean;
      { Модель родилась в ГЕНЕРАЦИИ и ещё не записана в кэш. Пока флаг
        поднят, модель нельзя просто освободить — только через
        EnqueueSave, иначе тайл потеряется и блок перегенерируется.
        Загрузка с диска (ApplyTileLoaded) ставит False: копия уже там. }
      NeedsSave:       Boolean;
      RetryFrame:      Int64;         { earliest frame to retry a failed load
                                        (mirror of TBlockSlot.RetryFrame) }
      destructor Destroy; override;
    end;

    TBlockSlot = class
      Id:              TBlockId;
      State:           TBlockGenState;
      Priority:        Double;        { lock-guarded }
      DesiredPriority: Double;        { Pump-only }
      LastTouchFrame:  Int64;
      RetryFrame:      Int64;         { earliest frame to retry after a fail }
      LastError:       string;        { retained while an automatic retry runs }
    end;

    TStreamResultItem = class
      Kind:   TStreamResultKind;
      Epoch:  Integer;
      TileId: TGeoTileId;
      Model:  TTileModel;             { srkTileLoaded; nil on load failure }
      Block:  TBlockId;
      Tiles:  TTileModelArray;        { srkBlockDone }
      Error:  string;
      destructor Destroy; override;
    end;
  private
    FCache:      TGeoTileCache;       { not owned }
    FOrigin:     TLatLon;
    FZone:       Byte;
    FEdgeMeters: Double;
    FBlockSize:  Integer;
    FHaloMeters: Double;

    FBlockGen:   TBlockGenerator;
    FLog:        TLogTarget;     { not owned — supplied by the host }

    { registry — touched only by the main thread (Pump); числовые ключи
      (TGeoTileId.ToKey / BlockKeyOf) — горячие lookup'и без строк }
    FTiles:  specialize TDictionary<Int64, TTileSlot>;
    FBlocks: specialize TDictionary<Int64, TBlockSlot>;
    { Фазы блоков (ключ = BlockKeyOf(block)): пишет ВОРКЕР (SetBlockPhase),
      читает main (BlockProgressForTile) — под FPhaseLock. }
    FBlockPhase: specialize TDictionary<Int64, TBlockPhaseRec>;
    FPhaseLock:  TCriticalSection;

    { scheduling — guarded by FQueueLock }
    FQueueLock:  TCriticalSection;
    FPendingIO:  specialize TList<TTileSlot>;
    FPendingGen: specialize TList<TBlockSlot>;
    FEpoch:      Integer;
    { Gen-start stagger: enforce a minimum spacing between the moments
      successive workers BEGIN a block, so their CPU-heavy carve phases land
      in each other's single-threaded gaps instead of colliding on the cores.
      FNextGenStartTick is the earliest tick the next block may start; each
      worker reserves a monotonic slot under FGenStartLock. }
    FGenStartLock:    TCriticalSection;
    FNextGenStartTick: QWord;

    { results — guarded by FResultLock }
    FResultLock: TCriticalSection;
    FResults:    specialize TQueue<TStreamResultItem>;

    { main-thread output }
    FUploadList: specialize TList<TTileSlot>;
    FEvictQueue: specialize TQueue<TGeoTileId>;
    { Tiles the route snapper has pinned: never evicted and their pending
      gen/IO is never cancelled while pinned. Only these tiles are held —
      all other eviction proceeds normally (no global freeze). Touched only
      on the main thread (SetPinnedTiles / Pump). }
    FPinned: specialize TDictionary<Int64, Boolean>;

    { workers }
    FIOWorkers:  array of TThread;
    FGenWorkers: array of TThread;
    FWakeIO:     TEvent;
    FWakeGen:    TEvent;
    { Фон-сохранение в кэш ПОСЛЕ монтажа (модель уже сварена и прочитана). }
    FSaveWorker: TThread;
    FWakeSave:   TEvent;
    FSaveQueue:  specialize TQueue<TSaveJob>;
    FSaveLock:   TCriticalSection;
    FShutdown:   Boolean;             { also the generator cancel flag }

    { shadow worker — gen + upload FIFO lists guarded by FShadowLock }
    FShadowLock:   TCriticalSection;
    FGenQueue:     specialize TList<PShadowGenJob>;
    FUploadQueue:  specialize TList<PShadowUpload>;
    FShadowWorker: TThread;
    FWakeShadow:   TEvent;

    { motion estimate (main thread) }
    FHasPrev: Boolean;
    FPrevE:   Double;
    FPrevN:   Double;
    FVelE:    Double;
    FVelN:    Double;
    FSpeed:   Double;

    FFrame:   Int64;
    { Диагностика обрезания keyhole-скана (FIX: MaxScanTiles). Pump живёт
      на ГЛАВНОМ потоке и не может звать Log (риск дедлока через
      Synchronize — см. комментарий в Log), поэтому заметка кладётся под
      FQueueLock, а ближайший воркер-джоб публикует её через Log. }
    FScanClampNote:     string;
    FScanClampLogFrame: Int64;
    { HOLE-DIAG: same worker-published-note channel for the mem-pressure load
      clamp starving the near ring. Separate field so it can't be displaced by
      a scan-clamp note in the same window; both drained in EmitScanClampNote. }
    FLoadClampNote:     string;
    FLoadClampLogFrame: Int64;

    { Источник высотных превью (режим 1 ДО генерации блока): heightmap-
      тайлы фетчатся на IO-воркере (HTTP-кэш общий с генератором, так что
      блок потом возьмёт их бесплатно). nil — высотный путь выключен. }
    FHmFetcher:     TTerrariumFetcher;   { shared height provider, not owned }
    FHmZoom:        Integer;
    FFarZoom:       Integer;             { грубый zoom высот суперов (~10), 0=как FHmZoom }
    FPrevTex:       TPrevTexFetcher;     { источник превью-текстур по блокам, not owned }

    { Кламп радиусов загрузки при давлении памяти: эвикнутые картой
      батчи не должны немедленно попадать обратно в скан-окно.
      0 = неактивен. Плавно отпускается в Pump, когда давление ушло. }
    FLoadClampM: Double;

    { Камера в тайловых единицах — кэш для сортировки очереди аплоада по
      близости (ставится в Pump). }
    FPrevCamE, FPrevCamN, FPrevEdgeM: Double;

    procedure Log(const AMsg: string);

    { scheduling helpers — main thread }
    procedure EnqueueIO(ASlot: TTileSlot);
    procedure ScheduleBlockFor(const AId: TGeoTileId; ASlot: TTileSlot;
                               APriority: Double);
    { Как ScheduleBlockFor, но БЕЗ tile-slot: ставит только блок в очередь
      генерации (режим «весь коридор пути сразу» — карта префетчит дальние
      тайлы коридора на диск, не удерживая их модели в RAM). Слот тайла не
      создаётся, поэтому по готовности блока ApplyBlockDone сохраняет такой
      тайл в кэш и СРАЗУ освобождает (ветка «тайл не нужен стримингу»). }
    procedure RequestBlockGen(const AId: TGeoTileId; APriority: Double);
    procedure EnqueueGen(ABlock: TBlockSlot);
    function  RemoveFromPendingIO(ASlot: TTileSlot): Boolean;

    { worker-side queue access — guarded by FQueueLock }
    function TakeBestIO(out AId: TGeoTileId): Boolean;
    function TakeBestGen(out ABlock: TBlockId; out AEpoch: Integer): Boolean;

    { worker-side result publishing — guarded by FResultLock }
    procedure PushTileLoaded(const AId: TGeoTileId; AModel: TTileModel);
    procedure PushBlockDone(const ABlock: TBlockId; AEpoch: Integer;
                            const ATiles: TTileModelArray);
    procedure PushBlockFailed(const ABlock: TBlockId; AEpoch: Integer;
                              const AError: string);

    { result draining — main thread }
    procedure DrainResults;
    procedure ApplyTileLoaded(AItem: TStreamResultItem);
    procedure ApplyBlockDone(AItem: TStreamResultItem);
    procedure ApplyBlockFailed(AItem: TStreamResultItem);
  public
    { Tunables (metres / seconds) — sensible defaults set in Create }
    UploadRadius:    Double;   { tiles inside -> mounted in CGE }
    NearRadius:      Double;   { isotropic prefetch ring }
    ForwardRadius:   Double;   { directional prefetch lobe radius }
    UnloadRadius:    Double;   { RAM model / pending job released beyond }
    SceneUnloadRadius: Double; { mounted scene removed from CGE beyond —
                                 deliberately large so tiles already in
                                 the scene are not torn down prematurely }
    LookAheadSeconds:Double;   { prefetch horizon }
    LookAheadMin:    Double;
    LookAheadMax:    Double;
    BehindPenalty:   Double;   { priority penalty for tiles behind travel }
    VelocityTau:     Double;   { velocity EMA time constant, s }
    StationarySpeed: Double;   { below this speed -> isotropic only }
    BlockFailCooldownFrames: Integer;
    TileFailCooldownFrames:  Integer; { кадры кулдауна перед ретраем tssFailed-тайла; без него
                                        провалившийся IO-load не повторяется, пока тайл wanted —
                                        вечная дыра в земле до отлёта за UnloadRadius }
    MaxScanTiles:    Integer;  { defensive cap on the per-Pump wanted scan }
    EvictLagFrames:  Integer;  { a tile must be un-wanted for this many
                                 consecutive frames before its RAM model
                                 / pending job is dropped — a hysteresis
                                 gap so a tile flickering across the
                                 keyhole edge is not dropped-and-reread }

    { Режим «геометрия только вдоль пути FIT»: предикат «этот тайл в коридоре?».
      Назначается потоковой картой; keyhole в Pump пропускает всё, для чего он
      вернул False. nil = обычная камерная замочная скважина (полный мир). }
    WantFilter:      TTileWantFilter;

    { ACache must already carry the correct genHash; it is NOT owned.
      AIOWorkers / AGenWorkers default to a small IO pool and a tiny
      generation pool (generation is network-bound; keep it narrow). }
    constructor Create(ACache: TGeoTileCache; const AOrigin: TLatLon;
      ABlockSize: Integer = 0;
      AHaloMeters: Double = 220.0;
      AIOWorkers: Integer = 3; AGenWorkers: Integer = 2);
    destructor Destroy; override;
    { Cancel work immediately, but keep tile models alive until all readers
      have joined. Safe to call again from the destructor. }
    procedure RequestStop;
    { After RequestStop, on a reaper thread: joins CPU workers and persists
      pending results; never mounts or frees Castle scenes / GL objects. }
    procedure JoinStoppedWorkers;

    { Recompute the wanted set, schedule work, drain finished work.
      ACamera is the camera position; ADeltaSeconds the frame time. }
    procedure Pump(const ACamera: TLatLon; ADeltaSeconds: Single);

    { Pop one tile ready to be mounted into CGE. AModel is borrowed —
      the host builds the scene from it, then MUST call MarkUploaded,
      after which the streamer frees the model. Returns False when the
      upload queue is empty. Call in a per-frame bounded loop. }
    function NextUpload(out ATileId: TGeoTileId;
                        out AModel: TTileModel): Boolean;
    procedure MarkUploaded(const ATileId: TGeoTileId);
    { Как MarkUploaded, но НЕ освобождает модель — передаёт владение вызывающему
      (фон-ассемблер: модель живёт в job до монтажа). }
    procedure ReleaseUploadOwnership(const ATileId: TGeoTileId);
    { Поставить смонтированную модель на фон-сохранение (владение уходит сюда). }
    procedure EnqueueSave(const ATileId: TGeoTileId; AModel: TTileModel);
    { Прогресс: ВОРКЕР сообщает фазу блока (потокобезопасно). }
    procedure SetBlockPhase(const ABlock: TBlockId; APhase: TBlockPhase;
      const Stage: string; Completed, Total: Int64);
    { main: стадия и счётчики для блока тайла. False, если тайл не грузится
      (блок готов/не запланирован). }
    function BlockProgressForTile(const AId: TGeoTileId;
      out Rec: TBlockPhaseRec): Boolean;
    function BlockErrorForTile(const AId: TGeoTileId): string;
    function DescribeTile(const AId: TGeoTileId): string;
    { Worker-safe: does not read main-thread tile/block slots. }
    function LastProgressTickForTiles(const Tiles: TGeoTileIdArray): QWord;
    { True, если модель тайла готова (tssReadyInRAM) — сгенерена/загружена и
      ждёт монтажа («готов к показу»). main-поток. }
    function TileReadyToShow(const AId: TGeoTileId): Boolean;

    procedure SetHeightPreviewSource(AFetcher: TTerrariumFetcher;
      AZoom: Integer; AFarZoom: Integer = 0);
    { Источник превью-текстур (.ptex.png по блокам генерации). not owned. }
    procedure SetPrevTexSource(AFetcher: TPrevTexFetcher);
    { Карта эвиктнула сцену тайла мимо штатной очереди (давление памяти):
      убрать слот, чтобы состояние стримера осталось консистентным. }
    procedure NotifySceneEvicted(const AId: TGeoTileId);
    { Сжать радиусы загрузки (upload + префетч) до AMaxM. }
    procedure ClampLoadRadius(AMaxM: Double);

    { Request generation / upload of a single tile (tree-driven). }
    procedure WantTile(const AId: TGeoTileId; APriority: Double;
                       AWithinUpload: Boolean);

    { Запланировать генерацию тайла в кэш БЕЗ монтажа и без удержания модели
      в RAM (режим «весь коридор пути сразу»: карта прогоняет дальние тайлы
      коридора через это, тайл генерируется на диск и тут же освобождается).
      Уже лежащий на диске тайл вызывающий должен отсеять сам (FCache.Has).
      Только ГЛАВНЫЙ поток. }
    procedure PregenTile(const AId: TGeoTileId; APriority: Double);

    { Pop one tile whose CGE scene should be removed and freed. }
    function NextEvict(out ATileId: TGeoTileId): Boolean;

    { Forget all tiles/blocks and cancel pending work; in-flight worker
      results are discarded on arrival (epoch bump). For an origin or
      route change within the SAME genHash. A genHash change needs a
      full destroy/recreate instead. }
    procedure Clear;

    { Internal — invoked by worker threads. }
    function DoOneIOJob: Boolean;
    function DoOneGenJob: Boolean;
    procedure EmitScanClampNote;   { воркер-поток: публикует заметку Pump }
    { Превью-меш земли для по-тайлового LOD B/C (зовётся из MountBatch). }
    function BuildHeightPreview(const AId: TGeoTileId): TTilePreviewData;
    function DoOneShadowJob: Boolean;
    function DoOneSaveJob: Boolean;

    { Ground-shadow mask offload (main thread enqueues / drains)
 EnqueueShadowGen hands the shadow worker a self-contained snapshot to
 rasterise. The finished mask is taken in two steps so the upload stays
 visible in the queue for its whole processing duration (the host swaps
 the bytes into a texture node, then commits): PeekShadowUpload returns
 at most one finished mask (Key + Gen + raw bytes) WITHOUT removing it;
 CommitShadowUpload removes that front entry once the host has applied
 (or skipped) it. HasPendingShadow reports whether a tile still has a
 gen job (queued OR being rasterised — the worker leaves the job in the
 queue until it finishes) or an undelivered/uncommitted upload; the host
 uses it to DEFER evicting a tile whose mask node is still referenced by
 in-flight work. DropTileShadow removes every pending gen job and
 undelivered upload for a tile (a belt-and-suspenders cancel; with the
 defer-on-pending policy it normally finds nothing). All four take
 FShadowLock — they cross the main/worker thread boundary. }
    procedure EnqueueShadowGen(const AJob: TShadowGenJob);
    function  PeekShadowUpload(out AKey: string;
                               out AGen: QWord;
                               out ABytes: TShadowMaskBytes;
                               out ABytesTree: TShadowMaskBytes): Boolean;
    procedure CommitShadowUpload;
    function  HasPendingShadow(const AKey: string): Boolean;
    procedure DropTileShadow(const AKey: string);
    { SH-TRACE diagnostic: current number of undelivered shadow uploads.
      Read under FShadowLock (the worker appends concurrently). }
    function  UploadQueueDepth: Integer;

    property OnGenerateBlock: TBlockGenerator
             read FBlockGen write FBlockGen;
    { Diagnostic log sink — the existing project log mechanism. May be
      written from worker threads; TCallbackLogTarget marshals safely. }
    property LogTarget: TLogTarget read FLog write FLog;
    property Origin: TLatLon read FOrigin;
    property Frame:  Int64   read FFrame;

    { Режим прогрева маршрута: тайлы генерируются для снапа и НЕ монтируются
      (камера далеко), поэтому отложенное «сохранение после монтажа» для них
      не срабатывает никогда. Когда флаг поднят, gen-воркер сохраняет каждый
      сгенерированный тайл в кэш СРАЗУ (FCache.Save потокобезопасен). Флаг —
      простой Boolean, пишется главным потоком, читается воркером; для булева
      признака рваного значения нет, а точность до кадра не важна. }
    { Тайл уже лежит в дисковом кэше? Хостам, монтирующим тайлы через
      ассемблер (DrainAssembled), нужно перед EnqueueSave, чтобы не
      переписывать заново то, что уже сохранено сразу при генерации
      (ждущий тайл). Тонкая обёртка над FCache.Has (потокобезопасен). }
    function AlreadyOnDisk(const ATileId: TGeoTileId): Boolean;
    { Main-thread diagnostic: requested local tiles not handed to the host yet. }
    function PendingVisibleTiles: Integer;

    { Main-thread call: replace the pinned-tile set (see FPinned). Pass an
      empty array to clear it. Pinned tiles are never evicted and their
      pending gen/IO is never cancelled, while every other tile evicts
      normally. The route snapper pins the route's tiles until it has
      harvested them; it MUST clear the set afterwards. }
    procedure SetPinnedTiles(const AIds: array of TGeoTileId);
  end;

implementation

const
  { Minimum spacing (ms) between successive workers BEGINNING a block, so
    their carve phases interleave with the other block's serial phases
    rather than colliding on the cores (see FNextGenStartTick). A lone
    worker, or workers already drifted this far apart, never wait. Tunable. }
  GEN_STAGGER_MS = 5000;

  { Backpressure: максимум ГОТОВЫХ, но ещё не смонтированных блоков в FResults.
    Gen-воркеры не берут новый блок, пока очередь готовых не опустится ниже —
    иначе при burst-загрузке новых тайлов готовые TTileModel (меши+X3D) копятся
    в FResults, и RSS скачет (наблюдался транзиентный пик до ~7.5 ГБ, спадавший
    к ~2.8 ГБ после монтирования). Меньше значение -> ниже пик RAM, но чаще
    воркеры ждут монтирования (main-поток). Пол пика задаётся числом gen-
    воркеров (каждый держит 1 блок в постройке). Tunable. }
  MAX_GEN_RESULTS_PENDING = 3;

type
  TStreamWorker = class(TThread)
  private
    FJob:  TTileStreamer.TStreamJobFunc;
    FWake: TEvent;
  protected
    procedure Execute; override;
  public
    constructor Create(AJob: TTileStreamer.TStreamJobFunc; AWake: TEvent);
  end;

{ Числовой ключ блока для FBlocks/FBlockPhase — тот же биективный приём,
  что и TGeoTileId.ToKey (Zone/North заморожены, BY в старшем dword). }
function BlockKeyOf(const ABlock: TBlockId): Int64; inline;
begin
  Result := (Int64(ABlock.BY) shl 32) or Int64(ABlock.BX);
end;

constructor TStreamWorker.Create(AJob: TTileStreamer.TStreamJobFunc;
  AWake: TEvent);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1291);{$ENDIF}
  inherited Create(True);          { suspended — caller Starts it }
  FreeOnTerminate := False;
  FJob  := AJob;
  FWake := AWake;
end;

procedure TStreamWorker.Execute;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(962);{$ENDIF}
  while not Terminated do
  begin
    { Timed wait: the SetEvent gives low latency, the timeout
      guarantees Terminated is rechecked even if a wake is missed. }
    FWake.WaitFor(250);
    if Terminated then Break;
    { Drain every job currently available before going back to wait. }
    while (not Terminated) and FJob() do
      ;
  end;
end;

destructor TTileStreamer.TTileSlot.Destroy;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1292);{$ENDIF}
  if Model <> nil then
    FreeAndNil(Model);
  inherited Destroy;
end;

destructor TTileStreamer.TStreamResultItem.Destroy;
var
  I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1293);{$ENDIF}
  { Frees only models NOT consumed by the drain (stale-epoch items).
    The drain nils every model it transfers into a slot. }
  if Model <> nil then
    FreeAndNil(Model);
  for I := 0 to High(Tiles) do
    if Tiles[I] <> nil then
      FreeAndNil(Tiles[I]);
  inherited Destroy;
end;

constructor TTileStreamer.Create(ACache: TGeoTileCache;
  const AOrigin: TLatLon; ABlockSize: Integer; AHaloMeters: Double;
  AIOWorkers, AGenWorkers: Integer);
var
  I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1294);{$ENDIF}
  inherited Create;

  FCache  := ACache;
  FOrigin := AOrigin;
  FZone   := ZoneOfLon(AOrigin.Lon);
  FLog    := nil;

  if (FCache <> nil) and (FCache.Grid <> nil) then
    FEdgeMeters := FCache.Grid.EdgeMeters
  else
    FEdgeMeters := GEO_TILE_EDGE_M;
  if FEdgeMeters < 1.0 then
    FEdgeMeters := GEO_TILE_EDGE_M;

  if ABlockSize < 1 then ABlockSize := GEO_BLOCK_SIZE;
  FBlockSize  := ABlockSize;
  if AHaloMeters < 0.0 then AHaloMeters := 0.0;
  FHaloMeters := AHaloMeters;

  { Streaming radii — единый источник GlobalLODConfig (TLODConfig).
    Настроены под гео-тайл GEO_TILE_EDGE_M. }
  UploadRadius      := GlobalLODConfig.StreamUploadM;
  NearRadius        := GlobalLODConfig.StreamNearM;
  ForwardRadius     := GlobalLODConfig.StreamForwardM;
  UnloadRadius      := GlobalLODConfig.StreamUnloadM;
  SceneUnloadRadius := GlobalLODConfig.StreamSceneUnloadM;
  LookAheadSeconds := 18.0;
  LookAheadMin     := 0.0;
  LookAheadMax     := 1800.0;
  BehindPenalty    := 2.0;
  VelocityTau      := 0.8;
  StationarySpeed  := 0.7;
  BlockFailCooldownFrames := 600;
  TileFailCooldownFrames  := 600;  { ~10 s at 60 fps — same cadence as blocks }
  EvictLagFrames          := 90;   { ~1.5 s at 60 fps — long enough to
                                     swallow keyhole-edge flicker }
  MaxScanTiles     := 20000;
  WantFilter       := nil;         { режим route-only ставит его через карту }

  FTiles  := specialize TDictionary<Int64, TTileSlot>.Create;
  FBlocks := specialize TDictionary<Int64, TBlockSlot>.Create;
  FBlockPhase := specialize TDictionary<Int64, TBlockPhaseRec>.Create;
  FPhaseLock  := TCriticalSection.Create;
  FPinned := specialize TDictionary<Int64, Boolean>.Create;

  FQueueLock  := TCriticalSection.Create;
  FGenStartLock := TCriticalSection.Create;
  FNextGenStartTick := 0;
  FPendingIO  := specialize TList<TTileSlot>.Create;
  FPendingGen := specialize TList<TBlockSlot>.Create;
  FEpoch      := 1;

  FResultLock := TCriticalSection.Create;
  FResults    := specialize TQueue<TStreamResultItem>.Create;

  FUploadList := specialize TList<TTileSlot>.Create;
  FEvictQueue := specialize TQueue<TGeoTileId>.Create;

  { auto-reset events — chained wake-up keeps the pool fed }
  FWakeIO  := TEvent.Create(nil, False, False, '');
  FWakeGen := TEvent.Create(nil, False, False, '');
  FShutdown := False;

  FShadowLock  := TCriticalSection.Create;
  FGenQueue    := specialize TList<PShadowGenJob>.Create;
  FUploadQueue := specialize TList<PShadowUpload>.Create;
  FWakeShadow  := TEvent.Create(nil, False, False, '');

  if AIOWorkers  < 1 then AIOWorkers  := 1;
  if AGenWorkers < 1 then AGenWorkers := 1;

  SetLength(FIOWorkers, AIOWorkers);
  for I := 0 to AIOWorkers - 1 do
  begin
    FIOWorkers[I] := TStreamWorker.Create(@DoOneIOJob, FWakeIO);
    FIOWorkers[I].Start;
  end;

  SetLength(FGenWorkers, AGenWorkers);
  for I := 0 to AGenWorkers - 1 do
  begin
    FGenWorkers[I] := TStreamWorker.Create(@DoOneGenJob, FWakeGen);
    FGenWorkers[I].Start;
  end;

  { one dedicated shadow worker — rasterises mask snapshots off the main
    thread; idles on FWakeShadow until EnqueueShadowGen feeds it }
  FShadowWorker := TStreamWorker.Create(@DoOneShadowJob, FWakeShadow);
  FShadowWorker.Start;

  { Фон-сохранение: пишет в кэш смонтированные модели вне критического пути. }
  FWakeSave  := TEvent.Create(nil, False, False, '');
  FSaveQueue := specialize TQueue<TSaveJob>.Create;
  FSaveLock  := TCriticalSection.Create;
  FSaveWorker := TStreamWorker.Create(@DoOneSaveJob, FWakeSave);
  FSaveWorker.Start;

  FHasPrev := False;
  FFrame   := 0;
end;

procedure TTileStreamer.RequestStop;
var I: Integer;
begin
  FShutdown := True;

  for I := 0 to High(FIOWorkers) do
    if FIOWorkers[I] <> nil then FIOWorkers[I].Terminate;
  for I := 0 to High(FGenWorkers) do
    if FGenWorkers[I] <> nil then FGenWorkers[I].Terminate;
  if FShadowWorker <> nil then FShadowWorker.Terminate;
  if FSaveWorker <> nil then FSaveWorker.Terminate;

  { Nudge everyone; the 250 ms timeout covers any missed wake. }
  if FWakeIO     <> nil then FWakeIO.SetEvent;
  if FWakeGen    <> nil then FWakeGen.SetEvent;
  if FWakeShadow <> nil then FWakeShadow.SetEvent;
  if FWakeSave <> nil then FWakeSave.SetEvent;

end;

procedure TTileStreamer.JoinStoppedWorkers;
var I,DI:Integer;SJob:TSaveJob;DItem:TStreamResultItem;Slot:TTileSlot;
begin
  for I:=0 to High(FIOWorkers)do if FIOWorkers[I]<>nil then FIOWorkers[I].WaitFor;
  for I:=0 to High(FGenWorkers)do if FGenWorkers[I]<>nil then FGenWorkers[I].WaitFor;
  if FShadowWorker<>nil then FShadowWorker.WaitFor;
  if FSaveWorker<>nil then FSaveWorker.WaitFor;
  if FSaveQueue <> nil then
    while FSaveQueue.Count > 0 do
    begin
      SJob := FSaveQueue.Dequeue;
      if SJob.Model <> nil then
      begin
        try
          FCache.Save(SJob.TileId, SJob.Model);
        except
        end;
        SJob.Model.Free;
      end;
    end;
  if FResults <> nil then
    while FResults.Count > 0 do
    begin
      DItem := FResults.Dequeue;
      if DItem.Kind = srkBlockDone then
        for DI := 0 to High(DItem.Tiles) do
          if DItem.Tiles[DI] <> nil then
            try
              FCache.Save(DItem.Tiles[DI].TileId, DItem.Tiles[DI]);
            except
            end;
      DItem.Free;   { модели освободит его деструктор }
    end;
  if FTiles<>nil then
    for Slot in FTiles.Values do
      if Slot.NeedsSave and(Slot.Model<>nil)then begin
        try FCache.Save(Slot.Id,Slot.Model);except end;
        Slot.NeedsSave:=False;
      end;
end;

destructor TTileStreamer.Destroy;
var
  I: Integer;
  Slot:  TTileSlot;
  BSlot: TBlockSlot;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1295);{$ENDIF}
  { Signal shutdown — also the generator cancel flag. }
  RequestStop;
  JoinStoppedWorkers;

  for I := 0 to High(FIOWorkers) do
    if FIOWorkers[I] <> nil then
    begin
      FIOWorkers[I].WaitFor;
      FIOWorkers[I].Free;
    end;
  for I := 0 to High(FGenWorkers) do
    if FGenWorkers[I] <> nil then
    begin
      FGenWorkers[I].WaitFor;
      FGenWorkers[I].Free;
    end;
  if FShadowWorker <> nil then
  begin
    FShadowWorker.WaitFor;
    FShadowWorker.Free;
  end;
  if FSaveWorker <> nil then
  begin
    FSaveWorker.WaitFor;
    FSaveWorker.Free;
  end;

  { No workers left — safe to tear down everything else. }
  { Оставшиеся в сейв-очереди модели: воркер остановлен — ДОЗАПИСЫВАЕМ
    синхронно (несколько тайлов * десятки мс — приемлемая цена выхода),
    иначе последние сгенерированные тайлы теряются и блоки
    перегенерируются при следующем запуске. Ошибки записи глотаем —
    выходу они помешать не должны. }
  if FSaveQueue <> nil then FreeAndNil(FSaveQueue);
  if FSaveLock  <> nil then FreeAndNil(FSaveLock);
  if FWakeSave  <> nil then FreeAndNil(FWakeSave);
  FResults.Free;

  if FTiles <> nil then
    for Slot in FTiles.Values do
    begin
      Slot.Free;
    end;
  FTiles.Free;

  if FBlocks <> nil then
    for BSlot in FBlocks.Values do
      BSlot.Free;
  FBlocks.Free;
  FBlockPhase.Free;
  FPhaseLock.Free;

  FPendingIO.Free;
  FPendingGen.Free;
  FUploadList.Free;
  FEvictQueue.Free;
  FPinned.Free;

  FQueueLock.Free;
  FGenStartLock.Free;
  FResultLock.Free;
  FWakeIO.Free;
  FWakeGen.Free;
  FWakeShadow.Free;

  { workers are gone — nothing touches the shadow queues now; dispose any
    leftover heap jobs/uploads (Dispose finalises their managed fields) }
  if FGenQueue <> nil then
  begin
    for I := 0 to FGenQueue.Count - 1 do Dispose(FGenQueue[I]);
    FGenQueue.Free;
  end;
  if FUploadQueue <> nil then
  begin
    for I := 0 to FUploadQueue.Count - 1 do Dispose(FUploadQueue[I]);
    FUploadQueue.Free;
  end;
  FShadowLock.Free;

  inherited Destroy;
end;

procedure TTileStreamer.Log(const AMsg: string);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(963);{$ENDIF}
  { MUST be called from worker threads only (DoOneIOJob / DoOneGenJob).
    TCallbackLogTarget.Write holds its internal lock across a blocking
    TThread.Synchronize; if the MAIN thread also called Write it could
    deadlock against a worker mid-Synchronize. The whole project keeps
    to this rule — only background code writes to the log target. }
  if FLog <> nil then
    FLog.Write(llInfo, AMsg);
end;

procedure TTileStreamer.EmitScanClampNote;
var
  Note, LoadNote: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1790);{$ENDIF}
  { Воркер-поток. Забираем заметки под тем же локом, под которым Pump их
    кладёт; Log — уже вне лока. }
  FQueueLock.Enter;
  try
    Note := FScanClampNote;
    FScanClampNote := '';
    LoadNote := FLoadClampNote;
    FLoadClampNote := '';
  finally
    FQueueLock.Leave;
  end;
  if Note <> '' then
    Log(Note);
  if LoadNote <> '' then
    Log(LoadNote);
end;

function TTileStreamer.DoOneIOJob: Boolean;
var
  Id:    TGeoTileId;
  Model: TTileModel;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(964);{$ENDIF}
  EmitScanClampNote;
  Result := False;
  if not TakeBestIO(Id) then Exit;
  Result := True;

  Model := nil;
  try
    if not FCache.TryLoad(Id, Model) then
      Model := nil;
  except
    Model := nil;
  end;
  { Per-tile success log SPAM-SILENCED (fires constantly while streaming);
    keep only the rare failure line. }
  if Model = nil then
    Log('tile ' + Id.ToString + ' cache load FAILED');
  PushTileLoaded(Id, Model);
end;

function TTileStreamer.DoOneGenJob: Boolean;
var
  Blk:   TBlockId;
  Epoch: Integer;
  Halo:  TLatLonBox;
  Res:   TBlockGenResult;
  I:     Integer;
  PrevIds: TGeoTileIdArray;       { id тайлов пачки для WriteBatch блок-PNG }
  Slot, Now64: QWord;             { gen-start stagger reservation }
  {$IFDEF TILE_MEM_PROFILE}HS0, HS1: TFPCHeapStatus;{$ENDIF}
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(965);{$ENDIF}
  EmitScanClampNote;
  Result := False;
  if not Assigned(FBlockGen) then Exit;
  { Backpressure: пока готовые блоки не смонтированы main-потоком (FResults),
    не берём новый — ограничивает пик RAM при burst-генерации. Воркер повторит
    сам по таймауту FWake.WaitFor(250) либо по FWakeGen из DrainResults. Чтение
    FResults.Count без блокировки намеренно: для эвристики staleness ±1 не важен,
    а чтение 4-байтного счётчика на x86 атомарно (без рваного значения). }
  if FResults.Count >= MAX_GEN_RESULTS_PENDING then Exit;
  if not TakeBestGen(Blk, Epoch) then Exit;
  Result := True;

  { Stagger block STARTS so two carves don't land on the cores together.
 Reserve a monotonic start slot ≥ GEN_STAGGER_MS after the previous one;
 wait for it (the OTHER worker keeps building meanwhile). A lone worker,
 or workers already that far apart, get Slot = now and never wait. }
  FGenStartLock.Enter;
  try
    Now64 := GetTickCount64;
    if Now64 >= FNextGenStartTick then
      Slot := Now64
    else
      Slot := FNextGenStartTick;
    FNextGenStartTick := Slot + GEN_STAGGER_MS;
  finally
    FGenStartLock.Leave;
  end;
  while (not FShutdown) and (GetTickCount64 < Slot) do
    Sleep(50);
  if FShutdown then Exit;

  Halo := BlockHaloBox(Blk, FCache.Grid, FHaloMeters, FBlockSize);

  Log(Format('block %s generating... [gen tid=%d]',
      [Blk.ToString, Int64(GetCurrentThreadID)]));
  {$IFDEF TILE_MEM_PROFILE}HS0 := GetFPCHeapStatus;{$ENDIF}

  Res.Success := False;
  Res.Error   := '';
  SetLength(Res.Tiles, 0);
  try
    Res := FBlockGen(Blk, Halo, FOrigin, @FShutdown);
  except
    on E: Exception do
    begin
      Res.Success := False;
      Res.Error   := E.ClassName + ': ' + E.Message;
      SetLength(Res.Tiles, 0);
    end;
  end;
  {$IFDEF TILE_MEM_PROFILE}
  HS1 := GetFPCHeapStatus;
  Log(Format('[gen-heap tid=%d] reserved %.0f / used %.0f / held(reserved-used) %.0f MB'
    + ' | прирост reserved за блок +%.0f MB  (per-thread куча ВОРКЕРА — главный поток её НЕ видит)',
    [Int64(GetCurrentThreadID),
     HS1.CurrHeapSize/(1024*1024), HS1.CurrHeapUsed/(1024*1024),
     (HS1.CurrHeapSize-HS1.CurrHeapUsed)/(1024*1024),
     (Int64(HS1.CurrHeapSize)-Int64(HS0.CurrHeapSize))/(1024*1024)]));
  {$ENDIF}

  if FShutdown then
  begin
    for I := 0 to High(Res.Tiles) do FreeAndNil(Res.Tiles[I]);
    for I := 0 to High(Res.Previews) do FreeAndNil(Res.Previews[I]);
    Exit; { A cancelled build is not a failed tile. }
  end;

  if Res.Success then
  begin
    Log(Format('block %s generated — %d tiles [gen tid=%d]',
        [Blk.ToString, Length(Res.Tiles), Int64(GetCurrentThreadID)]));
    { Сохранение в кэш решается в ApplyBlockDone (главный поток) per-tile
      по фактическому признаку монтажа: тайл в радиусе загрузки едет на
      монтаж и сохраняется после него; тайл, который ляжет ЖДАТЬ (дальний
      префетч, прогревной пин), сохраняется там же сразу. Здесь, в
      gen-воркере, ничего не пишем — состояние слота отсюда недоступно. }

    { Превью-текстура пачки: ОДИН .ptex.png на весь блок (вместо per-tile
      .prev). Собираем id тайлов и пишем через фетчер ДО live-update — он
      читает .Tex превьюшек, владение НЕ забирает. Высоты даёт terrarium (GetSuperHeights)
      при чтении. }
    if FPrevTex <> nil then
    begin
      SetLength(PrevIds, Length(Res.Tiles));
      for I := 0 to High(Res.Tiles) do
        if Res.Tiles[I] <> nil then
          PrevIds[I] := Res.Tiles[I].TileId
        else
          PrevIds[I] := TGeoTileId.Make(0, True, 0, 0);  { заглушка вне блока }
      try
        FPrevTex.WriteBatch(Blk, PrevIds, Res.Previews);
      except
        on E: Exception do
          Log('TileStreamer: block prev-tex write failed: ' + E.Message);
      end;
    end;

    { Текстуры превью уже записаны в .ptex.png (WriteBatch выше) — освобождаем превью-данные. }
    for I := 0 to High(Res.Previews) do
      FreeAndNil(Res.Previews[I]);
    PushBlockDone(Blk, Epoch, Res.Tiles);
  end
  else
  begin
    for I := 0 to High(Res.Previews) do
      FreeAndNil(Res.Previews[I]);
    Log('block ' + Blk.ToString + ' generation FAILED: ' + Res.Error);
    PushBlockFailed(Blk, Epoch, Res.Error);
  end;
end;

function TTileStreamer.TakeBestIO(out AId: TGeoTileId): Boolean;
var
  I, Best: Integer;
  Slot: TTileSlot;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(966);{$ENDIF}
  Result := False;
  FQueueLock.Enter;
  try
    if FPendingIO.Count = 0 then Exit;
    Best := 0;
    for I := 1 to FPendingIO.Count - 1 do
      if FPendingIO[I].Priority < FPendingIO[Best].Priority then
        Best := I;
    Slot := FPendingIO[Best];
    FPendingIO.Delete(Best);
    AId := Slot.Id;
    Result := True;
    { Chain-wake a sibling if work remains. }
    if FPendingIO.Count > 0 then
      FWakeIO.SetEvent;
  finally
    FQueueLock.Leave;
  end;
end;

function TTileStreamer.TakeBestGen(out ABlock: TBlockId;
  out AEpoch: Integer): Boolean;
var
  I, Best: Integer;
  BSlot: TBlockSlot;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(967);{$ENDIF}
  Result := False;
  FQueueLock.Enter;
  try
    if FPendingGen.Count = 0 then Exit;
    Best := 0;
    for I := 1 to FPendingGen.Count - 1 do
      if FPendingGen[I].Priority < FPendingGen[Best].Priority then
        Best := I;
    BSlot := FPendingGen[Best];
    FPendingGen.Delete(Best);
    ABlock := BSlot.Id;
    AEpoch := FEpoch;
    Result := True;
    if FPendingGen.Count > 0 then
      FWakeGen.SetEvent;
  finally
    FQueueLock.Leave;
  end;
end;

procedure TTileStreamer.PushTileLoaded(const AId: TGeoTileId;
  AModel: TTileModel);
var
  Item: TStreamResultItem;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(968);{$ENDIF}
  Item := TStreamResultItem.Create;
  Item.Kind   := srkTileLoaded;
  Item.TileId := AId;
  Item.Model  := AModel;
  FResultLock.Enter;
  try
    Item.Epoch := FEpoch;
    FResults.Enqueue(Item);
  finally
    FResultLock.Leave;
  end;
end;

procedure TTileStreamer.PushBlockDone(const ABlock: TBlockId;
  AEpoch: Integer; const ATiles: TTileModelArray);
var
  Item: TStreamResultItem;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(969);{$ENDIF}
  Item := TStreamResultItem.Create;
  Item.Kind  := srkBlockDone;
  Item.Block := ABlock;
  Item.Epoch := AEpoch;
  Item.Tiles := ATiles;        { ownership of the array + models moves in }
  FPhaseLock.Enter;
  try FBlockPhase.Remove(BlockKeyOf(ABlock)); finally FPhaseLock.Leave; end;
  FResultLock.Enter;
  try
    FResults.Enqueue(Item);
  finally
    FResultLock.Leave;
  end;
end;

procedure TTileStreamer.PushBlockFailed(const ABlock: TBlockId;
  AEpoch: Integer; const AError: string);
var
  Item: TStreamResultItem;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(970);{$ENDIF}
  Item := TStreamResultItem.Create;
  Item.Kind  := srkBlockFailed;
  Item.Block := ABlock;
  Item.Epoch := AEpoch;
  Item.Error := AError;
  FPhaseLock.Enter;
  try FBlockPhase.Remove(BlockKeyOf(ABlock)); finally FPhaseLock.Leave; end;
  FResultLock.Enter;
  try
    FResults.Enqueue(Item);
  finally
    FResultLock.Leave;
  end;
end;

function TTileStreamer.DoOneSaveJob: Boolean;
var Job: TSaveJob; Got: Boolean;
begin
  Got := False;
  FSaveLock.Enter;
  try
    if FSaveQueue.Count > 0 then begin Job := FSaveQueue.Dequeue; Got := True; end;
  finally
    FSaveLock.Leave;
  end;
  Result := Got;
  if not Got then Exit;
  if Job.Model <> nil then
  begin
    try
      FCache.Save(Job.TileId, Job.Model);
    except
      on E: Exception do
        Log('TileStreamer: async save failed for ' + Job.TileId.ToString
            + ': ' + E.Message);
    end;
    Job.Model.Free;      { владение было у очереди — освобождаем после записи }
  end;
end;

procedure TTileStreamer.EnqueueSave(const ATileId: TGeoTileId; AModel: TTileModel);
var Job: TSaveJob;
begin
  if AModel = nil then Exit;
  Job.TileId := ATileId;
  Job.Model  := AModel;   { владение переходит в сейв-очередь }
  FSaveLock.Enter;
  try FSaveQueue.Enqueue(Job); finally FSaveLock.Leave; end;
  if FWakeSave <> nil then FWakeSave.SetEvent;
end;

procedure TTileStreamer.SetBlockPhase(const ABlock: TBlockId; APhase: TBlockPhase;
  const Stage: string; Completed, Total: Int64);
var Rec: TBlockPhaseRec; Key: Int64;
begin
  Key := BlockKeyOf(ABlock);
  FPhaseLock.Enter;
  try
    if FBlockPhase.TryGetValue(Key, Rec) and (Rec.Phase = APhase)
      and (Rec.Stage = Stage) and (Rec.Total = Total)
      and (Completed <= Rec.Completed) then Exit;
    Rec.Phase := APhase; Rec.Stage := Stage;
    Rec.Completed := Completed; Rec.Total := Total;
    Rec.Tick := GetTickCount64;
    FBlockPhase.AddOrSetValue(Key, Rec);
  finally FPhaseLock.Leave end;
end;

function TTileStreamer.LastProgressTickForTiles(const Tiles: TGeoTileIdArray): QWord;
var Id: TGeoTileId; Rec: TBlockPhaseRec;
begin
  Result := 0;
  FPhaseLock.Enter;
  try
    for Id in Tiles do
      if FBlockPhase.TryGetValue(BlockKeyOf(BlockOf(Id, FBlockSize)), Rec) then
        if Rec.Tick > Result then Result := Rec.Tick;
  finally FPhaseLock.Leave end;
end;

function TTileStreamer.TileReadyToShow(const AId: TGeoTileId): Boolean;
var Slot: TTileSlot;
begin
  { FTiles — только main; без лока. }
  Result := FTiles.TryGetValue(AId.ToKey, Slot)
            and (Slot.State = tssReadyInRAM);
end;

function TTileStreamer.BlockErrorForTile(const AId: TGeoTileId): string;
var Slot: TBlockSlot;
begin
  Result:='';
  if FBlocks.TryGetValue(BlockKeyOf(BlockOf(AId,FBlockSize)),Slot) then
    Result:=Slot.LastError;
end;

function TTileStreamer.BlockProgressForTile(const AId: TGeoTileId;
  out Rec: TBlockPhaseRec): Boolean;
var BKey: Int64; BSlot: TBlockSlot;
begin
  Result := False; Rec := Default(TBlockPhaseRec);
  BKey := BlockKeyOf(BlockOf(AId, FBlockSize));
  { UI-only slots: worker watchdog uses LastProgressTickForTiles instead. }
  if not FBlocks.TryGetValue(BKey, BSlot) then Exit;
  if BSlot.State = bgsDone then
  begin
    { Geometry has finished; mounting/caching may still be pending. }
    Rec.Phase := bpGeom;
    Rec.Stage := 'Preparing tile';
    Exit(True);
  end;
  if BSlot.State <> bgsQueued then Exit;
  FPhaseLock.Enter;
  try Result := FBlockPhase.TryGetValue(BKey, Rec);
  finally FPhaseLock.Leave end;
end;

procedure TTileStreamer.SetHeightPreviewSource(AFetcher: TTerrariumFetcher;
  AZoom: Integer; AFarZoom: Integer);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1791);{$ENDIF}
  FHmFetcher := AFetcher;
  FHmZoom    := AZoom;
  if AFarZoom > 0 then FFarZoom := AFarZoom else FFarZoom := AZoom;
end;

procedure TTileStreamer.SetPrevTexSource(AFetcher: TPrevTexFetcher);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1792);{$ENDIF}
  FPrevTex := AFetcher;
end;

{ Превью-меш земли для по-тайлового LOD B/C (зовётся из MountBatch): высоты
  z13 из terrarium (фоллбэк на грубый z10), текстура из блочного .ptex.png.
  nil -> вызывающий оставляет композит/заглушку. }
function TTileStreamer.BuildHeightPreview(
  const AId: TGeoTileId): TTilePreviewData;
var
  Box: TLatLonBox;
  Stitched: THeightmap;
  Tex: TBytes;

  { Запас fetch-бокса: 2 texel'а terrarium данного зума (+1 м страховки).
    Билинейной выборке краевых точек геотайла нужен texel ЗА границей бокса;
    впритык-сшитая карта его не имела — SampleClamped дублировал крайний
    столбец, у соседнего тайла тот же texel был настоящим, и на каждом
    склоне вдоль шва вставала ступень (соседи «не стыкуются», хотя высоты —
    из одного менеджера). С запасом краевые сэмплы становятся внутренними:
    оба соседа читают ОДНИ texel'ы с одними весами — высоты шва совпадают
    побитно. Сам семплинг по-прежнему идёт по точному TileBox. }
  function TexelPadM(AZ: Integer): Double;
  begin
    Result := 2.0 * (2.0 * Pi * EARTH_RADIUS_M)
              * Cos(Box.Center.Lat * DEG_TO_RAD)
              / (Int64(256) shl AZ) + 1.0;
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1794);{$ENDIF}
  Result := nil;
  if FHmFetcher = nil then Exit;
  Box := FCache.Grid.TileBox(AId);
  if FShutdown then Exit;

  { Shared provider: decoded tiles are cached and deduped across previews
    and blocks, so the preview flood at startup no longer re-fetches the
    same terrarium tiles. GetRegion returns a finished, owned heightmap;
    nil -> network unavailable -> caller keeps the stub. }
  Stitched := FHmFetcher.GetRegion(Box.ExpandMeters(TexelPadM(FHmZoom)),
    FHmZoom);
  if Stitched = nil then
  begin
    { z13 не прогрелся/упал -> падаем на грубый z10: его PNG уже тянут суперы
      (19.6 км на тайл) и почти всегда в кэше, поэтому превью-меш B/C строится,
      а не пропадает. Чуть грубее высоты — приемлемо для превью.
      ВАЖНО: z10-превью рядом с z13-соседом даёт вечную ступень (у превью,
      задевших дыру terrarium, z13 не появится никогда). }
    Stitched := FHmFetcher.GetRegion(Box.ExpandMeters(TexelPadM(FFarZoom)),
      FFarZoom);
  end;
  if Stitched = nil then Exit;

  try
    { Диагностика швов через FLog.Write здесь УДАЛЕНА: BuildHeightPreview
      зовётся с MAIN-потока (MountBatch / EnqueueAssembleBatch), а
      TCallbackLogTarget.Write держит внутренний лок поперёк блокирующего
      Synchronize — запись с main могла встать в дедлок против воркера
      mid-Synchronize (см. контракт TTileStreamer.Log). Потокобезопасного
      main-пути записи в FLog в этом юните нет. }
    Result := BuildTilePreview(Stitched, Box, FOrigin.Lat, nil);   { высоты, без текстуры }
    { Наложить превью-текстуру тайла из блок-PNG фетчера (если блок сгенерён).
      Текстура живёт в блочном .ptex.png; высоты пересчитываются из terrarium при каждом чтении. }
    if (Result <> nil) and (FPrevTex <> nil) then
    begin
      Tex := FPrevTex.GetTileTexture(AId);
      if Length(Tex) = (GEO_TILE_EDGE_PX * PREVIEW_TEX_PER_HPX) * (GEO_TILE_EDGE_PX * PREVIEW_TEX_PER_HPX) * 3 then
      begin
        Result.TexPx := (GEO_TILE_EDGE_PX * PREVIEW_TEX_PER_HPX);
        SetLength(Result.Tex, Length(Tex));
        Move(Tex[0], Result.Tex[0], Length(Tex));
      end;
    end;
  finally
    Stitched.Free;
  end;
end;

procedure TTileStreamer.NotifySceneEvicted(const AId: TGeoTileId);
var
  Key: Int64;
  Slot: TTileSlot;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1795);{$ENDIF}
  Key := AId.ToKey;
  if not FTiles.TryGetValue(Key, Slot) then Exit;
  if Slot.State <> tssUploaded then Exit;
  FTiles.Remove(Key);
  Slot.Free;
end;

procedure TTileStreamer.ClampLoadRadius(AMaxM: Double);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1797);{$ENDIF}
  if AMaxM < 1000 then AMaxM := 1000;
  if (FLoadClampM = 0) or (AMaxM < FLoadClampM) then
    FLoadClampM := AMaxM;
end;

procedure TTileStreamer.EnqueueIO(ASlot: TTileSlot);
var
  AlreadyQueued: Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(971);{$ENDIF}
  FQueueLock.Enter;
  try
    { Guard against a double enqueue. The caller already checked the
      slot state and FCache.Has, but a slot can still be sitting in the
      pending-IO queue while its state has briefly moved on (e.g. a
      cancelled-then-rewanted slot, or a race between Pump and a worker
      taking the job). Adding it twice would read the same tile from
      disk twice — exactly the repeated-read pattern seen in the logs.
      One slot — at most one queue entry. }
    AlreadyQueued := FPendingIO.IndexOf(ASlot) >= 0;
    if not AlreadyQueued then
    begin
      ASlot.Priority := ASlot.DesiredPriority;
      FPendingIO.Add(ASlot);
    end;
  finally
    FQueueLock.Leave;
  end;
  ASlot.State := tssQueuedIO;
  if not AlreadyQueued then
    FWakeIO.SetEvent;
end;

procedure TTileStreamer.EnqueueGen(ABlock: TBlockSlot);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(972);{$ENDIF}
  FQueueLock.Enter;
  try
    ABlock.Priority := ABlock.DesiredPriority;
    FPendingGen.Add(ABlock);
  finally
    FQueueLock.Leave;
  end;
  ABlock.State := bgsQueued;
  FWakeGen.SetEvent;
end;

function TTileStreamer.RemoveFromPendingIO(ASlot: TTileSlot): Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(973);{$ENDIF}
  FQueueLock.Enter;
  try
    Result := FPendingIO.Remove(ASlot) >= 0;
  finally
    FQueueLock.Leave;
  end;
end;

procedure TTileStreamer.ScheduleBlockFor(const AId: TGeoTileId;
  ASlot: TTileSlot; APriority: Double);
var
  Blk:   TBlockId;
  BKey:  Int64;
  BSlot: TBlockSlot;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(974);{$ENDIF}
  Blk  := BlockOf(AId, FBlockSize);
  BKey := BlockKeyOf(Blk);
  if not FBlocks.TryGetValue(BKey, BSlot) then
  begin
    BSlot := TBlockSlot.Create;
    BSlot.Id    := Blk;
    BSlot.State := bgsIdle;
    BSlot.RetryFrame := 0;
    BSlot.LastTouchFrame := 0;
    FBlocks.Add(BKey, BSlot);
  end;

  { Per-frame minimum priority across the block's wanted tiles. }
  if BSlot.LastTouchFrame <> FFrame then
  begin
    BSlot.LastTouchFrame  := FFrame;
    BSlot.DesiredPriority := APriority;
  end
  else if APriority < BSlot.DesiredPriority then
    BSlot.DesiredPriority := APriority;

  { Keep the tile retryable until a job actually exists. Marking it as
    waiting during cooldown strands it forever: WantTile does not revisit
    tssWaitingBlock and no worker will produce a result for it. }
  if (BSlot.State = bgsFailed) and (FFrame < BSlot.RetryFrame) then
  begin
    ASlot.State := tssFailed;
    ASlot.RetryFrame := BSlot.RetryFrame;
    Exit;
  end;
  ASlot.State := tssWaitingBlock;

  case BSlot.State of
    bgsIdle:
      EnqueueGen(BSlot);
    bgsFailed:
      if FFrame >= BSlot.RetryFrame then
        EnqueueGen(BSlot);
    bgsDone:
      { File existence said miss yet the block is "done" — the file was
        lost externally. Regenerate the block. }
      EnqueueGen(BSlot);
    { bgsQueued: already pending or generating — nothing to do. }
  end;
end;

procedure TTileStreamer.RequestBlockGen(const AId: TGeoTileId;
  APriority: Double);
var
  Blk:   TBlockId;
  BKey:  Int64;
  BSlot: TBlockSlot;
begin
  { Как ScheduleBlockFor, но БЕЗ tile-slot: планируем ТОЛЬКО генерацию блока
    (режим «весь коридор пути сразу»). Тайл-слот не создаётся, поэтому по
    готовности блока ApplyBlockDone не найдёт для этого тайла ждущего слота
    и сохранит его в кэш, тут же освободив (ветка «тайл не нужен стримингу»)
    — коридор печётся на диск без удержания моделей в RAM. }
  Blk  := BlockOf(AId, FBlockSize);
  BKey := BlockKeyOf(Blk);
  if not FBlocks.TryGetValue(BKey, BSlot) then
  begin
    BSlot := TBlockSlot.Create;
    BSlot.Id    := Blk;
    BSlot.State := bgsIdle;
    BSlot.RetryFrame := 0;
    BSlot.LastTouchFrame := 0;
    FBlocks.Add(BKey, BSlot);
  end;

  if BSlot.LastTouchFrame <> FFrame then
  begin
    BSlot.LastTouchFrame  := FFrame;
    BSlot.DesiredPriority := APriority;
  end
  else if APriority < BSlot.DesiredPriority then
    BSlot.DesiredPriority := APriority;

  case BSlot.State of
    bgsIdle:
      EnqueueGen(BSlot);
    bgsFailed:
      if FFrame >= BSlot.RetryFrame then
        EnqueueGen(BSlot);
    { bgsDone: блок уже сгенерён В ЭТОЙ сессии — не перегенерируем (в отличие
      от ScheduleBlockFor: тут вызывающий уже отсеял тайлы, лежащие на диске,
      через FCache.Has, значит bgsDone = свежая генерация, файл на месте).
      bgsQueued: уже в очереди/строится — ничего. }
  end;
end;

procedure TTileStreamer.PregenTile(const AId: TGeoTileId; APriority: Double);
begin
  { Только главный поток (как Pump). Планируем генерацию блока тайла на диск
    без tile-slot и без монтажа. Уже лежащий на диске тайл вызывающий обязан
    отсеять сам (FCache.Has) — иначе зря перечитаем/перегенерируем. }
  RequestBlockGen(AId, APriority);
end;

procedure TTileStreamer.WantTile(const AId: TGeoTileId;
  APriority: Double; AWithinUpload: Boolean);
var
  Key:  Int64;
  Slot: TTileSlot;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(975);{$ENDIF}
  Key := AId.ToKey;
  if not FTiles.TryGetValue(Key, Slot) then
  begin
    Slot := TTileSlot.Create;
    Slot.Id    := AId;
    Slot.State := tssUnknown;
    Slot.Model := nil;
    Slot.QueuedForUpload := False;
    Slot.RetryFrame := 0;
    FTiles.Add(Key, Slot);
  end;

  Slot.LastWantedFrame := FFrame;
  Slot.WithinUpload    := AWithinUpload;
  Slot.DesiredPriority := APriority;

  { Дальнее превью даёт дерево (запрос суперов через хост-колбэки), а НЕ по-тайловый запрос здесь.
    Кэшированные вне upload-радиуса тайлы покрывает супер дерева. }

  case Slot.State of
    tssUnknown:
      if FCache.Has(AId) then
        EnqueueIO(Slot)
      else
        ScheduleBlockFor(AId, Slot, APriority);
    tssFailed:
      { Раньше провалившийся тайл (Has() сказал «файл есть», а load
        упал — битый/обрезанный файл, гонка с записью) застревал в
        tssFailed НАВСЕГДА, пока оставался wanted: Pump убирает его
        только за UnloadRadius. Видимый эффект — «дыра», в которой
        стриминг «не идёт дальше». Теперь — ретрай с кулдауном,
        зеркально блокам (ScheduleBlockFor/RetryFrame). }
      if FFrame >= Slot.RetryFrame then
      begin
        if FCache.Has(AId) then
          EnqueueIO(Slot)
        else
          ScheduleBlockFor(AId, Slot, APriority);
      end;
    { tssQueuedIO / tssWaitingBlock: already scheduled (DesiredPriority
      updated above; the rescore pass propagates it to the queue).
      tssReadyInRAM / tssUploaded: handled in Pump. }
  end;
end;

procedure TTileStreamer.ApplyTileLoaded(AItem: TStreamResultItem);
var
  Slot: TTileSlot;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(976);{$ENDIF}
  if not FTiles.TryGetValue(AItem.TileId.ToKey, Slot) then
    Exit;   { tile forgotten meanwhile — destructor frees the model }

  if AItem.Model <> nil then
  begin
    if Slot.Model <> nil then
      FreeAndNil(Slot.Model);
    Slot.Model  := AItem.Model;
    AItem.Model := nil;          { ownership transferred to the slot }
    Slot.State  := tssReadyInRAM;
    Slot.NeedsSave := False;     { модель ПРОЧИТАНА с диска — копия уже там }
  end
  else
  begin
    { Has() had said the file existed but the load failed. }
    Slot.State      := tssFailed;
    Slot.RetryFrame := FFrame + TileFailCooldownFrames;
  end;
end;

function TTileStreamer.DescribeTile(const AId: TGeoTileId): string;
var Slot: TTileSlot;
begin
  if not FTiles.TryGetValue(AId.ToKey, Slot) then Exit('not requested');
  Result:=Format('state=%d wanted=%s upload=%s queued=%s model=%s',
    [Ord(Slot.State),BoolToStr(Slot.LastWantedFrame=FFrame,True),
     BoolToStr(Slot.WithinUpload,True),BoolToStr(Slot.QueuedForUpload,True),
     BoolToStr(Slot.Model<>nil,True)]);
end;

procedure TTileStreamer.ApplyBlockDone(AItem: TStreamResultItem);
var
  BSlot: TBlockSlot;
  Slot:  TTileSlot;
  I:     Integer;
  M:     TTileModel;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(977);{$ENDIF}
  if FBlocks.TryGetValue(BlockKeyOf(AItem.Block), BSlot) then
  begin
    BSlot.State := bgsDone;
    BSlot.LastError := '';
  end;

  for I := 0 to High(AItem.Tiles) do
  begin
    M := AItem.Tiles[I];
    if M = nil then Continue;
    if FTiles.TryGetValue(M.TileId.ToKey, Slot)
       and (Slot.State = tssWaitingBlock) then
    begin
      Slot.Model     := M;
      Slot.State     := tssReadyInRAM;
      { Будет ли тайл смонтирован СРАЗУ? Монтаж происходит только для тайла
        в радиусе загрузки (Pump: tssReadyInRAM + WantedNow + WithinUpload).
        WithinUpload проставлен последним WantTile этого кадра.
          • В радиусе → смонтируется скоро → сохранение отложим на после
            монтажа (NeedsSave=True): модель сначала едет в сцену, тайл
            показывается быстрее.
          • НЕ в радиусе (прогревной пин, дальний префетч) → тайл ляжет
            ЖДАТЬ, и отложенное «сохранение после монтажа» может не
            наступить вовсе → пишем в кэш СРАЗУ (async), NeedsSave=False.
        Это заменяет глобальный флаг прогрева точным per-tile признаком —
        работает и вне прогрева. }
      if Slot.WithinUpload then
        Slot.NeedsSave := True    { смонтируется — сохраним после монтажа }
      else
      begin
        { Ляжет ждать — сохраняем СРАЗУ, но владение НЕ отдаём: модель
          остаётся в слоте (её ещё могут смонтировать/эвиктнуть). Пишем
          синхронно на главном потоке — FCache.Save потокобезопасен;
          таких тайлов в кадре единицы, а альтернатива (потеря →
          перегенерация целого блока) заметно дороже. Метим NeedsSave=
          False: файл уже на диске, повторно писать не нужно. }
        try
          if FCache <> nil then FCache.Save(M.TileId, M);
        except
          on E: Exception do
            Log('TileStreamer: waiting-tile save failed for '
              + M.TileId.ToString + ': ' + E.Message);
        end;
        Slot.NeedsSave := False;
      end;
      AItem.Tiles[I] := nil;     { ownership transferred to the slot }
    end
    else
    begin
      { Тайл блока сейчас не нужен стримингу вовсе (сплит-остаток ИЛИ
        pregen дальнего коридора без tile-slot). На диске его ещё нет —
        раньше он молча терялся с устаревшим «it is on disk», и когда
        камера доезжала, блок bgsDone без файла перегенерировался
        ЦЕЛИКОМ. Отдаём сейв-очереди: воркер запишет и освободит. }
      EnqueueSave(M.TileId, M);
      AItem.Tiles[I] := nil;     { владение ушло в сейв-очередь }
    end;
  end;

  { Сироты tssWaitingBlock: блок завершился УСПЕШНО, но какой-то его
    wanted-тайл НЕ пришёл в Res.Tiles (сплит дал KeptN < BlockSize² —
    success при частичном результате). Раньше такой тайл застревал в
    tssWaitingBlock НАВСЕГДА: WantTile для этого состояния ничего не
    делает, eviction-switch в Pump ветки tssWaitingBlock не имеет, а
    его блок уже bgsDone — перегенерации не будет. Видимый эффект —
    стриминг «замирает» на этом месте. Возврат в tssUnknown (зеркально
    ApplyBlockFailed) перезапускает тайл на следующем WantTile: файл
    на диске есть → EnqueueIO, нет → ScheduleBlockFor (bgsDone-ветка
    перегенерирует блок). }
  for Slot in FTiles.Values do
    if (Slot.State = tssWaitingBlock)
       and BlockOf(Slot.Id, FBlockSize).Equals(AItem.Block) then
      Slot.State := tssUnknown;
end;

procedure TTileStreamer.ApplyBlockFailed(AItem: TStreamResultItem);
var
  BSlot: TBlockSlot;
  Slot:  TTileSlot;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(978);{$ENDIF}
  if FBlocks.TryGetValue(BlockKeyOf(AItem.Block), BSlot) then
  begin
    BSlot.State      := bgsFailed;
    BSlot.LastError  := AItem.Error;
    BSlot.RetryFrame := FFrame + BlockFailCooldownFrames;
  end;

  { Release the block's waiting tiles so they are rescheduled once the
    cooldown elapses (ScheduleBlockFor gates the retry on RetryFrame). }
  for Slot in FTiles.Values do
    if (Slot.State = tssWaitingBlock)
       and BlockOf(Slot.Id, FBlockSize).Equals(AItem.Block) then
      Slot.State := tssUnknown;
end;

{ Shadow-mask worker
 EnqueueShadowGen / PeekShadowUpload / CommitShadowUpload / HasPendingShadow /
 DropTileShadow run on the MAIN thread; DoOneShadowJob is the worker entry.
 The gen + upload FIFOs hold heap pointers; the worker copies a job's payload
 out under the lock, releases it, rasterises with no lock held, then re-takes
 the lock to publish the upload and remove the (until-then still-queued) job. }

procedure TTileStreamer.EnqueueShadowGen(const AJob: TShadowGenJob);
var
  P: PShadowGenJob;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1802);{$ENDIF}
  New(P);
  P^ := AJob;                  { copies fields; managed arrays refcounted }
  FShadowLock.Enter;
  try
    FGenQueue.Add(P);
  finally
    FShadowLock.Leave;
  end;
  FWakeShadow.SetEvent;
end;

function TTileStreamer.DoOneShadowJob: Boolean;
var
  P:     PShadowGenJob;
  U:     PShadowUpload;
  bytes:     TShadowMaskBytes;
  bytesTree: TShadowMaskBytes;
  ox, oz, sx, sz: Single;
  w, h:  Integer;
  gen:   QWord;
  ground: TShadowGroundTriangles;
  receiver: TShadowReceiverRaster;
  tris:  TProjTriArray;
  trees: TShadowTreeCardArray;
  key:   string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1832);{$ENDIF}
  Result := False;
  { PEEK the front gen job but DO NOT remove it — it must stay in the queue
    for its whole processing duration so HasPendingShadow / DropTileShadow
    see it as in-flight and a tile whose mask is being rasterised is never
    evicted out from under us. Only ONE shadow worker exists, so no other
    thread processes this same front job concurrently. }
  FShadowLock.Enter;
  try
    if FGenQueue.Count = 0 then Exit;       { Result stays False -> sleep }
    P := FGenQueue[0];
    key := P^.Key;
    gen := P^.Gen;
    ox  := P^.OX;  oz := P^.OZ;  sx := P^.SX;  sz := P^.SZ;
    w   := P^.W;   h  := P^.H;
    tris  := P^.Tris;     { refcount bump — survives unlock + a Dispose }
    trees := P^.Trees;
    ground := P^.Ground;
  finally
    FShadowLock.Leave;
  end;

  { heavy rasterise OUTSIDE the lock — pure snapshot -> bytes }
  { Two SEPARATE masks now: buildings (Tris only, ShadowMaskBitsActive) and
    trees (Trees only, ShadowMaskBitsTree). Each packs independently at its
    own bit depth -> its own POT byte layout, matched to its placeholder.
    ACancel=@FShutdown: teardown карты рвёт растеризацию немедленно (nil →
    задание снимается без публикации ниже), иначе плотный тайл джойнил бы
    воркер секундами. }
  receiver := TShadowReceiverRaster.Create(ground, Vector2(ox,oz), Vector2(sx,sz), w,h,@FShutdown);
  try
  bytes     := RasterizeSnapshotMaskPacked(Vector2(ox, oz), Vector2(sx, sz),
                                           w, ShadowMaskBitsActive, tris, nil,
                                           @FShutdown, receiver);
  { TREE mask is 2-channel (darkness + wind sway-weight) -> own packer. }
  bytesTree := RasterizeTreeMaskPacked(Vector2(ox, oz), Vector2(sx, sz),
                                       w, ShadowMaskBitsTree, trees, @FShutdown, receiver);
  finally
    receiver.Free;
  end;

  { Re-acquire, publish the upload, and ONLY NOW remove the gen job we
    processed. Identity guard: if DropTileShadow pulled this job during the
    rasterise (it disposes the record itself), the front is no longer P — in
    that case discard our result and touch nothing. With the defer-on-pending
    eviction policy this guard normally never fires, but it keeps the worker
    correct even if a drop slips through. }
  FShadowLock.Enter;
  try
    if (FGenQueue.Count > 0) and (FGenQueue[0] = P) then
    begin
      if (bytes <> nil) or (bytesTree <> nil) then
      begin
        New(U);
        U^.Key       := key;
        U^.Gen       := gen;
        U^.Bytes     := bytes;
        U^.BytesTree := bytesTree;
        FUploadQueue.Add(U);   { stays here until the host peeks + commits }
      end;
      FGenQueue.Delete(0);
      Dispose(P);
    end;
    { else: P already removed + disposed elsewhere; drop bytes silently. }
  finally
    FShadowLock.Leave;
  end;
  Result := True;
end;

function TTileStreamer.PeekShadowUpload(out AKey: string;
  out AGen: QWord; out ABytes: TShadowMaskBytes;
  out ABytesTree: TShadowMaskBytes): Boolean;
var
  U: PShadowUpload;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1803);{$ENDIF}
  Result := False;
  AKey   := '';
  AGen   := 0;
  ABytes := nil;
  ABytesTree := nil;
  FShadowLock.Enter;
  try
    if FUploadQueue.Count = 0 then Exit;
    U := FUploadQueue[0];          { front — NOT removed here }
    AKey   := U^.Key;
    AGen   := U^.Gen;
    ABytes     := U^.Bytes;        { refcount bump — valid after unlock and
                                     after CommitShadowUpload disposes U }
    ABytesTree := U^.BytesTree;
    Result := True;
  finally
    FShadowLock.Leave;
  end;
end;

procedure TTileStreamer.CommitShadowUpload;
var
  U: PShadowUpload;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1804);{$ENDIF}
  { Remove the front upload the host just processed. Only the main thread
    removes from FUploadQueue (here and in DropTileShadow) and the worker
    only appends, so between a PeekShadowUpload and its CommitShadowUpload —
    both on the main thread, with no evict interleaved — the front is stable. }
  FShadowLock.Enter;
  try
    if FUploadQueue.Count = 0 then Exit;
    U := FUploadQueue[0];
    FUploadQueue.Delete(0);
    Dispose(U);
  finally
    FShadowLock.Leave;
  end;
end;

function TTileStreamer.UploadQueueDepth: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1805);{$ENDIF}
  FShadowLock.Enter;
  try
    Result := FUploadQueue.Count;
  finally
    FShadowLock.Leave;
  end;
end;

function TTileStreamer.HasPendingShadow(const AKey: string): Boolean;
var
  I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1806);{$ENDIF}
  { True if this tile still has a gen job (queued OR being rasterised — the
    worker leaves it in FGenQueue until it finishes) or an undelivered /
    uncommitted upload. The host calls this to defer eviction so a tile's
    mask texture node is never freed while in-flight work still references
    it. Cross-thread read -> under the lock. }
  Result := False;
  FShadowLock.Enter;
  try
    for I := 0 to FGenQueue.Count - 1 do
      if FGenQueue[I]^.Key = AKey then Exit(True);
    for I := 0 to FUploadQueue.Count - 1 do
      if FUploadQueue[I]^.Key = AKey then Exit(True);
  finally
    FShadowLock.Leave;
  end;
end;

procedure TTileStreamer.DropTileShadow(const AKey: string);
var
  I: Integer;
  P: PShadowGenJob;
  U: PShadowUpload;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1807);{$ENDIF}
  FShadowLock.Enter;
  try
    for I := FGenQueue.Count - 1 downto 0 do
    begin
      P := FGenQueue[I];
      if P^.Key = AKey then
      begin
        Dispose(P);
        FGenQueue.Delete(I);
      end;
    end;
    for I := FUploadQueue.Count - 1 downto 0 do
    begin
      U := FUploadQueue[I];
      if U^.Key = AKey then
      begin
        Dispose(U);
        FUploadQueue.Delete(I);
      end;
    end;
  finally
    FShadowLock.Leave;
  end;
end;

procedure TTileStreamer.DrainResults;
var
  SaveI: Integer;
  Item: TStreamResultItem;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(979);{$ENDIF}
  repeat
    Item := nil;
    FResultLock.Enter;
    try
      if FResults.Count > 0 then
        Item := FResults.Dequeue;
    finally
      FResultLock.Leave;
    end;
    if Item = nil then Break;

    try
      if Item.Epoch = FEpoch then
        case Item.Kind of
          srkTileLoaded:  ApplyTileLoaded(Item);
          srkBlockDone:   ApplyBlockDone(Item);
          srkBlockFailed: ApplyBlockFailed(Item);
        end
      else if Item.Kind = srkBlockDone then
        { Эпоха сменилась, но ГЕОМЕТРИЯ тайла от эпохи не зависит
          (ключ кэша — гео+genhash): сгенерированное сохраняем, а не
          выбрасываем — иначе труд воркера пропал и блок пере-генерится. }
        for SaveI := 0 to High(Item.Tiles) do
          if Item.Tiles[SaveI] <> nil then
          begin
            EnqueueSave(Item.Tiles[SaveI].TileId, Item.Tiles[SaveI]);
            Item.Tiles[SaveI] := nil;   { владение — сейв-очереди }
          end;
      { stale epoch (не-blockdone) -> drop; destructor frees models }
    finally
      Item.Free;
    end;
  until False;
  { Место в FResults освободилось — будим gen-воркеры на случай, если они
    стоят на backpressure (MAX_GEN_RESULTS_PENDING). Нет работы -> воркер
    проверит и снова уснёт; стоимость пренебрежимо мала. Auto-reset событие. }
  FWakeGen.SetEvent;
end;

procedure TTileStreamer.Pump(const ACamera: TLatLon; ADeltaSeconds: Single);
var
  CamE, CamN, FocE, FocN: Double;
  edgeM, CamPxX, CamPxY: Double;
  Alpha, InstE, InstN: Double;
  CamTX, CamTY, FocTX, FocTY: Integer;
  MinTX, MaxTX, MinTY, MaxTY, NearRT, FwdRT: Integer;
  EffUpload, EffNear, EffForward: Double;
  PrevRT: Integer;
  ScanH: Integer;
  TX, TY, Scanned: Integer;
  TeE, TeN, DNear, DFwd, Eff: Double;
  Tile: TGeoTileId;
  Slot: TTileSlot;
  ToRemove: specialize TList<TTileSlot>;
  I: Integer;
  WantedNow, ColdEnough: Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(980);{$ENDIF}
  Inc(FFrame);

  { Slippy keyhole in a LOCAL metric frame: metres = fractionalTile * edgeM
    (= global slippy pixel * metres-per-pixel). edgeM is one tile's ground
    size at the camera latitude — Web-Mercator is conformal, so tiles are
    locally square in metres. All radii stay metres; Floor(CamE/edgeM)
    recovers the integer slippy tile (== Grid.TileAt(camera).TX/TY). }
  edgeM := FCache.Grid.EdgeMetersAt(ACamera.Lat);
  if edgeM < 1.0 then edgeM := FEdgeMeters;

  { Кламп радиусов под давлением памяти (ClampLoadRadius из карты):
    эвикнутое не возвращается в скан немедленно. Отпускается ~1%/кадр,
    когда давление ушло. }
  if (FLoadClampM > 0) and not MemOverBudget then
  begin
    FLoadClampM := FLoadClampM + UploadRadius * 0.01;
    if FLoadClampM >= UploadRadius then FLoadClampM := 0;
  end;
  EffUpload  := UploadRadius;
  EffNear    := NearRadius;
  EffForward := ForwardRadius;
  if FLoadClampM > 0 then
  begin
    EffUpload  := Min(EffUpload,  FLoadClampM);
    EffNear    := Min(EffNear,    FLoadClampM);
    EffForward := Min(EffForward, FLoadClampM);
    { HOLE-DIAG: clamp pulled the near ring below its full radius. Detail
      prefetch inside the clamp is suppressed, so near tiles past it stay on
      their green-stub footprint — a FLAT patch, NOT a true hole (the stub
      still covers). Distinguishes "missing detail under mem pressure" from a
      genuine cut gap. Stashed for a worker to Log; throttled ~2 s. }
    if (EffNear < NearRadius) and (FFrame >= FLoadClampLogFrame) then
    begin
      FQueueLock.Enter;
      try
        if FLoadClampNote = '' then
        begin
          FLoadClampLogFrame := FFrame + 120;   { ~2 s at 60 fps }
          FLoadClampNote := Format(
            'NEAR ring clamped by mem-pressure: clamp=%.0f m < nearRadius=%.0f m'
            + ' — detail prefetch reduced; near tiles stay green-stub (flat,'
            + ' not a hole)', [FLoadClampM, NearRadius]);
        end;
      finally
        FQueueLock.Leave;
      end;
    end;
  end;
  FCache.Grid.PixelOf(ACamera, CamPxX, CamPxY);
  CamE := CamPxX / FCache.Grid.EdgePx * edgeM;
  CamN := CamPxY / FCache.Grid.EdgePx * edgeM;
  FQueueLock.Enter;
  FPrevCamE := CamE; FPrevCamN := CamN; FPrevEdgeM := edgeM;
  FQueueLock.Leave;

  if FHasPrev and (ADeltaSeconds > 1.0e-4) then
  begin
    InstE := (CamE - FPrevE) / ADeltaSeconds;
    InstN := (CamN - FPrevN) / ADeltaSeconds;
    if VelocityTau > 1.0e-3 then
      Alpha := 1.0 - Exp(-ADeltaSeconds / VelocityTau)
    else
      Alpha := 1.0;
    FVelE := FVelE + Alpha * (InstE - FVelE);
    FVelN := FVelN + Alpha * (InstN - FVelN);
  end;
  FPrevE   := CamE;
  FPrevN   := CamN;
  FHasPrev := True;
  FSpeed   := Hypot(FVelE, FVelN);

  { prefetch focus = camera (isotropic). The wanted region is a single disc centred on the camera,
 priority = plain distance. Direction/speed do NOT steer prefetch: a forward-lobe scheme mis-fired
 while turning — the velocity EMA lags ~VelocityTau s, so "ahead" pointed wrong for ~1 s, building
 distant off-axis tiles while skipping the one right in front. FVel*/FSpeed stay estimated above
 for stats only. }
  FocE := CamE;
  FocN := CamN;

  CamTX := Floor(CamE / edgeM); if CamTX < 0 then CamTX := 0;
  CamTY := Floor(CamN / edgeM); if CamTY < 0 then CamTY := 0;
  FocTX := Floor(FocE / edgeM); if FocTX < 0 then FocTX := 0;
  FocTY := Floor(FocN / edgeM); if FocTY < 0 then FocTY := 0;

  NearRT := Ceil(EffNear / edgeM) + 1;
  FwdRT  := Ceil(EffForward / edgeM) + 1;
  PrevRT := Ceil(GlobalLODConfig.Preview1x1M / edgeM) + 1;   { радиус префетча детали — чуть дальше радиуса монтирования }

  { кламп бокса скана (ГЛАВНЫЙ фикс «стриминг замирает на широте»)
 Радиусы заданы в МЕТРАХ, а edgeM ∝ cos(широты камеры): к северу тайл
 мельчает и бокс растёт как 1/cos². Раньше при превышении MaxScanTiles
 скан просто ОБРЫВАЛСЯ (Break) — а идёт он по TY с СЕВЕРНОГО края, так
 что обрезались южные ряды, ВКЛЮЧАЯ РЯД САМОЙ КАМЕРЫ: тайлы вокруг и
 под камерой переставали помечаться wanted → монтирование и генерация
 вокруг камеры останавливались, уже смонтированное «остывало» и
 эвиктилось. Симптом: на некоторой широте (зависит от HeightmapZoom и
 GlobalLODConfig.GroundVisibilityM; например z15 → ~45°, z14 → ~69°) стриминг
 «не идёт дальше» — молча, без единой строки в логе.
 Теперь радиусы клампятся так, чтобы бокс (2R+1)² гарантированно
 помещался в MaxScanTiles и ОСТАВАЛСЯ ЦЕНТРИРОВАН на камере: ближняя
 зона (upload/монтаж) обслуживается всегда, ужимается только дальний
 префетч. Break ниже остаётся как страховка. }
  ScanH := (Trunc(Sqrt(MaxScanTiles)) - 1) div 2;   { half-side of the cap }
  if ScanH < 1 then ScanH := 1;
  if (NearRT > ScanH) or (FwdRT > ScanH) then
  begin
    if FFrame >= FScanClampLogFrame then
    begin
      FScanClampLogFrame := FFrame + 3600;   { ~раз в минуту при 60 fps }
      FQueueLock.Enter;
      try
        FScanClampNote := Format(
          'keyhole scan CLAMPED: edge=%.0f m (lat %.3f), need near=%d fwd=%d'
          + ' tiles, cap half-side=%d (MaxScanTiles=%d) — prefetch radius'
          + ' reduced; raise MaxScanTiles or lower HeightmapZoom /'
          + ' view distance (GlobalLODConfig.GroundVisibilityM) to extend it',
          [edgeM, ACamera.Lat, NearRT, FwdRT, ScanH, MaxScanTiles]);
      finally
        FQueueLock.Leave;
      end;
    end;
    if NearRT > ScanH then NearRT := ScanH;
    if FwdRT  > ScanH then FwdRT  := ScanH;
  end;
  if PrevRT > ScanH then PrevRT := ScanH;
  if PrevRT < NearRT then PrevRT := NearRT;

  MinTX := Min(CamTX - PrevRT, FocTX - FwdRT); if MinTX < 0 then MinTX := 0;
  MaxTX := Max(CamTX + PrevRT, FocTX + FwdRT);
  MinTY := Min(CamTY - PrevRT, FocTY - FwdRT); if MinTY < 0 then MinTY := 0;
  MaxTY := Max(CamTY + PrevRT, FocTY + FwdRT);

  Scanned := 0;
  for TY := MinTY to MaxTY do
  begin
    if Scanned > MaxScanTiles then Break;
    for TX := MinTX to MaxTX do
    begin
      Inc(Scanned);
      if Scanned > MaxScanTiles then Break;

      TeE := (TX + 0.5) * edgeM;
      TeN := (TY + 0.5) * edgeM;
      DNear := Hypot(CamE - TeE, CamN - TeN);
      DFwd  := Hypot(FocE - TeE, FocN - TeN);
      if (DNear > EffNear) and (DFwd > EffForward) then
      begin
        { За радиусом монтирования — эту зону покрывает дерево суперами. }
        Continue;
      end;

      { isotropic priority — nearest tile first, no travel-direction bias }
      Eff := DNear;

      Tile.Zone  := 0;       { slippy — no UTM zone; matches Grid.TileAt & cache }
      Tile.North := True;
      Tile.TX    := Cardinal(TX);
      Tile.TY    := Cardinal(TY);
      { Route-only режим: карта отдала предикат коридора — тайлы вне коридора
        (в радиусе RouteOnlyRadiusM от ломаной пути) в этом режиме не строим. }
      if Assigned(WantFilter) and (not WantFilter(Tile)) then Continue;
      WantTile(Tile, Eff, DNear <= EffUpload);
    end;
  end;

  DrainResults;

  { promote ready tiles to upload / evict far tiles / cancel stale }
  ToRemove := specialize TList<TTileSlot>.Create;
  try
    for Slot in FTiles.Values do
    begin
      WantedNow := (Slot.LastWantedFrame = FFrame);
      { Hysteresis: a tile counts as evictable only once it has been
        un-wanted for EvictLagFrames consecutive frames. A tile that
        merely flickered out of the keyhole for a frame or two (camera
        jitter, look-ahead lobe wobble) is NOT cold yet, so it is not
        dropped — which is what caused the same edge tiles to be
        dropped and re-read from disk over and over. }
      ColdEnough := (FFrame - Slot.LastWantedFrame) > EvictLagFrames;
      { Route-snap pinned this tile: keep it hot (no eviction, no pending
        gen/IO cancel). Every other tile evicts normally. }
      if (FPinned.Count > 0) and FPinned.ContainsKey(Slot.Id.ToKey) then
        ColdEnough := False;
      TeE := (Slot.Id.TX + 0.5) * edgeM;
      TeN := (Slot.Id.TY + 0.5) * edgeM;
      DNear := Hypot(CamE - TeE, CamN - TeN);

      case Slot.State of
        tssReadyInRAM:
          if WantedNow and Slot.WithinUpload then
          begin
            if not Slot.QueuedForUpload then
            begin
              FUploadList.Add(Slot);
              Slot.QueuedForUpload := True;
            end;
          end
          else if ColdEnough and (DNear > SceneUnloadRadius) then
          begin
            { Несохранённая генерация не выбрасывается: сначала в
              сейв-очередь (воркер запишет и освободит), иначе блок
              позже перегенерируется. }
            if Slot.NeedsSave and (Slot.Model <> nil) then
            begin
              EnqueueSave(Slot.Id, Slot.Model);
              Slot.Model     := nil;
              Slot.NeedsSave := False;
            end;
            { Cold and very far — only now drop the RAM model; it stays
              on disk. A loaded-but-not-yet-mounted tile is kept until
              SceneUnloadRadius (not UnloadRadius): it is a prefetch
              that already cost a disk read, and ForwardRadius pushes
              prefetch out to ~2 km — well beyond UnloadRadius (1.4 km).
              Dropping it at UnloadRadius guaranteed a drop-and-reread
              of every look-ahead tile the camera had not reached yet
              (observed: the same tile read 7x). RAM for an unmounted
              TTileModel is far cheaper than re-reading it from disk. }
            if Slot.QueuedForUpload then
              FUploadList.Remove(Slot);
            ToRemove.Add(Slot);
          end;

        tssUploaded:
          if ColdEnough and (DNear > SceneUnloadRadius) then
          begin
            FEvictQueue.Enqueue(Slot.Id);
            ToRemove.Add(Slot);
          end;

        tssQueuedIO:
          if ColdEnough and (DNear > UnloadRadius) then
          begin
            { cancel only if the job has not started; if it is in
              flight let it finish — the result is cached anyway }
            if RemoveFromPendingIO(Slot) then
              Slot.State := tssUnknown;
          end;

        tssFailed:
          if ColdEnough and (DNear > UnloadRadius) then
            ToRemove.Add(Slot);
      end;
    end;

    for I := 0 to ToRemove.Count - 1 do
    begin
      Slot := ToRemove[I];
      FTiles.Remove(Slot.Id.ToKey);
      Slot.Free;     { frees the model if still held }
    end;
  finally
    ToRemove.Free;
  end;

  { propagate this frame's priorities to the pending queues }
  FQueueLock.Enter;
  try
    for I := 0 to FPendingIO.Count - 1 do
      FPendingIO[I].Priority := FPendingIO[I].DesiredPriority;
    for I := 0 to FPendingGen.Count - 1 do
      FPendingGen[I].Priority := FPendingGen[I].DesiredPriority;
  finally
    FQueueLock.Leave;
  end;
end;

function TTileStreamer.NextUpload(out ATileId: TGeoTileId;
  out AModel: TTileModel): Boolean;
var
  Slot: TTileSlot;
  I, Best: Integer;
  D, BestD: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(981);{$ENDIF}
  Result := False;
  while FUploadList.Count > 0 do
  begin
    Best := 0;  BestD := 1.0e30;
    for I := 0 to FUploadList.Count - 1 do
    begin
      D := Sqr(FPrevCamE - (FUploadList[I].Id.TX + 0.5) * FPrevEdgeM)
         + Sqr(FPrevCamN - (FUploadList[I].Id.TY + 0.5) * FPrevEdgeM);
      if D < BestD then begin BestD := D; Best := I; end;
    end;
    Slot := FUploadList[Best];
    FUploadList.Delete(Best);
    { Skip a slot whose model vanished or whose state moved on. }
    if (Slot.State = tssReadyInRAM) and (Slot.Model <> nil) then
    begin
      ATileId := Slot.Id;
      AModel  := Slot.Model;     { borrowed until MarkUploaded }
      Result  := True;
      Exit;
    end;
    Slot.QueuedForUpload := False;
  end;
end;

procedure TTileStreamer.MarkUploaded(const ATileId: TGeoTileId);
var
  Slot: TTileSlot;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(982);{$ENDIF}
  if not FTiles.TryGetValue(ATileId.ToKey, Slot) then Exit;
  Slot.State := tssUploaded;
  Slot.QueuedForUpload := False;
  { Геометрия уже в сцене. Модель отдаём в фон-сохранение ТОЛЬКО если её
    ещё нет на диске (NeedsSave). Ждущий тайл уже записан при генерации
    (ApplyBlockDone) и имеет NeedsSave=False — его здесь лишь
    освобождаем, без повторной записи. }
  if Slot.Model <> nil then
  begin
    if Slot.NeedsSave then
      EnqueueSave(ATileId, Slot.Model)   { поток сохранит и освободит }
    else
      Slot.Model.Free;                    { уже на диске — просто освобождаем }
    Slot.Model := nil;             { владение отдано (сейв-очереди или free) }
  end;
  Slot.NeedsSave := False;
end;

procedure TTileStreamer.ReleaseUploadOwnership(const ATileId: TGeoTileId);
var
  Slot: TTileSlot;
begin
  if not FTiles.TryGetValue(ATileId.ToKey, Slot) then Exit;
  Slot.State := tssUploaded;
  Slot.QueuedForUpload := False;
  { владение моделью переходит вызывающему — НЕ освобождаем, лишь забываем ссылку,
    чтобы эвикт/повторная загрузка не тронули её, пока фон-ассемблер её читает.
    Новый владелец (DrainAssembled) сам ставит её в сейв-очередь. }
  Slot.Model := nil;
  Slot.NeedsSave := False;
end;

function TTileStreamer.NextEvict(out ATileId: TGeoTileId): Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(983);{$ENDIF}
  Result := FEvictQueue.Count > 0;
  if Result then
    ATileId := FEvictQueue.Dequeue;
end;

procedure TTileStreamer.SetPinnedTiles(const AIds: array of TGeoTileId);
var
  I: Integer;
begin
  FPinned.Clear;
  for I := 0 to High(AIds) do
    FPinned.AddOrSetValue(AIds[I].ToKey, True);
end;

function TTileStreamer.PendingVisibleTiles: Integer;
var Slot: TTileSlot;
begin
  Result := 0;
  for Slot in FTiles.Values do
    if (Slot.LastWantedFrame = FFrame) and Slot.WithinUpload and
       not (Slot.State in [tssUploaded, tssFailed]) then Inc(Result);
end;

function TTileStreamer.AlreadyOnDisk(const ATileId: TGeoTileId): Boolean;
begin
  Result := (FCache <> nil) and FCache.Has(ATileId);
end;

procedure TTileStreamer.Clear;
var
  Slot:  TTileSlot;
  BSlot: TBlockSlot;
  ClrItem: TStreamResultItem;
  ClrI:    Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(984);{$ENDIF}
  { Bump the epoch so any in-flight worker result is discarded when it
    arrives, then drop all pending and known state. In-flight gen jobs
    keep running but their output becomes stale. }
  FQueueLock.Enter;
  try
    Inc(FEpoch);
    FPendingIO.Clear;
    FPendingGen.Clear;
  finally
    FQueueLock.Leave;
  end;

  FResultLock.Enter;
  try
    while FResults.Count > 0 do
    begin
      ClrItem := FResults.Dequeue;
      { Свежая генерация от эпохи не зависит (ключ кэша — гео+genhash):
        сохранить, а не выбросить. Сейв-воркер жив во время Clear. }
      if ClrItem.Kind = srkBlockDone then
        for ClrI := 0 to High(ClrItem.Tiles) do
          if ClrItem.Tiles[ClrI] <> nil then
          begin
            EnqueueSave(ClrItem.Tiles[ClrI].TileId, ClrItem.Tiles[ClrI]);
            ClrItem.Tiles[ClrI] := nil;
          end;
      ClrItem.Free;
    end;
  finally
    FResultLock.Leave;
  end;

  FUploadList.Clear;
  while FEvictQueue.Count > 0 do
    FEvictQueue.Dequeue;

  for Slot in FTiles.Values do
  begin
    { Несохранённую генерацию — в сейв-очередь перед сбросом слота. }
    if Slot.NeedsSave and (Slot.Model <> nil) then
    begin
      EnqueueSave(Slot.Id, Slot.Model);
      Slot.Model     := nil;
      Slot.NeedsSave := False;
    end;
    Slot.Free;
  end;
  FTiles.Clear;

  for BSlot in FBlocks.Values do
    BSlot.Free;
  FBlocks.Clear;

  FHasPrev := False;
  FVelE    := 0.0;
  FVelN    := 0.0;
  FSpeed   := 0.0;
end;

end.

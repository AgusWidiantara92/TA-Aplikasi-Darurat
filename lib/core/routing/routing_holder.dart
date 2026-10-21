import 'package:shared_preferences/shared_preferences.dart';
import '../../features/chat/data/repositories/chat_repository.dart';
import '../blockchain/blockdag_repository.dart';
import '../blockchain/blockdag_security_coordinator.dart';
import '../blockchain/gossip/gossip.dart';
import '../blockchain/lightweight_blockdag_ledger.dart';
import '../ids/selective_forwarding_detector.dart';
import '../transport/mesh_transport.dart';
import '../transport/transport_holder.dart';
import '../trust/dynamic_trust_manager.dart';
import '../trust/trust_repository.dart';
import '../trust/trust_types.dart';
import 'manet_routing_engine.dart';
import 'mesh_experiment_logger.dart';
import 'node_identity.dart';

/// Container singleton penyimpan instance [ManetRoutingEngine] aktif aplikasi SiagaMesh.
///
/// Memungkinkan injeksi instance perutean simulasi pada pengujian unit,
/// inisialisasi deterministik subsistem keamanan (IDS, Dynamic Trust, BlockDAG, Gossip),
/// dan integrasi transparan pada lapisan widget aplikasi.
class ManetRoutingHolder {
  static ManetRoutingEngine? _instance;
  static MeshExperimentLogger? _logger;
  static NodeIdentityManager? _identityManager;
  static SelectiveForwardingDetector? _idsDetector;
  static DynamicTrustManager? _trustManager;
  static TrustRepository? _trustRepository;
  static LightweightBlockdagLedger? _ledger;
  static BlockdagRepository? _blockdagRepository;
  static BlockdagSecurityCoordinator? _blockdagCoordinator;
  static DagGossipSyncEngine? _gossipSyncEngine;
  static bool _enableTrustRoutingPolicy = false;
  static bool _enableBlockdagReplication = false;
  static bool _isInitialized = false;

  static MeshExperimentLogger get logger => _logger ??= MeshExperimentLogger();

  static void setLogger(MeshExperimentLogger? logger) {
    _logger = logger;
  }

  static NodeIdentityManager get identityManager =>
      _identityManager ??= NodeIdentityManager();

  static void setIdentityManager(NodeIdentityManager? manager) {
    _identityManager = manager;
  }

  static String get localNodeId => identityManager.localNodeId;

  static String get localNodeName => identityManager.localNodeName;

  static String get displayName => identityManager.displayName;

  static String get shortNodeId => identityManager.shortNodeId;

  static Stream<NodeIdentity> get identityStream =>
      identityManager.identityStream;

  /// Memperbarui nama tampilan perangkat pengguna dan mengumumkan ke tetangga aktif.
  static Future<String> updateDisplayName(String newName) async {
    final sanitized = await identityManager.updateDisplayName(newName);
    if (_instance != null) {
      await _instance!.announcePresence();
    }
    return sanitized;
  }

  static SelectiveForwardingDetector? get idsDetector => _idsDetector;

  static void setIdsDetector(SelectiveForwardingDetector? detector) {
    _idsDetector = detector;
  }

  static DynamicTrustManager? get trustManager => _trustManager;

  static void setTrustManager(DynamicTrustManager? manager) {
    _trustManager = manager;
  }

  static TrustRepository? get trustRepository => _trustRepository;

  static void setTrustRepository(TrustRepository? repo) {
    _trustRepository = repo;
  }

  static LightweightBlockdagLedger? get ledger => _ledger;

  static void setLedger(LightweightBlockdagLedger? ledger) {
    _ledger = ledger;
  }

  static BlockdagRepository? get blockdagRepository => _blockdagRepository;

  static void setBlockdagRepository(BlockdagRepository? repo) {
    _blockdagRepository = repo;
  }

  static BlockdagSecurityCoordinator? get blockdagCoordinator =>
      _blockdagCoordinator;

  static void setBlockdagCoordinator(BlockdagSecurityCoordinator? coordinator) {
    _blockdagCoordinator = coordinator;
  }

  static DagGossipSyncEngine? get gossipSyncEngine => _gossipSyncEngine;

  static void setGossipSyncEngine(DagGossipSyncEngine? engine) {
    _gossipSyncEngine?.dispose();
    _gossipSyncEngine = engine;
    if (_instance != null) {
      _instance!.gossipSyncEngine = engine;
    }
  }

  static bool get enableTrustRoutingPolicy => _enableTrustRoutingPolicy;

  static void setEnableTrustRoutingPolicy(bool enable) {
    _enableTrustRoutingPolicy = enable;
  }

  static bool get enableBlockdagReplication => _enableBlockdagReplication;

  static void setEnableBlockdagReplication(bool enable) {
    _enableBlockdagReplication = enable;
    if (_gossipSyncEngine != null) {
      _gossipSyncEngine!.isEnabled = enable;
    }
  }

  static bool get isInitialized => _isInitialized;

  /// Inisialisasi asinkron bootstrap seluruh subsistem keamanan dan perutean MANET.
  ///
  /// Menjamin bahwa seluruh komponen (IDS, Dynamic Trust, BlockDAG Ledger, Repository,
  /// Coordinator, dan Gossip Engine) saling terhubung sebelum aplikasi beroperasi.
  static Future<ManetRoutingEngine> initialize({
    MeshTransport? transport,
    ChatRepository? chatRepository,
    BlockdagRepository? blockdagRepository,
    TrustRepository? trustRepository,
    NodeIdentityManager? identityManager,
    IdsConfig idsConfig = const IdsConfig(),
    TrustConfig trustConfig = const TrustConfig(
      routingPolicy: TrustRoutingPolicy.monitoringOnly,
    ),
    BlockdagBatchConfig blockdagConfig = const BlockdagBatchConfig(),
    bool enableBlockdagReplication = false,
    bool enableTrustRoutingPolicy = false,
    bool autoStartIdsTimeoutTimer = true,
  }) async {
    if (_instance != null && _isInitialized) {
      return _instance!;
    }

    if (transport != null) {
      MeshTransportHolder.setInstance(transport);
    }
    if (chatRepository != null) {
      ChatRepositoryHolder.setInstance(chatRepository);
    }

    if (_identityManager == null) {
      if (identityManager != null) {
        _identityManager = identityManager;
      } else {
        final prefs = await SharedPreferences.getInstance();
        _identityManager = NodeIdentityManager(prefs: prefs);
      }
    }
    final localNodeId = _identityManager!.localNodeId;

    // 1. Inisialisasi IDS Detector
    _idsDetector ??= SelectiveForwardingDetector(
      localNodeId: localNodeId,
      config: idsConfig,
      experimentLogger: logger,
    );

    // 2. Inisialisasi Trust Manager & Persistensi Trust
    _trustRepository ??= trustRepository ?? LocalTrustRepository();
    _trustManager ??= DynamicTrustManager(
      localNodeId: localNodeId,
      config: trustConfig,
      repository: _trustRepository,
      experimentLogger: logger,
    );
    await _trustManager!.restoreState();

    // 3. Inisialisasi BlockDAG Ledger, Repository, dan Coordinator
    _ledger ??= LightweightBlockdagLedger();
    _blockdagRepository ??= blockdagRepository ?? LocalBlockdagRepository();
    _blockdagCoordinator ??= BlockdagSecurityCoordinator(
      localNodeId: localNodeId,
      ledger: _ledger!,
      repository: _blockdagRepository!,
      config: blockdagConfig,
    );
    await _blockdagCoordinator!.initialize();

    // Hubungkan stream IDS dan Trust ke BlockDAG Coordinator
    _blockdagCoordinator!.attachToDetector(_idsDetector!);
    _blockdagCoordinator!.attachToTrustManager(_trustManager!);

    // 4. Inisialisasi Gossip Sync Engine
    _gossipSyncEngine ??= DagGossipSyncEngine(
      transport: MeshTransportHolder.instance,
      localNodeId: localNodeId,
      ledger: _ledger!,
      repository: _blockdagRepository,
      enableOrphanPool: true,
      isEnabled: false,
    );

    _enableTrustRoutingPolicy = enableTrustRoutingPolicy;
    _enableBlockdagReplication = enableBlockdagReplication;
    _gossipSyncEngine!.isEnabled = enableBlockdagReplication;

    // 5. Inisialisasi ManetRoutingEngine terpadu
    _instance ??= ManetRoutingEngine(
      transport: MeshTransportHolder.instance,
      identityManager: _identityManager!,
      repository: ChatRepositoryHolder.instance,
      experimentLogger: logger,
      idsDetector: _idsDetector,
      trustManager: _trustManager,
      blockdagCoordinator: _blockdagCoordinator,
      enableHopAck: true,
      enableTrustRoutingPolicy: _enableTrustRoutingPolicy,
      autoStartIdsTimeoutTimer: autoStartIdsTimeoutTimer,
      gossipSyncEngine: _gossipSyncEngine,
    );

    _isInitialized = true;
    return _instance!;
  }

  /// Sinkronisasi fallback jika [instance] diakses tanpa pemanggilan [initialize()] terlebih dahulu.
  static void _ensureInitializedSync() {
    _identityManager ??= NodeIdentityManager();
    final localNodeId = _identityManager!.localNodeId;

    _idsDetector ??= SelectiveForwardingDetector(
      localNodeId: localNodeId,
      config: const IdsConfig(),
      experimentLogger: logger,
    );

    _trustRepository ??= LocalTrustRepository();
    _trustManager ??= DynamicTrustManager(
      localNodeId: localNodeId,
      config: const TrustConfig(
        routingPolicy: TrustRoutingPolicy.monitoringOnly,
      ),
      repository: _trustRepository,
      experimentLogger: logger,
    );
    _trustManager!.restoreState().catchError((_) => false);

    _ledger ??= LightweightBlockdagLedger();
    _blockdagRepository ??= LocalBlockdagRepository();
    _blockdagCoordinator ??= BlockdagSecurityCoordinator(
      localNodeId: localNodeId,
      ledger: _ledger!,
      repository: _blockdagRepository!,
    );
    _blockdagCoordinator!.initialize().catchError(
      (_) => BlockdagInitStatus.storageUnavailable,
    );

    _blockdagCoordinator!.attachToDetector(_idsDetector!);
    _blockdagCoordinator!.attachToTrustManager(_trustManager!);

    _gossipSyncEngine ??= DagGossipSyncEngine(
      transport: MeshTransportHolder.instance,
      localNodeId: localNodeId,
      ledger: _ledger!,
      repository: _blockdagRepository,
      enableOrphanPool: true,
      isEnabled: _enableBlockdagReplication,
    );

    _instance ??= ManetRoutingEngine(
      transport: MeshTransportHolder.instance,
      identityManager: _identityManager!,
      repository: ChatRepositoryHolder.instance,
      experimentLogger: logger,
      idsDetector: _idsDetector,
      trustManager: _trustManager,
      blockdagCoordinator: _blockdagCoordinator,
      enableHopAck: true,
      enableTrustRoutingPolicy: _enableTrustRoutingPolicy,
      autoStartIdsTimeoutTimer: false,
      gossipSyncEngine: _gossipSyncEngine,
    );

    _isInitialized = true;
  }

  /// Mengambil singleton aktif [ManetRoutingEngine].
  static ManetRoutingEngine get instance {
    if (_instance != null) return _instance!;
    _ensureInitializedSync();
    return _instance!;
  }

  static void setInstance(ManetRoutingEngine? engine) {
    _instance?.dispose();
    _instance = engine;
    if (engine != null) {
      _isInitialized = true;
    }
  }

  /// Menghentikan dan membersihkan seluruh resource subsistem routing dan keamanan.
  static void reset() {
    _instance?.dispose();
    _instance = null;
    _idsDetector?.dispose();
    _idsDetector = null;
    _trustManager?.dispose();
    _trustManager = null;
    _trustRepository = null;
    _blockdagCoordinator?.dispose();
    _blockdagCoordinator = null;
    _gossipSyncEngine?.dispose();
    _gossipSyncEngine = null;
    _ledger = null;
    _blockdagRepository = null;
    _identityManager = null;
    _enableTrustRoutingPolicy = false;
    _enableBlockdagReplication = false;
    _isInitialized = false;
  }
}

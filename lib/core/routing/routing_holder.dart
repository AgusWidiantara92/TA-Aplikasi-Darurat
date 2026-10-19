import '../../features/chat/data/repositories/chat_repository.dart';
import '../blockchain/blockdag_security_coordinator.dart';
import '../blockchain/gossip/gossip.dart';
import '../ids/selective_forwarding_detector.dart';
import '../transport/transport_holder.dart';
import '../trust/dynamic_trust_manager.dart';
import 'manet_routing_engine.dart';
import 'mesh_experiment_logger.dart';
import 'node_identity.dart';

/// Container singleton penyimpan instance [ManetRoutingEngine] aktif aplikasi SiagaMesh.
///
/// Memungkinkan injeksi instance perutean simulasi pada pengujian unit
/// dan integrasi transparan pada lapisan widget aplikasi.
class ManetRoutingHolder {
  static ManetRoutingEngine? _instance;
  static MeshExperimentLogger? _logger;
  static SelectiveForwardingDetector? _idsDetector;
  static DynamicTrustManager? _trustManager;
  static BlockdagSecurityCoordinator? _blockdagCoordinator;
  static DagGossipSyncEngine? _gossipSyncEngine;
  static bool _enableTrustRoutingPolicy = false;
  static bool _enableBlockdagReplication = false;

  static MeshExperimentLogger get logger => _logger ??= MeshExperimentLogger();

  static void setLogger(MeshExperimentLogger? logger) {
    _logger = logger;
  }

  static SelectiveForwardingDetector? get idsDetector => _idsDetector;

  static void setIdsDetector(SelectiveForwardingDetector? detector) {
    _idsDetector = detector;
  }

  static DynamicTrustManager? get trustManager => _trustManager;

  static void setTrustManager(DynamicTrustManager? manager) {
    _trustManager = manager;
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

  static ManetRoutingEngine get instance {
    return _instance ??= ManetRoutingEngine(
      transport: MeshTransportHolder.instance,
      identityManager: NodeIdentityManager(),
      repository: ChatRepositoryHolder.instance,
      experimentLogger: logger,
      idsDetector: _idsDetector,
      enableHopAck: _idsDetector != null,
      trustManager: _trustManager,
      enableTrustRoutingPolicy: _enableTrustRoutingPolicy,
      gossipSyncEngine: _gossipSyncEngine,
    );
  }

  static void setInstance(ManetRoutingEngine? engine) {
    _instance?.dispose();
    _instance = engine;
  }

  static void reset() {
    _instance?.dispose();
    _instance = null;
    _idsDetector?.dispose();
    _idsDetector = null;
    _trustManager?.dispose();
    _trustManager = null;
    _blockdagCoordinator?.dispose();
    _blockdagCoordinator = null;
    _gossipSyncEngine?.dispose();
    _gossipSyncEngine = null;
    _enableTrustRoutingPolicy = false;
    _enableBlockdagReplication = false;
  }
}

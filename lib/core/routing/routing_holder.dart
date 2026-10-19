import '../../features/chat/data/repositories/chat_repository.dart';
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
  static bool _enableTrustRoutingPolicy = false;

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

  static bool get enableTrustRoutingPolicy => _enableTrustRoutingPolicy;

  static void setEnableTrustRoutingPolicy(bool enable) {
    _enableTrustRoutingPolicy = enable;
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
    _enableTrustRoutingPolicy = false;
  }
}

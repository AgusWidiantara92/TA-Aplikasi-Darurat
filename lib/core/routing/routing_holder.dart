import '../../features/chat/data/repositories/chat_repository.dart';
import '../transport/transport_holder.dart';
import 'manet_routing_engine.dart';
import 'node_identity.dart';

/// Container singleton penyimpan instance [ManetRoutingEngine] aktif aplikasi SiagaMesh.
///
/// Memungkinkan injeksi instance perutean simulasi pada pengujian unit
/// dan integrasi transparan pada lapisan widget aplikasi.
class ManetRoutingHolder {
  static ManetRoutingEngine? _instance;

  static ManetRoutingEngine get instance {
    return _instance ??= ManetRoutingEngine(
      transport: MeshTransportHolder.instance,
      identityManager: NodeIdentityManager(),
      repository: ChatRepositoryHolder.instance,
    );
  }

  static void setInstance(ManetRoutingEngine? engine) {
    _instance?.dispose();
    _instance = engine;
  }

  static void reset() {
    _instance?.dispose();
    _instance = null;
  }
}

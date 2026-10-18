import 'mesh_transport.dart';
import 'nearby_mesh_transport.dart';

/// Container singleton penyimpan instance [MeshTransport] aktif aplikasi SiagaMesh.
///
/// Memungkinkan injeksi [FakeMeshTransport] pada saat pengujian unit atau widget,
/// dan menggunakan [NearbyMeshTransport] pada lingkungan runtime Android.
class MeshTransportHolder {
  static MeshTransport? _instance;

  static MeshTransport get instance => _instance ??= NearbyMeshTransport();

  static void setInstance(MeshTransport? transport) {
    _instance = transport;
  }
}

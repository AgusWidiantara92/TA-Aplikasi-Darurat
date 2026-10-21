import 'dart:typed_data';

/// Status koneksi terhadap peer tertentu pada lapisan transport 1-hop.
enum PeerConnectionStatus { disconnected, connecting, connected, rejected }

/// Kategori kegagalan diagnostik operasi transport nirkabel.
enum TransportFailureCategory {
  /// Izin sistem belum diberikan atau ditolak.
  permissionDenied,

  /// Radio Bluetooth mati atau belum aktif.
  bluetoothDisabled,

  /// Kemampuan radio atau perangkat keras nirkabel tidak tersedia / error.
  radioUnavailable,

  /// Layanan Google Play Services tidak tersedia, usang, atau bermasalah.
  googlePlayServicesUnavailable,

  /// Operasi sebenarnya sudah berjalan aktif (bukan kegagalan fatal).
  alreadyRunning,

  /// Konflik strategi koneksi atau resource radio sedang digunakan proses lain.
  connectionConflict,

  /// Transport gagal diinisialisasi pada layer native.
  transportInitFailed,

  /// Error tidak dikenal.
  unknown,
}

/// Laporan diagnosa teknis kegagalan atau status operasi transport nirkabel.
class TransportDiagnosticReport {
  final String operation;
  final TransportFailureCategory category;
  final String? exceptionType;
  final String? platformCode;
  final int? statusCode;
  final String? nativeMessage;
  final Map<String, dynamic> prerequisitesSnapshot;
  final Map<String, dynamic> transportStateSnapshot;
  final DateTime timestamp;
  final String userFriendlyMessage;
  final String suggestedAction;

  const TransportDiagnosticReport({
    required this.operation,
    required this.category,
    this.exceptionType,
    this.platformCode,
    this.statusCode,
    this.nativeMessage,
    this.prerequisitesSnapshot = const {},
    this.transportStateSnapshot = const {},
    required this.timestamp,
    required this.userFriendlyMessage,
    required this.suggestedAction,
  });

  @override
  String toString() {
    return 'TransportDiagnosticReport(op: $operation, category: ${category.name}, '
        'code: $statusCode, platformCode: $platformCode, '
        'nativeMsg: "$nativeMessage", state: $transportStateSnapshot, prereq: $prerequisitesSnapshot)';
  }
}

/// Model data perangkat fisik tetangga yang terdeteksi oleh transport 1-hop.
///
/// PERHATIAN: [endpointId] adalah identitas sementara yang diberikan oleh transport
/// nirkabel (misalnya Nearby Connections) dan dapat berubah pada sesi berikutnya.
/// Identitas permanen node aplikasi dikelola terpisah pada lapisan aplikasi/envelope.
class DiscoveredPeer {
  final String endpointId;
  final String endpointName;
  final String serviceId;
  final DateTime discoveredAt;
  final PeerConnectionStatus status;

  const DiscoveredPeer({
    required this.endpointId,
    required this.endpointName,
    required this.serviceId,
    required this.discoveredAt,
    this.status = PeerConnectionStatus.disconnected,
  });

  DiscoveredPeer copyWith({
    String? endpointId,
    String? endpointName,
    String? serviceId,
    DateTime? discoveredAt,
    PeerConnectionStatus? status,
  }) {
    return DiscoveredPeer(
      endpointId: endpointId ?? this.endpointId,
      endpointName: endpointName ?? this.endpointName,
      serviceId: serviceId ?? this.serviceId,
      discoveredAt: discoveredAt ?? this.discoveredAt,
      status: status ?? this.status,
    );
  }
}

/// Peristiwa perubahan status koneksi terhadap suatu endpoint transport.
class TransportConnectionEvent {
  final String endpointId;
  final String endpointName;
  final PeerConnectionStatus status;
  final String? details;

  const TransportConnectionEvent({
    required this.endpointId,
    required this.endpointName,
    required this.status,
    this.details,
  });
}

/// Representasi payload byte mentah yang diterima dari lapisan transport 1-hop.
class TransportPayload {
  final String endpointId;
  final Uint8List bytes;
  final DateTime receivedAt;

  const TransportPayload({
    required this.endpointId,
    required this.bytes,
    required this.receivedAt,
  });
}

/// Kontrak antarmuka lapisan transport langsung antarperangkat (1-hop device-to-device).
///
/// Abstraksi ini memisahkan logika antarmuka UI dari implementasi hardware/plugin
/// (seperti Google Nearby Connections atau Bluetooth Low Energy) serta memungkinkan
/// penggunaan Fake Transport untuk pengujian unit otomatis yang deterministik.
abstract class MeshTransport {
  /// Memeriksa dan meminta izin sistem (Bluetooth, Lokasi, Wi-Fi) jika diperlukan.
  Future<bool> checkAndRequestPermissions();

  /// Memulai proses advertising agar perangkat dapat ditemukan oleh peer di sekitarnya.
  Future<bool> startAdvertising({required String localNodeName});

  /// Menghentikan proses advertising.
  Future<void> stopAdvertising();

  /// Memulai proses discovery untuk memindai peer di sekitarnya.
  Future<bool> startDiscovery();

  /// Menghentikan proses discovery.
  Future<void> stopDiscovery();

  /// Mengirim permintaan koneksi langsung ke endpoint yang telah ditemukan.
  Future<bool> requestConnection({
    required String endpointId,
    required String localNodeName,
  });

  /// Menyetujui permintaan koneksi masuk dari endpoint.
  Future<bool> acceptConnection({required String endpointId});

  /// Menolak permintaan koneksi dari endpoint.
  Future<void> rejectConnection({required String endpointId});

  /// Memutuskan koneksi terhadap endpoint tertentu.
  Future<void> disconnect({required String endpointId});

  /// Menghentikan seluruh aktivitas advertising, discovery, dan memutuskan semua koneksi.
  Future<void> stopAll();

  /// Mengirimkan byte data langsung ke endpoint yang telah berstatus [PeerConnectionStatus.connected].
  ///
  /// Mengembalikan `true` jika payload berhasil diserahkan ke stack pengiriman transport.
  Future<bool> sendBytes({
    required String endpointId,
    required Uint8List bytes,
  });

  /// Stream daftar peer yang sedang terdeteksi di sekitar.
  Stream<List<DiscoveredPeer>> get discoveredPeersStream;

  /// Stream peristiwa koneksi (inisiasi, terhubung, terputus, ditolak).
  Stream<TransportConnectionEvent> get connectionEventsStream;

  /// Stream data byte masuk yang diterima dari peer terkoneksi.
  Stream<TransportPayload> get payloadStream;

  /// Daftar peer yang sedang terdeteksi saat ini.
  List<DiscoveredPeer> get currentPeers;

  /// Daftar peer yang sedang berstatus terkoneksi aktif ([PeerConnectionStatus.connected]).
  List<DiscoveredPeer> get connectedPeers;

  /// Apakah proses advertising sedang aktif.
  bool get isAdvertising;

  /// Apakah proses discovery sedang aktif.
  bool get isDiscovering;

  /// Laporan diagnosa teknis dari kegagalan operasi terakhir (jika ada).
  TransportDiagnosticReport? get lastDiagnosticReport => null;

  /// Membersihkan seluruh listener dan membebaskan resource transport.
  void dispose();
}

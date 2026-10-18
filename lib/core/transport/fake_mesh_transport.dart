import 'dart:async';
import 'dart:typed_data';
import 'mesh_transport.dart';

/// Implementasi tiruan (fake) [MeshTransport] dalam memori untuk pengujian unit
/// otomatis dan simulasi lingkungan tanpa ketergantungan perangkat keras nirkabel.
class FakeMeshTransport implements MeshTransport {
  bool _isAdvertising = false;
  bool _isDiscovering = false;
  bool _permissionsGranted = true;

  final Map<String, DiscoveredPeer> _peers = {};
  final List<TransportPayload> _sentPayloads = [];

  final StreamController<List<DiscoveredPeer>> _peersController =
      StreamController<List<DiscoveredPeer>>.broadcast();
  final StreamController<TransportConnectionEvent> _eventsController =
      StreamController<TransportConnectionEvent>.broadcast();
  final StreamController<TransportPayload> _payloadController =
      StreamController<TransportPayload>.broadcast();

  // --- Helper Pengujian ---

  void setPermissionsGranted(bool granted) {
    _permissionsGranted = granted;
  }

  List<TransportPayload> get sentPayloads => List.unmodifiable(_sentPayloads);

  void clearSentPayloads() {
    _sentPayloads.clear();
  }

  /// Menyimulasikan penemuan peer baru di sekitar.
  void simulatePeerDiscovered(DiscoveredPeer peer) {
    _peers[peer.endpointId] = peer;
    _emitPeers();
  }

  /// Menyimulasikan hilangnya sinyal peer dari jangkauan.
  void simulatePeerLost(String endpointId) {
    if (_peers.containsKey(endpointId)) {
      _peers.remove(endpointId);
      _emitPeers();
    }
  }

  /// Menyimulasikan permintaan koneksi masuk dari perangkat lain.
  void simulateIncomingConnectionRequest({
    required String endpointId,
    required String endpointName,
  }) {
    final existing = _peers[endpointId];
    final updated = DiscoveredPeer(
      endpointId: endpointId,
      endpointName: endpointName,
      serviceId: existing?.serviceId ?? 'siagamesh-service',
      discoveredAt: existing?.discoveredAt ?? DateTime.now(),
      status: PeerConnectionStatus.connecting,
    );
    _peers[endpointId] = updated;
    _emitPeers();
    _eventsController.add(
      TransportConnectionEvent(
        endpointId: endpointId,
        endpointName: endpointName,
        status: PeerConnectionStatus.connecting,
        details: 'Permintaan koneksi masuk tiruan',
      ),
    );
  }

  /// Menyimulasikan penerimaan byte payload dari peer tertentu.
  void simulateIncomingPayload({
    required String endpointId,
    required Uint8List bytes,
  }) {
    _payloadController.add(
      TransportPayload(
        endpointId: endpointId,
        bytes: bytes,
        receivedAt: DateTime.now(),
      ),
    );
  }

  /// Menyimulasikan pemutusan koneksi secara tiba-tiba oleh sistem/peer.
  void simulateDisconnection(String endpointId) {
    final peer = _peers[endpointId];
    if (peer != null) {
      _peers[endpointId] = peer.copyWith(
        status: PeerConnectionStatus.disconnected,
      );
      _emitPeers();
      _eventsController.add(
        TransportConnectionEvent(
          endpointId: endpointId,
          endpointName: peer.endpointName,
          status: PeerConnectionStatus.disconnected,
          details: 'Simulasi pemutusan koneksi',
        ),
      );
    }
  }

  void _emitPeers() {
    if (!_peersController.isClosed) {
      _peersController.add(currentPeers);
    }
  }

  // --- Implementasi MeshTransport ---

  @override
  Future<bool> checkAndRequestPermissions() async {
    return _permissionsGranted;
  }

  @override
  Future<bool> startAdvertising({required String localNodeName}) async {
    if (!_permissionsGranted) return false;
    _isAdvertising = true;
    return true;
  }

  @override
  Future<void> stopAdvertising() async {
    _isAdvertising = false;
  }

  @override
  Future<bool> startDiscovery() async {
    if (!_permissionsGranted) return false;
    _isDiscovering = true;
    return true;
  }

  @override
  Future<void> stopDiscovery() async {
    _isDiscovering = false;
  }

  @override
  Future<bool> requestConnection({
    required String endpointId,
    required String localNodeName,
  }) async {
    final peer = _peers[endpointId];
    if (peer == null) return false;

    _peers[endpointId] = peer.copyWith(status: PeerConnectionStatus.connecting);
    _emitPeers();
    _eventsController.add(
      TransportConnectionEvent(
        endpointId: endpointId,
        endpointName: peer.endpointName,
        status: PeerConnectionStatus.connecting,
      ),
    );
    return true;
  }

  @override
  Future<bool> acceptConnection({required String endpointId}) async {
    final peer = _peers[endpointId];
    if (peer == null) return false;

    _peers[endpointId] = peer.copyWith(status: PeerConnectionStatus.connected);
    _emitPeers();
    _eventsController.add(
      TransportConnectionEvent(
        endpointId: endpointId,
        endpointName: peer.endpointName,
        status: PeerConnectionStatus.connected,
      ),
    );
    return true;
  }

  @override
  Future<void> rejectConnection({required String endpointId}) async {
    final peer = _peers[endpointId];
    if (peer == null) return;

    _peers[endpointId] = peer.copyWith(status: PeerConnectionStatus.rejected);
    _emitPeers();
    _eventsController.add(
      TransportConnectionEvent(
        endpointId: endpointId,
        endpointName: peer.endpointName,
        status: PeerConnectionStatus.rejected,
      ),
    );
  }

  @override
  Future<void> disconnect({required String endpointId}) async {
    final peer = _peers[endpointId];
    if (peer == null) return;

    _peers[endpointId] = peer.copyWith(
      status: PeerConnectionStatus.disconnected,
    );
    _emitPeers();
    _eventsController.add(
      TransportConnectionEvent(
        endpointId: endpointId,
        endpointName: peer.endpointName,
        status: PeerConnectionStatus.disconnected,
      ),
    );
  }

  @override
  Future<void> stopAll() async {
    _isAdvertising = false;
    _isDiscovering = false;
    for (final id in _peers.keys) {
      _peers[id] = _peers[id]!.copyWith(
        status: PeerConnectionStatus.disconnected,
      );
    }
    _peers.clear();
    _emitPeers();
  }

  @override
  Future<bool> sendBytes({
    required String endpointId,
    required Uint8List bytes,
  }) async {
    final peer = _peers[endpointId];
    // Menolak pengiriman bila endpoint tidak ada atau belum berstatus connected
    if (peer == null || peer.status != PeerConnectionStatus.connected) {
      return false;
    }

    _sentPayloads.add(
      TransportPayload(
        endpointId: endpointId,
        bytes: bytes,
        receivedAt: DateTime.now(),
      ),
    );
    return true;
  }

  @override
  Stream<List<DiscoveredPeer>> get discoveredPeersStream =>
      _peersController.stream;

  @override
  Stream<TransportConnectionEvent> get connectionEventsStream =>
      _eventsController.stream;

  @override
  Stream<TransportPayload> get payloadStream => _payloadController.stream;

  @override
  List<DiscoveredPeer> get currentPeers => _peers.values.toList();

  @override
  List<DiscoveredPeer> get connectedPeers => _peers.values
      .where((p) => p.status == PeerConnectionStatus.connected)
      .toList();

  @override
  bool get isAdvertising => _isAdvertising;

  @override
  bool get isDiscovering => _isDiscovering;

  @override
  void dispose() {
    _isAdvertising = false;
    _isDiscovering = false;
    _peers.clear();
    _peersController.close();
    _eventsController.close();
    _payloadController.close();
  }
}

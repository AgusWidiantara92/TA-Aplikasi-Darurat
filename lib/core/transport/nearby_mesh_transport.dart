import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'mesh_transport.dart';

/// Implementasi konkret [MeshTransport] menggunakan Google Nearby Connections API
/// dengan strategi [Strategy.P2P_CLUSTER] untuk komunikasi 1-hop nirkabel offline.
class NearbyMeshTransport implements MeshTransport {
  static const String defaultServiceId = 'com.siagamesh.emergency.mesh';

  final String serviceId;
  final Strategy strategy;

  bool _isAdvertising = false;
  bool _isDiscovering = false;

  final Map<String, DiscoveredPeer> _peers = {};

  final StreamController<List<DiscoveredPeer>> _peersController =
      StreamController<List<DiscoveredPeer>>.broadcast();
  final StreamController<TransportConnectionEvent> _eventsController =
      StreamController<TransportConnectionEvent>.broadcast();
  final StreamController<TransportPayload> _payloadController =
      StreamController<TransportPayload>.broadcast();

  NearbyMeshTransport({
    this.serviceId = defaultServiceId,
    this.strategy = Strategy.P2P_CLUSTER,
  });

  @override
  Future<bool> checkAndRequestPermissions() async {
    // Pada Android, izin dideklarasikan di AndroidManifest.xml.
    // Pengecekan runtime dapat dikembangkan melalui platform channel jika diperlukan.
    return true;
  }

  @override
  Future<bool> startAdvertising({required String localNodeName}) async {
    try {
      final hasPerm = await checkAndRequestPermissions();
      if (!hasPerm) {
        debugPrint('[NearbyTransport] Izin tidak terpenuhi untuk advertising');
        return false;
      }

      final success = await Nearby().startAdvertising(
        localNodeName,
        strategy,
        serviceId: serviceId,
        onConnectionInitiated: (endpointId, connectionInfo) {
          debugPrint(
            '[NearbyTransport] Permintaan koneksi masuk dari: ${connectionInfo.endpointName} ($endpointId)',
          );
          _handleConnectionInitiated(
            endpointId: endpointId,
            endpointName: connectionInfo.endpointName,
          );
        },
        onConnectionResult: (endpointId, status) {
          debugPrint(
            '[NearbyTransport] Hasil koneksi $endpointId: ${status.name}',
          );
          _handleConnectionResult(endpointId, status);
        },
        onDisconnected: (endpointId) {
          debugPrint('[NearbyTransport] Terputus dari: $endpointId');
          _handleDisconnected(endpointId);
        },
      );

      _isAdvertising = success;
      return success;
    } catch (e) {
      debugPrint('[NearbyTransport] Exception startAdvertising: $e');
      _isAdvertising = false;
      return false;
    }
  }

  @override
  Future<void> stopAdvertising() async {
    try {
      await Nearby().stopAdvertising();
    } catch (e) {
      debugPrint('[NearbyTransport] Exception stopAdvertising: $e');
    } finally {
      _isAdvertising = false;
    }
  }

  @override
  Future<bool> startDiscovery() async {
    try {
      final hasPerm = await checkAndRequestPermissions();
      if (!hasPerm) {
        debugPrint('[NearbyTransport] Izin tidak terpenuhi untuk discovery');
        return false;
      }

      final success = await Nearby().startDiscovery(
        'SiagaMesh-User',
        strategy,
        serviceId: serviceId,
        onEndpointFound: (endpointId, endpointName, foundServiceId) {
          debugPrint(
            '[NearbyTransport] Peer ditemukan: $endpointName ($endpointId)',
          );
          _peers[endpointId] = DiscoveredPeer(
            endpointId: endpointId,
            endpointName: endpointName,
            serviceId: foundServiceId,
            discoveredAt: DateTime.now(),
            status: PeerConnectionStatus.disconnected,
          );
          _emitPeers();
        },
        onEndpointLost: (endpointId) {
          debugPrint('[NearbyTransport] Peer hilang dari radar: $endpointId');
          if (_peers.containsKey(endpointId)) {
            _peers.remove(endpointId);
            _emitPeers();
          }
        },
      );

      _isDiscovering = success;
      return success;
    } catch (e) {
      debugPrint('[NearbyTransport] Exception startDiscovery: $e');
      _isDiscovering = false;
      return false;
    }
  }

  @override
  Future<void> stopDiscovery() async {
    try {
      await Nearby().stopDiscovery();
    } catch (e) {
      debugPrint('[NearbyTransport] Exception stopDiscovery: $e');
    } finally {
      _isDiscovering = false;
    }
  }

  @override
  Future<bool> requestConnection({
    required String endpointId,
    required String localNodeName,
  }) async {
    final peer = _peers[endpointId];
    if (peer == null) return false;

    try {
      _peers[endpointId] = peer.copyWith(
        status: PeerConnectionStatus.connecting,
      );
      _emitPeers();

      final success = await Nearby().requestConnection(
        localNodeName,
        endpointId,
        onConnectionInitiated: (id, connectionInfo) {
          _handleConnectionInitiated(
            endpointId: id,
            endpointName: connectionInfo.endpointName,
          );
        },
        onConnectionResult: (id, status) {
          _handleConnectionResult(id, status);
        },
        onDisconnected: (id) {
          _handleDisconnected(id);
        },
      );
      return success;
    } catch (e) {
      debugPrint('[NearbyTransport] Exception requestConnection: $e');
      _peers[endpointId] = peer.copyWith(
        status: PeerConnectionStatus.disconnected,
      );
      _emitPeers();
      return false;
    }
  }

  @override
  Future<bool> acceptConnection({required String endpointId}) async {
    try {
      final success = await Nearby().acceptConnection(
        endpointId,
        onPayLoadRecieved: (id, payload) {
          if (payload.type == PayloadType.BYTES && payload.bytes != null) {
            _payloadController.add(
              TransportPayload(
                endpointId: id,
                bytes: payload.bytes!,
                receivedAt: DateTime.now(),
              ),
            );
          }
        },
      );
      return success;
    } catch (e) {
      debugPrint('[NearbyTransport] Exception acceptConnection: $e');
      return false;
    }
  }

  @override
  Future<void> rejectConnection({required String endpointId}) async {
    try {
      await Nearby().rejectConnection(endpointId);
      final peer = _peers[endpointId];
      if (peer != null) {
        _peers[endpointId] = peer.copyWith(
          status: PeerConnectionStatus.rejected,
        );
        _emitPeers();
      }
    } catch (e) {
      debugPrint('[NearbyTransport] Exception rejectConnection: $e');
    }
  }

  @override
  Future<void> disconnect({required String endpointId}) async {
    try {
      await Nearby().disconnectFromEndpoint(endpointId);
      _handleDisconnected(endpointId);
    } catch (e) {
      debugPrint('[NearbyTransport] Exception disconnect: $e');
    }
  }

  @override
  Future<void> stopAll() async {
    try {
      await stopAdvertising();
      await stopDiscovery();
      await Nearby().stopAllEndpoints();
      _peers.clear();
      _emitPeers();
    } catch (e) {
      debugPrint('[NearbyTransport] Exception stopAll: $e');
    }
  }

  @override
  Future<bool> sendBytes({
    required String endpointId,
    required Uint8List bytes,
  }) async {
    final peer = _peers[endpointId];
    if (peer == null || peer.status != PeerConnectionStatus.connected) {
      debugPrint(
        '[NearbyTransport] Menolak kirim bytes: endpoint $endpointId belum connected',
      );
      return false;
    }

    try {
      await Nearby().sendBytesPayload(endpointId, bytes);
      return true;
    } catch (e) {
      debugPrint('[NearbyTransport] Exception sendBytes: $e');
      return false;
    }
  }

  void _handleConnectionInitiated({
    required String endpointId,
    required String endpointName,
  }) {
    final peer = _peers[endpointId];
    final updated = DiscoveredPeer(
      endpointId: endpointId,
      endpointName: endpointName,
      serviceId: serviceId,
      discoveredAt: peer?.discoveredAt ?? DateTime.now(),
      status: PeerConnectionStatus.connecting,
    );
    _peers[endpointId] = updated;
    _emitPeers();

    _eventsController.add(
      TransportConnectionEvent(
        endpointId: endpointId,
        endpointName: endpointName,
        status: PeerConnectionStatus.connecting,
        details: 'Koneksi diinisiasi, otomatis menyetujui (1-hop auto-accept)',
      ),
    );

    // Pada prototipe komunikasi darurat 1-hop, sambungan disetujui otomatis
    acceptConnection(endpointId: endpointId);
  }

  void _handleConnectionResult(String endpointId, Status status) {
    final peer = _peers[endpointId];
    final endpointName = peer?.endpointName ?? 'Unknown-Node';

    PeerConnectionStatus newStatus;
    if (status == Status.CONNECTED) {
      newStatus = PeerConnectionStatus.connected;
    } else if (status == Status.REJECTED) {
      newStatus = PeerConnectionStatus.rejected;
    } else {
      newStatus = PeerConnectionStatus.disconnected;
    }

    if (peer != null) {
      _peers[endpointId] = peer.copyWith(status: newStatus);
      _emitPeers();
    }

    _eventsController.add(
      TransportConnectionEvent(
        endpointId: endpointId,
        endpointName: endpointName,
        status: newStatus,
        details: 'Hasil koneksi status: ${status.name}',
      ),
    );
  }

  void _handleDisconnected(String endpointId) {
    final peer = _peers[endpointId];
    final endpointName = peer?.endpointName ?? 'Unknown-Node';

    if (peer != null) {
      _peers[endpointId] = peer.copyWith(
        status: PeerConnectionStatus.disconnected,
      );
      _emitPeers();
    }

    _eventsController.add(
      TransportConnectionEvent(
        endpointId: endpointId,
        endpointName: endpointName,
        status: PeerConnectionStatus.disconnected,
        details: 'Terputus dari endpoint',
      ),
    );
  }

  void _emitPeers() {
    if (!_peersController.isClosed) {
      _peersController.add(currentPeers);
    }
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
    stopAll();
    _peersController.close();
    _eventsController.close();
    _payloadController.close();
  }
}

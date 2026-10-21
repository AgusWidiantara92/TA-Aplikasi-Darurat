import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'connectivity_prerequisite_service.dart';
import 'mesh_transport.dart';
import 'transport_diagnostics.dart';

/// Implementasi konkret [MeshTransport] menggunakan Google Nearby Connections API
/// dengan strategi [Strategy.P2P_CLUSTER] untuk komunikasi 1-hop nirkabel offline.
class NearbyMeshTransport implements MeshTransport {
  static const String defaultServiceId = 'com.siagamesh.emergency.mesh';

  final String serviceId;
  final Strategy strategy;
  final ConnectivityPrerequisiteService _prerequisiteService;

  bool _isAdvertising = false;
  bool _isDiscovering = false;
  TransportDiagnosticReport? _lastDiagnosticReport;

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
    ConnectivityPrerequisiteService? prerequisiteService,
  }) : _prerequisiteService =
           prerequisiteService ?? ConnectivityPrerequisiteHolder.instance;

  @override
  TransportDiagnosticReport? get lastDiagnosticReport => _lastDiagnosticReport;

  Map<String, dynamic> _currentTransportStateSnapshot() => {
    'isAdvertising': _isAdvertising,
    'isDiscovering': _isDiscovering,
    'peerCount': _peers.length,
    'connectedPeerCount': connectedPeers.length,
  };

  @override
  Future<bool> checkAndRequestPermissions() async {
    final check = await _prerequisiteService.checkPrerequisites();
    if (check.isReady) return true;

    if (check.status == PrerequisiteStatus.permissionRequired) {
      final granted = await _prerequisiteService.requestPermissions();
      if (granted) {
        final recheck = await _prerequisiteService.checkPrerequisites();
        return recheck.isReady;
      }
    }
    return false;
  }

  @override
  Future<bool> startAdvertising({required String localNodeName}) async {
    final transportSnapshot = _currentTransportStateSnapshot();
    final prereqCheck = await _prerequisiteService.checkPrerequisites();
    final prereqSnapshot = prereqCheck.toSnapshot();

    TransportDiagnostics.logOperationStart(
      operation: 'startAdvertising',
      transportStateSnapshot: transportSnapshot,
      prerequisitesSnapshot: prereqSnapshot,
    );

    // Jika sudah aktif pada layer Dart, pertahankan state aktif
    if (_isAdvertising) {
      debugPrint(
        '[NearbyTransport] startAdvertising: Sudah aktif di layer transport.',
      );
      return true;
    }

    // Verifikasi prasyarat konektivitas
    if (!prereqCheck.isReady) {
      final category =
          prereqCheck.status == PrerequisiteStatus.bluetoothDisabled
          ? TransportFailureCategory.bluetoothDisabled
          : (prereqCheck.status ==
                    PrerequisiteStatus.googlePlayServicesUnavailable
                ? TransportFailureCategory.googlePlayServicesUnavailable
                : TransportFailureCategory.permissionDenied);

      final report = TransportDiagnosticReport(
        operation: 'startAdvertising',
        category: category,
        prerequisitesSnapshot: prereqSnapshot,
        transportStateSnapshot: transportSnapshot,
        timestamp: DateTime.now(),
        userFriendlyMessage:
            prereqCheck.errorMessage ??
            (category == TransportFailureCategory.bluetoothDisabled
                ? 'Bluetooth belum aktif pada perangkat ini.'
                : 'Izin perangkat sekitar belum terpenuhi.'),
        suggestedAction: category == TransportFailureCategory.bluetoothDisabled
            ? 'Aktifkan Bluetooth pada perangkat.'
            : 'Berikan izin yang diperlukan melalui dialog atau pengaturan.',
      );

      _lastDiagnosticReport = report;
      TransportDiagnostics.logDiagnostic(report);
      _isAdvertising = false;
      return false;
    }

    try {
      // Bersihkan sesi advertising sebelumnya jika ada yang tertinggal
      try {
        await Nearby().stopAdvertising();
      } catch (_) {}

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
      if (success) {
        _lastDiagnosticReport = null;
        debugPrint(
          '[NearbyTransport] startAdvertising BERHASIL aktif untuk: $localNodeName (strategy: ${strategy.name})',
        );
      } else {
        final report = TransportDiagnostics.createReport(
          operation: 'startAdvertising',
          error: 'Platform mengembalikan false tanpa exception',
          prerequisitesSnapshot: prereqSnapshot,
          transportStateSnapshot: _currentTransportStateSnapshot(),
        );
        _lastDiagnosticReport = report;
        TransportDiagnostics.logDiagnostic(report);
      }
      return success;
    } catch (e) {
      final statusCode = TransportDiagnostics.extractStatusCode(e);

      // Status 8001: STATUS_ALREADY_ADVERTISING menunjukkan operasi sebenarnya sudah berjalan aktif
      if (statusCode == 8001) {
        debugPrint(
          '[NearbyTransport] startAdvertising: Layanan Nearby sudah dalam kondisi aktif di platform (STATUS_ALREADY_ADVERTISING: 8001). Sinkronisasi state transport.',
        );
        _isAdvertising = true;
        _lastDiagnosticReport = null;
        return true;
      }

      _isAdvertising = false;
      final report = TransportDiagnostics.createReport(
        operation: 'startAdvertising',
        error: e,
        prerequisitesSnapshot: prereqSnapshot,
        transportStateSnapshot: _currentTransportStateSnapshot(),
      );
      _lastDiagnosticReport = report;
      TransportDiagnostics.logDiagnostic(report);
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
    final transportSnapshot = _currentTransportStateSnapshot();
    final prereqCheck = await _prerequisiteService.checkPrerequisites();
    final prereqSnapshot = prereqCheck.toSnapshot();

    TransportDiagnostics.logOperationStart(
      operation: 'startDiscovery',
      transportStateSnapshot: transportSnapshot,
      prerequisitesSnapshot: prereqSnapshot,
    );

    // Jika sudah aktif pada layer Dart, pertahankan state aktif
    if (_isDiscovering) {
      debugPrint(
        '[NearbyTransport] startDiscovery: Sudah aktif di layer transport.',
      );
      return true;
    }

    // Verifikasi prasyarat konektivitas
    if (!prereqCheck.isReady) {
      final category =
          prereqCheck.status == PrerequisiteStatus.bluetoothDisabled
          ? TransportFailureCategory.bluetoothDisabled
          : (prereqCheck.status ==
                    PrerequisiteStatus.googlePlayServicesUnavailable
                ? TransportFailureCategory.googlePlayServicesUnavailable
                : TransportFailureCategory.permissionDenied);

      final report = TransportDiagnosticReport(
        operation: 'startDiscovery',
        category: category,
        prerequisitesSnapshot: prereqSnapshot,
        transportStateSnapshot: transportSnapshot,
        timestamp: DateTime.now(),
        userFriendlyMessage:
            prereqCheck.errorMessage ??
            (category == TransportFailureCategory.bluetoothDisabled
                ? 'Bluetooth belum aktif pada perangkat ini.'
                : 'Izin perangkat sekitar belum terpenuhi.'),
        suggestedAction: category == TransportFailureCategory.bluetoothDisabled
            ? 'Aktifkan Bluetooth pada perangkat.'
            : 'Berikan izin yang diperlukan melalui dialog atau pengaturan.',
      );

      _lastDiagnosticReport = report;
      TransportDiagnostics.logDiagnostic(report);
      _isDiscovering = false;
      return false;
    }

    try {
      // Bersihkan sesi discovery sebelumnya jika ada yang tertinggal
      try {
        await Nearby().stopDiscovery();
      } catch (_) {}

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
      if (success) {
        _lastDiagnosticReport = null;
        debugPrint(
          '[NearbyTransport] startDiscovery BERHASIL aktif (strategy: ${strategy.name})',
        );
      } else {
        final report = TransportDiagnostics.createReport(
          operation: 'startDiscovery',
          error: 'Platform mengembalikan false tanpa exception',
          prerequisitesSnapshot: prereqSnapshot,
          transportStateSnapshot: _currentTransportStateSnapshot(),
        );
        _lastDiagnosticReport = report;
        TransportDiagnostics.logDiagnostic(report);
      }
      return success;
    } catch (e) {
      final statusCode = TransportDiagnostics.extractStatusCode(e);

      // Status 8002: STATUS_ALREADY_DISCOVERING menunjukkan operasi sebenarnya sudah berjalan aktif
      if (statusCode == 8002) {
        debugPrint(
          '[NearbyTransport] startDiscovery: Layanan Nearby sudah dalam kondisi aktif di platform (STATUS_ALREADY_DISCOVERING: 8002). Sinkronisasi state transport.',
        );
        _isDiscovering = true;
        _lastDiagnosticReport = null;
        return true;
      }

      _isDiscovering = false;
      final report = TransportDiagnostics.createReport(
        operation: 'startDiscovery',
        error: e,
        prerequisitesSnapshot: prereqSnapshot,
        transportStateSnapshot: _currentTransportStateSnapshot(),
      );
      _lastDiagnosticReport = report;
      TransportDiagnostics.logDiagnostic(report);
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
      _lastDiagnosticReport = null;
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

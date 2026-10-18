/// Representasi peer tetangga 1-hop yang terdaftar pada tabel routing.
class NeighborPeer {
  final String endpointId;
  final String nodeId;
  final String nodeName;
  final DateTime connectedAt;
  final DateTime lastSeen;
  final bool isConnected;

  const NeighborPeer({
    required this.endpointId,
    required this.nodeId,
    required this.nodeName,
    required this.connectedAt,
    required this.lastSeen,
    this.isConnected = true,
  });

  NeighborPeer copyWith({
    String? endpointId,
    String? nodeId,
    String? nodeName,
    DateTime? connectedAt,
    DateTime? lastSeen,
    bool? isConnected,
  }) {
    return NeighborPeer(
      endpointId: endpointId ?? this.endpointId,
      nodeId: nodeId ?? this.nodeId,
      nodeName: nodeName ?? this.nodeName,
      connectedAt: connectedAt ?? this.connectedAt,
      lastSeen: lastSeen ?? this.lastSeen,
      isConnected: isConnected ?? this.isConnected,
    );
  }

  @override
  String toString() =>
      'NeighborPeer(endpoint: $endpointId, node: $nodeId, name: $nodeName, connected: $isConnected)';
}

/// Tabel pemetaan tetangga 1-hop yang menghubungkan endpoint ID transport dengan node ID aplikasi.
class NeighborTable {
  final Map<String, NeighborPeer> _byEndpoint = {};
  final Map<String, String> _nodeToEndpoint = {};

  /// Mendaftarkan endpoint baru yang terhubung pada lapisan transport.
  void registerConnectedEndpoint({
    required String endpointId,
    required String endpointName,
  }) {
    final now = DateTime.now();
    final peer = NeighborPeer(
      endpointId: endpointId,
      nodeId: 'pending-$endpointId',
      nodeName: endpointName,
      connectedAt: now,
      lastSeen: now,
      isConnected: true,
    );
    _byEndpoint[endpointId] = peer;
  }

  /// Memperbarui pemetaan identitas node aplikasi setelah pertukaran handshake.
  void mapIdentity({
    required String endpointId,
    required String nodeId,
    required String nodeName,
  }) {
    final existing = _byEndpoint[endpointId];
    final now = DateTime.now();

    final updated = NeighborPeer(
      endpointId: endpointId,
      nodeId: nodeId,
      nodeName: nodeName.isNotEmpty
          ? nodeName
          : (existing?.nodeName ?? 'Node-$nodeId'),
      connectedAt: existing?.connectedAt ?? now,
      lastSeen: now,
      isConnected: true,
    );

    _byEndpoint[endpointId] = updated;
    _nodeToEndpoint[nodeId] = endpointId;
  }

  /// Menandai endpoint terputus.
  void markDisconnected(String endpointId) {
    final existing = _byEndpoint[endpointId];
    if (existing != null) {
      _byEndpoint[endpointId] = existing.copyWith(isConnected: false);
      if (_nodeToEndpoint[existing.nodeId] == endpointId) {
        _nodeToEndpoint.remove(existing.nodeId);
      }
    }
  }

  /// Menghapus endpoint dari tabel.
  void remove(String endpointId) {
    final existing = _byEndpoint.remove(endpointId);
    if (existing != null) {
      if (_nodeToEndpoint[existing.nodeId] == endpointId) {
        _nodeToEndpoint.remove(existing.nodeId);
      }
    }
  }

  NeighborPeer? getPeerByEndpoint(String endpointId) => _byEndpoint[endpointId];

  NeighborPeer? getPeerByNodeId(String nodeId) {
    final epId = _nodeToEndpoint[nodeId];
    if (epId != null) {
      return _byEndpoint[epId];
    }
    return null;
  }

  String? getEndpointIdForNode(String nodeId) {
    final peer = getPeerByNodeId(nodeId);
    if (peer != null && peer.isConnected) {
      return peer.endpointId;
    }
    return null;
  }

  String? getNodeIdForEndpoint(String endpointId) {
    final peer = _byEndpoint[endpointId];
    if (peer != null && peer.isConnected) {
      return peer.nodeId;
    }
    return null;
  }

  /// Daftar seluruh tetangga yang saat ini terhubung aktif.
  List<NeighborPeer> get activeNeighbors =>
      _byEndpoint.values.where((p) => p.isConnected).toList();

  /// Daftar endpoint ID dari tetangga yang aktif.
  List<String> get activeEndpoints =>
      activeNeighbors.map((p) => p.endpointId).toList();

  /// Daftar node ID dari tetangga yang aktif.
  List<String> get activeNodeIds =>
      activeNeighbors.map((p) => p.nodeId).toList();

  void clear() {
    _byEndpoint.clear();
    _nodeToEndpoint.clear();
  }
}

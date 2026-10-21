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
  final Map<String, Set<String>> _nodeToEndpoints = {};
  final Map<String, String> _nodeNames = {};

  String _cleanNodeId(String raw) {
    return raw
        .replaceFirst(RegExp(r'^Node:\s*#?', caseSensitive: false), '')
        .trim();
  }

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
    _nodeToEndpoints
        .putIfAbsent('pending-$endpointId', () => <String>{})
        .add(endpointId);
  }

  /// Memperbarui pemetaan identitas node aplikasi setelah pertukaran handshake.
  void mapIdentity({
    required String endpointId,
    required String nodeId,
    required String nodeName,
  }) {
    final clean = _cleanNodeId(nodeId);
    final cleanLower = clean.toLowerCase();
    final existing = _byEndpoint[endpointId];
    final now = DateTime.now();

    // Jika endpoint ini sebelumnya terdaftar sebagai pending, bersihkan mapping pending
    if (existing != null && existing.nodeId.startsWith('pending-')) {
      _nodeToEndpoints[existing.nodeId]?.remove(endpointId);
      if (_nodeToEndpoints[existing.nodeId]?.isEmpty ?? false) {
        _nodeToEndpoints.remove(existing.nodeId);
      }
    }

    final resolvedName = nodeName.isNotEmpty
        ? nodeName
        : (existing?.nodeName.isNotEmpty == true &&
                  !existing!.nodeName.startsWith('pending-')
              ? existing.nodeName
              : (_nodeNames[cleanLower] ?? 'Node-$clean'));
    _nodeNames[cleanLower] = resolvedName;

    final updated = NeighborPeer(
      endpointId: endpointId,
      nodeId: clean,
      nodeName: resolvedName,
      connectedAt: existing?.connectedAt ?? now,
      lastSeen: now,
      isConnected: true,
    );

    _byEndpoint[endpointId] = updated;
    _nodeToEndpoints.putIfAbsent(cleanLower, () => <String>{}).add(endpointId);
  }

  /// Menandai endpoint terputus.
  void markDisconnected(String endpointId) {
    final existing = _byEndpoint[endpointId];
    if (existing != null) {
      _byEndpoint[endpointId] = existing.copyWith(isConnected: false);
    }
  }

  /// Menghapus endpoint dari tabel.
  void remove(String endpointId) {
    final existing = _byEndpoint.remove(endpointId);
    if (existing != null) {
      final cleanLower = _cleanNodeId(existing.nodeId).toLowerCase();
      _nodeToEndpoints[cleanLower]?.remove(endpointId);
      if (_nodeToEndpoints[cleanLower]?.isEmpty ?? false) {
        _nodeToEndpoints.remove(cleanLower);
      }
    }
  }

  /// Memeriksa apakah node dengan ID ini masih memiliki setidaknya satu endpoint aktif yang terhubung.
  bool isNodeConnected(String nodeId) {
    final cleanLower = _cleanNodeId(nodeId).toLowerCase();
    final endpoints = _nodeToEndpoints[cleanLower];
    if (endpoints != null && endpoints.isNotEmpty) {
      return endpoints.any((ep) => _byEndpoint[ep]?.isConnected == true);
    }
    // Fallback jika nodeId langsung merupakan endpoint ID
    final directPeer = _byEndpoint[nodeId];
    if (directPeer != null && directPeer.isConnected) {
      return true;
    }
    return false;
  }

  NeighborPeer? getPeerByEndpoint(String endpointId) => _byEndpoint[endpointId];

  NeighborPeer? getPeerByNodeId(String nodeId) {
    final epId = getEndpointIdForNode(nodeId);
    if (epId != null) {
      return _byEndpoint[epId];
    }
    // Jika tidak ada endpoint yang aktif terhubung, kembalikan peer terakhir yang tercatat
    final cleanLower = _cleanNodeId(nodeId).toLowerCase();
    final endpoints = _nodeToEndpoints[cleanLower];
    if (endpoints != null && endpoints.isNotEmpty) {
      final peers = endpoints
          .map((ep) => _byEndpoint[ep])
          .where((p) => p != null)
          .cast<NeighborPeer>()
          .toList();
      if (peers.isNotEmpty) {
        peers.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
        return peers.first;
      }
    }
    return null;
  }

  String? getEndpointIdForNode(String nodeId) {
    final cleanLower = _cleanNodeId(nodeId).toLowerCase();
    final endpoints = _nodeToEndpoints[cleanLower];
    if (endpoints != null && endpoints.isNotEmpty) {
      // Cari endpoint yang masih isConnected == true, urutkan berdasarkan lastSeen terbaru
      final activeEps = endpoints
          .map((ep) => _byEndpoint[ep])
          .where((p) => p != null && p.isConnected)
          .cast<NeighborPeer>()
          .toList();
      if (activeEps.isNotEmpty) {
        activeEps.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
        return activeEps.first.endpointId;
      }
    }

    // Fallback: Jika parameter langsung adalah endpoint ID yang terhubung
    final directPeer = _byEndpoint[nodeId];
    if (directPeer != null && directPeer.isConnected) {
      return directPeer.endpointId;
    }
    if (nodeId.startsWith('peer-')) {
      final subEp = nodeId.substring(5);
      final subPeer = _byEndpoint[subEp];
      if (subPeer != null && subPeer.isConnected) {
        return subPeer.endpointId;
      }
    }
    return null;
  }

  String? getNodeIdForEndpoint(String endpointId) {
    final peer = _byEndpoint[endpointId];
    if (peer != null && peer.isConnected) {
      if (!peer.nodeId.startsWith('pending-')) {
        return peer.nodeId;
      }
    }
    return null;
  }

  /// Daftar seluruh tetangga yang saat ini terhubung aktif, dideduplikasi berdasarkan nodeId kanonis.
  List<NeighborPeer> get activeNeighbors {
    final Map<String, NeighborPeer> canonicalMap = {};
    for (final peer in _byEndpoint.values) {
      if (!peer.isConnected) continue;
      final key = peer.nodeId.startsWith('pending-')
          ? peer.endpointId
          : peer.nodeId.toLowerCase();
      if (!canonicalMap.containsKey(key)) {
        canonicalMap[key] = peer;
      } else {
        final current = canonicalMap[key]!;
        if (peer.lastSeen.isAfter(current.lastSeen)) {
          canonicalMap[key] = peer;
        }
      }
    }
    return canonicalMap.values.toList();
  }

  /// Daftar endpoint ID dari seluruh tetangga yang aktif terhubung.
  List<String> get activeEndpoints => _byEndpoint.values
      .where((p) => p.isConnected)
      .map((p) => p.endpointId)
      .toList();

  /// Daftar node ID unik dari tetangga yang aktif terhubung.
  List<String> get activeNodeIds =>
      activeNeighbors.map((p) => p.nodeId).toSet().toList();

  void clear() {
    _byEndpoint.clear();
    _nodeToEndpoints.clear();
    _nodeNames.clear();
  }
}

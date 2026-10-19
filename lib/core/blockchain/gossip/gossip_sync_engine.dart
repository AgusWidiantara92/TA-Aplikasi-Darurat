/// Engine layanan sinkronisasi gossip BlockDAG SiagaMesh (DAG-Sync).
///
/// Mengatur siklus hidup pertukaran [DAG_HELLO] dan [DAG_INV] antar-node 1-hop:
/// 1. Mengirim [DAG_HELLO] saat peer langsung terhubung (jika fitur aktif).
/// 2. Membalas dengan [DAG_INV] setelah menerima [DAG_HELLO] yang valid.
/// 3. Membandingkan inventaris hash tetangga dengan ledger lokal tanpa mutasi ledger.
/// 4. Mendeteksi dan mencatat hash kandidat yang belum dimiliki secara lokal (*missing block hashes*).
/// 5. Mencegah loop respons pertukaran inventaris yang identik dalam satu sesi.
///
/// PERINGATAN INTEGRITAS & BATAS TAHAP:
/// Pada tahap ini (Stage 5E.4.3), engine HANYA melakukan pengenalan dan pertukaran inventaris.
/// BELUM meminta, mengirim, ataupun memasukkan blok remote ke dalam ledger.
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';

import '../../transport/mesh_transport.dart';
import '../lightweight_blockdag_ledger.dart';
import 'gossip_codec.dart';
import 'gossip_constants.dart';
import 'gossip_messages.dart';

/// State sesi gossip untuk satu endpoint peer 1-hop aktif.
class PeerGossipSession {
  final String endpointId;
  String? remoteNodeId;
  int? remoteSchemaVersion;
  int? remoteActiveBlocksCount;
  int? remoteMaxIndex;

  bool helloSent = false;
  bool helloReceived = false;
  bool invSent = false;
  bool invReceived = false;

  List<String> lastReceivedTipHashes = [];
  List<String> lastReceivedRecentHashes = [];
  final Set<String> missingBlockHashes = {};
  final Set<String> knownPeerBlockHashes = {};
  DagInvMessage? pendingInv;

  DateTime lastActivity;

  PeerGossipSession({required this.endpointId})
    : lastActivity = DateTime.now().toUtc();
}

/// Layanan modular sinkronisasi replikasi gossip BlockDAG SiagaMesh.
class DagGossipSyncEngine {
  final MeshTransport transport;
  final String localNodeId;
  final LightweightBlockdagLedger ledger;

  bool _isEnabled = false;
  bool _isDisposed = false;
  StreamSubscription<TransportConnectionEvent>? _connectionSub;

  final Map<String, PeerGossipSession> _sessions = {};

  // Metrik instrumentasi lokal
  int _totalHelloSent = 0;
  int _totalHelloReceived = 0;
  int _totalInvSent = 0;
  int _totalInvReceived = 0;
  int _totalGossipBytesSent = 0;
  int _totalGossipBytesReceived = 0;

  DagGossipSyncEngine({
    required this.transport,
    required this.localNodeId,
    required this.ledger,
    bool isEnabled = false,
  }) : _isEnabled = isEnabled {
    if (_isEnabled) {
      _initListeners();
    }
  }

  bool get isEnabled => _isEnabled;

  set isEnabled(bool value) {
    if (_isDisposed) return;
    if (_isEnabled == value) return;
    _isEnabled = value;
    if (_isEnabled) {
      _initListeners();
    } else {
      _disposeListeners();
      _sessions.clear();
    }
  }

  bool get isDisposed => _isDisposed;

  int get totalHelloSent => _totalHelloSent;
  int get totalHelloReceived => _totalHelloReceived;
  int get totalInvSent => _totalInvSent;
  int get totalInvReceived => _totalInvReceived;
  int get totalGossipBytesSent => _totalGossipBytesSent;
  int get totalGossipBytesReceived => _totalGossipBytesReceived;

  Map<String, PeerGossipSession> get activeSessions =>
      Map.unmodifiable(_sessions);

  PeerGossipSession? getSession(String endpointId) => _sessions[endpointId];

  Set<String> getMissingBlockHashesForPeer(String endpointId) {
    return Set.unmodifiable(
      _sessions[endpointId]?.missingBlockHashes ?? const {},
    );
  }

  void _initListeners() {
    _connectionSub?.cancel();
    _connectionSub = transport.connectionEventsStream.listen(
      (event) {
        _handleConnectionEvent(event).catchError((Object e) {
          debugPrint(
            '[DagGossipSyncEngine] Error asinkron pada _handleConnectionEvent: $e',
          );
        });
      },
      onError: (Object e) {
        debugPrint(
          '[DagGossipSyncEngine] Error pada connectionEventsStream transport: $e',
        );
      },
    );
  }

  void _disposeListeners() {
    _connectionSub?.cancel();
    _connectionSub = null;
  }

  /// Pengecekan apakah payload Map menyatakan diri sebagai protokol gossip SiagaMesh DAG-Sync.
  static bool claimsGossipProtocol(Map<String, dynamic> map) {
    return map['protocol'] == kDagGossipProtocolName;
  }

  /// Pengecekan apakah payload Map merupakan paket protokol gossip yang sah dan dikenali.
  static bool isGossipMap(Map<String, dynamic> map) {
    if (map['protocol'] != kDagGossipProtocolName) return false;
    final type = map['type'];
    if (type is! String || DagGossipMessageType.fromWireName(type) == null) {
      return false;
    }
    return true;
  }

  /// Pengecekan cepat apakah payload byte merupakan paket protokol gossip SiagaMesh DAG-Sync.
  ///
  /// Menjamin bahwa marker yang muncul hanya sebagai teks obrolan biasa di dalam envelope chat
  /// TIDAK akan diklasifikasikan sebagai paket gossip.
  static bool isGossipPayload(Uint8List bytes) {
    if (bytes.length < 30 || bytes.length > kMaxRawGossipPayloadBytes) {
      return false;
    }
    if (bytes[0] != 0x7B) {
      return false;
    }
    try {
      final jsonStr = utf8.decode(bytes);
      final decoded = jsonDecode(jsonStr);
      if (decoded is Map<String, dynamic>) {
        return claimsGossipProtocol(decoded);
      }
    } catch (_) {}
    return false;
  }

  /// Menangani peristiwa koneksi transport 1-hop.
  Future<void> _handleConnectionEvent(TransportConnectionEvent event) async {
    if (!_isEnabled || _isDisposed) return;

    if (event.status == PeerConnectionStatus.connected) {
      // Cegah duplikasi pengiriman HELLO bila event connected diterima berulang untuk endpoint yang sama
      final existing = _sessions[event.endpointId];
      if (existing != null && existing.helloSent) {
        existing.lastActivity = DateTime.now().toUtc();
        return;
      }

      final session = _sessions.putIfAbsent(
        event.endpointId,
        () => PeerGossipSession(endpointId: event.endpointId),
      );
      session.lastActivity = DateTime.now().toUtc();

      // Kirim DAG_HELLO pengenalan status awal ke tetangga baru
      await _sendHello(event.endpointId, session);
    } else if (event.status == PeerConnectionStatus.disconnected ||
        event.status == PeerConnectionStatus.rejected) {
      _sessions.remove(event.endpointId);
    }
  }

  /// Mengirimkan pesan [DAG_HELLO] ke peer tertentu dengan batas isolasi error.
  Future<bool> _sendHello(String endpointId, PeerGossipSession session) async {
    if (!_isEnabled || _isDisposed) return false;

    final tips = ledger.tipHashes.toList()..sort();
    final effectiveTips = tips.isEmpty ? [ledger.genesisBlock.blockHash] : tips;

    final maxIdx = ledger.getAllActiveBlocks().fold<int>(
      0,
      (max, b) => b.index > max ? b.index : max,
    );

    final helloMsg = DagHelloMessage(
      senderNodeId: localNodeId,
      senderTimestamp: DateTime.now().toUtc().millisecondsSinceEpoch,
      schemaVersion: 1,
      activeBlocksCount: ledger.activeBlocksCount,
      maxIndex: maxIdx,
      tipHashes: effectiveTips,
      genesisHash: ledger.genesisBlock.blockHash,
    );

    final bytes = DagGossipCodec.encode(helloMsg);
    bool sent = false;
    try {
      sent = await transport.sendBytes(endpointId: endpointId, bytes: bytes);
    } catch (e) {
      debugPrint(
        '[DagGossipSyncEngine] Exception saat sendHello ke $endpointId: $e',
      );
      sent = false;
    }

    if (!_isEnabled || _isDisposed) return false;
    final currentSession = _sessions[endpointId];
    if (currentSession == null || currentSession != session) {
      // Sesi telah dibersihkan atau diganti saat operasi asinkron menunggu
      return false;
    }

    if (sent) {
      session.helloSent = true;
      session.lastActivity = DateTime.now().toUtc();
      _totalHelloSent++;
      _totalGossipBytesSent += bytes.length;
    }
    return sent;
  }

  /// Mengirimkan pesan [DAG_INV] ke peer tertentu dengan batas isolasi error.
  Future<bool> _sendInv(String endpointId, PeerGossipSession session) async {
    if (!_isEnabled || _isDisposed) return false;

    final tips = ledger.tipHashes.toList()..sort();
    final effectiveTips = tips.isEmpty ? [ledger.genesisBlock.blockHash] : tips;

    final recentBlocks = ledger
        .getAllActiveBlocks()
        .map((b) => b.blockHash)
        .take(kMaxInvHashes)
        .toList();

    final invMsg = DagInvMessage(
      senderNodeId: localNodeId,
      senderTimestamp: DateTime.now().toUtc().millisecondsSinceEpoch,
      tipHashes: effectiveTips,
      recentBlockHashes: recentBlocks,
    );

    final bytes = DagGossipCodec.encode(invMsg);
    bool sent = false;
    try {
      sent = await transport.sendBytes(endpointId: endpointId, bytes: bytes);
    } catch (e) {
      debugPrint(
        '[DagGossipSyncEngine] Exception saat sendInv ke $endpointId: $e',
      );
      sent = false;
    }

    if (!_isEnabled || _isDisposed) return false;
    final currentSession = _sessions[endpointId];
    if (currentSession == null || currentSession != session) {
      return false;
    }

    if (sent) {
      session.invSent = true;
      session.lastActivity = DateTime.now().toUtc();
      _totalInvSent++;
      _totalGossipBytesSent += bytes.length;
    }
    return sent;
  }

  /// Menangani payload nirkabel yang masuk dari transport bytes mentah.
  Future<void> handleIncomingPayload(TransportPayload payload) async {
    final bytes = payload.bytes;
    if (bytes.length < 30 || bytes.length > kMaxRawGossipPayloadBytes) {
      return;
    }
    dynamic decoded;
    try {
      final jsonStr = utf8.decode(bytes);
      decoded = jsonDecode(jsonStr);
    } catch (_) {
      return;
    }
    if (decoded is! Map<String, dynamic>) {
      return;
    }
    await handleIncomingPayloadMap(
      endpointId: payload.endpointId,
      map: decoded,
      rawByteLength: bytes.length,
    );
  }

  /// Menangani payload yang telah didekode menjadi Map JSON tanpa decoding ganda.
  Future<void> handleIncomingPayloadMap({
    required String endpointId,
    required Map<String, dynamic> map,
    required int rawByteLength,
  }) async {
    if (!_isEnabled || _isDisposed) return;

    _totalGossipBytesReceived += rawByteLength;

    final decodeRes = DagGossipCodec.decodeFromMap(
      map,
      rawByteLength: rawByteLength,
    );
    if (!decodeRes.isSuccess || decodeRes.message == null) {
      debugPrint(
        '[DagGossipSyncEngine] Payload gossip tidak valid dari $endpointId: ${decodeRes.errorCode} - ${decodeRes.errorMessage}',
      );
      return;
    }

    final message = decodeRes.message!;
    final session = _sessions.putIfAbsent(
      endpointId,
      () => PeerGossipSession(endpointId: endpointId),
    );
    session.lastActivity = DateTime.now().toUtc();

    switch (message.type) {
      case DagGossipMessageType.hello:
        final hello = message as DagHelloMessage;
        _totalHelloReceived++;

        // Validasi kompatibilitas genesis hash dan schema version
        if (hello.genesisHash != ledger.genesisBlock.blockHash ||
            hello.schemaVersion != 1) {
          // Jangan memproses peer dengan jaringan/skema yang tidak kompatibel; bersihkan sesi
          _sessions.remove(endpointId);
          return;
        }

        session.remoteNodeId = hello.senderNodeId;
        session.remoteSchemaVersion = hello.schemaVersion;
        session.remoteActiveBlocksCount = hello.activeBlocksCount;
        session.remoteMaxIndex = hello.maxIndex;
        session.helloReceived = true;

        // Balas dengan inventaris lokal jika belum pernah dikirim pada sesi ini
        if (!session.invSent) {
          await _sendInv(endpointId, session);
        }

        // Jika sebelumnya ada DAG_INV yang tertahan menunggu verifikasi DAG_HELLO, proses sekarang
        if (session.pendingInv != null) {
          final pending = session.pendingInv!;
          session.pendingInv = null;
          _processInv(session, pending);
        }
        break;

      case DagGossipMessageType.inv:
        final inv = message as DagInvMessage;
        _totalInvReceived++;
        session.remoteNodeId = inv.senderNodeId;

        // Validasi urutan protokol: jika DAG_HELLO yang kompatibel belum diterima,
        // tahan inventaris di pendingInv hingga DAG_HELLO yang valid diverifikasi
        if (!session.helloReceived) {
          session.pendingInv = inv;
          if (!session.helloSent) {
            await _sendHello(endpointId, session);
          }
          return;
        }

        _processInv(session, inv);
        break;

      default:
        // Tipe pesan lain (DAG_GET_BLOCKS, DAG_BLOCK_BATCH, dll) belum diaktifkan pada tahap ini
        break;
    }
  }

  /// Memproses perbandingan hash inventaris [DAG_INV] terhadap status ledger lokal.
  void _processInv(PeerGossipSession session, DagInvMessage inv) {
    // Deduplikasi: Abaikan jika inventaris yang diumumkan identik dengan yang baru saja diterima
    if (_isDuplicateInventory(session, inv)) {
      return;
    }

    session.lastReceivedTipHashes = List.from(inv.tipHashes);
    session.lastReceivedRecentHashes = List.from(inv.recentBlockHashes);
    session.invReceived = true;

    // Bandingkan hash inventaris yang diumumkan dengan ledger lokal
    final allAnnouncedHashes = <String>{
      ...inv.tipHashes,
      ...inv.recentBlockHashes,
    };

    for (final hash in allAnnouncedHashes) {
      final existsInActive = ledger.getBlock(hash) != null;
      final existsInProcessed = ledger.processedBlockHashes.contains(hash);
      final existsInCheckpoints = ledger.checkpoints.any(
        (c) =>
            c.retainedGenesisHash == hash || c.prunedBlockHashes.contains(hash),
      );

      if (existsInActive || existsInProcessed || existsInCheckpoints) {
        session.knownPeerBlockHashes.add(hash);
      } else {
        session.missingBlockHashes.add(hash);
      }
    }
  }

  bool _isDuplicateInventory(PeerGossipSession session, DagInvMessage inv) {
    if (session.lastReceivedTipHashes.length != inv.tipHashes.length ||
        session.lastReceivedRecentHashes.length !=
            inv.recentBlockHashes.length) {
      return false;
    }
    for (int i = 0; i < inv.tipHashes.length; i++) {
      if (session.lastReceivedTipHashes[i] != inv.tipHashes[i]) {
        return false;
      }
    }
    for (int i = 0; i < inv.recentBlockHashes.length; i++) {
      if (session.lastReceivedRecentHashes[i] != inv.recentBlockHashes[i]) {
        return false;
      }
    }
    return true;
  }

  /// Membersihkan seluruh resources, membatalkan subscription, dan mengosongkan sesi.
  void dispose() {
    _isDisposed = true;
    _isEnabled = false;
    _disposeListeners();
    _sessions.clear();
  }
}

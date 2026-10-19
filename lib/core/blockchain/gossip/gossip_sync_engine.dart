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
import '../blockchain_types.dart';
import '../blockdag_repository.dart';
import '../lightweight_blockdag_ledger.dart';
import 'gossip_codec.dart';
import 'gossip_constants.dart';
import 'gossip_messages.dart';
import 'gossip_privacy_sanitizer.dart';
import 'orphan_block_pool.dart';
import 'periodic_gossip_scheduler.dart';

/// State sesi gossip untuk satu endpoint peer 1-hop aktif.
class PeerGossipSession {
  final String sessionId;
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

  // Pelacakan permintaan blok aktif
  String? _activeRequestId;
  String? get activeRequestId => _activeRequestId;
  set activeRequestId(String? value) {
    _activeRequestId = value;
    if (value != null) {
      recordRecognizedRequestId(value);
    }
  }

  final Set<String> activeRequestedHashes = {};
  DateTime? activeRequestTime;

  /// Riwayat requestId permintaan blok yang diinisiasi atau diproses dalam sesi ini (maksimum 50 entri FIFO).
  ///
  /// Menjamin bahwa ACK tertunda (deferred ACK) hanya dapat dikirim jika requestId cocok
  /// dengan catatan permintaan sah dalam sesi ini (Stage 5E.4.5.2).
  final Set<String> recognizedRequestIds = {};

  // Pelacakan requestId dari DAG_GET_BLOCKS yang dilayani ke peer ini
  final Set<String> servedRequestIds = {};

  DateTime lastActivity;

  // Pelacakan rekonsiliasi periodik dan backoff (Stage 5E.4.6 & Stage 5E.4.6.1)
  /// Status apakah sesi ini sedang dalam proses eksekusi rekonsiliasi aktif (paling banyak 1 per sesi).
  bool isReconciling = false;

  /// Status apakah sesi ini sedang menunggu respons rekonsiliasi inventaris dari peer (Stage 5E.4.6.1).
  bool isAwaitingReconcileResponse = false;

  /// Identifier unik percobaan rekonsiliasi aktif saat ini untuk korelasi respons deterministik.
  String? activeReconcileAttemptId;

  /// Waktu inisiasi pengiriman rekonsiliasi inventaris terakhir.
  DateTime? reconcileAttemptTime;

  /// Waktu terakhir pesan respons valid diterima dari peer pada sesi ini.
  DateTime? lastPeerResponseTime;

  /// Waktu terakhir rekonsiliasi terkonfirmasi berhasil pada sesi ini.
  DateTime? lastReconcileConfirmedTime;

  /// Jumlah kegagalan beruntun pada transmisi atau respons rekonsiliasi ke peer ini.
  int consecutiveFailures = 0;

  /// Durasi jeda backoff saat ini setelah kegagalan rekonsiliasi.
  Duration currentBackoff = Duration.zero;

  /// Waktu paling awal di mana rekonsiliasi berikutnya boleh dijalankan untuk sesi ini.
  DateTime? nextEligibleReconcileTime;

  /// Waktu pelaksanaan rekonsiliasi periodik terakhir yang dicoba.
  DateTime? lastPeriodicReconcileTime;

  static int _sessionCounter = 0;

  PeerGossipSession({required this.endpointId, String? sessionId})
    : sessionId =
          sessionId ??
          '${endpointId}_${DateTime.now().toUtc().microsecondsSinceEpoch}_${++_sessionCounter}',
      lastActivity = DateTime.now().toUtc();

  void addServedRequestId(String reqId) {
    if (servedRequestIds.length >= 50) {
      servedRequestIds.remove(servedRequestIds.first);
    }
    servedRequestIds.add(reqId);
  }

  /// Mencatat requestId ke dalam riwayat permintaan yang diakui dalam sesi ini.
  void recordRecognizedRequestId(String reqId) {
    final trimmed = reqId.trim();
    if (trimmed.isNotEmpty) {
      if (recognizedRequestIds.length >= 50) {
        recognizedRequestIds.remove(recognizedRequestIds.first);
      }
      recognizedRequestIds.add(trimmed);
    }
  }

  void clearActiveRequest() {
    _activeRequestId = null;
    activeRequestedHashes.clear();
    activeRequestTime = null;
  }

  /// Membersihkan konteks percobaan rekonsiliasi aktif saat ini.
  void clearReconcileAttempt() {
    isAwaitingReconcileResponse = false;
    activeReconcileAttemptId = null;
    reconcileAttemptTime = null;
  }

  /// Mengembalikan state backoff ke kondisi awal (setelah rekonsiliasi berhasil).
  void resetBackoff() {
    consecutiveFailures = 0;
    currentBackoff = Duration.zero;
  }
}

/// Layanan modular sinkronisasi replikasi gossip BlockDAG SiagaMesh.
class DagGossipSyncEngine {
  final MeshTransport transport;
  final String localNodeId;
  final LightweightBlockdagLedger ledger;
  final BlockdagRepository? repository;
  final OrphanBlockPool? orphanPool;
  late final PeriodicGossipScheduler _scheduler;
  final DateTime Function() _nowProvider;

  bool _isEnabled = false;
  bool _isDisposed = false;
  StreamSubscription<TransportConnectionEvent>? _connectionSub;

  final Map<String, PeerGossipSession> _sessions = {};

  // Metrik instrumentasi lokal
  int _totalHelloSent = 0;
  int _totalHelloReceived = 0;
  int _totalInvSent = 0;
  int _totalInvReceived = 0;
  int _totalGetBlocksSent = 0;
  int _totalGetBlocksReceived = 0;
  int _totalBlockBatchSent = 0;
  int _totalBlockBatchReceived = 0;
  int _totalSyncAckSent = 0;
  int _totalSyncAckReceived = 0;
  int _totalRejectSent = 0;
  int _totalRejectReceived = 0;
  int _totalPrunedNoticeSent = 0;
  int _totalPrunedNoticeReceived = 0;
  int _totalRemoteBlocksAccepted = 0;
  int _totalRemoteBlocksRejected = 0;
  int _totalGossipBytesSent = 0;
  int _totalGossipBytesReceived = 0;

  // Metrik instrumentasi rekonsiliasi periodik (Stage 5E.4.6 & Stage 5E.4.6.1)
  int _totalPeriodicInvSent = 0;
  int _totalPeriodicSendSuccess = 0;
  int _totalPeriodicSendFailures = 0;
  int _totalPeerResponsesReceived = 0;
  int _totalPeriodicReconcileAttempts = 0;
  int _totalPeriodicReconcileConfirmed = 0;
  int _totalPeriodicReconcileTimeouts = 0;

  DagGossipSyncEngine({
    required this.transport,
    required this.localNodeId,
    required this.ledger,
    this.repository,
    OrphanBlockPool? orphanPool,
    bool enableOrphanPool = false,
    bool isEnabled = false,
    PeriodicGossipConfig? periodicConfig,
    PeriodicGossipScheduler? scheduler,
    DateTime Function()? nowProvider,
  }) : orphanPool = orphanPool ?? (enableOrphanPool ? OrphanBlockPool() : null),
       _nowProvider = nowProvider ?? (() => DateTime.now().toUtc()),
       _isEnabled = isEnabled {
    _scheduler =
        scheduler ??
        PeriodicGossipScheduler(
          config: periodicConfig ?? const PeriodicGossipConfig(),
          onReconcilePeer: (endpointId, [now]) =>
              reconcilePeer(endpointId, now),
          getEligibleEndpoints: _getEligibleEndpoints,
          nowProvider: _nowProvider,
        );
    if (_isEnabled) {
      _initListeners();
      _scheduler.start();
    }
  }

  bool get isEnabled => _isEnabled;

  /// Memeriksa apakah repositori penyimpanan persisten tersedia untuk mengomit blok remote.
  bool get hasPersistentStorage => repository != null;

  set isEnabled(bool value) {
    if (_isDisposed) return;
    if (_isEnabled == value) return;
    _isEnabled = value;
    if (_isEnabled) {
      _initListeners();
      _scheduler.start();
    } else {
      _scheduler.stop();
      _disposeListeners();
      _sessions.clear();
      orphanPool?.clear();
    }
  }

  bool get isDisposed => _isDisposed;

  int get totalHelloSent => _totalHelloSent;
  int get totalHelloReceived => _totalHelloReceived;
  int get totalInvSent => _totalInvSent;
  int get totalInvReceived => _totalInvReceived;
  int get totalGetBlocksSent => _totalGetBlocksSent;
  int get totalGetBlocksReceived => _totalGetBlocksReceived;
  int get totalBlockBatchSent => _totalBlockBatchSent;
  int get totalBlockBatchReceived => _totalBlockBatchReceived;
  int get totalSyncAckSent => _totalSyncAckSent;
  int get totalSyncAckReceived => _totalSyncAckReceived;
  int get totalRejectSent => _totalRejectSent;
  int get totalRejectReceived => _totalRejectReceived;
  int get totalPrunedNoticeSent => _totalPrunedNoticeSent;
  int get totalPrunedNoticeReceived => _totalPrunedNoticeReceived;
  int get totalRemoteBlocksAccepted => _totalRemoteBlocksAccepted;
  int get totalRemoteBlocksRejected => _totalRemoteBlocksRejected;
  int get totalGossipBytesSent => _totalGossipBytesSent;
  int get totalGossipBytesReceived => _totalGossipBytesReceived;

  // Getters rekonsiliasi periodik (Stage 5E.4.6 & Stage 5E.4.6.1)
  PeriodicGossipScheduler get scheduler => _scheduler;
  PeriodicGossipConfig get periodicConfig => _scheduler.config;

  /// Jumlah pengiriman pesan [DAG_INV] rekonsiliasi periodik yang berhasil di-dispatch ke transport lokal.
  int get totalPeriodicInvSent => _totalPeriodicInvSent;

  /// Jumlah percobaan pengiriman rekonsiliasi yang diterima oleh transport lokal (send success).
  int get totalPeriodicSendSuccess => _totalPeriodicSendSuccess;

  /// Jumlah kegagalan pengiriman pesan rekonsiliasi pada transport lokal.
  int get totalPeriodicSendFailures => _totalPeriodicSendFailures;

  /// Jumlah respons pesan gossip yang valid dan terverifikasi diterima dari peer pada sesi aktif (peer responsiveness).
  int get totalPeerResponsesReceived => _totalPeerResponsesReceived;

  /// Jumlah inisiasi rekonsiliasi periodik yang dicoba ke peer.
  int get totalPeriodicReconcileAttempts => _totalPeriodicReconcileAttempts;

  /// Jumlah rekonsiliasi periodik yang terkonfirmasi berhasil oleh respons valid peer dalam batas waktu (reconciliation confirmed).
  int get totalPeriodicReconcileConfirmed => _totalPeriodicReconcileConfirmed;

  /// Jumlah percobaan rekonsiliasi periodik yang kedaluwarsa tanpa respons dari peer (unresponsive peer timeout).
  int get totalPeriodicReconcileTimeouts => _totalPeriodicReconcileTimeouts;

  /// Alias semantik untuk rekonsiliasi yang terkonfirmasi berhasil (Stage 5E.4.6.1).
  ///
  /// CATATAN SEMANTIK: Metrik ini kini secara eksplisit mencerminkan keberhasilan rekonsiliasi
  /// yang dikonfirmasi oleh respons peer, BUKAN sekadar keberhasilan pengiriman paket lokal.
  int get totalPeriodicReconcileSuccess => _totalPeriodicReconcileConfirmed;

  /// Total kegagalan rekonsiliasi (kegagalan transport lokal + batas waktu respons peer terlampaui).
  int get totalPeriodicReconcileFailures =>
      _totalPeriodicSendFailures + _totalPeriodicReconcileTimeouts;

  List<String> _getEligibleEndpoints() {
    return _sessions.entries
        .where(
          (entry) =>
              entry.value.helloReceived && entry.value.remoteSchemaVersion == 1,
        )
        .map((entry) => entry.key)
        .toList();
  }

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
      final oldSession = _sessions.remove(event.endpointId);
      oldSession?.clearReconcileAttempt();
      _scheduler.onPeerDisconnected(event.endpointId);
      // Kebijakan Orphan Block Pool (Stage 5E.4.5):
      // Pemutusan koneksi peer (disconnect) TIDAK serta-merta membuang blok yatim dari orphanPool.
      // Blok yatim yang telah lolos validasi intrinsik tetap dipertahankan selama belum kedaluwarsa (TTL 60 detik)
      // karena parent yang hilang dapat diterima dari peer lain atau saat koneksi pulih kembali.
    }
  }

  /// Mengirimkan byte mentah ke transport dengan isolasi kesalahan dan metrik.
  Future<bool> _sendRawBytes(String endpointId, Uint8List bytes) async {
    if (!_isEnabled || _isDisposed) return false;
    try {
      final sent = await transport.sendBytes(
        endpointId: endpointId,
        bytes: bytes,
      );
      if (sent) {
        _totalGossipBytesSent += bytes.length;
      }
      return sent;
    } catch (e) {
      debugPrint(
        '[DagGossipSyncEngine] Exception saat mengirim bytes ke $endpointId: $e',
      );
      return false;
    }
  }

  /// Mengirimkan pesan protokol gossip bertipe ke peer tertentu.
  Future<bool> _sendMessage(String endpointId, DagGossipMessage msg) async {
    return _sendRawBytes(endpointId, DagGossipCodec.encode(msg));
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
    final sent = await _sendRawBytes(endpointId, bytes);

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
    final sent = await _sendRawBytes(endpointId, bytes);

    if (!_isEnabled || _isDisposed) return false;
    final currentSession = _sessions[endpointId];
    if (currentSession == null || currentSession != session) {
      return false;
    }

    if (sent) {
      session.invSent = true;
      session.lastActivity = DateTime.now().toUtc();
      _totalInvSent++;
    }
    return sent;
  }

  /// Meminta blok yang belum dimiliki ([missingBlockHashes]) dari peer tertentu.
  ///
  /// Mengambil maksimal [kMaxGetBlocksHashes] (4) hash per permintaan dan melacak requestId aktif.
  Future<bool> requestMissingBlocks(String endpointId) async {
    if (!_isEnabled || _isDisposed) return false;
    final session = _sessions[endpointId];
    if (session == null) return false;
    return _sendGetBlocks(endpointId, session);
  }

  /// Mengirimkan pesan [DAG_GET_BLOCKS] untuk meminta blok yang belum dimiliki.
  Future<bool> _sendGetBlocks(
    String endpointId,
    PeerGossipSession session,
  ) async {
    if (!_isEnabled || _isDisposed) return false;
    if (session.activeRequestId != null) {
      // Menghindari meminta hash ketika permintaan sebelumnya masih dalam status in-flight
      return false;
    }

    // Bersihkan kandidat hash yang ternyata sudah dimiliki di ledger lokal
    session.missingBlockHashes.removeWhere((hash) {
      final existsInActive = ledger.getBlock(hash) != null;
      final existsInProcessed = ledger.processedBlockHashes.contains(hash);
      final existsInCheckpoints = ledger.checkpoints.any(
        (c) =>
            c.retainedGenesisHash == hash || c.prunedBlockHashes.contains(hash),
      );
      if (existsInActive || existsInProcessed || existsInCheckpoints) {
        session.knownPeerBlockHashes.add(hash);
        return true;
      }
      return false;
    });

    if (session.missingBlockHashes.isEmpty) {
      return false;
    }

    // Minta paling banyak kMaxGetBlocksHashes (4) per permintaan
    final hashesToRequest = session.missingBlockHashes
        .take(kMaxGetBlocksHashes)
        .toList();

    final requestId =
        'req-$localNodeId-${DateTime.now().toUtc().microsecondsSinceEpoch}';

    session.activeRequestId = requestId;
    session.activeRequestedHashes.clear();
    session.activeRequestedHashes.addAll(hashesToRequest);
    session.activeRequestTime = DateTime.now().toUtc();

    final getBlocksMsg = DagGetBlocksMessage(
      senderNodeId: localNodeId,
      requestId: requestId,
      requestedBlockHashes: hashesToRequest,
    );

    final bytes = DagGossipCodec.encode(getBlocksMsg);
    final sent = await _sendRawBytes(endpointId, bytes);

    if (!_isEnabled || _isDisposed) {
      session.clearActiveRequest();
      return false;
    }

    final currentSession = _sessions[endpointId];
    if (currentSession == null || currentSession != session) {
      return false;
    }

    if (sent) {
      _totalGetBlocksSent++;
      session.lastActivity = DateTime.now().toUtc();
    } else {
      // Jika transmisi gagal, bersihkan activeRequestId agar dapat dicoba lagi
      session.clearActiveRequest();
    }
    return sent;
  }

  /// Menangani pesan [DAG_GET_BLOCKS] pada node sumber: menyajikan blok yang tersedia.
  Future<void> _handleGetBlocks(
    String endpointId,
    PeerGossipSession session,
    DagGetBlocksMessage msg,
  ) async {
    session.remoteNodeId ??= msg.senderNodeId;
    session.addServedRequestId(msg.requestId);
    final availableBlocks = <SecurityBlock>[];
    final prunedHashes = <String>[];

    for (final hash in msg.requestedBlockHashes) {
      final block = ledger.getBlock(hash);
      if (block != null) {
        // Terapkan filter privasi sebelum menyertakan blok
        final privacyRes = GossipPrivacySanitizer.validateBlock(block);
        if (privacyRes.isCompliant) {
          availableBlocks.add(block);
        } else {
          debugPrint(
            '[DagGossipSyncEngine] Blok $hash melanggar aturan privasi: ${privacyRes.violationReason}',
          );
        }
      } else {
        // Periksa apakah blok sudah dipangkas (pruned) pada checkpoint
        final isPruned = ledger.checkpoints.any(
          (c) =>
              c.retainedGenesisHash == hash ||
              c.prunedBlockHashes.contains(hash),
        );
        if (isPruned) {
          prunedHashes.add(hash);
        }
      }
    }

    // Jika blok yang diminta telah dipangkas dan tidak ada blok aktif yang dapat disajikan
    if (availableBlocks.isEmpty && prunedHashes.isNotEmpty) {
      final lastCheckpoint = ledger.checkpoints.isNotEmpty
          ? ledger.checkpoints.last
          : null;
      final notice = DagPrunedNoticeMessage(
        senderNodeId: localNodeId,
        requestId: msg.requestId,
        prunedBlockHashes: prunedHashes,
        lastPrunedIndex: lastCheckpoint?.lastPrunedIndex ?? 0,
        retainedGenesisHash:
            lastCheckpoint?.retainedGenesisHash ??
            ledger.genesisBlock.blockHash,
      );
      final sent = await _sendMessage(endpointId, notice);
      if (sent) _totalPrunedNoticeSent++;
      return;
    }

    // Jika tidak ada satupun blok yang ditemukan (unknown hashes)
    if (availableBlocks.isEmpty) {
      final reject = DagRejectMessage(
        senderNodeId: localNodeId,
        requestId: msg.requestId,
        errorCode: DagRejectCode.emptyPayload,
        errorMessage:
            'Tidak ada blok yang dapat disajikan untuk hash yang diminta',
      );
      final sent = await _sendMessage(endpointId, reject);
      if (sent) _totalRejectSent++;
      return;
    }

    // Urutkan blok secara topologis berdasarkan index ascending (kausalitas parent -> child)
    availableBlocks.sort((a, b) => a.index.compareTo(b.index));

    // Batasi jumlah blok per batch hingga kMaxBlocksPerBatch (4)
    final blocksToSend = availableBlocks.take(kMaxBlocksPerBatch).toList();

    // Buat pesan batch (batchIndex = 1, totalBatches = 1 karena 1-indexed)
    final batchMsg = DagBlockBatchMessage(
      senderNodeId: localNodeId,
      requestId: msg.requestId,
      batchIndex: 1,
      totalBatches: 1,
      blocks: blocksToSend,
    );

    final encodedBytes = DagGossipCodec.encode(batchMsg);

    // Periksa batas ukuran paket batch (16 KiB = 16384 bytes)
    if (encodedBytes.length > kMaxBatchPayloadBytes) {
      // Jika ukuran batch melebihi 16 KiB, coba kurangi menjadi 1 blok jika memungkinkan
      if (blocksToSend.length > 1) {
        final singleBlockBatch = DagBlockBatchMessage(
          senderNodeId: localNodeId,
          requestId: msg.requestId,
          batchIndex: 1,
          totalBatches: 1,
          blocks: [blocksToSend.first],
        );
        final singleBytes = DagGossipCodec.encode(singleBlockBatch);
        if (singleBytes.length <= kMaxBatchPayloadBytes) {
          final sent = await _sendRawBytes(endpointId, singleBytes);
          if (sent) _totalBlockBatchSent++;
          return;
        }
      }

      // Jika bahkan 1 blok melebihi 16 KiB, jangan pernah memotong bytes atau merusak integritas hash!
      // Kirim pesan DAG_REJECT resmi dengan kode BATCH_PAYLOAD_TOO_LARGE
      final reject = DagRejectMessage(
        senderNodeId: localNodeId,
        requestId: msg.requestId,
        errorCode: DagRejectCode.batchPayloadTooLarge,
        errorMessage:
            'Ukuran serialisasi batch (${encodedBytes.length} bytes) melampaui batas $kMaxBatchPayloadBytes bytes',
      );
      final sent = await _sendMessage(endpointId, reject);
      if (sent) _totalRejectSent++;
      return;
    }

    final sent = await _sendRawBytes(endpointId, encodedBytes);
    if (sent) {
      _totalBlockBatchSent++;
    }

    // Jika sebagian blok yang diminta telah dipangkas, kirim juga DAG_PRUNED_NOTICE
    if (prunedHashes.isNotEmpty) {
      final lastCheckpoint = ledger.checkpoints.isNotEmpty
          ? ledger.checkpoints.last
          : null;
      final notice = DagPrunedNoticeMessage(
        senderNodeId: localNodeId,
        requestId: msg.requestId,
        prunedBlockHashes: prunedHashes,
        lastPrunedIndex: lastCheckpoint?.lastPrunedIndex ?? 0,
        retainedGenesisHash:
            lastCheckpoint?.retainedGenesisHash ??
            ledger.genesisBlock.blockHash,
      );
      final sentNotice = await _sendMessage(endpointId, notice);
      if (sentNotice) _totalPrunedNoticeSent++;
    }
  }

  /// Menangani pesan [DAG_BLOCK_BATCH] pada node penerima: validasi dan ingestion ke ledger.
  Future<void> _handleBlockBatch(
    String endpointId,
    PeerGossipSession session,
    DagBlockBatchMessage batch,
  ) async {
    // 1. Validasi requestId: abaikan jika tidak cocok dengan activeRequestId sesi ini
    if (session.activeRequestId == null ||
        batch.requestId != session.activeRequestId) {
      debugPrint(
        '[DagGossipSyncEngine] Mengabaikan DAG_BLOCK_BATCH dari $endpointId: '
        'requestId "${batch.requestId}" tidak cocok dengan activeRequestId "${session.activeRequestId}"',
      );
      return;
    }

    session.remoteNodeId ??= batch.senderNodeId;
    session.recordRecognizedRequestId(batch.requestId);

    // Ambil snapshot ledger sebelum mutasi apa pun untuk jaminan rollback jika persistensi gagal
    final preIngestSnapshot = ledger.exportPersistedState();

    final tentativelyAcceptedBlocks = <SecurityBlock>[];
    final rejectedHashes = <String>[];
    String? firstRejectCode;
    String? firstRejectMessage;

    for (final block in batch.blocks) {
      // 2. Allowlist privasi pada metadata blok dan event
      final privacyRes = GossipPrivacySanitizer.validateBlock(block);
      if (!privacyRes.isCompliant) {
        _totalRemoteBlocksRejected++;
        rejectedHashes.add(block.blockHash);
        firstRejectCode ??= DagRejectCode.privacyViolation;
        firstRejectMessage ??= privacyRes.violationReason;
        continue;
      }

      // 3. Tolak blok duplikat tanpa mutasi ganda (sudah tersimpan sebelumnya)
      if (ledger.processedBlockHashes.contains(block.blockHash)) {
        session.missingBlockHashes.remove(block.blockHash);
        session.knownPeerBlockHashes.add(block.blockHash);
        continue;
      }

      // 4. Validasi intrinsik blok (format hash, kriptografi Merkle root & header hash, dsb.)
      final intrinsicRes = ledger.validateBlockIntrinsic(block);
      if (!intrinsicRes.isValid) {
        debugPrint(
          '[DagGossipSyncEngine] Blok ${block.blockHash} gagal validasi intrinsik: ${intrinsicRes.status} - ${intrinsicRes.message}',
        );
        _totalRemoteBlocksRejected++;
        rejectedHashes.add(block.blockHash);
        firstRejectCode ??= _mapLedgerStatusToRejectCode(intrinsicRes.status);
        firstRejectMessage ??= intrinsicRes.message;
        continue;
      }

      // 5. Validasi ketersediaan parent di ledger aktif atau checkpoint
      final fullValRes = ledger.validateBlock(block);
      if (fullValRes.isValid) {
        // Parent lengkap dan valid: terima ke dalam ledger
        final addResult = ledger.acceptRemoteBlock(block);
        if (addResult.isValid) {
          tentativelyAcceptedBlocks.add(block);
        } else {
          _totalRemoteBlocksRejected++;
          rejectedHashes.add(block.blockHash);
          firstRejectCode ??= _mapLedgerStatusToRejectCode(addResult.status);
          firstRejectMessage ??= addResult.message;
        }
      } else if (fullValRes.status == LedgerValidationStatus.missingParent) {
        final pool = orphanPool;
        if (pool != null) {
          // Blok valid secara intrinsik tapi satu atau lebih parent belum ada di ledger!
          // Tahan di Orphan Block Pool (Stage 5E.4.5)
          final missingParents = block.parentBlockHashes.where((p) {
            final inActive = ledger.getBlock(p) != null;
            final inCheckpoint = ledger.checkpoints.any(
              (c) =>
                  c.retainedGenesisHash == p || c.prunedBlockHashes.contains(p),
            );
            return !inActive && !inCheckpoint;
          }).toSet();

          final addResult = pool.add(
            block: block,
            missingParentHashes: missingParents,
            peerEndpointId: endpointId,
            peerNodeId: session.remoteNodeId ?? batch.senderNodeId,
            sessionId: session.sessionId,
            requestId: batch.requestId,
          );

          if (addResult.isAdded) {
            debugPrint(
              '[DagGossipSyncEngine] Blok ${block.blockHash} ditahan di orphan pool (menunggu parent: $missingParents)',
            );
            // Tambahkan parent yang hilang ke missingBlockHashes sesi agar dapat diminta
            session.missingBlockHashes.addAll(missingParents);
            session.missingBlockHashes.remove(block.blockHash);
          } else if (addResult.isDuplicate) {
            session.missingBlockHashes.remove(block.blockHash);
          } else {
            // Pool penuh atau kuota per-peer habis
            debugPrint(
              '[DagGossipSyncEngine] Gagal menahan blok orphan ${block.blockHash}: ${addResult.status} - ${addResult.message}',
            );
            _totalRemoteBlocksRejected++;
            rejectedHashes.add(block.blockHash);
            firstRejectCode ??= DagRejectCode.invalidBlockStructure;
            firstRejectMessage ??= addResult.message;
          }
        } else {
          // Orphan pool nonaktif (mode default / backward-compatible Stage 5E.4.4):
          // Blok dengan missing parent langsung ditolak
          debugPrint(
            '[DagGossipSyncEngine] Blok ${block.blockHash} ditolak karena missing parent (orphan pool nonaktif)',
          );
          _totalRemoteBlocksRejected++;
          rejectedHashes.add(block.blockHash);
          firstRejectCode ??= DagRejectCode.invalidBlockStructure;
          firstRejectMessage ??= fullValRes.message;
        }
      } else {
        // Pelanggaran aturan validasi lainnya (misal: index <= parent index atau timestamp mendahului parent)
        debugPrint(
          '[DagGossipSyncEngine] Blok ${block.blockHash} ditolak oleh ledger: ${fullValRes.status} - ${fullValRes.message}',
        );
        _totalRemoteBlocksRejected++;
        rejectedHashes.add(block.blockHash);
        firstRejectCode ??= _mapLedgerStatusToRejectCode(fullValRes.status);
        firstRejectMessage ??= fullValRes.message;
      }
    }

    // 6. Persistensikan state ke repository jika terdapat blok yang berhasil divalidasi
    final confirmedAcceptedHashes = <String>[];
    bool persistSuccess = false;

    if (tentativelyAcceptedBlocks.isNotEmpty) {
      if (repository == null) {
        // Kontrak Persistensi Stage 5E.4.5.1:
        // Engine replikasi aktif tanpa repository TIDAK BOLEH menganggap persistensi berhasil.
        // Blok yang tidak dapat dipersistensikan TIDAK BOLEH di-ACK.
        persistSuccess = false;
        ledger.restoreFromPersistedState(preIngestSnapshot);
        debugPrint(
          '[DagGossipSyncEngine] repository tidak tersedia: batch ${batch.requestId} dibatalkan dan di-rollback (tidak ada ACK dikirim)',
        );
      } else {
        try {
          final saved = await repository!.saveState(
            ledger.exportPersistedState(),
          );
          if (saved) {
            persistSuccess = true;
          } else {
            persistSuccess = false;
            debugPrint(
              '[DagGossipSyncEngine] repository.saveState() mengembalikan false untuk batch ${batch.requestId}',
            );
          }
        } catch (e) {
          persistSuccess = false;
          debugPrint(
            '[DagGossipSyncEngine] Exception saat repository.saveState(): $e',
          );
        }

        if (!persistSuccess) {
          // ROLLBACK: Batalkan seluruh mutasi ledger in-memory kembali ke snapshot sebelum batch.
          // Blok yang gagal disimpan TIDAK dihitung sebagai accepted,
          // TIDAK dimasukkan ke confirmedAcceptedHashes,
          // TIDAK dihapus dari session.missingBlockHashes (tetap dapat diminta ulang setelah storage pulih),
          // dan TIDAK dimasukkan ke session.knownPeerBlockHashes.
          ledger.restoreFromPersistedState(preIngestSnapshot);
        } else {
          // Penyimpanan persisten BERHASIL: konfirmasi seluruh blok yang tersimpan
          for (final block in tentativelyAcceptedBlocks) {
            _totalRemoteBlocksAccepted++;
            confirmedAcceptedHashes.add(block.blockHash);
            session.missingBlockHashes.remove(block.blockHash);
            session.knownPeerBlockHashes.add(block.blockHash);
          }
        }
      }
    } else {
      persistSuccess = true;
    }

    // 7. Jika persistensi sukses, evaluasi dan proses orphan pool yang parent-nya baru saja tiba (Stage 5E.4.5)
    if (persistSuccess) {
      final promotedOrphans = await processOrphans(endpointId, session);
      for (final orphan in promotedOrphans) {
        // Jika orphan ini berasal dari batch yang sama (misal child diletakkan sebelum parent dalam batch)
        if (batch.blocks.any((b) => b.blockHash == orphan.blockHash)) {
          confirmedAcceptedHashes.add(orphan.blockHash);
        }
      }
    }

    // Blok yang secara permanen ditolak oleh validasi ledger/privasi dibersihkan dari missingBlockHashes
    if (rejectedHashes.isNotEmpty) {
      session.missingBlockHashes.removeAll(rejectedHashes);
    }

    // Bersihkan active request dari sesi peminta agar tidak terkunci
    session.clearActiveRequest();

    // 8. Kirim respons konfirmasi (ACK) HANYA untuk blok yang benar-benar berhasil dipersistensikan
    if (confirmedAcceptedHashes.isNotEmpty) {
      final tips = ledger.tipHashes.toList()..sort();
      final effectiveTips = tips.isEmpty
          ? [ledger.genesisBlock.blockHash]
          : tips;

      final ack = DagSyncAckMessage(
        senderNodeId: localNodeId,
        requestId: batch.requestId,
        acceptedBlockHashes: confirmedAcceptedHashes,
        newTipHashes: effectiveTips,
      );
      final sent = await _sendMessage(endpointId, ack);
      if (sent) _totalSyncAckSent++;
    } else if (rejectedHashes.isNotEmpty && persistSuccess) {
      // Hanya kirim DAG_REJECT jika penolakan disebabkan oleh isi blok (bukan kegagalan penyimpanan lokal)
      final reject = DagRejectMessage(
        senderNodeId: localNodeId,
        requestId: batch.requestId,
        rejectedHash: rejectedHashes.first,
        errorCode: firstRejectCode ?? DagRejectCode.invalidBlockStructure,
        errorMessage:
            firstRejectMessage ?? 'Blok remote ditolak oleh validasi ledger',
      );
      final sent = await _sendMessage(endpointId, reject);
      if (sent) _totalRejectSent++;
    }

    // 9. Jika persistensi sukses dan masih ada hash kandidat yang belum dimiliki, minta batch berikutnya.
    // MENCEGAH INFINITE RETRY LOOP: Jangan memicu permintaan berikutnya jika penyimpanan lokal gagal!
    if (persistSuccess && session.missingBlockHashes.isNotEmpty) {
      await _sendGetBlocks(endpointId, session);
    }
  }

  /// Memproses ulang blok yatim di [orphanPool] yang seluruh parent-nya telah tersedia di ledger.
  ///
  /// Dilakukan secara berulang (*iterative resolution*) untuk menangani rantai orphan bertingkat
  /// (misal: C menunggu B, B menunggu A).
  Future<List<SecurityBlock>> processOrphans([
    String? currentEndpointId,
    PeerGossipSession? currentSession,
  ]) async {
    final pool = orphanPool;
    if (pool == null) return const [];

    final promotedBlocks = <SecurityBlock>[];

    bool anyPromoted = true;
    while (anyPromoted) {
      anyPromoted = false;
      final ready = pool.getReadyOrphans(ledger);
      if (ready.isEmpty) break;

      for (final entry in ready) {
        final candidate = entry.block;

        // 1. Validasi penuh terhadap ledger sekarang setelah parent seharusnya ada
        final valRes = ledger.validateBlock(candidate);
        if (!valRes.isValid) {
          if (valRes.status == LedgerValidationStatus.missingParent) {
            // Masih ada parent yang belum lengkap
            continue;
          }
          // Ditolak permanen (misal: parent tiba tapi timestamp/indeks melanggar aturan DAG)
          debugPrint(
            '[DagGossipSyncEngine] Orphan ${candidate.blockHash} ditolak permanen: ${valRes.status} - ${valRes.message}',
          );
          pool.remove(candidate.blockHash);
          _totalRemoteBlocksRejected++;
          continue;
        }

        // 2. Simpan snapshot sebelum mutasi untuk jaminan rollback jika persistensi gagal
        final preSnapshot = ledger.exportPersistedState();
        final acceptRes = ledger.acceptRemoteBlock(candidate);
        if (!acceptRes.isValid) {
          pool.remove(candidate.blockHash);
          _totalRemoteBlocksRejected++;
          continue;
        }

        // 3. Persistensi ke repository (Kontrak Stage 5E.4.5.1)
        bool saved = false;
        if (repository != null) {
          try {
            saved = await repository!.saveState(ledger.exportPersistedState());
          } catch (e) {
            saved = false;
            debugPrint(
              '[DagGossipSyncEngine] Exception saat repository.saveState() untuk orphan ${candidate.blockHash}: $e',
            );
          }
        } else {
          debugPrint(
            '[DagGossipSyncEngine] repository tidak tersedia: orphan ${candidate.blockHash} tidak dapat dipromosikan tanpa penyimpanan persisten',
          );
        }

        if (!saved) {
          // ROLLBACK: Batalkan mutasi in-memory dan JANGAN hapus dari pool
          // Blok tetap berada di orphan pool agar dapat dicoba lagi setelah storage pulih / repository tersedia.
          ledger.restoreFromPersistedState(preSnapshot);
          return promotedBlocks;
        }

        // 4. Sukses diterima dan disimpan persisten
        pool.remove(candidate.blockHash);
        _totalRemoteBlocksAccepted++;
        promotedBlocks.add(candidate);
        anyPromoted = true;

        // Perbarui missing dan known hashes pada sesi peer
        final peerSession =
            _sessions[entry.peerEndpointId] ??
            (entry.peerEndpointId == currentEndpointId ? currentSession : null);
        if (peerSession != null) {
          peerSession.missingBlockHashes.remove(candidate.blockHash);
          peerSession.knownPeerBlockHashes.add(candidate.blockHash);
        }

        // 5. Kirim DAG_SYNC_ACK jika orphan ini berasal dari request sebelumnya yang belum di-ACK (Stage 5E.4.5.1 & 5E.4.5.2)
        final reqId = entry.requestId?.trim();
        final peerEndpointId = entry.peerEndpointId.trim();

        if (reqId != null && reqId.isNotEmpty && peerEndpointId.isNotEmpty) {
          final targetPeerSession =
              _sessions[peerEndpointId] ??
              (peerEndpointId == currentEndpointId ? currentSession : null);

          // Pengecekan Keketatan Korelasi Sesi & Request (Stage 5E.4.5.2):
          //
          // 1. sessionId orphan TIDAK BOLEH null atau kosong (wildcard dilarang)
          final hasValidSessionId =
              entry.sessionId != null && entry.sessionId!.trim().isNotEmpty;

          // 2. Sesi asal harus masih aktif dan sessionId harus cocok secara eksplisit
          final isSameSession =
              targetPeerSession != null &&
              hasValidSessionId &&
              targetPeerSession.sessionId == entry.sessionId;

          // 3. Jika identitas remoteNodeId pada request diketahui (entry.peerNodeId),
          //    target session harus memiliki remoteNodeId yang cocok secara eksplisit.
          //    Jika konteks request tidak lengkap atau ambigu, jangan mengirim ACK.
          final isPeerNodeMatched =
              targetPeerSession != null &&
              entry.peerNodeId != null &&
              entry.peerNodeId!.trim().isNotEmpty &&
              targetPeerSession.remoteNodeId != null &&
              targetPeerSession.remoteNodeId == entry.peerNodeId;

          // 4. Request ID harus cocok dengan catatan request yang relevan pada sesi ini
          final isRequestIdRecognized =
              targetPeerSession != null &&
              targetPeerSession.recognizedRequestIds.contains(reqId);

          // 5. Request ID tidak boleh sama dengan activeRequestId sesi saat ini
          //    (karena batch aktif saat ini di-ACK secara langsung oleh _handleBlockBatch)
          final isNotActiveBatchRequest =
              currentSession == null || reqId != currentSession.activeRequestId;

          if (isSameSession &&
              isPeerNodeMatched &&
              isRequestIdRecognized &&
              isNotActiveBatchRequest) {
            final tips = ledger.tipHashes.toList()..sort();
            final effectiveTips = tips.isEmpty
                ? [ledger.genesisBlock.blockHash]
                : tips;
            final orphanAck = DagSyncAckMessage(
              senderNodeId: localNodeId,
              requestId: reqId,
              acceptedBlockHashes: [candidate.blockHash],
              newTipHashes: effectiveTips,
            );
            final sent = await _sendMessage(peerEndpointId, orphanAck);
            if (sent) _totalSyncAckSent++;
          } else {
            // Catat alasan penolakan ACK tertunda secara aman (Stage 5E.4.5.2)
            final reason = !hasValidSessionId
                ? 'sessionId orphan null/kosong (wildcard dilarang)'
                : targetPeerSession == null
                ? 'sesi peer asal sudah terputus'
                : targetPeerSession.sessionId != entry.sessionId
                ? 'sessionId berbeda setelah reconnect/berganti sesi (${entry.sessionId} vs ${targetPeerSession.sessionId})'
                : !isPeerNodeMatched
                ? 'peerNodeId tidak cocok atau konteks remoteNodeId tidak lengkap (${entry.peerNodeId} vs ${targetPeerSession.remoteNodeId})'
                : !isRequestIdRecognized
                ? 'requestId "$reqId" tidak tercatat dalam riwayat permintaan sesi ini'
                : 'requestId cocok dengan batch aktif saat ini (di-ACK langsung)';

            debugPrint(
              '[DagGossipSyncEngine] Tidak mengirim DAG_SYNC_ACK tertunda untuk orphan ${candidate.blockHash}: $reason. '
              'Kebijakan retry: blok tetap tersimpan persisten; peer akan melakukan rekonsiliasi via inventaris DAG_INV saat tersambung kembali.',
            );
          }
        } else {
          debugPrint(
            '[DagGossipSyncEngine] Tidak mengirim DAG_SYNC_ACK tertunda untuk orphan ${candidate.blockHash}: '
            'konteks requestId atau peerEndpointId tidak lengkap atau ambigu. '
            'Kebijakan retry: blok tetap tersimpan persisten; rekonsiliasi dilakukan via DAG_INV.',
          );
        }
      }
    }

    return promotedBlocks;
  }

  /// Menangani konfirmasi penerimaan [DAG_SYNC_ACK] dari peer.
  void _handleSyncAck(
    String endpointId,
    PeerGossipSession session,
    DagSyncAckMessage ack,
  ) {
    // Validasi bahwa requestId pada ACK sesuai dengan batch yang pernah dilayani untuk peer ini
    if (!session.servedRequestIds.contains(ack.requestId)) {
      debugPrint(
        '[DagGossipSyncEngine] Mengabaikan DAG_SYNC_ACK dari $endpointId: '
        'requestId "${ack.requestId}" tidak cocok dengan request yang pernah dilayani',
      );
      return;
    }
    _totalSyncAckReceived++;
    session.servedRequestIds.remove(ack.requestId);
    session.knownPeerBlockHashes.addAll(ack.acceptedBlockHashes);
    if (ack.newTipHashes.isNotEmpty) {
      session.lastReceivedTipHashes = List.from(ack.newTipHashes);
    }
  }

  /// Menangani penolakan [DAG_REJECT] dari peer.
  void _handleReject(
    String endpointId,
    PeerGossipSession session,
    DagRejectMessage reject,
  ) {
    _totalRejectReceived++;
    if (reject.requestId != null &&
        reject.requestId == session.activeRequestId) {
      if (reject.rejectedHash != null) {
        session.missingBlockHashes.remove(reject.rejectedHash);
      }
      session.clearActiveRequest();
    }
  }

  /// Menangani pemberitahuan pemangkasan blok [DAG_PRUNED_NOTICE] dari peer.
  Future<void> _handlePrunedNotice(
    String endpointId,
    PeerGossipSession session,
    DagPrunedNoticeMessage prunedNotice,
  ) async {
    _totalPrunedNoticeReceived++;
    session.missingBlockHashes.removeAll(prunedNotice.prunedBlockHashes);
    if (prunedNotice.requestId == session.activeRequestId) {
      session.clearActiveRequest();
      if (session.missingBlockHashes.isNotEmpty) {
        await _sendGetBlocks(endpointId, session);
      }
    }
  }

  /// Memetakan [LedgerValidationStatus] ke kode penolakan protokol [DagRejectCode].
  static String _mapLedgerStatusToRejectCode(LedgerValidationStatus status) {
    switch (status) {
      case LedgerValidationStatus.unsupportedVersion:
        return DagRejectCode.unsupportedVersion;
      case LedgerValidationStatus.invalidHashFormat:
      case LedgerValidationStatus.invalidHeaderHash:
        return DagRejectCode.invalidHashFormat;
      case LedgerValidationStatus.invalidMerkleRoot:
        return DagRejectCode.invalidMerkleRoot;
      case LedgerValidationStatus.invalidStructure:
      case LedgerValidationStatus.missingParent:
      case LedgerValidationStatus.duplicateBlock:
      case LedgerValidationStatus.duplicateEvent:
      case LedgerValidationStatus.timestampOutOfBounds:
        return DagRejectCode.invalidBlockStructure;
      case LedgerValidationStatus.valid:
        return '';
    }
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
      if (decodeRes.errorCode == DagRejectCode.privacyViolation) {
        _totalRemoteBlocksRejected++;
        final rawReqId = map['requestId'];
        if (rawReqId is String && rawReqId.isNotEmpty) {
          final reject = DagRejectMessage(
            senderNodeId: localNodeId,
            requestId: rawReqId,
            errorCode: DagRejectCode.privacyViolation,
            errorMessage:
                decodeRes.errorMessage ?? 'Privacy violation in block',
          );
          await _sendMessage(endpointId, reject);
          _totalRejectSent++;
        }
      }
      return;
    }

    final message = decodeRes.message!;
    final session = _sessions.putIfAbsent(
      endpointId,
      () => PeerGossipSession(endpointId: endpointId),
    );
    session.lastActivity = _nowProvider();

    // Catat responsivitas peer jika identitas pengirim cocok dengan remoteNodeId sesi (Stage 5E.4.6.1)
    final isMatchingSender =
        session.remoteNodeId == null ||
        session.remoteNodeId!.isEmpty ||
        session.remoteNodeId == message.senderNodeId;
    if (isMatchingSender) {
      _totalPeerResponsesReceived++;
      session.lastPeerResponseTime = _nowProvider();
    }

    switch (message.type) {
      case DagGossipMessageType.hello:
        final hello = message as DagHelloMessage;
        _totalHelloReceived++;

        // Validasi kompatibilitas genesis hash dan schema version
        if (hello.genesisHash != ledger.genesisBlock.blockHash ||
            hello.schemaVersion != 1) {
          // Jangan memproses peer dengan jaringan/skema yang tidak kompatibel; bersihkan sesi
          final old = _sessions.remove(endpointId);
          old?.clearReconcileAttempt();
          _scheduler.onPeerDisconnected(endpointId);
          return;
        }

        session.remoteNodeId ??= hello.senderNodeId;
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
          _tryConfirmReconciliationFromPeer(
            endpointId: endpointId,
            session: session,
            message: pending,
            receivedTime: _nowProvider(),
          );
          await _processInv(session, pending);
        }

        // Inisialisasi jadwal rekonsiliasi periodik pertama setelah handshake selesai
        final jitter = _scheduler.config.computeJitter(endpointId);
        final initialInterval = _scheduler.config.interval + jitter;
        session.nextEligibleReconcileTime = _nowProvider().add(initialInterval);

        // Beritahu scheduler bahwa sesi peer telah siap dan kompatibel untuk rekonsiliasi periodik
        _scheduler.onPeerReady(endpointId, initialInterval);
        break;

      case DagGossipMessageType.inv:
        final inv = message as DagInvMessage;
        _totalInvReceived++;

        // Validasi identitas pengirim: jika remoteNodeId telah diverifikasi, senderNodeId WAJIB cocok
        if (session.remoteNodeId != null &&
            session.remoteNodeId!.isNotEmpty &&
            inv.senderNodeId != session.remoteNodeId) {
          debugPrint(
            '[DagGossipSyncEngine] Mengabaikan DAG_INV dari $endpointId: '
            'senderNodeId "${inv.senderNodeId}" tidak cocok dengan remoteNodeId "${session.remoteNodeId}"',
          );
          return;
        }
        session.remoteNodeId ??= inv.senderNodeId;

        // Validasi urutan protokol: jika DAG_HELLO yang kompatibel belum diterima,
        // tahan inventaris di pendingInv hingga DAG_HELLO yang valid diverifikasi
        if (!session.helloReceived) {
          session.pendingInv = inv;
          if (!session.helloSent) {
            await _sendHello(endpointId, session);
          }
          return;
        }

        _tryConfirmReconciliationFromPeer(
          endpointId: endpointId,
          session: session,
          message: inv,
          receivedTime: _nowProvider(),
        );

        await _processInv(session, inv);
        break;

      case DagGossipMessageType.getBlocks:
        final getBlocks = message as DagGetBlocksMessage;
        _totalGetBlocksReceived++;
        if (session.remoteNodeId != null &&
            session.remoteNodeId!.isNotEmpty &&
            getBlocks.senderNodeId != session.remoteNodeId) {
          debugPrint(
            '[DagGossipSyncEngine] Mengabaikan DAG_GET_BLOCKS dari $endpointId: '
            'senderNodeId "${getBlocks.senderNodeId}" tidak cocok dengan remoteNodeId "${session.remoteNodeId}"',
          );
          return;
        }
        session.remoteNodeId ??= getBlocks.senderNodeId;

        _tryConfirmReconciliationFromPeer(
          endpointId: endpointId,
          session: session,
          message: getBlocks,
          receivedTime: _nowProvider(),
        );

        await _handleGetBlocks(endpointId, session, getBlocks);
        break;

      case DagGossipMessageType.blockBatch:
        final batch = message as DagBlockBatchMessage;
        _totalBlockBatchReceived++;
        await _handleBlockBatch(endpointId, session, batch);
        break;

      case DagGossipMessageType.syncAck:
        final ack = message as DagSyncAckMessage;
        // Invariant: DAG_SYNC_ACK memiliki semantik penerimaan blok dan TIDAK mengonfirmasi rekonsiliasi inventaris!
        _handleSyncAck(endpointId, session, ack);
        break;

      case DagGossipMessageType.reject:
        final reject = message as DagRejectMessage;
        if (session.remoteNodeId != null &&
            session.remoteNodeId!.isNotEmpty &&
            reject.senderNodeId != session.remoteNodeId) {
          return;
        }
        _tryConfirmReconciliationFromPeer(
          endpointId: endpointId,
          session: session,
          message: reject,
          receivedTime: _nowProvider(),
        );
        _handleReject(endpointId, session, reject);
        break;

      case DagGossipMessageType.prunedNotice:
        final pruned = message as DagPrunedNoticeMessage;
        await _handlePrunedNotice(endpointId, session, pruned);
        break;
    }
  }

  /// Memproses perbandingan hash inventaris [DAG_INV] terhadap status ledger lokal.
  Future<void> _processInv(PeerGossipSession session, DagInvMessage inv) async {
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

    // Jika terdapat kandidat blok yang belum dimiliki, minta secara proaktif
    if (session.missingBlockHashes.isNotEmpty &&
        session.activeRequestId == null) {
      await _sendGetBlocks(session.endpointId, session);
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

  /// Menjalankan rekonsiliasi inventaris untuk satu peer 1-hop yang memenuhi syarat (Stage 5E.4.6 & Stage 5E.4.6.1).
  ///
  /// Mengirimkan pesan [DAG_INV] dengan ringkasan tips dan blok terbaru lokal.
  /// Menerapkan proteksi konkurensi (paling banyak 1 rekonsiliasi aktif per sesi),
  /// penanganan in-flight request timeout, pelacakan respons peer (liveness), serta perhitungan backoff terbatas.
  ///
  /// CATATAN SEMANTIK (Stage 5E.4.6.1):
  /// Mengembalikan true jika pesan [DAG_INV] berhasil dikirim ke transport nirkabel lokal (send success).
  /// Keberhasilan rekonsiliasi end-to-end (confirmed reconciliation) baru terjadi dan memulihkan backoff
  /// setelah peer memberikan respons inventaris yang valid dalam batas waktu [responseTimeout].
  Future<bool> reconcilePeer(String endpointId, [DateTime? now]) async {
    if (!_isEnabled || _isDisposed) return false;

    final session = _sessions[endpointId];
    if (session == null) return false;

    // 1. Validasi sesi kompatibel: DAG_HELLO sudah diverifikasi dan skema sesuai
    if (!session.helloReceived || session.remoteSchemaVersion != 1) {
      return false;
    }

    // 2. Mencegah rekonsiliasi ganda serentak untuk sesi yang sama
    if (session.isReconciling) {
      return false;
    }

    final currentTime = now ?? _nowProvider();

    // 3. Tangani in-flight block request yang masih aktif (jangan duplikasi request)
    if (session.activeRequestId != null) {
      if (session.activeRequestTime != null &&
          currentTime.difference(session.activeRequestTime!) >=
              _scheduler.config.requestTimeout) {
        // Permintaan blok in-flight telah melebihi batas waktu (peer tidak merespons)
        session.clearActiveRequest();
        _recordReconciliationFailure(endpointId, session, currentTime);
        return false;
      } else {
        // Permintaan in-flight masih aktif dalam batas wajar: jangan gandakan request!
        return false;
      }
    }

    // 4. Tangani percobaan rekonsiliasi aktif sebelumnya yang masih menunggu respons (Stage 5E.4.6.1)
    if (session.isAwaitingReconcileResponse) {
      if (session.reconcileAttemptTime != null &&
          currentTime.difference(session.reconcileAttemptTime!) >=
              _scheduler.config.responseTimeout) {
        // Percobaan rekonsiliasi periodik sebelumnya kedaluwarsa tanpa respons (peer tidak merespons)
        session.clearReconcileAttempt();
        _scheduler.cancelResponseTimeout(endpointId);
        _totalPeriodicReconcileTimeouts++;
        _recordReconciliationFailure(endpointId, session, currentTime);
        return false;
      } else {
        // Percobaan rekonsiliasi sebelumnya masih aktif menunggu respons: jangan buat percobaan serentak!
        return false;
      }
    }

    // 5. Periksa apakah sesi masih dalam masa jeda backoff
    if (session.nextEligibleReconcileTime != null &&
        currentTime.isBefore(session.nextEligibleReconcileTime!)) {
      return false;
    }

    session.isReconciling = true;
    _totalPeriodicReconcileAttempts++;

    bool sent = false;
    try {
      sent = await _sendPeriodicInv(endpointId, session);
      if (sent) {
        _totalPeriodicSendSuccess++;
        session.lastPeriodicReconcileTime = currentTime;

        // CATATAN STAGE 5E.4.6.1:
        // sendBytes() == true HANYA membuktikan transport lokal menerima paket,
        // BUKAN konfirmasi bahwa peer merespons atau rekonsiliasi selesai!
        // Jangan mereset backoff dan jangan mengklaim rekonsiliasi sukses di sini.
        final attemptId =
            'reconcile-${session.sessionId}-${currentTime.microsecondsSinceEpoch}';
        session.isAwaitingReconcileResponse = true;
        session.activeReconcileAttemptId = attemptId;
        session.reconcileAttemptTime = currentTime;

        // Pasang timer batas waktu respons jika autoStartTimer aktif
        _scheduler.scheduleResponseTimeout(
          endpointId,
          _scheduler.config.responseTimeout,
          () => _handleReconcileResponseTimeout(endpointId, attemptId),
        );
      } else {
        _totalPeriodicSendFailures++;
        session.clearReconcileAttempt();
        _recordReconciliationFailure(endpointId, session, currentTime);
      }
      return sent;
    } catch (e) {
      debugPrint(
        '[DagGossipSyncEngine] Exception saat rekonsiliasi periodik ke $endpointId: $e',
      );
      _totalPeriodicSendFailures++;
      session.clearReconcileAttempt();
      _recordReconciliationFailure(endpointId, session, currentTime);
      return false;
    } finally {
      session.isReconciling = false;
    }
  }

  /// Menangani kedaluwarsa batas waktu respons rekonsiliasi periodik dari peer.
  void _handleReconcileResponseTimeout(String endpointId, String attemptId) {
    if (!_isEnabled || _isDisposed) return;
    final session = _sessions[endpointId];
    if (session == null) return;
    if (session.isAwaitingReconcileResponse &&
        session.activeReconcileAttemptId == attemptId) {
      session.clearReconcileAttempt();
      _scheduler.cancelResponseTimeout(endpointId);
      _totalPeriodicReconcileTimeouts++;
      _recordReconciliationFailure(endpointId, session, _nowProvider());
    }
  }

  /// Memeriksa timeout percobaan rekonsiliasi yang belum menerima respons peer (Stage 5E.4.6.1).
  ///
  /// Peer yang tidak merespons dalam batas waktu [responseTimeout] akan dicatat kegagalannya
  /// dan dijadwalkan backoff bertahap.
  void checkReconciliationTimeouts([DateTime? now]) {
    if (!_isEnabled || _isDisposed) return;
    final currentTime = now ?? _nowProvider();
    for (final entry in _sessions.entries) {
      final endpointId = entry.key;
      final session = entry.value;
      if (session.isAwaitingReconcileResponse &&
          session.reconcileAttemptTime != null &&
          currentTime.difference(session.reconcileAttemptTime!) >=
              _scheduler.config.responseTimeout) {
        session.clearReconcileAttempt();
        _scheduler.cancelResponseTimeout(endpointId);
        _totalPeriodicReconcileTimeouts++;
        _recordReconciliationFailure(endpointId, session, currentTime);
      }
    }
  }

  /// Memeriksa dan mengonfirmasi keberhasilan rekonsiliasi inventaris jika pesan yang masuk
  /// merupakan respons valid dari peer yang sedang ditunggu (Stage 5E.4.6.1).
  void _tryConfirmReconciliationFromPeer({
    required String endpointId,
    required PeerGossipSession session,
    required DagGossipMessage message,
    required DateTime receivedTime,
  }) {
    // 1. Sesi harus dalam status aktif menunggu respons rekonsiliasi
    if (!session.isAwaitingReconcileResponse) {
      return;
    }

    // 2. KEKETATAN PROTOKOL: DAG_SYNC_ACK HANYA memiliki semantik penerimaan blok,
    //    TIDAK BOLEH digunakan sebagai bukti liveness atau konfirmasi rekonsiliasi inventaris!
    if (message.type == DagGossipMessageType.syncAck) {
      return;
    }

    // 3. Konfirmasi hanya sah jika jenis pesan mengindikasikan respons terhadap rekonsiliasi inventaris
    //    (DAG_INV, DAG_GET_BLOCKS, atau DAG_REJECT)
    final isReconciliationRelevantMessage =
        message.type == DagGossipMessageType.inv ||
        message.type == DagGossipMessageType.getBlocks ||
        message.type == DagGossipMessageType.reject;
    if (!isReconciliationRelevantMessage) {
      return;
    }

    // 4. Verifikasi identitas pengirim: jika remoteNodeId sesi sudah tercatat,
    //    senderNodeId pesan masuk WAJIB cocok persis (mencegah konfirmasi dari node asing/impostor)
    if (session.remoteNodeId != null &&
        session.remoteNodeId!.isNotEmpty &&
        message.senderNodeId != session.remoteNodeId) {
      debugPrint(
        '[DagGossipSyncEngine] Mengabaikan konfirmasi rekonsiliasi dari $endpointId: '
        'senderNodeId "${message.senderNodeId}" tidak cocok dengan remoteNodeId "${session.remoteNodeId}"',
      );
      return;
    }

    // 5. Verifikasi batas waktu (timeout): jika respons tiba setelah timeout berakhir,
    //    percobaan sudah kedaluwarsa dan tidak boleh mengonfirmasi rekonsiliasi!
    if (session.reconcileAttemptTime != null &&
        receivedTime.difference(session.reconcileAttemptTime!) >=
            _scheduler.config.responseTimeout) {
      debugPrint(
        '[DagGossipSyncEngine] Mengabaikan respons terlambat dari $endpointId: '
        'tiba setelah timeout ${_scheduler.config.responseTimeout.inSeconds} detik terlewati',
      );
      session.clearReconcileAttempt();
      _scheduler.cancelResponseTimeout(endpointId);
      _totalPeriodicReconcileTimeouts++;
      _recordReconciliationFailure(endpointId, session, receivedTime);
      return;
    }

    // 6. Terkonfirmasi: Peer responsif dan rekonsiliasi inventaris berhasil
    session.clearReconcileAttempt();
    _scheduler.cancelResponseTimeout(endpointId);
    session.lastReconcileConfirmedTime = receivedTime;

    _totalPeriodicReconcileConfirmed++;

    // Rekonsiliasi terkonfirmasi berhasil: pulihkan keadaan backoff dan jadwalkan tick berikutnya
    _recordReconciliationSuccess(endpointId, session, receivedTime);
  }

  /// Mengirimkan pesan [DAG_INV] periodik ke peer tertentu.
  Future<bool> _sendPeriodicInv(
    String endpointId,
    PeerGossipSession session,
  ) async {
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
      senderTimestamp: _nowProvider().millisecondsSinceEpoch,
      tipHashes: effectiveTips,
      recentBlockHashes: recentBlocks,
    );

    final bytes = DagGossipCodec.encode(invMsg);
    final sent = await _sendRawBytes(endpointId, bytes);

    if (!_isEnabled || _isDisposed) return false;
    final currentSession = _sessions[endpointId];
    if (currentSession == null || currentSession != session) {
      return false;
    }

    if (sent) {
      session.invSent = true;
      session.lastActivity = _nowProvider();
      _totalInvSent++;
      _totalPeriodicInvSent++;
    }
    return sent;
  }

  void _recordReconciliationSuccess(
    String endpointId,
    PeerGossipSession session,
    DateTime now,
  ) {
    _scheduler.cancelResponseTimeout(endpointId);
    session.resetBackoff();
    session.lastPeriodicReconcileTime = now;
    final jitter = _scheduler.config.computeJitter(endpointId);
    final nextInterval = _scheduler.config.interval + jitter;
    session.nextEligibleReconcileTime = now.add(nextInterval);

    _scheduler.schedulePeer(endpointId, nextInterval);
  }

  void _recordReconciliationFailure(
    String endpointId,
    PeerGossipSession session,
    DateTime now,
  ) {
    _scheduler.cancelResponseTimeout(endpointId);
    session.consecutiveFailures++;
    final backoff = _scheduler.config.computeBackoff(
      session.consecutiveFailures,
    );
    session.currentBackoff = backoff;
    session.nextEligibleReconcileTime = now.add(backoff);

    _scheduler.schedulePeer(endpointId, backoff);
  }

  /// Menjalankan satu tick rekonsiliasi periodik secara eksplisit (untuk pengujian deterministik).
  Future<void> tickPeriodicReconciliation([DateTime? now]) async {
    checkReconciliationTimeouts(now);
    await _scheduler.tick(now);
  }

  /// Memicu rekonsiliasi inventaris untuk satu endpoint tertentu secara eksplisit.
  Future<bool> triggerPeriodicReconciliation(
    String endpointId, [
    DateTime? now,
  ]) async {
    return reconcilePeer(endpointId, now);
  }

  /// Membersihkan seluruh resources, membatalkan subscription, dan mengosongkan sesi.
  void dispose() {
    _isDisposed = true;
    _isEnabled = false;
    _scheduler.dispose();
    _disposeListeners();
    for (final session in _sessions.values) {
      session.clearReconcileAttempt();
    }
    _sessions.clear();
    orphanPool?.dispose();
  }
}

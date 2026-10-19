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

  // Pelacakan permintaan blok aktif
  String? activeRequestId;
  final Set<String> activeRequestedHashes = {};
  DateTime? activeRequestTime;

  DateTime lastActivity;

  PeerGossipSession({required this.endpointId})
    : lastActivity = DateTime.now().toUtc();

  void clearActiveRequest() {
    activeRequestId = null;
    activeRequestedHashes.clear();
    activeRequestTime = null;
  }
}

/// Layanan modular sinkronisasi replikasi gossip BlockDAG SiagaMesh.
class DagGossipSyncEngine {
  final MeshTransport transport;
  final String localNodeId;
  final LightweightBlockdagLedger ledger;
  final BlockdagRepository? repository;

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

  DagGossipSyncEngine({
    required this.transport,
    required this.localNodeId,
    required this.ledger,
    this.repository,
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

    final acceptedHashes = <String>[];
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

      // 3. Tolak blok duplikat tanpa mutasi ganda
      if (ledger.processedBlockHashes.contains(block.blockHash)) {
        session.missingBlockHashes.remove(block.blockHash);
        session.knownPeerBlockHashes.add(block.blockHash);
        continue;
      }

      // 4. Validasi aturan ledger (Merkle root, header hash, schema, DAG acyclicity, parent availability)
      final addResult = ledger.acceptRemoteBlock(block);
      if (addResult.isValid) {
        _totalRemoteBlocksAccepted++;
        acceptedHashes.add(block.blockHash);
        session.missingBlockHashes.remove(block.blockHash);
        session.knownPeerBlockHashes.add(block.blockHash);
      } else {
        _totalRemoteBlocksRejected++;
        rejectedHashes.add(block.blockHash);
        firstRejectCode ??= _mapLedgerStatusToRejectCode(addResult.status);
        firstRejectMessage ??= addResult.message;
      }
    }

    // 5. Persistensikan state ke repository jika terdapat blok yang berhasil diterima
    if (acceptedHashes.isNotEmpty && repository != null) {
      try {
        await repository!.saveState(ledger.exportPersistedState());
      } catch (e) {
        debugPrint(
          '[DagGossipSyncEngine] Gagal menyimpan state ke repository: $e',
        );
      }
    }

    // Bersihkan active request dari sesi peminta
    session.clearActiveRequest();

    // 6. Kirim respons konfirmasi (ACK) hanya untuk blok yang benar-benar diterima
    if (acceptedHashes.isNotEmpty) {
      final tips = ledger.tipHashes.toList()..sort();
      final effectiveTips = tips.isEmpty
          ? [ledger.genesisBlock.blockHash]
          : tips;

      final ack = DagSyncAckMessage(
        senderNodeId: localNodeId,
        requestId: batch.requestId,
        acceptedBlockHashes: acceptedHashes,
        newTipHashes: effectiveTips,
      );
      final sent = await _sendMessage(endpointId, ack);
      if (sent) _totalSyncAckSent++;
    } else if (rejectedHashes.isNotEmpty) {
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

    // 7. Jika masih ada hash kandidat yang belum dimiliki, minta batch berikutnya
    if (session.missingBlockHashes.isNotEmpty) {
      await _sendGetBlocks(endpointId, session);
    }
  }

  /// Menangani konfirmasi penerimaan [DAG_SYNC_ACK] dari peer.
  void _handleSyncAck(
    String endpointId,
    PeerGossipSession session,
    DagSyncAckMessage ack,
  ) {
    _totalSyncAckReceived++;
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
          await _processInv(session, pending);
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

        await _processInv(session, inv);
        break;

      case DagGossipMessageType.getBlocks:
        final getBlocks = message as DagGetBlocksMessage;
        _totalGetBlocksReceived++;
        await _handleGetBlocks(endpointId, session, getBlocks);
        break;

      case DagGossipMessageType.blockBatch:
        final batch = message as DagBlockBatchMessage;
        _totalBlockBatchReceived++;
        await _handleBlockBatch(endpointId, session, batch);
        break;

      case DagGossipMessageType.syncAck:
        final ack = message as DagSyncAckMessage;
        _handleSyncAck(endpointId, session, ack);
        break;

      case DagGossipMessageType.reject:
        final reject = message as DagRejectMessage;
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

  /// Membersihkan seluruh resources, membatalkan subscription, dan mengosongkan sesi.
  void dispose() {
    _isDisposed = true;
    _isEnabled = false;
    _disposeListeners();
    _sessions.clear();
  }
}

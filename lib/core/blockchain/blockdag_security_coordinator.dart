/// Koordinator keamanan dan adapter event BlockDAG SiagaMesh.
///
/// Bertanggung jawab untuk:
/// 1. Menerima peristiwa keamanan dari IDS ([IdsDetectionEvent]) dan Dynamic Trust ([TrustScoreChangeEvent]).
/// 2. Memetakan peristiwa menjadi [SecurityAuditEvent] dengan validasi ketat dan perlindungan privasi.
/// 3. Mengatur antrean batching event dan batas waktu flushing (*controlled batching*).
/// 4. Menyimpan dan menyinkronkan state ke [BlockdagRepository] secara konsisten.
/// 5. Menyediakan metrik performa lokal tanpa mengganggu aliran perutean MANET.
library;

import 'dart:async';
import 'dart:convert';
import '../ids/ids_types.dart';
import '../ids/selective_forwarding_detector.dart';
import '../trust/dynamic_trust_manager.dart';
import '../trust/trust_types.dart';
import 'blockchain_types.dart';
import 'blockdag_repository.dart';
import 'lightweight_blockdag_ledger.dart';

/// Konfigurasi parameter batching dan flushing untuk BlockDAG Coordinator.
class BlockdagBatchConfig {
  /// Batas maksimum event di antrean sebelum blok baru dibentuk secara otomatis.
  final int maxBatchSize;

  /// Batas durasi penantian flushing otomatis jika batch belum penuh.
  final Duration flushTimeout;

  /// Pemicu pembuatan blok seketika jika node terdeteksi berstatus suspected atau untrusted.
  final bool immediateFlushOnSuspected;

  /// Apakah mengizinkan pembuatan blok kosong jika flushing dipicu manual (default: false).
  final bool allowEmptyBlocks;

  const BlockdagBatchConfig({
    this.maxBatchSize = 4,
    this.flushTimeout = const Duration(seconds: 30),
    this.immediateFlushOnSuspected = true,
    this.allowEmptyBlocks = false,
  });

  BlockdagBatchConfig copyWith({
    int? maxBatchSize,
    Duration? flushTimeout,
    bool? immediateFlushOnSuspected,
    bool? allowEmptyBlocks,
  }) {
    return BlockdagBatchConfig(
      maxBatchSize: maxBatchSize ?? this.maxBatchSize,
      flushTimeout: flushTimeout ?? this.flushTimeout,
      immediateFlushOnSuspected:
          immediateFlushOnSuspected ?? this.immediateFlushOnSuspected,
      allowEmptyBlocks: allowEmptyBlocks ?? this.allowEmptyBlocks,
    );
  }
}

/// Status hasil inisialisasi koordinator BlockDAG.
enum BlockdagInitStatus {
  /// Belum diinisialisasi.
  uninitialized,

  /// Inisialisasi bersih pertama kali (membuat Genesis block baru pada storage kosong).
  freshGenesis,

  /// Berhasil memulihkan state rantai DAG dari penyimpanan lokal.
  restoredFromStorage,

  /// Data lokal di disk korup/rusak sehingga jatuh ke fallback inisialisasi Genesis baru.
  corruptedFallbackGenesis,

  /// Penyimpanan lokal tidak dapat diakses atau terjadi kegagalan I/O pada storage.
  storageUnavailable,

  /// Versi skema tidak didukung; inisialisasi dihentikan agar tidak menimpa data lama.
  unsupportedVersionHalted,

  /// Pembuatan Genesis awal gagal disimpan ke storage.
  genesisPersistenceFailed,
}

/// Koordinator integrasi event keamanan ke BlockDAG ledger lokal.
class BlockdagSecurityCoordinator {
  final String localNodeId;
  final LightweightBlockdagLedger ledger;
  final BlockdagRepository repository;
  final BlockdagBatchConfig config;

  final Stopwatch _stopwatch = Stopwatch()..start();
  Timer? _flushTimer;
  bool _isFlushing = false;
  bool _isInitialized = false;
  BlockdagInitStatus _initStatus = BlockdagInitStatus.uninitialized;

  StreamSubscription<IdsDetectionEvent>? _idsSubscription;
  StreamSubscription<TrustScoreChangeEvent>? _trustSubscription;

  // Metrik instrumentasi lokal
  int _totalEventsReceived = 0;
  int _totalEventsRejectedOrDeduplicated = 0;
  int _totalBlocksCreated = 0;
  int _totalEventsCommitted = 0;
  int _totalPersistenceFailures = 0;
  int _lastRecordingLatencyMicros = 0;

  BlockdagSecurityCoordinator({
    required this.localNodeId,
    required this.ledger,
    required this.repository,
    this.config = const BlockdagBatchConfig(),
  });

  bool get isInitialized => _isInitialized;
  BlockdagInitStatus get initStatus => _initStatus;
  int get totalEventsReceived => _totalEventsReceived;
  int get totalEventsRejectedOrDeduplicated =>
      _totalEventsRejectedOrDeduplicated;
  int get totalBlocksCreated => _totalBlocksCreated;
  int get totalEventsCommitted => _totalEventsCommitted;
  int get totalPersistenceFailures => _totalPersistenceFailures;
  int get lastRecordingLatencyMicros => _lastRecordingLatencyMicros;

  double get averageEventsPerBlock => _totalBlocksCreated == 0
      ? 0.0
      : _totalEventsCommitted / _totalBlocksCreated;

  /// Estimasi ukuran serialisasi JSON dari seluruh state ledger yang tersimpan.
  int get estimatedStorageSizeBytes {
    try {
      final state = ledger.exportPersistedState();
      return jsonEncode(state.toMap()).length;
    } catch (_) {
      return 0;
    }
  }

  /// Inisialisasi koordinator: memulihkan state dari [repository] atau menyimpan genesis jika baru.
  ///
  /// Mengembalikan [BlockdagInitStatus] eksplisit yang membedakan antara:
  /// - [BlockdagInitStatus.freshGenesis] (penyimpanan pertama kali yang sah)
  /// - [BlockdagInitStatus.restoredFromStorage] (pemulihan sukses dari disk)
  /// - [BlockdagInitStatus.corruptedFallbackGenesis] (data disk korup, fallback ke Genesis baru)
  /// - [BlockdagInitStatus.storageUnavailable] (storage tidak dapat diakses, tidak menimpa data)
  /// - [BlockdagInitStatus.unsupportedVersionHalted] (versi skema tidak didukung, tidak menimpa data)
  /// - [BlockdagInitStatus.genesisPersistenceFailed] (penulisan awal Genesis ke storage gagal)
  Future<BlockdagInitStatus> initialize() async {
    if (_isInitialized) return _initStatus;

    final loadResult = await repository.loadResult();

    switch (loadResult.status) {
      case BlockdagLoadStatus.success:
        ledger.restoreFromPersistedState(loadResult.state!);
        _initStatus = BlockdagInitStatus.restoredFromStorage;
        _isInitialized = true;
        if (ledger.pendingEventsCount > 0) {
          _ensureFlushTimer();
        }
        return _initStatus;

      case BlockdagLoadStatus.storageUnavailable:
        // Storage tidak dapat diakses: JANGAN membuat Genesis dan JANGAN menimpa storage!
        _initStatus = BlockdagInitStatus.storageUnavailable;
        _totalPersistenceFailures++;
        _isInitialized = false; // Memungkinkan retry saat storage pulih
        return _initStatus;

      case BlockdagLoadStatus.unsupportedVersion:
        // Versi skema tidak didukung: JANGAN menimpa data pengguna dengan Genesis baru!
        _initStatus = BlockdagInitStatus.unsupportedVersionHalted;
        _isInitialized = false; // Hentikan inisialisasi persisten
        return _initStatus;

      case BlockdagLoadStatus.empty:
      case BlockdagLoadStatus.corruptedData:
        final isCorrupted =
            (loadResult.status == BlockdagLoadStatus.corruptedData);
        // Reset ledger ke Genesis baru
        ledger.reset();

        final initialOk = await _persistLedgerState();
        if (initialOk) {
          _initStatus = isCorrupted
              ? BlockdagInitStatus.corruptedFallbackGenesis
              : BlockdagInitStatus.freshGenesis;
          _isInitialized = true;
        } else {
          _initStatus = BlockdagInitStatus.genesisPersistenceFailed;
          _totalPersistenceFailures++;
          _isInitialized = false; // Izinkan retry jika penulisan awal gagal
        }
        return _initStatus;
    }
  }

  /// Berlangganan langsung pada stream event detektor IDS.
  void attachToDetector(SelectiveForwardingDetector detector) {
    _idsSubscription?.cancel();
    _idsSubscription = detector.detectionEventsStream.listen(
      processIdsDetectionEvent,
    );
  }

  /// Berlangganan langsung pada stream event manajer reputasi dinamis.
  void attachToTrustManager(DynamicTrustManager manager) {
    _trustSubscription?.cancel();
    _trustSubscription = manager.changeEventsStream.listen(
      processTrustScoreChangeEvent,
    );
  }

  /// Memproses peristiwa deteksi IDS ([IdsDetectionEvent]) ke dalam ledger.
  ///
  /// Menolak event yang tidak valid atau korup secara format.
  Future<bool> processIdsDetectionEvent(IdsDetectionEvent event) async {
    // Validasi identitas event
    if (event.eventId.trim().isEmpty ||
        event.observerNodeId.trim().isEmpty ||
        event.targetNodeId.trim().isEmpty) {
      _totalEventsRejectedOrDeduplicated++;
      return false;
    }

    final auditEvent = SecurityAuditEvent.fromIdsDetectionEvent(event);
    final isSuspected = (event.status == NodeDetectionStatus.suspected);
    return _ingestSecurityAuditEvent(auditEvent, isSuspected: isSuspected);
  }

  /// Memproses peristiwa pembaruan skor kepercayaan ([TrustScoreChangeEvent]) ke dalam ledger.
  ///
  /// Menolak event yang tidak valid atau korup secara format.
  Future<bool> processTrustScoreChangeEvent(TrustScoreChangeEvent event) async {
    // Validasi identitas event
    if (event.eventId.trim().isEmpty ||
        event.observerNodeId.trim().isEmpty ||
        event.targetNodeId.trim().isEmpty) {
      _totalEventsRejectedOrDeduplicated++;
      return false;
    }

    final auditEvent = SecurityAuditEvent.fromTrustScoreChangeEvent(event);
    final isUntrusted =
        (event.evaluationStatus == TrustEvaluationStatus.untrusted);
    return _ingestSecurityAuditEvent(auditEvent, isSuspected: isUntrusted);
  }

  /// Mencatat keputusan isolasi atau reintegrasi node dari routing policy.
  Future<bool> recordIsolationDecision({
    required String eventId,
    required String targetNodeId,
    required String action,
    required double score,
    required String reason,
    DateTime? timestamp,
  }) async {
    if (eventId.trim().isEmpty || targetNodeId.trim().isEmpty) {
      _totalEventsRejectedOrDeduplicated++;
      return false;
    }

    final auditEvent = SecurityAuditEvent.isolationDecision(
      eventId: eventId,
      observerNodeId: localNodeId,
      targetNodeId: targetNodeId,
      action: action,
      score: score,
      reason: reason,
      timestamp: timestamp,
    );

    return _ingestSecurityAuditEvent(
      auditEvent,
      isSuspected: action.toLowerCase() == 'isolate',
    );
  }

  /// Pipeline internal memasukkan [SecurityAuditEvent] ke antrean pending dan mengevaluasi batching.
  Future<bool> _ingestSecurityAuditEvent(
    SecurityAuditEvent event, {
    bool isSuspected = false,
  }) async {
    final startMicros = _stopwatch.elapsedMicroseconds;

    final added = ledger.addPendingEvent(event);
    if (!added) {
      _totalEventsRejectedOrDeduplicated++;
      return false;
    }

    _totalEventsReceived++;
    _lastRecordingLatencyMicros = _stopwatch.elapsedMicroseconds - startMicros;

    // Evaluasi aturan pembentukan blok
    if (config.immediateFlushOnSuspected && isSuspected) {
      _cancelFlushTimer();
      await flushPendingEvents(reason: 'emergency_suspected');
    } else if (ledger.pendingEventsCount >= config.maxBatchSize) {
      _cancelFlushTimer();
      await flushPendingEvents(reason: 'batch_capacity');
    } else {
      _ensureFlushTimer();
      // Persist pending pool agar tidak hilang jika aplikasi dimatikan mendadak
      final saveOk = await _persistLedgerState();
      if (!saveOk) {
        _totalPersistenceFailures++;
      }
    }

    return true;
  }

  /// Membentuk blok baru dari seluruh antrean pending dan menyimpannya secara persisten.
  ///
  /// Mengembalikan [SecurityBlock] yang terbentuk, atau `null` jika antrean kosong.
  Future<SecurityBlock?> flushPendingEvents({String reason = 'manual'}) async {
    if (_isFlushing) {
      return null;
    }

    if (ledger.pendingEventsCount == 0 && !config.allowEmptyBlocks) {
      _cancelFlushTimer();
      return null;
    }

    _isFlushing = true;
    _cancelFlushTimer();

    try {
      final eventsCount = ledger.pendingEventsCount;
      final block = ledger.createBlock(
        creatorNodeId: localNodeId,
        validationProof: {'flushReason': reason, 'creatorNodeId': localNodeId},
      );

      _totalBlocksCreated++;
      _totalEventsCommitted += eventsCount;

      final saveOk = await _persistLedgerState();
      if (!saveOk) {
        _totalPersistenceFailures++;
      }

      return block;
    } catch (_) {
      _totalPersistenceFailures++;
      return null;
    } finally {
      _isFlushing = false;
      if (ledger.pendingEventsCount > 0) {
        _ensureFlushTimer();
      }
    }
  }

  /// Memicu flush berbasis waktu secara terkontrol (untuk pengujian deterministik).
  Future<SecurityBlock?> triggerTimeFlush() async {
    return flushPendingEvents(reason: 'controlled_time_flush');
  }

  /// Memastikan timer flush aktif jika belum berjalan.
  void _ensureFlushTimer() {
    if (_flushTimer != null) return;
    if (config.flushTimeout <= Duration.zero) return;

    _flushTimer = Timer(config.flushTimeout, () {
      _flushTimer = null;
      flushPendingEvents(reason: 'timeout_flush');
    });
  }

  void _cancelFlushTimer() {
    _flushTimer?.cancel();
    _flushTimer = null;
  }

  Future<bool> _persistLedgerState() async {
    final state = ledger.exportPersistedState();
    return repository.saveState(state);
  }

  /// Ringkasan seluruh metrik pencatatan lokal.
  Map<String, dynamic> getMetrics() => {
    'totalEventsReceived': _totalEventsReceived,
    'totalEventsRejectedOrDeduplicated': _totalEventsRejectedOrDeduplicated,
    'totalBlocksCreated': _totalBlocksCreated,
    'totalEventsCommitted': _totalEventsCommitted,
    'averageEventsPerBlock': averageEventsPerBlock,
    'totalPersistenceFailures': _totalPersistenceFailures,
    'lastRecordingLatencyMicros': _lastRecordingLatencyMicros,
    'estimatedStorageSizeBytes': estimatedStorageSizeBytes,
    'activeBlocksCount': ledger.activeBlocksCount,
    'pendingEventsCount': ledger.pendingEventsCount,
    'initStatus': _initStatus.name,
  };

  /// Membersihkan seluruh resources, membatalkan timer, dan melepaskan stream listener.
  void dispose() {
    _cancelFlushTimer();
    _idsSubscription?.cancel();
    _idsSubscription = null;
    _trustSubscription?.cancel();
    _trustSubscription = null;
  }
}

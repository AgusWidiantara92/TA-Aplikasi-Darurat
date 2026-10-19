import 'dart:async';
import '../routing/mesh_experiment_logger.dart';
import 'ids_types.dart';

/// Konfigurasi parameter operasional detektor Selective Forwarding.
///
/// PERINGATAN METODOLOGI:
/// Seluruh nilai ambang batas pada konfigurasi ini bersifat provisional (sementara)
/// dan dapat dikonfigurasi ulang untuk pengujian sensitivitas. Nilai ini TIDAK DIKLAIM
/// sebagai nilai optimal sebelum dilakukan pengujian parameter lapangan skala penuh.
class IdsConfig {
  /// Batas minimal observasi pengiriman yang diharapkan ke suatu peer sebelum IDS
  /// membuat keputusan klasifikasi definitif (menghindari alarm dini akibat 1 sampel).
  final int minObservationsForEvaluation;

  /// Ambang batas persentase paket tak terkonfirmasi (rasio drop) untuk mencurigai peer.
  /// Contoh: 0.35 berarti jika $\ge 35\%$ paket gagal dikonfirmasi pada link aktif,
  /// peer diklasifikasikan sebagai `NodeDetectionStatus.suspected`.
  final double dropRateThreshold;

  /// Batas waktu penantian bukti forwarding (HOP_ACK) sebelum paket dianggap tidak diteruskan.
  final Duration ackTimeout;

  /// Apakah node ini secara otomatis mengirimkan HOP_ACK saat berhasil meneruskan paket orang lain.
  final bool autoSendHopAck;

  const IdsConfig({
    this.minObservationsForEvaluation = 4,
    this.dropRateThreshold = 0.35,
    this.ackTimeout = const Duration(milliseconds: 2500),
    this.autoSendHopAck = true,
  });

  IdsConfig copyWith({
    int? minObservationsForEvaluation,
    double? dropRateThreshold,
    Duration? ackTimeout,
    bool? autoSendHopAck,
  }) {
    return IdsConfig(
      minObservationsForEvaluation:
          minObservationsForEvaluation ?? this.minObservationsForEvaluation,
      dropRateThreshold: dropRateThreshold ?? this.dropRateThreshold,
      ackTimeout: ackTimeout ?? this.ackTimeout,
      autoSendHopAck: autoSendHopAck ?? this.autoSendHopAck,
    );
  }
}

/// Pelacakan kewajiban penerusan untuk satu paket tertentu yang dipercayakan ke peer tetangga.
class TrackedForwardingObligation {
  final String envelopeId;
  final String peerNodeId;
  final DateTime registeredAt;
  final int monotonicMicros;
  ForwardingEvidenceType evidenceType;
  bool isResolved;

  TrackedForwardingObligation({
    required this.envelopeId,
    required this.peerNodeId,
    required this.registeredAt,
    required this.monotonicMicros,
    this.evidenceType = ForwardingEvidenceType.forwardingExpected,
    this.isResolved = false,
  });
}

/// Akumulasi statistik bukti penerusan untuk satu peer tetangga tertentu.
class PeerForwardingStats {
  final String nodeId;
  int expectedCount;
  int claimedCount;
  int unconfirmedCount;
  int linkFailureCount;
  int protocolDropCount;

  /// Alias kompatibilitas ke belakang untuk [claimedCount].
  int get confirmedCount => claimedCount;
  set confirmedCount(int value) => claimedCount = value;

  /// Cache ID envelope yang telah diproses untuk mencegah penghitungan ganda (deduplikasi event).
  final Set<String> _processedEnvelopeIds = {};

  NodeDetectionStatus currentStatus;

  PeerForwardingStats({
    required this.nodeId,
    this.expectedCount = 0,
    int? confirmedCount,
    int? claimedCount,
    this.unconfirmedCount = 0,
    this.linkFailureCount = 0,
    this.protocolDropCount = 0,
    this.currentStatus = NodeDetectionStatus.insufficientEvidence,
  }) : claimedCount = claimedCount ?? confirmedCount ?? 0;

  /// Rasio paket tidak terkonfirmasi terhadap total yang diharapkan diteruskan.
  double get dropRate =>
      expectedCount == 0 ? 0.0 : unconfirmedCount / expectedCount;

  bool hasProcessed(String envelopeId) =>
      _processedEnvelopeIds.contains(envelopeId);

  void markProcessed(String envelopeId) =>
      _processedEnvelopeIds.add(envelopeId);

  void reset() {
    expectedCount = 0;
    claimedCount = 0;
    unconfirmedCount = 0;
    linkFailureCount = 0;
    protocolDropCount = 0;
    _processedEnvelopeIds.clear();
    currentStatus = NodeDetectionStatus.insufficientEvidence;
  }
}

/// Komponen Intrusion Detection System (IDS) independen untuk mendeteksi Selective Forwarding Attack.
///
/// Memisahkan secara tegas:
/// 1. Dugaan serangan (Selective Forwarding) pada link aktif yang sehat.
/// 2. Kegagalan transmisi akibat link terputus alami (Link Failure).
/// 3. Pembuangan paket akibat aturan protokol yang sah (Protocol Drop: TTL, Dedup, Loop).
/// 4. Kondisi data observasi yang belum mencukupi (Insufficient Evidence).
class SelectiveForwardingDetector {
  final String localNodeId;
  final IdsConfig config;
  MeshExperimentLogger? experimentLogger;
  String? simulationGroundTruth;
  final Stopwatch _stopwatch = Stopwatch()..start();

  final Map<String, PeerForwardingStats> _peerStats = {};
  final Map<String, TrackedForwardingObligation> _pendingObligations = {};
  final List<IdsDetectionEvent> _detectionHistory = [];
  final StreamController<IdsDetectionEvent> _detectionEventsController =
      StreamController<IdsDetectionEvent>.broadcast(sync: true);

  String activeRunId;
  int _eventCounter = 0;

  SelectiveForwardingDetector({
    required this.localNodeId,
    this.config = const IdsConfig(),
    this.experimentLogger,
    this.simulationGroundTruth,
    this.activeRunId = 'EXP-IDS-INIT',
  });

  Stream<IdsDetectionEvent> get detectionEventsStream =>
      _detectionEventsController.stream;

  List<IdsDetectionEvent> get detectionHistory =>
      List.unmodifiable(_detectionHistory);

  PeerForwardingStats _getOrCreateStats(String peerNodeId) {
    return _peerStats.putIfAbsent(
      peerNodeId,
      () => PeerForwardingStats(nodeId: peerNodeId),
    );
  }

  PeerForwardingStats? getStats(String peerNodeId) => _peerStats[peerNodeId];

  Map<String, PeerForwardingStats> get allStats => Map.unmodifiable(_peerStats);

  /// 1. Mendaftarkan ekspektasi bahwa [peerNodeId] wajib meneruskan paket [envelopeId].
  ///
  /// Menolak duplikasi jika envelope yang sama telah terdaftar untuk peer tersebut.
  bool registerForwardingExpected({
    required String peerNodeId,
    required String envelopeId,
    DateTime? timestamp,
  }) {
    if (peerNodeId == localNodeId) return false;

    final stats = _getOrCreateStats(peerNodeId);
    if (stats.hasProcessed(envelopeId)) {
      // Tolak pemrosesan ganda untuk envelope yang sama
      return false;
    }

    final key = '$peerNodeId-$envelopeId';
    if (_pendingObligations.containsKey(key)) {
      return false;
    }

    final now = timestamp ?? DateTime.now();
    _pendingObligations[key] = TrackedForwardingObligation(
      envelopeId: envelopeId,
      peerNodeId: peerNodeId,
      registeredAt: now,
      monotonicMicros: _stopwatch.elapsedMicroseconds,
      evidenceType: ForwardingEvidenceType.forwardingExpected,
    );

    stats.expectedCount++;
    stats.markProcessed(envelopeId);
    evaluateNode(peerNodeId);
    return true;
  }

  /// 2. Mendaftarkan klaim bahwa [peerNodeId] telah merelai paket [envelopeId]
  /// berdasarkan tanda terima `HOP_ACK` yang diterima dari peer relai.
  ///
  /// PERINGATAN SEMANTIK: Tanda terima ini dicatat sebagai `relayClaimed` (klaim sepihak peer),
  /// BUKAN konfirmasi verifikasi bahwa hop downstream benar-benar menerima paket.
  ///
  /// Mengembalikan `true` hanya jika terdapat obligasi tertunda yang cocok dan belum terselesaikan.
  /// Menolak ACK duplikat, terlambat (setelah timeout), atau envelope yang tidak dilacak.
  bool registerRelayClaimed({
    required String peerNodeId,
    required String envelopeId,
    DateTime? timestamp,
  }) {
    final key = '$peerNodeId-$envelopeId';
    final obligation = _pendingObligations[key];
    final stats = _getOrCreateStats(peerNodeId);

    if (obligation != null && !obligation.isResolved) {
      obligation.evidenceType = ForwardingEvidenceType.relayClaimed;
      obligation.isResolved = true;
      _pendingObligations.remove(key);

      stats.claimedCount++;
      evaluateNode(peerNodeId);
      return true;
    }

    // Jika tidak ada obligasi tertunda (ACK terlambat, duplikat, atau tidak cocok):
    // Tolak dan jangan ubah statistik agar tidak dapat dimanipulasi
    return false;
  }

  /// Alias kompatibilitas ke belakang untuk [registerRelayClaimed].
  bool registerForwardingConfirmed({
    required String peerNodeId,
    required String envelopeId,
    DateTime? timestamp,
  }) => registerRelayClaimed(
    peerNodeId: peerNodeId,
    envelopeId: envelopeId,
    timestamp: timestamp,
  );

  /// 3. Mendaftarkan pembuangan paket karena aturan protokol yang sah
  /// (misal TTL habis, deduplikasi, loop, atau paket memang ditujukan untuk node tersebut).
  ///
  /// Paket jenis ini TIDAK BOLEH dihitung sebagai selective forwarding!
  void registerProtocolDrop({
    required String peerNodeId,
    required String envelopeId,
    required String reason,
  }) {
    final key = '$peerNodeId-$envelopeId';
    final obligation = _pendingObligations.remove(key);
    if (obligation != null) {
      obligation.evidenceType = ForwardingEvidenceType.protocolDrop;
      obligation.isResolved = true;
    }

    final stats = _getOrCreateStats(peerNodeId);
    stats.protocolDropCount++;
    evaluateNode(peerNodeId);
  }

  /// 4. Mendaftarkan kegagalan koneksi atau putusnya link radio.
  ///
  /// Kegagalan link fisik membatalkan kecurigaan selective forwarding untuk paket tertunda
  /// pada peer tersebut dan mencatatnya sebagai kegagalan tautan alami.
  void registerLinkFailure({
    required String peerNodeId,
    String? envelopeId,
    String? reason,
  }) {
    final stats = _getOrCreateStats(peerNodeId);
    stats.linkFailureCount++;

    if (envelopeId != null) {
      final key = '$peerNodeId-$envelopeId';
      final obligation = _pendingObligations.remove(key);
      if (obligation != null) {
        obligation.evidenceType = ForwardingEvidenceType.linkFailureSuspected;
        obligation.isResolved = true;
      }
    } else {
      // Peer terputus secara global: seluruh kewajiban tertunda pada peer ini
      // dialihkan statusnya ke linkFailureSuspected agar tidak dituduh menyerang
      final keysToRemove = <String>[];
      for (final entry in _pendingObligations.entries) {
        if (entry.value.peerNodeId == peerNodeId && !entry.value.isResolved) {
          entry.value.evidenceType =
              ForwardingEvidenceType.linkFailureSuspected;
          entry.value.isResolved = true;
          keysToRemove.add(entry.key);
        }
      }
      for (final k in keysToRemove) {
        _pendingObligations.remove(k);
      }
    }

    evaluateNode(peerNodeId);
  }

  /// 5. Memeriksa timeout untuk seluruh kewajiban penerusan yang tertunda.
  ///
  /// Jika batas waktu `config.ackTimeout` terlampaui dan link masih aktif,
  /// paket ditandai sebagai `forwardingUnconfirmed` dan memicu evaluasi status.
  void checkTimeouts({DateTime? now, bool isLinkConnected = true}) {
    final currentTime = now ?? DateTime.now();
    final expiredKeys = <String>[];

    for (final entry in _pendingObligations.entries) {
      final ob = entry.value;
      if (ob.isResolved) continue;

      if (currentTime.difference(ob.registeredAt) >= config.ackTimeout) {
        expiredKeys.add(entry.key);
        ob.isResolved = true;

        final stats = _getOrCreateStats(ob.peerNodeId);
        if (isLinkConnected) {
          ob.evidenceType = ForwardingEvidenceType.forwardingUnconfirmed;
          stats.unconfirmedCount++;
        } else {
          ob.evidenceType = ForwardingEvidenceType.linkFailureSuspected;
          stats.linkFailureCount++;
        }
      }
    }

    for (final key in expiredKeys) {
      final ob = _pendingObligations.remove(key);
      if (ob != null) {
        evaluateNode(ob.peerNodeId);
      }
    }
  }

  /// 6. Evaluasi klasifikasi status node berdasarkan bukti terakumulasi.
  NodeDetectionStatus evaluateNode(String peerNodeId) {
    final stats = _getOrCreateStats(peerNodeId);
    final previousStatus = stats.currentStatus;

    NodeDetectionStatus newStatus;
    String reason;

    if (stats.expectedCount < config.minObservationsForEvaluation) {
      // Observasi belum cukup untuk mengambil kesimpulan definitif
      newStatus = NodeDetectionStatus.insufficientEvidence;
      reason =
          'Observasi (${stats.expectedCount}/${config.minObservationsForEvaluation}) belum mencukupi ambang minimum';
    } else if (stats.dropRate >= config.dropRateThreshold) {
      // Tingkat drop paket melebihi batas toleransi pada link aktif
      newStatus = NodeDetectionStatus.suspected;
      reason =
          'Rasio drop paket ${(stats.dropRate * 100).toStringAsFixed(1)}% melampaui ambang ${(config.dropRateThreshold * 100).toStringAsFixed(1)}%';
    } else {
      // Perilaku forwarding dalam batas normal
      newStatus = NodeDetectionStatus.normal;
      reason =
          'Rasio drop ${(stats.dropRate * 100).toStringAsFixed(1)}% berada di bawah ambang batas';
    }

    stats.currentStatus = newStatus;

    // Picu event HANYA jika terjadi transisi status (mencegah log/alarm berulang tanpa alasan)
    if (newStatus != previousStatus) {
      _emitDetectionEvent(
        targetNodeId: peerNodeId,
        status: newStatus,
        dropRate: stats.dropRate,
        stats: stats,
        reason: reason,
      );
    }

    return newStatus;
  }

  /// Evaluasi seluruh node yang terdata.
  Map<String, NodeDetectionStatus> evaluateAllNodes() {
    final result = <String, NodeDetectionStatus>{};
    for (final nodeId in _peerStats.keys) {
      result[nodeId] = evaluateNode(nodeId);
    }
    return result;
  }

  void _emitDetectionEvent({
    required String targetNodeId,
    required NodeDetectionStatus status,
    required double dropRate,
    required PeerForwardingStats stats,
    required String reason,
  }) {
    _eventCounter++;
    final event = IdsDetectionEvent(
      eventId: 'ids-evt-$_eventCounter',
      runId: activeRunId,
      observerNodeId: localNodeId,
      targetNodeId: targetNodeId,
      status: status,
      observedDropRate: dropRate,
      totalExpected: stats.expectedCount,
      totalClaimed: stats.claimedCount,
      totalConfirmed: stats.claimedCount,
      totalUnconfirmed: stats.unconfirmedCount,
      totalLinkFailures: stats.linkFailureCount,
      totalProtocolDrops: stats.protocolDropCount,
      reason: reason,
      timestamp: DateTime.now(),
      monotonicMicros: _stopwatch.elapsedMicroseconds,
    );

    _detectionHistory.add(event);
    if (_detectionHistory.length > 500) {
      _detectionHistory.removeAt(0); // Batasi riwayat di memori
    }

    if (!_detectionEventsController.isClosed) {
      _detectionEventsController.add(event);
    }

    // Integrasi ke MeshExperimentLogger jika tersedia (dengan try-catch agar kegagalan logger tidak menghentikan perutean)
    if (experimentLogger != null) {
      try {
        experimentLogger!.logIdsDetection(
          targetNodeId: targetNodeId,
          observerNodeId: localNodeId,
          status: status.name,
          reason: reason,
          totalExpected: stats.expectedCount,
          totalConfirmed: stats.claimedCount,
          totalUnconfirmed: stats.unconfirmedCount,
          totalLinkFailures: stats.linkFailureCount,
          totalProtocolDrops: stats.protocolDropCount,
          observedDropRate: dropRate,
          thresholdConfig: {
            'minObservations': config.minObservationsForEvaluation,
            'dropRateThreshold': config.dropRateThreshold,
            'ackTimeoutMs': config.ackTimeout.inMilliseconds,
          },
          runId: activeRunId,
          simulationGroundTruth: simulationGroundTruth,
        );
      } catch (_) {
        // Logging error tidak boleh menghentikan proses perutean
      }
    }
  }

  /// Membersihkan seluruh state dan riwayat deteksi (misal saat reset sesi uji).
  void clear() {
    _peerStats.clear();
    _pendingObligations.clear();
    _detectionHistory.clear();
  }

  void dispose() {
    _detectionEventsController.close();
  }
}

import 'dart:async';
import '../ids/ids_types.dart';
import '../routing/mesh_experiment_logger.dart';
import 'trust_repository.dart';
import 'trust_types.dart';

/// Mesin pengelola reputasi dinamis (*Dynamic Trust Management Engine*) SiagaMesh.
///
/// Bertanggung jawab atas:
/// 1. Menghitung dan memperbarui skor kepercayaan tetangga ($T_i \in [0.0, 1.0]$)
///    berdasarkan bukti riwayat transaksi forwarding yang tervalidasi.
/// 2. Memisahkan secara ketat bukti forwarding positif (*relay claim* berbobot diskon),
///    kegagalan link radio alami (*link disconnect*), dan aturan protokol sah (*protocol drop*).
/// 3. Mengontrol keputusan pemilihan perantara perutean (*trust-aware forwarding filter*).
/// 4. Mencegah manipulasi skor melalui deduplikasi ID event dan peredaman fluktuasi historis.
class DynamicTrustManager {
  final String localNodeId;
  final TrustConfig config;
  final TrustRepository? repository;
  MeshExperimentLogger? experimentLogger;
  String? simulationGroundTruth;
  final Stopwatch _stopwatch = Stopwatch()..start();

  final Map<String, TrustRecord> _records = {};
  final List<TrustScoreChangeEvent> _changeHistory = [];
  final StreamController<TrustScoreChangeEvent> _eventsController =
      StreamController<TrustScoreChangeEvent>.broadcast(sync: true);

  String activeRunId;
  int _eventCounter = 0;

  DynamicTrustManager({
    required this.localNodeId,
    this.config = const TrustConfig(),
    this.repository,
    this.experimentLogger,
    this.simulationGroundTruth,
    this.activeRunId = 'EXP-TRUST-INIT',
  });

  Stream<TrustScoreChangeEvent> get changeEventsStream =>
      _eventsController.stream;

  List<TrustScoreChangeEvent> get changeHistory =>
      List.unmodifiable(_changeHistory);

  Map<String, double> get allScores => {
    for (final entry in _records.entries) entry.key: entry.value.currentScore,
  };

  TrustRecord _getOrCreateRecord(String nodeId) {
    return _records.putIfAbsent(
      nodeId,
      () => TrustRecord(nodeId: nodeId, currentScore: config.initialTrust),
    );
  }

  /// Mengambil skor kepercayaan terkini untuk [nodeId].
  /// Mengembalikan [config.initialTrust] jika node belum memiliki riwayat interaksi.
  double getTrustScore(String nodeId) {
    if (nodeId == localNodeId) {
      return 1.0; // Node lokal selalu dipercaya oleh dirinya sendiri
    }
    return _records[nodeId]?.currentScore ?? config.initialTrust;
  }

  /// Mengambil status klasifikasi kepercayaan untuk [nodeId].
  TrustEvaluationStatus getStatus(String nodeId) {
    if (nodeId == localNodeId) {
      return TrustEvaluationStatus.trusted;
    }
    final record = _records[nodeId];
    if (record == null) return TrustEvaluationStatus.uncertain;
    return record.evaluateStatus(config);
  }

  TrustRecord? getRecord(String nodeId) => _records[nodeId];

  /// Memproses bukti forwarding langsung dari subsistem transport / routing.
  ///
  /// Mengembalikan `true` jika bukti baru berhasil diproses dan memicu evaluasi,
  /// atau `false` jika bukti ditolak karena duplikat atau identitas tidak valid.
  bool observeDirectEvidence({
    required String targetNodeId,
    required String evidenceId,
    required ForwardingEvidenceType evidenceType,
    String? reason,
  }) {
    if (targetNodeId.isEmpty || targetNodeId == localNodeId) return false;

    final record = _getOrCreateRecord(targetNodeId);

    // Mencegah pemrosesan ganda (Idempotensi & Replay Prevention)
    if (record.hasProcessed(evidenceId)) {
      return false;
    }
    record.markProcessed(evidenceId);

    final oldScore = record.currentScore;
    double newScore = oldScore;
    String actualReason = reason ?? evidenceType.name;

    switch (evidenceType) {
      case ForwardingEvidenceType.receiptConfirmed:
        // Konfirmasi penerimaan 1-hop: tetangga menerima paket, namun belum membuktikan forwarding
        actualReason = 'Penerimaan link 1-hop terkonfirmasi';
        break;

      case ForwardingEvidenceType.forwardingExpected:
        // Ekspektasi penerusan terdaftar: menunggu penyelesaian bukti
        break;

      case ForwardingEvidenceType.relayClaimed:
      // ignore: deprecated_member_use_from_same_package
      case ForwardingEvidenceType.forwardingConfirmed:
        // Node relai mengklaim telah meneruskan paket via Hop ACK (berbobot diskon karena unauthenticated)
        record.relayClaimCount++;
        record.positiveEvidenceSum += config.weightRelayClaimed;
        record.totalObservations++;
        newScore = _calculateUpdatedTrust(record);
        actualReason =
            'Hop ACK relai diterima (klaim sepihak berbobot ${(config.weightRelayClaimed * 100).toInt()}%)';
        break;

      case ForwardingEvidenceType.downstreamConfirmed:
        // Konfirmasi hop downstream menerima paket hasil forwarding
        record.downstreamConfirmedCount++;
        record.positiveEvidenceSum += config.weightDownstreamConfirmed;
        record.totalObservations++;
        newScore = _calculateUpdatedTrust(record);
        actualReason = 'Penerimaan hop downstream terkonfirmasi';
        break;

      case ForwardingEvidenceType.deliveryConfirmed:
        // Konfirmasi pengiriman akhir sampai ke penerima tujuan (E2E ACK)
        record.deliveryConfirmedCount++;
        record.positiveEvidenceSum += config.weightDeliveryConfirmed;
        record.totalObservations++;
        newScore = _calculateUpdatedTrust(record);
        actualReason = 'Pengiriman pesan akhir terkonfirmasi (E2E)';
        break;

      case ForwardingEvidenceType.forwardingUnconfirmed:
        // Timeout penerusan pada link aktif tanpa bukti/klaim (indikasi selective forwarding)
        record.unconfirmedDropCount++;
        record.negativeEvidenceSum += config.weightUnconfirmedDrop;
        record.totalObservations++;
        newScore = _calculateUpdatedTrust(record);
        actualReason =
            'Timeout penerusan pada link aktif (paket tidak dikonfirmasi)';
        break;

      case ForwardingEvidenceType.linkFailureSuspected:
        // Kegagalan koneksi transport alami (link terputus):
        // ATURAN WAJIB: TIDAK BOLEH menjatuhkan penalti skor selective forwarding!
        record.linkFailureCount++;
        actualReason =
            'Koneksi link transport terputus alami (tanpa penalti trust)';
        break;

      case ForwardingEvidenceType.protocolDrop:
        // Pembuangan paket sah berdasarkan aturan protokol (TTL habis, loop, deduplikasi):
        // ATURAN WAJIB: TIDAK BOLEH menjatuhkan penalti skor selective forwarding!
        record.protocolDropCount++;
        actualReason =
            'Pembuangan paket sesuai aturan protokol (tanpa penalti trust)';
        break;
    }

    record.currentScore = newScore;
    record.lastUpdated = DateTime.now();

    final newStatus = record.evaluateStatus(config);

    _emitTrustChangeEvent(
      targetNodeId: targetNodeId,
      oldScore: oldScore,
      newScore: newScore,
      evidenceType: evidenceType,
      evaluationStatus: newStatus,
      reason: actualReason,
      record: record,
    );

    return true;
  }

  /// Memproses peristiwa deteksi keamanan dari [IdsDetectionEvent].
  ///
  /// Menghubungkan output IDS ke evaluasi Dynamic Trust secara modular.
  bool observeIdsEvent(
    IdsDetectionEvent event, {
    String? simulationGroundTruth,
  }) {
    if (event.targetNodeId.isEmpty || event.targetNodeId == localNodeId) {
      return false;
    }

    final record = _getOrCreateRecord(event.targetNodeId);

    // Mencegah pemrosesan event IDS yang sama berulang kali
    if (record.hasProcessed(event.eventId)) {
      return false;
    }
    record.markProcessed(event.eventId);

    final oldScore = record.currentScore;
    double newScore = oldScore;
    String actualReason = event.reason;
    ForwardingEvidenceType evidenceType;

    if (event.status == NodeDetectionStatus.insufficientEvidence) {
      // Data observasi belum mencukupi ambang batas minimum:
      // ATURAN WAJIB: Skor trust TIDAK BOLEH diubah secara sewenang-wenang
      evidenceType = ForwardingEvidenceType.forwardingExpected;
      actualReason =
          'Observasi IDS belum mencukupi ambang minimum (skor dipertahankan)';
    } else if (event.status == NodeDetectionStatus.suspected) {
      // Node terindikasi melakukan selective forwarding:
      evidenceType = ForwardingEvidenceType.forwardingUnconfirmed;
      record.unconfirmedDropCount++;
      record.negativeEvidenceSum += config.weightUnconfirmedDrop;
      record.totalObservations++;
      newScore = _calculateUpdatedTrust(record);
      actualReason =
          'Alarm IDS: Indikasi Selective Forwarding (${event.reason})';
    } else {
      // Node normal kooperatif:
      evidenceType = ForwardingEvidenceType.relayClaimed;
      record.relayClaimCount++;
      record.positiveEvidenceSum += config.weightRelayClaimed;
      record.totalObservations++;
      newScore = _calculateUpdatedTrust(record);
      actualReason = 'Observasi IDS: Perilaku penerusan normal kooperatif';
    }

    record.currentScore = newScore;
    record.lastUpdated = DateTime.now();

    final newStatus = record.evaluateStatus(config);

    _emitTrustChangeEvent(
      targetNodeId: event.targetNodeId,
      oldScore: oldScore,
      newScore: newScore,
      evidenceType: evidenceType,
      evaluationStatus: newStatus,
      reason: actualReason,
      record: record,
      simulationGroundTruth: simulationGroundTruth,
    );

    return true;
  }

  /// Rumus pembaruan skor kepercayaan dinamis (Exponential Moving Average / Decay):
  ///
  /// $$T_{\text{direct}} = \frac{S_{\text{pos}}}{S_{\text{pos}} + S_{\text{neg}}}$$
  /// $$T_{\text{baru}} = \alpha \cdot T_{\text{lama}} + (1 - \alpha) \cdot T_{\text{direct}}$$
  ///
  /// Dibatasi ketat dalam rentang $[0.0, 1.0]$.
  double _calculateUpdatedTrust(TrustRecord record) {
    final sPos = record.positiveEvidenceSum;
    final sNeg = record.negativeEvidenceSum;
    final totalEvidence = sPos + sNeg;

    if (totalEvidence <= 0.0) {
      return record.currentScore;
    }

    final tDirect = sPos / totalEvidence;
    final updated =
        (config.decayAlpha * record.currentScore) +
        ((1.0 - config.decayAlpha) * tDirect);

    // Pastikan hasil dibatasi ketat dalam interval [0.0, 1.0]
    return updated.clamp(0.0, 1.0);
  }

  /// Memfilter tetangga kandidat perantara forwarding berdasarkan kebijakan kepercayaan aktif.
  ///
  /// Mengimplementasikan kebijakan [TrustRoutingPolicy]:
  /// - [TrustRoutingPolicy.strictIsolation]: Menolak kandidat `untrusted`.
  /// - [TrustRoutingPolicy.fallbackWithWarning]: Memilih peer terpercaya, atau fallback jika seluruhnya untrusted.
  /// - [TrustRoutingPolicy.monitoringOnly]: Meneruskan seluruh kandidat tanpa filter.
  List<T> filterForwardingPeers<T>({
    required List<T> peers,
    required String Function(T) getNodeId,
    required String destinationId,
    void Function(String peerId, String decision, double score)? onDecision,
  }) {
    if (peers.isEmpty) return const [];

    // Jika mode monitoring murni, seluruh peer lolos tanpa filter
    if (config.routingPolicy == TrustRoutingPolicy.monitoringOnly) {
      for (final p in peers) {
        final id = getNodeId(p);
        onDecision?.call(id, 'FORWARD_MONITORING_ONLY', getTrustScore(id));
      }
      return List<T>.from(peers);
    }

    final trustedCandidates = <T>[];
    final untrustedCandidates = <T>[];

    for (final peer in peers) {
      final peerId = getNodeId(peer);
      // Jika peer adalah penerima tujuan akhir, selalu izinkan pengiriman langsung
      if (peerId == destinationId) {
        trustedCandidates.add(peer);
        onDecision?.call(
          peerId,
          'FORWARD_DIRECT_DESTINATION',
          getTrustScore(peerId),
        );
        continue;
      }

      final status = getStatus(peerId);
      final score = getTrustScore(peerId);

      if (status == TrustEvaluationStatus.untrusted) {
        untrustedCandidates.add(peer);
        onDecision?.call(peerId, 'BLOCKED_UNTRUSTED_RELAY', score);
      } else {
        // Status trusted atau uncertain (masih diizinkan eksplorasi awal)
        trustedCandidates.add(peer);
        onDecision?.call(peerId, 'APPROVED_TRUSTED_RELAY', score);
      }
    }

    if (trustedCandidates.isNotEmpty) {
      return trustedCandidates;
    }

    // Penanganan kondisi ekstrem: Seluruh tetangga berstatus untrusted!
    if (config.routingPolicy == TrustRoutingPolicy.fallbackWithWarning) {
      // Fallback: Pilih tetangga dengan skor kepercayaan tertinggi dan catat log peringatan
      untrustedCandidates.sort((a, b) {
        final scoreA = getTrustScore(getNodeId(a));
        final scoreB = getTrustScore(getNodeId(b));
        return scoreB.compareTo(scoreA); // Urutan menurun
      });
      final fallbackPeer = untrustedCandidates.first;
      final fallbackId = getNodeId(fallbackPeer);
      onDecision?.call(
        fallbackId,
        'FALLBACK_WARNING_NO_TRUSTED_RELAY',
        getTrustScore(fallbackId),
      );
      return [fallbackPeer];
    }

    // Pada strictIsolation: Jangan teruskan melalui penyerang yang telah terisolasi
    return const [];
  }

  void _emitTrustChangeEvent({
    required String targetNodeId,
    required double oldScore,
    required double newScore,
    required ForwardingEvidenceType evidenceType,
    required TrustEvaluationStatus evaluationStatus,
    required String reason,
    required TrustRecord record,
    String? simulationGroundTruth,
  }) {
    _eventCounter++;
    final event = TrustScoreChangeEvent(
      eventId: 'trust-evt-$_eventCounter',
      runId: activeRunId,
      observerNodeId: localNodeId,
      targetNodeId: targetNodeId,
      oldScore: oldScore,
      newScore: newScore,
      evidenceType: evidenceType,
      evaluationStatus: evaluationStatus,
      reason: reason,
      totalObservations: record.totalObservations,
      positiveEvidenceSum: record.positiveEvidenceSum,
      negativeEvidenceSum: record.negativeEvidenceSum,
      linkFailureCount: record.linkFailureCount,
      protocolDropCount: record.protocolDropCount,
      relayClaimCount: record.relayClaimCount,
      downstreamConfirmedCount: record.downstreamConfirmedCount,
      deliveryConfirmedCount: record.deliveryConfirmedCount,
      unconfirmedDropCount: record.unconfirmedDropCount,
      thresholdConfig: {
        'initialTrust': config.initialTrust,
        'decayAlpha': config.decayAlpha,
        'isolationThreshold': config.isolationThreshold,
        'minObservations': config.minObservationsForIsolation,
        'routingPolicy': config.routingPolicy.name,
      },
      timestamp: DateTime.now(),
      monotonicMicros: _stopwatch.elapsedMicroseconds,
    );

    _changeHistory.add(event);
    if (_changeHistory.length > 500) {
      _changeHistory.removeAt(0); // Batasi riwayat di memori perangkat
    }

    if (!_eventsController.isClosed) {
      _eventsController.add(event);
    }

    // Integrasikan ke MeshExperimentLogger terpusat jika tersedia
    if (experimentLogger != null) {
      try {
        experimentLogger!.logTrustUpdate(
          targetNodeId: targetNodeId,
          observerNodeId: localNodeId,
          oldScore: oldScore,
          newScore: newScore,
          evidenceType: evidenceType.name,
          evaluationStatus: evaluationStatus.name,
          reason: reason,
          totalObservations: record.totalObservations,
          positiveEvidenceSum: record.positiveEvidenceSum,
          negativeEvidenceSum: record.negativeEvidenceSum,
          linkFailureCount: record.linkFailureCount,
          protocolDropCount: record.protocolDropCount,
          relayClaimCount: record.relayClaimCount,
          downstreamConfirmedCount: record.downstreamConfirmedCount,
          deliveryConfirmedCount: record.deliveryConfirmedCount,
          unconfirmedDropCount: record.unconfirmedDropCount,
          thresholdConfig: {
            'initialTrust': config.initialTrust,
            'decayAlpha': config.decayAlpha,
            'isolationThreshold': config.isolationThreshold,
            'minObservations': config.minObservationsForIsolation,
            'routingPolicy': config.routingPolicy.name,
          },
          runId: activeRunId,
          simulationGroundTruth:
              simulationGroundTruth ?? this.simulationGroundTruth,
        );
      } catch (_) {
        // Kegagalan pencatatan log tidak boleh menghentikan sistem
      }
    }

    if (repository != null) {
      persistState().catchError((_) => false);
    }
  }

  /// Menyimpan seluruh state reputasi node ke [repository] persisten.
  Future<bool> persistState() async {
    if (repository == null) return false;
    try {
      final state = {
        'schemaVersion': 1,
        'savedAt': DateTime.now().toUtc().toIso8601String(),
        'records': _records.map((k, v) => MapEntry(k, v.toMap())),
      };
      return await repository!.saveState(state);
    } catch (_) {
      return false;
    }
  }

  /// Memulihkan state reputasi node dari [repository] persisten.
  Future<bool> restoreState() async {
    if (repository == null) return false;
    try {
      final state = await repository!.loadState();
      if (state == null) return false;
      final version = (state['schemaVersion'] as num?)?.toInt();
      if (version != 1) return false;

      final rawRecords = state['records'];
      if (rawRecords is! Map) return false;

      for (final entry in rawRecords.entries) {
        final nodeId = entry.key.toString();
        if (entry.value is Map) {
          try {
            final record = TrustRecord.fromMap(
              Map<String, dynamic>.from(entry.value as Map),
            );
            _records[nodeId] = record;
          } catch (_) {}
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Membersihkan seluruh rekam jejak reputasi sesi (misal saat reset eksperimen).
  void clear() {
    _records.clear();
    _changeHistory.clear();
  }

  void dispose() {
    _eventsController.close();
  }
}

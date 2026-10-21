/// Definisi tipe data, konfigurasi, status klasifikasi, dan event
/// untuk subsistem Dynamic Trust Management SiagaMesh.
///
/// Mengacu pada rancangan Stage 5A untuk Konfigurasi B (IDS + Dynamic Trust).
library;

import '../ids/ids_types.dart';

/// Status klasifikasi kepercayaan terhadap suatu node.
enum TrustEvaluationStatus {
  /// Node memiliki reputasi baik / terpercaya ($T \ge T_{\text{threshold}}$)
  /// dan memenuhi syarat untuk dipilih sebagai relai pesan.
  trusted,

  /// Node terindikasi tidak kooperatif / tidak terpercaya ($T < T_{\text{threshold}}$)
  /// dengan jumlah observasi yang mencukupi ambang batas minimum.
  untrusted,

  /// Jumlah observasi belum mencukupi batas minimum ($N_{\text{obs}} < N_{\text{min}}$)
  /// untuk mengambil keputusan definitif. Node diperlakukan dengan netral.
  uncertain,
}

/// Kebijakan perutean berbasis skor kepercayaan (*Trust-Aware Forwarding Policy*).
enum TrustRoutingPolicy {
  /// Isolasi ketat: Node berstatus [TrustEvaluationStatus.untrusted] TIDAK AKAN
  /// pernah dipilih sebagai perantara (relai). Jika seluruh tetangga berstatus
  /// untrusted, paket ditahan di Store-and-Forward atau dibuang secara terkendali.
  strictIsolation,

  /// Cadangan dengan peringatan (*fallback*): Prioritaskan peer terpercaya, namun jika
  /// SELURUH peer yang tersedia berstatus untrusted, pilih peer dengan skor tertinggi
  /// disertai pencatatan peringatan eksplisit (mencegah isolasi total jaringan terputus).
  fallbackWithWarning,

  /// Mode pengawasan (*monitoring only*): Skor kepercayaan dihitung dan dicatat
  /// ke log eksperimen, namun tidak mengubah aliran penerusan perutean (controlled flooding murni).
  monitoringOnly,
}

/// Konfigurasi parameter operasional Dynamic Trust Manager.
///
/// PERINGATAN METODOLOGI:
/// Seluruh parameter di bawah ini bersifat provisional (sementara) untuk simulasi
/// dan evaluasi sensitivitas. Nilai ini TIDAK DIKLAIM optimal sebelum uji coba lapangan fisik.
class TrustConfig {
  /// Nilai kepercayaan awal yang diberikan kepada node baru sebelum memiliki riwayat.
  /// Standar provisional: 0.60 (netral cenderung optimis terkendali).
  final double initialTrust;

  /// Faktor peluruhan memori historis ($\alpha \in [0.0, 1.0]$).
  /// Nilai tinggi (misal 0.70) memberi bobot besar pada reputasi historis,
  /// mencegah fluktuasi skor drastis akibat kegagalan tunggal sesaat.
  final double decayAlpha;

  /// Ambang batas isolasi ($T_{\text{threshold}}$).
  /// Jika $T_i < T_{\text{threshold}}$ dan observasi mencukupi, node diklasifikasikan sebagai `untrusted`.
  final double isolationThreshold;

  /// Jumlah observasi minimum sebelum suatu node dapat diklasifikasikan sebagai `untrusted`.
  /// Mencegah penalti dini sebelum cukup bukti statistik terkumpul.
  final int minObservationsForIsolation;

  /// Bobot pengali bukti konfirmasi pengiriman akhir (*deliveryConfirmed*).
  final double weightDeliveryConfirmed;

  /// Bobot pengali bukti verifikasi downstream (*downstreamConfirmed*).
  final double weightDownstreamConfirmed;

  /// Bobot pengali klaim sepihak node relai (*relayClaimed* via Hop ACK).
  /// Diberi diskon (misal 0.60) karena bukan bukti terverifikasi kriptografis.
  final double weightRelayClaimed;

  /// Bobot pengali bukti paket tidak terkonfirmasi / drop pada link aktif (*forwardingUnconfirmed*).
  final double weightUnconfirmedDrop;

  /// Kebijakan perutean aktif saat memilih peer penerus pesan.
  final TrustRoutingPolicy routingPolicy;

  const TrustConfig({
    this.initialTrust = 0.60,
    this.decayAlpha = 0.70,
    this.isolationThreshold = 0.50,
    this.minObservationsForIsolation = 4,
    this.weightDeliveryConfirmed = 1.0,
    this.weightDownstreamConfirmed = 0.90,
    this.weightRelayClaimed = 0.60,
    this.weightUnconfirmedDrop = 1.0,
    this.routingPolicy = TrustRoutingPolicy.strictIsolation,
  });

  TrustConfig copyWith({
    double? initialTrust,
    double? decayAlpha,
    double? isolationThreshold,
    int? minObservationsForIsolation,
    double? weightDeliveryConfirmed,
    double? weightDownstreamConfirmed,
    double? weightRelayClaimed,
    double? weightUnconfirmedDrop,
    TrustRoutingPolicy? routingPolicy,
  }) {
    return TrustConfig(
      initialTrust: initialTrust ?? this.initialTrust,
      decayAlpha: decayAlpha ?? this.decayAlpha,
      isolationThreshold: isolationThreshold ?? this.isolationThreshold,
      minObservationsForIsolation:
          minObservationsForIsolation ?? this.minObservationsForIsolation,
      weightDeliveryConfirmed:
          weightDeliveryConfirmed ?? this.weightDeliveryConfirmed,
      weightDownstreamConfirmed:
          weightDownstreamConfirmed ?? this.weightDownstreamConfirmed,
      weightRelayClaimed: weightRelayClaimed ?? this.weightRelayClaimed,
      weightUnconfirmedDrop:
          weightUnconfirmedDrop ?? this.weightUnconfirmedDrop,
      routingPolicy: routingPolicy ?? this.routingPolicy,
    );
  }
}

/// Rekam jejak statistik dan skor kepercayaan untuk satu node tertentu.
class TrustRecord {
  final String nodeId;
  double currentScore;
  int totalObservations;
  double positiveEvidenceSum;
  double negativeEvidenceSum;
  int linkFailureCount;
  int protocolDropCount;

  /// Dimensi A: Penghitung respons protokol (klaim sepihak Hop ACK tak terverifikasi)
  int relayClaimCount;

  /// Dimensi B1: Verifikasi forwarding tingkat hop downstream
  int downstreamConfirmedCount;

  /// Dimensi B2: Konfirmasi pengiriman ujung-ke-ujung (E2E ACK)
  int deliveryConfirmedCount;

  /// Dimensi C: Kegagalan forwarding terindikasi selective forwarding pada link aktif
  int unconfirmedDropCount;

  DateTime lastUpdated;

  /// Cache ID event atau envelope yang telah diproses untuk menjamin idempotensi
  /// (mencegah pemrosesan ganda / replay manipulation).
  final Set<String> _processedIds = {};

  TrustRecord({
    required this.nodeId,
    required this.currentScore,
    this.totalObservations = 0,
    this.positiveEvidenceSum = 0.0,
    this.negativeEvidenceSum = 0.0,
    this.linkFailureCount = 0,
    this.protocolDropCount = 0,
    this.relayClaimCount = 0,
    this.downstreamConfirmedCount = 0,
    this.deliveryConfirmedCount = 0,
    this.unconfirmedDropCount = 0,
    DateTime? lastUpdated,
  }) : lastUpdated = lastUpdated ?? DateTime.now();

  /// Total interaksi respons protokol (klaim Hop ACK)
  int get protocolResponsivenessCount => relayClaimCount;

  /// Total interaksi forwarding yang benar-benar terverifikasi downstream atau E2E
  int get verifiedForwardingCount =>
      downstreamConfirmedCount + deliveryConfirmedCount;

  bool hasProcessed(String id) => _processedIds.contains(id);

  void markProcessed(String id) => _processedIds.add(id);

  /// Status klasifikasi reputasi node berdasarkan konfigurasi ambang batas.
  TrustEvaluationStatus evaluateStatus(TrustConfig config) {
    if (totalObservations < config.minObservationsForIsolation) {
      return TrustEvaluationStatus.uncertain;
    }
    if (currentScore < config.isolationThreshold) {
      return TrustEvaluationStatus.untrusted;
    }
    return TrustEvaluationStatus.trusted;
  }

  void reset(double initialScore) {
    currentScore = initialScore;
    totalObservations = 0;
    positiveEvidenceSum = 0.0;
    negativeEvidenceSum = 0.0;
    linkFailureCount = 0;
    protocolDropCount = 0;
    relayClaimCount = 0;
    downstreamConfirmedCount = 0;
    deliveryConfirmedCount = 0;
    unconfirmedDropCount = 0;
    _processedIds.clear();
    lastUpdated = DateTime.now();
  }

  Map<String, dynamic> toMap() => {
    'nodeId': nodeId,
    'currentScore': currentScore,
    'totalObservations': totalObservations,
    'positiveEvidenceSum': positiveEvidenceSum,
    'negativeEvidenceSum': negativeEvidenceSum,
    'linkFailureCount': linkFailureCount,
    'protocolDropCount': protocolDropCount,
    'relayClaimCount': relayClaimCount,
    'downstreamConfirmedCount': downstreamConfirmedCount,
    'deliveryConfirmedCount': deliveryConfirmedCount,
    'unconfirmedDropCount': unconfirmedDropCount,
    'lastUpdatedIso': lastUpdated.toUtc().toIso8601String(),
    'processedIds': _processedIds.toList(),
  };

  factory TrustRecord.fromMap(Map<String, dynamic> map) {
    final rawScore = (map['currentScore'] as num?)?.toDouble() ?? 0.60;
    final clampedScore = rawScore.isNaN || rawScore.isInfinite
        ? 0.60
        : rawScore.clamp(0.0, 1.0);

    final record = TrustRecord(
      nodeId: map['nodeId'] as String,
      currentScore: clampedScore,
      totalObservations: (map['totalObservations'] as num?)?.toInt() ?? 0,
      positiveEvidenceSum:
          (map['positiveEvidenceSum'] as num?)?.toDouble() ?? 0.0,
      negativeEvidenceSum:
          (map['negativeEvidenceSum'] as num?)?.toDouble() ?? 0.0,
      linkFailureCount: (map['linkFailureCount'] as num?)?.toInt() ?? 0,
      protocolDropCount: (map['protocolDropCount'] as num?)?.toInt() ?? 0,
      relayClaimCount: (map['relayClaimCount'] as num?)?.toInt() ?? 0,
      downstreamConfirmedCount:
          (map['downstreamConfirmedCount'] as num?)?.toInt() ?? 0,
      deliveryConfirmedCount:
          (map['deliveryConfirmedCount'] as num?)?.toInt() ?? 0,
      unconfirmedDropCount: (map['unconfirmedDropCount'] as num?)?.toInt() ?? 0,
      lastUpdated: map['lastUpdatedIso'] != null
          ? DateTime.tryParse(map['lastUpdatedIso'] as String)?.toUtc() ??
                DateTime.now().toUtc()
          : DateTime.now().toUtc(),
    );

    final processed = map['processedIds'] as List? ?? [];
    for (final id in processed) {
      if (id != null) {
        record.markProcessed(id.toString());
      }
    }
    return record;
  }
}

/// Representasi data peristiwa pembaruan skor kepercayaan (*Trust Score Change Event*).
class TrustScoreChangeEvent {
  final String eventId;
  final String runId;
  final String observerNodeId;
  final String targetNodeId;
  final double oldScore;
  final double newScore;
  final ForwardingEvidenceType evidenceType;
  final TrustEvaluationStatus evaluationStatus;
  final String reason;
  final int totalObservations;
  final double positiveEvidenceSum;
  final double negativeEvidenceSum;
  final int linkFailureCount;
  final int protocolDropCount;
  final int relayClaimCount;
  final int downstreamConfirmedCount;
  final int deliveryConfirmedCount;
  final int unconfirmedDropCount;
  final Map<String, dynamic> thresholdConfig;
  final DateTime timestamp;
  final int monotonicMicros;

  const TrustScoreChangeEvent({
    required this.eventId,
    required this.runId,
    required this.observerNodeId,
    required this.targetNodeId,
    required this.oldScore,
    required this.newScore,
    required this.evidenceType,
    required this.evaluationStatus,
    required this.reason,
    required this.totalObservations,
    required this.positiveEvidenceSum,
    required this.negativeEvidenceSum,
    required this.linkFailureCount,
    required this.protocolDropCount,
    this.relayClaimCount = 0,
    this.downstreamConfirmedCount = 0,
    this.deliveryConfirmedCount = 0,
    this.unconfirmedDropCount = 0,
    required this.thresholdConfig,
    required this.timestamp,
    required this.monotonicMicros,
  });

  /// Total interaksi respons protokol (klaim Hop ACK)
  int get protocolResponsivenessCount => relayClaimCount;

  /// Total interaksi forwarding yang benar-benar terverifikasi downstream atau E2E
  int get verifiedForwardingCount =>
      downstreamConfirmedCount + deliveryConfirmedCount;

  Map<String, dynamic> toJson() => {
    'eventId': eventId,
    'runId': runId,
    'observerNodeId': observerNodeId,
    'targetNodeId': targetNodeId,
    'oldScore': oldScore,
    'newScore': newScore,
    'delta': newScore - oldScore,
    'evidenceType': evidenceType.name,
    'evaluationStatus': evaluationStatus.name,
    'reason': reason,
    'totalObservations': totalObservations,
    'positiveEvidenceSum': positiveEvidenceSum,
    'negativeEvidenceSum': negativeEvidenceSum,
    'linkFailureCount': linkFailureCount,
    'protocolDropCount': protocolDropCount,
    'relayClaimCount': relayClaimCount,
    'downstreamConfirmedCount': downstreamConfirmedCount,
    'deliveryConfirmedCount': deliveryConfirmedCount,
    'unconfirmedDropCount': unconfirmedDropCount,
    'protocolResponsivenessCount': protocolResponsivenessCount,
    'verifiedForwardingCount': verifiedForwardingCount,
    'thresholdConfig': thresholdConfig,
    'timestampMs': timestamp.millisecondsSinceEpoch,
    'timestampIso': timestamp.toIso8601String(),
    'monotonicMicros': monotonicMicros,
  };

  @override
  String toString() =>
      'TrustScoreChangeEvent(target: $targetNodeId, old: ${oldScore.toStringAsFixed(2)}, new: ${newScore.toStringAsFixed(2)}, status: ${evaluationStatus.name}, reason: $reason)';
}

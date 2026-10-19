/// Definisi tipe data, semantik bukti, dan status deteksi IDS SiagaMesh.
///
/// Mengacu pada rancangan Stage 5A untuk deteksi serangan Selective Forwarding
/// pada jaringan MANET darurat.
library;

/// Kategori semantik bukti pengamatan penerusan pesan (*Forwarding Evidence*).
///
/// Hierarki verifikasi bukti (dari terlemah hingga terkuat):
/// 1. [receiptConfirmed]: Konfirmasi penerimaan 1-hop oleh tetangga langsung.
/// 2. [forwardingExpected]: Protokol mewajibkan tetangga meneruskan pesan (TTL > 1).
/// 3. [relayClaimed]: Node relai mengklaim telah merelai paket (melalui Hop ACK).
///    PERINGATAN SEMANTIK: Bukti ini merupakan klaim sepihak node relai (*unauthenticated relay claim*),
///    BUKAN verifikasi kriptografis bahwa hop downstream benar-benar menerima paket.
/// 4. [downstreamConfirmed]: Konfirmasi bahwa hop downstream (node berikutnya setelah relai) telah menerima paket.
/// 5. [deliveryConfirmed]: Konfirmasi penerimaan akhir oleh recipient tujuan (End-to-End Delivery ACK).
/// 6. [forwardingUnconfirmed]: Timeout tanpa bukti/klaim pada link aktif.
/// 7. [linkFailureSuspected]: Terputus alami (Link Failure).
/// 8. [protocolDrop]: Pembuangan sah berdasarkan aturan protokol (TTL, Dedup, Loop).
enum ForwardingEvidenceType {
  receiptConfirmed,
  forwardingExpected,
  relayClaimed,
  downstreamConfirmed,
  deliveryConfirmed,
  forwardingUnconfirmed,
  linkFailureSuspected,
  protocolDrop,

  /// Alias kompatibilitas ke belakang untuk [relayClaimed].
  @Deprecated(
    'Gunakan relayClaimed untuk mencerminkan semantik klaim node relai',
  )
  forwardingConfirmed,
}

/// Status klasifikasi perilaku node oleh IDS.
enum NodeDetectionStatus {
  /// Perilaku forwarding node berada dalam batas normal / kooperatif.
  normal,

  /// Node terindikasi melakukan selective forwarding (rasio kegagalan penerusan melampaui ambang batas pada link aktif).
  suspected,

  /// Jumlah observasi pesan belum mencukupi batas minimum untuk penentuan status yang valid secara statistik.
  insufficientEvidence,
}

/// Label Ground Truth independen untuk evaluasi benchmark dan simulasi pengujian.
/// Label ini independen dari output detektor IDS.
enum NodeGroundTruth {
  /// Node berperilaku normal dan kooperatif meneruskan semua pesan yang sah.
  normal,

  /// Node penyerang yang sengaja menjatuhkan sebagian atau seluruh paket yang seharusnya diteruskan.
  maliciousSelectiveForwarder,

  /// Node normal yang mengalami gangguan konektivitas / radio terputus (bukan penyerang).
  unstableLink,

  /// Node normal yang menolak paket karena aturan protokol yang sah (misal TTL habis).
  protocolDropCompliant,
}

/// Representasi data peristiwa deteksi keamanan yang dihasilkan oleh IDS.
class IdsDetectionEvent {
  final String eventId;
  final String runId;
  final String observerNodeId;
  final String targetNodeId;
  final NodeDetectionStatus status;
  final double observedDropRate;
  final int totalExpected;
  final int totalClaimed;
  final int totalUnconfirmed;
  final int totalLinkFailures;
  final int totalProtocolDrops;
  final String reason;
  final DateTime timestamp;
  final int monotonicMicros;

  /// Alias kompatibilitas untuk [totalClaimed].
  int get totalConfirmed => totalClaimed;

  const IdsDetectionEvent({
    required this.eventId,
    required this.runId,
    required this.observerNodeId,
    required this.targetNodeId,
    required this.status,
    required this.observedDropRate,
    required this.totalExpected,
    int? totalConfirmed,
    int? totalClaimed,
    required this.totalUnconfirmed,
    required this.totalLinkFailures,
    required this.totalProtocolDrops,
    required this.reason,
    required this.timestamp,
    required this.monotonicMicros,
  }) : totalClaimed = totalClaimed ?? totalConfirmed ?? 0;

  Map<String, dynamic> toJson() => {
    'eventId': eventId,
    'runId': runId,
    'observerNodeId': observerNodeId,
    'targetNodeId': targetNodeId,
    'status': status.name,
    'observedDropRate': observedDropRate,
    'totalExpected': totalExpected,
    'totalClaimed': totalClaimed,
    'totalConfirmed': totalConfirmed,
    'totalUnconfirmed': totalUnconfirmed,
    'totalLinkFailures': totalLinkFailures,
    'totalProtocolDrops': totalProtocolDrops,
    'reason': reason,
    'timestampMs': timestamp.millisecondsSinceEpoch,
    'timestampIso': timestamp.toIso8601String(),
    'monotonicMicros': monotonicMicros,
  };

  @override
  String toString() =>
      'IdsDetectionEvent(target: $targetNodeId, status: ${status.name}, dropRate: ${(observedDropRate * 100).toStringAsFixed(1)}%, reason: $reason)';
}

/// Evaluator metrik performa IDS (Confusion Matrix, Recall/TPR, False Positive Rate/FPR).
class IdsMetricsEvaluator {
  final int truePositives;
  final int falsePositives;
  final int trueNegatives;
  final int falseNegatives;

  const IdsMetricsEvaluator({
    required this.truePositives,
    required this.falsePositives,
    required this.trueNegatives,
    required this.falseNegatives,
  });

  /// True Positive Rate (TPR) / Detection Rate / Recall = TP / (TP + FN).
  /// Mengembalikan `null` jika penyebut bernilai nol (tidak terdefinisi).
  double? get detectionRate {
    final denominator = truePositives + falseNegatives;
    if (denominator == 0) return null;
    return truePositives / denominator;
  }

  /// False Positive Rate (FPR) = FP / (FP + TN).
  /// Mengembalikan `null` jika penyebut bernilai nol (tidak terdefinisi).
  double? get falsePositiveRate {
    final denominator = falsePositives + trueNegatives;
    if (denominator == 0) return null;
    return falsePositives / denominator;
  }

  /// Evaluasi terhadap peta ground truth dan prediksi status setiap node.
  /// Unit evaluasi: Keputusan klasifikasi per node pada satu jendela eksperimen.
  factory IdsMetricsEvaluator.evaluate({
    required Map<String, NodeGroundTruth> groundTruths,
    required Map<String, NodeDetectionStatus> predictions,
  }) {
    int tp = 0;
    int fp = 0;
    int tn = 0;
    int fn = 0;

    for (final entry in groundTruths.entries) {
      final nodeId = entry.key;
      final truth = entry.value;
      final pred =
          predictions[nodeId] ?? NodeDetectionStatus.insufficientEvidence;

      final isActuallyMalicious =
          truth == NodeGroundTruth.maliciousSelectiveForwarder;
      final isPredictedMalicious = pred == NodeDetectionStatus.suspected;

      if (isActuallyMalicious) {
        if (isPredictedMalicious) {
          tp++;
        } else {
          fn++;
        }
      } else {
        if (isPredictedMalicious) {
          fp++;
        } else {
          tn++;
        }
      }
    }

    return IdsMetricsEvaluator(
      truePositives: tp,
      falsePositives: fp,
      trueNegatives: tn,
      falseNegatives: fn,
    );
  }

  Map<String, dynamic> toSummaryMap() => {
    'truePositives': truePositives,
    'falsePositives': falsePositives,
    'trueNegatives': trueNegatives,
    'falseNegatives': falseNegatives,
    'detectionRate': detectionRate,
    'falsePositiveRate': falsePositiveRate,
  };

  @override
  String toString() {
    final drStr = detectionRate != null
        ? '${(detectionRate! * 100).toStringAsFixed(1)}%'
        : 'N/A';
    final fprStr = falsePositiveRate != null
        ? '${(falsePositiveRate! * 100).toStringAsFixed(1)}%'
        : 'N/A';
    return 'IdsMetrics(TP: $truePositives, FP: $falsePositives, TN: $trueNegatives, FN: $falseNegatives, Recall: $drStr, FPR: $fprStr)';
  }
}

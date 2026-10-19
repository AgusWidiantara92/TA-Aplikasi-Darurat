import 'dart:math';
import '../routing/message_envelope.dart';
import 'ids_types.dart';

/// Mode perilaku forwarding node pada lingkungan simulasi uji terkendali.
enum ForwardingBehaviorMode {
  /// Meneruskan seluruh paket secara kooperatif dan mengirimkan HOP_ACK.
  normal,

  /// Menjatuhkan seluruh paket yang seharusnya diteruskan (Blackhole / 100% Selective Drop).
  dropAll,

  /// Menjatuhkan sebagian paket secara deterministik berdasarkan rasio drop tertentu (misal 50%).
  selectiveDropRatio,

  /// Menjatuhkan paket secara periodik (misal setiap paket ke-N).
  dropPeriodic,

  /// Mensimulasikan kondisi link terputus (radio disconnect).
  disconnected,

  /// Menjatuhkan paket karena aturan protokol sah (TTL habis, duplikat, dsb).
  protocolDropCompliant,
}

/// Konfigurasi perilaku simulasi untuk satu node virtual dalam pengujian.
class NodeSimulationProfile {
  final String nodeId;
  final ForwardingBehaviorMode mode;
  final NodeGroundTruth groundTruth;
  final double dropRatio;
  final int dropInterval;

  int _transmittedCounter = 0;
  int _droppedCounter = 0;

  NodeSimulationProfile({
    required this.nodeId,
    required this.mode,
    required this.groundTruth,
    this.dropRatio = 0.5,
    this.dropInterval = 2,
  });

  /// Factory untuk node normal (Ground Truth = Normal).
  factory NodeSimulationProfile.normal(String nodeId) => NodeSimulationProfile(
    nodeId: nodeId,
    mode: ForwardingBehaviorMode.normal,
    groundTruth: NodeGroundTruth.normal,
  );

  /// Factory untuk node penyerang selective forwarding (Ground Truth = Malicious).
  factory NodeSimulationProfile.selectiveDrop(
    String nodeId, {
    double ratio = 0.5,
    int interval = 2,
  }) => NodeSimulationProfile(
    nodeId: nodeId,
    mode: ForwardingBehaviorMode.dropPeriodic,
    groundTruth: NodeGroundTruth.maliciousSelectiveForwarder,
    dropRatio: ratio,
    dropInterval: interval,
  );

  /// Factory untuk node penyerang blackhole 100% drop (Ground Truth = Malicious).
  factory NodeSimulationProfile.dropAll(String nodeId) => NodeSimulationProfile(
    nodeId: nodeId,
    mode: ForwardingBehaviorMode.dropAll,
    groundTruth: NodeGroundTruth.maliciousSelectiveForwarder,
  );

  /// Factory untuk node dengan gangguan konektivitas (Ground Truth = UnstableLink).
  factory NodeSimulationProfile.disconnected(String nodeId) =>
      NodeSimulationProfile(
        nodeId: nodeId,
        mode: ForwardingBehaviorMode.disconnected,
        groundTruth: NodeGroundTruth.unstableLink,
      );

  /// Factory untuk node protokol sah (Ground Truth = ProtocolDropCompliant).
  factory NodeSimulationProfile.protocolCompliant(String nodeId) =>
      NodeSimulationProfile(
        nodeId: nodeId,
        mode: ForwardingBehaviorMode.protocolDropCompliant,
        groundTruth: NodeGroundTruth.protocolDropCompliant,
      );

  int get transmittedCount => _transmittedCounter;
  int get droppedCount => _droppedCounter;

  /// Menentukan secara deterministik apakah paket harus dijatuhkan berdasarkan profil node.
  bool shouldDrop(MessageEnvelope envelope, {int? seed}) {
    switch (mode) {
      case ForwardingBehaviorMode.normal:
        _transmittedCounter++;
        return false;

      case ForwardingBehaviorMode.dropAll:
        _droppedCounter++;
        return true;

      case ForwardingBehaviorMode.dropPeriodic:
        // Pola deterministik: Jatuhkan setiap ke-N paket
        final isDrop =
            (_transmittedCounter + _droppedCounter) % dropInterval == 0;
        if (isDrop) {
          _droppedCounter++;
        } else {
          _transmittedCounter++;
        }
        return isDrop;

      case ForwardingBehaviorMode.selectiveDropRatio:
        final random = Random(
          seed ?? (_transmittedCounter + _droppedCounter + 42),
        );
        final isDrop = random.nextDouble() < dropRatio;
        if (isDrop) {
          _droppedCounter++;
        } else {
          _transmittedCounter++;
        }
        return isDrop;

      case ForwardingBehaviorMode.disconnected:
      case ForwardingBehaviorMode.protocolDropCompliant:
        _droppedCounter++;
        return true;
    }
  }

  void reset() {
    _transmittedCounter = 0;
    _droppedCounter = 0;
  }
}

/// Fixture pengujian untuk mengelola Ground Truth independen dan menyimulasikan
/// serangan selective forwarding secara terkendali dan deterministik.
class SelectiveForwardingSimulationFixture {
  final Map<String, NodeSimulationProfile> _profiles = {};

  void registerNodeProfile(NodeSimulationProfile profile) {
    _profiles[profile.nodeId] = profile;
  }

  NodeSimulationProfile? getProfile(String nodeId) => _profiles[nodeId];

  /// Mengambil peta label Ground Truth independen untuk seluruh node terdaftar.
  Map<String, NodeGroundTruth> get groundTruths => {
    for (final entry in _profiles.entries) entry.key: entry.value.groundTruth,
  };

  /// Mengevaluasi apakah node tertentu harus menjatuhkan paket dalam simulasi.
  bool shouldDrop(String nodeId, MessageEnvelope envelope, {int? seed}) {
    final profile = _profiles[nodeId];
    if (profile == null) return false; // Default normal jika tidak terdaftar
    return profile.shouldDrop(envelope, seed: seed);
  }

  /// Menghitung Confusion Matrix dan metrik deteksi (TPR, FPR) terhadap output detektor.
  IdsMetricsEvaluator evaluateDetectorPredictions(
    Map<String, NodeDetectionStatus> predictions,
  ) {
    return IdsMetricsEvaluator.evaluate(
      groundTruths: groundTruths,
      predictions: predictions,
    );
  }

  void resetAll() {
    for (final p in _profiles.values) {
      p.reset();
    }
  }
}

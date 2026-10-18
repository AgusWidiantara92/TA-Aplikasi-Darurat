enum MeshNodeStatus { connected, available, connecting }

/// Model data perangkat sekitar (mock node) untuk halaman Perangkat Terdekat & Radar.
class MeshNode {
  final String id;
  final String name;
  final String distanceText;
  final String signalQuality;
  final MeshNodeStatus status;
  final String subInfo;
  final bool isEmergencyChannel;
  final double radarAngle; // Posisi sudut pada radar visual (radian)
  final double radarRadiusRatio; // Jarak relatif dari pusat radar (0.0 - 1.0)

  const MeshNode({
    required this.id,
    required this.name,
    required this.distanceText,
    required this.signalQuality,
    required this.status,
    required this.subInfo,
    this.isEmergencyChannel = false,
    this.radarAngle = 0.0,
    this.radarRadiusRatio = 0.5,
  });
}

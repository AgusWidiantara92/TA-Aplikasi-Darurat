import 'dart:convert';
import 'dart:typed_data';
import '../../features/chat/models/chat_message.dart';

/// Struktur envelope payload data untuk eksperimen transport 1-hop SiagaMesh.
///
/// PERHATIAN KEAMANAN: Pada tahap 1-hop ini, [senderNodeId] belum diautentikasi
/// secara kriptografis (misalnya dengan tanda tangan digital atau sertifikat).
/// Perlindungan terhadap pemalsuan identitas (spoofing) akan diintegrasikan pada
/// tahap lanjutan arsitektur keamanan.
class OneHopPayloadEnvelope {
  static const int currentVersion = 1;
  static const int maxPayloadSizeBytes =
      32768; // Batas aman 32 KB untuk transfer teks & telemetri

  final int version;
  final String messageId;
  final String type; // e.g. 'CHAT_1HOP', 'ACK_1HOP', 'BEACON_1HOP'
  final String senderNodeId;
  final String senderName;
  final int timestamp;
  final String text;
  final TelemetryData? telemetry;

  const OneHopPayloadEnvelope({
    this.version = currentVersion,
    required this.messageId,
    required this.type,
    required this.senderNodeId,
    required this.senderName,
    required this.timestamp,
    required this.text,
    this.telemetry,
  });

  Map<String, dynamic> toJson() => {
    'version': version,
    'messageId': messageId,
    'type': type,
    'senderNodeId': senderNodeId,
    'senderName': senderName,
    'timestamp': timestamp,
    'text': text,
    'telemetry': telemetry?.toJson(),
  };

  /// Mengonversi envelope menjadi array byte UTF-8 JSON yang siap dikirim melalui transport.
  Uint8List toBytes() {
    final jsonStr = jsonEncode(toJson());
    return Uint8List.fromList(utf8.encode(jsonStr));
  }

  /// Membaca array byte dari transport dan memvalidasi integritas format JSON.
  ///
  /// Mengembalikan `null` secara aman jika data melebihi batas ukuran, korup,
  /// atau tidak sesuai dengan spesifikasi envelope yang didukung.
  static OneHopPayloadEnvelope? fromBytes(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxPayloadSizeBytes) {
      return null;
    }

    try {
      final jsonStr = utf8.decode(bytes);
      final dynamic decoded = jsonDecode(jsonStr);

      if (decoded is! Map<String, dynamic>) {
        return null;
      }

      final version = decoded['version'] as int? ?? 1;
      if (version > currentVersion) {
        // Menolak versi protokol masa depan yang belum didukung
        return null;
      }

      final messageId = decoded['messageId'] as String?;
      final type = decoded['type'] as String?;
      final senderNodeId = decoded['senderNodeId'] as String?;
      final senderName = decoded['senderName'] as String?;
      final timestamp = decoded['timestamp'] as int?;
      final text = decoded['text'] as String? ?? '';

      if (messageId == null ||
          type == null ||
          senderNodeId == null ||
          senderName == null ||
          timestamp == null) {
        return null;
      }

      TelemetryData? telemetry;
      if (decoded['telemetry'] != null &&
          decoded['telemetry'] is Map<String, dynamic>) {
        try {
          telemetry = TelemetryData.fromJson(
            decoded['telemetry'] as Map<String, dynamic>,
          );
        } catch (_) {
          telemetry = null;
        }
      }

      return OneHopPayloadEnvelope(
        version: version,
        messageId: messageId,
        type: type,
        senderNodeId: senderNodeId,
        senderName: senderName,
        timestamp: timestamp,
        text: text,
        telemetry: telemetry,
      );
    } catch (_) {
      // Penanganan aman: jika JSON corrupt, return null tanpa melempar exception fatal
      return null;
    }
  }
}

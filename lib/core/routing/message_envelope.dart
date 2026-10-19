import 'dart:convert';
import 'dart:typed_data';

/// Struktur envelope pesan perutean MANET multi-hop SiagaMesh sesuai perancangan Stage 5A.
///
/// Membawa metadata perutean (TTL, jejak hop, pengalamatan asal & tujuan)
/// serta payload data pesan obrolan atau handshake antar-node.
class MessageEnvelope {
  static const int currentVersion = 1;
  static const int defaultTtl = 5;
  static const int maxPayloadBytes =
      32768; // 32 KB batas aman untuk transfer nirkabel

  static const String typeChat = 'CHAT_MESSAGE';
  static const String typeHandshake = 'PEER_HANDSHAKE';
  static const String typeHopAck = 'HOP_ACK';
  static const String typeE2eAck = 'E2E_ACK';

  final int version;
  final String envelopeId;
  final String type;
  final String senderId;
  final String senderName;
  final String recipientId;
  final int createdAt;
  final int ttl;
  final int hopCount;
  final List<String> routeTrace;
  final Map<String, dynamic> payload;

  const MessageEnvelope({
    this.version = currentVersion,
    required this.envelopeId,
    required this.type,
    required this.senderId,
    required this.senderName,
    required this.recipientId,
    required this.createdAt,
    this.ttl = defaultTtl,
    this.hopCount = 0,
    required this.routeTrace,
    required this.payload,
  });

  /// Membuat salinan envelope untuk diteruskan (*forwarded*) oleh node perantara.
  ///
  /// Mengurangi [ttl] sebesar 1, menambah [hopCount] sebesar 1, dan menambahkan
  /// [localNodeId] ke dalam [routeTrace] untuk pencegahan loop perutean.
  MessageEnvelope createForwardedCopy(String localNodeId) {
    return MessageEnvelope(
      version: version,
      envelopeId: envelopeId,
      type: type,
      senderId: senderId,
      senderName: senderName,
      recipientId: recipientId,
      createdAt: createdAt,
      ttl: ttl - 1,
      hopCount: hopCount + 1,
      routeTrace: [...routeTrace, localNodeId],
      payload: Map<String, dynamic>.from(payload),
    );
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'envelopeId': envelopeId,
    'type': type,
    'senderId': senderId,
    'senderName': senderName,
    'recipientId': recipientId,
    'createdAt': createdAt,
    'ttl': ttl,
    'hopCount': hopCount,
    'routeTrace': routeTrace,
    'payload': payload,
  };

  Uint8List toBytes() {
    final jsonStr = jsonEncode(toJson());
    return Uint8List.fromList(utf8.encode(jsonStr));
  }

  /// Membaca Map JSON dan memvalidasi struktur envelope perutean.
  ///
  /// Mengembalikan `null` secara aman jika data korup, tidak lengkap,
  /// atau menggunakan versi yang belum didukung.
  static MessageEnvelope? fromMap(Map<String, dynamic> decoded) {
    final version = decoded['version'] as int? ?? 1;
    if (version > currentVersion) {
      return null; // Tolak versi masa depan
    }

    final envelopeId = decoded['envelopeId'] as String?;
    final type = decoded['type'] as String?;
    final senderId = decoded['senderId'] as String?;
    final senderName = decoded['senderName'] as String?;
    final recipientId = decoded['recipientId'] as String?;
    final createdAt = decoded['createdAt'] as int?;
    final ttl = decoded['ttl'] as int? ?? defaultTtl;
    final hopCount = decoded['hopCount'] as int? ?? 0;
    final rawRouteTrace = decoded['routeTrace'] as List<dynamic>? ?? [];
    final payload = decoded['payload'] as Map<String, dynamic>? ?? {};

    if (envelopeId == null ||
        type == null ||
        senderId == null ||
        senderName == null ||
        recipientId == null ||
        createdAt == null) {
      return null;
    }

    final routeTrace = rawRouteTrace.map((e) => e.toString()).toList();

    return MessageEnvelope(
      version: version,
      envelopeId: envelopeId,
      type: type,
      senderId: senderId,
      senderName: senderName,
      recipientId: recipientId,
      createdAt: createdAt,
      ttl: ttl,
      hopCount: hopCount,
      routeTrace: routeTrace,
      payload: payload,
    );
  }

  /// Membaca array byte dari transport dan memvalidasi struktur envelope perutean.
  ///
  /// Mengembalikan `null` secara aman jika data korup, tidak lengkap,
  /// melebihi batas ukuran, atau menggunakan versi yang belum didukung.
  static MessageEnvelope? fromBytes(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxPayloadBytes) {
      return null;
    }

    try {
      final jsonStr = utf8.decode(bytes);
      final dynamic decoded = jsonDecode(jsonStr);

      if (decoded is! Map<String, dynamic>) {
        return null;
      }

      return fromMap(decoded);
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() =>
      'MessageEnvelope(id: $envelopeId, type: $type, from: $senderId, to: $recipientId, ttl: $ttl, hops: $hopCount)';
}

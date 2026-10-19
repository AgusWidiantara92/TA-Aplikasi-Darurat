import 'message_envelope.dart';

/// Item antrean pada buffer store-and-forward.
class QueuedEnvelopeItem {
  final MessageEnvelope envelope;
  final int enqueuedAt;
  int retryAttempts;

  QueuedEnvelopeItem({
    required this.envelope,
    required this.enqueuedAt,
    this.retryAttempts = 0,
  });

  bool isExpired(int now, int maxTtlMs) {
    return (now - enqueuedAt) > maxTtlMs;
  }
}

/// Buffer penyimpanan sementara (*Store-and-Forward Queue*) untuk menampung pesan
/// ketika tautan nirkabel ke node tujuan atau hop berikutnya belum tersedia.
class StoreAndForwardQueue {
  static const int defaultMaxCapacity = 50;
  static const int defaultExpiryMs = 600000; // 10 menit

  final int maxCapacity;
  final int expiryMs;
  final List<QueuedEnvelopeItem> _queue = [];

  StoreAndForwardQueue({
    this.maxCapacity = defaultMaxCapacity,
    this.expiryMs = defaultExpiryMs,
  });

  /// Memasukkan envelope ke antrean penyimpanan.
  ///
  /// Mengembalikan `true` jika berhasil diantrekan.
  /// Jika kapasitas penuh, pesan tertua yang bukan darurat akan dikeluarkan.
  bool enqueue(MessageEnvelope envelope) {
    cleanExpired();

    // Cek apakah pesan dengan ID ini sudah ada di antrean
    final existingIndex = _queue.indexWhere(
      (item) => item.envelope.envelopeId == envelope.envelopeId,
    );
    if (existingIndex != -1) {
      return false; // Jangan duplikasi di antrean
    }

    if (_queue.length >= maxCapacity) {
      // Cari pesan tertua yang bukan darurat untuk dikeluarkan
      final nonEmergencyIndex = _queue.indexWhere(
        (item) => item.envelope.payload['isEmergency'] != true,
      );
      if (nonEmergencyIndex != -1) {
        _queue.removeAt(nonEmergencyIndex);
      } else {
        // Jika semuanya darurat, tolak pesan baru agar buffer tidak meledak
        return false;
      }
    }

    _queue.add(
      QueuedEnvelopeItem(
        envelope: envelope,
        enqueuedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    return true;
  }

  /// Mengambil daftar envelope yang ditujukan untuk [targetNodeId] tertentu atau siaran umum.
  List<MessageEnvelope> getPendingForTarget(String targetNodeId) {
    cleanExpired();
    return _queue
        .where(
          (item) =>
              item.envelope.recipientId == targetNodeId ||
              item.envelope.recipientId == 'BROADCAST',
        )
        .map((item) => item.envelope)
        .toList();
  }

  /// Mengambil seluruh pesan siaran yang tertunda.
  List<MessageEnvelope> getPendingBroadcasts() {
    cleanExpired();
    return _queue
        .where((item) => item.envelope.recipientId == 'BROADCAST')
        .map((item) => item.envelope)
        .toList();
  }

  /// Mengambil seluruh pesan tertunda dalam antrean.
  List<MessageEnvelope> get allPending {
    cleanExpired();
    return _queue.map((item) => item.envelope).toList();
  }

  /// Menghapus pesan dari antrean setelah berhasil diteruskan.
  void remove(String envelopeId) {
    _queue.removeWhere((item) => item.envelope.envelopeId == envelopeId);
  }

  /// Menghapus pesan dari antrean berdasarkan payload messageId atau envelopeId.
  /// Mengembalikan `true` jika setidaknya satu pesan berhasil dihapus/dibatalkan.
  bool removeByMessageId(String messageId) {
    final initialLen = _queue.length;
    _queue.removeWhere((item) {
      final env = item.envelope;
      final envMsgId = env.payload['messageId'] as String? ?? env.envelopeId;
      return envMsgId == messageId || env.envelopeId == messageId;
    });
    return _queue.length < initialLen;
  }

  /// Memeriksa apakah pesan dengan messageId atau envelopeId masih ada di antrean.
  bool containsMessageId(String messageId) {
    cleanExpired();
    return _queue.any((item) {
      final env = item.envelope;
      final envMsgId = env.payload['messageId'] as String? ?? env.envelopeId;
      return envMsgId == messageId || env.envelopeId == messageId;
    });
  }

  /// Membersihkan pesan-pesan yang telah kedaluwarsa.
  void cleanExpired() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _queue.removeWhere((item) => item.isExpired(now, expiryMs));
  }

  int get length => _queue.length;

  /// Memeriksa apakah pesan dengan [envelopeId] tertentu masih ada di antrean.
  bool contains(String envelopeId) {
    cleanExpired();
    return _queue.any((item) => item.envelope.envelopeId == envelopeId);
  }

  void clear() => _queue.clear();
}

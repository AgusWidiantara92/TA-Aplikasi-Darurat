import 'dart:collection';

/// Cache deduplikasi pesan berbasis LRU (Least Recently Used)
/// untuk mencegah pesan duplikat terus beredar dan menghentikan broadcast storm.
class DeduplicationCache {
  static const int defaultCapacity = 500;

  final int capacity;
  final LinkedHashSet<String> _cache = LinkedHashSet<String>();

  DeduplicationCache({this.capacity = defaultCapacity});

  /// Memeriksa apakah [envelopeId] sudah pernah dilihat.
  bool contains(String envelopeId) => _cache.contains(envelopeId);

  /// Menambahkan [envelopeId] ke cache. Jika kapasitas melebihi batas,
  /// elemen tertua (paling awal masuk) akan dikeluarkan.
  void add(String envelopeId) {
    if (_cache.contains(envelopeId)) {
      // Refresh posisi agar menjadi yang terbaru
      _cache.remove(envelopeId);
    } else if (_cache.length >= capacity) {
      // Hapus elemen tertua di awal set
      _cache.remove(_cache.first);
    }
    _cache.add(envelopeId);
  }

  /// Memeriksa apakah pesan duplikat.
  ///
  /// Mengembalikan `true` jika [envelopeId] sudah ada di cache (duplikat).
  /// Mengembalikan `false` jika pesan baru, dan langsung menyimpannya ke cache.
  bool checkAndAdd(String envelopeId) {
    if (contains(envelopeId)) {
      return true; // Duplikat!
    }
    add(envelopeId);
    return false; // Pesan baru
  }

  int get length => _cache.length;

  void clear() => _cache.clear();
}

/// Pool penyimpanan sementara untuk blok yatim (Orphan Block Pool) BlockDAG SiagaMesh.
///
/// Bertanggung jawab untuk:
/// 1. Menampung blok-blok remote yang valid secara intrinsik tetapi parent-nya belum
///    tersedia di ledger lokal (*missingParent*).
/// 2. Menerapkan pembatasan kapasitas deterministik ketat (maksimum 20 blok) dan TTL (60 detik)
///    untuk mencegah kelelahan memori (*memory exhaustion* / buffer-bloat) pada perangkat seluler Android.
/// 3. Mencegah monopoli pool oleh satu peer tertentu (*per-peer quota limit*).
/// 4. Menyediakan metode pencarian terurut (*topological candidate resolution*) saat parent tiba.
/// 5. Strictly in-memory: tidak pernah disimpan ke repositori ledger persisten sebelum divalidasi penuh.
library;

import '../blockchain_types.dart';
import '../lightweight_blockdag_ledger.dart';
import 'gossip_constants.dart';

/// Status hasil penambahan blok ke dalam [OrphanBlockPool].
enum OrphanPoolAddStatus {
  /// Blok berhasil ditahan sementara di dalam pool menunggu kedatangan parent.
  added,

  /// Blok sudah ada di dalam pool (duplikasi hash diabaikan tanpa memperpanjang TTL).
  duplicate,

  /// Pool telah mencapai kapasitas maksimum (20 blok).
  poolFull,

  /// Kuota entri untuk peer pengirim telah habis.
  peerQuotaExceeded,

  /// Blok bukan merupakan orphan (seluruh parent sudah ada di ledger/checkpoint).
  notOrphan,
}

/// Hasil operasi penambahan blok ke dalam [OrphanBlockPool].
class OrphanPoolAddResult {
  final OrphanPoolAddStatus status;
  final String? message;

  const OrphanPoolAddResult(this.status, [this.message]);

  bool get isAdded => status == OrphanPoolAddStatus.added;
  bool get isDuplicate => status == OrphanPoolAddStatus.duplicate;
  bool get isFull => status == OrphanPoolAddStatus.poolFull;
  bool get isPeerQuotaExceeded =>
      status == OrphanPoolAddStatus.peerQuotaExceeded;
  bool get isNotOrphan => status == OrphanPoolAddStatus.notOrphan;

  @override
  String toString() =>
      'OrphanPoolAddResult($status${message != null ? ': $message' : ''})';
}

/// Entri satu blok yatim yang ditahan di dalam [OrphanBlockPool].
class OrphanBlockEntry {
  final SecurityBlock block;
  final String blockHash;
  final Set<String> missingParentHashes;
  final DateTime entryTime;
  final DateTime expiresAt;
  final String peerEndpointId;
  final String? requestId;

  OrphanBlockEntry({
    required this.block,
    required this.blockHash,
    required Set<String> missingParentHashes,
    required this.entryTime,
    required this.expiresAt,
    required this.peerEndpointId,
    this.requestId,
  }) : missingParentHashes = Set.unmodifiable(missingParentHashes);

  /// Memeriksa apakah entri telah melampaui batas TTL relatif terhadap waktu [now].
  bool isExpired(DateTime now) => now.isAfter(expiresAt);
}

/// Pool terbatas di memori untuk menahan blok yatim hingga seluruh parent tiba.
class OrphanBlockPool {
  /// Kapasitas maksimum total blok yatim yang dapat ditahan (default: 20 blok).
  final int maxCapacity;

  /// Batas waktu retensi blok yatim sebelum kedaluwarsa (default: 60 detik).
  final Duration ttl;

  /// Batas maksimum blok yatim yang dapat ditahan dari satu peer tertentu (default: 8 blok).
  final int maxOrphansPerPeer;

  /// Fungsi penyedia waktu sekarang (untuk kemudahan pengujian deterministik).
  final DateTime Function() _nowProvider;

  /// Penyimpanan entri orphan berbasis blockHash.
  final Map<String, OrphanBlockEntry> _entries = {};

  OrphanBlockPool({
    this.maxCapacity = kMaxOrphanBlocks,
    this.ttl = kOrphanBlockTtl,
    this.maxOrphansPerPeer = kMaxOrphansPerPeer,
    DateTime Function()? nowProvider,
  }) : _nowProvider = nowProvider ?? (() => DateTime.now().toUtc());

  /// Jumlah blok yatim yang saat ini aktif di dalam pool (belum kedaluwarsa).
  int get count {
    _purgeExpired();
    return _entries.length;
  }

  /// Seluruh entri aktif di dalam pool saat ini.
  List<OrphanBlockEntry> get entries {
    _purgeExpired();
    return _entries.values.toList();
  }

  /// Memeriksa apakah suatu [blockHash] ada di dalam pool dan belum kedaluwarsa.
  bool contains(String blockHash) {
    _purgeExpired();
    return _entries.containsKey(blockHash);
  }

  /// Mengambil entri orphan berdasarkan hash. Mengembalikan null jika tidak ada atau kedaluwarsa.
  OrphanBlockEntry? getEntry(String blockHash) {
    _purgeExpired();
    return _entries[blockHash];
  }

  /// Menghitung jumlah entri yang dimiliki oleh peer tertentu.
  int countForPeer(String peerEndpointId) {
    _purgeExpired();
    return _entries.values
        .where((e) => e.peerEndpointId == peerEndpointId)
        .length;
  }

  /// Menambahkan blok yatim ke dalam pool setelah melalui validasi intrinsik dan privasi.
  ///
  /// Kebijakan:
  /// 1. Membersihkan seluruh entri kedaluwarsa terlebih dahulu.
  /// 2. Jika hash sudah ada, abaikan tanpa memperpanjang TTL ([OrphanPoolAddStatus.duplicate]).
  /// 3. Jika peer pengirim telah mencapai [maxOrphansPerPeer], tolak ([OrphanPoolAddStatus.peerQuotaExceeded]).
  /// 4. Jika kapasitas pool penuh ([maxCapacity]), tolak entri baru ([OrphanPoolAddStatus.poolFull]).
  OrphanPoolAddResult add({
    required SecurityBlock block,
    required Set<String> missingParentHashes,
    required String peerEndpointId,
    String? requestId,
  }) {
    _purgeExpired();

    if (missingParentHashes.isEmpty) {
      return const OrphanPoolAddResult(
        OrphanPoolAddStatus.notOrphan,
        'Blok tidak memiliki parent yang hilang',
      );
    }

    // 1. Deduplikasi: jangan menambah entri atau memperpanjang TTL jika hash sudah ada
    if (_entries.containsKey(block.blockHash)) {
      return const OrphanPoolAddResult(
        OrphanPoolAddStatus.duplicate,
        'Blok sudah ada di dalam orphan pool',
      );
    }

    // 2. Batasi kuota per-peer untuk mencegah monopoli pool
    final peerCount = _entries.values
        .where((e) => e.peerEndpointId == peerEndpointId)
        .length;
    if (peerCount >= maxOrphansPerPeer) {
      return OrphanPoolAddResult(
        OrphanPoolAddStatus.peerQuotaExceeded,
        'Peer $peerEndpointId telah mencapai batas maksimum orphan ($maxOrphansPerPeer)',
      );
    }

    // 3. Batasi total kapasitas maksimum pool
    if (_entries.length >= maxCapacity) {
      return OrphanPoolAddResult(
        OrphanPoolAddStatus.poolFull,
        'Orphan pool penuh ($maxCapacity blok)',
      );
    }

    final now = _nowProvider();
    final entry = OrphanBlockEntry(
      block: block,
      blockHash: block.blockHash,
      missingParentHashes: missingParentHashes,
      entryTime: now,
      expiresAt: now.add(ttl),
      peerEndpointId: peerEndpointId,
      requestId: requestId,
    );

    _entries[block.blockHash] = entry;
    return const OrphanPoolAddResult(OrphanPoolAddStatus.added);
  }

  /// Mengambil daftar blok yatim yang SELURUH parent-nya sekarang sudah ada di ledger atau checkpoint.
  ///
  /// Mengembalikan daftar terurut secara deterministik:
  /// `(blockIndex ASC, timestamp ASC, blockHash ASC)`
  /// untuk menjamin resolusi kausalitas parent-child bertahap (topological order).
  List<OrphanBlockEntry> getReadyOrphans(LightweightBlockdagLedger ledger) {
    _purgeExpired();
    final ready = <OrphanBlockEntry>[];

    for (final entry in _entries.values) {
      bool allParentsPresent = true;
      for (final parentHash in entry.block.parentBlockHashes) {
        final inActive = ledger.getBlock(parentHash) != null;
        final inCheckpoint = ledger.checkpoints.any(
          (c) =>
              c.retainedGenesisHash == parentHash ||
              c.prunedBlockHashes.contains(parentHash),
        );
        if (!inActive && !inCheckpoint) {
          allParentsPresent = false;
          break;
        }
      }

      if (allParentsPresent) {
        ready.add(entry);
      }
    }

    // Urutkan secara deterministik topologis
    ready.sort((a, b) {
      final cmpIdx = a.block.index.compareTo(b.block.index);
      if (cmpIdx != 0) return cmpIdx;
      final cmpTime = a.block.timestamp.compareTo(b.block.timestamp);
      if (cmpTime != 0) return cmpTime;
      return a.blockHash.compareTo(b.blockHash);
    });

    return ready;
  }

  /// Menghapus blok dari pool (misal setelah berhasil di-ingest atau ditolak permanen).
  OrphanBlockEntry? remove(String blockHash) {
    return _entries.remove(blockHash);
  }

  /// Membersihkan seluruh entri yang sudah kedaluwarsa berdasarkan [_nowProvider].
  int purgeExpired() {
    return _purgeExpired();
  }

  int _purgeExpired() {
    final now = _nowProvider();
    final expiredKeys = <String>[];
    for (final entry in _entries.values) {
      if (entry.isExpired(now)) {
        expiredKeys.add(entry.blockHash);
      }
    }
    for (final key in expiredKeys) {
      _entries.remove(key);
    }
    return expiredKeys.length;
  }

  /// Mengosongkan seluruh isi pool.
  void clear() {
    _entries.clear();
  }

  /// Membersihkan seluruh resource saat pool dimatikan.
  void dispose() {
    _entries.clear();
  }
}

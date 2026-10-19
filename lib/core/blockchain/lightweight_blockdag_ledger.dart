/// Implementasi core penyimpanan, validasi, dan rekonsiliasi BlockDAG Ledger
/// untuk pencatatan audit keamanan terdistribusi SiagaMesh (Konfigurasi C).
///
/// Karakteristik utama:
/// 1. Partisi-toleran: Mendukung multi-parent (`parentBlockHashes`) untuk mempertahankan
///    percabangan sah yang muncul saat net-split tanpa pembuangan data (zero event loss).
/// 2. Integritas kriptografis: Validasi header hash SHA-256 dan Merkle root tree.
/// 3. Idempotensi & Anti-Replay: Pelacakan deduplikasi `_processedEventIds` dan `_processedBlockHashes`.
/// 4. Deterministik: Urutan pemutaran ulang linier (*Deterministic Linear Replay Ordering*).
/// 5. Bounded Ledger Window: Pemangkasan aman (*safe pruning*) dengan titik jangkar [LedgerCheckpoint].
library;

import 'blockchain_types.dart';

/// Komponen ledger BlockDAG lokal yang memelihara graf blok keamanan terdistribusi.
class LightweightBlockdagLedger {
  /// Kapasitas jendela retensi maksimum blok aktif sebelum pemangkasan otomatis dipicu.
  final int maxRetentionBlocks;

  /// Batas toleransi deviasi waktu ke masa depan (mencegah time-warp attack).
  /// Bernilai null jika dinonaktifkan (misal dalam simulasi pengujian deterministik).
  final Duration? maxFutureDrift;

  /// Batas maksimum cache pelacakan event ID untuk mencegah pembengkakan memori tak terbatas.
  final int maxProcessedEventsCache;

  /// Batas maksimum cache pelacakan block hash untuk mencegah pembengkakan memori tak terbatas.
  final int maxProcessedBlockHashesCache;

  /// Blok genesis awal.
  late final SecurityBlock _genesisBlock;

  /// Penyimpanan blok terindeks berdasarkan [SecurityBlock.blockHash].
  final Map<String, SecurityBlock> _blocks = {};

  /// Relasi graf: parentHash -> Set dari childHash.
  final Map<String, Set<String>> _children = {};

  /// Himpunan hash blok ujung graf (*DAG Tips*) yang belum memiliki anak.
  final Set<String> _tipHashes = {};

  /// Cache ID blok yang telah diterima dan divalidasi ke dalam ledger.
  final Set<String> _processedBlockHashes = {};

  /// Cache ID event yang telah tercatat untuk menjamin anti-duplikasi dan idempotensi.
  final Set<String> _processedEventIds = {};

  /// Antrean event keamanan lokal yang belum dipaketkan ke dalam blok (*pending pool*).
  final List<SecurityAuditEvent> _pendingEvents = [];

  /// Riwayat titik jangkar pemangkasan blok usang (*checkpoint anchors*).
  final List<LedgerCheckpoint> _checkpoints = [];

  LightweightBlockdagLedger({
    this.maxRetentionBlocks = 100,
    this.maxProcessedEventsCache = 5000,
    this.maxProcessedBlockHashesCache = 1000,
    this.maxFutureDrift,
    SecurityBlock? genesisBlock,
  }) {
    _genesisBlock = genesisBlock ?? SecurityBlock.genesis();
    _initializeGenesis();
  }

  void _addProcessedEventId(String eventId) {
    if (_processedEventIds.length >= maxProcessedEventsCache) {
      _processedEventIds.remove(_processedEventIds.first);
    }
    _processedEventIds.add(eventId);
  }

  void _addProcessedBlockHash(String blockHash) {
    if (_processedBlockHashes.length >= maxProcessedBlockHashesCache) {
      _processedBlockHashes.remove(_processedBlockHashes.first);
    }
    _processedBlockHashes.add(blockHash);
  }

  void _initializeGenesis() {
    _blocks[_genesisBlock.blockHash] = _genesisBlock;
    _tipHashes.add(_genesisBlock.blockHash);
    _addProcessedBlockHash(_genesisBlock.blockHash);
    for (final event in _genesisBlock.events) {
      _addProcessedEventId(event.eventId);
    }
  }

  /// Blok genesis yang menjadi akar dari BlockDAG.
  SecurityBlock get genesisBlock => _genesisBlock;

  /// Jumlah blok yang saat ini tersimpan dalam jendela aktif.
  int get activeBlocksCount => _blocks.length;

  /// Jumlah total blok historis yang pernah diproses (aktif + terpangkas).
  int get totalHistoricalBlocksCount => _blocks.length + totalPrunedBlocksCount;

  /// Total blok yang telah dipangkas ke dalam checkpoint.
  int get totalPrunedBlocksCount =>
      _checkpoints.fold(0, (sum, c) => sum + c.prunedBlockCount);

  /// Himpunan hash ujung DAG (*tips*) saat ini.
  Set<String> get tipHashes => Set.unmodifiable(_tipHashes);

  /// Cache ID event yang sudah pernah diproses di seluruh riwayat ledger.
  Set<String> get processedEventIds => Set.unmodifiable(_processedEventIds);

  /// Cache ID blok yang sudah pernah divalidasi dan diterima.
  Set<String> get processedBlockHashes =>
      Set.unmodifiable(_processedBlockHashes);

  /// Jumlah event yang mengantre di buffer lokal.
  int get pendingEventsCount => _pendingEvents.length;

  /// Daftar event yang sedang mengantre di buffer lokal.
  List<SecurityAuditEvent> get pendingEvents =>
      List.unmodifiable(_pendingEvents);

  /// Riwayat checkpoint pemangkasan.
  List<LedgerCheckpoint> get checkpoints => List.unmodifiable(_checkpoints);

  /// Mengambil blok berdasarkan hash. Mengembalikan null jika tidak ada di jendela aktif.
  SecurityBlock? getBlock(String blockHash) => _blocks[blockHash];

  /// Mengambil seluruh blok di jendela aktif.
  List<SecurityBlock> getAllActiveBlocks() => _blocks.values.toList();

  /// Menambahkan event keamanan ke dalam antrean lokal (*pending events*).
  ///
  /// Mengembalikan `false` jika [event.eventId] sudah pernah tercatat di ledger
  /// atau sudah ada di dalam antrean lokal (deduplikasi).
  bool addPendingEvent(SecurityAuditEvent event) {
    if (_processedEventIds.contains(event.eventId)) {
      return false;
    }
    if (_pendingEvents.any((e) => e.eventId == event.eventId)) {
      return false;
    }
    _pendingEvents.add(event);
    return true;
  }

  /// Membersihkan antrean event lokal tanpa memasukkannya ke blok.
  void clearPendingEvents() {
    _pendingEvents.clear();
  }

  /// Membuat dan menambahkan blok baru yang memaketkan event dari antrean lokal.
  ///
  /// Blok baru secara otomatis:
  /// - Menghubungkan SELURUH tip DAG aktif sebagai `parentBlockHashes` (mendukung konvergensi percabangan).
  /// - Menetapkan `index` = `max(parentIndices) + 1`.
  /// - Menghitung Merkle root dari event yang dipaketkan.
  /// - Menghitung `blockHash` SHA-256 dari header kanonikal.
  /// - Memvalidasi dan memasukkan blok ke dalam ledger lokal.
  SecurityBlock createBlock({
    required String creatorNodeId,
    Map<String, dynamic> validationProof = const {},
    DateTime? timestamp,
    int? monotonicMicros,
    int? maxEvents,
  }) {
    final List<SecurityAuditEvent> eventsToPack;
    if (maxEvents != null && maxEvents < _pendingEvents.length) {
      eventsToPack = _pendingEvents.take(maxEvents).toList();
    } else {
      eventsToPack = List<SecurityAuditEvent>.from(_pendingEvents);
    }

    final sortedParents = _tipHashes.toList()..sort();
    int nextIndex = 0;
    if (_tipHashes.isNotEmpty) {
      int maxParentIndex = 0;
      for (final parentHash in _tipHashes) {
        final parentBlock = _blocks[parentHash];
        if (parentBlock != null && parentBlock.index > maxParentIndex) {
          maxParentIndex = parentBlock.index;
        }
      }
      nextIndex = maxParentIndex + 1;
    }

    final block = SecurityBlock.create(
      index: nextIndex,
      parentBlockHashes: sortedParents,
      creatorNodeId: creatorNodeId,
      events: eventsToPack,
      validationProof: validationProof,
      timestamp: timestamp,
      monotonicMicros: monotonicMicros,
    );

    final addResult = addBlock(block);
    if (!addResult.isValid) {
      throw StateError('Gagal menambahkan blok yang baru dibuat: $addResult');
    }

    return block;
  }

  /// Memvalidasi integritas, format hash, rantai parent, Merkle root, dan keunikan event suatu blok.
  LedgerValidationResult validateBlock(SecurityBlock block) {
    // 1. Validasi versi skema
    if (block.version != 1) {
      return const LedgerValidationResult.invalid(
        LedgerValidationStatus.unsupportedVersion,
        'Versi skema blok tidak didukung',
      );
    }

    // 2. Validasi format hash hex 64 karakter
    final hexRegex = RegExp(r'^[0-9a-f]{64}$');
    if (block.blockHash.length != 64 || !hexRegex.hasMatch(block.blockHash)) {
      return const LedgerValidationResult.invalid(
        LedgerValidationStatus.invalidHashFormat,
        'Format blockHash tidak valid (harus 64 karakter hex huruf kecil)',
      );
    }
    if (block.merkleRoot.length != 64 || !hexRegex.hasMatch(block.merkleRoot)) {
      return const LedgerValidationResult.invalid(
        LedgerValidationStatus.invalidHashFormat,
        'Format merkleRoot tidak valid (harus 64 karakter hex huruf kecil)',
      );
    }

    // 3. Validasi struktur index dan relasi parent
    if (block.index < 0) {
      return const LedgerValidationResult.invalid(
        LedgerValidationStatus.invalidStructure,
        'Indeks blok tidak boleh bernilai negatif',
      );
    }
    if (block.index == 0) {
      if (block.parentBlockHashes.isNotEmpty) {
        return const LedgerValidationResult.invalid(
          LedgerValidationStatus.invalidStructure,
          'Blok genesis tidak boleh memiliki parent',
        );
      }
    } else {
      if (block.parentBlockHashes.isEmpty) {
        return const LedgerValidationResult.invalid(
          LedgerValidationStatus.invalidStructure,
          'Blok non-genesis wajib memiliki minimal satu parent',
        );
      }
    }

    // 4. Pemeriksaan duplikasi blok
    if (_processedBlockHashes.contains(block.blockHash)) {
      return const LedgerValidationResult.invalid(
        LedgerValidationStatus.duplicateBlock,
        'Blok dengan hash ini sudah pernah dicatat di ledger',
      );
    }

    // 5. Validasi eksistensi parent block di ledger aktif atau checkpoint, serta pencegahan siklus (DAG acyclicity)
    for (final parentHash in block.parentBlockHashes) {
      if (parentHash == block.blockHash) {
        return const LedgerValidationResult.invalid(
          LedgerValidationStatus.invalidStructure,
          'Blok tidak boleh mereferensikan dirinya sendiri (siklus terdeteksi)',
        );
      }

      final parentInActive = _blocks[parentHash];
      final existsInCheckpoints = _checkpoints.any(
        (c) =>
            c.retainedGenesisHash == parentHash ||
            c.prunedBlockHashes.contains(parentHash),
      );
      if (parentInActive == null && !existsInCheckpoints) {
        return LedgerValidationResult.invalid(
          LedgerValidationStatus.missingParent,
          'Parent block $parentHash tidak ditemukan pada ledger atau checkpoint',
        );
      }

      // Pastikan index blok strictly lebih besar dari index parent aktif (bukti formal graf DAG asiklik)
      if (parentInActive != null && block.index <= parentInActive.index) {
        return LedgerValidationResult.invalid(
          LedgerValidationStatus.invalidStructure,
          'Indeks blok (${block.index}) harus lebih besar dari indeks parent (${parentInActive.index})',
        );
      }
    }

    // 6. Verifikasi re-komputasi Merkle Root
    final computedMerkleRoot = MerkleTree.computeRoot(
      block.events.map((e) => e.hash).toList(),
    );
    if (computedMerkleRoot != block.merkleRoot) {
      return const LedgerValidationResult.invalid(
        LedgerValidationStatus.invalidMerkleRoot,
        'Merkle root yang dihitung ulang tidak cocok dengan header blok',
      );
    }

    // 7. Verifikasi re-komputasi Header Hash
    final computedBlockHash = block.computeHash();
    if (computedBlockHash != block.blockHash) {
      return const LedgerValidationResult.invalid(
        LedgerValidationStatus.invalidHeaderHash,
        'Hash header yang dihitung ulang tidak cocok dengan blockHash',
      );
    }

    // 8. Pemeriksaan deduplikasi event (anti double-counting)
    final internalEventIds = <String>{};
    for (final event in block.events) {
      if (!internalEventIds.add(event.eventId)) {
        return LedgerValidationResult.invalid(
          LedgerValidationStatus.duplicateEvent,
          'Duplikasi eventId ${event.eventId} di dalam blok yang sama',
        );
      }
      if (_processedEventIds.contains(event.eventId)) {
        return LedgerValidationResult.invalid(
          LedgerValidationStatus.duplicateEvent,
          'EventId ${event.eventId} sudah pernah diproses di rantai ledger lain',
        );
      }
    }

    // 9. Validasi batas timestamp (tidak boleh mendahului parent atau melompat jauh ke masa depan)
    if (maxFutureDrift != null) {
      final now = DateTime.now().toUtc();
      if (block.timestamp.isAfter(now.add(maxFutureDrift!))) {
        return const LedgerValidationResult.invalid(
          LedgerValidationStatus.timestampOutOfBounds,
          'Timestamp blok melompat terlalu jauh ke masa depan',
        );
      }
    }
    for (final parentHash in block.parentBlockHashes) {
      final parentBlock = _blocks[parentHash];
      if (parentBlock != null &&
          block.timestamp.isBefore(parentBlock.timestamp)) {
        return const LedgerValidationResult.invalid(
          LedgerValidationStatus.timestampOutOfBounds,
          'Timestamp blok mendahului timestamp blok parent',
        );
      }
    }

    return const LedgerValidationResult.valid();
  }

  /// Menambahkan blok yang telah divalidasi ke dalam BlockDAG.
  ///
  /// Mengembalikan [LedgerValidationResult.valid()] jika berhasil, atau hasil invalid jika gagal.
  LedgerValidationResult addBlock(SecurityBlock block) {
    final validationResult = validateBlock(block);
    if (!validationResult.isValid) {
      return validationResult;
    }

    // Simpan ke storage lokal
    _blocks[block.blockHash] = block;

    // Perbarui relasi graf parent-child dan DAG tips
    for (final parentHash in block.parentBlockHashes) {
      _children.putIfAbsent(parentHash, () => <String>{}).add(block.blockHash);
      _tipHashes.remove(parentHash);
    }
    _tipHashes.add(block.blockHash);
    _addProcessedBlockHash(block.blockHash);

    // Tandai event telah diproses dan bersihkan dari antrean lokal
    for (final event in block.events) {
      _addProcessedEventId(event.eventId);
      _pendingEvents.removeWhere((e) => e.eventId == event.eventId);
    }

    // Evaluasi pemangkasan jika melampaui jendela retensi
    if (_blocks.length > maxRetentionBlocks) {
      prune(maxRetention: maxRetentionBlocks);
    }

    return const LedgerValidationResult.valid();
  }

  /// Menghasilkan urutan pemutaran ulang linier deterministik (*Deterministic Linear Replay Order*).
  ///
  /// PERINGATAN METODOLOGI & ARSITEKTUR:
  /// Urutan ini merupakan total ordering deterministik lokal untuk rekonstruksi state yang konsisten
  /// di seluruh node nirkabel SiagaMesh. Urutan ini BUKAN bukti waktu fisik kronologis absolut dan
  /// BUKAN konsensus global tersinkronisasi.
  /// Karena node Android pada skenario darurat beroperasi secara terdesentralisasi tanpa NTP/GPS terpusat,
  /// urutan kausalitas utama ditegakkan oleh relasi graf DAG ($index_{\text{child}} > index_{\text{parent}}$).
  ///
  /// Urutan total:
  /// `(blockIndex ASC, timestampMs ASC, creatorNodeId ASC, blockHash ASC)`
  List<SecurityBlock> getLinearReplayOrder() {
    final ordered = _blocks.values.toList();
    ordered.sort((a, b) {
      final cmpIndex = a.index.compareTo(b.index);
      if (cmpIndex != 0) return cmpIndex;

      final cmpTime = a.timestamp.millisecondsSinceEpoch.compareTo(
        b.timestamp.millisecondsSinceEpoch,
      );
      if (cmpTime != 0) return cmpTime;

      final cmpCreator = a.creatorNodeId.compareTo(b.creatorNodeId);
      if (cmpCreator != 0) return cmpCreator;

      return a.blockHash.compareTo(b.blockHash);
    });
    return List.unmodifiable(ordered);
  }

  /// Melakukan pemangkasan blok usang yang melampaui kapasitas jendela retensi.
  ///
  /// BATASAN VALIDASI PASCA-PRUNING:
  /// Blok-blok yang telah dipangkas diringkas ke dalam titik jangkar [LedgerCheckpoint].
  /// Blok baru yang berakar pada blok terpangkas divalidasi terhadap checkpoint jangkar tersebut,
  /// bukan verifikasi penuh kembali ke blok genesis awal.
  /// Cache deduplikasi `_processedEventIds` dan `_processedBlockHashes` tetap dipertahankan
  /// dalam batas kapasitas cache untuk mencegah injeksi event usang.
  LedgerCheckpoint? prune({int? maxRetention}) {
    final retentionLimit = maxRetention ?? maxRetentionBlocks;
    if (_blocks.length <= retentionLimit) {
      return null;
    }

    final pruneCount = _blocks.length - retentionLimit;
    final ordered = getLinearReplayOrder();
    final blocksToPrune = ordered.take(pruneCount).toList();

    final prunedHashes = <String>{};
    final prunedEvents = <String>{};
    int lastPrunedIndex = -1;

    for (final b in blocksToPrune) {
      prunedHashes.add(b.blockHash);
      for (final e in b.events) {
        prunedEvents.add(e.eventId);
      }
      if (b.index > lastPrunedIndex) {
        lastPrunedIndex = b.index;
      }
      _blocks.remove(b.blockHash);
    }

    final retainedBaseBlock = ordered[pruneCount];

    final checkpoint = LedgerCheckpoint(
      checkpointIndex: _checkpoints.length + 1,
      lastPrunedIndex: lastPrunedIndex,
      retainedGenesisHash: retainedBaseBlock.blockHash,
      prunedBlockHashes: prunedHashes,
      prunedEventIds: prunedEvents,
      summaryMetadata: {
        'prunedBlocksCount': blocksToPrune.length,
        'activeBlocksRemaining': _blocks.length,
        'retainedGenesisIndex': retainedBaseBlock.index,
      },
    );

    _checkpoints.add(checkpoint);
    return checkpoint;
  }

  /// Memeriksa apakah simpul [ancestorHash] merupakan leluhur dari [descendantHash] pada graf DAG.
  bool isAncestor(String ancestorHash, String descendantHash) {
    if (ancestorHash == descendantHash) return true;
    final visited = <String>{};
    final queue = <String>[descendantHash];

    while (queue.isNotEmpty) {
      final current = queue.removeAt(0);
      if (!visited.add(current)) continue;

      final block = _blocks[current];
      if (block == null) continue;

      for (final parent in block.parentBlockHashes) {
        if (parent == ancestorHash) return true;
        queue.add(parent);
      }
    }
    return false;
  }

  /// Ekspor seluruh state internal aktif ke dalam [BlockdagPersistedState].
  BlockdagPersistedState exportPersistedState({int schemaVersion = 1}) {
    return BlockdagPersistedState(
      schemaVersion: schemaVersion,
      blocks: _blocks.values.toList(),
      checkpoints: _checkpoints.toList(),
      tipHashes: _tipHashes.toList(),
      processedBlockHashes: _processedBlockHashes.toList(),
      processedEventIds: _processedEventIds.toList(),
      pendingEvents: _pendingEvents.toList(),
      savedAt: DateTime.now().toUtc(),
    );
  }

  /// Memulihkan state internal dari [BlockdagPersistedState].
  void restoreFromPersistedState(BlockdagPersistedState state) {
    _blocks.clear();
    _children.clear();
    _tipHashes.clear();
    _processedBlockHashes.clear();
    _processedEventIds.clear();
    _pendingEvents.clear();
    _checkpoints.clear();

    for (final b in state.blocks) {
      _blocks[b.blockHash] = b;
      for (final parent in b.parentBlockHashes) {
        _children.putIfAbsent(parent, () => <String>{}).add(b.blockHash);
      }
    }
    _tipHashes.addAll(state.tipHashes);
    _processedBlockHashes.addAll(state.processedBlockHashes);
    _processedEventIds.addAll(state.processedEventIds);
    _pendingEvents.addAll(state.pendingEvents);
    _checkpoints.addAll(state.checkpoints);

    if (_blocks.isEmpty) {
      _initializeGenesis();
    }
  }

  /// Mengosongkan seluruh state ledger dan menginisialisasi ulang dari Genesis.
  void reset() {
    _blocks.clear();
    _children.clear();
    _tipHashes.clear();
    _processedBlockHashes.clear();
    _processedEventIds.clear();
    _pendingEvents.clear();
    _checkpoints.clear();
    _initializeGenesis();
  }
}

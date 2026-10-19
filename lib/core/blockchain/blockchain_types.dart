/// Tipe data, serialisasi kanonikal, struktur blok BlockDAG, dan Merkle tree
/// untuk subsistem Lightweight Blockchain / Security Audit Ledger SiagaMesh.
///
/// Mengacu pada rancangan Stage 5E.1 (Alternatif B: Replicated Partition-Tolerant
/// Ledger with Merkle BlockDAG) untuk Konfigurasi C (MANET + IDS + Trust + Blockchain).
library;

import 'dart:convert';
import 'package:crypto/crypto.dart';

import '../ids/ids_types.dart';
import '../trust/trust_types.dart';

/// Hash SHA-256 standar untuk string kosong "".
const String kEmptySha256 =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

/// Menghitung nilai hash SHA-256 dalam representasi string hex 64 karakter huruf kecil.
String computeSha256(String input) {
  if (input.isEmpty) return kEmptySha256;
  return sha256.convert(utf8.encode(input)).toString();
}

/// Mengurutkan kunci map secara leksikografis (rekursif) dan menstandarkan tipe data
/// sesuai spesifikasi SiagaMesh Application Canonical JSON Format v1 (SACJ-v1).
///
/// PERNYATAAN AKADEMIK & STANDAR:
/// Serializer ini merupakan format kanonikal deterministik khusus aplikasi (SACJ-v1),
/// BUKAN implementasi penuh RFC 8785 (JSON Canonicalization Scheme).
/// Aturan deterministik SACJ-v1:
/// 1. Map keys diurutkan secara leksikografis rekursif berdasarkan perbandingan UTF-16 code units.
/// 2. List mempertahankan urutan elemen aslinya dengan kanonisasi rekursif pada setiap elemen.
/// 3. Primitif angka: int dan double standar IEEE 754; nilai NaN atau Infinity DITOLAK (ArgumentError).
///    Nilai -0.0 dinormalisasi menjadi 0.0.
/// 4. DateTime dikonversi menjadi representasi string UTC ISO-8601.
/// 5. String di-encode sesuai RFC 8259 tanpa spasi ekstra di luar token string.
/// 6. Hashing menggunakan SHA-256 atas representasi byte UTF-8 dari JSON kanonikal.
dynamic canonicalizeValue(dynamic value) {
  if (value == null) {
    return null;
  }
  if (value is num) {
    if (value.isNaN || value.isInfinite) {
      throw ArgumentError(
        'Nilai numerik tidak valid untuk serialisasi kanonikal SACJ-v1: $value',
      );
    }
    if (value == 0.0 && value.isNegative) {
      return 0.0;
    }
    return value;
  }
  if (value is Map) {
    final sortedKeys = value.keys.map((k) => k.toString()).toList()..sort();
    final sortedMap = <String, dynamic>{};
    for (final key in sortedKeys) {
      sortedMap[key] = canonicalizeValue(value[key]);
    }
    return sortedMap;
  } else if (value is List) {
    return value.map(canonicalizeValue).toList();
  } else if (value is DateTime) {
    return value.toUtc().toIso8601String();
  } else if (value is String || value is bool) {
    return value;
  }
  return value;
}

/// Menghasilkan representasi string JSON kanonikal deterministik dengan format SACJ-v1.
String canonicalJsonEncode(dynamic value) {
  final canonical = canonicalizeValue(value);
  return jsonEncode(canonical);
}

/// Langkah pembuktian keanggotaan Merkle (Merkle Audit Proof Step).
class MerkleProofStep {
  final String siblingHash;
  final bool isRightSibling;

  const MerkleProofStep({
    required this.siblingHash,
    required this.isRightSibling,
  });

  Map<String, dynamic> toMap() => {
    'siblingHash': siblingHash,
    'isRightSibling': isRightSibling,
  };
}

/// Implementasi Merkle Tree deterministik varian Bitcoin-Style (Odd-Leaf Duplication).
///
/// PERNYATAAN SPESIFIKASI DAN STANDAR:
/// Konstruksi ini menggunakan varian Bitcoin-Style dengan aturan:
/// - Daun kosong menghasilkan [kEmptySha256].
/// - Daun tunggal menghasilkan hash daun itu sendiri.
/// - Jumlah simpul ganjil pada tiap tingkat diduplikasi daun terakhirnya.
/// - Penggabungan pasangan simpul: `SHA-256(leftHash + rightHash)`.
///
/// PERBEDAAN TERHADAP RFC 6962:
/// Konstruksi ini BUKAN RFC 6962. RFC 6962 menggunakan pembagian berbasis pangkat-dua terbesar
/// (power-of-two splitting k = 2^floor(log2(n-1))) serta domain separation prefix 0x00 untuk daun
/// dan 0x01 untuk simpul internal.
///
/// MITIGASI CVE-2012-2459:
/// Kelemahan duplikasi daun ganjil gaya Bitcoin (CVE-2012-2459) dimitigasi secara eksplisit
/// pada level validasi blok di [LightweightBlockdagLedger.validateBlock] yang menolak
/// keberadaan duplikasi event internal dalam satu blok yang sama.
class MerkleTree {
  /// Menghitung Merkle root deterministik dari daftar hash daun (leaf hashes).
  ///
  /// - Daftar kosong menghasilkan [kEmptySha256].
  /// - Daun tunggal menghasilkan hash daun itu sendiri.
  /// - Jumlah daun ganjil pada tiap tingkat menduplikasi daun terakhir.
  /// - Pasangan simpul digabungkan sebagai `leftHash + rightHash` lalu di-hash dengan SHA-256.
  static String computeRoot(List<String> leafHashes) {
    if (leafHashes.isEmpty) {
      return kEmptySha256;
    }
    if (leafHashes.length == 1) {
      return leafHashes.first;
    }

    List<String> currentLevel = List<String>.from(leafHashes);
    while (currentLevel.length > 1) {
      final List<String> nextLevel = [];
      if (currentLevel.length % 2 != 0) {
        currentLevel.add(currentLevel.last);
      }
      for (int i = 0; i < currentLevel.length; i += 2) {
        final combined = currentLevel[i] + currentLevel[i + 1];
        nextLevel.add(computeSha256(combined));
      }
      currentLevel = nextLevel;
    }
    return currentLevel.first;
  }

  /// Menghasilkan bukti inklusi Merkle untuk daun pada indeks [leafIndex].
  static List<MerkleProofStep> generateProof(
    List<String> leafHashes,
    int leafIndex,
  ) {
    if (leafIndex < 0 || leafIndex >= leafHashes.length) {
      throw ArgumentError('leafIndex out of bounds');
    }
    if (leafHashes.length <= 1) {
      return const [];
    }

    final List<MerkleProofStep> proof = [];
    List<String> currentLevel = List<String>.from(leafHashes);
    int currentIndex = leafIndex;

    while (currentLevel.length > 1) {
      if (currentLevel.length % 2 != 0) {
        currentLevel.add(currentLevel.last);
      }

      final bool isEven = (currentIndex % 2 == 0);
      final int siblingIndex = isEven ? currentIndex + 1 : currentIndex - 1;
      proof.add(
        MerkleProofStep(
          siblingHash: currentLevel[siblingIndex],
          isRightSibling: isEven,
        ),
      );

      final List<String> nextLevel = [];
      for (int i = 0; i < currentLevel.length; i += 2) {
        final combined = currentLevel[i] + currentLevel[i + 1];
        nextLevel.add(computeSha256(combined));
      }
      currentLevel = nextLevel;
      currentIndex = currentIndex ~/ 2;
    }

    return proof;
  }

  /// Memverifikasi bukti audit Merkle terhadap [merkleRoot] yang diharapkan.
  static bool verifyProof({
    required String leafHash,
    required List<MerkleProofStep> proof,
    required String merkleRoot,
  }) {
    if (proof.isEmpty) {
      return leafHash == merkleRoot;
    }
    String currentHash = leafHash;
    for (final step in proof) {
      final combined = step.isRightSibling
          ? (currentHash + step.siblingHash)
          : (step.siblingHash + currentHash);
      currentHash = computeSha256(combined);
    }
    return currentHash == merkleRoot;
  }
}

/// Tipe peristiwa audit keamanan yang dicatat ke dalam ledger.
enum AuditEventType {
  /// Peristiwa deteksi anomali forwarding dari IDS.
  idsDetection,

  /// Peristiwa pembaruan skor kepercayaan dari Dynamic Trust Manager.
  trustUpdate,

  /// Keputusan isolasi atau reintegrasi node dari routing policy.
  isolationDecision,

  /// Titik jangkar pemangkasan ledger (*checkpoint anchor*).
  checkpointAnchor,
}

/// Model peristiwa audit keamanan minimal yang dicatat ke dalam blok.
///
/// PERINGATAN PRIVASI & EFISIENSI:
/// Model ini secara ketat HANYA menyimpan metadata teknis keamanan.
/// TIDAK menyimpan teks pesan obrolan, kredensial, koordinat GPS, atau data pribadi.
class SecurityAuditEvent {
  final String eventId;
  final AuditEventType eventType;
  final String observerNodeId;
  final String targetNodeId;
  final DateTime timestamp;
  final int monotonicMicros;
  final Map<String, dynamic> metadata;

  const SecurityAuditEvent({
    required this.eventId,
    required this.eventType,
    required this.observerNodeId,
    required this.targetNodeId,
    required this.timestamp,
    required this.monotonicMicros,
    required this.metadata,
  });

  /// Konversi dari [IdsDetectionEvent].
  factory SecurityAuditEvent.fromIdsDetectionEvent(IdsDetectionEvent event) {
    return SecurityAuditEvent(
      eventId: event.eventId,
      eventType: AuditEventType.idsDetection,
      observerNodeId: event.observerNodeId,
      targetNodeId: event.targetNodeId,
      timestamp: event.timestamp,
      monotonicMicros: event.monotonicMicros,
      metadata: {
        'status': event.status.name,
        'observedDropRate': event.observedDropRate,
        'totalExpected': event.totalExpected,
        'totalClaimed': event.totalClaimed,
        'totalUnconfirmed': event.totalUnconfirmed,
        'totalLinkFailures': event.totalLinkFailures,
        'totalProtocolDrops': event.totalProtocolDrops,
        'reason': event.reason,
      },
    );
  }

  /// Konversi dari [TrustScoreChangeEvent].
  factory SecurityAuditEvent.fromTrustScoreChangeEvent(
    TrustScoreChangeEvent event,
  ) {
    return SecurityAuditEvent(
      eventId: event.eventId,
      eventType: AuditEventType.trustUpdate,
      observerNodeId: event.observerNodeId,
      targetNodeId: event.targetNodeId,
      timestamp: event.timestamp,
      monotonicMicros: event.monotonicMicros,
      metadata: {
        'oldScore': event.oldScore,
        'newScore': event.newScore,
        'delta': event.newScore - event.oldScore,
        'evidenceType': event.evidenceType.name,
        'evaluationStatus': event.evaluationStatus.name,
        'reason': event.reason,
        'protocolResponsivenessCount': event.protocolResponsivenessCount,
        'relayClaimCount': event.relayClaimCount,
        'verifiedForwardingCount': event.verifiedForwardingCount,
        'unconfirmedDropCount': event.unconfirmedDropCount,
      },
    );
  }

  /// Factory untuk mencatat keputusan isolasi atau reintegrasi node.
  factory SecurityAuditEvent.isolationDecision({
    required String eventId,
    required String observerNodeId,
    required String targetNodeId,
    required String action,
    required double score,
    required String reason,
    DateTime? timestamp,
    int? monotonicMicros,
  }) {
    final now = timestamp ?? DateTime.now().toUtc();
    return SecurityAuditEvent(
      eventId: eventId,
      eventType: AuditEventType.isolationDecision,
      observerNodeId: observerNodeId,
      targetNodeId: targetNodeId,
      timestamp: now,
      monotonicMicros: monotonicMicros ?? 0,
      metadata: {'action': action, 'score': score, 'reason': reason},
    );
  }

  /// Factory untuk mencatat titik jangkar checkpoint saat terjadi pemangkasan ledger.
  factory SecurityAuditEvent.checkpointAnchor({
    required String eventId,
    required String observerNodeId,
    required int prunedBlockCount,
    required int lastPrunedIndex,
    required String retainedGenesisHash,
    DateTime? timestamp,
    int? monotonicMicros,
  }) {
    final now = timestamp ?? DateTime.now().toUtc();
    return SecurityAuditEvent(
      eventId: eventId,
      eventType: AuditEventType.checkpointAnchor,
      observerNodeId: observerNodeId,
      targetNodeId: 'SYSTEM',
      timestamp: now,
      monotonicMicros: monotonicMicros ?? 0,
      metadata: {
        'prunedBlockCount': prunedBlockCount,
        'lastPrunedIndex': lastPrunedIndex,
        'retainedGenesisHash': retainedGenesisHash,
      },
    );
  }

  Map<String, dynamic> toMap() => {
    'eventId': eventId,
    'eventType': eventType.name,
    'observerNodeId': observerNodeId,
    'targetNodeId': targetNodeId,
    'timestampMs': timestamp.toUtc().millisecondsSinceEpoch,
    'timestampIso': timestamp.toUtc().toIso8601String(),
    'monotonicMicros': monotonicMicros,
    'metadata': metadata,
  };

  factory SecurityAuditEvent.fromMap(Map<String, dynamic> map) {
    return SecurityAuditEvent(
      eventId: map['eventId'] as String,
      eventType: AuditEventType.values.firstWhere(
        (e) => e.name == map['eventType'],
        orElse: () => AuditEventType.idsDetection,
      ),
      observerNodeId: map['observerNodeId'] as String,
      targetNodeId: map['targetNodeId'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        map['timestampMs'] as int,
        isUtc: true,
      ),
      monotonicMicros: (map['monotonicMicros'] as num?)?.toInt() ?? 0,
      metadata: Map<String, dynamic>.from(map['metadata'] as Map? ?? {}),
    );
  }

  /// Serialisasi kanonikal JSON deterministik.
  String toCanonicalJson() => canonicalJsonEncode(toMap());

  /// Hash SHA-256 dari serialisasi kanonikal event ini.
  String get hash => computeSha256(toCanonicalJson());
}

/// Struktur data blok keamanan (*Security Block*) dalam model BlockDAG.
///
/// Mendukung multi-parent (`parentBlockHashes`) untuk mempertahankan percabangan sah
/// akibat partisi jaringan MANET nirkabel (net-split) tanpa kehilangan event audit.
class SecurityBlock {
  final int version;
  final int index;
  final String blockHash;
  final List<String> parentBlockHashes;
  final String creatorNodeId;
  final DateTime timestamp;
  final int monotonicMicros;
  final String merkleRoot;
  final List<SecurityAuditEvent> events;
  final Map<String, dynamic> validationProof;

  /// Getter kompatibilitas ke belakang untuk rantai linier tunggal.
  String get prevBlockHash =>
      parentBlockHashes.isEmpty ? '' : parentBlockHashes.first;

  int get eventsCount => events.length;

  const SecurityBlock({
    this.version = 1,
    required this.index,
    required this.blockHash,
    required this.parentBlockHashes,
    required this.creatorNodeId,
    required this.timestamp,
    required this.monotonicMicros,
    required this.merkleRoot,
    required this.events,
    this.validationProof = const {},
  });

  /// Map kanonikal header blok yang menjadi input perhitungan [blockHash].
  Map<String, dynamic> get headerMap => {
    'version': version,
    'index': index,
    'parentBlockHashes': parentBlockHashes,
    'creatorNodeId': creatorNodeId,
    'timestampMs': timestamp.toUtc().millisecondsSinceEpoch,
    'timestampIso': timestamp.toUtc().toIso8601String(),
    'monotonicMicros': monotonicMicros,
    'eventsCount': events.length,
    'merkleRoot': merkleRoot,
    'validationProof': validationProof,
  };

  /// Menghitung hash SHA-256 dari header blok secara kanonikal.
  static String computeHeaderHash(Map<String, dynamic> header) {
    return computeSha256(canonicalJsonEncode(header));
  }

  /// Menghitung ulang hash blok aktual dari header.
  String computeHash() => computeHeaderHash(headerMap);

  /// Factory untuk membuat blok baru dengan perhitungan otomatis Merkle root dan blockHash.
  factory SecurityBlock.create({
    int version = 1,
    required int index,
    required List<String> parentBlockHashes,
    required String creatorNodeId,
    required List<SecurityAuditEvent> events,
    Map<String, dynamic> validationProof = const {},
    DateTime? timestamp,
    int? monotonicMicros,
  }) {
    final blockTimestamp = timestamp?.toUtc() ?? DateTime.now().toUtc();
    final blockMonotonic = monotonicMicros ?? 0;
    final leafHashes = events.map((e) => e.hash).toList();
    final merkleRoot = MerkleTree.computeRoot(leafHashes);

    final sortedParents = List<String>.from(parentBlockHashes)..sort();

    final header = {
      'version': version,
      'index': index,
      'parentBlockHashes': sortedParents,
      'creatorNodeId': creatorNodeId,
      'timestampMs': blockTimestamp.millisecondsSinceEpoch,
      'timestampIso': blockTimestamp.toIso8601String(),
      'monotonicMicros': blockMonotonic,
      'eventsCount': events.length,
      'merkleRoot': merkleRoot,
      'validationProof': validationProof,
    };

    final hash = computeHeaderHash(header);

    return SecurityBlock(
      version: version,
      index: index,
      blockHash: hash,
      parentBlockHashes: sortedParents,
      creatorNodeId: creatorNodeId,
      timestamp: blockTimestamp,
      monotonicMicros: blockMonotonic,
      merkleRoot: merkleRoot,
      events: List.unmodifiable(events),
      validationProof: validationProof,
    );
  }

  /// Membuat Genesis Block standar yang deterministik.
  factory SecurityBlock.genesis({
    String creatorNodeId = 'SYSTEM',
    DateTime? timestamp,
    int? monotonicMicros,
  }) {
    final genesisTime =
        timestamp?.toUtc() ??
        DateTime.parse('2026-01-01T00:00:00.000Z').toUtc();
    final genesisMonotonic = monotonicMicros ?? 0;
    const List<SecurityAuditEvent> genesisEvents = [];
    final merkleRoot = MerkleTree.computeRoot(const []);

    final header = {
      'version': 1,
      'index': 0,
      'parentBlockHashes': <String>[],
      'creatorNodeId': creatorNodeId,
      'timestampMs': genesisTime.millisecondsSinceEpoch,
      'timestampIso': genesisTime.toIso8601String(),
      'monotonicMicros': genesisMonotonic,
      'eventsCount': 0,
      'merkleRoot': merkleRoot,
      'validationProof': {'type': 'GENESIS', 'network': 'SIAGAMESH_MANET'},
    };

    final hash = computeHeaderHash(header);

    return SecurityBlock(
      version: 1,
      index: 0,
      blockHash: hash,
      parentBlockHashes: const [],
      creatorNodeId: creatorNodeId,
      timestamp: genesisTime,
      monotonicMicros: genesisMonotonic,
      merkleRoot: merkleRoot,
      events: genesisEvents,
      validationProof: const {'type': 'GENESIS', 'network': 'SIAGAMESH_MANET'},
    );
  }

  Map<String, dynamic> toMap() => {
    'version': version,
    'index': index,
    'blockHash': blockHash,
    'parentBlockHashes': parentBlockHashes,
    'prevBlockHash': prevBlockHash,
    'creatorNodeId': creatorNodeId,
    'timestampMs': timestamp.toUtc().millisecondsSinceEpoch,
    'timestampIso': timestamp.toUtc().toIso8601String(),
    'monotonicMicros': monotonicMicros,
    'eventsCount': events.length,
    'merkleRoot': merkleRoot,
    'events': events.map((e) => e.toMap()).toList(),
    'validationProof': validationProof,
  };

  factory SecurityBlock.fromMap(Map<String, dynamic> map) {
    final rawParents =
        map['parentBlockHashes'] as List? ??
        (map['prevBlockHash'] != null &&
                (map['prevBlockHash'] as String).isNotEmpty
            ? [map['prevBlockHash'] as String]
            : <String>[]);
    final parents = rawParents.map((e) => e.toString()).toList();

    final rawEvents = map['events'] as List? ?? [];
    final events = rawEvents
        .map(
          (e) =>
              SecurityAuditEvent.fromMap(Map<String, dynamic>.from(e as Map)),
        )
        .toList();

    return SecurityBlock(
      version: (map['version'] as num?)?.toInt() ?? 1,
      index: (map['index'] as num).toInt(),
      blockHash: map['blockHash'] as String,
      parentBlockHashes: parents,
      creatorNodeId: map['creatorNodeId'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        map['timestampMs'] as int,
        isUtc: true,
      ),
      monotonicMicros: (map['monotonicMicros'] as num?)?.toInt() ?? 0,
      merkleRoot: map['merkleRoot'] as String,
      events: events,
      validationProof: Map<String, dynamic>.from(
        map['validationProof'] as Map? ?? {},
      ),
    );
  }

  String toCanonicalJson() => canonicalJsonEncode(toMap());
}

/// Status hasil validasi blok ledger.
enum LedgerValidationStatus {
  /// Blok sah dan memenuhi seluruh kriteria integritas kriptografis dan aturan DAG.
  valid,

  /// Struktur blok tidak lengkap, null, atau tidak sesuai skema.
  invalidStructure,

  /// Format hash bukan 64 karakter hex huruf kecil.
  invalidHashFormat,

  /// Rekomputasi hash header tidak cocok dengan blockHash.
  invalidHeaderHash,

  /// Rekomputasi Merkle root tidak cocok dengan merkleRoot blok.
  invalidMerkleRoot,

  /// Satu atau lebih parent hash tidak ditemukan pada ledger lokal maupun checkpoint.
  missingParent,

  /// Hash blok sudah pernah diproses sebelumnya (duplikasi blok).
  duplicateBlock,

  /// Satu atau lebih eventId di dalam blok sudah pernah diproses sebelumnya di rantai lain.
  duplicateEvent,

  /// Versi skema blok tidak didukung.
  unsupportedVersion,

  /// Timestamp blok berada di luar batas toleransi (melebihi batas waktu ke depan).
  timestampOutOfBounds,
}

/// Hasil evaluasi validasi blok.
class LedgerValidationResult {
  final bool isValid;
  final LedgerValidationStatus status;
  final String? message;

  const LedgerValidationResult({
    required this.isValid,
    required this.status,
    this.message,
  });

  const LedgerValidationResult.valid()
    : isValid = true,
      status = LedgerValidationStatus.valid,
      message = null;

  const LedgerValidationResult.invalid(this.status, [this.message])
    : isValid = false;

  @override
  String toString() =>
      'LedgerValidationResult(isValid: $isValid, status: $status, message: $message)';
}

/// Rekam jejak checkpoint jangkar untuk retensi dan pemangkasan blok usang (*safe pruning*).
class LedgerCheckpoint {
  final int checkpointIndex;
  final int lastPrunedIndex;
  final String retainedGenesisHash;
  final Set<String> prunedBlockHashes;
  final Set<String> prunedEventIds;
  final DateTime createdAt;
  final Map<String, dynamic> summaryMetadata;

  LedgerCheckpoint({
    required this.checkpointIndex,
    required this.lastPrunedIndex,
    required this.retainedGenesisHash,
    required Set<String> prunedBlockHashes,
    required Set<String> prunedEventIds,
    DateTime? createdAt,
    this.summaryMetadata = const {},
  }) : prunedBlockHashes = Set.unmodifiable(prunedBlockHashes),
       prunedEventIds = Set.unmodifiable(prunedEventIds),
       createdAt = createdAt ?? DateTime.now().toUtc();

  int get prunedBlockCount => prunedBlockHashes.length;
  int get prunedEventCount => prunedEventIds.length;

  Map<String, dynamic> toMap() => {
    'checkpointIndex': checkpointIndex,
    'lastPrunedIndex': lastPrunedIndex,
    'retainedGenesisHash': retainedGenesisHash,
    'prunedBlockCount': prunedBlockCount,
    'prunedEventCount': prunedEventCount,
    'prunedBlockHashes': prunedBlockHashes.toList(),
    'prunedEventIds': prunedEventIds.toList(),
    'createdAt': createdAt.toIso8601String(),
    'summaryMetadata': summaryMetadata,
  };

  factory LedgerCheckpoint.fromMap(Map<String, dynamic> map) {
    return LedgerCheckpoint(
      checkpointIndex: (map['checkpointIndex'] as num).toInt(),
      lastPrunedIndex: (map['lastPrunedIndex'] as num).toInt(),
      retainedGenesisHash: map['retainedGenesisHash'] as String,
      prunedBlockHashes: Set<String>.from(
        (map['prunedBlockHashes'] as List? ?? []).map((e) => e.toString()),
      ),
      prunedEventIds: Set<String>.from(
        (map['prunedEventIds'] as List? ?? []).map((e) => e.toString()),
      ),
      createdAt: map['createdAt'] != null
          ? DateTime.parse(map['createdAt'] as String)
          : DateTime.now().toUtc(),
      summaryMetadata: Map<String, dynamic>.from(
        map['summaryMetadata'] as Map? ?? {},
      ),
    );
  }
}

/// Model snapshot seluruh state BlockDAG untuk persistensi lokal dan pemulihan.
class BlockdagPersistedState {
  final int schemaVersion;
  final List<SecurityBlock> blocks;
  final List<LedgerCheckpoint> checkpoints;
  final List<String> tipHashes;
  final List<String> processedBlockHashes;
  final List<String> processedEventIds;
  final List<SecurityAuditEvent> pendingEvents;
  final DateTime savedAt;

  const BlockdagPersistedState({
    this.schemaVersion = 1,
    required this.blocks,
    this.checkpoints = const [],
    required this.tipHashes,
    required this.processedBlockHashes,
    required this.processedEventIds,
    this.pendingEvents = const [],
    required this.savedAt,
  });

  Map<String, dynamic> toMap() => {
    'schemaVersion': schemaVersion,
    'blocks': blocks.map((b) => b.toMap()).toList(),
    'checkpoints': checkpoints.map((c) => c.toMap()).toList(),
    'tipHashes': tipHashes,
    'processedBlockHashes': processedBlockHashes,
    'processedEventIds': processedEventIds,
    'pendingEvents': pendingEvents.map((e) => e.toMap()).toList(),
    'savedAt': savedAt.toUtc().toIso8601String(),
  };

  factory BlockdagPersistedState.fromMap(Map<String, dynamic> map) {
    final rawBlocks = map['blocks'] as List? ?? [];
    final blocks = rawBlocks
        .map((b) => SecurityBlock.fromMap(Map<String, dynamic>.from(b as Map)))
        .toList();

    final rawCheckpoints = map['checkpoints'] as List? ?? [];
    final checkpoints = rawCheckpoints
        .map(
          (c) => LedgerCheckpoint.fromMap(Map<String, dynamic>.from(c as Map)),
        )
        .toList();

    final rawPending = map['pendingEvents'] as List? ?? [];
    final pending = rawPending
        .map(
          (e) =>
              SecurityAuditEvent.fromMap(Map<String, dynamic>.from(e as Map)),
        )
        .toList();

    return BlockdagPersistedState(
      schemaVersion: (map['schemaVersion'] as num?)?.toInt() ?? 1,
      blocks: blocks,
      checkpoints: checkpoints,
      tipHashes: List<String>.from(map['tipHashes'] as List? ?? []),
      processedBlockHashes: List<String>.from(
        map['processedBlockHashes'] as List? ?? [],
      ),
      processedEventIds: List<String>.from(
        map['processedEventIds'] as List? ?? [],
      ),
      pendingEvents: pending,
      savedAt: map['savedAt'] != null
          ? DateTime.parse(map['savedAt'] as String)
          : DateTime.now().toUtc(),
    );
  }
}

/// Codec, parser, dan validator input untuk protokol replikasi gossip BlockDAG (DAG-Sync).
///
/// Bertanggung jawab atas:
/// 1. Serialisasi pesan bertipe ke byte array [Uint8List] deterministik (SACJ-v1).
/// 2. Parsing aman [Uint8List] mentah dengan perlindungan batas ukuran payload.
/// 3. Validasi ketat format hash SHA-256, batas daftar, deduplikasi hash, dan tipe data.
/// 4. Validasi kepatuhan privasi metadata event pada [DAG_BLOCK_BATCH].
/// 5. Penanganan kesalahan deterministik tanpa memicu *unhandled runtime exception*.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../blockchain_types.dart';
import 'gossip_constants.dart';
import 'gossip_messages.dart';
import 'gossip_privacy_sanitizer.dart';

/// Hasil decoding payload protokol gossip.
class DagGossipDecodeResult {
  final bool isSuccess;
  final DagGossipMessage? message;
  final String? errorCode;
  final String? errorMessage;

  const DagGossipDecodeResult.success(this.message)
    : isSuccess = true,
      errorCode = null,
      errorMessage = null;

  const DagGossipDecodeResult.failure(this.errorCode, this.errorMessage)
    : isSuccess = false,
      message = null;

  @override
  String toString() => isSuccess
      ? 'DagGossipDecodeResult.success(${message?.typeName})'
      : 'DagGossipDecodeResult.failure($errorCode: $errorMessage)';
}

/// Codec deterministik untuk de/serialisasi pesan protokol SiagaMesh DAG-Sync.
class DagGossipCodec {
  /// Mengonversi [DagGossipMessage] menjadi byte array [Uint8List] deterministik (SACJ-v1).
  static Uint8List encode(DagGossipMessage message) {
    return message.toBytes();
  }

  /// Membaca byte array mentah dari transport dan mengembalikan [DagGossipDecodeResult].
  ///
  /// Menjamin:
  /// - Pemeriksaan ukuran payload [kMaxRawGossipPayloadBytes] sebelum decoding JSON.
  /// - Menangkap seluruh [FormatException], [TypeError], dan [ArgumentError] secara aman.
  static DagGossipDecodeResult decode(Uint8List bytes) {
    // 1. Validasi batas awal ukuran byte mentah
    if (bytes.isEmpty) {
      return const DagGossipDecodeResult.failure(
        DagRejectCode.emptyPayload,
        'Payload byte kosong',
      );
    }
    if (bytes.length > kMaxRawGossipPayloadBytes) {
      return DagGossipDecodeResult.failure(
        DagRejectCode.payloadTooLarge,
        'Ukuran payload (${bytes.length} bytes) melebihi batas maksimum ($kMaxRawGossipPayloadBytes bytes)',
      );
    }

    // 2. Decode UTF-8 string
    String jsonStr;
    try {
      jsonStr = utf8.decode(bytes);
    } catch (e) {
      return DagGossipDecodeResult.failure(
        DagRejectCode.malformedJson,
        'Payload byte bukan encoding UTF-8 valid: $e',
      );
    }

    return decodeFromJson(jsonStr, rawByteLength: bytes.length);
  }

  /// Mendekode pesan dari string JSON.
  static DagGossipDecodeResult decodeFromJson(
    String jsonStr, {
    int? rawByteLength,
  }) {
    if (jsonStr.trim().isEmpty) {
      return const DagGossipDecodeResult.failure(
        DagRejectCode.emptyPayload,
        'String JSON kosong',
      );
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(jsonStr);
    } catch (e) {
      return DagGossipDecodeResult.failure(
        DagRejectCode.malformedJson,
        'Format JSON rusak: $e',
      );
    }

    if (decoded is! Map<String, dynamic>) {
      return const DagGossipDecodeResult.failure(
        DagRejectCode.invalidFieldType,
        'Root payload protokol harus berupa Map/JSON Object',
      );
    }

    final byteLen = rawByteLength ?? utf8.encode(jsonStr).length;
    return decodeFromMap(decoded, rawByteLength: byteLen);
  }

  /// Mendekode dan memvalidasi pesan dari Map struktur data.
  static DagGossipDecodeResult decodeFromMap(
    Map<String, dynamic> map, {
    int? rawByteLength,
  }) {
    try {
      // 1. Validasi field protokol dasar
      final rawProtocol = map['protocol'];
      if (rawProtocol == null) {
        return const DagGossipDecodeResult.failure(
          DagRejectCode.missingRequiredField,
          'Field "protocol" wajib ada',
        );
      }
      if (rawProtocol is! String || rawProtocol != kDagGossipProtocolName) {
        return DagGossipDecodeResult.failure(
          DagRejectCode.unsupportedProtocol,
          'Nama protokol "$rawProtocol" tidak didukung',
        );
      }

      final rawVersion = map['version'];
      if (rawVersion == null) {
        return const DagGossipDecodeResult.failure(
          DagRejectCode.missingRequiredField,
          'Field "version" wajib ada',
        );
      }
      if (rawVersion is! int || rawVersion != kDagGossipProtocolVersion) {
        return DagGossipDecodeResult.failure(
          DagRejectCode.unsupportedVersion,
          'Versi protokol "$rawVersion" tidak didukung (harus versi $kDagGossipProtocolVersion)',
        );
      }

      final rawType = map['type'];
      if (rawType == null) {
        return const DagGossipDecodeResult.failure(
          DagRejectCode.missingRequiredField,
          'Field "type" wajib ada',
        );
      }
      if (rawType is! String) {
        return const DagGossipDecodeResult.failure(
          DagRejectCode.invalidFieldType,
          'Field "type" harus bertipe String',
        );
      }

      final messageType = DagGossipMessageType.fromWireName(rawType);
      if (messageType == null) {
        return DagGossipDecodeResult.failure(
          DagRejectCode.unsupportedType,
          'Tipe pesan gossip "$rawType" tidak dikenal',
        );
      }

      final rawSender = map['senderNodeId'];
      if (rawSender == null) {
        return const DagGossipDecodeResult.failure(
          DagRejectCode.missingRequiredField,
          'Field "senderNodeId" wajib ada',
        );
      }
      if (rawSender is! String || rawSender.trim().isEmpty) {
        return const DagGossipDecodeResult.failure(
          DagRejectCode.invalidFieldType,
          'Field "senderNodeId" harus berupa String tidak kosong',
        );
      }
      if (rawSender.length > kMaxIdentifierLength) {
        return DagGossipDecodeResult.failure(
          DagRejectCode.invalidFieldType,
          'Field "senderNodeId" melebihi batas $kMaxIdentifierLength karakter',
        );
      }

      // 2. Dispatch parsing spesifik berdasarkan jenis pesan
      switch (messageType) {
        case DagGossipMessageType.hello:
          return _decodeHello(map, rawSender);

        case DagGossipMessageType.inv:
          return _decodeInv(map, rawSender);

        case DagGossipMessageType.getBlocks:
          return _decodeGetBlocks(map, rawSender);

        case DagGossipMessageType.blockBatch:
          return _decodeBlockBatch(map, rawSender, rawByteLength);

        case DagGossipMessageType.syncAck:
          return _decodeSyncAck(map, rawSender);

        case DagGossipMessageType.reject:
          return _decodeReject(map, rawSender);

        case DagGossipMessageType.prunedNotice:
          return _decodePrunedNotice(map, rawSender);
      }
    } catch (e) {
      return DagGossipDecodeResult.failure(
        DagRejectCode.invalidBlockStructure,
        'Gagal mem-parsing payload pesan: $e',
      );
    }
  }

  // --- Helper Parser Spesifik ---

  static DagGossipDecodeResult _decodeHello(
    Map<String, dynamic> map,
    String senderNodeId,
  ) {
    final senderTimestamp = _validatePositiveInt(map, 'senderTimestamp');
    if (senderTimestamp == null) {
      return const DagGossipDecodeResult.failure(
        DagRejectCode.invalidFieldType,
        'Field "senderTimestamp" harus bertipe integer positif',
      );
    }

    final schemaVersion = _validatePositiveInt(map, 'schemaVersion');
    if (schemaVersion == null) {
      return const DagGossipDecodeResult.failure(
        DagRejectCode.invalidFieldType,
        'Field "schemaVersion" harus bertipe integer positif',
      );
    }

    final activeBlocksCount = _validateNonNegativeInt(map, 'activeBlocksCount');
    if (activeBlocksCount == null) {
      return const DagGossipDecodeResult.failure(
        DagRejectCode.invalidFieldType,
        'Field "activeBlocksCount" harus bertipe integer non-negatif',
      );
    }

    final maxIndex = _validateNonNegativeInt(map, 'maxIndex');
    if (maxIndex == null) {
      return const DagGossipDecodeResult.failure(
        DagRejectCode.invalidFieldType,
        'Field "maxIndex" harus bertipe integer non-negatif',
      );
    }

    final tipHashesRes = _validateHashList(
      map['tipHashes'],
      minCount: 1,
      maxCount: kMaxTipHashes,
      fieldName: 'tipHashes',
    );
    if (!tipHashesRes.isSuccess) return tipHashesRes;

    final genesisHashRes = _validateSingleHash(
      map['genesisHash'],
      fieldName: 'genesisHash',
    );
    if (!genesisHashRes.isSuccess) return genesisHashRes;

    return DagGossipDecodeResult.success(
      DagHelloMessage(
        senderNodeId: senderNodeId,
        senderTimestamp: senderTimestamp,
        schemaVersion: schemaVersion,
        activeBlocksCount: activeBlocksCount,
        maxIndex: maxIndex,
        tipHashes: tipHashesRes.hashes!,
        genesisHash: genesisHashRes.hash!,
      ),
    );
  }

  static DagGossipDecodeResult _decodeInv(
    Map<String, dynamic> map,
    String senderNodeId,
  ) {
    final senderTimestamp = _validatePositiveInt(map, 'senderTimestamp');
    if (senderTimestamp == null) {
      return const DagGossipDecodeResult.failure(
        DagRejectCode.invalidFieldType,
        'Field "senderTimestamp" harus bertipe integer positif',
      );
    }

    final tipHashesRes = _validateHashList(
      map['tipHashes'],
      minCount: 1,
      maxCount: kMaxTipHashes,
      fieldName: 'tipHashes',
    );
    if (!tipHashesRes.isSuccess) return tipHashesRes;

    final recentRes = _validateHashList(
      map['recentBlockHashes'] ?? <dynamic>[],
      minCount: 0,
      maxCount: kMaxInvHashes,
      fieldName: 'recentBlockHashes',
    );
    if (!recentRes.isSuccess) return recentRes;

    return DagGossipDecodeResult.success(
      DagInvMessage(
        senderNodeId: senderNodeId,
        senderTimestamp: senderTimestamp,
        tipHashes: tipHashesRes.hashes!,
        recentBlockHashes: recentRes.hashes ?? const [],
      ),
    );
  }

  static DagGossipDecodeResult _decodeGetBlocks(
    Map<String, dynamic> map,
    String senderNodeId,
  ) {
    final requestId = _validateRequestId(map['requestId']);
    if (requestId == null) {
      return const DagGossipDecodeResult.failure(
        DagRejectCode.missingRequiredField,
        'Field "requestId" wajib ada dan berupa String tidak kosong <= 64 karakter',
      );
    }

    final rawList = map['requestedBlockHashes'];
    if (rawList == null || rawList is! List || rawList.isEmpty) {
      return const DagGossipDecodeResult.failure(
        DagRejectCode.emptyPayload,
        'Daftar "requestedBlockHashes" tidak boleh kosong',
      );
    }

    if (rawList.length > kMaxGetBlocksHashes) {
      return DagGossipDecodeResult.failure(
        DagRejectCode.exceedsHashLimit,
        'Jumlah hash yang diminta (${rawList.length}) melebihi batas $kMaxGetBlocksHashes hash per request',
      );
    }

    final hashesRes = _validateHashList(
      rawList,
      minCount: 1,
      maxCount: kMaxGetBlocksHashes,
      fieldName: 'requestedBlockHashes',
    );
    if (!hashesRes.isSuccess) return hashesRes;

    return DagGossipDecodeResult.success(
      DagGetBlocksMessage(
        senderNodeId: senderNodeId,
        requestId: requestId,
        requestedBlockHashes: hashesRes.hashes!,
      ),
    );
  }

  static DagGossipDecodeResult _decodeBlockBatch(
    Map<String, dynamic> map,
    String senderNodeId,
    int? rawByteLength,
  ) {
    // Validasi batas ukuran paket batch 16 KiB
    final byteLen =
        rawByteLength ?? utf8.encode(canonicalJsonEncode(map)).length;
    if (byteLen > kMaxBatchPayloadBytes) {
      return DagGossipDecodeResult.failure(
        DagRejectCode.batchPayloadTooLarge,
        'Ukuran paket DAG_BLOCK_BATCH ($byteLen bytes) melebihi batas maksimum ($kMaxBatchPayloadBytes bytes)',
      );
    }

    final requestId = _validateRequestId(map['requestId']);
    if (requestId == null) {
      return const DagGossipDecodeResult.failure(
        DagRejectCode.missingRequiredField,
        'Field "requestId" wajib ada dan berupa String tidak kosong <= 64 karakter',
      );
    }

    final batchIndex = _validatePositiveInt(map, 'batchIndex');
    final totalBatches = _validatePositiveInt(map, 'totalBatches');
    if (batchIndex == null || totalBatches == null) {
      return const DagGossipDecodeResult.failure(
        DagRejectCode.invalidFieldType,
        'Field "batchIndex" dan "totalBatches" harus berupa integer positif',
      );
    }
    if (batchIndex > totalBatches) {
      return DagGossipDecodeResult.failure(
        DagRejectCode.invalidFieldType,
        'batchIndex ($batchIndex) tidak boleh lebih besar dari totalBatches ($totalBatches)',
      );
    }

    final rawBlocks = map['blocks'];
    if (rawBlocks == null || rawBlocks is! List || rawBlocks.isEmpty) {
      return const DagGossipDecodeResult.failure(
        DagRejectCode.emptyPayload,
        'Daftar "blocks" dalam batch tidak boleh kosong',
      );
    }
    if (rawBlocks.length > kMaxBlocksPerBatch) {
      return DagGossipDecodeResult.failure(
        DagRejectCode.exceedsHashLimit,
        'Jumlah blok (${rawBlocks.length}) melebihi batas $kMaxBlocksPerBatch per batch',
      );
    }

    final parsedBlocks = <SecurityBlock>[];
    for (int i = 0; i < rawBlocks.length; i++) {
      final rawBlock = rawBlocks[i];
      if (rawBlock is! Map) {
        return DagGossipDecodeResult.failure(
          DagRejectCode.invalidBlockStructure,
          'Elemen blok pada indeks $i bukan berupa Map',
        );
      }

      SecurityBlock block;
      try {
        block = SecurityBlock.fromMap(Map<String, dynamic>.from(rawBlock));
      } catch (e) {
        return DagGossipDecodeResult.failure(
          DagRejectCode.invalidBlockStructure,
          'Gagal mem-parsing blok pada indeks $i: $e',
        );
      }

      // Validasi kepatuhan privasi metadata event
      final privacyRes = GossipPrivacySanitizer.validateBlock(block);
      if (!privacyRes.isCompliant) {
        return DagGossipDecodeResult.failure(
          DagRejectCode.privacyViolation,
          'Pelanggaran privasi pada blok ${block.blockHash}: ${privacyRes.violationReason}',
        );
      }

      parsedBlocks.add(block);
    }

    return DagGossipDecodeResult.success(
      DagBlockBatchMessage(
        senderNodeId: senderNodeId,
        requestId: requestId,
        batchIndex: batchIndex,
        totalBatches: totalBatches,
        blocks: parsedBlocks,
      ),
    );
  }

  static DagGossipDecodeResult _decodeSyncAck(
    Map<String, dynamic> map,
    String senderNodeId,
  ) {
    final requestId = _validateRequestId(map['requestId']);
    if (requestId == null) {
      return const DagGossipDecodeResult.failure(
        DagRejectCode.missingRequiredField,
        'Field "requestId" wajib ada',
      );
    }

    final acceptedRes = _validateHashList(
      map['acceptedBlockHashes'] ?? <dynamic>[],
      minCount: 0,
      maxCount: kMaxTipHashes,
      fieldName: 'acceptedBlockHashes',
    );
    if (!acceptedRes.isSuccess) return acceptedRes;

    final tipsRes = _validateHashList(
      map['newTipHashes'],
      minCount: 1,
      maxCount: kMaxTipHashes,
      fieldName: 'newTipHashes',
    );
    if (!tipsRes.isSuccess) return tipsRes;

    return DagGossipDecodeResult.success(
      DagSyncAckMessage(
        senderNodeId: senderNodeId,
        requestId: requestId,
        acceptedBlockHashes: acceptedRes.hashes ?? const [],
        newTipHashes: tipsRes.hashes!,
      ),
    );
  }

  static DagGossipDecodeResult _decodeReject(
    Map<String, dynamic> map,
    String senderNodeId,
  ) {
    final errorCode = map['errorCode'];
    if (errorCode == null || errorCode is! String || errorCode.trim().isEmpty) {
      return const DagGossipDecodeResult.failure(
        DagRejectCode.missingRequiredField,
        'Field "errorCode" wajib ada dan berupa String',
      );
    }

    final errorMessage = map['errorMessage'];
    if (errorMessage == null ||
        errorMessage is! String ||
        errorMessage.trim().isEmpty) {
      return const DagGossipDecodeResult.failure(
        DagRejectCode.missingRequiredField,
        'Field "errorMessage" wajib ada dan berupa String',
      );
    }
    if (errorMessage.length > kMaxErrorMessageLength) {
      return DagGossipDecodeResult.failure(
        DagRejectCode.invalidFieldType,
        'Field "errorMessage" melebihi batas $kMaxErrorMessageLength karakter',
      );
    }

    final requestId = _validateRequestId(map['requestId'], isOptional: true);
    final rawRejectedHash = map['rejectedHash'];
    String? rejectedHash;
    if (rawRejectedHash != null) {
      if (rawRejectedHash is! String ||
          !kSha256HexRegex.hasMatch(rawRejectedHash)) {
        return const DagGossipDecodeResult.failure(
          DagRejectCode.invalidHashFormat,
          'Format "rejectedHash" tidak valid',
        );
      }
      rejectedHash = rawRejectedHash;
    }

    return DagGossipDecodeResult.success(
      DagRejectMessage(
        senderNodeId: senderNodeId,
        requestId: requestId,
        rejectedHash: rejectedHash,
        errorCode: errorCode,
        errorMessage: errorMessage,
      ),
    );
  }

  static DagGossipDecodeResult _decodePrunedNotice(
    Map<String, dynamic> map,
    String senderNodeId,
  ) {
    final requestId = _validateRequestId(map['requestId']);
    if (requestId == null) {
      return const DagGossipDecodeResult.failure(
        DagRejectCode.missingRequiredField,
        'Field "requestId" wajib ada',
      );
    }

    final prunedRes = _validateHashList(
      map['prunedBlockHashes'],
      minCount: 1,
      maxCount: kMaxTipHashes,
      fieldName: 'prunedBlockHashes',
    );
    if (!prunedRes.isSuccess) return prunedRes;

    final lastPrunedIndex = _validateNonNegativeInt(map, 'lastPrunedIndex');
    if (lastPrunedIndex == null) {
      return const DagGossipDecodeResult.failure(
        DagRejectCode.invalidFieldType,
        'Field "lastPrunedIndex" harus berupa integer non-negatif',
      );
    }

    final retainedRes = _validateSingleHash(
      map['retainedGenesisHash'],
      fieldName: 'retainedGenesisHash',
    );
    if (!retainedRes.isSuccess) return retainedRes;

    return DagGossipDecodeResult.success(
      DagPrunedNoticeMessage(
        senderNodeId: senderNodeId,
        requestId: requestId,
        prunedBlockHashes: prunedRes.hashes!,
        lastPrunedIndex: lastPrunedIndex,
        retainedGenesisHash: retainedRes.hash!,
      ),
    );
  }

  // --- Validasi Primitif Utility ---

  static int? _validatePositiveInt(Map<String, dynamic> map, String key) {
    final val = map[key];
    if (val == null || val is! num) return null;
    if (val is double && val != val.truncateToDouble()) return null;
    final intVal = val.toInt();
    if (intVal <= 0) return null;
    return intVal;
  }

  static int? _validateNonNegativeInt(Map<String, dynamic> map, String key) {
    final val = map[key];
    if (val == null || val is! num) return null;
    if (val is double && val != val.truncateToDouble()) return null;
    final intVal = val.toInt();
    if (intVal < 0) return null;
    return intVal;
  }

  static String? _validateRequestId(dynamic val, {bool isOptional = false}) {
    if (val == null) return isOptional ? null : null;
    if (val is! String || val.trim().isEmpty) return null;
    if (val.length > kMaxIdentifierLength) return null;
    return val;
  }

  static _SingleHashValidationResult _validateSingleHash(
    dynamic val, {
    required String fieldName,
  }) {
    if (val == null) {
      return _SingleHashValidationResult.failure(
        DagRejectCode.missingRequiredField,
        'Field "$fieldName" wajib ada',
      );
    }
    if (val is! String) {
      return _SingleHashValidationResult.failure(
        DagRejectCode.invalidFieldType,
        'Field "$fieldName" harus berupa String',
      );
    }
    if (!kSha256HexRegex.hasMatch(val)) {
      return _SingleHashValidationResult.failure(
        DagRejectCode.invalidHashFormat,
        'Format "$fieldName" harus 64 karakter hex huruf kecil, ditemukan: $val',
      );
    }
    return _SingleHashValidationResult.success(val);
  }

  static _HashListValidationResult _validateHashList(
    dynamic rawList, {
    required int minCount,
    required int maxCount,
    required String fieldName,
  }) {
    if (rawList == null) {
      if (minCount == 0) return const _HashListValidationResult.success([]);
      return _HashListValidationResult.failure(
        DagRejectCode.missingRequiredField,
        'Field "$fieldName" wajib ada',
      );
    }
    if (rawList is! List) {
      return _HashListValidationResult.failure(
        DagRejectCode.invalidFieldType,
        'Field "$fieldName" harus berupa List',
      );
    }
    if (rawList.length < minCount) {
      return _HashListValidationResult.failure(
        DagRejectCode.emptyPayload,
        'Daftar "$fieldName" tidak boleh kosong',
      );
    }
    if (rawList.length > maxCount) {
      return _HashListValidationResult.failure(
        DagRejectCode.exceedsHashLimit,
        'Jumlah elemen "$fieldName" (${rawList.length}) melebihi batas $maxCount',
      );
    }

    final hashes = <String>[];
    final seen = <String>{};
    for (int i = 0; i < rawList.length; i++) {
      final elem = rawList[i];
      if (elem is! String) {
        return _HashListValidationResult.failure(
          DagRejectCode.invalidFieldType,
          'Elemen pada "$fieldName" indeks $i bukan String',
        );
      }
      if (!kSha256HexRegex.hasMatch(elem)) {
        return _HashListValidationResult.failure(
          DagRejectCode.invalidHashFormat,
          'Elemen pada "$fieldName" indeks $i bukan 64 karakter hex huruf kecil: $elem',
        );
      }
      if (!seen.add(elem)) {
        return _HashListValidationResult.failure(
          DagRejectCode.duplicateHash,
          'Duplikasi hash terdeteksi pada "$fieldName": $elem',
        );
      }
      hashes.add(elem);
    }

    return _HashListValidationResult.success(hashes);
  }
}

class _SingleHashValidationResult extends DagGossipDecodeResult {
  final String? hash;
  const _SingleHashValidationResult.success(this.hash) : super.success(null);
  const _SingleHashValidationResult.failure(super.errorCode, super.errorMessage)
    : hash = null,
      super.failure();
}

class _HashListValidationResult extends DagGossipDecodeResult {
  final List<String>? hashes;
  const _HashListValidationResult.success(this.hashes) : super.success(null);
  const _HashListValidationResult.failure(super.errorCode, super.errorMessage)
    : hashes = null,
      super.failure();
}

/// Sanitizer dan validator kepatuhan privasi untuk audit event dan blok replikasi BlockDAG.
///
/// PERNYATAAN PRIVASI & BATAS KEAMANAN:
/// 1. Protokol replikasi gossip SiagaMesh DAG-Sync SECARA KETAT HANYA mereplikasi
///    metadata audit teknis perutean dan keamanan.
/// 2. DILARANG KERAS menyerialisasi atau menyebarkan: isi pesan teks obrolan (*chat body*),
///    koordinat GPS korban/relawan, nomor telepon, identitas pribadi, atau kredensial/rahasia.
/// 3. Peringatan Autentikasi: [senderNodeId] dan [creatorNodeId] saat ini masih merupakan
///    identitas teknis berbasis klaim diri (*self-claimed*). Tanda tangan asimetris digital
///    dan Public Key Infrastructure (PKI) belum tersedia pada tahap ini.
library;

import '../blockchain_types.dart';
import 'gossip_constants.dart';

/// Hasil evaluasi kepatuhan privasi untuk event atau blok audit.
class PrivacyValidationResult {
  final bool isCompliant;
  final String? violationReason;

  const PrivacyValidationResult.valid()
    : isCompliant = true,
      violationReason = null;

  const PrivacyValidationResult.invalid(this.violationReason)
    : isCompliant = false;

  @override
  String toString() => isCompliant
      ? 'PrivacyValidationResult.valid'
      : 'PrivacyValidationResult.invalid: $violationReason';
}

/// Validator privasi berbasis allowlist ketat (*strict metadata allowlist*).
class GossipPrivacySanitizer {
  /// Kunci metadata yang diizinkan untuk setiap tipe event audit.
  static const Map<AuditEventType, Set<String>> _allowedMetadataKeys = {
    AuditEventType.idsDetection: {
      'status',
      'observedDropRate',
      'totalExpected',
      'totalClaimed',
      'totalUnconfirmed',
      'totalLinkFailures',
      'totalProtocolDrops',
      'reason',
    },
    AuditEventType.trustUpdate: {
      'oldScore',
      'newScore',
      'delta',
      'evidenceType',
      'evaluationStatus',
      'reason',
      'protocolResponsivenessCount',
      'relayClaimCount',
      'verifiedForwardingCount',
      'unconfirmedDropCount',
    },
    AuditEventType.isolationDecision: {'action', 'score', 'reason'},
    AuditEventType.checkpointAnchor: {
      'prunedBlockCount',
      'lastPrunedIndex',
      'retainedGenesisHash',
    },
  };

  /// Kunci metadata proof validasi blok yang diizinkan untuk replikasi.
  static const Set<String> _allowedValidationProofKeys = {
    'creatorNodeName',
    'type',
    'network',
    'signatureType',
    'flushReason',
    'creatorNodeId',
  };

  /// Nilai flushReason yang sah dan digunakan oleh aplikasi/koordinator.
  static const Set<String> _allowedFlushReasons = {
    'emergency_suspected',
    'batch_capacity',
    'manual',
    'controlled_time_flush',
    'timeout_flush',
  };

  /// Pola kata kunci terlarang (sensitif/privasi) yang tidak boleh muncul dalam metadata.
  static final List<RegExp> _forbiddenPatterns = [
    RegExp(r'\b(chat|text|message_body|body)\b', caseSensitive: false),
    RegExp(
      r'\b(gps|lat|latitude|lon|longitude|altitude|coord)\b',
      caseSensitive: false,
    ),
    RegExp(r'\b(phone|tel|email|contact|victim)\b', caseSensitive: false),
    RegExp(
      r'\b(token|password|secret|credential|privkey|private_key)\b',
      caseSensitive: false,
    ),
  ];

  /// Memvalidasi kepatuhan privasi untuk seluruh blok audit beserta event-event di dalamnya.
  static PrivacyValidationResult validateBlock(SecurityBlock block) {
    if (block.creatorNodeId.length > kMaxIdentifierLength) {
      return PrivacyValidationResult.invalid(
        'creatorNodeId melebihi batas $kMaxIdentifierLength karakter',
      );
    }

    // Validasi validationProof metadata
    for (final key in block.validationProof.keys) {
      if (!_allowedValidationProofKeys.contains(key)) {
        return PrivacyValidationResult.invalid(
          'Kunci validationProof tidak diizinkan untuk replikasi: $key',
        );
      }
      final value = block.validationProof[key];

      // Validasi khusus untuk flushReason: hanya izinkan nilai operasional yang sah
      if (key == 'flushReason') {
        if (value is! String || !_allowedFlushReasons.contains(value)) {
          return PrivacyValidationResult.invalid(
            'Nilai flushReason "$value" tidak diizinkan dalam validationProof',
          );
        }
      }

      // Validasi khusus untuk creatorNodeId: harus konsisten dengan identitas kreator blok
      if (key == 'creatorNodeId') {
        if (value is! String || value != block.creatorNodeId) {
          return PrivacyValidationResult.invalid(
            'creatorNodeId dalam validationProof ($value) tidak cocok dengan creatorNodeId blok (${block.creatorNodeId})',
          );
        }
      }

      if (value is String && value.length > kMaxMetadataReasonLength) {
        return PrivacyValidationResult.invalid(
          'Nilai validationProof[$key] melebihi batas panjang maksimum',
        );
      }
    }

    // Validasi seluruh event audit di dalam blok
    for (final event in block.events) {
      final eventResult = validateEvent(event);
      if (!eventResult.isCompliant) {
        return eventResult;
      }
    }

    return const PrivacyValidationResult.valid();
  }

  /// Memvalidasi kepatuhan privasi untuk satu [SecurityAuditEvent].
  static PrivacyValidationResult validateEvent(SecurityAuditEvent event) {
    if (event.eventId.length > kMaxIdentifierLength) {
      return PrivacyValidationResult.invalid(
        'eventId melebihi batas $kMaxIdentifierLength karakter',
      );
    }
    if (event.observerNodeId.length > kMaxIdentifierLength) {
      return PrivacyValidationResult.invalid(
        'observerNodeId melebihi batas $kMaxIdentifierLength karakter',
      );
    }
    if (event.targetNodeId.length > kMaxIdentifierLength) {
      return PrivacyValidationResult.invalid(
        'targetNodeId melebihi batas $kMaxIdentifierLength karakter',
      );
    }

    final allowedKeys = _allowedMetadataKeys[event.eventType];
    if (allowedKeys == null) {
      return PrivacyValidationResult.invalid(
        'Tipe event ${event.eventType} tidak memiliki allowlist metadata',
      );
    }

    for (final entry in event.metadata.entries) {
      final key = entry.key;
      final value = entry.value;

      // 1. Periksa apakah key termasuk dalam allowlist
      if (!allowedKeys.contains(key)) {
        return PrivacyValidationResult.invalid(
          'Kunci metadata "$key" tidak diizinkan pada event ${event.eventType.name}',
        );
      }

      // 2. Periksa apakah key atau nama string melanggar pola kata terlarang
      for (final pattern in _forbiddenPatterns) {
        if (pattern.hasMatch(key)) {
          return PrivacyValidationResult.invalid(
            'Kunci metadata "$key" mengandung kata kunci terlarang',
          );
        }
      }

      // 3. Periksa nilai string jika ada (misal pada field reason)
      if (value is String) {
        if (value.length > kMaxMetadataReasonLength) {
          return PrivacyValidationResult.invalid(
            'Nilai metadata[$key] melebihi batas maksimum $kMaxMetadataReasonLength karakter',
          );
        }
        for (final pattern in _forbiddenPatterns) {
          if (pattern.hasMatch(value)) {
            return PrivacyValidationResult.invalid(
              'Nilai metadata[$key] terdeteksi mengandung konten privasi terlarang: "$value"',
            );
          }
        }
      } else if (value is num) {
        if (value.isNaN || value.isInfinite) {
          return PrivacyValidationResult.invalid(
            'Nilai numerik metadata[$key] tidak valid (NaN/Infinite)',
          );
        }
      }
    }

    return const PrivacyValidationResult.valid();
  }
}

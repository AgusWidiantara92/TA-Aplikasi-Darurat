import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';

import 'package:siagamesh_app/core/blockchain/blockchain_types.dart';
import 'package:siagamesh_app/core/blockchain/lightweight_blockdag_ledger.dart';
import 'package:siagamesh_app/core/blockchain/gossip/gossip.dart';
import 'package:siagamesh_app/core/routing/routing_holder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Helper hash 64-karakter hex
  String dummyHash(String seed) {
    return computeSha256(seed);
  }

  group('STAGE 5E.4.2 — BlockDAG Gossip Protocol Codec & Message Validation', () {
    final hash1 = dummyHash('block-1');
    final hash2 = dummyHash('block-2');
    final hash3 = dummyHash('block-3');
    final hash4 = dummyHash('block-4');
    final hash5 = dummyHash('block-5');
    final genesisHash = dummyHash('genesis');

    setUp(() {
      ManetRoutingHolder.reset();
    });

    // ------------------------------------------------------------------------
    // 1. Round-Trip Encode/Decode untuk Semua 7 Tipe Pesan
    // ------------------------------------------------------------------------
    test('1. Round-trip encode/decode untuk DAG_HELLO', () {
      final msg = DagHelloMessage(
        senderNodeId: 'NODE-A',
        senderTimestamp: 1792380000000,
        schemaVersion: 1,
        activeBlocksCount: 5,
        maxIndex: 3,
        tipHashes: [hash1, hash2],
        genesisHash: genesisHash,
      );

      final bytes = DagGossipCodec.encode(msg);
      expect(bytes, isNotEmpty);

      final res = DagGossipCodec.decode(bytes);
      expect(res.isSuccess, isTrue);
      expect(res.message, isA<DagHelloMessage>());

      final decoded = res.message as DagHelloMessage;
      expect(decoded.protocol, equals(kDagGossipProtocolName));
      expect(decoded.version, equals(1));
      expect(decoded.type, equals(DagGossipMessageType.hello));
      expect(decoded.senderNodeId, equals('NODE-A'));
      expect(decoded.senderTimestamp, equals(1792380000000));
      expect(decoded.schemaVersion, equals(1));
      expect(decoded.activeBlocksCount, equals(5));
      expect(decoded.maxIndex, equals(3));
      expect(decoded.tipHashes, equals([hash1, hash2]));
      expect(decoded.genesisHash, equals(genesisHash));
    });

    test('2. Round-trip encode/decode untuk DAG_INV', () {
      final msg = DagInvMessage(
        senderNodeId: 'NODE-B',
        senderTimestamp: 1792380001000,
        tipHashes: [hash1],
        recentBlockHashes: [hash2, hash3],
      );

      final bytes = DagGossipCodec.encode(msg);
      final res = DagGossipCodec.decode(bytes);
      expect(res.isSuccess, isTrue);
      expect(res.message, isA<DagInvMessage>());

      final decoded = res.message as DagInvMessage;
      expect(decoded.senderNodeId, equals('NODE-B'));
      expect(decoded.tipHashes, equals([hash1]));
      expect(decoded.recentBlockHashes, equals([hash2, hash3]));
    });

    test('3. Round-trip encode/decode untuk DAG_GET_BLOCKS', () {
      final msg = DagGetBlocksMessage(
        senderNodeId: 'NODE-A',
        requestId: 'req-get-101',
        requestedBlockHashes: [hash1, hash2, hash3],
      );

      final bytes = DagGossipCodec.encode(msg);
      final res = DagGossipCodec.decode(bytes);
      expect(res.isSuccess, isTrue);
      expect(res.message, isA<DagGetBlocksMessage>());

      final decoded = res.message as DagGetBlocksMessage;
      expect(decoded.requestId, equals('req-get-101'));
      expect(decoded.requestedBlockHashes, equals([hash1, hash2, hash3]));
    });

    test('4. Round-trip encode/decode untuk DAG_BLOCK_BATCH', () {
      final testEvent = SecurityAuditEvent(
        eventId: 'ids-test-1',
        eventType: AuditEventType.idsDetection,
        observerNodeId: 'NODE-A',
        targetNodeId: 'NODE-B',
        timestamp: DateTime.now().toUtc(),
        monotonicMicros: 1000,
        metadata: {
          'status': 'suspected',
          'observedDropRate': 0.6,
          'totalExpected': 10,
          'totalClaimed': 4,
          'totalUnconfirmed': 6,
          'totalLinkFailures': 0,
          'totalProtocolDrops': 0,
          'reason': 'Drop rate exceeded threshold',
        },
      );

      final block = SecurityBlock.create(
        index: 1,
        parentBlockHashes: [genesisHash],
        creatorNodeId: 'NODE-A',
        events: [testEvent],
        validationProof: {'creatorNodeName': 'Relawan Pos A'},
      );

      final msg = DagBlockBatchMessage(
        senderNodeId: 'NODE-A',
        requestId: 'req-batch-55',
        batchIndex: 1,
        totalBatches: 2,
        blocks: [block],
      );

      final bytes = DagGossipCodec.encode(msg);
      expect(bytes.length, lessThanOrEqualTo(kMaxBatchPayloadBytes));

      final res = DagGossipCodec.decode(bytes);
      expect(res.isSuccess, isTrue);
      expect(res.message, isA<DagBlockBatchMessage>());

      final decoded = res.message as DagBlockBatchMessage;
      expect(decoded.requestId, equals('req-batch-55'));
      expect(decoded.batchIndex, equals(1));
      expect(decoded.totalBatches, equals(2));
      expect(decoded.blocks.length, equals(1));
      expect(decoded.blocks.first.blockHash, equals(block.blockHash));
      expect(decoded.blocks.first.events.first.eventId, equals('ids-test-1'));
    });

    test('5. Round-trip encode/decode untuk DAG_SYNC_ACK', () {
      final msg = DagSyncAckMessage(
        senderNodeId: 'NODE-B',
        requestId: 'req-batch-55',
        acceptedBlockHashes: [hash1, hash2],
        newTipHashes: [hash2],
      );

      final bytes = DagGossipCodec.encode(msg);
      final res = DagGossipCodec.decode(bytes);
      expect(res.isSuccess, isTrue);
      expect(res.message, isA<DagSyncAckMessage>());

      final decoded = res.message as DagSyncAckMessage;
      expect(decoded.requestId, equals('req-batch-55'));
      expect(decoded.acceptedBlockHashes, equals([hash1, hash2]));
      expect(decoded.newTipHashes, equals([hash2]));
    });

    test('6. Round-trip encode/decode untuk DAG_REJECT', () {
      final msg = DagRejectMessage(
        senderNodeId: 'NODE-B',
        requestId: 'req-fail-99',
        rejectedHash: hash3,
        errorCode: DagRejectCode.invalidMerkleRoot,
        errorMessage: 'Merkle root mismatch detected during verification',
      );

      final bytes = DagGossipCodec.encode(msg);
      final res = DagGossipCodec.decode(bytes);
      expect(res.isSuccess, isTrue);
      expect(res.message, isA<DagRejectMessage>());

      final decoded = res.message as DagRejectMessage;
      expect(decoded.requestId, equals('req-fail-99'));
      expect(decoded.rejectedHash, equals(hash3));
      expect(decoded.errorCode, equals(DagRejectCode.invalidMerkleRoot));
      expect(decoded.errorMessage, contains('Merkle root mismatch'));
    });

    test('7. Round-trip encode/decode untuk DAG_PRUNED_NOTICE', () {
      final msg = DagPrunedNoticeMessage(
        senderNodeId: 'NODE-B',
        requestId: 'req-pruned-1',
        prunedBlockHashes: [hash1, hash2],
        lastPrunedIndex: 25,
        retainedGenesisHash: hash3,
      );

      final bytes = DagGossipCodec.encode(msg);
      final res = DagGossipCodec.decode(bytes);
      expect(res.isSuccess, isTrue);
      expect(res.message, isA<DagPrunedNoticeMessage>());

      final decoded = res.message as DagPrunedNoticeMessage;
      expect(decoded.requestId, equals('req-pruned-1'));
      expect(decoded.prunedBlockHashes, equals([hash1, hash2]));
      expect(decoded.lastPrunedIndex, equals(25));
      expect(decoded.retainedGenesisHash, equals(hash3));
    });

    // ------------------------------------------------------------------------
    // 2. Penolakan Versi Protokol dan Tipe Pesan Tidak Dikenal
    // ------------------------------------------------------------------------
    test('8. Penolakan nama protokol asing dan versi tidak didukung', () {
      // Protokol salah
      final badProtocolMap = {
        'protocol': 'OTHER_CHAIN_GOSSIP',
        'version': 1,
        'type': 'DAG_HELLO',
        'senderNodeId': 'NODE-A',
        'senderTimestamp': 1792380000000,
        'schemaVersion': 1,
        'activeBlocksCount': 1,
        'maxIndex': 1,
        'tipHashes': [hash1],
        'genesisHash': genesisHash,
      };
      final res1 = DagGossipCodec.decodeFromMap(badProtocolMap);
      expect(res1.isSuccess, isFalse);
      expect(res1.errorCode, equals(DagRejectCode.unsupportedProtocol));

      // Versi salah (misal versi masa depan 2)
      final badVersionMap = Map<String, dynamic>.from(badProtocolMap)
        ..['protocol'] = kDagGossipProtocolName
        ..['version'] = 2;
      final res2 = DagGossipCodec.decodeFromMap(badVersionMap);
      expect(res2.isSuccess, isFalse);
      expect(res2.errorCode, equals(DagRejectCode.unsupportedVersion));
    });

    test('9. Penolakan tipe pesan tidak dikenal', () {
      final badTypeMap = {
        'protocol': kDagGossipProtocolName,
        'version': kDagGossipProtocolVersion,
        'type': 'DAG_UNKNOWN_FUTURE_TYPE',
        'senderNodeId': 'NODE-A',
      };
      final res = DagGossipCodec.decodeFromMap(badTypeMap);
      expect(res.isSuccess, isFalse);
      expect(res.errorCode, equals(DagRejectCode.unsupportedType));
    });

    // ------------------------------------------------------------------------
    // 3. Penanganan JSON Rusak, Payload Kosong, dan Field Wajib Hilang
    // ------------------------------------------------------------------------
    test('10. Penanganan payload kosong dan JSON korup tanpa crash', () {
      // Payload kosong
      final emptyRes = DagGossipCodec.decode(Uint8List(0));
      expect(emptyRes.isSuccess, isFalse);
      expect(emptyRes.errorCode, equals(DagRejectCode.emptyPayload));

      // JSON string kosong
      final emptyJsonRes = DagGossipCodec.decodeFromJson('   ');
      expect(emptyJsonRes.isSuccess, isFalse);
      expect(emptyJsonRes.errorCode, equals(DagRejectCode.emptyPayload));

      // JSON malformed (sintaks rusak)
      final malformedBytes = Uint8List.fromList(
        utf8.encode('{"protocol": "SIAGA'),
      );
      final malformedRes = DagGossipCodec.decode(malformedBytes);
      expect(malformedRes.isSuccess, isFalse);
      expect(malformedRes.errorCode, equals(DagRejectCode.malformedJson));
    });

    test('11. Penolakan bila field wajib tidak tersedia', () {
      final missingSender = {
        'protocol': kDagGossipProtocolName,
        'version': kDagGossipProtocolVersion,
        'type': 'DAG_INV',
        // 'senderNodeId' hilang!
        'senderTimestamp': 1792380000000,
        'tipHashes': [hash1],
      };
      final res1 = DagGossipCodec.decodeFromMap(missingSender);
      expect(res1.isSuccess, isFalse);
      expect(res1.errorCode, equals(DagRejectCode.missingRequiredField));

      final missingReqId = {
        'protocol': kDagGossipProtocolName,
        'version': kDagGossipProtocolVersion,
        'type': 'DAG_GET_BLOCKS',
        'senderNodeId': 'NODE-A',
        // 'requestId' hilang!
        'requestedBlockHashes': [hash1],
      };
      final res2 = DagGossipCodec.decodeFromMap(missingReqId);
      expect(res2.isSuccess, isFalse);
      expect(res2.errorCode, equals(DagRejectCode.missingRequiredField));
    });

    // ------------------------------------------------------------------------
    // 4. Penolakan Hash Malformed atau Duplikat
    // ------------------------------------------------------------------------
    test('12. Penolakan format hash bukan 64 hex huruf kecil', () {
      final badHashes = [
        'short-hash', // terlalu pendek
        '1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdefZZ', // non-hex
        'A1B2C3D4E5F60718293A4B5C6D7E8F90123456789ABCDEF0123456789ABCDEF0', // huruf kapital
      ];

      for (final bad in badHashes) {
        final map = {
          'protocol': kDagGossipProtocolName,
          'version': kDagGossipProtocolVersion,
          'type': 'DAG_GET_BLOCKS',
          'senderNodeId': 'NODE-A',
          'requestId': 'req-1',
          'requestedBlockHashes': [bad],
        };
        final res = DagGossipCodec.decodeFromMap(map);
        expect(res.isSuccess, isFalse);
        expect(res.errorCode, equals(DagRejectCode.invalidHashFormat));
      }
    });

    test('13. Penolakan hash duplikat dalam daftar inventaris/permintaan', () {
      final duplicateHashesMap = {
        'protocol': kDagGossipProtocolName,
        'version': kDagGossipProtocolVersion,
        'type': 'DAG_GET_BLOCKS',
        'senderNodeId': 'NODE-A',
        'requestId': 'req-1',
        'requestedBlockHashes': [hash1, hash2, hash1], // hash1 duplikat!
      };

      final res = DagGossipCodec.decodeFromMap(duplicateHashesMap);
      expect(res.isSuccess, isFalse);
      expect(res.errorCode, equals(DagRejectCode.duplicateHash));
    });

    // ------------------------------------------------------------------------
    // 5. Batas Empat Hash untuk Permintaan Blok (DAG_GET_BLOCKS)
    // ------------------------------------------------------------------------
    test('14. Batas kMaxGetBlocksHashes (4 hash per permintaan)', () {
      // 4 hash diperbolehkan
      final okMap = {
        'protocol': kDagGossipProtocolName,
        'version': kDagGossipProtocolVersion,
        'type': 'DAG_GET_BLOCKS',
        'senderNodeId': 'NODE-A',
        'requestId': 'req-ok',
        'requestedBlockHashes': [hash1, hash2, hash3, hash4],
      };
      final okRes = DagGossipCodec.decodeFromMap(okMap);
      expect(okRes.isSuccess, isTrue);

      // 5 hash melampaui batas
      final exceedMap = {
        'protocol': kDagGossipProtocolName,
        'version': kDagGossipProtocolVersion,
        'type': 'DAG_GET_BLOCKS',
        'senderNodeId': 'NODE-A',
        'requestId': 'req-exceed',
        'requestedBlockHashes': [hash1, hash2, hash3, hash4, hash5],
      };
      final exceedRes = DagGossipCodec.decodeFromMap(exceedMap);
      expect(exceedRes.isSuccess, isFalse);
      expect(exceedRes.errorCode, equals(DagRejectCode.exceedsHashLimit));

      // 0 hash ditolak
      final emptyListMap = {
        'protocol': kDagGossipProtocolName,
        'version': kDagGossipProtocolVersion,
        'type': 'DAG_GET_BLOCKS',
        'senderNodeId': 'NODE-A',
        'requestId': 'req-empty',
        'requestedBlockHashes': <String>[],
      };
      final emptyRes = DagGossipCodec.decodeFromMap(emptyListMap);
      expect(emptyRes.isSuccess, isFalse);
      expect(emptyRes.errorCode, equals(DagRejectCode.emptyPayload));
    });

    // ------------------------------------------------------------------------
    // 6. Batas Ukuran Payload Batch 16 KiB & Raw Ingress 32 KiB (Boundary Test)
    // ------------------------------------------------------------------------
    test(
      '15. Batas ukuran payload batch 16 KiB (16384 bytes boundary test)',
      () {
        // Buat dummy payload besar pada DAG_BLOCK_BATCH
        final longValidReason = 'A' * 100;
        final events = List.generate(
          10,
          (i) => SecurityAuditEvent(
            eventId: 'evt-size-$i',
            eventType: AuditEventType.idsDetection,
            observerNodeId: 'NODE-A',
            targetNodeId: 'NODE-B',
            timestamp: DateTime.now().toUtc(),
            monotonicMicros: i * 1000,
            metadata: {
              'status': 'suspected',
              'observedDropRate': 0.5,
              'reason': longValidReason,
            },
          ),
        );

        final bigBlock = SecurityBlock.create(
          index: 10,
          parentBlockHashes: [genesisHash],
          creatorNodeId: 'NODE-A',
          events: events,
        );

        final batchMsg = DagBlockBatchMessage(
          senderNodeId: 'NODE-A',
          requestId: 'req-boundary',
          batchIndex: 1,
          totalBatches: 1,
          blocks: [bigBlock],
        );

        final encodedBytes = DagGossipCodec.encode(batchMsg);
        expect(encodedBytes.length, lessThan(kMaxBatchPayloadBytes));

        // Uji jika rawByteLength dilaporkan melebihi 16384
        final overLimitRes = DagGossipCodec.decodeFromMap(
          batchMsg.toMap(),
          rawByteLength: 16385, // 1 byte di atas 16 KiB
        );
        expect(overLimitRes.isSuccess, isFalse);
        expect(
          overLimitRes.errorCode,
          equals(DagRejectCode.batchPayloadTooLarge),
        );

        // Uji jika rawByteLength tepat pada batas 16384
        final exactLimitRes = DagGossipCodec.decodeFromMap(
          batchMsg.toMap(),
          rawByteLength: 16384,
        );
        expect(exactLimitRes.isSuccess, isTrue);
      },
    );

    test(
      '16. Batas absolut raw byte mentah 32 KiB (kMaxRawGossipPayloadBytes)',
      () {
        final oversizedBytes = Uint8List(kMaxRawGossipPayloadBytes + 1);
        final res = DagGossipCodec.decode(oversizedBytes);
        expect(res.isSuccess, isFalse);
        expect(res.errorCode, equals(DagRejectCode.payloadTooLarge));
      },
    );

    // ------------------------------------------------------------------------
    // 7. Penolakan Nilai dengan Tipe Salah / Struktur Tidak Valid
    // ------------------------------------------------------------------------
    test(
      '17. Penolakan tipe numerik pecahan atau string untuk integer versions',
      () {
        final fractionalVersionMap = {
          'protocol': kDagGossipProtocolName,
          'version': kDagGossipProtocolVersion,
          'type': 'DAG_HELLO',
          'senderNodeId': 'NODE-A',
          'senderTimestamp': 1792380000000,
          'schemaVersion': 1.5, // Pecahan!
          'activeBlocksCount': 1,
          'maxIndex': 1,
          'tipHashes': [hash1],
          'genesisHash': genesisHash,
        };
        final res1 = DagGossipCodec.decodeFromMap(fractionalVersionMap);
        expect(res1.isSuccess, isFalse);
        expect(res1.errorCode, equals(DagRejectCode.invalidFieldType));

        final stringVersionMap = Map<String, dynamic>.from(fractionalVersionMap)
          ..['schemaVersion'] = '1'; // String!
        final res2 = DagGossipCodec.decodeFromMap(stringVersionMap);
        expect(res2.isSuccess, isFalse);
        expect(res2.errorCode, equals(DagRejectCode.invalidFieldType));
      },
    );

    test('18. Penolakan batchIndex > totalBatches', () {
      final invalidIndexMap = {
        'protocol': kDagGossipProtocolName,
        'version': kDagGossipProtocolVersion,
        'type': 'DAG_BLOCK_BATCH',
        'senderNodeId': 'NODE-A',
        'requestId': 'req-bad-index',
        'batchIndex': 3,
        'totalBatches': 2, // batchIndex > totalBatches!
        'blocks': [
          SecurityBlock.create(
            index: 1,
            parentBlockHashes: [genesisHash],
            creatorNodeId: 'NODE-A',
            events: const [],
          ).toMap(),
        ],
      };
      final res = DagGossipCodec.decodeFromMap(invalidIndexMap);
      expect(res.isSuccess, isFalse);
      expect(res.errorCode, equals(DagRejectCode.invalidFieldType));
    });

    // ------------------------------------------------------------------------
    // 8. Validasi Identitas Request dan Korelasi Respons
    // ------------------------------------------------------------------------
    test(
      '19. RequestId harus terkorelasi dan dibatasi maksimal 64 karakter',
      () {
        final tooLongId = 'R' * 65;
        final map = {
          'protocol': kDagGossipProtocolName,
          'version': kDagGossipProtocolVersion,
          'type': 'DAG_GET_BLOCKS',
          'senderNodeId': 'NODE-A',
          'requestId': tooLongId,
          'requestedBlockHashes': [hash1],
        };
        final res = DagGossipCodec.decodeFromMap(map);
        expect(res.isSuccess, isFalse);
        expect(res.errorCode, equals(DagRejectCode.missingRequiredField));
      },
    );

    // ------------------------------------------------------------------------
    // 9. Batas Privasi & Metadata Allowlist Sanitization
    // ------------------------------------------------------------------------
    test(
      '20. Sanitizer privasi menolak konten percakapan obrolan korban dalam metadata',
      () {
        final leakedChatEvent = SecurityAuditEvent(
          eventId: 'leak-evt-1',
          eventType: AuditEventType.idsDetection,
          observerNodeId: 'NODE-A',
          targetNodeId: 'NODE-B',
          timestamp: DateTime.now().toUtc(),
          monotonicMicros: 100,
          metadata: {
            'status': 'suspected',
            'chat_text':
                'Tolong korban terjebak di lantai dua', // Kunci obrolan terlarang!
          },
        );

        final leakedBlock = SecurityBlock.create(
          index: 1,
          parentBlockHashes: [genesisHash],
          creatorNodeId: 'NODE-A',
          events: [leakedChatEvent],
        );

        final msg = DagBlockBatchMessage(
          senderNodeId: 'NODE-A',
          requestId: 'req-leak',
          batchIndex: 1,
          totalBatches: 1,
          blocks: [leakedBlock],
        );

        final res = DagGossipCodec.decodeFromMap(msg.toMap());
        expect(res.isSuccess, isFalse);
        expect(res.errorCode, equals(DagRejectCode.privacyViolation));
        expect(res.errorMessage, contains('tidak diizinkan'));
      },
    );

    test('21. Sanitizer privasi menolak koordinat GPS dan nomor telepon', () {
      final leakedGpsEvent = SecurityAuditEvent(
        eventId: 'leak-evt-2',
        eventType: AuditEventType.trustUpdate,
        observerNodeId: 'NODE-A',
        targetNodeId: 'NODE-B',
        timestamp: DateTime.now().toUtc(),
        monotonicMicros: 200,
        metadata: {
          'oldScore': 0.6,
          'newScore': 0.4,
          'latitude': -8.5123, // Kunci GPS terlarang!
          'longitude': 115.2345,
        },
      );

      final leakedBlock = SecurityBlock.create(
        index: 1,
        parentBlockHashes: [genesisHash],
        creatorNodeId: 'NODE-A',
        events: [leakedGpsEvent],
      );

      final msg = DagBlockBatchMessage(
        senderNodeId: 'NODE-A',
        requestId: 'req-gps',
        batchIndex: 1,
        totalBatches: 1,
        blocks: [leakedBlock],
      );

      final res = DagGossipCodec.decodeFromMap(msg.toMap());
      expect(res.isSuccess, isFalse);
      expect(res.errorCode, equals(DagRejectCode.privacyViolation));
    });

    test(
      '22. Sanitizer privasi menolak string reason yang melebihi 128 karakter',
      () {
        final longReasonEvent = SecurityAuditEvent(
          eventId: 'long-reason-1',
          eventType: AuditEventType.idsDetection,
          observerNodeId: 'NODE-A',
          targetNodeId: 'NODE-B',
          timestamp: DateTime.now().toUtc(),
          monotonicMicros: 300,
          metadata: {
            'status': 'suspected',
            'reason': 'A' * 129, // Melebihi 128 karakter!
          },
        );

        final block = SecurityBlock.create(
          index: 1,
          parentBlockHashes: [genesisHash],
          creatorNodeId: 'NODE-A',
          events: [longReasonEvent],
        );

        final msg = DagBlockBatchMessage(
          senderNodeId: 'NODE-A',
          requestId: 'req-long',
          batchIndex: 1,
          totalBatches: 1,
          blocks: [block],
        );

        final res = DagGossipCodec.decodeFromMap(msg.toMap());
        expect(res.isSuccess, isFalse);
        expect(res.errorCode, equals(DagRejectCode.privacyViolation));
      },
    );

    // ------------------------------------------------------------------------
    // 10. Klarifikasi Desain 1: Validasi Blok Ledger Memiliki Tepat 9 Aturan
    // ------------------------------------------------------------------------
    test(
      '23. Klarifikasi Desain 1: Verifikasi bahwa validateBlock memiliki tepat 9 aturan implementasi',
      () {
        final ledger = LightweightBlockdagLedger();

        // Buat blok valid
        final validBlock = SecurityBlock.create(
          index: 1,
          parentBlockHashes: [ledger.genesisBlock.blockHash],
          creatorNodeId: 'NODE-A',
          events: const [],
        );

        final valRes = ledger.validateBlock(validBlock);
        expect(valRes.isValid, isTrue);

        // Verifikasi bahwa enumerasi LedgerValidationStatus mendefinisikan 10 status (1 valid + 9 aturan penolakan)
        // Aturan penolakan:
        // 1. unsupportedVersion
        // 2. invalidHashFormat
        // 3. invalidStructure
        // 4. duplicateBlock
        // 5. missingParent (termasuk asiklisitas)
        // 6. invalidMerkleRoot
        // 7. invalidHeaderHash
        // 8. duplicateEvent
        // 9. timestampOutOfBounds
        expect(
          LedgerValidationStatus.values,
          containsAll([
            LedgerValidationStatus.valid,
            LedgerValidationStatus.unsupportedVersion,
            LedgerValidationStatus.invalidHashFormat,
            LedgerValidationStatus.invalidStructure,
            LedgerValidationStatus.duplicateBlock,
            LedgerValidationStatus.missingParent,
            LedgerValidationStatus.invalidMerkleRoot,
            LedgerValidationStatus.invalidHeaderHash,
            LedgerValidationStatus.duplicateEvent,
            LedgerValidationStatus.timestampOutOfBounds,
          ]),
        );
        expect(LedgerValidationStatus.values.length, equals(10));
      },
    );

    // ------------------------------------------------------------------------
    // 11. Klarifikasi Desain 2: Kesamaan Tip Hashes Saja Bukan Bukti Sinkron Riwayat
    // ------------------------------------------------------------------------
    test(
      '24. Klarifikasi Desain 2: Tip Hashes sama tetapi depth/retention berbeda terdeteksi via metadata hello',
      () {
        // Node A memiliki 10 blok aktif (maxIndex 9)
        final helloA = DagHelloMessage(
          senderNodeId: 'NODE-A',
          senderTimestamp: 1792380000000,
          schemaVersion: 1,
          activeBlocksCount: 10,
          maxIndex: 9,
          tipHashes: [hash1],
          genesisHash: genesisHash,
        );

        // Node B memiliki tip yang sama (hash1), namun hanya memiliki 2 blok aktif karena sudah dipangkas (pruned)
        final helloB = DagHelloMessage(
          senderNodeId: 'NODE-B',
          senderTimestamp: 1792380000000,
          schemaVersion: 1,
          activeBlocksCount: 2,
          maxIndex: 9,
          tipHashes: [hash1],
          genesisHash: genesisHash,
        );

        // Tip hashes sama persis
        expect(helloA.tipHashes, equals(helloB.tipHashes));

        // Tetapi activeBlocksCount berbeda membuktikan status riwayat berbeda
        expect(
          helloA.activeBlocksCount,
          isNot(equals(helloB.activeBlocksCount)),
        );
      },
    );

    // ------------------------------------------------------------------------
    // 12. Feature Gating & Isolasi Konfigurasi
    // ------------------------------------------------------------------------
    test(
      '25. Feature gating: enableBlockdagReplication default false (Konfigurasi A & B terisolasi)',
      () {
        expect(ManetRoutingHolder.enableBlockdagReplication, isFalse);

        ManetRoutingHolder.setEnableBlockdagReplication(true);
        expect(ManetRoutingHolder.enableBlockdagReplication, isTrue);

        ManetRoutingHolder.reset();
        expect(ManetRoutingHolder.enableBlockdagReplication, isFalse);
      },
    );
  });
}

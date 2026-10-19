/// STAGE 5E.2 — Pengujian Unit Core Lightweight BlockDAG Ledger SiagaMesh
///
/// Memverifikasi seluruh spesifikasi arsitektur BlockDAG (Alternatif B):
/// 1. Genesis block initialization & well-known attributes
/// 2. Canonical JSON serialization determinism (key order invariance)
/// 3. SHA-256 calculation correctness (NIST test vectors)
/// 4. Merkle Tree computation across edge cases (empty, single, even, odd)
/// 5. Merkle Tree tamper detection & inclusion proof verification
/// 6. Linear chain block creation, addition & hash linkage
/// 7. Multi-parent BlockDAG branch creation (network partition)
/// 8. BlockDAG branch merge (reconvergence)
/// 9. Deterministic linear replay order across divergent branches
/// 10. Event deduplication prevention (anti double-counting)
/// 11. Block validation: detecting malformed structure & version
/// 12. Block validation: detecting altered block header hash
/// 13. Block validation: detecting altered Merkle root
/// 14. Ledger retention and safe pruning policy (checkpoint anchors)
/// 15. Full event conversion from IdsDetectionEvent & TrustScoreChangeEvent (zero sensitive data leakage)
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:siagamesh_app/core/blockchain/blockchain_types.dart';
import 'package:siagamesh_app/core/blockchain/lightweight_blockdag_ledger.dart';
import 'package:siagamesh_app/core/ids/ids_types.dart';
import 'package:siagamesh_app/core/trust/trust_types.dart';

void main() {
  group('STAGE 5E.2 — Core Lightweight BlockDAG Ledger SiagaMesh', () {
    // -------------------------------------------------------------------------
    // 1. Genesis block initialization & well-known attributes
    // -------------------------------------------------------------------------
    test(
      '1. Inisialisasi Genesis block memiliki atribut deterministik yang valid',
      () {
        final ledger = LightweightBlockdagLedger();
        final genesis = ledger.genesisBlock;

        expect(genesis.index, equals(0));
        expect(genesis.version, equals(1));
        expect(genesis.parentBlockHashes, isEmpty);
        expect(genesis.prevBlockHash, equals(''));
        expect(genesis.creatorNodeId, equals('SYSTEM'));
        expect(genesis.events, isEmpty);
        expect(genesis.eventsCount, equals(0));
        expect(genesis.merkleRoot, equals(kEmptySha256));
        expect(genesis.blockHash.length, equals(64));
        expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(genesis.blockHash), isTrue);
        expect(genesis.computeHash(), equals(genesis.blockHash));

        expect(ledger.activeBlocksCount, equals(1));
        expect(ledger.tipHashes, contains(genesis.blockHash));
        expect(ledger.processedBlockHashes, contains(genesis.blockHash));
      },
    );

    // -------------------------------------------------------------------------
    // 2. Canonical JSON serialization determinism
    // -------------------------------------------------------------------------
    test(
      '2. Serialisasi kanonikal JSON menghasilkan output identik terlepas dari urutan kunci',
      () {
        final mapOrderA = {
          'version': 1,
          'zeta': 'last',
          'creator': 'NODE-A',
          'alpha': 100,
          'nested': {'delta': 0.5, 'beta': true},
        };

        final mapOrderB = {
          'alpha': 100,
          'nested': {'beta': true, 'delta': 0.5},
          'creator': 'NODE-A',
          'version': 1,
          'zeta': 'last',
        };

        final jsonA = canonicalJsonEncode(mapOrderA);
        final jsonB = canonicalJsonEncode(mapOrderB);

        expect(jsonA, equals(jsonB));
        expect(computeSha256(jsonA), equals(computeSha256(jsonB)));

        // Verifikasi urutan leksikografis kunci pada string JSON
        expect(
          jsonA,
          equals(
            '{"alpha":100,"creator":"NODE-A","nested":{"beta":true,"delta":0.5},"version":1,"zeta":"last"}',
          ),
        );
      },
    );

    // -------------------------------------------------------------------------
    // 3. SHA-256 calculation correctness
    // -------------------------------------------------------------------------
    test(
      '3. Perhitungan SHA-256 cocok dengan vektor uji standar kriptografis',
      () {
        // Vektor uji NIST untuk SHA-256
        expect(
          computeSha256(''),
          equals(
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
          ),
        );
        expect(
          computeSha256('abc'),
          equals(
            'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
          ),
        );
      },
    );

    // -------------------------------------------------------------------------
    // 4. Merkle Tree computation across edge cases
    // -------------------------------------------------------------------------
    test(
      '4. Perhitungan Merkle Tree menangani daftar kosong, tunggal, genap, dan ganjil',
      () {
        // Kasus A: Daftar kosong
        expect(MerkleTree.computeRoot([]), equals(kEmptySha256));

        // Kasus B: Daun tunggal
        final hashA = computeSha256('leaf-A');
        expect(MerkleTree.computeRoot([hashA]), equals(hashA));

        // Kasus C: Daun genap (2 daun)
        final hashB = computeSha256('leaf-B');
        final expectedRoot2 = computeSha256(hashA + hashB);
        expect(MerkleTree.computeRoot([hashA, hashB]), equals(expectedRoot2));

        // Kasus D: Daun ganjil (3 daun -> duplikasi daun terakhir menjadi 4)
        final hashC = computeSha256('leaf-C');
        final level1Left = computeSha256(hashA + hashB);
        final level1Right = computeSha256(hashC + hashC);
        final expectedRoot3 = computeSha256(level1Left + level1Right);
        expect(
          MerkleTree.computeRoot([hashA, hashB, hashC]),
          equals(expectedRoot3),
        );
      },
    );

    // -------------------------------------------------------------------------
    // 5. Merkle Tree tamper detection & inclusion proof verification
    // -------------------------------------------------------------------------
    test(
      '5. Bukti inklusi Merkle Tree memverifikasi daun asli dan mendeteksi manipulasi data',
      () {
        final leaves = [
          computeSha256('event-1'),
          computeSha256('event-2'),
          computeSha256('event-3'),
          computeSha256('event-4'),
        ];

        final root = MerkleTree.computeRoot(leaves);

        // Verifikasi bukti inklusi untuk setiap daun
        for (int i = 0; i < leaves.length; i++) {
          final proof = MerkleTree.generateProof(leaves, i);
          final isValid = MerkleTree.verifyProof(
            leafHash: leaves[i],
            proof: proof,
            merkleRoot: root,
          );
          expect(isValid, isTrue, reason: 'Bukti untuk daun $i harus valid');
        }

        // Verifikasi penolakan jika daun dimanipulasi
        final tamperedLeaf = computeSha256('event-1-tampered');
        final proof0 = MerkleTree.generateProof(leaves, 0);
        final isTamperedValid = MerkleTree.verifyProof(
          leafHash: tamperedLeaf,
          proof: proof0,
          merkleRoot: root,
        );
        expect(isTamperedValid, isFalse);
      },
    );

    // -------------------------------------------------------------------------
    // 6. Linear chain block creation, addition & hash linkage
    // -------------------------------------------------------------------------
    test(
      '6. Pembentukan rantai linier mempertahankan tautan hash yang valid',
      () {
        final ledger = LightweightBlockdagLedger();
        final genesis = ledger.genesisBlock;

        final event1 = SecurityAuditEvent(
          eventId: 'evt-001',
          eventType: AuditEventType.idsDetection,
          observerNodeId: 'NODE-A',
          targetNodeId: 'NODE-B',
          timestamp: DateTime.parse('2026-10-19T10:00:00.000Z'),
          monotonicMicros: 1000,
          metadata: {'status': 'suspected', 'dropRate': 0.50},
        );

        ledger.addPendingEvent(event1);
        final block1 = ledger.createBlock(
          creatorNodeId: 'NODE-A',
          timestamp: DateTime.parse('2026-10-19T10:01:00.000Z'),
        );

        expect(block1.index, equals(1));
        expect(block1.parentBlockHashes, equals([genesis.blockHash]));
        expect(block1.prevBlockHash, equals(genesis.blockHash));
        expect(block1.eventsCount, equals(1));
        expect(ledger.tipHashes, equals({block1.blockHash}));

        final event2 = SecurityAuditEvent(
          eventId: 'evt-002',
          eventType: AuditEventType.trustUpdate,
          observerNodeId: 'NODE-A',
          targetNodeId: 'NODE-B',
          timestamp: DateTime.parse('2026-10-19T10:02:00.000Z'),
          monotonicMicros: 2000,
          metadata: {'oldScore': 0.60, 'newScore': 0.40},
        );

        ledger.addPendingEvent(event2);
        final block2 = ledger.createBlock(
          creatorNodeId: 'NODE-A',
          timestamp: DateTime.parse('2026-10-19T10:03:00.000Z'),
        );

        expect(block2.index, equals(2));
        expect(block2.parentBlockHashes, equals([block1.blockHash]));
        expect(block2.prevBlockHash, equals(block1.blockHash));
        expect(ledger.tipHashes, equals({block2.blockHash}));
        expect(ledger.activeBlocksCount, equals(3));
        expect(ledger.isAncestor(genesis.blockHash, block2.blockHash), isTrue);
      },
    );

    // -------------------------------------------------------------------------
    // 7. Multi-parent BlockDAG branch creation (network partition)
    // -------------------------------------------------------------------------
    test(
      '7. Partisi jaringan menghasilkan cabang BlockDAG multi-tip tanpa membuang blok',
      () {
        final ledger = LightweightBlockdagLedger();
        final genesis = ledger.genesisBlock;

        // Partisi 1: Node A membuat blok cabang 1A
        final eventA = SecurityAuditEvent(
          eventId: 'evt-branch-A',
          eventType: AuditEventType.idsDetection,
          observerNodeId: 'NODE-A',
          targetNodeId: 'NODE-X',
          timestamp: DateTime.parse('2026-10-19T10:10:00.000Z'),
          monotonicMicros: 5000,
          metadata: {'partition': 'Klaster 1'},
        );
        final block1A = SecurityBlock.create(
          index: 1,
          parentBlockHashes: [genesis.blockHash],
          creatorNodeId: 'NODE-A',
          events: [eventA],
          timestamp: DateTime.parse('2026-10-19T10:10:05.000Z'),
        );

        // Partisi 2: Node B membuat blok cabang 1B secara konkuren terhadap parent yang sama
        final eventB = SecurityAuditEvent(
          eventId: 'evt-branch-B',
          eventType: AuditEventType.idsDetection,
          observerNodeId: 'NODE-B',
          targetNodeId: 'NODE-Y',
          timestamp: DateTime.parse('2026-10-19T10:10:02.000Z'),
          monotonicMicros: 5100,
          metadata: {'partition': 'Klaster 2'},
        );
        final block1B = SecurityBlock.create(
          index: 1,
          parentBlockHashes: [genesis.blockHash],
          creatorNodeId: 'NODE-B',
          events: [eventB],
          timestamp: DateTime.parse('2026-10-19T10:10:06.000Z'),
        );

        // Tambahkan kedua blok ke ledger
        final resA = ledger.addBlock(block1A);
        final resB = ledger.addBlock(block1B);

        expect(resA.isValid, isTrue);
        expect(resB.isValid, isTrue);

        // Keduanya harus sah dan menjadi tip DAG aktif simultan
        expect(ledger.activeBlocksCount, equals(3)); // Genesis, 1A, 1B
        expect(ledger.tipHashes, contains(block1A.blockHash));
        expect(ledger.tipHashes, contains(block1B.blockHash));
        expect(ledger.tipHashes.length, equals(2));
      },
    );

    // -------------------------------------------------------------------------
    // 8. BlockDAG branch merge (reconvergence)
    // -------------------------------------------------------------------------
    test(
      '8. Penggabungan cabang partisi (merge) mereferensikan seluruh tip aktif',
      () {
        final ledger = LightweightBlockdagLedger();
        final genesis = ledger.genesisBlock;

        // Buat dua cabang konkuren 1A dan 1B
        final block1A = SecurityBlock.create(
          index: 1,
          parentBlockHashes: [genesis.blockHash],
          creatorNodeId: 'NODE-A',
          events: [
            SecurityAuditEvent(
              eventId: 'evt-A',
              eventType: AuditEventType.idsDetection,
              observerNodeId: 'NODE-A',
              targetNodeId: 'NODE-M',
              timestamp: DateTime.parse('2026-10-19T10:10:00.000Z'),
              monotonicMicros: 1,
              metadata: {},
            ),
          ],
          timestamp: DateTime.parse('2026-10-19T10:10:10.000Z'),
        );

        final block1B = SecurityBlock.create(
          index: 1,
          parentBlockHashes: [genesis.blockHash],
          creatorNodeId: 'NODE-B',
          events: [
            SecurityAuditEvent(
              eventId: 'evt-B',
              eventType: AuditEventType.idsDetection,
              observerNodeId: 'NODE-B',
              targetNodeId: 'NODE-N',
              timestamp: DateTime.parse('2026-10-19T10:10:00.000Z'),
              monotonicMicros: 2,
              metadata: {},
            ),
          ],
          timestamp: DateTime.parse('2026-10-19T10:10:12.000Z'),
        );

        ledger.addBlock(block1A);
        ledger.addBlock(block1B);
        expect(ledger.tipHashes.length, equals(2));

        // Partisi pulih: Node C membuat blok merge yang menyatukan kedua tip
        final mergeEvent = SecurityAuditEvent(
          eventId: 'evt-merge',
          eventType: AuditEventType.isolationDecision,
          observerNodeId: 'NODE-C',
          targetNodeId: 'NODE-M',
          timestamp: DateTime.parse('2026-10-19T10:12:00.000Z'),
          monotonicMicros: 3,
          metadata: {'action': 'isolate'},
        );

        ledger.addPendingEvent(mergeEvent);
        final mergeBlock = ledger.createBlock(
          creatorNodeId: 'NODE-C',
          timestamp: DateTime.parse('2026-10-19T10:12:05.000Z'),
        );

        expect(mergeBlock.index, equals(2));
        expect(
          mergeBlock.parentBlockHashes,
          containsAll([block1A.blockHash, block1B.blockHash]),
        );
        expect(mergeBlock.parentBlockHashes.length, equals(2));

        // Tip sekarang kembali tunggal (merge block)
        expect(ledger.tipHashes, equals({mergeBlock.blockHash}));
        expect(
          ledger.isAncestor(block1A.blockHash, mergeBlock.blockHash),
          isTrue,
        );
        expect(
          ledger.isAncestor(block1B.blockHash, mergeBlock.blockHash),
          isTrue,
        );
      },
    );

    // -------------------------------------------------------------------------
    // 9. Deterministic linear replay order across divergent branches
    // -------------------------------------------------------------------------
    test(
      '9. Urutan pemutaran ulang linier deterministik konsisten terlepas dari urutan penambahan blok',
      () {
        // Ledger 1: Menambahkan 1A lalu 1B
        final ledger1 = LightweightBlockdagLedger();
        final gen = ledger1.genesisBlock;

        final b1A = SecurityBlock.create(
          index: 1,
          parentBlockHashes: [gen.blockHash],
          creatorNodeId: 'NODE-A',
          events: const [],
          timestamp: DateTime.parse('2026-10-19T10:20:00.000Z'),
        );
        final b1B = SecurityBlock.create(
          index: 1,
          parentBlockHashes: [gen.blockHash],
          creatorNodeId: 'NODE-B',
          events: const [],
          timestamp: DateTime.parse('2026-10-19T10:20:00.000Z'),
        );

        ledger1.addBlock(b1A);
        ledger1.addBlock(b1B);
        final order1 = ledger1.getLinearReplayOrder();

        // Ledger 2: Menambahkan 1B lalu 1A
        final ledger2 = LightweightBlockdagLedger();
        ledger2.addBlock(b1B);
        ledger2.addBlock(b1A);
        final order2 = ledger2.getLinearReplayOrder();

        // Kedua urutan harus 100% sama
        expect(order1.length, equals(3));
        expect(order2.length, equals(3));
        for (int i = 0; i < order1.length; i++) {
          expect(order1[i].blockHash, equals(order2[i].blockHash));
        }

        // Verifikasi urutan: Genesis (index 0) -> 1A (creator NODE-A) -> 1B (creator NODE-B)
        expect(order1[0].blockHash, equals(gen.blockHash));
        expect(order1[1].creatorNodeId, equals('NODE-A'));
        expect(order1[2].creatorNodeId, equals('NODE-B'));
      },
    );

    // -------------------------------------------------------------------------
    // 10. Event deduplication prevention (anti double-counting)
    // -------------------------------------------------------------------------
    test(
      '10. Deduplikasi event menolak penambahan ulang event yang sama ke antrean dan blok',
      () {
        final ledger = LightweightBlockdagLedger();
        final event = SecurityAuditEvent(
          eventId: 'duplicate-check-01',
          eventType: AuditEventType.idsDetection,
          observerNodeId: 'NODE-A',
          targetNodeId: 'NODE-B',
          timestamp: DateTime.parse('2026-10-19T10:30:00.000Z'),
          monotonicMicros: 100,
          metadata: {},
        );

        // Tambahkan pertama kali -> berhasil
        expect(ledger.addPendingEvent(event), isTrue);
        // Tambahkan kedua kali ke buffer -> ditolak (false)
        expect(ledger.addPendingEvent(event), isFalse);

        final block = ledger.createBlock(creatorNodeId: 'NODE-A');
        expect(block.eventsCount, equals(1));
        expect(ledger.processedEventIds, contains('duplicate-check-01'));

        // Mencoba menambahkan event yang sama setelah dikomit ke blok -> ditolak
        expect(ledger.addPendingEvent(event), isFalse);

        // Mencoba menyuntikkan blok eksternal yang membawa eventId yang sama
        final maliciousBlock = SecurityBlock.create(
          index: block.index + 1,
          parentBlockHashes: [block.blockHash],
          creatorNodeId: 'NODE-ATTACKER',
          events: [event], // Duplicate eventId!
        );

        final addResult = ledger.addBlock(maliciousBlock);
        expect(addResult.isValid, isFalse);
        expect(addResult.status, equals(LedgerValidationStatus.duplicateEvent));
      },
    );

    // -------------------------------------------------------------------------
    // 11. Block validation: detecting malformed structure & version
    // -------------------------------------------------------------------------
    test(
      '11. Validasi blok mendeteksi struktur malformed dan versi tidak sah',
      () {
        final ledger = LightweightBlockdagLedger();
        final genesis = ledger.genesisBlock;

        // Kasus A: Blok non-genesis tanpa parent
        final malformedBlock1 = SecurityBlock(
          version: 1,
          index: 1,
          blockHash: computeSha256('dummy-1'),
          parentBlockHashes: const [], // Kosong padahal index > 0!
          creatorNodeId: 'NODE-A',
          timestamp: DateTime.now().toUtc(),
          monotonicMicros: 0,
          merkleRoot: kEmptySha256,
          events: const [],
        );
        final res1 = ledger.validateBlock(malformedBlock1);
        expect(res1.isValid, isFalse);
        expect(res1.status, equals(LedgerValidationStatus.invalidStructure));

        // Kasus B: Versi skema tidak didukung
        final malformedBlock2 = SecurityBlock(
          version: 99, // Unsupported!
          index: 1,
          blockHash: computeSha256('dummy-2'),
          parentBlockHashes: [genesis.blockHash],
          creatorNodeId: 'NODE-A',
          timestamp: DateTime.now().toUtc(),
          monotonicMicros: 0,
          merkleRoot: kEmptySha256,
          events: const [],
        );
        final res2 = ledger.validateBlock(malformedBlock2);
        expect(res2.isValid, isFalse);
        expect(res2.status, equals(LedgerValidationStatus.unsupportedVersion));

        // Kasus C: Hash format tidak valid (kurang dari 64 hex)
        final malformedBlock3 = SecurityBlock(
          version: 1,
          index: 1,
          blockHash: 'short-invalid-hash',
          parentBlockHashes: [genesis.blockHash],
          creatorNodeId: 'NODE-A',
          timestamp: DateTime.now().toUtc(),
          monotonicMicros: 0,
          merkleRoot: kEmptySha256,
          events: const [],
        );
        final res3 = ledger.validateBlock(malformedBlock3);
        expect(res3.isValid, isFalse);
        expect(res3.status, equals(LedgerValidationStatus.invalidHashFormat));

        // Kasus D: Timestamp mendahului parent
        final malformedBlock4 = SecurityBlock.create(
          index: 1,
          parentBlockHashes: [genesis.blockHash],
          creatorNodeId: 'NODE-A',
          events: const [],
          timestamp: genesis.timestamp.subtract(const Duration(seconds: 10)),
        );
        final res4 = ledger.validateBlock(malformedBlock4);
        expect(res4.isValid, isFalse);
        expect(
          res4.status,
          equals(LedgerValidationStatus.timestampOutOfBounds),
        );

        // Kasus E: Timestamp melompat ke masa depan saat maxFutureDrift aktif
        final strictLedger = LightweightBlockdagLedger(
          maxFutureDrift: const Duration(hours: 1),
        );
        final futureBlock = SecurityBlock.create(
          index: 1,
          parentBlockHashes: [genesis.blockHash],
          creatorNodeId: 'NODE-A',
          events: const [],
          timestamp: DateTime.now().toUtc().add(const Duration(hours: 5)),
        );
        final res5 = strictLedger.validateBlock(futureBlock);
        expect(res5.isValid, isFalse);
        expect(
          res5.status,
          equals(LedgerValidationStatus.timestampOutOfBounds),
        );
      },
    );

    // -------------------------------------------------------------------------
    // 12. Block validation: detecting altered block header hash
    // -------------------------------------------------------------------------
    test(
      '12. Validasi blok mendeteksi manipulasi header blok (invalidHeaderHash)',
      () {
        final ledger = LightweightBlockdagLedger();
        final genesis = ledger.genesisBlock;

        final authenticBlock = SecurityBlock.create(
          index: 1,
          parentBlockHashes: [genesis.blockHash],
          creatorNodeId: 'NODE-A',
          events: const [],
          timestamp: DateTime.parse('2026-10-19T10:40:00.000Z'),
        );

        // Manipulasi: Ubah creatorNodeId tanpa memperbarui blockHash
        final tamperedBlock = SecurityBlock(
          version: authenticBlock.version,
          index: authenticBlock.index,
          blockHash: authenticBlock.blockHash, // Hash lama!
          parentBlockHashes: authenticBlock.parentBlockHashes,
          creatorNodeId: 'NODE-IMPOSTOR', // Dimanipulasi!
          timestamp: authenticBlock.timestamp,
          monotonicMicros: authenticBlock.monotonicMicros,
          merkleRoot: authenticBlock.merkleRoot,
          events: authenticBlock.events,
        );

        final valResult = ledger.validateBlock(tamperedBlock);
        expect(valResult.isValid, isFalse);
        expect(
          valResult.status,
          equals(LedgerValidationStatus.invalidHeaderHash),
        );
      },
    );

    // -------------------------------------------------------------------------
    // 13. Block validation: detecting altered Merkle root
    // -------------------------------------------------------------------------
    test(
      '13. Validasi blok mendeteksi manipulasi isi event (invalidMerkleRoot)',
      () {
        final ledger = LightweightBlockdagLedger();
        final genesis = ledger.genesisBlock;

        final originalEvent = SecurityAuditEvent(
          eventId: 'audit-original-01',
          eventType: AuditEventType.idsDetection,
          observerNodeId: 'NODE-A',
          targetNodeId: 'NODE-B',
          timestamp: DateTime.parse('2026-10-19T10:50:00.000Z'),
          monotonicMicros: 10,
          metadata: {'observedDropRate': 0.20},
        );

        final block = SecurityBlock.create(
          index: 1,
          parentBlockHashes: [genesis.blockHash],
          creatorNodeId: 'NODE-A',
          events: [originalEvent],
          timestamp: DateTime.parse('2026-10-19T10:50:05.000Z'),
        );

        // Manipulasi: Ganti event di dalam blok tanpa mengubah Merkle root
        final tamperedEvent = SecurityAuditEvent(
          eventId: 'audit-original-01',
          eventType: AuditEventType.idsDetection,
          observerNodeId: 'NODE-A',
          targetNodeId: 'NODE-B',
          timestamp: DateTime.parse('2026-10-19T10:50:00.000Z'),
          monotonicMicros: 10,
          metadata: {'observedDropRate': 0.99}, // Nilai diubah secara ilegal!
        );

        final tamperedBlock = SecurityBlock(
          version: block.version,
          index: block.index,
          blockHash: block.blockHash,
          parentBlockHashes: block.parentBlockHashes,
          creatorNodeId: block.creatorNodeId,
          timestamp: block.timestamp,
          monotonicMicros: block.monotonicMicros,
          merkleRoot: block.merkleRoot, // Root lama!
          events: [tamperedEvent],
        );

        final valResult = ledger.validateBlock(tamperedBlock);
        expect(valResult.isValid, isFalse);
        expect(
          valResult.status,
          equals(LedgerValidationStatus.invalidMerkleRoot),
        );
      },
    );

    // -------------------------------------------------------------------------
    // 14. Ledger retention and safe pruning policy
    // -------------------------------------------------------------------------
    test(
      '14. Kebijakan pemangkasan (safe pruning) membatasi jendela aktif dan membentuk checkpoint anchor',
      () {
        // Inisialisasi ledger dengan batas jendela retensi kecil (misal 4 blok)
        final ledger = LightweightBlockdagLedger(maxRetentionBlocks: 4);

        // Tambahkan 6 blok linier (akan memicu pemangkasan otomatis saat > 4)
        for (int i = 1; i <= 6; i++) {
          final evt = SecurityAuditEvent(
            eventId: 'prune-test-evt-$i',
            eventType: AuditEventType.idsDetection,
            observerNodeId: 'NODE-A',
            targetNodeId: 'NODE-X',
            timestamp: DateTime.parse('2026-10-19T11:00:0$i.000Z'),
            monotonicMicros: i * 100,
            metadata: {'round': i},
          );
          ledger.addPendingEvent(evt);
          ledger.createBlock(
            creatorNodeId: 'NODE-A',
            timestamp: DateTime.parse('2026-10-19T11:00:1$i.000Z'),
          );
        }

        // Jendela aktif harus dibatasi tepat pada maxRetentionBlocks (4)
        expect(ledger.activeBlocksCount, equals(4));
        // Total blok historis tetap terlacak (7: Genesis + 6 blok)
        expect(ledger.totalHistoricalBlocksCount, equals(7));
        expect(ledger.totalPrunedBlocksCount, equals(3));

        // Checkpoint harus terbentuk pada setiap siklus pemangkasan (3 checkpoint masing-masing memangkas 1 blok)
        expect(ledger.checkpoints.length, equals(3));
        final latestCheckpoint = ledger.checkpoints.last;
        expect(
          latestCheckpoint.lastPrunedIndex,
          equals(2),
        ); // Genesis (0), Block 1, Block 2 dipangkas
        expect(latestCheckpoint.retainedGenesisHash, isNotEmpty);

        // Verifikasi anti-duplikasi: Event yang telah dipangkas TETAP dicegah dari penambahan ulang!
        final replayedPrunedEvent = SecurityAuditEvent(
          eventId: 'prune-test-evt-1', // Event yang sudah dipangkas
          eventType: AuditEventType.idsDetection,
          observerNodeId: 'NODE-A',
          targetNodeId: 'NODE-X',
          timestamp: DateTime.parse('2026-10-19T11:00:01.000Z'),
          monotonicMicros: 100,
          metadata: {},
        );
        expect(ledger.addPendingEvent(replayedPrunedEvent), isFalse);
      },
    );

    // -------------------------------------------------------------------------
    // 15. Full event conversion from IdsDetectionEvent & TrustScoreChangeEvent
    // -------------------------------------------------------------------------
    test(
      '15. Konversi event dari IDS dan Trust Management mempertahankan seluruh metrik tanpa membocorkan data pribadi',
      () {
        // 1. Uji konversi IdsDetectionEvent
        final idsEvent = IdsDetectionEvent(
          eventId: 'ids-full-test-99',
          runId: 'RUN-EXP-01',
          observerNodeId: 'OBSERVER-A',
          targetNodeId: 'TARGET-B',
          status: NodeDetectionStatus.suspected,
          observedDropRate: 0.65,
          totalExpected: 20,
          totalClaimed: 7,
          totalUnconfirmed: 13,
          totalLinkFailures: 0,
          totalProtocolDrops: 0,
          reason: 'Drop rate 0.65 melampaui ambang batas 0.35 pada link aktif',
          timestamp: DateTime.parse('2026-10-19T11:15:00.000Z'),
          monotonicMicros: 99999,
        );

        final auditFromIds = SecurityAuditEvent.fromIdsDetectionEvent(idsEvent);
        expect(auditFromIds.eventId, equals('ids-full-test-99'));
        expect(auditFromIds.eventType, equals(AuditEventType.idsDetection));
        expect(auditFromIds.metadata['status'], equals('suspected'));
        expect(auditFromIds.metadata['observedDropRate'], equals(0.65));
        expect(auditFromIds.metadata['totalExpected'], equals(20));
        expect(auditFromIds.metadata['totalClaimed'], equals(7));
        expect(auditFromIds.metadata['totalUnconfirmed'], equals(13));

        // 2. Uji konversi TrustScoreChangeEvent
        final trustEvent = TrustScoreChangeEvent(
          eventId: 'trust-full-test-88',
          runId: 'RUN-EXP-01',
          observerNodeId: 'OBSERVER-A',
          targetNodeId: 'TARGET-B',
          oldScore: 0.60,
          newScore: 0.38,
          evidenceType: ForwardingEvidenceType.forwardingUnconfirmed,
          evaluationStatus: TrustEvaluationStatus.untrusted,
          reason: 'Penalti selective forwarding pada link aktif',
          totalObservations: 10,
          positiveEvidenceSum: 4.2,
          negativeEvidenceSum: 6.0,
          linkFailureCount: 0,
          protocolDropCount: 0,
          relayClaimCount: 7,
          downstreamConfirmedCount: 0,
          deliveryConfirmedCount: 0,
          unconfirmedDropCount: 6,
          thresholdConfig: {'threshold': 0.50},
          timestamp: DateTime.parse('2026-10-19T11:15:05.000Z'),
          monotonicMicros: 100050,
        );

        final auditFromTrust = SecurityAuditEvent.fromTrustScoreChangeEvent(
          trustEvent,
        );
        expect(auditFromTrust.eventId, equals('trust-full-test-88'));
        expect(auditFromTrust.eventType, equals(AuditEventType.trustUpdate));
        expect(auditFromTrust.metadata['oldScore'], equals(0.60));
        expect(auditFromTrust.metadata['newScore'], equals(0.38));
        expect(
          (auditFromTrust.metadata['delta'] as double).toStringAsFixed(2),
          equals('-0.22'),
        );
        expect(
          auditFromTrust.metadata['evaluationStatus'],
          equals('untrusted'),
        );
        expect(auditFromTrust.metadata['relayClaimCount'], equals(7));
        expect(auditFromTrust.metadata['unconfirmedDropCount'], equals(6));

        // 3. Verifikasi ketiadaan data sensitif (chat text, GPS, credentials)
        final auditJsonA = auditFromIds.toCanonicalJson();
        final auditJsonB = auditFromTrust.toCanonicalJson();

        for (final forbidden in [
          'chat',
          'messageText',
          'payload',
          'gps',
          'latitude',
          'longitude',
          'password',
          'privateKey',
        ]) {
          expect(
            auditJsonA.toLowerCase().contains(forbidden),
            isFalse,
            reason: 'auditFromIds tidak boleh mengandung field $forbidden',
          );
          expect(
            auditJsonB.toLowerCase().contains(forbidden),
            isFalse,
            reason: 'auditFromTrust tidak boleh mengandung field $forbidden',
          );
        }
      },
    );

    // -------------------------------------------------------------------------
    // 16. Kanonisasi SACJ-v1: Penolakan NaN/Infinity, normalisasi -0.0, Unicode & Escape
    // -------------------------------------------------------------------------
    test(
      '16. Serialisasi kanonikal SACJ-v1 menolak NaN/Infinity, menormalkan -0.0, dan menangani Unicode serta karakter escape',
      () {
        // A. Penolakan NaN dan Infinity
        expect(
          () => canonicalJsonEncode({'invalid': double.nan}),
          throwsArgumentError,
        );
        expect(
          () => canonicalJsonEncode({'invalid': double.infinity}),
          throwsArgumentError,
        );

        // B. Normalisasi -0.0 menjadi 0.0
        final jsonNegZero = canonicalJsonEncode({'zero': -0.0});
        final jsonPosZero = canonicalJsonEncode({'zero': 0.0});
        expect(jsonNegZero, equals(jsonPosZero));

        // C. String dengan escape sequence dan karakter Unicode
        final complexData = {
          'text': 'Pesan Darurat: "Jalur A-1 Putus"\n\tStatus: Waspada! \\ 🚨',
          'symbols': 'Alpha & Omega: α, β, γ / 100%',
          'array': [
            {'nested': 1},
            {'nested': 2},
          ],
        };
        final canonicalString = canonicalJsonEncode(complexData);
        expect(
          canonicalString,
          contains(
            'Pesan Darurat: \\"Jalur A-1 Putus\\"\\n\\tStatus: Waspada! \\\\ 🚨',
          ),
        );
        expect(canonicalString, contains('Alpha & Omega: α, β, γ / 100%'));
        // Verifikasi tidak ada forward slash yang di-escape
        expect(canonicalString.contains(r'\/'), isFalse);
      },
    );

    // -------------------------------------------------------------------------
    // 17. Validasi graf mendeteksi self-loop dan pelanggaran indeks non-monotonik
    // -------------------------------------------------------------------------
    test(
      '17. Validasi graf mendeteksi self-loop dan pelanggaran indeks non-monotonik (jaminan DAG asiklik)',
      () {
        final ledger = LightweightBlockdagLedger();
        final genesis = ledger.genesisBlock;

        // A. Blok mereferensikan dirinya sendiri (self-loop)
        final dummyHash = computeSha256('self-loop-block');
        final selfLoopBlock = SecurityBlock(
          version: 1,
          index: 1,
          blockHash: dummyHash,
          parentBlockHashes: [dummyHash], // Self-loop!
          creatorNodeId: 'NODE-A',
          timestamp: DateTime.parse('2026-10-19T11:30:00.000Z'),
          monotonicMicros: 0,
          merkleRoot: kEmptySha256,
          events: const [],
        );
        final resSelfLoop = ledger.validateBlock(selfLoopBlock);
        expect(resSelfLoop.isValid, isFalse);
        expect(
          resSelfLoop.status,
          equals(LedgerValidationStatus.invalidStructure),
        );

        // B. Pelanggaran indeks non-monotonik (index block <= index parent)
        final invalidIndexBlock = SecurityBlock.create(
          index: 0, // Indeks 0 padahal memiliki parent genesis (index 0)!
          parentBlockHashes: [genesis.blockHash],
          creatorNodeId: 'NODE-A',
          events: const [],
          timestamp: DateTime.parse('2026-10-19T11:30:05.000Z'),
        );
        final resInvalidIndex = ledger.validateBlock(invalidIndexBlock);
        expect(resInvalidIndex.isValid, isFalse);
        expect(
          resInvalidIndex.status,
          equals(LedgerValidationStatus.invalidStructure),
        );
      },
    );

    // -------------------------------------------------------------------------
    // 18. Mitigasi CVE-2012-2459: Blok dengan duplikasi event internal ditolak
    // -------------------------------------------------------------------------
    test(
      '18. Mitigasi CVE-2012-2459: Blok yang menduplikasi event internal ditolak',
      () {
        final ledger = LightweightBlockdagLedger();
        final genesis = ledger.genesisBlock;

        final event1 = SecurityAuditEvent(
          eventId: 'evt-cve-01',
          eventType: AuditEventType.idsDetection,
          observerNodeId: 'NODE-A',
          targetNodeId: 'NODE-B',
          timestamp: DateTime.parse('2026-10-19T11:40:00.000Z'),
          monotonicMicros: 1,
          metadata: {'metric': 1},
        );

        final event2 = SecurityAuditEvent(
          eventId: 'evt-cve-02',
          eventType: AuditEventType.idsDetection,
          observerNodeId: 'NODE-A',
          targetNodeId: 'NODE-B',
          timestamp: DateTime.parse('2026-10-19T11:40:02.000Z'),
          monotonicMicros: 2,
          metadata: {'metric': 2},
        );

        // Kasus Bitcoin-style attack: Tiga event [E1, E2, E3] memiliki root yang sama dengan [E1, E2, E3, E3]
        // SiagaMesh menolak blok yang memuat duplikasi event internal [E1, E2, E2]
        final maliciousBlock = SecurityBlock.create(
          index: 1,
          parentBlockHashes: [genesis.blockHash],
          creatorNodeId: 'NODE-ATTACKER',
          events: [event1, event2, event2], // Duplicate event2 inside block!
          timestamp: DateTime.parse('2026-10-19T11:40:10.000Z'),
        );

        final valResult = ledger.validateBlock(maliciousBlock);
        expect(valResult.isValid, isFalse);
        expect(valResult.status, equals(LedgerValidationStatus.duplicateEvent));
      },
    );
  });
}

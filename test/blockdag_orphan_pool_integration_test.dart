/// STAGE 5E.4.5 — Bounded Orphan Block Pool & Parent-Arrival Recovery Integration Tests
///
/// Memverifikasi 20 skenario deterministik:
/// 1. Blok dengan parent lengkap diterima langsung tanpa masuk ke orphan pool.
/// 2. Blok dengan single missing parent ditahan di orphan pool tanpa mutasi ledger.
/// 3. Blok multi-parent hanya dipromosikan setelah SELURUH parent tersedia.
/// 4. Rantai orphan bertingkat (A -> B -> C) pulih secara berurutan saat parent tiba.
/// 5. Orphan yang seluruh parent-nya tiba diterima dan dipersistensikan ke repositori.
/// 6. Blok dengan header hash korup ditolak sebelum masuk ke orphan pool.
/// 7. Blok dengan Merkle root korup ditolak sebelum masuk ke orphan pool.
/// 8. Metadata yang melanggar kebijakan privasi ditolak sebelum masuk ke orphan pool.
/// 9. Kedatangan parent yang tidak valid mencegah promosi orphan di pool.
/// 10. Blok yatim kedaluwarsa dibersihkan sesuai TTL (60 detik) dan tidak dapat dipromosikan.
/// 11. Batas kapasitas pool (20 blok) ditegakkan secara deterministik (penolakan poolFull).
/// 12. Hash duplikat tidak menambah entri dan tidak memperpanjang TTL.
/// 13. Batas kuota per-peer (8 blok) mencegah satu peer memonopoli pool.
/// 14. Kegagalan persistensi saat promosi orphan membatalkan mutasi RAM, tidak mengirim ACK, dan menahan orphan di pool.
/// 15. Pemulihan media penyimpanan memungkinkan orphan dalam batas TTL dipersistensikan pada percobaan berikutnya.
/// 16. Indeks atau kausalitas tidak valid (misal index <= parent index) ditolak permanen dari pool.
/// 17. Diskoneksi mempertahankan orphan unexpired, sementara disable dan dispose membersihkan pool.
/// 18. Restart proses tidak memperlakukan orphan yang belum dipersistensikan sebagai committed.
/// 19. Konfigurasi A dan B menghasilkan nol paket gossip; Konfigurasi C memerlukan aktivasi eksplisit.
/// 20. Kompatibilitas mundur dengan seluruh pengujian terdahulu dan mode orphan pool nonaktif.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:siagamesh_app/core/blockchain/blockchain_types.dart';
import 'package:siagamesh_app/core/blockchain/blockdag_repository.dart';
import 'package:siagamesh_app/core/blockchain/gossip/gossip.dart';
import 'package:siagamesh_app/core/blockchain/lightweight_blockdag_ledger.dart';
import 'package:siagamesh_app/core/routing/manet_routing_engine.dart';
import 'package:siagamesh_app/core/routing/mesh_experiment_logger.dart';
import 'package:siagamesh_app/core/routing/node_identity.dart';
import 'package:siagamesh_app/core/routing/routing_holder.dart';
import 'package:siagamesh_app/core/transport/fake_mesh_transport.dart';
import 'package:siagamesh_app/core/ids/selective_forwarding_detector.dart';
import 'package:siagamesh_app/core/trust/dynamic_trust_manager.dart';
import 'package:siagamesh_app/features/chat/data/repositories/chat_repository.dart';
import 'package:siagamesh_app/features/chat/models/chat_conversation.dart';
import 'package:siagamesh_app/features/chat/models/chat_message.dart';

class InMemoryBlockdagRepository implements BlockdagRepository {
  BlockdagPersistedState? _state;
  final bool _corrupted = false;

  InMemoryBlockdagRepository({BlockdagPersistedState? initialState})
    : _state = initialState;

  @override
  bool get lastLoadCorrupted => _corrupted;

  @override
  Future<BlockdagLoadResult> loadResult() async {
    if (_state == null) return BlockdagLoadResult.empty();
    return BlockdagLoadResult.success(_state!);
  }

  @override
  Future<BlockdagPersistedState?> loadState() async => _state;

  @override
  Future<bool> saveState(BlockdagPersistedState state) async {
    _state = state;
    return true;
  }

  @override
  Future<bool> clear() async {
    _state = null;
    return true;
  }
}

class ControllableBlockdagRepository implements BlockdagRepository {
  BlockdagPersistedState? _state;
  bool shouldFailSave = false;
  bool shouldThrowOnSave = false;
  int saveCount = 0;
  final bool _corrupted = false;

  ControllableBlockdagRepository({BlockdagPersistedState? initialState})
    : _state = initialState;

  @override
  bool get lastLoadCorrupted => _corrupted;

  @override
  Future<BlockdagLoadResult> loadResult() async {
    if (_state == null) return BlockdagLoadResult.empty();
    return BlockdagLoadResult.success(_state!);
  }

  @override
  Future<BlockdagPersistedState?> loadState() async => _state;

  @override
  Future<bool> saveState(BlockdagPersistedState state) async {
    saveCount++;
    if (shouldThrowOnSave) {
      throw Exception('Simulated repository write failure (I/O error)');
    }
    if (shouldFailSave) {
      return false;
    }
    _state = state;
    return true;
  }

  @override
  Future<bool> clear() async {
    _state = null;
    return true;
  }
}

class FakeChatRepository implements ChatRepository {
  final List<ChatMessage> savedMessages = [];

  @override
  Future<List<ChatConversation>> getConversations() async => [];

  @override
  Future<List<ChatMessage>> getMessages(String conversationId) async =>
      savedMessages;

  @override
  Future<void> saveMessage(String conversationId, ChatMessage message) async {
    savedMessages.add(message);
  }

  @override
  Future<ChatConversation> getOrCreateConversationForNode({
    required String nodeId,
    required String nodeName,
    bool isEmergency = false,
    bool isConnected = true,
  }) async {
    return ChatConversation(
      id: 'conv-$nodeId',
      title: nodeName,
      nodeId: nodeId,
      peerNodeId: nodeId,
      lastMessage: 'Belum ada pesan',
      time: 'Baru saja',
      badgeText: 'Node',
      badgeBgColor: const Color(0xFF000000),
      badgeTextColor: const Color(0xFFFFFFFF),
    );
  }

  @override
  Future<ChatConversation> getOrCreateBroadcastConversation() async {
    return const ChatConversation(
      id: 'broadcast',
      title: 'Broadcast',
      nodeId: 'BROADCAST',
      lastMessage: 'Belum ada pesan',
      time: 'Baru saja',
      badgeText: 'Siaran',
      badgeBgColor: Color(0xFF000000),
      badgeTextColor: Color(0xFFFFFFFF),
    );
  }

  @override
  Future<bool> deleteMessage(String conversationId, String messageId) async {
    final initialCount = savedMessages.length;
    savedMessages.removeWhere((m) => m.id == messageId);
    return savedMessages.length < initialCount;
  }

  @override
  Future<void> clearAllData() async {
    savedMessages.clear();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('STAGE 5E.4.5 — Bounded Orphan Block Pool & Parent-Arrival Recovery', () {
    late FakeMeshTransport transportA;
    late FakeMeshTransport transportB;
    late LightweightBlockdagLedger ledgerA;
    late LightweightBlockdagLedger ledgerB;
    late InMemoryBlockdagRepository repoA;
    late InMemoryBlockdagRepository repoB;
    late OrphanBlockPool orphanPoolB;
    late DagGossipSyncEngine engineA;
    late DagGossipSyncEngine engineB;
    late FakeChatRepository chatRepoA;
    late FakeChatRepository chatRepoB;
    late MeshExperimentLogger loggerA;
    late MeshExperimentLogger loggerB;
    late ManetRoutingEngine routingA;
    late ManetRoutingEngine routingB;

    setUp(() {
      transportA = FakeMeshTransport();
      transportB = FakeMeshTransport();
      ledgerA = LightweightBlockdagLedger();
      ledgerB = LightweightBlockdagLedger();
      repoA = InMemoryBlockdagRepository();
      repoB = InMemoryBlockdagRepository();
      orphanPoolB = OrphanBlockPool();
      chatRepoA = FakeChatRepository();
      chatRepoB = FakeChatRepository();
      loggerA = MeshExperimentLogger();
      loggerB = MeshExperimentLogger();

      engineA = DagGossipSyncEngine(
        transport: transportA,
        localNodeId: 'NODE-A',
        ledger: ledgerA,
        repository: repoA,
        enableOrphanPool: true,
        isEnabled: true,
      );

      engineB = DagGossipSyncEngine(
        transport: transportB,
        localNodeId: 'NODE-B',
        ledger: ledgerB,
        repository: repoB,
        orphanPool: orphanPoolB,
        isEnabled: true,
      );

      routingA = ManetRoutingEngine(
        transport: transportA,
        identityManager: NodeIdentityManager(),
        repository: chatRepoA,
        experimentLogger: loggerA,
        gossipSyncEngine: engineA,
      );

      routingB = ManetRoutingEngine(
        transport: transportB,
        identityManager: NodeIdentityManager(),
        repository: chatRepoB,
        experimentLogger: loggerB,
        gossipSyncEngine: engineB,
      );
    });

    tearDown(() {
      routingA.dispose();
      routingB.dispose();
      engineA.dispose();
      engineB.dispose();
      ManetRoutingHolder.reset();
    });

    Future<void> establishSession() async {
      transportA.simulateIncomingConnectionRequest(
        endpointId: 'ep-b',
        endpointName: 'Node B',
      );
      await transportA.acceptConnection(endpointId: 'ep-b');

      transportB.simulateIncomingConnectionRequest(
        endpointId: 'ep-a',
        endpointName: 'Node A',
      );
      await transportB.acceptConnection(endpointId: 'ep-a');

      await Future<void>.delayed(const Duration(milliseconds: 20));

      final helloPayloadsA = transportA.sentPayloads
          .where((p) => DagGossipSyncEngine.isGossipPayload(p.bytes))
          .toList();
      for (final p in helloPayloadsA) {
        transportB.simulateIncomingPayload(endpointId: 'ep-a', bytes: p.bytes);
      }

      final helloPayloadsB = transportB.sentPayloads
          .where((p) => DagGossipSyncEngine.isGossipPayload(p.bytes))
          .toList();
      for (final p in helloPayloadsB) {
        transportA.simulateIncomingPayload(endpointId: 'ep-b', bytes: p.bytes);
      }

      await Future<void>.delayed(const Duration(milliseconds: 20));

      final invPayloadsA = transportA.sentPayloads
          .where((p) => DagGossipSyncEngine.isGossipPayload(p.bytes))
          .toList();
      for (final p in invPayloadsA) {
        transportB.simulateIncomingPayload(endpointId: 'ep-a', bytes: p.bytes);
      }

      final invPayloadsB = transportB.sentPayloads
          .where((p) => DagGossipSyncEngine.isGossipPayload(p.bytes))
          .toList();
      for (final p in invPayloadsB) {
        transportA.simulateIncomingPayload(endpointId: 'ep-b', bytes: p.bytes);
      }

      await Future<void>.delayed(const Duration(milliseconds: 20));

      transportA.clearSentPayloads();
      transportB.clearSentPayloads();
    }

    // ------------------------------------------------------------------------
    // 1. Complete parent block accepted directly without pool
    // ------------------------------------------------------------------------
    test('1. Complete parent block accepted directly without pool', () async {
      await establishSession();

      final blockA1 = ledgerA.createBlock(
        creatorNodeId: 'NODE-A',
        validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
      );

      final sessionB = engineB.getSession('ep-a')!;
      sessionB.activeRequestId = 'req-test-1';

      transportB.clearSentPayloads();
      transportB.simulateIncomingPayload(
        endpointId: 'ep-a',
        bytes: DagGossipCodec.encode(
          DagBlockBatchMessage(
            senderNodeId: 'NODE-A',
            requestId: 'req-test-1',
            batchIndex: 1,
            totalBatches: 1,
            blocks: [blockA1],
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(ledgerB.getBlock(blockA1.blockHash), isNotNull);
      expect(orphanPoolB.count, equals(0));
      expect(engineB.totalRemoteBlocksAccepted, equals(1));

      final acks = transportB.sentPayloads
          .map((p) => DagGossipCodec.decode(p.bytes).message)
          .whereType<DagSyncAckMessage>()
          .toList();
      expect(acks.length, equals(1));
      expect(acks.first.acceptedBlockHashes, equals([blockA1.blockHash]));
    });

    // ------------------------------------------------------------------------
    // 2. Single missing parent held in pool without ledger mutation
    // ------------------------------------------------------------------------
    test(
      '2. Single missing parent held in pool without ledger mutation',
      () async {
        await establishSession();

        final missingParentHash = computeSha256('missing-parent-2');
        final orphanBlock = SecurityBlock.create(
          index: 2,
          parentBlockHashes: [missingParentHash],
          creatorNodeId: 'NODE-A',
          events: [],
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        final sessionB = engineB.getSession('ep-a')!;
        sessionB.activeRequestId = 'req-test-2';

        transportB.clearSentPayloads();
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-test-2',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [orphanBlock],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(orphanPoolB.count, equals(1));
        expect(orphanPoolB.contains(orphanBlock.blockHash), isTrue);
        expect(ledgerB.getBlock(orphanBlock.blockHash), isNull);
        expect(ledgerB.activeBlocksCount, equals(1)); // Only genesis
        expect(engineB.totalRemoteBlocksAccepted, equals(0));
        expect(sessionB.missingBlockHashes, contains(missingParentHash));

        // No ACK sent for unpersisted orphan block
        final acks = transportB.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagSyncAckMessage>()
            .toList();
        expect(acks, isEmpty);
      },
    );

    // ------------------------------------------------------------------------
    // 3. Multi-parent block processed only after all parents arrive
    // ------------------------------------------------------------------------
    test('3. Multi-parent block processed only after all parents arrive', () async {
      await establishSession();

      final p1 = ledgerA.createBlock(
        creatorNodeId: 'NODE-A',
        validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
      );
      final p2 = ledgerA.createBlock(
        creatorNodeId: 'NODE-A',
        validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
      );

      final multiParentBlock = SecurityBlock.create(
        index: 3,
        parentBlockHashes: [p1.blockHash, p2.blockHash],
        creatorNodeId: 'NODE-A',
        events: [],
        validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
      );

      final sessionB = engineB.getSession('ep-a')!;

      // 1. Send multi-parent block first -> enters orphan pool
      sessionB.activeRequestId = 'req-multi-1';
      transportB.simulateIncomingPayload(
        endpointId: 'ep-a',
        bytes: DagGossipCodec.encode(
          DagBlockBatchMessage(
            senderNodeId: 'NODE-A',
            requestId: 'req-multi-1',
            batchIndex: 1,
            totalBatches: 1,
            blocks: [multiParentBlock],
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(orphanPoolB.count, equals(1));
      expect(ledgerB.getBlock(multiParentBlock.blockHash), isNull);

      // 2. Send P1 only -> P1 accepted, multi-parent block REMAINS in pool (waiting for P2)
      sessionB.activeRequestId = 'req-multi-2';
      transportB.simulateIncomingPayload(
        endpointId: 'ep-a',
        bytes: DagGossipCodec.encode(
          DagBlockBatchMessage(
            senderNodeId: 'NODE-A',
            requestId: 'req-multi-2',
            batchIndex: 1,
            totalBatches: 1,
            blocks: [p1],
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(ledgerB.getBlock(p1.blockHash), isNotNull);
      expect(ledgerB.getBlock(multiParentBlock.blockHash), isNull);
      expect(orphanPoolB.count, equals(1));

      // 3. Send P2 -> P2 accepted, AND multi-parent block is promoted and accepted!
      sessionB.activeRequestId = 'req-multi-3';
      transportB.simulateIncomingPayload(
        endpointId: 'ep-a',
        bytes: DagGossipCodec.encode(
          DagBlockBatchMessage(
            senderNodeId: 'NODE-A',
            requestId: 'req-multi-3',
            batchIndex: 1,
            totalBatches: 1,
            blocks: [p2],
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(ledgerB.getBlock(p2.blockHash), isNotNull);
      expect(ledgerB.getBlock(multiParentBlock.blockHash), isNotNull);
      expect(orphanPoolB.count, equals(0));
      expect(
        ledgerB.activeBlocksCount,
        equals(4),
      ); // Genesis, P1, P2, multiParentBlock
    });

    // ------------------------------------------------------------------------
    // 4. Chained orphan A -> B -> C recovered as parents arrive sequentially
    // ------------------------------------------------------------------------
    test(
      '4. Chained orphan A -> B -> C recovered as parents arrive sequentially',
      () async {
        await establishSession();

        // B1 depends on Genesis
        final b1 = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );
        // B2 depends on B1
        final b2 = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );
        // B3 depends on B2
        final b3 = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        final sessionB = engineB.getSession('ep-a')!;

        // Deliver in reverse order: B3 first
        sessionB.activeRequestId = 'req-chain-b3';
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-chain-b3',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [b3],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(orphanPoolB.count, equals(1));

        // Deliver B2 second
        sessionB.activeRequestId = 'req-chain-b2';
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-chain-b2',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [b2],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(orphanPoolB.count, equals(2));

        // Deliver B1 -> triggers resolution: B1 accepted, then B2 promoted, then B3 promoted!
        sessionB.activeRequestId = 'req-chain-b1';
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-chain-b1',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [b1],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(orphanPoolB.count, equals(0));
        expect(ledgerB.getBlock(b1.blockHash), isNotNull);
        expect(ledgerB.getBlock(b2.blockHash), isNotNull);
        expect(ledgerB.getBlock(b3.blockHash), isNotNull);
        expect(ledgerB.activeBlocksCount, equals(4)); // Genesis + 3
      },
    );

    // ------------------------------------------------------------------------
    // 5. Orphan with all parents arrived is accepted and persisted
    // ------------------------------------------------------------------------
    test(
      '5. Orphan with all parents arrived is accepted and persisted',
      () async {
        await establishSession();

        final parent = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );
        final orphan = SecurityBlock.create(
          index: 2,
          parentBlockHashes: [parent.blockHash],
          creatorNodeId: 'NODE-A',
          events: [],
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        final sessionB = engineB.getSession('ep-a')!;

        // 1. Ingest orphan -> placed in pool
        sessionB.activeRequestId = 'req-orphan-5';
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-orphan-5',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [orphan],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(orphanPoolB.count, equals(1));

        // 2. Parent arrives -> accepted, orphan promoted & persisted to repoB
        sessionB.activeRequestId = 'req-parent-5';
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-parent-5',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [parent],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(orphanPoolB.count, equals(0));
        final savedState = await repoB.loadState();
        expect(savedState, isNotNull);
        expect(
          savedState!.blocks.any((b) => b.blockHash == orphan.blockHash),
          isTrue,
        );
        expect(sessionB.knownPeerBlockHashes, contains(orphan.blockHash));
      },
    );

    // ------------------------------------------------------------------------
    // 6. Orphan with bad header hash rejected before entering pool
    // ------------------------------------------------------------------------
    test(
      '6. Orphan with bad header hash rejected before entering pool',
      () async {
        await establishSession();

        final validOrphan = SecurityBlock.create(
          index: 2,
          parentBlockHashes: [computeSha256('non-existent-parent-6')],
          creatorNodeId: 'NODE-A',
          events: [],
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        final badHashBlock = SecurityBlock(
          version: validOrphan.version,
          index: validOrphan.index,
          blockHash: '0' * 64, // Invalid recomputed header hash
          parentBlockHashes: validOrphan.parentBlockHashes,
          creatorNodeId: validOrphan.creatorNodeId,
          timestamp: validOrphan.timestamp,
          monotonicMicros: validOrphan.monotonicMicros,
          merkleRoot: validOrphan.merkleRoot,
          events: validOrphan.events,
          validationProof: validOrphan.validationProof,
        );

        final sessionB = engineB.getSession('ep-a')!;
        sessionB.activeRequestId = 'req-bad-hash-6';

        transportB.clearSentPayloads();
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-bad-hash-6',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [badHashBlock],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(orphanPoolB.count, equals(0));
        expect(engineB.totalRemoteBlocksRejected, equals(1));

        final rejects = transportB.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagRejectMessage>()
            .toList();
        expect(rejects.length, equals(1));
        expect(
          rejects.first.errorCode,
          equals(DagRejectCode.invalidHashFormat),
        );
      },
    );

    // ------------------------------------------------------------------------
    // 7. Orphan with bad Merkle root rejected before entering pool
    // ------------------------------------------------------------------------
    test(
      '7. Orphan with bad Merkle root rejected before entering pool',
      () async {
        await establishSession();

        final validOrphan = SecurityBlock.create(
          index: 2,
          parentBlockHashes: [computeSha256('non-existent-parent-7')],
          creatorNodeId: 'NODE-A',
          events: [],
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        final badMerkleBlock = SecurityBlock(
          version: validOrphan.version,
          index: validOrphan.index,
          blockHash: validOrphan.blockHash,
          parentBlockHashes: validOrphan.parentBlockHashes,
          creatorNodeId: validOrphan.creatorNodeId,
          timestamp: validOrphan.timestamp,
          monotonicMicros: validOrphan.monotonicMicros,
          merkleRoot: computeSha256('tampered-merkle-7'),
          events: validOrphan.events,
          validationProof: validOrphan.validationProof,
        );

        final sessionB = engineB.getSession('ep-a')!;
        sessionB.activeRequestId = 'req-bad-merkle-7';

        transportB.clearSentPayloads();
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-bad-merkle-7',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [badMerkleBlock],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(orphanPoolB.count, equals(0));
        expect(engineB.totalRemoteBlocksRejected, equals(1));

        final rejects = transportB.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagRejectMessage>()
            .toList();
        expect(rejects.length, equals(1));
        expect(
          rejects.first.errorCode,
          equals(DagRejectCode.invalidMerkleRoot),
        );
      },
    );

    // ------------------------------------------------------------------------
    // 8. Forbidden privacy metadata rejected before entering pool
    // ------------------------------------------------------------------------
    test(
      '8. Forbidden privacy metadata rejected before entering pool',
      () async {
        await establishSession();

        final badEvent = SecurityAuditEvent(
          eventId: 'evt-bad-privacy-8',
          eventType: AuditEventType.idsDetection,
          observerNodeId: 'NODE-A',
          targetNodeId: 'NODE-B',
          timestamp: DateTime.now().toUtc(),
          monotonicMicros: 100,
          metadata: {
            'status': 'detected',
            'reason': 'normal',
            'body': 'unauthorized private text content',
          },
        );

        final blockWithPrivateData = SecurityBlock.create(
          index: 2,
          parentBlockHashes: [computeSha256('missing-parent-8')],
          creatorNodeId: 'NODE-A',
          events: [badEvent],
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        final sessionB = engineB.getSession('ep-a')!;
        sessionB.activeRequestId = 'req-privacy-8';

        transportB.clearSentPayloads();
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-privacy-8',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [blockWithPrivateData],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(orphanPoolB.count, equals(0));
        expect(engineB.totalRemoteBlocksRejected, equals(1));

        final rejects = transportB.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagRejectMessage>()
            .toList();
        expect(rejects.length, equals(1));
        expect(rejects.first.errorCode, equals(DagRejectCode.privacyViolation));
      },
    );

    // ------------------------------------------------------------------------
    // 9. Invalid arriving parent prevents orphan promotion
    // ------------------------------------------------------------------------
    test('9. Invalid arriving parent prevents orphan promotion', () async {
      await establishSession();

      final parentHash = computeSha256('parent-target-9');
      final orphan = SecurityBlock.create(
        index: 2,
        parentBlockHashes: [parentHash],
        creatorNodeId: 'NODE-A',
        events: [],
        validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
      );

      final sessionB = engineB.getSession('ep-a')!;

      // 1. Orphan arrives and enters pool
      sessionB.activeRequestId = 'req-orphan-9';
      transportB.simulateIncomingPayload(
        endpointId: 'ep-a',
        bytes: DagGossipCodec.encode(
          DagBlockBatchMessage(
            senderNodeId: 'NODE-A',
            requestId: 'req-orphan-9',
            batchIndex: 1,
            totalBatches: 1,
            blocks: [orphan],
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(orphanPoolB.count, equals(1));

      // 2. An invalid block arrives claiming to be the parent (corrupted Merkle root)
      final fakeParent = SecurityBlock(
        version: 1,
        index: 1,
        blockHash: parentHash,
        parentBlockHashes: [ledgerB.genesisBlock.blockHash],
        creatorNodeId: 'NODE-A',
        timestamp: DateTime.now().toUtc(),
        monotonicMicros: 100,
        merkleRoot: computeSha256('tampered-merkle'),
        events: const [],
        validationProof: const {
          'flushReason': 'manual',
          'creatorNodeId': 'NODE-A',
        },
      );

      sessionB.activeRequestId = 'req-fake-parent-9';
      transportB.simulateIncomingPayload(
        endpointId: 'ep-a',
        bytes: DagGossipCodec.encode(
          DagBlockBatchMessage(
            senderNodeId: 'NODE-A',
            requestId: 'req-fake-parent-9',
            batchIndex: 1,
            totalBatches: 1,
            blocks: [fakeParent],
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Parent rejected -> orphan remains in pool and is not promoted
      expect(ledgerB.getBlock(parentHash), isNull);
      expect(ledgerB.getBlock(orphan.blockHash), isNull);
      expect(orphanPoolB.count, equals(1));
    });

    // ------------------------------------------------------------------------
    // 10. Expired blocks purged according to TTL (60s)
    // ------------------------------------------------------------------------
    test('10. Expired blocks purged according to TTL (60s)', () async {
      DateTime currentTime = DateTime.utc(2026, 1, 1, 12, 0, 0);
      final pool = OrphanBlockPool(nowProvider: () => currentTime);

      final orphan = SecurityBlock.create(
        index: 2,
        parentBlockHashes: [computeSha256('missing-10')],
        creatorNodeId: 'NODE-A',
        events: [],
        validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
      );

      final addResult = pool.add(
        block: orphan,
        missingParentHashes: {orphan.parentBlockHashes.first},
        peerEndpointId: 'ep-a',
      );
      expect(addResult.isAdded, isTrue);
      expect(pool.count, equals(1));

      // Advance time by 30 seconds -> not expired yet
      currentTime = currentTime.add(const Duration(seconds: 30));
      expect(pool.count, equals(1));

      // Advance time by another 31 seconds (total 61s > TTL 60s) -> expired & purged!
      currentTime = currentTime.add(const Duration(seconds: 31));
      expect(pool.count, equals(0));
      expect(pool.contains(orphan.blockHash), isFalse);
    });

    // ------------------------------------------------------------------------
    // 11. Capacity never exceeds 20 blocks
    // ------------------------------------------------------------------------
    test('11. Capacity never exceeds 20 blocks', () {
      final pool = OrphanBlockPool(
        maxCapacity: 20,
        maxOrphansPerPeer: 30, // Unrestrict peer limit for this capacity test
      );

      for (int i = 0; i < 20; i++) {
        final b = SecurityBlock.create(
          index: i + 1,
          parentBlockHashes: [computeSha256('parent-$i')],
          creatorNodeId: 'NODE-A',
          events: [],
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );
        final res = pool.add(
          block: b,
          missingParentHashes: {b.parentBlockHashes.first},
          peerEndpointId: 'ep-$i',
        );
        expect(res.isAdded, isTrue);
      }

      expect(pool.count, equals(20));

      // 21st block must be rejected due to poolFull
      final overflowBlock = SecurityBlock.create(
        index: 21,
        parentBlockHashes: [computeSha256('parent-21')],
        creatorNodeId: 'NODE-A',
        events: [],
        validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
      );

      final overflowRes = pool.add(
        block: overflowBlock,
        missingParentHashes: {overflowBlock.parentBlockHashes.first},
        peerEndpointId: 'ep-overflow',
      );
      expect(overflowRes.isFull, isTrue);
      expect(overflowRes.status, equals(OrphanPoolAddStatus.poolFull));
      expect(pool.count, equals(20));
    });

    // ------------------------------------------------------------------------
    // 12. Duplicate hash does not increase entry count or extend TTL
    // ------------------------------------------------------------------------
    test('12. Duplicate hash does not increase entry count or extend TTL', () {
      DateTime currentTime = DateTime.utc(2026, 1, 1, 12, 0, 0);
      final pool = OrphanBlockPool(nowProvider: () => currentTime);

      final orphan = SecurityBlock.create(
        index: 2,
        parentBlockHashes: [computeSha256('missing-12')],
        creatorNodeId: 'NODE-A',
        events: [],
        validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
      );

      final res1 = pool.add(
        block: orphan,
        missingParentHashes: {orphan.parentBlockHashes.first},
        peerEndpointId: 'ep-a',
      );
      expect(res1.isAdded, isTrue);
      final originalExpiresAt = pool.getEntry(orphan.blockHash)!.expiresAt;

      // Advance time by 40s
      currentTime = currentTime.add(const Duration(seconds: 40));

      // Add identical orphan again
      final res2 = pool.add(
        block: orphan,
        missingParentHashes: {orphan.parentBlockHashes.first},
        peerEndpointId: 'ep-a',
      );
      expect(res2.isDuplicate, isTrue);
      expect(pool.count, equals(1));
      expect(
        pool.getEntry(orphan.blockHash)!.expiresAt,
        equals(originalExpiresAt),
      );

      // Advance 21s (total 61s from start) -> must expire, not extended
      currentTime = currentTime.add(const Duration(seconds: 21));
      expect(pool.count, equals(0));
    });

    // ------------------------------------------------------------------------
    // 13. Per-peer quota (8) prevents single peer from monopolizing pool
    // ------------------------------------------------------------------------
    test(
      '13. Per-peer quota (8) prevents single peer from monopolizing pool',
      () {
        final pool = OrphanBlockPool(maxCapacity: 20, maxOrphansPerPeer: 8);

        // Peer A adds 8 blocks
        for (int i = 0; i < 8; i++) {
          final b = SecurityBlock.create(
            index: i + 1,
            parentBlockHashes: [computeSha256('parent-peera-$i')],
            creatorNodeId: 'NODE-A',
            events: [],
            validationProof: {
              'flushReason': 'manual',
              'creatorNodeId': 'NODE-A',
            },
          );
          final res = pool.add(
            block: b,
            missingParentHashes: {b.parentBlockHashes.first},
            peerEndpointId: 'ep-peer-a',
          );
          expect(res.isAdded, isTrue);
        }
        expect(pool.countForPeer('ep-peer-a'), equals(8));

        // 9th block from Peer A is rejected with peerQuotaExceeded
        final b9 = SecurityBlock.create(
          index: 9,
          parentBlockHashes: [computeSha256('parent-peera-9')],
          creatorNodeId: 'NODE-A',
          events: [],
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );
        final res9 = pool.add(
          block: b9,
          missingParentHashes: {b9.parentBlockHashes.first},
          peerEndpointId: 'ep-peer-a',
        );
        expect(res9.isPeerQuotaExceeded, isTrue);
        expect(res9.status, equals(OrphanPoolAddStatus.peerQuotaExceeded));

        // Peer B can still add blocks!
        final bPeerB = SecurityBlock.create(
          index: 1,
          parentBlockHashes: [computeSha256('parent-peerb-1')],
          creatorNodeId: 'NODE-B',
          events: [],
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-B'},
        );
        final resPeerB = pool.add(
          block: bPeerB,
          missingParentHashes: {bPeerB.parentBlockHashes.first},
          peerEndpointId: 'ep-peer-b',
        );
        expect(resPeerB.isAdded, isTrue);
        expect(pool.count, equals(9));
      },
    );

    // ------------------------------------------------------------------------
    // 14. Storage failure during orphan promotion sends no ACK and rolls back ledger
    // ------------------------------------------------------------------------
    test(
      '14. Storage failure during orphan promotion sends no ACK and rolls back ledger',
      () async {
        engineB.dispose();
        final controllableRepo = ControllableBlockdagRepository();
        final controllableEngineB = DagGossipSyncEngine(
          transport: transportB,
          localNodeId: 'NODE-B',
          ledger: ledgerB,
          repository: controllableRepo,
          orphanPool: orphanPoolB,
          isEnabled: true,
        );
        routingB.gossipSyncEngine = controllableEngineB;

        transportB.simulateIncomingConnectionRequest(
          endpointId: 'ep-a',
          endpointName: 'Node A',
        );
        await transportB.acceptConnection(endpointId: 'ep-a');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final sessionB = controllableEngineB.getSession('ep-a')!;

        final parent = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );
        final orphan = SecurityBlock.create(
          index: 2,
          parentBlockHashes: [parent.blockHash],
          creatorNodeId: 'NODE-A',
          events: [],
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        // Put orphan in pool
        sessionB.activeRequestId = 'req-orphan-14';
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-orphan-14',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [orphan],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(orphanPoolB.count, equals(1));

        // Set storage to fail during parent ingestion & orphan promotion
        controllableRepo.shouldFailSave = true;

        sessionB.activeRequestId = 'req-parent-14';
        transportB.clearSentPayloads();
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-parent-14',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [parent],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Ledger rolled back to pre-ingest snapshot: only Genesis
        expect(ledgerB.activeBlocksCount, equals(1));
        expect(ledgerB.getBlock(parent.blockHash), isNull);
        expect(ledgerB.getBlock(orphan.blockHash), isNull);

        // Orphan REMAINS in pool for future retry
        expect(orphanPoolB.count, equals(1));

        // No ACK sent for unpersisted blocks
        final acks = transportB.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagSyncAckMessage>()
            .toList();
        expect(acks, isEmpty);

        controllableEngineB.dispose();
      },
    );

    // ------------------------------------------------------------------------
    // 15. Storage recovery allows orphan within TTL to be retried and persisted
    // ------------------------------------------------------------------------
    test(
      '15. Storage recovery allows orphan within TTL to be retried and persisted',
      () async {
        engineB.dispose();
        final controllableRepo = ControllableBlockdagRepository();
        final controllableEngineB = DagGossipSyncEngine(
          transport: transportB,
          localNodeId: 'NODE-B',
          ledger: ledgerB,
          repository: controllableRepo,
          orphanPool: orphanPoolB,
          isEnabled: true,
        );
        routingB.gossipSyncEngine = controllableEngineB;

        transportB.simulateIncomingConnectionRequest(
          endpointId: 'ep-a',
          endpointName: 'Node A',
        );
        await transportB.acceptConnection(endpointId: 'ep-a');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final sessionB = controllableEngineB.getSession('ep-a')!;

        final parent = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );
        final orphan = SecurityBlock.create(
          index: 2,
          parentBlockHashes: [parent.blockHash],
          creatorNodeId: 'NODE-A',
          events: [],
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        // Put orphan in pool
        sessionB.activeRequestId = 'req-orphan-15';
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-orphan-15',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [orphan],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(orphanPoolB.count, equals(1));

        // Stage 1: Storage fails
        controllableRepo.shouldFailSave = true;
        sessionB.activeRequestId = 'req-parent-15-fail';
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-parent-15-fail',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [parent],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(ledgerB.activeBlocksCount, equals(1));
        expect(orphanPoolB.count, equals(1));

        // Stage 2: Storage recovers
        controllableRepo.shouldFailSave = false;

        // Resend parent -> parent persisted, and orphan in pool promoted & persisted!
        sessionB.activeRequestId = 'req-parent-15-success';
        transportB.clearSentPayloads();
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-parent-15-success',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [parent],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(orphanPoolB.count, equals(0));
        expect(ledgerB.getBlock(parent.blockHash), isNotNull);
        expect(ledgerB.getBlock(orphan.blockHash), isNotNull);
        expect(ledgerB.activeBlocksCount, equals(3));

        final acks = transportB.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagSyncAckMessage>()
            .toList();
        expect(acks.isNotEmpty, isTrue);

        controllableEngineB.dispose();
      },
    );

    // ------------------------------------------------------------------------
    // 16. Parent cycle or invalid index causes permanent rejection
    // ------------------------------------------------------------------------
    test(
      '16. Parent cycle or invalid index causes permanent rejection',
      () async {
        await establishSession();

        // Block with index 1 (same as parent index 1)
        final parent = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );
        expect(parent.index, equals(1));

        // Invalid orphan: index 1 <= parent index 1
        final invalidIndexOrphan = SecurityBlock.create(
          index: 1,
          parentBlockHashes: [parent.blockHash],
          creatorNodeId: 'NODE-A',
          events: [],
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        final sessionB = engineB.getSession('ep-a')!;

        // 1. Invalid orphan enters pool
        sessionB.activeRequestId = 'req-invalid-idx-16';
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-invalid-idx-16',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [invalidIndexOrphan],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(orphanPoolB.count, equals(1));

        // 2. Parent arrives -> triggers evaluation. Orphan has index <= parent index -> permanently rejected!
        sessionB.activeRequestId = 'req-parent-16';
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-parent-16',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [parent],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Orphan was removed from pool and rejected, not accepted into ledger
        expect(orphanPoolB.count, equals(0));
        expect(ledgerB.getBlock(invalidIndexOrphan.blockHash), isNull);
        expect(ledgerB.getBlock(parent.blockHash), isNotNull);
        expect(engineB.totalRemoteBlocksRejected, equals(1));
      },
    );

    // ------------------------------------------------------------------------
    // 17. Disconnect, disable, and dispose leave no active pool resources
    // ------------------------------------------------------------------------
    test(
      '17. Disconnect, disable, and dispose leave no active pool resources',
      () async {
        await establishSession();

        final orphan = SecurityBlock.create(
          index: 2,
          parentBlockHashes: [computeSha256('missing-17')],
          creatorNodeId: 'NODE-A',
          events: [],
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        final sessionB = engineB.getSession('ep-a')!;
        sessionB.activeRequestId = 'req-orphan-17';
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-orphan-17',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [orphan],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(orphanPoolB.count, equals(1));

        // Peer disconnect: unexpired orphan is kept in pool
        transportB.simulateDisconnection('ep-a');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(orphanPoolB.count, equals(1));

        // Disable engine: clears orphan pool
        engineB.isEnabled = false;
        expect(orphanPoolB.count, equals(0));

        // Dispose: cleans all resources safely
        engineB.dispose();
        expect(engineB.isDisposed, isTrue);
        expect(orphanPoolB.count, equals(0));
      },
    );

    // ------------------------------------------------------------------------
    // 18. Process restart does not treat unpersisted orphans as committed
    // ------------------------------------------------------------------------
    test(
      '18. Process restart does not treat unpersisted orphans as committed',
      () async {
        await establishSession();

        final orphan = SecurityBlock.create(
          index: 2,
          parentBlockHashes: [computeSha256('missing-18')],
          creatorNodeId: 'NODE-A',
          events: [],
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        final sessionB = engineB.getSession('ep-a')!;
        sessionB.activeRequestId = 'req-orphan-18';
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-orphan-18',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [orphan],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(orphanPoolB.count, equals(1));

        // Simulate process restart: load ledger fresh from repoB
        final freshRepoState = await repoB.loadState();
        final freshLedger = LightweightBlockdagLedger();
        if (freshRepoState != null) {
          freshLedger.restoreFromPersistedState(freshRepoState);
        }

        // Unpersisted orphan MUST NOT be in restored ledger
        expect(freshLedger.getBlock(orphan.blockHash), isNull);
        expect(freshLedger.activeBlocksCount, equals(1)); // Only genesis
      },
    );

    // ------------------------------------------------------------------------
    // 19. Config A/B generate 0 gossip packets; Config C requires explicit activation
    // ------------------------------------------------------------------------
    test(
      '19. Config A/B generate 0 gossip packets; Config C requires explicit activation',
      () async {
        // Config A: Default routing without gossip
        final configATransport = FakeMeshTransport();
        final configAEngine = ManetRoutingEngine(
          transport: configATransport,
          identityManager: NodeIdentityManager(),
          repository: FakeChatRepository(),
          experimentLogger: MeshExperimentLogger(),
        );

        configATransport.simulateIncomingConnectionRequest(
          endpointId: 'ep-peer',
          endpointName: 'Peer',
        );
        await configATransport.acceptConnection(endpointId: 'ep-peer');
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(
          configATransport.sentPayloads.any(
            (p) => DagGossipSyncEngine.isGossipPayload(p.bytes),
          ),
          isFalse,
        );
        configAEngine.dispose();

        // Config B: Security Hardened without gossip replication
        final configBTransport = FakeMeshTransport();
        final configBEngine = ManetRoutingEngine(
          transport: configBTransport,
          identityManager: NodeIdentityManager(),
          repository: FakeChatRepository(),
          experimentLogger: MeshExperimentLogger(),
          idsDetector: SelectiveForwardingDetector(localNodeId: 'NODE-B'),
          trustManager: DynamicTrustManager(localNodeId: 'NODE-B'),
          enableTrustRoutingPolicy: true,
        );

        configBTransport.simulateIncomingConnectionRequest(
          endpointId: 'ep-peer',
          endpointName: 'Peer',
        );
        await configBTransport.acceptConnection(endpointId: 'ep-peer');
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(
          configBTransport.sentPayloads.any(
            (p) => DagGossipSyncEngine.isGossipPayload(p.bytes),
          ),
          isFalse,
        );
        configBEngine.dispose();

        // Config C: Explicit activation required
        ManetRoutingHolder.reset();
        expect(ManetRoutingHolder.enableBlockdagReplication, isFalse);

        final cTransport = FakeMeshTransport();
        final cSyncEngine = DagGossipSyncEngine(
          transport: cTransport,
          localNodeId: 'NODE-C',
          ledger: LightweightBlockdagLedger(),
          enableOrphanPool: true,
          isEnabled: false,
        );
        ManetRoutingHolder.setGossipSyncEngine(cSyncEngine);
        expect(cSyncEngine.isEnabled, isFalse);

        ManetRoutingHolder.setEnableBlockdagReplication(true);
        expect(cSyncEngine.isEnabled, isTrue);

        cSyncEngine.dispose();
        ManetRoutingHolder.reset();
      },
    );

    // ------------------------------------------------------------------------
    // 20. Backward compatibility with all existing tests
    // ------------------------------------------------------------------------
    test('20. Backward compatibility with all existing tests', () async {
      engineB.dispose();
      // When orphan pool is not enabled (default), missing parent immediately rejects as in Stage 5E.4.4
      final nonPoolEngine = DagGossipSyncEngine(
        transport: transportB,
        localNodeId: 'NODE-B',
        ledger: ledgerB,
        enableOrphanPool: false, // Default
        isEnabled: true,
      );
      routingB.gossipSyncEngine = nonPoolEngine;

      transportB.simulateIncomingConnectionRequest(
        endpointId: 'ep-a',
        endpointName: 'Node A',
      );
      await transportB.acceptConnection(endpointId: 'ep-a');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final sessionB = nonPoolEngine.getSession('ep-a')!;
      sessionB.activeRequestId = 'req-orphan-20';

      final orphan = SecurityBlock.create(
        index: 2,
        parentBlockHashes: [computeSha256('missing-parent-20')],
        creatorNodeId: 'NODE-A',
        events: [],
        validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
      );

      transportB.clearSentPayloads();
      transportB.simulateIncomingPayload(
        endpointId: 'ep-a',
        bytes: DagGossipCodec.encode(
          DagBlockBatchMessage(
            senderNodeId: 'NODE-A',
            requestId: 'req-orphan-20',
            batchIndex: 1,
            totalBatches: 1,
            blocks: [orphan],
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(nonPoolEngine.totalRemoteBlocksRejected, equals(1));
      expect(ledgerB.getBlock(orphan.blockHash), isNull);

      final rejects = transportB.sentPayloads
          .map((p) => DagGossipCodec.decode(p.bytes).message)
          .whereType<DagRejectMessage>()
          .toList();
      expect(rejects.length, equals(1));
      expect(
        rejects.first.errorCode,
        equals(DagRejectCode.invalidBlockStructure),
      );

      nonPoolEngine.dispose();
    });
  });
}

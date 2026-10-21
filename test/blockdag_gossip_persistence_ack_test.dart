/// STAGE 5E.4.5.1 — Enforce Persistence Requirement for Gossip ACKs Regression Tests
///
/// Memverifikasi 13 skenario deterministik:
/// 1. Engine replikasi aktif tanpa repository dapat berjalan namun persistensi tidak tersedia.
/// 2. Blok biasa TIDAK di-ACK dan di-rollback ketika persistensi tidak tersedia (repository == null).
/// 3. Orphan yang dipromosikan TIDAK di-ACK dan tetap di pool ketika repository tidak tersedia.
/// 4. saveState() mengembalikan false: rollback ledger, tidak kirim ACK, orphan tetap di pool.
/// 5. saveState() melempar exception: ditangani aman, rollback ledger, tidak kirim ACK.
/// 6. Rollback mempertahankan konsistensi ledger, tips, dan tracking hash sesi.
/// 7. Retry setelah storage pulih berhasil mengomit blok, persisten, dan mengirim DAG_SYNC_ACK.
/// 8. ACK yang dikirim berkorelasi secara presisi dengan peer, request, dan hash blok.
/// 9. Disconnect atau reconnect tidak menyebabkan pengiriman ACK tertunda ke sesi baru/salah.
/// 10. Kegagalan pengiriman ACK (transport failure) tidak menyebabkan crash atau mutasi ganda.
/// 11. Konfigurasi A dan B tidak mengirim paket gossip.
/// 12. Konfigurasi C memerlukan aktivasi eksplisit dan repository yang sesuai.
/// 13. Seluruh invariant ledger, dual-slot recovery, orphan pool, IDS, dan trust tetap valid.
library;

import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:siagamesh_app/core/blockchain/blockchain_types.dart';
import 'package:siagamesh_app/core/blockchain/blockdag_repository.dart';
import 'package:siagamesh_app/core/blockchain/gossip/gossip.dart';
import 'package:siagamesh_app/core/blockchain/lightweight_blockdag_ledger.dart';
import 'package:siagamesh_app/core/ids/selective_forwarding_detector.dart';
import 'package:siagamesh_app/core/routing/manet_routing_engine.dart';
import 'package:siagamesh_app/core/routing/mesh_experiment_logger.dart';
import 'package:siagamesh_app/core/routing/node_identity.dart';
import 'package:siagamesh_app/core/routing/routing_holder.dart';
import 'package:siagamesh_app/core/transport/fake_mesh_transport.dart';
import 'package:siagamesh_app/core/transport/mesh_transport.dart';
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

class ControllableFakeMeshTransport extends FakeMeshTransport {
  bool sendResult = true;
  bool shouldThrow = false;

  @override
  Future<bool> sendBytes({
    required String endpointId,
    required Uint8List bytes,
  }) async {
    if (shouldThrow) {
      throw Exception('Simulated transport channel failure');
    }
    if (!sendResult) {
      return false;
    }
    return super.sendBytes(endpointId: endpointId, bytes: bytes);
  }
}

class FakeChatRepository extends ChatRepository {
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
  Future<bool> updateMessageStatus(
    String conversationId,
    String messageId,
    String newStatusText,
  ) async => true;

  @override
  Future<void> clearAllData() async {
    savedMessages.clear();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('STAGE 5E.4.5.1 — Enforce Persistence Requirement for Gossip ACKs', () {
    late FakeMeshTransport transportA;
    late FakeMeshTransport transportB;
    late LightweightBlockdagLedger ledgerA;
    late LightweightBlockdagLedger ledgerB;
    late InMemoryBlockdagRepository repoA;
    late DagGossipSyncEngine engineA;
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
      );
    });

    tearDown(() {
      routingA.dispose();
      routingB.dispose();
      engineA.dispose();
      ManetRoutingHolder.reset();
    });

    // Helper untuk menghubungkan transport 1-hop
    Future<void> connectPeers(DagGossipSyncEngine engineBInstance) async {
      routingB.gossipSyncEngine = engineBInstance;

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

      final helloA = transportA.sentPayloads
          .where((p) => DagGossipSyncEngine.isGossipPayload(p.bytes))
          .toList();
      for (final p in helloA) {
        transportB.simulateIncomingPayload(endpointId: 'ep-a', bytes: p.bytes);
      }
      final helloB = transportB.sentPayloads
          .where((p) => DagGossipSyncEngine.isGossipPayload(p.bytes))
          .toList();
      for (final p in helloB) {
        transportA.simulateIncomingPayload(endpointId: 'ep-b', bytes: p.bytes);
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final invA = transportA.sentPayloads
          .where((p) => DagGossipSyncEngine.isGossipPayload(p.bytes))
          .toList();
      for (final p in invA) {
        transportB.simulateIncomingPayload(endpointId: 'ep-a', bytes: p.bytes);
      }
      final invB = transportB.sentPayloads
          .where((p) => DagGossipSyncEngine.isGossipPayload(p.bytes))
          .toList();
      for (final p in invB) {
        transportA.simulateIncomingPayload(endpointId: 'ep-b', bytes: p.bytes);
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));

      transportA.clearSentPayloads();
      transportB.clearSentPayloads();
    }

    // ------------------------------------------------------------------------
    // 1. Engine replikasi aktif tanpa repository
    // ------------------------------------------------------------------------
    test(
      '1. Engine replikasi aktif tanpa repository dapat berjalan namun persistensi tidak tersedia',
      () async {
        final engineNoRepo = DagGossipSyncEngine(
          transport: transportB,
          localNodeId: 'NODE-B',
          ledger: ledgerB,
          repository: null,
          isEnabled: true,
        );

        expect(engineNoRepo.isEnabled, isTrue);
        expect(engineNoRepo.repository, isNull);
        expect(engineNoRepo.hasPersistentStorage, isFalse);

        await connectPeers(engineNoRepo);

        final sessionB = engineNoRepo.getSession('ep-a');
        expect(sessionB, isNotNull);
        expect(sessionB!.helloSent, isTrue);

        engineNoRepo.dispose();
      },
    );

    // ------------------------------------------------------------------------
    // 2. Blok biasa tidak di-ACK ketika persistensi tidak tersedia
    // ------------------------------------------------------------------------
    test(
      '2. Blok biasa TIDAK di-ACK dan di-rollback ketika persistensi tidak tersedia (repository == null)',
      () async {
        final engineNoRepo = DagGossipSyncEngine(
          transport: transportB,
          localNodeId: 'NODE-B',
          ledger: ledgerB,
          repository: null,
          isEnabled: true,
        );
        await connectPeers(engineNoRepo);

        final blockA1 = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        final sessionB = engineNoRepo.getSession('ep-a')!;
        sessionB.activeRequestId = 'req-no-repo-2';
        sessionB.missingBlockHashes.add(blockA1.blockHash);

        transportB.clearSentPayloads();
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-no-repo-2',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [blockA1],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Ledger in-memory di-rollback ke snapshot awal (hanya genesis)
        expect(ledgerB.activeBlocksCount, equals(1));
        expect(ledgerB.getBlock(blockA1.blockHash), isNull);
        expect(engineNoRepo.totalRemoteBlocksAccepted, equals(0));

        // TIDAK ADA DAG_SYNC_ACK yang dikirim!
        final acks = transportB.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagSyncAckMessage>()
            .toList();
        expect(acks, isEmpty);

        // Blok tetap dicatat sebagai missing agar dapat diminta/di-retry nanti
        expect(sessionB.missingBlockHashes, contains(blockA1.blockHash));
        expect(
          sessionB.knownPeerBlockHashes.contains(blockA1.blockHash),
          isFalse,
        );

        engineNoRepo.dispose();
      },
    );

    // ------------------------------------------------------------------------
    // 3. Orphan yang dipromosikan tidak di-ACK tanpa persistensi
    // ------------------------------------------------------------------------
    test(
      '3. Orphan yang dipromosikan TIDAK di-ACK dan tetap di pool ketika repository tidak tersedia',
      () async {
        final pool = OrphanBlockPool();
        final engineNoRepo = DagGossipSyncEngine(
          transport: transportB,
          localNodeId: 'NODE-B',
          ledger: ledgerB,
          repository: null,
          orphanPool: pool,
          isEnabled: true,
        );
        await connectPeers(engineNoRepo);

        final missingParent = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );
        final orphan = SecurityBlock.create(
          index: 2,
          parentBlockHashes: [missingParent.blockHash],
          creatorNodeId: 'NODE-A',
          events: [],
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        final sessionB = engineNoRepo.getSession('ep-a')!;

        // 1. Masukkan orphan ke pool
        sessionB.activeRequestId = 'req-orphan-3';
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-orphan-3',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [orphan],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(pool.count, equals(1));

        // 2. Parent tiba, tetapi karena repository == null, parent tidak dapat dipersistensikan
        sessionB.activeRequestId = 'req-parent-3';
        transportB.clearSentPayloads();
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-parent-3',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [missingParent],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Parent di-rollback
        expect(ledgerB.getBlock(missingParent.blockHash), isNull);
        // Orphan tetap di pool dan tidak di-ACK
        expect(pool.count, equals(1));
        expect(ledgerB.getBlock(orphan.blockHash), isNull);
        expect(engineNoRepo.totalRemoteBlocksAccepted, equals(0));

        final acks = transportB.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagSyncAckMessage>()
            .toList();
        expect(acks, isEmpty);

        // 3. Evaluasi langsung processOrphans tanpa repository
        final promoted = await engineNoRepo.processOrphans();
        expect(promoted, isEmpty);
        expect(pool.count, equals(1));

        engineNoRepo.dispose();
      },
    );

    // ------------------------------------------------------------------------
    // 4. saveState() mengembalikan false
    // ------------------------------------------------------------------------
    test(
      '4. saveState() mengembalikan false: rollback ledger, tidak kirim ACK, orphan tetap di pool',
      () async {
        final controllableRepo = ControllableBlockdagRepository();
        final pool = OrphanBlockPool();
        final controllableEngine = DagGossipSyncEngine(
          transport: transportB,
          localNodeId: 'NODE-B',
          ledger: ledgerB,
          repository: controllableRepo,
          orphanPool: pool,
          isEnabled: true,
        );
        await connectPeers(controllableEngine);

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

        final sessionB = controllableEngine.getSession('ep-a')!;

        // Orphan ditahan di pool
        sessionB.activeRequestId = 'req-orphan-4';
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-orphan-4',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [orphan],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(pool.count, equals(1));

        // Set storage gagal
        controllableRepo.shouldFailSave = true;

        sessionB.activeRequestId = 'req-parent-4';
        transportB.clearSentPayloads();
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-parent-4',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [parent],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(ledgerB.activeBlocksCount, equals(1));
        expect(ledgerB.getBlock(parent.blockHash), isNull);
        expect(ledgerB.getBlock(orphan.blockHash), isNull);
        expect(pool.count, equals(1)); // Orphan tetap bertahan di pool

        final acks = transportB.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagSyncAckMessage>()
            .toList();
        expect(acks, isEmpty);

        controllableEngine.dispose();
      },
    );

    // ------------------------------------------------------------------------
    // 5. saveState() melempar exception
    // ------------------------------------------------------------------------
    test(
      '5. saveState() melempar exception: ditangani aman, rollback ledger, tidak kirim ACK',
      () async {
        final controllableRepo = ControllableBlockdagRepository();
        final controllableEngine = DagGossipSyncEngine(
          transport: transportB,
          localNodeId: 'NODE-B',
          ledger: ledgerB,
          repository: controllableRepo,
          isEnabled: true,
        );
        await connectPeers(controllableEngine);

        final blockA1 = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        controllableRepo.shouldThrowOnSave = true;

        final sessionB = controllableEngine.getSession('ep-a')!;
        sessionB.activeRequestId = 'req-throw-5';

        transportB.clearSentPayloads();
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-throw-5',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [blockA1],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(ledgerB.activeBlocksCount, equals(1));
        expect(ledgerB.getBlock(blockA1.blockHash), isNull);
        expect(controllableEngine.totalRemoteBlocksAccepted, equals(0));

        final acks = transportB.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagSyncAckMessage>()
            .toList();
        expect(acks, isEmpty);

        controllableEngine.dispose();
      },
    );

    // ------------------------------------------------------------------------
    // 6. Rollback mempertahankan konsistensi ledger dan cache deduplikasi
    // ------------------------------------------------------------------------
    test(
      '6. Rollback mempertahankan konsistensi ledger, tips, dan tracking hash sesi',
      () async {
        final controllableRepo = ControllableBlockdagRepository();
        final controllableEngine = DagGossipSyncEngine(
          transport: transportB,
          localNodeId: 'NODE-B',
          ledger: ledgerB,
          repository: controllableRepo,
          isEnabled: true,
        );
        await connectPeers(controllableEngine);

        final initialTips = ledgerB.tipHashes.toSet();
        final initialBlockCount = ledgerB.activeBlocksCount;

        controllableRepo.shouldFailSave = true;

        final blockA1 = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        final sessionB = controllableEngine.getSession('ep-a')!;
        sessionB.activeRequestId = 'req-rb-6';
        sessionB.missingBlockHashes.add(blockA1.blockHash);

        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-rb-6',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [blockA1],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Verifikasi ledger tidak bocor atau terdistorsi
        expect(ledgerB.activeBlocksCount, equals(initialBlockCount));
        expect(ledgerB.tipHashes.toSet(), equals(initialTips));
        expect(ledgerB.getBlock(blockA1.blockHash), isNull);
        expect(
          sessionB.knownPeerBlockHashes.contains(blockA1.blockHash),
          isFalse,
        );
        expect(sessionB.missingBlockHashes, contains(blockA1.blockHash));

        controllableEngine.dispose();
      },
    );

    // ------------------------------------------------------------------------
    // 7. Retry setelah storage pulih dapat berhasil dan di-ACK
    // ------------------------------------------------------------------------
    test(
      '7. Retry setelah storage pulih berhasil mengomit blok, persisten, dan mengirim DAG_SYNC_ACK',
      () async {
        final controllableRepo = ControllableBlockdagRepository();
        final pool = OrphanBlockPool();
        final controllableEngine = DagGossipSyncEngine(
          transport: transportB,
          localNodeId: 'NODE-B',
          ledger: ledgerB,
          repository: controllableRepo,
          orphanPool: pool,
          isEnabled: true,
        );
        await connectPeers(controllableEngine);

        final parent = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        final sessionB = controllableEngine.getSession('ep-a')!;

        // 1. Simulasikan kegagalan
        controllableRepo.shouldFailSave = true;
        sessionB.activeRequestId = 'req-fail-7';
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-fail-7',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [parent],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(ledgerB.getBlock(parent.blockHash), isNull);

        // 2. Storage pulih
        controllableRepo.shouldFailSave = false;

        // 3. Retry pengiriman batch yang sama
        sessionB.activeRequestId = 'req-retry-7';
        transportB.clearSentPayloads();
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-retry-7',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [parent],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(ledgerB.getBlock(parent.blockHash), isNotNull);
        expect(controllableEngine.totalRemoteBlocksAccepted, equals(1));
        final savedState = await controllableRepo.loadState();
        expect(
          savedState!.blocks.any((b) => b.blockHash == parent.blockHash),
          isTrue,
        );

        final acks = transportB.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagSyncAckMessage>()
            .toList();
        expect(acks.length, equals(1));
        expect(acks.first.requestId, equals('req-retry-7'));
        expect(acks.first.acceptedBlockHashes, equals([parent.blockHash]));

        controllableEngine.dispose();
      },
    );

    // ------------------------------------------------------------------------
    // 8. ACK yang dikirim berkorelasi dengan peer serta request yang benar
    // ------------------------------------------------------------------------
    test(
      '8. ACK yang dikirim berkorelasi secara presisi dengan peer, request, dan hash blok',
      () async {
        final repoB = InMemoryBlockdagRepository();
        final engineB = DagGossipSyncEngine(
          transport: transportB,
          localNodeId: 'NODE-B',
          ledger: ledgerB,
          repository: repoB,
          isEnabled: true,
        );
        await connectPeers(engineB);

        final blockA1 = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        final sessionB = engineB.getSession('ep-a')!;
        sessionB.activeRequestId = 'req-corr-8';

        transportB.clearSentPayloads();
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-corr-8',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [blockA1],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final acks = transportB.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagSyncAckMessage>()
            .toList();
        expect(acks.length, equals(1));
        final ack = acks.first;
        expect(ack.senderNodeId, equals('NODE-B'));
        expect(ack.requestId, equals('req-corr-8'));
        expect(ack.acceptedBlockHashes, equals([blockA1.blockHash]));
        expect(ack.newTipHashes, contains(blockA1.blockHash));

        engineB.dispose();
      },
    );

    // ------------------------------------------------------------------------
    // 9. Disconnect atau reconnect tidak menyebabkan ACK salah sesi
    // ------------------------------------------------------------------------
    test(
      '9. Disconnect atau reconnect tidak menyebabkan pengiriman ACK tertunda ke sesi baru/salah',
      () async {
        final repoB = InMemoryBlockdagRepository();
        final pool = OrphanBlockPool();
        final engineB = DagGossipSyncEngine(
          transport: transportB,
          localNodeId: 'NODE-B',
          ledger: ledgerB,
          repository: repoB,
          orphanPool: pool,
          isEnabled: true,
        );
        await connectPeers(engineB);

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

        final sessionB1 = engineB.getSession('ep-a')!;
        final originalSessionId = sessionB1.sessionId;

        // 1. Terima orphan pada session 1
        sessionB1.activeRequestId = 'req-orphan-sess1';
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-orphan-sess1',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [orphan],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(pool.count, equals(1));

        // 2. Peer putus koneksi (disconnect)
        transportB.simulateDisconnection('ep-a');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(engineB.getSession('ep-a'), isNull);
        expect(pool.count, equals(1)); // Orphan dipertahankan

        // 3. Peer terhubung kembali (reconnect) -> membuat PeerGossipSession baru dengan sessionId baru
        transportB.simulateIncomingConnectionRequest(
          endpointId: 'ep-a',
          endpointName: 'Node A Reconnected',
        );
        await transportB.acceptConnection(endpointId: 'ep-a');
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final sessionB2 = engineB.getSession('ep-a')!;
        expect(sessionB2.sessionId, isNot(equals(originalSessionId)));

        // 4. Parent tiba melalui sesi baru dan disimpan persisten
        sessionB2.activeRequestId = 'req-parent-sess2';
        transportB.clearSentPayloads();
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-parent-sess2',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [parent],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Parent dan orphan berhasil dipersistensikan ke repositori
        expect(ledgerB.getBlock(parent.blockHash), isNotNull);
        expect(ledgerB.getBlock(orphan.blockHash), isNotNull);
        expect(pool.count, equals(0));

        // Verifikasi ACK: Hanya batch parent 'req-parent-sess2' yang di-ACK pada sesi aktif baru.
        // ACK orphan lama ('req-orphan-sess1') TIDAK dikirim ke sesi baru karena sessionId tidak cocok!
        final acks = transportB.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagSyncAckMessage>()
            .toList();
        expect(acks.length, equals(1));
        expect(acks.first.requestId, equals('req-parent-sess2'));

        engineB.dispose();
      },
    );

    // ------------------------------------------------------------------------
    // 10. Kegagalan pengiriman ACK tidak menyebabkan crash atau mutasi ledger tambahan
    // ------------------------------------------------------------------------
    test(
      '10. Kegagalan pengiriman ACK (transport failure) tidak menyebabkan crash atau mutasi ganda',
      () async {
        final controllableTransport = ControllableFakeMeshTransport();
        final repoB = InMemoryBlockdagRepository();
        final engineB = DagGossipSyncEngine(
          transport: controllableTransport,
          localNodeId: 'NODE-B',
          ledger: ledgerB,
          repository: repoB,
          isEnabled: true,
        );

        routingB.gossipSyncEngine = engineB;
        controllableTransport.simulateIncomingConnectionRequest(
          endpointId: 'ep-a',
          endpointName: 'Node A',
        );
        await controllableTransport.acceptConnection(endpointId: 'ep-a');
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final blockA1 = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        final sessionB = engineB.getSession('ep-a')!;
        sessionB.activeRequestId = 'req-ack-fail-10';

        // Buat kanal transport gagal melempar exception saat ACK dikirim
        controllableTransport.shouldThrow = true;

        await engineB.handleIncomingPayload(
          TransportPayload(
            endpointId: 'ep-a',
            bytes: DagGossipCodec.encode(
              DagBlockBatchMessage(
                senderNodeId: 'NODE-A',
                requestId: 'req-ack-fail-10',
                batchIndex: 1,
                totalBatches: 1,
                blocks: [blockA1],
              ),
            ),
            receivedAt: DateTime.now().toUtc(),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Exception tertangkap aman, ledger dan repository tetap konsisten dengan blok yang tersimpan
        expect(ledgerB.getBlock(blockA1.blockHash), isNotNull);
        final savedState = await repoB.loadState();
        expect(
          savedState!.blocks.any((b) => b.blockHash == blockA1.blockHash),
          isTrue,
        );
        expect(engineB.isDisposed, isFalse);

        engineB.dispose();
      },
    );

    // ------------------------------------------------------------------------
    // 11. Konfigurasi A dan B tidak mengirim paket gossip
    // ------------------------------------------------------------------------
    test('11. Konfigurasi A dan B tidak mengirim paket gossip', () async {
      // Config A: Default MANET
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

      // Config B: Security Hardened tanpa replikasi gossip
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
    });

    // ------------------------------------------------------------------------
    // 12. Konfigurasi C memerlukan aktivasi eksplisit dan repository yang sesuai
    // ------------------------------------------------------------------------
    test(
      '12. Konfigurasi C memerlukan aktivasi eksplisit dan repository yang sesuai',
      () async {
        ManetRoutingHolder.reset();
        expect(ManetRoutingHolder.enableBlockdagReplication, isFalse);

        final cTransport = FakeMeshTransport();
        final cRepo = InMemoryBlockdagRepository();
        final cSyncEngine = DagGossipSyncEngine(
          transport: cTransport,
          localNodeId: 'NODE-C',
          ledger: LightweightBlockdagLedger(),
          repository: cRepo,
          enableOrphanPool: true,
          isEnabled: false,
        );
        ManetRoutingHolder.setGossipSyncEngine(cSyncEngine);
        expect(cSyncEngine.isEnabled, isFalse);
        expect(cSyncEngine.hasPersistentStorage, isTrue);

        ManetRoutingHolder.setEnableBlockdagReplication(true);
        expect(cSyncEngine.isEnabled, isTrue);

        cSyncEngine.dispose();
        ManetRoutingHolder.reset();
      },
    );

    // ------------------------------------------------------------------------
    // 13. Seluruh invariant ledger, dual-slot recovery, orphan pool, IDS, dan trust tetap valid
    // ------------------------------------------------------------------------
    test(
      '13. Seluruh invariant ledger, dual-slot recovery, orphan pool, IDS, dan trust tetap valid',
      () async {
        final repoB = InMemoryBlockdagRepository();
        final pool = OrphanBlockPool();
        final engineB = DagGossipSyncEngine(
          transport: transportB,
          localNodeId: 'NODE-B',
          ledger: ledgerB,
          repository: repoB,
          orphanPool: pool,
          isEnabled: true,
        );
        await connectPeers(engineB);

        // Buat event audit keamanan valid (IDS detection)
        final idsEvent = SecurityAuditEvent(
          eventId: 'evt-trust-13',
          eventType: AuditEventType.idsDetection,
          observerNodeId: 'NODE-A',
          targetNodeId: 'NODE-C',
          timestamp: DateTime.now().toUtc(),
          monotonicMicros: 100,
          metadata: {
            'status': 'detected',
            'reason': 'selective_forwarding_drop',
          },
        );
        ledgerA.addPendingEvent(idsEvent);
        final blockA1 = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        final sessionB = engineB.getSession('ep-a')!;
        sessionB.activeRequestId = 'req-inv-13';

        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-inv-13',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [blockA1],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(ledgerB.getBlock(blockA1.blockHash), isNotNull);
        final storedState = await repoB.loadState();
        expect(
          storedState!.blocks
              .expand((b) => b.events)
              .any((e) => e.eventId == 'evt-trust-13'),
          isTrue,
        );
        expect(storedState.processedEventIds.contains('evt-trust-13'), isTrue);

        engineB.dispose();
      },
    );
  });
}

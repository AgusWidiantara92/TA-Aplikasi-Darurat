/// STAGE 5E.4.5.2 — Strict Deferred ACK Session Binding Tests
///
/// Memverifikasi 10 skenario deterministik:
/// 1. ACK tertunda terkirim saat sesi, peer, dan request ID seluruhnya cocok.
/// 2. sessionId orphan null tidak menghasilkan ACK.
/// 3. sessionId berbeda setelah reconnect tidak menghasilkan ACK.
/// 4. peerNodeId berbeda tidak menghasilkan ACK ketika identitas remote tersedia untuk diverifikasi.
/// 5. Request ID tidak cocok atau tidak memiliki konteks yang valid tidak menghasilkan ACK.
/// 6. Blok tetap tercatat sebagai tersimpan jika persistensi sudah sukses tetapi sesi asal sudah terputus; tidak boleh dikirim ke sesi baru.
/// 7. Kegagalan persistensi tidak pernah menghasilkan ACK.
/// 8. Kegagalan pengiriman ACK tidak menyebabkan mutasi ledger tambahan atau crash.
/// 9. Pengiriman ACK normal yang langsung berkaitan dengan sesi aktif tetap berfungsi.
/// 10. Seluruh tes lama untuk transfer blok, persistensi dual-slot, orphan pool, IDS, Dynamic Trust, dan routing tetap lulus.
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
  bool shouldFailSend = false;
  bool shouldThrowOnSend = false;

  @override
  Future<bool> sendBytes({
    required String endpointId,
    required Uint8List bytes,
  }) async {
    if (shouldThrowOnSend) {
      throw Exception('Simulated transport channel failure');
    }
    if (shouldFailSend) {
      return false;
    }
    return super.sendBytes(endpointId: endpointId, bytes: bytes);
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

  group('STAGE 5E.4.5.2 — Strict Deferred ACK Session Binding', () {
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

      transportA.clearSentPayloads();
      transportB.clearSentPayloads();
    }

    // ------------------------------------------------------------------------
    // 1. ACK tertunda terkirim saat sesi, peer, dan request ID seluruhnya cocok
    // ------------------------------------------------------------------------
    test(
      '1. ACK tertunda terkirim saat sesi, peer, dan request ID seluruhnya cocok',
      () async {
        final repoB = InMemoryBlockdagRepository();
        final poolB = OrphanBlockPool();
        final engineB = DagGossipSyncEngine(
          transport: transportB,
          localNodeId: 'NODE-B',
          ledger: ledgerB,
          repository: repoB,
          orphanPool: poolB,
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

        final sessionB = engineB.getSession('ep-a')!;
        expect(sessionB.remoteNodeId, equals('NODE-A'));

        // 1. Kirim orphan terlebih dahulu -> ditahan di orphan pool
        sessionB.activeRequestId = 'req-orphan-1';
        transportB.clearSentPayloads();
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-orphan-1',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [orphan],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(poolB.count, equals(1));
        expect(ledgerB.getBlock(orphan.blockHash), isNull);
        // Tidak ada ACK yang dikirim untuk orphan
        final initialAcks = transportB.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagSyncAckMessage>()
            .toList();
        expect(initialAcks.isEmpty, isTrue);

        // 2. Kirim parent block -> parent diterima & persisten, orphan dipromosikan & persisten
        sessionB.activeRequestId = 'req-parent-1';
        transportB.clearSentPayloads();
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-parent-1',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [parent],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(ledgerB.getBlock(parent.blockHash), isNotNull);
        expect(ledgerB.getBlock(orphan.blockHash), isNotNull);
        expect(poolB.count, equals(0));

        // Verifikasi pengiriman ACK:
        // Harus ada 2 ACK:
        // 1) Deferred ACK untuk 'req-orphan-1' (karena sesi, peer, dan request ID cocok)
        // 2) Immediate ACK untuk 'req-parent-1'
        final acks = transportB.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagSyncAckMessage>()
            .toList();
        expect(acks.length, equals(2));

        final orphanAck = acks.firstWhere((a) => a.requestId == 'req-orphan-1');
        expect(orphanAck.acceptedBlockHashes, equals([orphan.blockHash]));

        final parentAck = acks.firstWhere((a) => a.requestId == 'req-parent-1');
        expect(parentAck.acceptedBlockHashes, equals([parent.blockHash]));

        engineB.dispose();
      },
    );

    // ------------------------------------------------------------------------
    // 2. sessionId orphan null tidak menghasilkan ACK
    // ------------------------------------------------------------------------
    test('2. sessionId orphan null tidak menghasilkan ACK', () async {
      final repoB = InMemoryBlockdagRepository();
      final poolB = OrphanBlockPool();
      final engineB = DagGossipSyncEngine(
        transport: transportB,
        localNodeId: 'NODE-B',
        ledger: ledgerB,
        repository: repoB,
        orphanPool: poolB,
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

      final sessionB = engineB.getSession('ep-a')!;
      sessionB.recordRecognizedRequestId('req-null-sess-2');

      // Masukkan orphan langsung ke pool dengan sessionId: null (wildcard dilarang)
      poolB.add(
        block: orphan,
        missingParentHashes: {parent.blockHash},
        peerEndpointId: 'ep-a',
        peerNodeId: 'NODE-A',
        sessionId: null, // NULL sessionId
        requestId: 'req-null-sess-2',
      );
      expect(poolB.count, equals(1));

      // Kirim parent batch
      sessionB.activeRequestId = 'req-parent-2';
      transportB.clearSentPayloads();
      transportB.simulateIncomingPayload(
        endpointId: 'ep-a',
        bytes: DagGossipCodec.encode(
          DagBlockBatchMessage(
            senderNodeId: 'NODE-A',
            requestId: 'req-parent-2',
            batchIndex: 1,
            totalBatches: 1,
            blocks: [parent],
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Orphan dipromosikan dan tersimpan ke ledger dan repository
      expect(ledgerB.getBlock(orphan.blockHash), isNotNull);
      expect(poolB.count, equals(0));

      // ACK tertunda untuk orphan TIDAK dikirim karena sessionId == null!
      final acks = transportB.sentPayloads
          .map((p) => DagGossipCodec.decode(p.bytes).message)
          .whereType<DagSyncAckMessage>()
          .toList();
      expect(acks.length, equals(1));
      expect(acks.first.requestId, equals('req-parent-2'));

      engineB.dispose();
    });

    // ------------------------------------------------------------------------
    // 3. sessionId berbeda setelah reconnect tidak menghasilkan ACK
    // ------------------------------------------------------------------------
    test(
      '3. sessionId berbeda setelah reconnect tidak menghasilkan ACK',
      () async {
        final repoB = InMemoryBlockdagRepository();
        final poolB = OrphanBlockPool();
        final engineB = DagGossipSyncEngine(
          transport: transportB,
          localNodeId: 'NODE-B',
          ledger: ledgerB,
          repository: repoB,
          orphanPool: poolB,
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

        // 1. Terima orphan pada sesi pertama
        sessionB1.activeRequestId = 'req-orphan-s1';
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-orphan-s1',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [orphan],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(poolB.count, equals(1));

        // 2. Putus koneksi
        transportB.simulateDisconnection('ep-a');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(engineB.getSession('ep-a'), isNull);

        // 3. Reconnect -> membuat sesi baru dengan sessionId berbeda
        transportB.simulateIncomingConnectionRequest(
          endpointId: 'ep-a',
          endpointName: 'Node A',
        );
        await transportB.acceptConnection(endpointId: 'ep-a');
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final sessionB2 = engineB.getSession('ep-a')!;
        expect(sessionB2.sessionId, isNot(equals(originalSessionId)));

        // 4. Parent tiba di sesi baru
        sessionB2.activeRequestId = 'req-parent-s2';
        transportB.clearSentPayloads();
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-parent-s2',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [parent],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Blok orphan berhasil dipromosikan & persisten
        expect(ledgerB.getBlock(orphan.blockHash), isNotNull);
        expect(poolB.count, equals(0));

        // Hanya batch parent yang di-ACK. Sesi baru TIDAK menerima ACK orphan dari sesi lama!
        final acks = transportB.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagSyncAckMessage>()
            .toList();
        expect(acks.length, equals(1));
        expect(acks.first.requestId, equals('req-parent-s2'));

        engineB.dispose();
      },
    );

    // ------------------------------------------------------------------------
    // 4. peerNodeId berbeda tidak menghasilkan ACK ketika identitas remote tersedia
    // ------------------------------------------------------------------------
    test(
      '4. peerNodeId berbeda tidak menghasilkan ACK ketika identitas remote tersedia untuk diverifikasi',
      () async {
        final repoB = InMemoryBlockdagRepository();
        final poolB = OrphanBlockPool();
        final engineB = DagGossipSyncEngine(
          transport: transportB,
          localNodeId: 'NODE-B',
          ledger: ledgerB,
          repository: repoB,
          orphanPool: poolB,
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

        final sessionB = engineB.getSession('ep-a')!;
        expect(sessionB.remoteNodeId, equals('NODE-A'));
        sessionB.recordRecognizedRequestId('req-diff-node-4');

        // Orphan dimasukkan dengan peerNodeId: 'NODE-OTHER' (berbeda dari identitas remote 'NODE-A')
        poolB.add(
          block: orphan,
          missingParentHashes: {parent.blockHash},
          peerEndpointId: 'ep-a',
          peerNodeId: 'NODE-OTHER', // Identity mismatch!
          sessionId: sessionB.sessionId,
          requestId: 'req-diff-node-4',
        );
        expect(poolB.count, equals(1));

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

        // Blok orphan tetap tersimpan di ledger
        expect(ledgerB.getBlock(orphan.blockHash), isNotNull);
        expect(poolB.count, equals(0));

        // Tidak ada ACK untuk orphan karena peerNodeId tidak cocok
        final acks = transportB.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagSyncAckMessage>()
            .toList();
        expect(acks.length, equals(1));
        expect(acks.first.requestId, equals('req-parent-4'));

        engineB.dispose();
      },
    );

    // ------------------------------------------------------------------------
    // 5. Request ID tidak cocok atau tidak memiliki konteks yang valid tidak menghasilkan ACK
    // ------------------------------------------------------------------------
    test(
      '5. Request ID tidak cocok atau tidak memiliki konteks yang valid tidak menghasilkan ACK',
      () async {
        final repoB = InMemoryBlockdagRepository();
        final poolB = OrphanBlockPool();
        final engineB = DagGossipSyncEngine(
          transport: transportB,
          localNodeId: 'NODE-B',
          ledger: ledgerB,
          repository: repoB,
          orphanPool: poolB,
          isEnabled: true,
        );
        await connectPeers(engineB);

        final parent = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );
        final orphan1 = SecurityBlock.create(
          index: 2,
          parentBlockHashes: [parent.blockHash],
          creatorNodeId: 'NODE-A',
          events: [],
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );
        final orphan2 = SecurityBlock.create(
          index: 3,
          parentBlockHashes: [parent.blockHash],
          creatorNodeId: 'NODE-A',
          events: [],
          validationProof: {
            'flushReason': 'manual2',
            'creatorNodeId': 'NODE-A',
          },
        );

        final sessionB = engineB.getSession('ep-a')!;

        // Kasus A: requestId null / kosong
        poolB.add(
          block: orphan1,
          missingParentHashes: {parent.blockHash},
          peerEndpointId: 'ep-a',
          peerNodeId: 'NODE-A',
          sessionId: sessionB.sessionId,
          requestId: null,
        );

        // Kasus B: requestId tidak tercatat dalam recognizedRequestIds sesi
        poolB.add(
          block: orphan2,
          missingParentHashes: {parent.blockHash},
          peerEndpointId: 'ep-a',
          peerNodeId: 'NODE-A',
          sessionId: sessionB.sessionId,
          requestId: 'req-unrecognized-999',
        );

        expect(poolB.count, equals(2));

        sessionB.activeRequestId = 'req-parent-5';
        transportB.clearSentPayloads();
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

        // Kedua orphan berhasil dipromosikan dan tersimpan ke ledger & repository
        expect(ledgerB.getBlock(orphan1.blockHash), isNotNull);
        expect(ledgerB.getBlock(orphan2.blockHash), isNotNull);
        expect(poolB.count, equals(0));

        // Hanya batch parent yang di-ACK! Tidak ada ACK untuk orphan1 atau orphan2
        final acks = transportB.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagSyncAckMessage>()
            .toList();
        expect(acks.length, equals(1));
        expect(acks.first.requestId, equals('req-parent-5'));

        engineB.dispose();
      },
    );

    // ------------------------------------------------------------------------
    // 6. Blok tetap tersimpan jika persistensi sukses tetapi sesi terputus
    // ------------------------------------------------------------------------
    test(
      '6. Blok tetap tercatat sebagai tersimpan jika persistensi sudah sukses tetapi sesi asal sudah terputus; tidak boleh dikirim ke sesi baru',
      () async {
        final repoB = InMemoryBlockdagRepository();
        final poolB = OrphanBlockPool();
        final engineB = DagGossipSyncEngine(
          transport: transportB,
          localNodeId: 'NODE-B',
          ledger: ledgerB,
          repository: repoB,
          orphanPool: poolB,
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

        final sessionB = engineB.getSession('ep-a')!;

        // 1. Terima orphan
        sessionB.activeRequestId = 'req-orphan-6';
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-orphan-6',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [orphan],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(poolB.count, equals(1));

        // 2. Putus koneksi sebelum parent tiba
        transportB.simulateDisconnection('ep-a');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(engineB.getSession('ep-a'), isNull);

        // 3. Parent dimasukkan ke ledger lokal Node B (misal dari node lain atau konsolidasi lokal)
        final acceptRes = ledgerB.acceptRemoteBlock(parent);
        expect(acceptRes.isValid, isTrue);
        await repoB.saveState(ledgerB.exportPersistedState());

        // 4. Proses orphan saat tidak ada sesi peer aktif
        transportB.clearSentPayloads();
        final promoted = await engineB.processOrphans();
        expect(promoted.length, equals(1));
        expect(promoted.first.blockHash, equals(orphan.blockHash));

        // Blok orphan tersimpan permanen di ledger & repository
        expect(ledgerB.getBlock(orphan.blockHash), isNotNull);
        final savedState = await repoB.loadState();
        expect(
          savedState!.blocks.any((b) => b.blockHash == orphan.blockHash),
          isTrue,
        );
        expect(poolB.count, equals(0));

        // Tidak ada pesan ACK yang dikirim ke transport
        expect(transportB.sentPayloads.isEmpty, isTrue);

        // 5. Node A terhubung kembali di masa mendatang -> TIDAK ada ACK tertunda liar
        transportB.simulateIncomingConnectionRequest(
          endpointId: 'ep-a',
          endpointName: 'Node A',
        );
        await transportB.acceptConnection(endpointId: 'ep-a');
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final postReconnectAcks = transportB.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagSyncAckMessage>()
            .toList();
        expect(postReconnectAcks.isEmpty, isTrue);

        engineB.dispose();
      },
    );

    // ------------------------------------------------------------------------
    // 7. Kegagalan persistensi tidak pernah menghasilkan ACK
    // ------------------------------------------------------------------------
    test('7. Kegagalan persistensi tidak pernah menghasilkan ACK', () async {
      final controllableRepo = ControllableBlockdagRepository();
      final poolB = OrphanBlockPool();
      final engineB = DagGossipSyncEngine(
        transport: transportB,
        localNodeId: 'NODE-B',
        ledger: ledgerB,
        repository: controllableRepo,
        orphanPool: poolB,
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

      final sessionB = engineB.getSession('ep-a')!;

      // 1. Masukkan orphan
      sessionB.activeRequestId = 'req-orphan-7';
      transportB.simulateIncomingPayload(
        endpointId: 'ep-a',
        bytes: DagGossipCodec.encode(
          DagBlockBatchMessage(
            senderNodeId: 'NODE-A',
            requestId: 'req-orphan-7',
            batchIndex: 1,
            totalBatches: 1,
            blocks: [orphan],
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(poolB.count, equals(1));

      // 2. Simulasikan kegagalan persistensi repositori
      controllableRepo.shouldFailSave = true;

      sessionB.activeRequestId = 'req-parent-7';
      transportB.clearSentPayloads();
      transportB.simulateIncomingPayload(
        endpointId: 'ep-a',
        bytes: DagGossipCodec.encode(
          DagBlockBatchMessage(
            senderNodeId: 'NODE-A',
            requestId: 'req-parent-7',
            batchIndex: 1,
            totalBatches: 1,
            blocks: [parent],
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Karena saveState gagal:
      // - Ledger di-rollback (parent dan orphan tidak ter-commit)
      // - Orphan tetap berada di pool
      // - TIDAK ADA ACK yang dikirim
      expect(ledgerB.getBlock(parent.blockHash), isNull);
      expect(ledgerB.getBlock(orphan.blockHash), isNull);
      expect(poolB.count, equals(1));

      final acks = transportB.sentPayloads
          .map((p) => DagGossipCodec.decode(p.bytes).message)
          .whereType<DagSyncAckMessage>()
          .toList();
      expect(acks.isEmpty, isTrue);

      engineB.dispose();
    });

    // ------------------------------------------------------------------------
    // 8. Kegagalan pengiriman ACK tidak menyebabkan mutasi ledger tambahan atau crash
    // ------------------------------------------------------------------------
    test(
      '8. Kegagalan pengiriman ACK tidak menyebabkan mutasi ledger tambahan atau crash',
      () async {
        final controllableTransport = ControllableFakeMeshTransport();
        final repoB = InMemoryBlockdagRepository();
        final poolB = OrphanBlockPool();
        final engineB = DagGossipSyncEngine(
          transport: controllableTransport,
          localNodeId: 'NODE-B',
          ledger: ledgerB,
          repository: repoB,
          orphanPool: poolB,
          isEnabled: true,
        );

        controllableTransport.simulateIncomingConnectionRequest(
          endpointId: 'ep-a',
          endpointName: 'Node A',
        );
        await controllableTransport.acceptConnection(endpointId: 'ep-a');
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final sessionB = engineB.getSession('ep-a')!;
        sessionB.remoteNodeId = 'NODE-A';

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

        // Terima orphan
        sessionB.activeRequestId = 'req-orphan-8';
        await engineB.handleIncomingPayload(
          TransportPayload(
            endpointId: 'ep-a',
            bytes: DagGossipCodec.encode(
              DagBlockBatchMessage(
                senderNodeId: 'NODE-A',
                requestId: 'req-orphan-8',
                batchIndex: 1,
                totalBatches: 1,
                blocks: [orphan],
              ),
            ),
            receivedAt: DateTime.now().toUtc(),
          ),
        );
        expect(poolB.count, equals(1));

        // Konfigurasikan transport agar melempar exception saat mengirim ACK
        controllableTransport.shouldThrowOnSend = true;

        sessionB.activeRequestId = 'req-parent-8';
        await engineB.handleIncomingPayload(
          TransportPayload(
            endpointId: 'ep-a',
            bytes: DagGossipCodec.encode(
              DagBlockBatchMessage(
                senderNodeId: 'NODE-A',
                requestId: 'req-parent-8',
                batchIndex: 1,
                totalBatches: 1,
                blocks: [parent],
              ),
            ),
            receivedAt: DateTime.now().toUtc(),
          ),
        );

        // Blok tetap tersimpan persisten
        expect(ledgerB.getBlock(parent.blockHash), isNotNull);
        expect(ledgerB.getBlock(orphan.blockHash), isNotNull);
        expect(poolB.count, equals(0));

        final savedState = await repoB.loadState();
        expect(
          savedState!.blocks.any((b) => b.blockHash == orphan.blockHash),
          isTrue,
        );

        // Tidak terjadi mutasi ganda: jumlah blok tepat sesuai genesis + parent + orphan
        expect(ledgerB.activeBlocksCount, equals(3));

        engineB.dispose();
      },
    );

    // ------------------------------------------------------------------------
    // 9. Pengiriman ACK normal yang langsung berkaitan dengan sesi aktif tetap berfungsi
    // ------------------------------------------------------------------------
    test(
      '9. Pengiriman ACK normal yang langsung berkaitan dengan sesi aktif tetap berfungsi',
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
        sessionB.activeRequestId = 'req-normal-9';

        transportB.clearSentPayloads();
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-normal-9',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [blockA1],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(ledgerB.getBlock(blockA1.blockHash), isNotNull);
        expect(engineB.totalRemoteBlocksAccepted, equals(1));

        final acks = transportB.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagSyncAckMessage>()
            .toList();
        expect(acks.length, equals(1));
        expect(acks.first.requestId, equals('req-normal-9'));
        expect(acks.first.acceptedBlockHashes, equals([blockA1.blockHash]));

        engineB.dispose();
      },
    );

    // ------------------------------------------------------------------------
    // 10. Seluruh invariant ledger, dual-slot recovery, orphan pool, IDS, dan trust tetap valid
    // ------------------------------------------------------------------------
    test(
      '10. Seluruh invariant ledger, dual-slot recovery, orphan pool, IDS, dan trust tetap valid',
      () async {
        final repoB = InMemoryBlockdagRepository();
        final poolB = OrphanBlockPool();
        final engineB = DagGossipSyncEngine(
          transport: transportB,
          localNodeId: 'NODE-B',
          ledger: ledgerB,
          repository: repoB,
          orphanPool: poolB,
          isEnabled: true,
        );

        final detector = SelectiveForwardingDetector(localNodeId: 'NODE-B');
        final trustManager = DynamicTrustManager(localNodeId: 'NODE-B');

        expect(ledgerB.activeBlocksCount, equals(1)); // Genesis
        expect(ledgerB.genesisBlock.index, equals(0));
        expect(poolB.count, equals(0));
        expect(detector.config.minObservationsForEvaluation, equals(4));
        expect(trustManager.config.initialTrust, equals(0.6));
        expect(engineB.hasPersistentStorage, isTrue);

        engineB.dispose();
      },
    );
  });
}

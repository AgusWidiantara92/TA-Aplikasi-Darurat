/// STAGE 5E.4.6 — Bounded Periodic Gossip Reconciliation Integration Tests
///
/// Memverifikasi 14 skenario deterministik sesuai spesifikasi:
/// 1. Scheduler tidak berjalan sebelum fitur diaktifkan.
/// 2. Konfigurasi A dan B tidak mengirim paket gossip.
/// 3. Konfigurasi C mengirim inventaris periodik hanya setelah aktivasi eksplisit.
/// 4. Satu tick menghasilkan paling banyak satu rekonsiliasi aktif per sesi.
/// 5. Inventaris baru memicu penanganan selisih inventaris.
/// 6. Inventaris identik tidak memicu rangkaian transfer berulang.
/// 7. Kegagalan sendBytes() memulai backoff.
/// 8. Kegagalan berulang tidak menghasilkan retry tanpa batas.
/// 9. Rekonsiliasi berhasil memulihkan keadaan backoff sesuai kebijakan.
/// 10. Disconnect membatalkan penjadwalan untuk sesi lama.
/// 11. Reconnect membuat sesi baru tanpa menggunakan konteks request atau ACK sesi sebelumnya.
/// 12. Disable, dispose, dan reset membersihkan semua resource penjadwalan.
/// 13. Operasi scheduler tidak menggandakan request blok yang masih aktif.
/// 14. Kegagalan persistensi tetap tidak menghasilkan ACK sukses.
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

  InMemoryBlockdagRepository({BlockdagPersistedState? initialState})
    : _state = initialState;

  @override
  bool get lastLoadCorrupted => false;

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

  ControllableBlockdagRepository({BlockdagPersistedState? initialState})
    : _state = initialState;

  @override
  bool get lastLoadCorrupted => false;

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
  Future<void> clearAllData() async {
    savedMessages.clear();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('STAGE 5E.4.6 — Bounded Periodic Gossip Reconciliation', () {
    late ControllableFakeMeshTransport transportA;
    late ControllableFakeMeshTransport transportB;
    late LightweightBlockdagLedger ledgerA;
    late LightweightBlockdagLedger ledgerB;
    late InMemoryBlockdagRepository repoA;
    late InMemoryBlockdagRepository repoB;
    late FakeChatRepository chatRepoA;
    late FakeChatRepository chatRepoB;
    late MeshExperimentLogger loggerA;
    late MeshExperimentLogger loggerB;
    late ManetRoutingEngine routingA;
    late ManetRoutingEngine routingB;
    late DateTime fakeCurrentTime;

    DateTime fakeNow() => fakeCurrentTime;

    setUp(() {
      fakeCurrentTime = DateTime.utc(2026, 10, 19, 12, 0, 0);
      transportA = ControllableFakeMeshTransport();
      transportB = ControllableFakeMeshTransport();
      ledgerA = LightweightBlockdagLedger();
      ledgerB = LightweightBlockdagLedger();
      repoA = InMemoryBlockdagRepository();
      repoB = InMemoryBlockdagRepository();
      chatRepoA = FakeChatRepository();
      chatRepoB = FakeChatRepository();
      loggerA = MeshExperimentLogger();
      loggerB = MeshExperimentLogger();

      routingA = ManetRoutingEngine(
        transport: transportA,
        identityManager: NodeIdentityManager(),
        repository: chatRepoA,
        experimentLogger: loggerA,
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
      ManetRoutingHolder.reset();
    });

    /// Helper untuk menghubungkan Peer A dan Peer B serta menyelesaikan handshake awal.
    Future<void> connectAndHandshake(
      DagGossipSyncEngine engineA,
      DagGossipSyncEngine engineB,
    ) async {
      routingA.gossipSyncEngine = engineA;
      routingB.gossipSyncEngine = engineB;

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

      // Kirim DAG_HELLO A ke B
      final helloA = transportA.sentPayloads
          .where((p) => DagGossipSyncEngine.isGossipPayload(p.bytes))
          .toList();
      for (final p in helloA) {
        transportB.simulateIncomingPayload(endpointId: 'ep-a', bytes: p.bytes);
      }

      // Kirim DAG_HELLO B ke A
      final helloB = transportB.sentPayloads
          .where((p) => DagGossipSyncEngine.isGossipPayload(p.bytes))
          .toList();
      for (final p in helloB) {
        transportA.simulateIncomingPayload(endpointId: 'ep-b', bytes: p.bytes);
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Saling alirkan balasan DAG_INV jika ada
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
    // 1. Scheduler tidak berjalan sebelum fitur diaktifkan
    // ------------------------------------------------------------------------
    test('1. Scheduler tidak berjalan sebelum fitur diaktifkan', () async {
      final engine = DagGossipSyncEngine(
        transport: transportA,
        localNodeId: 'NODE-A',
        ledger: ledgerA,
        repository: repoA,
        isEnabled: false, // Default: replication nonaktif
        nowProvider: fakeNow,
      );

      expect(engine.isEnabled, isFalse);
      expect(engine.scheduler.isRunning, isFalse);

      // Jalankan tick secara manual: tidak boleh mengirim apa pun
      await engine.tickPeriodicReconciliation(fakeNow());
      expect(transportA.sentPayloads, isEmpty);
      expect(engine.totalPeriodicInvSent, equals(0));
      expect(engine.totalPeriodicReconcileAttempts, equals(0));

      engine.dispose();
    });

    // ------------------------------------------------------------------------
    // 2. Konfigurasi A dan B tidak mengirim paket gossip
    // ------------------------------------------------------------------------
    test('2. Konfigurasi A dan B tidak mengirim paket gossip', () async {
      // Konfigurasi A (Baseline)
      ManetRoutingHolder.reset();
      ManetRoutingHolder.setInstance(routingA);
      expect(ManetRoutingHolder.enableBlockdagReplication, isFalse);

      transportA.clearSentPayloads();
      transportA.simulateIncomingConnectionRequest(
        endpointId: 'ep-peer',
        endpointName: 'Peer Node',
      );
      await transportA.acceptConnection(endpointId: 'ep-peer');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Nol paket gossip pada Konfigurasi A
      expect(
        transportA.sentPayloads.any(
          (p) => DagGossipSyncEngine.isGossipPayload(p.bytes),
        ),
        isFalse,
      );

      // Konfigurasi B (MANET + IDS + Dynamic Trust)
      ManetRoutingHolder.setIdsDetector(
        SelectiveForwardingDetector(localNodeId: 'NODE-A'),
      );
      ManetRoutingHolder.setTrustManager(
        DynamicTrustManager(localNodeId: 'NODE-A'),
      );
      expect(ManetRoutingHolder.enableBlockdagReplication, isFalse);

      transportA.clearSentPayloads();
      transportA.simulateIncomingConnectionRequest(
        endpointId: 'ep-peer-b',
        endpointName: 'Peer Node B',
      );
      await transportA.acceptConnection(endpointId: 'ep-peer-b');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Nol paket gossip pada Konfigurasi B
      expect(
        transportA.sentPayloads.any(
          (p) => DagGossipSyncEngine.isGossipPayload(p.bytes),
        ),
        isFalse,
      );
    });

    // ------------------------------------------------------------------------
    // 3. Konfigurasi C mengirim inventaris periodik hanya setelah aktivasi eksplisit
    // ------------------------------------------------------------------------
    test(
      '3. Konfigurasi C mengirim inventaris periodik hanya setelah aktivasi eksplisit',
      () async {
        final engineA = DagGossipSyncEngine(
          transport: transportA,
          localNodeId: 'NODE-A',
          ledger: ledgerA,
          repository: repoA,
          isEnabled: false,
          periodicConfig: const PeriodicGossipConfig(
            interval: Duration(seconds: 30),
            jitterRange: Duration.zero,
            autoStartTimer: false,
          ),
          nowProvider: fakeNow,
        );

        final engineB = DagGossipSyncEngine(
          transport: transportB,
          localNodeId: 'NODE-B',
          ledger: ledgerB,
          repository: repoB,
          isEnabled: false,
          periodicConfig: const PeriodicGossipConfig(
            interval: Duration(seconds: 30),
            jitterRange: Duration.zero,
            autoStartTimer: false,
          ),
          nowProvider: fakeNow,
        );

        ManetRoutingHolder.setGossipSyncEngine(engineA);
        ManetRoutingHolder.setEnableBlockdagReplication(true);
        expect(engineA.isEnabled, isTrue);

        engineB.isEnabled = true;
        await connectAndHandshake(engineA, engineB);

        transportA.clearSentPayloads();

        // Sebelum interval 30 detik: tick tidak mengirim paket periodik
        fakeCurrentTime = fakeCurrentTime.add(const Duration(seconds: 15));
        await engineA.tickPeriodicReconciliation(fakeCurrentTime);
        expect(transportA.sentPayloads, isEmpty);
        expect(engineA.totalPeriodicInvSent, equals(0));

        // Setelah interval 30 detik: tick memicu pengiriman DAG_INV periodik
        fakeCurrentTime = fakeCurrentTime.add(const Duration(seconds: 16));
        await engineA.tickPeriodicReconciliation(fakeCurrentTime);

        expect(engineA.totalPeriodicInvSent, equals(1));
        final sentInvs = transportA.sentPayloads
            .where((p) => DagGossipSyncEngine.isGossipPayload(p.bytes))
            .toList();
        expect(sentInvs.length, equals(1));

        final decoded = DagGossipCodec.decode(sentInvs.first.bytes);
        expect(decoded.isSuccess, isTrue);
        expect(decoded.message?.type, equals(DagGossipMessageType.inv));

        engineA.dispose();
        engineB.dispose();
      },
    );

    // ------------------------------------------------------------------------
    // 4. Satu tick menghasilkan paling banyak satu rekonsiliasi aktif per sesi
    // ------------------------------------------------------------------------
    test(
      '4. Satu tick menghasilkan paling banyak satu rekonsiliasi aktif per sesi',
      () async {
        final engineA = DagGossipSyncEngine(
          transport: transportA,
          localNodeId: 'NODE-A',
          ledger: ledgerA,
          repository: repoA,
          isEnabled: true,
          periodicConfig: const PeriodicGossipConfig(
            interval: Duration(seconds: 30),
            jitterRange: Duration.zero,
            autoStartTimer: false,
          ),
          nowProvider: fakeNow,
        );
        final engineB = DagGossipSyncEngine(
          transport: transportB,
          localNodeId: 'NODE-B',
          ledger: ledgerB,
          repository: repoB,
          isEnabled: true,
          periodicConfig: const PeriodicGossipConfig(
            interval: Duration(seconds: 30),
            jitterRange: Duration.zero,
            autoStartTimer: false,
          ),
          nowProvider: fakeNow,
        );

        await connectAndHandshake(engineA, engineB);

        final session = engineA.getSession('ep-b')!;
        expect(session.isReconciling, isFalse);

        // Simulasikan operasi rekonsiliasi yang sedang aktif berjalan
        session.isReconciling = true;

        fakeCurrentTime = fakeCurrentTime.add(const Duration(seconds: 35));
        final triggered = await engineA.reconcilePeer('ep-b', fakeCurrentTime);

        // Rekonsiliasi konkuren ditolak
        expect(triggered, isFalse);
        expect(engineA.totalPeriodicReconcileAttempts, equals(0));

        session.isReconciling = false;
        engineA.dispose();
        engineB.dispose();
      },
    );

    // ------------------------------------------------------------------------
    // 5. Inventaris baru memicu penanganan selisih inventaris
    // ------------------------------------------------------------------------
    test('5. Inventaris baru memicu penanganan selisih inventaris', () async {
      final engineA = DagGossipSyncEngine(
        transport: transportA,
        localNodeId: 'NODE-A',
        ledger: ledgerA,
        repository: repoA,
        isEnabled: true,
        periodicConfig: const PeriodicGossipConfig(
          interval: Duration(seconds: 30),
          jitterRange: Duration.zero,
          autoStartTimer: false,
        ),
        nowProvider: fakeNow,
      );
      final engineB = DagGossipSyncEngine(
        transport: transportB,
        localNodeId: 'NODE-B',
        ledger: ledgerB,
        repository: repoB,
        isEnabled: true,
        periodicConfig: const PeriodicGossipConfig(
          interval: Duration(seconds: 30),
          jitterRange: Duration.zero,
          autoStartTimer: false,
        ),
        nowProvider: fakeNow,
      );

      await connectAndHandshake(engineA, engineB);

      // Node B membuat blok baru
      final blockB1 = ledgerB.createBlock(
        creatorNodeId: 'NODE-B',
        validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-B'},
      );
      await repoB.saveState(ledgerB.exportPersistedState());

      expect(ledgerA.getBlock(blockB1.blockHash), isNull);

      // Node B mengeksekusi tick periodik setelah 30 detik
      fakeCurrentTime = fakeCurrentTime.add(const Duration(seconds: 30));
      transportB.clearSentPayloads();
      await engineB.tickPeriodicReconciliation(fakeCurrentTime);

      final invPayloads = transportB.sentPayloads
          .where((p) => DagGossipSyncEngine.isGossipPayload(p.bytes))
          .toList();
      expect(invPayloads.length, equals(1));

      // Node A menerima DAG_INV dari Node B
      transportA.clearSentPayloads();
      await engineA.handleIncomingPayload(
        TransportPayload(
          endpointId: 'ep-b',
          bytes: invPayloads.first.bytes,
          receivedAt: fakeCurrentTime,
        ),
      );

      // Node A mendeteksi selisih inventaris dan langsung mengirim DAG_GET_BLOCKS
      final getBlocksPayloads = transportA.sentPayloads
          .where((p) => DagGossipSyncEngine.isGossipPayload(p.bytes))
          .toList();
      expect(getBlocksPayloads.length, equals(1));

      final getBlocksMsg =
          DagGossipCodec.decode(getBlocksPayloads.first.bytes).message
              as DagGetBlocksMessage;
      expect(getBlocksMsg.requestedBlockHashes, contains(blockB1.blockHash));

      // Node B melayani permintaan dan mengirim DAG_BLOCK_BATCH
      transportB.clearSentPayloads();
      await engineB.handleIncomingPayload(
        TransportPayload(
          endpointId: 'ep-a',
          bytes: getBlocksPayloads.first.bytes,
          receivedAt: fakeCurrentTime,
        ),
      );

      final batchPayloads = transportB.sentPayloads
          .where((p) => DagGossipSyncEngine.isGossipPayload(p.bytes))
          .toList();
      expect(batchPayloads.length, equals(1));

      // Node A mengonsumsi batch, memvalidasi, dan meng-ingest ke ledger
      transportA.clearSentPayloads();
      await engineA.handleIncomingPayload(
        TransportPayload(
          endpointId: 'ep-b',
          bytes: batchPayloads.first.bytes,
          receivedAt: fakeCurrentTime,
        ),
      );

      expect(ledgerA.getBlock(blockB1.blockHash), isNotNull);

      // Node A mengirim DAG_SYNC_ACK
      final ackPayloads = transportA.sentPayloads
          .where((p) => DagGossipSyncEngine.isGossipPayload(p.bytes))
          .toList();
      expect(ackPayloads.length, equals(1));

      engineA.dispose();
      engineB.dispose();
    });

    // ------------------------------------------------------------------------
    // 6. Inventaris identik tidak memicu rangkaian transfer berulang
    // ------------------------------------------------------------------------
    test('6. Inventaris identik tidak memicu rangkaian transfer berulang', () async {
      final engineA = DagGossipSyncEngine(
        transport: transportA,
        localNodeId: 'NODE-A',
        ledger: ledgerA,
        repository: repoA,
        isEnabled: true,
        periodicConfig: const PeriodicGossipConfig(
          interval: Duration(seconds: 30),
          jitterRange: Duration.zero,
          autoStartTimer: false,
        ),
        nowProvider: fakeNow,
      );
      final engineB = DagGossipSyncEngine(
        transport: transportB,
        localNodeId: 'NODE-B',
        ledger: ledgerB,
        repository: repoB,
        isEnabled: true,
        periodicConfig: const PeriodicGossipConfig(
          interval: Duration(seconds: 30),
          jitterRange: Duration.zero,
          autoStartTimer: false,
        ),
        nowProvider: fakeNow,
      );

      await connectAndHandshake(engineA, engineB);

      // Kedua ledger sinkron (hanya genesis). Tick B mengirim DAG_INV periodik
      fakeCurrentTime = fakeCurrentTime.add(const Duration(seconds: 30));
      transportB.clearSentPayloads();
      await engineB.tickPeriodicReconciliation(fakeCurrentTime);

      final invPayload = transportB.sentPayloads.first;

      // Node A menerima DAG_INV identik (sudah diketahui dari handshake)
      transportA.clearSentPayloads();
      await engineA.handleIncomingPayload(
        TransportPayload(
          endpointId: 'ep-b',
          bytes: invPayload.bytes,
          receivedAt: fakeCurrentTime,
        ),
      );

      // Deduplikasi bekerja: Node A TIDAK mengirim DAG_GET_BLOCKS maupun pesan apa pun
      expect(transportA.sentPayloads, isEmpty);

      // Tick kedua B setelah 30 detik berikutnya: mengirim DAG_INV identik lagi
      fakeCurrentTime = fakeCurrentTime.add(const Duration(seconds: 30));
      transportB.clearSentPayloads();
      await engineB.tickPeriodicReconciliation(fakeCurrentTime);

      final invPayload2 = transportB.sentPayloads.first;
      transportA.clearSentPayloads();
      await engineA.handleIncomingPayload(
        TransportPayload(
          endpointId: 'ep-b',
          bytes: invPayload2.bytes,
          receivedAt: fakeCurrentTime,
        ),
      );

      // Tetap nol respon, tidak ada transfer berulang
      expect(transportA.sentPayloads, isEmpty);

      engineA.dispose();
      engineB.dispose();
    });

    // ------------------------------------------------------------------------
    // 7. Kegagalan sendBytes() memulai backoff
    // ------------------------------------------------------------------------
    test('7. Kegagalan sendBytes() memulai backoff', () async {
      final engineA = DagGossipSyncEngine(
        transport: transportA,
        localNodeId: 'NODE-A',
        ledger: ledgerA,
        repository: repoA,
        isEnabled: true,
        periodicConfig: const PeriodicGossipConfig(
          interval: Duration(seconds: 30),
          minBackoff: Duration(seconds: 5),
          maxBackoff: Duration(seconds: 120),
          jitterRange: Duration.zero,
          autoStartTimer: false,
        ),
        nowProvider: fakeNow,
      );
      final engineB = DagGossipSyncEngine(
        transport: transportB,
        localNodeId: 'NODE-B',
        ledger: ledgerB,
        repository: repoB,
        isEnabled: true,
        periodicConfig: const PeriodicGossipConfig(
          interval: Duration(seconds: 30),
          jitterRange: Duration.zero,
          autoStartTimer: false,
        ),
        nowProvider: fakeNow,
      );

      await connectAndHandshake(engineA, engineB);

      // Simulasikan kegagalan transport pada Node A
      transportA.shouldFailSend = true;

      fakeCurrentTime = fakeCurrentTime.add(const Duration(seconds: 30));
      final success = await engineA.reconcilePeer('ep-b', fakeCurrentTime);

      expect(success, isFalse);
      expect(engineA.totalPeriodicReconcileFailures, equals(1));

      final session = engineA.getSession('ep-b')!;
      expect(session.consecutiveFailures, equals(1));
      expect(session.currentBackoff, equals(const Duration(seconds: 5)));
      expect(
        session.nextEligibleReconcileTime,
        equals(fakeCurrentTime.add(const Duration(seconds: 5))),
      );

      // Percobaan tick 2 detik kemudian (masih dalam jeda 5s backoff): langsung dilewati
      fakeCurrentTime = fakeCurrentTime.add(const Duration(seconds: 2));
      final skipped = await engineA.reconcilePeer('ep-b', fakeCurrentTime);
      expect(skipped, isFalse);
      // Kegagalan tidak bertambah karena langsung diskip oleh backoff
      expect(session.consecutiveFailures, equals(1));

      engineA.dispose();
      engineB.dispose();
    });

    // ------------------------------------------------------------------------
    // 8. Kegagalan berulang tidak menghasilkan retry tanpa batas
    // ------------------------------------------------------------------------
    test(
      '8. Kegagalan berulang tidak menghasilkan retry tanpa batas',
      () async {
        final engineA = DagGossipSyncEngine(
          transport: transportA,
          localNodeId: 'NODE-A',
          ledger: ledgerA,
          repository: repoA,
          isEnabled: true,
          periodicConfig: const PeriodicGossipConfig(
            interval: Duration(seconds: 30),
            minBackoff: Duration(seconds: 5),
            maxBackoff: Duration(seconds: 40), // Batas maksimum 40 detik
            jitterRange: Duration.zero,
            autoStartTimer: false,
          ),
          nowProvider: fakeNow,
        );
        final engineB = DagGossipSyncEngine(
          transport: transportB,
          localNodeId: 'NODE-B',
          ledger: ledgerB,
          repository: repoB,
          isEnabled: true,
          periodicConfig: const PeriodicGossipConfig(
            interval: Duration(seconds: 30),
            jitterRange: Duration.zero,
            autoStartTimer: false,
          ),
          nowProvider: fakeNow,
        );

        await connectAndHandshake(engineA, engineB);

        transportA.shouldFailSend = true;
        final session = engineA.getSession('ep-b')!;

        // Failure 1: 5s backoff
        fakeCurrentTime = fakeCurrentTime.add(const Duration(seconds: 30));
        await engineA.reconcilePeer('ep-b', fakeCurrentTime);
        expect(session.consecutiveFailures, equals(1));
        expect(session.currentBackoff, equals(const Duration(seconds: 5)));

        // Failure 2: 10s backoff (5 * 2^1)
        fakeCurrentTime = fakeCurrentTime.add(const Duration(seconds: 5));
        await engineA.reconcilePeer('ep-b', fakeCurrentTime);
        expect(session.consecutiveFailures, equals(2));
        expect(session.currentBackoff, equals(const Duration(seconds: 10)));

        // Failure 3: 20s backoff (5 * 2^2)
        fakeCurrentTime = fakeCurrentTime.add(const Duration(seconds: 10));
        await engineA.reconcilePeer('ep-b', fakeCurrentTime);
        expect(session.consecutiveFailures, equals(3));
        expect(session.currentBackoff, equals(const Duration(seconds: 20)));

        // Failure 4: 40s backoff (5 * 2^3 = 40s = maxBackoff)
        fakeCurrentTime = fakeCurrentTime.add(const Duration(seconds: 20));
        await engineA.reconcilePeer('ep-b', fakeCurrentTime);
        expect(session.consecutiveFailures, equals(4));
        expect(session.currentBackoff, equals(const Duration(seconds: 40)));

        // Failure 5: tetap dibatasi 40s (maxBackoff cap)
        fakeCurrentTime = fakeCurrentTime.add(const Duration(seconds: 40));
        await engineA.reconcilePeer('ep-b', fakeCurrentTime);
        expect(session.consecutiveFailures, equals(5));
        expect(session.currentBackoff, equals(const Duration(seconds: 40)));

        engineA.dispose();
        engineB.dispose();
      },
    );

    // ------------------------------------------------------------------------
    // 9. Rekonsiliasi berhasil memulihkan keadaan backoff sesuai kebijakan
    // ------------------------------------------------------------------------
    test(
      '9. Rekonsiliasi berhasil memulihkan keadaan backoff sesuai kebijakan',
      () async {
        final engineA = DagGossipSyncEngine(
          transport: transportA,
          localNodeId: 'NODE-A',
          ledger: ledgerA,
          repository: repoA,
          isEnabled: true,
          periodicConfig: const PeriodicGossipConfig(
            interval: Duration(seconds: 30),
            minBackoff: Duration(seconds: 5),
            maxBackoff: Duration(seconds: 60),
            jitterRange: Duration.zero,
            autoStartTimer: false,
          ),
          nowProvider: fakeNow,
        );
        final engineB = DagGossipSyncEngine(
          transport: transportB,
          localNodeId: 'NODE-B',
          ledger: ledgerB,
          repository: repoB,
          isEnabled: true,
          periodicConfig: const PeriodicGossipConfig(
            interval: Duration(seconds: 30),
            jitterRange: Duration.zero,
            autoStartTimer: false,
          ),
          nowProvider: fakeNow,
        );

        await connectAndHandshake(engineA, engineB);

        // Mengalami kegagalan terlebih dahulu
        transportA.shouldFailSend = true;
        fakeCurrentTime = fakeCurrentTime.add(const Duration(seconds: 30));
        await engineA.reconcilePeer('ep-b', fakeCurrentTime);

        final session = engineA.getSession('ep-b')!;
        expect(session.consecutiveFailures, equals(1));
        expect(session.currentBackoff, equals(const Duration(seconds: 5)));

        // Transport pulih kembali
        transportA.shouldFailSend = false;
        fakeCurrentTime = fakeCurrentTime.add(const Duration(seconds: 5));
        final success = await engineA.reconcilePeer('ep-b', fakeCurrentTime);

        expect(success, isTrue);
        expect(session.consecutiveFailures, equals(0));
        expect(session.currentBackoff, equals(Duration.zero));
        expect(
          session.nextEligibleReconcileTime,
          equals(fakeCurrentTime.add(const Duration(seconds: 30))),
        );

        engineA.dispose();
        engineB.dispose();
      },
    );

    // ------------------------------------------------------------------------
    // 10. Disconnect membatalkan penjadwalan untuk sesi lama
    // ------------------------------------------------------------------------
    test('10. Disconnect membatalkan penjadwalan untuk sesi lama', () async {
      final engineA = DagGossipSyncEngine(
        transport: transportA,
        localNodeId: 'NODE-A',
        ledger: ledgerA,
        repository: repoA,
        isEnabled: true,
        periodicConfig: const PeriodicGossipConfig(
          interval: Duration(seconds: 30),
          autoStartTimer: false,
        ),
        nowProvider: fakeNow,
      );
      final engineB = DagGossipSyncEngine(
        transport: transportB,
        localNodeId: 'NODE-B',
        ledger: ledgerB,
        repository: repoB,
        isEnabled: true,
        periodicConfig: const PeriodicGossipConfig(
          interval: Duration(seconds: 30),
          autoStartTimer: false,
        ),
        nowProvider: fakeNow,
      );

      await connectAndHandshake(engineA, engineB);
      expect(engineA.getSession('ep-b'), isNotNull);

      // Simulasikan disconnect
      transportA.simulateDisconnection('ep-b');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Sesi lama dibersihkan
      expect(engineA.getSession('ep-b'), isNull);

      // Rekonsiliasi untuk endpoint yang terputus menghasilkan false dan 0 paket
      transportA.clearSentPayloads();
      final res = await engineA.reconcilePeer('ep-b', fakeCurrentTime);
      expect(res, isFalse);
      expect(transportA.sentPayloads, isEmpty);

      engineA.dispose();
      engineB.dispose();
    });

    // ------------------------------------------------------------------------
    // 11. Reconnect membuat sesi baru tanpa menggunakan konteks request atau ACK sesi sebelumnya
    // ------------------------------------------------------------------------
    test(
      '11. Reconnect membuat sesi baru tanpa menggunakan konteks request atau ACK sesi sebelumnya',
      () async {
        final engineA = DagGossipSyncEngine(
          transport: transportA,
          localNodeId: 'NODE-A',
          ledger: ledgerA,
          repository: repoA,
          isEnabled: true,
          periodicConfig: const PeriodicGossipConfig(
            interval: Duration(seconds: 30),
            autoStartTimer: false,
          ),
          nowProvider: fakeNow,
        );
        final engineB = DagGossipSyncEngine(
          transport: transportB,
          localNodeId: 'NODE-B',
          ledger: ledgerB,
          repository: repoB,
          isEnabled: true,
          periodicConfig: const PeriodicGossipConfig(
            interval: Duration(seconds: 30),
            autoStartTimer: false,
          ),
          nowProvider: fakeNow,
        );

        await connectAndHandshake(engineA, engineB);

        final oldSession = engineA.getSession('ep-b')!;
        final oldSessionId = oldSession.sessionId;
        oldSession.consecutiveFailures = 4;
        oldSession.currentBackoff = const Duration(seconds: 40);
        oldSession.recordRecognizedRequestId('req-old-session-1');

        // Disconnect
        transportA.simulateDisconnection('ep-b');
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Reconnect
        transportA.simulateIncomingConnectionRequest(
          endpointId: 'ep-b',
          endpointName: 'Node B',
        );
        await transportA.acceptConnection(endpointId: 'ep-b');
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final newSession = engineA.getSession('ep-b')!;
        expect(newSession.sessionId, isNot(equals(oldSessionId)));
        expect(newSession.consecutiveFailures, equals(0));
        expect(newSession.currentBackoff, equals(Duration.zero));
        expect(
          newSession.recognizedRequestIds.contains('req-old-session-1'),
          isFalse,
        );
        expect(newSession.activeRequestId, isNull);

        engineA.dispose();
        engineB.dispose();
      },
    );

    // ------------------------------------------------------------------------
    // 12. Disable, dispose, dan reset membersihkan semua resource penjadwalan
    // ------------------------------------------------------------------------
    test(
      '12. Disable, dispose, dan reset membersihkan semua resource penjadwalan',
      () async {
        final engine = DagGossipSyncEngine(
          transport: transportA,
          localNodeId: 'NODE-A',
          ledger: ledgerA,
          repository: repoA,
          isEnabled: true,
          periodicConfig: const PeriodicGossipConfig(
            interval: Duration(seconds: 30),
            autoStartTimer: true,
          ),
          nowProvider: fakeNow,
        );

        expect(engine.scheduler.isRunning, isTrue);

        // 1. isEnabled = false
        engine.isEnabled = false;
        expect(engine.scheduler.isRunning, isFalse);
        expect(engine.scheduler.activeTimersCount, equals(0));

        // 2. dispose()
        engine.dispose();
        expect(engine.scheduler.isDisposed, isTrue);
        expect(engine.scheduler.isRunning, isFalse);

        // 3. ManetRoutingHolder.reset()
        ManetRoutingHolder.reset();
        expect(ManetRoutingHolder.enableBlockdagReplication, isFalse);
        expect(ManetRoutingHolder.gossipSyncEngine, isNull);
      },
    );

    // ------------------------------------------------------------------------
    // 13. Operasi scheduler tidak menggandakan request blok yang masih aktif
    // ------------------------------------------------------------------------
    test(
      '13. Operasi scheduler tidak menggandakan request blok yang masih aktif',
      () async {
        final engineA = DagGossipSyncEngine(
          transport: transportA,
          localNodeId: 'NODE-A',
          ledger: ledgerA,
          repository: repoA,
          isEnabled: true,
          periodicConfig: const PeriodicGossipConfig(
            interval: Duration(seconds: 30),
            requestTimeout: Duration(seconds: 15),
            autoStartTimer: false,
          ),
          nowProvider: fakeNow,
        );
        final engineB = DagGossipSyncEngine(
          transport: transportB,
          localNodeId: 'NODE-B',
          ledger: ledgerB,
          repository: repoB,
          isEnabled: true,
          periodicConfig: const PeriodicGossipConfig(
            interval: Duration(seconds: 30),
            autoStartTimer: false,
          ),
          nowProvider: fakeNow,
        );

        await connectAndHandshake(engineA, engineB);

        final session = engineA.getSession('ep-b')!;
        session.activeRequestId = 'req-in-flight-active';
        session.activeRequestTime = fakeCurrentTime;

        // Tick terjadi 5 detik kemudian (masih di dalam batas 15 detik requestTimeout)
        fakeCurrentTime = fakeCurrentTime.add(const Duration(seconds: 5));
        transportA.clearSentPayloads();

        final res = await engineA.reconcilePeer('ep-b', fakeCurrentTime);

        // Tidak boleh mengirim request ganda atau menimpa activeRequestId
        expect(res, isFalse);
        expect(session.activeRequestId, equals('req-in-flight-active'));
        expect(transportA.sentPayloads, isEmpty);

        engineA.dispose();
        engineB.dispose();
      },
    );

    // ------------------------------------------------------------------------
    // 14. Kegagalan persistensi tetap tidak menghasilkan ACK sukses
    // ------------------------------------------------------------------------
    test(
      '14. Kegagalan persistensi tetap tidak menghasilkan ACK sukses',
      () async {
        final controllableRepoA = ControllableBlockdagRepository();
        final engineA = DagGossipSyncEngine(
          transport: transportA,
          localNodeId: 'NODE-A',
          ledger: ledgerA,
          repository: controllableRepoA,
          isEnabled: true,
          periodicConfig: const PeriodicGossipConfig(
            interval: Duration(seconds: 30),
            autoStartTimer: false,
          ),
          nowProvider: fakeNow,
        );
        final engineB = DagGossipSyncEngine(
          transport: transportB,
          localNodeId: 'NODE-B',
          ledger: ledgerB,
          repository: repoB,
          isEnabled: true,
          periodicConfig: const PeriodicGossipConfig(
            interval: Duration(seconds: 30),
            autoStartTimer: false,
          ),
          nowProvider: fakeNow,
        );

        await connectAndHandshake(engineA, engineB);

        // Node B membuat blok valid
        final blockB1 = ledgerB.createBlock(
          creatorNodeId: 'NODE-B',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-B'},
        );
        await repoB.saveState(ledgerB.exportPersistedState());

        // Atur repositori Node A agar gagal menyimpan
        controllableRepoA.shouldFailSave = true;

        final sessionA = engineA.getSession('ep-b')!;
        sessionA.activeRequestId = 'req-batch-fail-persist';

        // Simulasikan pengiriman DAG_BLOCK_BATCH dari Node B ke Node A
        final batchMsg = DagBlockBatchMessage(
          senderNodeId: 'NODE-B',
          requestId: 'req-batch-fail-persist',
          batchIndex: 1,
          totalBatches: 1,
          blocks: [blockB1],
        );

        transportA.clearSentPayloads();
        await engineA.handleIncomingPayload(
          TransportPayload(
            endpointId: 'ep-b',
            bytes: batchMsg.toBytes(),
            receivedAt: fakeCurrentTime,
          ),
        );

        // Tidak ada DAG_SYNC_ACK yang terkirim saat penyimpanan gagal!
        final ackPayloads = transportA.sentPayloads
            .where((p) => DagGossipSyncEngine.isGossipPayload(p.bytes))
            .where((p) {
              final decoded = DagGossipCodec.decode(p.bytes);
              return decoded.message?.type == DagGossipMessageType.syncAck;
            })
            .toList();
        expect(ackPayloads, isEmpty);

        // Ledger Node A di-rollback (blok tidak di-ingest)
        expect(ledgerA.getBlock(blockB1.blockHash), isNull);

        engineA.dispose();
        engineB.dispose();
      },
    );

    // ------------------------------------------------------------------------
    // 15. Integrasi simultan: transfer blok, orphan pool, strict deferred ACK binding, dan dual-slot persistence tetap konsisten selama periodic reconciliation
    // ------------------------------------------------------------------------
    test(
      '15. Integrasi simultan: transfer blok, orphan pool, strict deferred ACK binding, dan dual-slot persistence tetap konsisten selama periodic reconciliation',
      () async {
        final poolA = OrphanBlockPool();
        final engineA = DagGossipSyncEngine(
          transport: transportA,
          localNodeId: 'NODE-A',
          ledger: ledgerA,
          repository: repoA,
          orphanPool: poolA,
          isEnabled: true,
          periodicConfig: const PeriodicGossipConfig(
            interval: Duration(seconds: 30),
            jitterRange: Duration.zero,
            autoStartTimer: false,
          ),
          nowProvider: fakeNow,
        );

        final engineB = DagGossipSyncEngine(
          transport: transportB,
          localNodeId: 'NODE-B',
          ledger: ledgerB,
          repository: repoB,
          isEnabled: true,
          periodicConfig: const PeriodicGossipConfig(
            interval: Duration(seconds: 30),
            jitterRange: Duration.zero,
            autoStartTimer: false,
          ),
          nowProvider: fakeNow,
        );

        await connectAndHandshake(engineA, engineB);

        // Node B membuat Parent Block B1 dan Child Block B2
        final parentB1 = ledgerB.createBlock(
          creatorNodeId: 'NODE-B',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-B'},
        );
        final childB2 = SecurityBlock.create(
          index: 2,
          parentBlockHashes: [parentB1.blockHash],
          creatorNodeId: 'NODE-B',
          events: [],
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-B'},
        );
        ledgerB.acceptRemoteBlock(childB2);
        await repoB.saveState(ledgerB.exportPersistedState());

        final sessionA = engineA.getSession('ep-b')!;
        expect(sessionA.remoteNodeId, equals('NODE-B'));

        // 1. Tick rekonsiliasi periodik pada Node B setelah 30 detik
        fakeCurrentTime = fakeCurrentTime.add(const Duration(seconds: 30));
        transportB.clearSentPayloads();
        await engineB.tickPeriodicReconciliation(fakeCurrentTime);

        final periodicInv = transportB.sentPayloads.first;
        expect(
          DagGossipCodec.decode(periodicInv.bytes).message?.type,
          equals(DagGossipMessageType.inv),
        );

        // 2. Node A menerima periodic DAG_INV, mendeteksi ketiadaan parentB1 & childB2, dan mengirim DAG_GET_BLOCKS
        transportA.clearSentPayloads();
        await engineA.handleIncomingPayload(
          TransportPayload(
            endpointId: 'ep-b',
            bytes: periodicInv.bytes,
            receivedAt: fakeCurrentTime,
          ),
        );

        final getBlocksPayloads = transportA.sentPayloads
            .where(
              (p) =>
                  DagGossipCodec.decode(p.bytes).message?.type ==
                  DagGossipMessageType.getBlocks,
            )
            .toList();
        expect(getBlocksPayloads.length, equals(1));

        final getBlocksMsg =
            DagGossipCodec.decode(getBlocksPayloads.first.bytes).message
                as DagGetBlocksMessage;
        expect(getBlocksMsg.requestedBlockHashes, contains(parentB1.blockHash));
        expect(getBlocksMsg.requestedBlockHashes, contains(childB2.blockHash));

        // 3. Node B menyajikan batch blok terurut topologis (parent sebelum child)
        transportB.clearSentPayloads();
        await engineB.handleIncomingPayload(
          TransportPayload(
            endpointId: 'ep-a',
            bytes: getBlocksPayloads.first.bytes,
            receivedAt: fakeCurrentTime,
          ),
        );

        final batchPayloads = transportB.sentPayloads
            .where(
              (p) =>
                  DagGossipCodec.decode(p.bytes).message?.type ==
                  DagGossipMessageType.blockBatch,
            )
            .toList();
        expect(batchPayloads.length, equals(1));

        // 4. Node A mengonsumsi batch: memvalidasi, meng-ingest kedua blok, dan menyimpan ke repoA
        transportA.clearSentPayloads();
        await engineA.handleIncomingPayload(
          TransportPayload(
            endpointId: 'ep-b',
            bytes: batchPayloads.first.bytes,
            receivedAt: fakeCurrentTime,
          ),
        );

        expect(ledgerA.getBlock(parentB1.blockHash), isNotNull);
        expect(ledgerA.getBlock(childB2.blockHash), isNotNull);
        final loadedFromRepo = await repoA.loadState();
        expect(
          loadedFromRepo?.blocks.any((b) => b.blockHash == parentB1.blockHash),
          isTrue,
        );
        expect(
          loadedFromRepo?.blocks.any((b) => b.blockHash == childB2.blockHash),
          isTrue,
        );

        // Verifikasi DAG_SYNC_ACK dikirim mengonfirmasi kedua blok
        final ackPayloads = transportA.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagSyncAckMessage>()
            .toList();
        expect(ackPayloads.length, equals(1));
        expect(
          ackPayloads.first.acceptedBlockHashes,
          contains(parentB1.blockHash),
        );
        expect(
          ackPayloads.first.acceptedBlockHashes,
          contains(childB2.blockHash),
        );

        // 5. Node B memproses ACK dan menandai blok telah diakui oleh Node A
        await engineB.handleIncomingPayload(
          TransportPayload(
            endpointId: 'ep-a',
            bytes: transportA.sentPayloads.first.bytes,
            receivedAt: fakeCurrentTime,
          ),
        );
        final sessionB = engineB.getSession('ep-a')!;
        expect(
          sessionB.knownPeerBlockHashes.contains(parentB1.blockHash),
          isTrue,
        );
        expect(
          sessionB.knownPeerBlockHashes.contains(childB2.blockHash),
          isTrue,
        );

        // 6. Tick periodik berikutnya pada Node B: kedua node sudah identik, tidak ada transfer berulang
        fakeCurrentTime = fakeCurrentTime.add(const Duration(seconds: 30));
        transportB.clearSentPayloads();
        await engineB.tickPeriodicReconciliation(fakeCurrentTime);

        transportA.clearSentPayloads();
        await engineA.handleIncomingPayload(
          TransportPayload(
            endpointId: 'ep-b',
            bytes: transportB.sentPayloads.first.bytes,
            receivedAt: fakeCurrentTime,
          ),
        );

        expect(transportA.sentPayloads, isEmpty);

        engineA.dispose();
        engineB.dispose();
      },
    );
  });
}

/// STAGE 5E.4.3 — Pengujian Integrasi Transport dan Pertukaran Inventaris BlockDAG (DAG-Sync)
///
/// Memverifikasi 12 skenario deterministik:
/// 1. Peer terhubung memicu DAG_HELLO hanya ketika gossip aktif.
/// 2. DAG_HELLO valid diterima dan menghasilkan balasan DAG_INV.
/// 3. Inventaris remote dibandingkan dengan ledger lokal tanpa mutasi ledger.
/// 4. Hash yang tidak dikenal dicatat sebagai kandidat blok yang belum dimiliki (missingBlockHashes).
/// 5. Inventaris identik berulang tidak menciptakan loop pertukaran tak terbatas (deduplikasi sesi).
/// 6. Disconnect dan reconnect membersihkan atau membangun kembali state sesi dengan benar.
/// 7. Payload DAG-Sync tidak masuk ke ChatRepository dan tidak tercatat sebagai chat malformed.
/// 8. Payload chat dan handshake tetap berfungsi normal ketika fitur gossip aktif.
/// 9. Konfigurasi A dan B menghasilkan nol paket gossip.
/// 10. Konfigurasi C hanya mengirim paket setelah layanan secara eksplisit diaktifkan.
/// 11. Flag dinonaktifkan atau routing di-reset: subscription gossip dibersihkan.
/// 12. Blok hasil aktual BlockdagSecurityCoordinator.flushPendingEvents() lolos pemeriksaan privasi yang direkonsiliasi.
library;

import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:siagamesh_app/core/blockchain/blockchain_types.dart';
import 'package:siagamesh_app/core/blockchain/blockdag_repository.dart';
import 'package:siagamesh_app/core/blockchain/blockdag_security_coordinator.dart';
import 'package:siagamesh_app/core/blockchain/gossip/gossip.dart';
import 'package:siagamesh_app/core/blockchain/lightweight_blockdag_ledger.dart';
import 'package:siagamesh_app/core/ids/ids_types.dart';
import 'package:siagamesh_app/core/ids/selective_forwarding_detector.dart';
import 'package:siagamesh_app/core/routing/manet_routing_engine.dart';
import 'package:siagamesh_app/core/routing/mesh_experiment_logger.dart';
import 'package:siagamesh_app/core/routing/message_envelope.dart';
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

class ControllableFakeMeshTransport extends FakeMeshTransport {
  final bool sendResult;
  final bool shouldThrow;
  final int sendDelayMs;

  ControllableFakeMeshTransport({
    this.sendResult = true,
    this.shouldThrow = false,
    this.sendDelayMs = 0,
  });

  @override
  Future<bool> sendBytes({
    required String endpointId,
    required Uint8List bytes,
  }) async {
    if (sendDelayMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: sendDelayMs));
    }
    if (shouldThrow) {
      throw Exception('Simulated transport channel failure');
    }
    if (!sendResult) {
      return false;
    }
    return super.sendBytes(endpointId: endpointId, bytes: bytes);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('STAGE 5E.4.3 — Transport Integration & DAG Inventory Exchange', () {
    late FakeMeshTransport fakeTransport;
    late LightweightBlockdagLedger ledger;
    late DagGossipSyncEngine gossipEngine;
    late MeshExperimentLogger logger;
    late FakeChatRepository fakeChatRepo;
    late ManetRoutingEngine routingEngine;

    setUp(() {
      ManetRoutingHolder.reset();
      fakeTransport = FakeMeshTransport();
      ledger = LightweightBlockdagLedger();
      logger = MeshExperimentLogger();
      fakeChatRepo = FakeChatRepository();

      gossipEngine = DagGossipSyncEngine(
        transport: fakeTransport,
        localNodeId: 'NODE-A',
        ledger: ledger,
        isEnabled: false,
      );

      routingEngine = ManetRoutingEngine(
        transport: fakeTransport,
        identityManager: NodeIdentityManager(),
        repository: fakeChatRepo,
        experimentLogger: logger,
        gossipSyncEngine: gossipEngine,
      );
    });

    tearDown(() {
      routingEngine.dispose();
      gossipEngine.dispose();
      ManetRoutingHolder.reset();
    });

    // ------------------------------------------------------------------------
    // 1. Peer terhubung memicu DAG_HELLO hanya ketika gossip aktif
    // ------------------------------------------------------------------------
    test(
      '1. Peer terhubung memicu DAG_HELLO hanya ketika gossip aktif',
      () async {
        // Kondisi Nonaktif (isEnabled = false):
        fakeTransport.simulatePeerDiscovered(
          DiscoveredPeer(
            endpointId: 'ep-1',
            endpointName: 'Node B',
            serviceId: 'siagamesh-service',
            discoveredAt: DateTime.now(),
          ),
        );
        fakeTransport.simulateIncomingConnectionRequest(
          endpointId: 'ep-1',
          endpointName: 'Node B',
        );
        await fakeTransport.acceptConnection(endpointId: 'ep-1');
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Saat nonaktif, payload yang dikirim hanyalah PEER_HANDSHAKE dari routing engine (0 paket gossip)
        expect(gossipEngine.totalHelloSent, equals(0));
        expect(
          fakeTransport.sentPayloads.any(
            (p) => DagGossipSyncEngine.isGossipPayload(p.bytes),
          ),
          isFalse,
        );

        // Aktifkan gossip:
        gossipEngine.isEnabled = true;
        fakeTransport.clearSentPayloads();

        fakeTransport.simulateIncomingConnectionRequest(
          endpointId: 'ep-2',
          endpointName: 'Node C',
        );
        await fakeTransport.acceptConnection(endpointId: 'ep-2');
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Sekarang DAG_HELLO terkirim!
        expect(gossipEngine.totalHelloSent, equals(1));
        final helloPayload = fakeTransport.sentPayloads.firstWhere(
          (p) => DagGossipSyncEngine.isGossipPayload(p.bytes),
        );
        expect(helloPayload.endpointId, equals('ep-2'));

        final decodeRes = DagGossipCodec.decode(helloPayload.bytes);
        expect(decodeRes.isSuccess, isTrue);
        expect(decodeRes.message, isA<DagHelloMessage>());
        final hello = decodeRes.message as DagHelloMessage;
        expect(hello.senderNodeId, equals('NODE-A'));
        expect(hello.genesisHash, equals(ledger.genesisBlock.blockHash));
      },
    );

    // ------------------------------------------------------------------------
    // 2. DAG_HELLO valid diterima dan menghasilkan DAG_INV
    // ------------------------------------------------------------------------
    test(
      '2. DAG_HELLO valid diterima dan menghasilkan respons DAG_INV',
      () async {
        gossipEngine.isEnabled = true;

        fakeTransport.simulateIncomingConnectionRequest(
          endpointId: 'ep-remote-b',
          endpointName: 'Node B',
        );
        await fakeTransport.acceptConnection(endpointId: 'ep-remote-b');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        fakeTransport.clearSentPayloads();

        final remoteHello = DagHelloMessage(
          senderNodeId: 'NODE-B',
          senderTimestamp: DateTime.now().toUtc().millisecondsSinceEpoch,
          schemaVersion: 1,
          activeBlocksCount: 3,
          maxIndex: 2,
          tipHashes: [computeSha256('remote-tip-1')],
          genesisHash: ledger.genesisBlock.blockHash,
        );

        // Simulasikan payload masuk ke transport
        fakeTransport.simulateIncomingPayload(
          endpointId: 'ep-remote-b',
          bytes: DagGossipCodec.encode(remoteHello),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Memverifikasi DAG_HELLO tercatat diterima
        expect(gossipEngine.totalHelloReceived, equals(1));
        final session = gossipEngine.getSession('ep-remote-b');
        expect(session, isNotNull);
        expect(session!.remoteNodeId, equals('NODE-B'));
        expect(session.helloReceived, isTrue);

        // Memverifikasi DAG_INV dibalas ke ep-remote-b
        expect(gossipEngine.totalInvSent, equals(1));
        final invPayload = fakeTransport.sentPayloads.lastWhere(
          (p) =>
              p.endpointId == 'ep-remote-b' &&
              DagGossipSyncEngine.isGossipPayload(p.bytes),
        );
        final decodedInv = DagGossipCodec.decode(invPayload.bytes);
        expect(decodedInv.isSuccess, isTrue);
        expect(decodedInv.message, isA<DagInvMessage>());
        final inv = decodedInv.message as DagInvMessage;
        expect(inv.senderNodeId, equals('NODE-A'));
        expect(inv.tipHashes, contains(ledger.genesisBlock.blockHash));
      },
    );

    // ------------------------------------------------------------------------
    // 3 & 4. Perbandingan inventaris dan pencatatan missingBlockHashes tanpa mutasi ledger
    // ------------------------------------------------------------------------
    test(
      '3 & 4. Inventaris remote dibandingkan dengan ledger lokal tanpa mutasi ledger',
      () async {
        gossipEngine.isEnabled = true;
        final initialBlockCount = ledger.activeBlocksCount;

        // Buat satu blok lokal di Node A (Index 1)
        final localBlock1 = ledger.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        final remoteTipKnown = localBlock1.blockHash;
        final remoteTipUnknown1 = computeSha256('unknown-block-1');
        final remoteTipUnknown2 = computeSha256('unknown-block-2');

        // Kirim DAG_HELLO pengenalan status terlebih dahulu
        final remoteHello = DagHelloMessage(
          senderNodeId: 'NODE-B',
          senderTimestamp: DateTime.now().toUtc().millisecondsSinceEpoch,
          schemaVersion: 1,
          activeBlocksCount: 1,
          maxIndex: 0,
          tipHashes: [ledger.genesisBlock.blockHash],
          genesisHash: ledger.genesisBlock.blockHash,
        );
        fakeTransport.simulateIncomingPayload(
          endpointId: 'ep-b',
          bytes: DagGossipCodec.encode(remoteHello),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final remoteInv = DagInvMessage(
          senderNodeId: 'NODE-B',
          senderTimestamp: DateTime.now().toUtc().millisecondsSinceEpoch,
          tipHashes: [remoteTipKnown, remoteTipUnknown1],
          recentBlockHashes: [remoteTipUnknown2],
        );

        fakeTransport.simulateIncomingPayload(
          endpointId: 'ep-b',
          bytes: DagGossipCodec.encode(remoteInv),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Jaminan: Ledger TIDAK bermutasi (activeBlocksCount tetap sama)
        expect(ledger.activeBlocksCount, equals(initialBlockCount + 1));

        final session = gossipEngine.getSession('ep-b');
        expect(session, isNotNull);
        expect(session!.knownPeerBlockHashes, contains(remoteTipKnown));
        expect(session.missingBlockHashes, contains(remoteTipUnknown1));
        expect(session.missingBlockHashes, contains(remoteTipUnknown2));
        expect(session.missingBlockHashes.length, equals(2));

        // Verifikasi via getter publik
        final missing = gossipEngine.getMissingBlockHashesForPeer('ep-b');
        expect(missing, containsAll([remoteTipUnknown1, remoteTipUnknown2]));
      },
    );

    // ------------------------------------------------------------------------
    // 5. Inventaris identik berulang tidak menciptakan loop pertukaran
    // ------------------------------------------------------------------------
    test(
      '5. Deduplikasi inventaris: pesan DAG_INV berulang tidak diproses ulang',
      () async {
        gossipEngine.isEnabled = true;
        final hashX = computeSha256('block-x');

        // Kirim DAG_HELLO pengenalan status terlebih dahulu
        final remoteHello = DagHelloMessage(
          senderNodeId: 'NODE-B',
          senderTimestamp: DateTime.now().toUtc().millisecondsSinceEpoch,
          schemaVersion: 1,
          activeBlocksCount: 1,
          maxIndex: 0,
          tipHashes: [ledger.genesisBlock.blockHash],
          genesisHash: ledger.genesisBlock.blockHash,
        );
        fakeTransport.simulateIncomingPayload(
          endpointId: 'ep-dup',
          bytes: DagGossipCodec.encode(remoteHello),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final invMsg = DagInvMessage(
          senderNodeId: 'NODE-B',
          senderTimestamp: DateTime.now().toUtc().millisecondsSinceEpoch,
          tipHashes: [hashX],
          recentBlockHashes: const [],
        );

        // Kirim pertama kali
        fakeTransport.simulateIncomingPayload(
          endpointId: 'ep-dup',
          bytes: DagGossipCodec.encode(invMsg),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(gossipEngine.totalInvReceived, equals(1));

        // Kirim kedua kali dengan konten identik
        fakeTransport.simulateIncomingPayload(
          endpointId: 'ep-dup',
          bytes: DagGossipCodec.encode(invMsg),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(gossipEngine.totalInvReceived, equals(2));

        // Session hanya memiliki 1 hash di missingBlockHashes tanpa duplikasi
        final session = gossipEngine.getSession('ep-dup');
        expect(session!.missingBlockHashes.length, equals(1));
      },
    );

    // ------------------------------------------------------------------------
    // 6. Disconnect dan reconnect membersihkan dan membangun kembali state sesi
    // ------------------------------------------------------------------------
    test(
      '6. Disconnect membersihkan sesi dan reconnect menginisialisasi sesi baru',
      () async {
        gossipEngine.isEnabled = true;

        fakeTransport.simulateIncomingConnectionRequest(
          endpointId: 'ep-reconnect',
          endpointName: 'Node R',
        );
        await fakeTransport.acceptConnection(endpointId: 'ep-reconnect');
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(gossipEngine.getSession('ep-reconnect'), isNotNull);

        // Disconnect
        fakeTransport.simulateDisconnection('ep-reconnect');
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(gossipEngine.getSession('ep-reconnect'), isNull);

        // Reconnect
        fakeTransport.simulateIncomingConnectionRequest(
          endpointId: 'ep-reconnect',
          endpointName: 'Node R',
        );
        await fakeTransport.acceptConnection(endpointId: 'ep-reconnect');
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final newSession = gossipEngine.getSession('ep-reconnect');
        expect(newSession, isNotNull);
        expect(newSession!.helloSent, isTrue);
      },
    );

    // ------------------------------------------------------------------------
    // 7. Payload DAG-Sync tidak masuk ke ChatRepository dan tidak dilaporkan korup
    // ------------------------------------------------------------------------
    test(
      '7. Payload DAG-Sync tidak masuk ke ChatRepository dan tidak dicatat sebagai chat korup',
      () async {
        gossipEngine.isEnabled = true;

        final helloMsg = DagHelloMessage(
          senderNodeId: 'NODE-B',
          senderTimestamp: DateTime.now().toUtc().millisecondsSinceEpoch,
          schemaVersion: 1,
          activeBlocksCount: 1,
          maxIndex: 0,
          tipHashes: [ledger.genesisBlock.blockHash],
          genesisHash: ledger.genesisBlock.blockHash,
        );

        fakeTransport.simulateIncomingPayload(
          endpointId: 'ep-dispatch',
          bytes: DagGossipCodec.encode(helloMsg),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Chat repository menerima 0 pesan!
        expect(fakeChatRepo.savedMessages, isEmpty);

        // Logger eksperimen tidak mencatat CORRUPT_OR_UNSUPPORTED_PAYLOAD!
        final logs = logger.events;
        expect(
          logs.any((l) => l.failureReason == 'CORRUPT_OR_UNSUPPORTED_PAYLOAD'),
          isFalse,
        );
      },
    );

    // ------------------------------------------------------------------------
    // 8. Payload chat dan handshake tetap berfungsi normal saat gossip aktif
    // ------------------------------------------------------------------------
    test(
      '8. Payload chat dan handshake tetap berfungsi normal ketika gossip aktif',
      () async {
        gossipEngine.isEnabled = true;

        // 1. Handshake
        final hsEnvelope = MessageEnvelope(
          envelopeId: 'hs-1',
          type: MessageEnvelope.typeHandshake,
          senderId: 'NODE-REMOTE',
          senderName: 'Remote Peer',
          recipientId: 'BROADCAST',
          createdAt: DateTime.now().millisecondsSinceEpoch,
          routeTrace: const ['NODE-REMOTE'],
          payload: {'nodeId': 'NODE-REMOTE', 'nodeName': 'Remote Peer'},
        );

        fakeTransport.simulateIncomingPayload(
          endpointId: 'ep-chat',
          bytes: hsEnvelope.toBytes(),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final neighbor = routingEngine.neighborTable.getPeerByNodeId(
          'NODE-REMOTE',
        );
        expect(neighbor, isNotNull);

        // 2. Chat Message
        final chatEnvelope = MessageEnvelope(
          envelopeId: 'chat-env-1',
          type: MessageEnvelope.typeChat,
          senderId: 'NODE-REMOTE',
          senderName: 'Remote Peer',
          recipientId: routingEngine.localNodeId,
          createdAt: DateTime.now().millisecondsSinceEpoch,
          routeTrace: const ['NODE-REMOTE'],
          payload: {
            'messageId': 'msg-101',
            'senderId': 'NODE-REMOTE',
            'senderName': 'Remote Peer',
            'recipientId': routingEngine.localNodeId,
            'text': 'Pesan darurat gempa',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          },
        );

        fakeTransport.simulateIncomingPayload(
          endpointId: 'ep-chat',
          bytes: chatEnvelope.toBytes(),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(fakeChatRepo.savedMessages.length, equals(1));
        expect(
          fakeChatRepo.savedMessages.first.text,
          equals('Pesan darurat gempa'),
        );
      },
    );

    // ------------------------------------------------------------------------
    // 9 & 10. Konfigurasi A, B, dan C Feature Gating
    // ------------------------------------------------------------------------
    test(
      '9 & 10. Konfigurasi A dan B menghasilkan nol paket gossip; C hanya aktif jika eksplisit',
      () async {
        // Skenario Konfigurasi A (Baseline)
        ManetRoutingHolder.reset();
        ManetRoutingHolder.setInstance(routingEngine);
        expect(ManetRoutingHolder.enableBlockdagReplication, isFalse);

        fakeTransport.clearSentPayloads();
        fakeTransport.simulateIncomingConnectionRequest(
          endpointId: 'ep-config-a',
          endpointName: 'Node Peer',
        );
        await fakeTransport.acceptConnection(endpointId: 'ep-config-a');
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Konfigurasi A: 0 paket gossip
        expect(
          fakeTransport.sentPayloads.any(
            (p) => DagGossipSyncEngine.isGossipPayload(p.bytes),
          ),
          isFalse,
        );

        // Skenario Konfigurasi B (MANET + IDS + Trust)
        ManetRoutingHolder.setIdsDetector(
          SelectiveForwardingDetector(localNodeId: 'NODE-A'),
        );
        ManetRoutingHolder.setTrustManager(
          DynamicTrustManager(localNodeId: 'NODE-A'),
        );
        expect(ManetRoutingHolder.enableBlockdagReplication, isFalse);

        fakeTransport.clearSentPayloads();
        fakeTransport.simulateIncomingConnectionRequest(
          endpointId: 'ep-config-b',
          endpointName: 'Node Peer',
        );
        await fakeTransport.acceptConnection(endpointId: 'ep-config-b');
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Konfigurasi B: 0 paket gossip
        expect(
          fakeTransport.sentPayloads.any(
            (p) => DagGossipSyncEngine.isGossipPayload(p.bytes),
          ),
          isFalse,
        );

        // Skenario Konfigurasi C: Pasang koordinator & gossip engine, aktifkan replikasi
        ManetRoutingHolder.setGossipSyncEngine(gossipEngine);
        ManetRoutingHolder.setEnableBlockdagReplication(true);
        expect(ManetRoutingHolder.enableBlockdagReplication, isTrue);
        expect(gossipEngine.isEnabled, isTrue);

        fakeTransport.clearSentPayloads();
        fakeTransport.simulateIncomingConnectionRequest(
          endpointId: 'ep-config-c',
          endpointName: 'Node Peer',
        );
        await fakeTransport.acceptConnection(endpointId: 'ep-config-c');
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Konfigurasi C: Paket gossip DAG_HELLO terkirim!
        expect(
          fakeTransport.sentPayloads.any(
            (p) => DagGossipSyncEngine.isGossipPayload(p.bytes),
          ),
          isTrue,
        );
      },
    );

    // ------------------------------------------------------------------------
    // 11. Flag dinonaktifkan atau routing di-reset melepaskan resources
    // ------------------------------------------------------------------------
    test(
      '11. Reset ManetRoutingHolder membersihkan gossip engine dan subscription',
      () {
        ManetRoutingHolder.setGossipSyncEngine(gossipEngine);
        ManetRoutingHolder.setEnableBlockdagReplication(true);
        expect(gossipEngine.isEnabled, isTrue);

        ManetRoutingHolder.reset();
        expect(ManetRoutingHolder.enableBlockdagReplication, isFalse);
        expect(ManetRoutingHolder.gossipSyncEngine, isNull);
        expect(gossipEngine.isEnabled, isFalse);
        expect(gossipEngine.activeSessions, isEmpty);
      },
    );

    // ------------------------------------------------------------------------
    // 12. Rekonsiliasi Privasi Blok Hasil Koordinator
    // ------------------------------------------------------------------------
    test(
      '12. Blok hasil BlockdagSecurityCoordinator.flushPendingEvents() lolos validasi privasi',
      () async {
        final repo = InMemoryBlockdagRepository();
        final coord = BlockdagSecurityCoordinator(
          localNodeId: 'NODE-A',
          ledger: ledger,
          repository: repo,
          config: const BlockdagBatchConfig(maxBatchSize: 10),
        );
        await coord.initialize();

        // Masukkan event IDS sah
        await coord.processIdsDetectionEvent(
          IdsDetectionEvent(
            eventId: 'ids-coord-1',
            runId: 'RUN-1',
            observerNodeId: 'NODE-A',
            targetNodeId: 'NODE-B',
            status: NodeDetectionStatus.suspected,
            observedDropRate: 0.65,
            totalExpected: 10,
            totalClaimed: 3,
            totalUnconfirmed: 7,
            totalLinkFailures: 0,
            totalProtocolDrops: 0,
            reason: 'Drop rate 0.65 exceeds threshold',
            timestamp: DateTime.now().toUtc(),
            monotonicMicros: 1000,
          ),
        );

        // Uji kelima nilai flushReason yang sah
        final allowedReasons = [
          'emergency_suspected',
          'batch_capacity',
          'manual',
          'controlled_time_flush',
          'timeout_flush',
        ];

        for (final reason in allowedReasons) {
          ledger.addPendingEvent(
            SecurityAuditEvent(
              eventId: 'evt-$reason',
              eventType: AuditEventType.isolationDecision,
              observerNodeId: 'NODE-A',
              targetNodeId: 'NODE-B',
              timestamp: DateTime.now().toUtc(),
              monotonicMicros: 100,
              metadata: {'action': 'isolate', 'score': 0.3, 'reason': 'test'},
            ),
          );

          final block = await coord.flushPendingEvents(reason: reason);
          expect(block, isNotNull);

          // Verifikasi GossipPrivacySanitizer
          final privRes = GossipPrivacySanitizer.validateBlock(block!);
          expect(
            privRes.isCompliant,
            isTrue,
            reason: 'Blok dengan flushReason "$reason" harus lolos privasi',
          );
        }

        // Uji blok dengan flushReason tidak diizinkan
        final badReasonBlock = SecurityBlock.create(
          index: 99,
          parentBlockHashes: [ledger.genesisBlock.blockHash],
          creatorNodeId: 'NODE-A',
          events: const [],
          validationProof: {
            'flushReason': 'arbitrary_illegal_reason',
            'creatorNodeId': 'NODE-A',
          },
        );
        final badReasonRes = GossipPrivacySanitizer.validateBlock(
          badReasonBlock,
        );
        expect(badReasonRes.isCompliant, isFalse);
        expect(badReasonRes.violationReason, contains('flushReason'));

        // Uji blok dengan creatorNodeId yang tidak konsisten
        final forgedCreatorBlock = SecurityBlock.create(
          index: 100,
          parentBlockHashes: [ledger.genesisBlock.blockHash],
          creatorNodeId: 'NODE-A',
          events: const [],
          validationProof: {
            'flushReason': 'manual',
            'creatorNodeId':
                'ATTACKER-NODE', // Tidak cocok dengan block.creatorNodeId 'NODE-A'!
          },
        );
        final forgedRes = GossipPrivacySanitizer.validateBlock(
          forgedCreatorBlock,
        );
        expect(forgedRes.isCompliant, isFalse);
        expect(
          forgedRes.violationReason,
          contains('creatorNodeId dalam validationProof'),
        );
      },
    );
  });

  group(
    'STAGE 5E.4.3.1 — Harden Gossip Payload Demultiplexing & Async Error Handling',
    () {
      late FakeMeshTransport fakeTransport;
      late LightweightBlockdagLedger ledger;
      late DagGossipSyncEngine gossipEngine;
      late MeshExperimentLogger logger;
      late FakeChatRepository fakeChatRepo;
      late ManetRoutingEngine routingEngine;

      setUp(() {
        ManetRoutingHolder.reset();
        fakeTransport = FakeMeshTransport();
        ledger = LightweightBlockdagLedger();
        logger = MeshExperimentLogger();
        fakeChatRepo = FakeChatRepository();

        gossipEngine = DagGossipSyncEngine(
          transport: fakeTransport,
          localNodeId: 'NODE-A',
          ledger: ledger,
          isEnabled: false,
        );

        routingEngine = ManetRoutingEngine(
          transport: fakeTransport,
          identityManager: NodeIdentityManager(),
          repository: fakeChatRepo,
          experimentLogger: logger,
          gossipSyncEngine: gossipEngine,
        );
      });

      tearDown(() {
        routingEngine.dispose();
        gossipEngine.dispose();
        ManetRoutingHolder.reset();
      });

      // 1. Pesan chat berisi marker literal "SIAGAMESH_DAG_SYNC"
      test(
        '1. Chat message containing literal text "SIAGAMESH_DAG_SYNC" routes normally to chat',
        () async {
          gossipEngine.isEnabled = true;
          fakeTransport.clearSentPayloads();

          final chatEnvelope = MessageEnvelope(
            envelopeId: 'chat-marker-101',
            type: MessageEnvelope.typeChat,
            senderId: 'NODE-SENDER',
            senderName: 'Sender Node',
            recipientId: routingEngine.localNodeId,
            createdAt: DateTime.now().millisecondsSinceEpoch,
            routeTrace: const ['NODE-SENDER'],
            payload: {
              'messageId': 'msg-marker-101',
              'senderId': 'NODE-SENDER',
              'senderName': 'Sender Node',
              'recipientId': routingEngine.localNodeId,
              'text':
                  'Harap gunakan protokol SIAGAMESH_DAG_SYNC untuk sinkronisasi',
              'timestamp': DateTime.now().millisecondsSinceEpoch,
            },
          );

          fakeTransport.simulateIncomingPayload(
            endpointId: 'ep-chat-marker',
            bytes: chatEnvelope.toBytes(),
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));

          // Pesan chat harus masuk ke ChatRepository
          expect(fakeChatRepo.savedMessages.length, equals(1));
          expect(
            fakeChatRepo.savedMessages.first.text,
            contains('SIAGAMESH_DAG_SYNC'),
          );

          // Tidak boleh diproses sebagai pesan gossip
          expect(gossipEngine.totalHelloReceived, equals(0));
          expect(gossipEngine.totalInvReceived, equals(0));

          // Tidak boleh dicatat sebagai payload korup
          final logs = logger.events;
          expect(
            logs.any(
              (l) => l.failureReason == 'CORRUPT_OR_UNSUPPORTED_PAYLOAD',
            ),
            isFalse,
          );
        },
      );

      // 2. Payload gossip valid tetap menuju handler gossip
      test(
        '2. Valid gossip payload routes to gossip handler without entering ChatRepository',
        () async {
          gossipEngine.isEnabled = true;
          fakeChatRepo.clearAllData();

          final remoteHello = DagHelloMessage(
            senderNodeId: 'NODE-B',
            senderTimestamp: DateTime.now().toUtc().millisecondsSinceEpoch,
            schemaVersion: 1,
            activeBlocksCount: 1,
            maxIndex: 0,
            tipHashes: [ledger.genesisBlock.blockHash],
            genesisHash: ledger.genesisBlock.blockHash,
          );

          fakeTransport.simulateIncomingPayload(
            endpointId: 'ep-valid-gossip',
            bytes: DagGossipCodec.encode(remoteHello),
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));

          expect(gossipEngine.totalHelloReceived, equals(1));
          expect(fakeChatRepo.savedMessages, isEmpty);
        },
      );

      // 3. Pesan chat dan handshake normal tetap berfungsi saat gossip aktif
      test(
        '3. Normal chat and handshake messages function normally while gossip is active',
        () async {
          gossipEngine.isEnabled = true;
          fakeChatRepo.clearAllData();

          // Handshake
          final hs = MessageEnvelope(
            envelopeId: 'hs-node-h',
            type: MessageEnvelope.typeHandshake,
            senderId: 'NODE-H',
            senderName: 'Node H',
            recipientId: 'BROADCAST',
            createdAt: DateTime.now().millisecondsSinceEpoch,
            routeTrace: const ['NODE-H'],
            payload: {'nodeId': 'NODE-H', 'nodeName': 'Node H'},
          );
          fakeTransport.simulateIncomingPayload(
            endpointId: 'ep-h',
            bytes: hs.toBytes(),
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(
            routingEngine.neighborTable.getPeerByNodeId('NODE-H'),
            isNotNull,
          );

          // Chat
          final chat = MessageEnvelope(
            envelopeId: 'chat-h',
            type: MessageEnvelope.typeChat,
            senderId: 'NODE-H',
            senderName: 'Node H',
            recipientId: routingEngine.localNodeId,
            createdAt: DateTime.now().millisecondsSinceEpoch,
            routeTrace: const ['NODE-H'],
            payload: {
              'messageId': 'm-h',
              'senderId': 'NODE-H',
              'senderName': 'Node H',
              'recipientId': routingEngine.localNodeId,
              'text': 'Normal message',
            },
          );
          fakeTransport.simulateIncomingPayload(
            endpointId: 'ep-h',
            bytes: chat.toBytes(),
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(fakeChatRepo.savedMessages.length, equals(1));
          expect(
            fakeChatRepo.savedMessages.first.text,
            equals('Normal message'),
          );
        },
      );

      // 4. Payload malformed tidak crash dan tidak menyebabkan salah klasifikasi
      test(
        '4. Malformed payloads do not crash and are not misclassified as valid chat',
        () async {
          gossipEngine.isEnabled = true;
          fakeChatRepo.clearAllData();

          // Payload A: Mengklaim protocol SIAGAMESH_DAG_SYNC tapi JSON terpotong/rusak
          final brokenGossip = utf8.encode(
            '{"protocol":"SIAGAMESH_DAG_SYNC", corrupted',
          );
          fakeTransport.simulateIncomingPayload(
            endpointId: 'ep-bad-1',
            bytes: Uint8List.fromList(brokenGossip),
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));

          // Payload B: Mengklaim protocol SIAGAMESH_DAG_SYNC tapi struktur type/version tidak valid
          final invalidGossipStructure = utf8.encode(
            jsonEncode({
              'protocol': 'SIAGAMESH_DAG_SYNC',
              'version': 999,
              'type': 'UNKNOWN_TYPE_XYZ',
              'senderNodeId': 'ATTACKER',
            }),
          );
          fakeTransport.simulateIncomingPayload(
            endpointId: 'ep-bad-2',
            bytes: Uint8List.fromList(invalidGossipStructure),
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));

          // Payload C: Data biner acak bukan JSON
          final randomBinary = Uint8List.fromList([
            0xDE,
            0xAD,
            0xBE,
            0xEF,
            0x00,
            0x12,
          ]);
          fakeTransport.simulateIncomingPayload(
            endpointId: 'ep-bad-3',
            bytes: randomBinary,
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));

          // ChatRepository tetap bersih dari seluruh payload malformed
          expect(fakeChatRepo.savedMessages, isEmpty);
          expect(gossipEngine.totalHelloReceived, equals(0));
          expect(gossipEngine.totalInvReceived, equals(0));
        },
      );

      // 5. Pesan gossip tidak pernah masuk ke ChatRepository
      test('5. Gossip messages never enter ChatRepository', () async {
        gossipEngine.isEnabled = true;
        fakeChatRepo.clearAllData();

        final inv = DagInvMessage(
          senderNodeId: 'NODE-B',
          senderTimestamp: DateTime.now().toUtc().millisecondsSinceEpoch,
          tipHashes: [ledger.genesisBlock.blockHash],
        );
        fakeTransport.simulateIncomingPayload(
          endpointId: 'ep-inv-only',
          bytes: DagGossipCodec.encode(inv),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(fakeChatRepo.savedMessages, isEmpty);
      });

      // 6. sendBytes mengembalikan false ditangani secara aman
      test(
        '6. sendBytes returning false is handled gracefully without crash or state inconsistency',
        () async {
          final failingTransport = ControllableFakeMeshTransport(
            sendResult: false,
          );
          final engine = DagGossipSyncEngine(
            transport: failingTransport,
            localNodeId: 'NODE-A',
            ledger: ledger,
            isEnabled: true,
          );

          failingTransport.simulateIncomingConnectionRequest(
            endpointId: 'ep-fail',
            endpointName: 'Fail Node',
          );
          await failingTransport.acceptConnection(endpointId: 'ep-fail');
          await Future<void>.delayed(const Duration(milliseconds: 20));

          // Karena sendBytes false: totalHelloSent tidak bertambah dan helloSent bernilai false
          expect(engine.totalHelloSent, equals(0));
          final session = engine.getSession('ep-fail');
          expect(session, isNotNull);
          expect(session!.helloSent, isFalse);

          engine.dispose();
        },
      );

      // 7. sendBytes melempar exception ditangani secara aman tanpa unhandled error
      test(
        '7. sendBytes throwing an exception is handled gracefully without unhandled error',
        () async {
          final throwingTransport = ControllableFakeMeshTransport(
            shouldThrow: true,
          );
          final engine = DagGossipSyncEngine(
            transport: throwingTransport,
            localNodeId: 'NODE-A',
            ledger: ledger,
            isEnabled: true,
          );

          throwingTransport.simulateIncomingConnectionRequest(
            endpointId: 'ep-throw',
            endpointName: 'Throw Node',
          );
          await throwingTransport.acceptConnection(endpointId: 'ep-throw');
          await Future<void>.delayed(const Duration(milliseconds: 20));

          expect(engine.totalHelloSent, equals(0));
          final session = engine.getSession('ep-throw');
          expect(session, isNotNull);
          expect(session!.helloSent, isFalse);

          engine.dispose();
        },
      );

      // 8. Disconnect selama pengiriman asinkron berjalan tidak menghasilkan unhandled exception atau zombie session
      test(
        '8. Disconnect during sending does not produce unhandled exception or zombie session',
        () async {
          final delayedTransport = ControllableFakeMeshTransport(
            sendDelayMs: 40,
          );
          final engine = DagGossipSyncEngine(
            transport: delayedTransport,
            localNodeId: 'NODE-A',
            ledger: ledger,
            isEnabled: true,
          );

          delayedTransport.simulateIncomingConnectionRequest(
            endpointId: 'ep-disconnect-race',
            endpointName: 'Race Node',
          );
          await delayedTransport.acceptConnection(
            endpointId: 'ep-disconnect-race',
          );

          // Segera simulasikan diskoneksi sebelum delay pengiriman selesai
          delayedTransport.simulateDisconnection('ep-disconnect-race');
          await Future<void>.delayed(const Duration(milliseconds: 80));

          // Sesi harus terhapus dan tidak hidup kembali menjadi zombie
          expect(engine.getSession('ep-disconnect-race'), isNull);
          expect(engine.activeSessions, isEmpty);

          engine.dispose();
        },
      );

      // 9. Disable atau dispose saat operasi asinkron berjalan tidak menciptakan sesi baru atau resource yang bocor
      test(
        '9. Disable or dispose during async operation does not create new sessions or leak',
        () async {
          final delayedTransport = ControllableFakeMeshTransport(
            sendDelayMs: 40,
          );
          final engine = DagGossipSyncEngine(
            transport: delayedTransport,
            localNodeId: 'NODE-A',
            ledger: ledger,
            isEnabled: true,
          );

          delayedTransport.simulateIncomingConnectionRequest(
            endpointId: 'ep-dispose-race',
            endpointName: 'Dispose Race Node',
          );
          await delayedTransport.acceptConnection(
            endpointId: 'ep-dispose-race',
          );

          // Dispose saat pengiriman asinkron sedang berlangsung
          engine.dispose();
          await Future<void>.delayed(const Duration(milliseconds: 80));

          expect(engine.isDisposed, isTrue);
          expect(engine.isEnabled, isFalse);
          expect(engine.activeSessions, isEmpty);
        },
      );

      // 10. Inventaris identik tetap terdeduplikasi; inventaris berubah diproses; INV sebelum HELLO ditahan
      test(
        '10. Identical inventory remains deduplicated; changed inventory processed; INV before HELLO buffered',
        () async {
          gossipEngine.isEnabled = true;
          final tip1 = computeSha256('tip-block-1');
          final tip2 = computeSha256('tip-block-2');

          final invBeforeHello = DagInvMessage(
            senderNodeId: 'NODE-BUFFERED',
            senderTimestamp: DateTime.now().toUtc().millisecondsSinceEpoch,
            tipHashes: [tip1],
            recentBlockHashes: const [],
          );

          // Kirim DAG_INV SEBELUM DAG_HELLO
          fakeTransport.simulateIncomingPayload(
            endpointId: 'ep-buffered',
            bytes: DagGossipCodec.encode(invBeforeHello),
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));

          final session = gossipEngine.getSession('ep-buffered');
          expect(session, isNotNull);
          expect(session!.helloReceived, isFalse);
          // Karena DAG_HELLO belum ada, inventaris tertahan di pendingInv dan missingBlockHashes belum diisi
          expect(session.pendingInv, isNotNull);
          expect(session.missingBlockHashes, isEmpty);

          // Sekarang kirim DAG_HELLO yang kompatibel
          final helloMsg = DagHelloMessage(
            senderNodeId: 'NODE-BUFFERED',
            senderTimestamp: DateTime.now().toUtc().millisecondsSinceEpoch,
            schemaVersion: 1,
            activeBlocksCount: 1,
            maxIndex: 0,
            tipHashes: [ledger.genesisBlock.blockHash],
            genesisHash: ledger.genesisBlock.blockHash,
          );
          fakeTransport.simulateIncomingPayload(
            endpointId: 'ep-buffered',
            bytes: DagGossipCodec.encode(helloMsg),
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));

          // Setelah DAG_HELLO valid diterima, pendingInv otomatis diproses!
          expect(session.helloReceived, isTrue);
          expect(session.pendingInv, isNull);
          expect(session.missingBlockHashes, contains(tip1));
          expect(session.missingBlockHashes.length, equals(1));

          // Kirim ulang inventaris identik -> deduplikasi (missingBlockHashes tetap 1)
          fakeTransport.simulateIncomingPayload(
            endpointId: 'ep-buffered',
            bytes: DagGossipCodec.encode(invBeforeHello),
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(session.missingBlockHashes.length, equals(1));

          // Kirim inventaris BERUBAH (menambahkan tip2) -> diproses!
          final changedInv = DagInvMessage(
            senderNodeId: 'NODE-BUFFERED',
            senderTimestamp: DateTime.now().toUtc().millisecondsSinceEpoch,
            tipHashes: [tip1, tip2],
            recentBlockHashes: const [],
          );
          fakeTransport.simulateIncomingPayload(
            endpointId: 'ep-buffered',
            bytes: DagGossipCodec.encode(changedInv),
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(session.missingBlockHashes, contains(tip2));
          expect(session.missingBlockHashes.length, equals(2));
        },
      );

      // 11 & 12. Konfigurasi A, B tidak mengirim paket; Konfigurasi C memerlukan aktivasi eksplisit
      test(
        '11 & 12. Config A and B send no gossip packets; Config C requires explicit activation',
        () async {
          // Config A
          ManetRoutingHolder.reset();
          ManetRoutingHolder.setInstance(routingEngine);
          expect(ManetRoutingHolder.enableBlockdagReplication, isFalse);

          fakeTransport.clearSentPayloads();
          fakeTransport.simulateIncomingConnectionRequest(
            endpointId: 'ep-a',
            endpointName: 'Peer A',
          );
          await fakeTransport.acceptConnection(endpointId: 'ep-a');
          await Future<void>.delayed(const Duration(milliseconds: 20));

          expect(
            fakeTransport.sentPayloads.any(
              (p) => DagGossipSyncEngine.isGossipPayload(p.bytes),
            ),
            isFalse,
          );

          // Config B
          ManetRoutingHolder.setIdsDetector(
            SelectiveForwardingDetector(localNodeId: 'NODE-A'),
          );
          ManetRoutingHolder.setTrustManager(
            DynamicTrustManager(localNodeId: 'NODE-A'),
          );
          expect(ManetRoutingHolder.enableBlockdagReplication, isFalse);

          fakeTransport.clearSentPayloads();
          fakeTransport.simulateIncomingConnectionRequest(
            endpointId: 'ep-b-peer',
            endpointName: 'Peer B',
          );
          await fakeTransport.acceptConnection(endpointId: 'ep-b-peer');
          await Future<void>.delayed(const Duration(milliseconds: 20));

          expect(
            fakeTransport.sentPayloads.any(
              (p) => DagGossipSyncEngine.isGossipPayload(p.bytes),
            ),
            isFalse,
          );

          // Config C: Aktif hanya jika eksplisit
          ManetRoutingHolder.setGossipSyncEngine(gossipEngine);
          ManetRoutingHolder.setEnableBlockdagReplication(true);
          expect(ManetRoutingHolder.enableBlockdagReplication, isTrue);
          expect(gossipEngine.isEnabled, isTrue);

          fakeTransport.clearSentPayloads();
          fakeTransport.simulateIncomingConnectionRequest(
            endpointId: 'ep-c-peer',
            endpointName: 'Peer C',
          );
          await fakeTransport.acceptConnection(endpointId: 'ep-c-peer');
          await Future<void>.delayed(const Duration(milliseconds: 20));

          expect(
            fakeTransport.sentPayloads.any(
              (p) => DagGossipSyncEngine.isGossipPayload(p.bytes),
            ),
            isTrue,
          );
        },
      );
    },
  );
}

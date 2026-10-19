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
}

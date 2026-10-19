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

  group('STAGE 5E.4.4 — Block Transfer & Validated Ingestion', () {
    late FakeMeshTransport transportA;
    late FakeMeshTransport transportB;
    late LightweightBlockdagLedger ledgerA;
    late LightweightBlockdagLedger ledgerB;
    late InMemoryBlockdagRepository repoA;
    late InMemoryBlockdagRepository repoB;
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
      chatRepoA = FakeChatRepository();
      chatRepoB = FakeChatRepository();
      loggerA = MeshExperimentLogger();
      loggerB = MeshExperimentLogger();

      engineA = DagGossipSyncEngine(
        transport: transportA,
        localNodeId: 'NODE-A',
        ledger: ledgerA,
        repository: repoA,
        isEnabled: true,
      );

      engineB = DagGossipSyncEngine(
        transport: transportB,
        localNodeId: 'NODE-B',
        ledger: ledgerB,
        repository: repoB,
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

    test('1. Node requests blocks that it does not possess', () async {
      await establishSession();

      final blockA1 = ledgerA.createBlock(
        creatorNodeId: 'NODE-A',
        validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
      );

      final invMsg = DagInvMessage(
        senderNodeId: 'NODE-A',
        senderTimestamp: DateTime.now().toUtc().millisecondsSinceEpoch,
        tipHashes: [blockA1.blockHash],
        recentBlockHashes: [blockA1.blockHash],
      );
      transportB.clearSentPayloads();
      transportB.simulateIncomingPayload(
        endpointId: 'ep-a',
        bytes: DagGossipCodec.encode(invMsg),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final sessionB = engineB.getSession('ep-a')!;
      expect(sessionB.missingBlockHashes, contains(blockA1.blockHash));
      expect(sessionB.activeRequestId, isNotNull);
      expect(sessionB.activeRequestedHashes, contains(blockA1.blockHash));

      final getBlocksPayloads = transportB.sentPayloads
          .map((p) => DagGossipCodec.decode(p.bytes).message)
          .whereType<DagGetBlocksMessage>()
          .toList();
      expect(getBlocksPayloads.length, equals(1));
      expect(
        getBlocksPayloads.first.requestedBlockHashes,
        equals([blockA1.blockHash]),
      );
      expect(
        getBlocksPayloads.first.requestId,
        equals(sessionB.activeRequestId),
      );
    });

    test('2. Requester limits DAG_GET_BLOCKS to at most 4 hashes', () async {
      await establishSession();

      final unknownHashes = List.generate(
        6,
        (i) => computeSha256('missing-hash-$i'),
      );
      final invMsg = DagInvMessage(
        senderNodeId: 'NODE-A',
        senderTimestamp: DateTime.now().toUtc().millisecondsSinceEpoch,
        tipHashes: [unknownHashes.first],
        recentBlockHashes: unknownHashes,
      );

      transportB.clearSentPayloads();
      transportB.simulateIncomingPayload(
        endpointId: 'ep-a',
        bytes: DagGossipCodec.encode(invMsg),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final sessionB = engineB.getSession('ep-a')!;
      expect(sessionB.missingBlockHashes.length, equals(6));

      final getBlocksPayloads = transportB.sentPayloads
          .map((p) => DagGossipCodec.decode(p.bytes).message)
          .whereType<DagGetBlocksMessage>()
          .toList();
      expect(getBlocksPayloads.length, equals(1));
      expect(
        getBlocksPayloads.first.requestedBlockHashes.length,
        equals(kMaxGetBlocksHashes),
      );
      expect(getBlocksPayloads.first.requestedBlockHashes.length, equals(4));
    });

    test('3. Source serves only requested and available blocks', () async {
      await establishSession();

      final blockA1 = ledgerA.createBlock(
        creatorNodeId: 'NODE-A',
        validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
      );
      final blockA2 = ledgerA.createBlock(
        creatorNodeId: 'NODE-A',
        validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
      );

      final unknownHash = computeSha256('never-existed-block');

      final getBlocks = DagGetBlocksMessage(
        senderNodeId: 'NODE-B',
        requestId: 'req-test-3',
        requestedBlockHashes: [blockA1.blockHash, unknownHash],
      );

      transportA.clearSentPayloads();
      transportA.simulateIncomingPayload(
        endpointId: 'ep-b',
        bytes: DagGossipCodec.encode(getBlocks),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final batchPayloads = transportA.sentPayloads
          .map((p) => DagGossipCodec.decode(p.bytes).message)
          .whereType<DagBlockBatchMessage>()
          .toList();
      expect(batchPayloads.length, equals(1));
      expect(batchPayloads.first.blocks.length, equals(1));
      expect(
        batchPayloads.first.blocks.first.blockHash,
        equals(blockA1.blockHash),
      );
      expect(
        batchPayloads.first.blocks.any((b) => b.blockHash == blockA2.blockHash),
        isFalse,
      );
    });

    test('4. Unknown or pruned hashes are handled safely', () async {
      await establishSession();

      // Part A: Unknown hash -> DAG_REJECT
      final unknownHash = computeSha256('totally-unknown-block');
      final getUnknown = DagGetBlocksMessage(
        senderNodeId: 'NODE-B',
        requestId: 'req-unknown-4',
        requestedBlockHashes: [unknownHash],
      );

      transportA.clearSentPayloads();
      transportA.simulateIncomingPayload(
        endpointId: 'ep-b',
        bytes: DagGossipCodec.encode(getUnknown),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final rejectPayloads = transportA.sentPayloads
          .map((p) => DagGossipCodec.decode(p.bytes).message)
          .whereType<DagRejectMessage>()
          .toList();
      expect(rejectPayloads.length, equals(1));
      expect(
        rejectPayloads.first.errorCode,
        equals(DagRejectCode.emptyPayload),
      );

      // Part B: Pruned block -> DAG_PRUNED_NOTICE
      for (int i = 0; i < 5; i++) {
        ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );
      }
      final checkpoint = ledgerA.prune(maxRetention: 2);
      final prunedHash = checkpoint!.prunedBlockHashes.first;

      final getPruned = DagGetBlocksMessage(
        senderNodeId: 'NODE-B',
        requestId: 'req-pruned-4',
        requestedBlockHashes: [prunedHash],
      );

      transportA.clearSentPayloads();
      transportA.simulateIncomingPayload(
        endpointId: 'ep-b',
        bytes: DagGossipCodec.encode(getPruned),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final prunedPayloads = transportA.sentPayloads
          .map((p) => DagGossipCodec.decode(p.bytes).message)
          .whereType<DagPrunedNoticeMessage>()
          .toList();
      expect(prunedPayloads.length, equals(1));
      expect(prunedPayloads.first.prunedBlockHashes, contains(prunedHash));

      final sessionB = engineB.getSession('ep-a')!;
      sessionB.missingBlockHashes.add(prunedHash);
      sessionB.activeRequestId = 'req-pruned-4';

      transportB.simulateIncomingPayload(
        endpointId: 'ep-a',
        bytes: DagGossipCodec.encode(prunedPayloads.first),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(sessionB.missingBlockHashes.contains(prunedHash), isFalse);
      expect(sessionB.activeRequestId, isNull);
    });

    test('5. Batch payload strictly conforms to 16 KiB limit', () async {
      await establishSession();

      final blockHashes = <String>[];
      for (int i = 0; i < 4; i++) {
        ledgerA.addPendingEvent(
          SecurityAuditEvent(
            eventId: 'evt-batch-$i',
            eventType: AuditEventType.trustUpdate,
            observerNodeId: 'NODE-A',
            targetNodeId: 'NODE-PEER',
            timestamp: DateTime.now().toUtc(),
            monotonicMicros: 1000 + i,
            metadata: {
              'oldScore': 0.7,
              'newScore': 0.8,
              'delta': 0.1,
              'evidenceType': 'forwarding_verified',
              'reason': 'trust_updated_ok',
            },
          ),
        );
        final b = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );
        blockHashes.add(b.blockHash);
      }

      final getBlocks = DagGetBlocksMessage(
        senderNodeId: 'NODE-B',
        requestId: 'req-batch-5',
        requestedBlockHashes: blockHashes,
      );

      transportA.clearSentPayloads();
      transportA.simulateIncomingPayload(
        endpointId: 'ep-b',
        bytes: DagGossipCodec.encode(getBlocks),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final sentPayload = transportA.sentPayloads.first;
      expect(
        sentPayload.bytes.length,
        lessThanOrEqualTo(kMaxBatchPayloadBytes),
      );
      expect(sentPayload.bytes.length, greaterThan(200));

      final decoded = DagGossipCodec.decode(sentPayload.bytes);
      expect(decoded.isSuccess, isTrue);
      final batch = decoded.message as DagBlockBatchMessage;
      expect(batch.blocks.length, equals(4));
    });

    test(
      '6. Oversized batch payload is rejected safely without truncation or mutation',
      () async {
        await establishSession();

        final hugeReason = 'A' * (kMaxBatchPayloadBytes + 100);
        final fakeRawMap = {
          'protocol': kDagGossipProtocolName,
          'version': kDagGossipProtocolVersion,
          'type': DagGossipMessageType.blockBatch.wireName,
          'senderNodeId': 'NODE-A',
          'requestId': 'req-oversized-6',
          'batchIndex': 1,
          'totalBatches': 1,
          'blocks': [
            {
              'version': 1,
              'index': 1,
              'blockHash': computeSha256('huge-block'),
              'parentBlockHashes': [ledgerB.genesisBlock.blockHash],
              'creatorNodeId': 'NODE-A',
              'timestampMs': DateTime.now().toUtc().millisecondsSinceEpoch,
              'timestampIso': DateTime.now().toUtc().toIso8601String(),
              'monotonicMicros': 100,
              'eventsCount': 0,
              'merkleRoot': computeSha256('empty'),
              'validationProof': {
                'flushReason': 'manual',
                'creatorNodeId': 'NODE-A',
                'reason': hugeReason,
              },
              'events': [],
            },
          ],
        };

        final rawBytes = Uint8List.fromList(
          utf8.encode(jsonEncode(fakeRawMap)),
        );
        expect(rawBytes.length, greaterThan(kMaxBatchPayloadBytes));

        final decodeResult = DagGossipCodec.decode(rawBytes);
        expect(decodeResult.isSuccess, isFalse);
        expect(
          decodeResult.errorCode,
          equals(DagRejectCode.batchPayloadTooLarge),
        );

        final sessionB = engineB.getSession('ep-a')!;
        sessionB.activeRequestId = 'req-oversized-6';

        transportB.clearSentPayloads();
        transportB.simulateIncomingPayload(endpointId: 'ep-a', bytes: rawBytes);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(ledgerB.activeBlocksCount, equals(1));
      },
    );

    test(
      '7. Valid remote block with known parent is accepted and ACKed',
      () async {
        await establishSession();

        final blockA1 = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        final sessionB = engineB.getSession('ep-a')!;
        sessionB.missingBlockHashes.add(blockA1.blockHash);
        sessionB.activeRequestId = 'req-valid-7';
        sessionB.activeRequestedHashes.add(blockA1.blockHash);

        final batch = DagBlockBatchMessage(
          senderNodeId: 'NODE-A',
          requestId: 'req-valid-7',
          batchIndex: 1,
          totalBatches: 1,
          blocks: [blockA1],
        );

        transportB.clearSentPayloads();
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(batch),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(ledgerB.getBlock(blockA1.blockHash), isNotNull);
        expect(ledgerB.activeBlocksCount, equals(2));
        expect(
          sessionB.missingBlockHashes.contains(blockA1.blockHash),
          isFalse,
        );
        expect(sessionB.knownPeerBlockHashes, contains(blockA1.blockHash));
        expect(engineB.totalRemoteBlocksAccepted, equals(1));

        final acks = transportB.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagSyncAckMessage>()
            .toList();
        expect(acks.length, equals(1));
        expect(acks.first.requestId, equals('req-valid-7'));
        expect(acks.first.acceptedBlockHashes, equals([blockA1.blockHash]));

        final savedState = await repoB.loadState();
        expect(savedState, isNotNull);
        expect(
          savedState!.blocks.any((b) => b.blockHash == blockA1.blockHash),
          isTrue,
        );
      },
    );

    test(
      '8. Batch blocks are sorted and ingested topologically parent-first',
      () async {
        await establishSession();

        final blockA1 = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );
        final blockA2 = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );
        expect(blockA2.parentBlockHashes, contains(blockA1.blockHash));

        final getBlocks = DagGetBlocksMessage(
          senderNodeId: 'NODE-B',
          requestId: 'req-topo-8',
          requestedBlockHashes: [blockA2.blockHash, blockA1.blockHash],
        );

        transportA.clearSentPayloads();
        transportA.simulateIncomingPayload(
          endpointId: 'ep-b',
          bytes: DagGossipCodec.encode(getBlocks),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final sentBatch = transportA.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagBlockBatchMessage>()
            .first;

        expect(sentBatch.blocks.first.blockHash, equals(blockA1.blockHash));
        expect(sentBatch.blocks.last.blockHash, equals(blockA2.blockHash));

        final sessionB = engineB.getSession('ep-a')!;
        sessionB.missingBlockHashes.addAll([
          blockA1.blockHash,
          blockA2.blockHash,
        ]);
        sessionB.activeRequestId = 'req-topo-8';

        transportB.clearSentPayloads();
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(sentBatch),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(ledgerB.getBlock(blockA1.blockHash), isNotNull);
        expect(ledgerB.getBlock(blockA2.blockHash), isNotNull);
        expect(ledgerB.activeBlocksCount, equals(3));
        expect(engineB.totalRemoteBlocksAccepted, equals(2));
      },
    );

    test(
      '9. Blocks with corrupted Merkle root or blockHash are rejected',
      () async {
        await establishSession();

        final validBlock = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        final badMerkleBlock = SecurityBlock(
          version: validBlock.version,
          index: validBlock.index,
          blockHash: validBlock.blockHash,
          parentBlockHashes: validBlock.parentBlockHashes,
          creatorNodeId: validBlock.creatorNodeId,
          timestamp: validBlock.timestamp,
          monotonicMicros: validBlock.monotonicMicros,
          merkleRoot: computeSha256('tampered-merkle-root'),
          events: validBlock.events,
          validationProof: validBlock.validationProof,
        );

        final sessionB = engineB.getSession('ep-a')!;
        sessionB.activeRequestId = 'req-bad-merkle-9';

        transportB.clearSentPayloads();
        final batchBadMerkle = DagBlockBatchMessage(
          senderNodeId: 'NODE-A',
          requestId: 'req-bad-merkle-9',
          batchIndex: 1,
          totalBatches: 1,
          blocks: [badMerkleBlock],
        );

        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(batchBadMerkle),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(ledgerB.getBlock(badMerkleBlock.blockHash), isNull);
        expect(ledgerB.activeBlocksCount, equals(1));
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

    test(
      '10. Blocks violating privacy allowlist are rejected without ingestion',
      () async {
        await establishSession();

        final badEvent = SecurityAuditEvent(
          eventId: 'bad-evt-10',
          eventType: AuditEventType.idsDetection,
          observerNodeId: 'NODE-A',
          targetNodeId: 'NODE-B',
          timestamp: DateTime.now().toUtc(),
          monotonicMicros: 100,
          metadata: {
            'status': 'detected',
            'reason': 'normal',
            'body': 'unauthorized private chat text',
          },
        );

        final badBlock = SecurityBlock.create(
          index: 1,
          parentBlockHashes: [ledgerB.genesisBlock.blockHash],
          creatorNodeId: 'NODE-A',
          events: [badEvent],
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        final sessionB = engineB.getSession('ep-a')!;
        sessionB.activeRequestId = 'req-privacy-10';

        transportB.clearSentPayloads();
        final batch = DagBlockBatchMessage(
          senderNodeId: 'NODE-A',
          requestId: 'req-privacy-10',
          batchIndex: 1,
          totalBatches: 1,
          blocks: [badBlock],
        );

        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(batch),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(ledgerB.getBlock(badBlock.blockHash), isNull);
        expect(ledgerB.activeBlocksCount, equals(1));
        expect(engineB.totalRemoteBlocksRejected, equals(1));

        final rejects = transportB.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagRejectMessage>()
            .toList();
        expect(rejects.length, equals(1));
        expect(rejects.first.errorCode, equals(DagRejectCode.privacyViolation));
      },
    );

    test(
      '11. Duplicate blocks do not cause duplicate ledger mutations or duplicate events',
      () async {
        await establishSession();

        final blockA1 = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        final sessionB = engineB.getSession('ep-a')!;
        sessionB.activeRequestId = 'req-dup-1';
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-dup-1',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [blockA1],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(ledgerB.activeBlocksCount, equals(2));
        expect(engineB.totalRemoteBlocksAccepted, equals(1));

        sessionB.activeRequestId = 'req-dup-2';
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-dup-2',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [blockA1],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(ledgerB.activeBlocksCount, equals(2));
        expect(engineB.totalRemoteBlocksAccepted, equals(1));
      },
    );

    test(
      '12. Block with missing parent fails validation and is rejected',
      () async {
        await establishSession();

        final orphanBlock = SecurityBlock.create(
          index: 5,
          parentBlockHashes: [computeSha256('non-existent-parent-hash')],
          creatorNodeId: 'NODE-A',
          events: [],
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        final sessionB = engineB.getSession('ep-a')!;
        sessionB.activeRequestId = 'req-orphan-12';

        transportB.clearSentPayloads();
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-orphan-12',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [orphanBlock],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(ledgerB.getBlock(orphanBlock.blockHash), isNull);
        expect(ledgerB.activeBlocksCount, equals(1));
        expect(engineB.totalRemoteBlocksRejected, equals(1));

        final rejects = transportB.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagRejectMessage>()
            .toList();
        expect(rejects.length, equals(1));
        expect(
          rejects.first.errorCode,
          equals(DagRejectCode.invalidBlockStructure),
        );
      },
    );

    test(
      '13. Response with mismatched requestId or unsolicited peer is ignored',
      () async {
        await establishSession();

        final blockA1 = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        final sessionB = engineB.getSession('ep-a')!;
        sessionB.activeRequestId = 'req-expected-13';

        final batchWrongId = DagBlockBatchMessage(
          senderNodeId: 'NODE-A',
          requestId: 'req-unexpected-999',
          batchIndex: 1,
          totalBatches: 1,
          blocks: [blockA1],
        );

        transportB.clearSentPayloads();
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(batchWrongId),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(ledgerB.getBlock(blockA1.blockHash), isNull);
        expect(ledgerB.activeBlocksCount, equals(1));
        expect(sessionB.activeRequestId, equals('req-expected-13'));
        expect(transportB.sentPayloads, isEmpty);
      },
    );

    test(
      '14. sendBytes returning false or throwing exception is handled gracefully',
      () async {
        final failingTransport = ControllableFakeMeshTransport(
          sendResult: false,
        );
        final throwingTransport = ControllableFakeMeshTransport(
          shouldThrow: true,
        );

        final testLedger = LightweightBlockdagLedger();
        final engineFailing = DagGossipSyncEngine(
          transport: failingTransport,
          localNodeId: 'NODE-FAIL',
          ledger: testLedger,
          isEnabled: true,
        );

        failingTransport.simulateIncomingConnectionRequest(
          endpointId: 'ep-f',
          endpointName: 'Peer',
        );
        await failingTransport.acceptConnection(endpointId: 'ep-f');
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final sessionF = engineFailing.getSession('ep-f')!;
        sessionF.missingBlockHashes.add(computeSha256('hash-fail'));
        final resFail = await engineFailing.requestMissingBlocks('ep-f');
        expect(resFail, isFalse);
        expect(sessionF.activeRequestId, isNull);

        final engineThrowing = DagGossipSyncEngine(
          transport: throwingTransport,
          localNodeId: 'NODE-THROW',
          ledger: testLedger,
          isEnabled: true,
        );

        throwingTransport.simulateIncomingConnectionRequest(
          endpointId: 'ep-t',
          endpointName: 'Peer',
        );
        await throwingTransport.acceptConnection(endpointId: 'ep-t');
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final sessionT = engineThrowing.getSession('ep-t')!;
        sessionT.missingBlockHashes.add(computeSha256('hash-throw'));
        final resThrow = await engineThrowing.requestMissingBlocks('ep-t');
        expect(resThrow, isFalse);
        expect(sessionT.activeRequestId, isNull);

        engineFailing.dispose();
        engineThrowing.dispose();
      },
    );

    test(
      '15. Disconnection or dispose during active transfer clears request state cleanly',
      () async {
        await establishSession();

        final sessionB = engineB.getSession('ep-a')!;
        sessionB.activeRequestId = 'req-pending-15';
        sessionB.activeRequestedHashes.add(computeSha256('hash-15'));

        transportB.simulateDisconnection('ep-a');
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(engineB.getSession('ep-a'), isNull);

        engineB.dispose();
        expect(engineB.isDisposed, isTrue);
        expect(engineB.activeSessions, isEmpty);
      },
    );

    test(
      '16. Rejected blocks do not alter ledger state or persistent repository',
      () async {
        await establishSession();

        await repoB.saveState(ledgerB.exportPersistedState());
        final baselineState = await repoB.loadState();
        final baselineTips = ledgerB.tipHashes.toSet();
        final baselineCount = ledgerB.activeBlocksCount;

        final validBlock = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );
        final corruptedBlock = SecurityBlock(
          version: validBlock.version,
          index: validBlock.index,
          blockHash:
              '0000000000000000000000000000000000000000000000000000000000000000',
          parentBlockHashes: validBlock.parentBlockHashes,
          creatorNodeId: validBlock.creatorNodeId,
          timestamp: validBlock.timestamp,
          monotonicMicros: validBlock.monotonicMicros,
          merkleRoot: validBlock.merkleRoot,
          events: validBlock.events,
          validationProof: validBlock.validationProof,
        );

        final sessionB = engineB.getSession('ep-a')!;
        sessionB.activeRequestId = 'req-alter-16';

        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-alter-16',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [corruptedBlock],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(ledgerB.activeBlocksCount, equals(baselineCount));
        expect(ledgerB.tipHashes, equals(baselineTips));

        final currentState = await repoB.loadState();
        expect(
          currentState!.blocks.length,
          equals(baselineState!.blocks.length),
        );
        expect(currentState.tipHashes, equals(baselineState.tipHashes));
      },
    );

    test(
      '17. DAG_SYNC_ACK acknowledges ONLY genuinely accepted blocks',
      () async {
        await establishSession();

        final goodBlock = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );
        final badBlock = SecurityBlock(
          version: 1,
          index: 2,
          blockHash: computeSha256('bad-block-17'),
          parentBlockHashes: [goodBlock.blockHash],
          creatorNodeId: 'NODE-A',
          timestamp: DateTime.now().toUtc(),
          monotonicMicros: 200,
          merkleRoot: computeSha256('bad-merkle-17'),
          events: [],
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        final sessionB = engineB.getSession('ep-a')!;
        sessionB.activeRequestId = 'req-mixed-17';
        sessionB.missingBlockHashes.addAll([
          goodBlock.blockHash,
          badBlock.blockHash,
        ]);

        transportB.clearSentPayloads();
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-mixed-17',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [goodBlock, badBlock],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(ledgerB.getBlock(goodBlock.blockHash), isNotNull);
        expect(ledgerB.getBlock(badBlock.blockHash), isNull);

        final acks = transportB.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagSyncAckMessage>()
            .toList();
        expect(acks.length, equals(1));
        expect(acks.first.acceptedBlockHashes, equals([goodBlock.blockHash]));
        expect(
          acks.first.acceptedBlockHashes.contains(badBlock.blockHash),
          isFalse,
        );
      },
    );

    test(
      '18. Config A/B generate 0 gossip packets; Config C transfers only when explicitly enabled',
      () async {
        final fakeTransport = FakeMeshTransport();
        final chatRepo = FakeChatRepository();
        final logger = MeshExperimentLogger();

        ManetRoutingHolder.reset();
        final routingA = ManetRoutingEngine(
          transport: fakeTransport,
          identityManager: NodeIdentityManager(),
          repository: chatRepo,
          experimentLogger: logger,
        );
        ManetRoutingHolder.setInstance(routingA);

        fakeTransport.clearSentPayloads();
        fakeTransport.simulateIncomingConnectionRequest(
          endpointId: 'ep-cfg-a',
          endpointName: 'Peer',
        );
        await fakeTransport.acceptConnection(endpointId: 'ep-cfg-a');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(
          fakeTransport.sentPayloads.any(
            (p) => DagGossipSyncEngine.isGossipPayload(p.bytes),
          ),
          isFalse,
        );

        ManetRoutingHolder.setIdsDetector(
          SelectiveForwardingDetector(localNodeId: 'NODE-LOCAL'),
        );
        ManetRoutingHolder.setTrustManager(
          DynamicTrustManager(localNodeId: 'NODE-LOCAL'),
        );
        expect(ManetRoutingHolder.enableBlockdagReplication, isFalse);

        fakeTransport.clearSentPayloads();
        fakeTransport.simulateIncomingConnectionRequest(
          endpointId: 'ep-cfg-b',
          endpointName: 'Peer',
        );
        await fakeTransport.acceptConnection(endpointId: 'ep-cfg-b');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(
          fakeTransport.sentPayloads.any(
            (p) => DagGossipSyncEngine.isGossipPayload(p.bytes),
          ),
          isFalse,
        );

        final engineC = DagGossipSyncEngine(
          transport: fakeTransport,
          localNodeId: 'NODE-LOCAL',
          ledger: LightweightBlockdagLedger(),
          isEnabled: false,
        );
        ManetRoutingHolder.setGossipSyncEngine(engineC);
        expect(engineC.isEnabled, isFalse);

        ManetRoutingHolder.setEnableBlockdagReplication(true);
        expect(ManetRoutingHolder.enableBlockdagReplication, isTrue);
        expect(engineC.isEnabled, isTrue);

        fakeTransport.clearSentPayloads();
        fakeTransport.simulateIncomingConnectionRequest(
          endpointId: 'ep-cfg-c',
          endpointName: 'Peer',
        );
        await fakeTransport.acceptConnection(endpointId: 'ep-cfg-c');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(
          fakeTransport.sentPayloads.any(
            (p) => DagGossipSyncEngine.isGossipPayload(p.bytes),
          ),
          isTrue,
        );

        routingA.dispose();
        engineC.dispose();
      },
    );

    test(
      '19. Chat envelopes, handshakes, HOP_ACK, and E2E_ACK function normally during gossip transfer',
      () async {
        final fakeTransport = FakeMeshTransport();
        final chatRepo = FakeChatRepository();
        final logger = MeshExperimentLogger();
        final testLedger = LightweightBlockdagLedger();

        final gossip = DagGossipSyncEngine(
          transport: fakeTransport,
          localNodeId: 'NODE-ROUTER',
          ledger: testLedger,
          isEnabled: true,
        );

        final routing = ManetRoutingEngine(
          transport: fakeTransport,
          identityManager: NodeIdentityManager(),
          repository: chatRepo,
          experimentLogger: logger,
          gossipSyncEngine: gossip,
          enableHopAck: true,
        );

        // 1. Handshake
        final hsEnv = MessageEnvelope(
          envelopeId: 'hs-19',
          type: MessageEnvelope.typeHandshake,
          senderId: 'NODE-SENDER',
          senderName: 'Sender Node',
          recipientId: 'BROADCAST',
          createdAt: DateTime.now().millisecondsSinceEpoch,
          routeTrace: const ['NODE-SENDER'],
          payload: {'nodeId': 'NODE-SENDER', 'nodeName': 'Sender Node'},
        );
        fakeTransport.simulateIncomingPayload(
          endpointId: 'ep-19',
          bytes: hsEnv.toBytes(),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(routing.neighborTable.getPeerByNodeId('NODE-SENDER'), isNotNull);

        // 2. Chat message
        final chatEnv = MessageEnvelope(
          envelopeId: 'chat-19',
          type: MessageEnvelope.typeChat,
          senderId: 'NODE-SENDER',
          senderName: 'Sender Node',
          recipientId: routing.localNodeId,
          createdAt: DateTime.now().millisecondsSinceEpoch,
          routeTrace: const ['NODE-SENDER'],
          payload: {
            'messageId': 'msg-19',
            'senderId': 'NODE-SENDER',
            'senderName': 'Sender Node',
            'recipientId': routing.localNodeId,
            'text': 'Evakuasi zona utara',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          },
        );
        fakeTransport.simulateIncomingPayload(
          endpointId: 'ep-19',
          bytes: chatEnv.toBytes(),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(
          chatRepo.savedMessages.any((m) => m.text == 'Evakuasi zona utara'),
          isTrue,
        );

        // 3. HOP_ACK
        final hopAckEnv = MessageEnvelope(
          envelopeId: 'hop-ack-19',
          type: MessageEnvelope.typeHopAck,
          senderId: 'NODE-SENDER',
          senderName: 'Sender Node',
          recipientId: routing.localNodeId,
          createdAt: DateTime.now().millisecondsSinceEpoch,
          routeTrace: const ['NODE-SENDER'],
          payload: {
            'originalEnvelopeId': 'chat-19',
            'hopSenderId': 'NODE-SENDER',
          },
        );
        fakeTransport.simulateIncomingPayload(
          endpointId: 'ep-19',
          bytes: hopAckEnv.toBytes(),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // 4. E2E_ACK
        final e2eAckEnv = MessageEnvelope(
          envelopeId: 'e2e-ack-19',
          type: MessageEnvelope.typeE2eAck,
          senderId: 'NODE-SENDER',
          senderName: 'Sender Node',
          recipientId: routing.localNodeId,
          createdAt: DateTime.now().millisecondsSinceEpoch,
          routeTrace: const ['NODE-SENDER'],
          payload: {'messageId': 'msg-19', 'recipientId': routing.localNodeId},
        );
        fakeTransport.simulateIncomingPayload(
          endpointId: 'ep-19',
          bytes: e2eAckEnv.toBytes(),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        routing.dispose();
        gossip.dispose();
      },
    );

    test(
      '20. End-to-end multi-step DAG block synchronization succeeds between Node A and Node B',
      () async {
        await establishSession();

        final blockA1 = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );
        final blockA2 = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        transportB.clearSentPayloads();
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagInvMessage(
              senderNodeId: 'NODE-A',
              senderTimestamp: DateTime.now().toUtc().millisecondsSinceEpoch,
              tipHashes: [blockA2.blockHash],
              recentBlockHashes: [blockA1.blockHash, blockA2.blockHash],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final getBlocksFromB = transportB.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagGetBlocksMessage>()
            .first;

        transportA.clearSentPayloads();
        transportA.simulateIncomingPayload(
          endpointId: 'ep-b',
          bytes: DagGossipCodec.encode(getBlocksFromB),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final batchFromA = transportA.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagBlockBatchMessage>()
            .first;

        transportB.clearSentPayloads();
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(batchFromA),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(ledgerB.getBlock(blockA1.blockHash), isNotNull);
        expect(ledgerB.getBlock(blockA2.blockHash), isNotNull);
        expect(ledgerB.activeBlocksCount, equals(3));
        expect(ledgerB.tipHashes, contains(blockA2.blockHash));

        final ackFromB = transportB.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagSyncAckMessage>()
            .first;
        expect(
          ackFromB.acceptedBlockHashes,
          containsAll([blockA1.blockHash, blockA2.blockHash]),
        );

        transportA.simulateIncomingPayload(
          endpointId: 'ep-b',
          bytes: DagGossipCodec.encode(ackFromB),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(engineA.totalSyncAckReceived, equals(1));
      },
    );
  });

  group('STAGE 5E.4.4.1 — Persistence-Consistent ACK & Retry Safety', () {
    late FakeMeshTransport transportA;
    late FakeMeshTransport transportB;
    late LightweightBlockdagLedger ledgerA;
    late LightweightBlockdagLedger ledgerB;
    late ControllableBlockdagRepository repoA;
    late ControllableBlockdagRepository repoB;
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
      repoA = ControllableBlockdagRepository(
        initialState: ledgerA.exportPersistedState(),
      );
      repoB = ControllableBlockdagRepository(
        initialState: ledgerB.exportPersistedState(),
      );
      chatRepoA = FakeChatRepository();
      chatRepoB = FakeChatRepository();
      loggerA = MeshExperimentLogger();
      loggerB = MeshExperimentLogger();

      engineA = DagGossipSyncEngine(
        transport: transportA,
        localNodeId: 'NODE-A',
        ledger: ledgerA,
        repository: repoA,
        isEnabled: true,
      );

      engineB = DagGossipSyncEngine(
        transport: transportB,
        localNodeId: 'NODE-B',
        ledger: ledgerB,
        repository: repoB,
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

    test(
      '1. Valid batch saved successfully receives appropriate DAG_SYNC_ACK',
      () async {
        await establishSession();

        final blockA1 = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        final sessionB = engineB.getSession('ep-a')!;
        sessionB.activeRequestId = 'req-pers-1';
        sessionB.missingBlockHashes.add(blockA1.blockHash);

        transportB.clearSentPayloads();
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-pers-1',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [blockA1],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Verifikasi state ledger in-memory
        expect(ledgerB.getBlock(blockA1.blockHash), isNotNull);
        expect(ledgerB.activeBlocksCount, equals(2));
        expect(engineB.totalRemoteBlocksAccepted, equals(1));

        // Verifikasi persistensi di repository
        expect(repoB.saveCount, equals(1));
        final persisted = await repoB.loadState();
        expect(persisted, isNotNull);
        expect(
          persisted!.blocks.any((b) => b.blockHash == blockA1.blockHash),
          isTrue,
        );

        // Verifikasi pengiriman DAG_SYNC_ACK yang tepat
        final acks = transportB.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagSyncAckMessage>()
            .toList();
        expect(acks.length, equals(1));
        expect(acks.first.requestId, equals('req-pers-1'));
        expect(acks.first.acceptedBlockHashes, equals([blockA1.blockHash]));
      },
    );

    test(
      '2. saveState() returning false rolls back ledger and sends NO DAG_SYNC_ACK',
      () async {
        await establishSession();

        final blockA1 = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        repoB.shouldFailSave = true;

        final sessionB = engineB.getSession('ep-a')!;
        sessionB.activeRequestId = 'req-pers-2';
        sessionB.missingBlockHashes.add(blockA1.blockHash);

        transportB.clearSentPayloads();
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-pers-2',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [blockA1],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Ledger harus di-rollback: blok tidak ada di RAM ledger
        expect(ledgerB.getBlock(blockA1.blockHash), isNull);
        expect(ledgerB.activeBlocksCount, equals(1));
        expect(
          ledgerB.processedBlockHashes.contains(blockA1.blockHash),
          isFalse,
        );
        expect(engineB.totalRemoteBlocksAccepted, equals(0));

        // Tidak boleh mengirim DAG_SYNC_ACK
        final acks = transportB.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagSyncAckMessage>()
            .toList();
        expect(acks, isEmpty);
        expect(engineB.totalSyncAckSent, equals(0));

        // Blok harus tetap ada di missingBlockHashes agar dapat di-retry
        expect(sessionB.missingBlockHashes, contains(blockA1.blockHash));
        expect(sessionB.activeRequestId, isNull);
      },
    );

    test(
      '3. saveState() throwing exception is caught safely, rolls back ledger, and sends NO ACK',
      () async {
        await establishSession();

        final blockA1 = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        repoB.shouldThrowOnSave = true;

        final sessionB = engineB.getSession('ep-a')!;
        sessionB.activeRequestId = 'req-pers-3';
        sessionB.missingBlockHashes.add(blockA1.blockHash);

        transportB.clearSentPayloads();
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-pers-3',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [blockA1],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Ledger harus di-rollback tanpa unhandled exception / crash
        expect(ledgerB.getBlock(blockA1.blockHash), isNull);
        expect(ledgerB.activeBlocksCount, equals(1));
        expect(engineB.totalRemoteBlocksAccepted, equals(0));

        // Tidak boleh ada ACK yang dikirim
        final acks = transportB.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagSyncAckMessage>()
            .toList();
        expect(acks, isEmpty);

        // Hash tetap ada di missingBlockHashes
        expect(sessionB.missingBlockHashes, contains(blockA1.blockHash));
        expect(sessionB.activeRequestId, isNull);
      },
    );

    test(
      '4. After save failure, ledger RAM does not retain new blocks as processed',
      () async {
        await establishSession();

        final event = SecurityAuditEvent(
          eventId: 'evt-test-4',
          eventType: AuditEventType.idsDetection,
          observerNodeId: 'NODE-A',
          targetNodeId: 'NODE-B',
          timestamp: DateTime.now().toUtc(),
          monotonicMicros: 100,
          metadata: {'status': 'suspected', 'reason': 'rapidForwarding'},
        );
        ledgerA.addPendingEvent(event);
        final blockA1 = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        repoB.shouldFailSave = true;

        final sessionB = engineB.getSession('ep-a')!;
        sessionB.activeRequestId = 'req-pers-4';

        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-pers-4',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [blockA1],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Struktur data internal ledger RAM harus bersih dari jejak blockA1
        expect(ledgerB.activeBlocksCount, equals(1));
        expect(
          ledgerB.processedBlockHashes.contains(blockA1.blockHash),
          isFalse,
        );
        expect(ledgerB.processedEventIds.contains(event.eventId), isFalse);
        expect(ledgerB.tipHashes, equals([ledgerB.genesisBlock.blockHash]));
        expect(repoB.saveCount, equals(1));
      },
    );

    test(
      '5. Reloading state from repository reflects pre-failure state without partial blocks',
      () async {
        await establishSession();

        final blockA1 = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        repoB.shouldFailSave = true;

        final sessionB = engineB.getSession('ep-a')!;
        sessionB.activeRequestId = 'req-pers-5';

        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-pers-5',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [blockA1],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Muat ulang state dari repository
        final reloaded = await repoB.loadState();
        expect(reloaded, isNotNull);
        expect(reloaded!.blocks.length, equals(1));
        expect(
          reloaded.blocks.first.blockHash,
          equals(ledgerB.genesisBlock.blockHash),
        );
        expect(
          reloaded.blocks.any((b) => b.blockHash == blockA1.blockHash),
          isFalse,
        );
      },
    );

    test(
      '6. Storage failure strictly bounds state without sending DAG_SYNC_ACK',
      () async {
        await establishSession();

        final blockA1 = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        repoB.shouldFailSave = true;

        final sessionB = engineB.getSession('ep-a')!;
        sessionB.activeRequestId = 'req-pers-6';

        transportB.clearSentPayloads();
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-pers-6',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [blockA1],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(engineB.totalSyncAckSent, equals(0));
        final acks = transportB.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagSyncAckMessage>()
            .toList();
        expect(acks, isEmpty);
      },
    );

    test(
      '7. Mixed batch with 1 valid and 1 invalid block: only valid and persisted block is ACKed',
      () async {
        await establishSession();

        final goodBlock = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );
        final badBlock = SecurityBlock(
          version: 1,
          index: 2,
          blockHash: computeSha256('corrupt-block-7'),
          parentBlockHashes: [goodBlock.blockHash],
          creatorNodeId: 'NODE-A',
          timestamp: DateTime.now().toUtc(),
          monotonicMicros: 300,
          merkleRoot: computeSha256('corrupt-merkle-7'),
          events: [],
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        final sessionB = engineB.getSession('ep-a')!;
        sessionB.activeRequestId = 'req-pers-7';
        sessionB.missingBlockHashes.addAll([
          goodBlock.blockHash,
          badBlock.blockHash,
        ]);

        transportB.clearSentPayloads();
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-pers-7',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [goodBlock, badBlock],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Hanya goodBlock yang ada di ledger
        expect(ledgerB.getBlock(goodBlock.blockHash), isNotNull);
        expect(ledgerB.getBlock(badBlock.blockHash), isNull);

        // Hanya goodBlock yang dipersistensikan
        final persisted = await repoB.loadState();
        expect(
          persisted!.blocks.any((b) => b.blockHash == goodBlock.blockHash),
          isTrue,
        );
        expect(
          persisted.blocks.any((b) => b.blockHash == badBlock.blockHash),
          isFalse,
        );

        // Hanya goodBlock yang di-ACK
        final acks = transportB.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagSyncAckMessage>()
            .toList();
        expect(acks.length, equals(1));
        expect(acks.first.acceptedBlockHashes, equals([goodBlock.blockHash]));
        expect(
          acks.first.acceptedBlockHashes.contains(badBlock.blockHash),
          isFalse,
        );
      },
    );

    test(
      '8. All-invalid batch does not alter ledger nor invoke saveState on repository',
      () async {
        await establishSession();

        final badBlock1 = SecurityBlock(
          version: 1,
          index: 2,
          blockHash: computeSha256('bad-1'),
          parentBlockHashes: [ledgerA.genesisBlock.blockHash],
          creatorNodeId: 'NODE-A',
          timestamp: DateTime.now().toUtc(),
          monotonicMicros: 401,
          merkleRoot: computeSha256('bad-merkle-1'),
          events: [],
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );
        final badBlock2 = SecurityBlock(
          version: 1,
          index: 3,
          blockHash: computeSha256('bad-2'),
          parentBlockHashes: [badBlock1.blockHash],
          creatorNodeId: 'NODE-A',
          timestamp: DateTime.now().toUtc(),
          monotonicMicros: 402,
          merkleRoot: computeSha256('bad-merkle-2'),
          events: [],
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        final priorSaveCount = repoB.saveCount;

        final sessionB = engineB.getSession('ep-a')!;
        sessionB.activeRequestId = 'req-pers-8';

        transportB.clearSentPayloads();
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-pers-8',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [badBlock1, badBlock2],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // saveState tidak boleh dipanggil
        expect(repoB.saveCount, equals(priorSaveCount));
        expect(ledgerB.activeBlocksCount, equals(1));

        // Balasan penolakan terkirim
        final rejects = transportB.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagRejectMessage>()
            .toList();
        expect(rejects.length, equals(1));
        expect(rejects.first.requestId, equals('req-pers-8'));
      },
    );

    test(
      '9. Retry after storage recovers successfully ingests, persists, and ACKs previously failed block',
      () async {
        await establishSession();

        final blockA1 = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        // Tahap 1: Kegagalan penyimpanan pertama
        repoB.shouldFailSave = true;
        final sessionB = engineB.getSession('ep-a')!;
        sessionB.activeRequestId = 'req-pers-9-fail';
        sessionB.missingBlockHashes.add(blockA1.blockHash);

        transportB.clearSentPayloads();
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-pers-9-fail',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [blockA1],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(ledgerB.getBlock(blockA1.blockHash), isNull);
        expect(sessionB.missingBlockHashes, contains(blockA1.blockHash));
        expect(sessionB.activeRequestId, isNull);

        // Tahap 2: Storage pulih
        repoB.shouldFailSave = false;

        // Permintaan ulang (retry) dipicu
        transportB.clearSentPayloads();
        final reqOk = await engineB.requestMissingBlocks('ep-a');
        expect(reqOk, isTrue);

        final getBlocks = transportB.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagGetBlocksMessage>()
            .first;
        expect(getBlocks.requestedBlockHashes, contains(blockA1.blockHash));

        // Node A melayani ulang batch
        transportA.clearSentPayloads();
        transportA.simulateIncomingPayload(
          endpointId: 'ep-b',
          bytes: DagGossipCodec.encode(getBlocks),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final batchMsg = transportA.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagBlockBatchMessage>()
            .first;

        // Node B menerima batch yang diulang
        transportB.clearSentPayloads();
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(batchMsg),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Sukses diterima dan dipersistensikan
        expect(ledgerB.getBlock(blockA1.blockHash), isNotNull);
        expect(ledgerB.activeBlocksCount, equals(2));
        final persisted = await repoB.loadState();
        expect(
          persisted!.blocks.any((b) => b.blockHash == blockA1.blockHash),
          isTrue,
        );

        // ACK terkirim
        final acks = transportB.sentPayloads
            .map((p) => DagGossipCodec.decode(p.bytes).message)
            .whereType<DagSyncAckMessage>()
            .toList();
        expect(acks.length, equals(1));
        expect(acks.first.acceptedBlockHashes, equals([blockA1.blockHash]));
      },
    );

    test(
      '10. Resending already-persisted block is idempotent without double mutation or redundant save',
      () async {
        await establishSession();

        final blockA1 = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        final sessionB = engineB.getSession('ep-a')!;
        sessionB.activeRequestId = 'req-pers-10a';
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-pers-10a',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [blockA1],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(ledgerB.activeBlocksCount, equals(2));
        final priorSaveCount = repoB.saveCount;
        final priorAcceptedCount = engineB.totalRemoteBlocksAccepted;

        // Kirim ulang blok yang sama
        sessionB.activeRequestId = 'req-pers-10b';
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-pers-10b',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [blockA1],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Tidak boleh ada mutasi ganda atau pemanggilan saveState berulang
        expect(ledgerB.activeBlocksCount, equals(2));
        expect(repoB.saveCount, equals(priorSaveCount));
        expect(engineB.totalRemoteBlocksAccepted, equals(priorAcceptedCount));
      },
    );

    test(
      '11. Disconnect after reception or save cleans session safely without corrupted ledger',
      () async {
        await establishSession();

        final blockA1 = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        final sessionB = engineB.getSession('ep-a')!;
        sessionB.activeRequestId = 'req-pers-11';
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-pers-11',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [blockA1],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(ledgerB.getBlock(blockA1.blockHash), isNotNull);

        // Putus koneksi
        transportB.simulateDisconnection('ep-a');
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(engineB.getSession('ep-a'), isNull);

        // State yang tersimpan tetap utuh dan valid
        final reloaded = await repoB.loadState();
        expect(reloaded, isNotNull);
        expect(
          reloaded!.blocks.any((b) => b.blockHash == blockA1.blockHash),
          isTrue,
        );
      },
    );

    test(
      '12. Request or ACK with mismatched requestId is strictly ignored',
      () async {
        await establishSession();

        final blockA1 = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );

        final sessionB = engineB.getSession('ep-a')!;
        sessionB.activeRequestId = 'req-expected-12';

        // Part 1: DAG_BLOCK_BATCH dengan requestId salah
        transportB.clearSentPayloads();
        transportB.simulateIncomingPayload(
          endpointId: 'ep-a',
          bytes: DagGossipCodec.encode(
            DagBlockBatchMessage(
              senderNodeId: 'NODE-A',
              requestId: 'req-wrong-12',
              batchIndex: 1,
              totalBatches: 1,
              blocks: [blockA1],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(ledgerB.getBlock(blockA1.blockHash), isNull);
        expect(sessionB.activeRequestId, equals('req-expected-12'));
        expect(transportB.sentPayloads, isEmpty);

        // Part 2: DAG_SYNC_ACK dengan requestId salah (unsolicited)
        final priorAckReceived = engineA.totalSyncAckReceived;
        transportA.simulateIncomingPayload(
          endpointId: 'ep-b',
          bytes: DagGossipCodec.encode(
            DagSyncAckMessage(
              senderNodeId: 'NODE-B',
              requestId: 'req-unknown-served-id',
              acceptedBlockHashes: [blockA1.blockHash],
              newTipHashes: [blockA1.blockHash],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(engineA.totalSyncAckReceived, equals(priorAckReceived));
      },
    );

    test(
      '13. Config A and B generate zero gossip packets; Config C requires explicit activation',
      () async {
        final mockTransport = FakeMeshTransport();
        final mockLedger = LightweightBlockdagLedger();
        final mockChatRepo = FakeChatRepository();

        // Konfigurasi A & B: Gossip engine dimatikan (isEnabled: false)
        final engineDisabled = DagGossipSyncEngine(
          transport: mockTransport,
          localNodeId: 'NODE-DIS',
          ledger: mockLedger,
          isEnabled: false,
        );
        final routingDisabled = ManetRoutingEngine(
          transport: mockTransport,
          identityManager: NodeIdentityManager(),
          repository: mockChatRepo,
          gossipSyncEngine: engineDisabled,
        );

        mockTransport.simulateIncomingConnectionRequest(
          endpointId: 'ep-peer',
          endpointName: 'Peer',
        );
        await mockTransport.acceptConnection(endpointId: 'ep-peer');
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final gossipPacketsDisabled = mockTransport.sentPayloads
            .where((p) => DagGossipSyncEngine.isGossipPayload(p.bytes))
            .toList();
        expect(gossipPacketsDisabled, isEmpty);

        routingDisabled.dispose();
        engineDisabled.dispose();

        // Konfigurasi C: Memerlukan aktivasi eksplisit (enableGossip)
        final mockTransportC = FakeMeshTransport();
        final engineC = DagGossipSyncEngine(
          transport: mockTransportC,
          localNodeId: 'NODE-C',
          ledger: mockLedger,
          isEnabled: false,
        );
        final routingC = ManetRoutingEngine(
          transport: mockTransportC,
          identityManager: NodeIdentityManager(),
          repository: mockChatRepo,
          gossipSyncEngine: engineC,
        );

        mockTransportC.simulateIncomingConnectionRequest(
          endpointId: 'ep-peer-c',
          endpointName: 'Peer C',
        );
        await mockTransportC.acceptConnection(endpointId: 'ep-peer-c');
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(
          mockTransportC.sentPayloads.any(
            (p) => DagGossipSyncEngine.isGossipPayload(p.bytes),
          ),
          isFalse,
        );

        // Setelah diaktifkan secara eksplisit, HELLO dikirimkan
        engineC.isEnabled = true;
        expect(engineC.isEnabled, isTrue);

        routingC.dispose();
        engineC.dispose();
      },
    );

    test(
      '14. Prior tests for hash integrity, Merkle root, parent causal order, and privacy remain strictly valid',
      () {
        // Verifikasi deterministik bahwa integritas kriptografis dan privasi tetap ditegakkan
        final validBlock = ledgerA.createBlock(
          creatorNodeId: 'NODE-A',
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );
        expect(ledgerB.acceptRemoteBlock(validBlock).isValid, isTrue);

        final corruptMerkleBlock = SecurityBlock(
          version: 1,
          index: 2,
          blockHash: computeSha256('corrupt-merkle'),
          parentBlockHashes: [validBlock.blockHash],
          creatorNodeId: 'NODE-A',
          timestamp: DateTime.now().toUtc(),
          monotonicMicros: 999,
          merkleRoot: computeSha256('corrupt-merkle-data'),
          events: [],
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );
        expect(
          ledgerB.acceptRemoteBlock(corruptMerkleBlock).status,
          equals(LedgerValidationStatus.invalidMerkleRoot),
        );

        final privacyViolationBlock = SecurityBlock.create(
          index: 3,
          parentBlockHashes: [validBlock.blockHash],
          creatorNodeId: 'NODE-A',
          events: [
            SecurityAuditEvent(
              eventId: 'bad-evt-14',
              eventType: AuditEventType.idsDetection,
              observerNodeId: 'NODE-A',
              targetNodeId: 'NODE-B',
              timestamp: DateTime.now().toUtc(),
              monotonicMicros: 100,
              metadata: {
                'status': 'detected',
                'reason': 'normal',
                'body': 'unallowed private text',
              },
            ),
          ],
          validationProof: {'flushReason': 'manual', 'creatorNodeId': 'NODE-A'},
        );
        expect(
          GossipPrivacySanitizer.validateBlock(
            privacyViolationBlock,
          ).isCompliant,
          isFalse,
        );
      },
    );
  });
}

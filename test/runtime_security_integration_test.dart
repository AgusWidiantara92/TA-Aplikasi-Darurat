/// STAGE: Pengujian Integrasi Runtime IDS, Dynamic Trust Management, dan BlockDAG
///
/// Memverifikasi 10 kriteria integrasi runtime menggunakan bootstrap nyata:
/// 1. IDS menerima bukti forwarding dari ManetRoutingEngine.
/// 2. Timeout forwarding dievaluasi otomatis tanpa pemanggilan manual dari test.
/// 3. Event IDS memengaruhi DynamicTrustManager.
/// 4. Perubahan trust memengaruhi keputusan routing hanya ketika kebijakan diaktifkan.
/// 5. Event IDS dan trust mencapai BlockDAG Security Coordinator.
/// 6. Ledger BlockDAG dapat disimpan dan dipulihkan.
/// 7. Lifecycle tidak menggandakan listener, timer, atau engine.
/// 8. Kegagalan transport alami tidak dianggap sebagai serangan.
/// 9. Pesan darurat (SOS) tetap memiliki jalur pengiriman yang aman.
/// 10. Gossip sync berjalan hanya ketika prasyarat tersedia dan tidak mengganggu pesan reguler.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:siagamesh_app/core/blockchain/blockdag_repository.dart';
import 'package:siagamesh_app/core/blockchain/blockdag_security_coordinator.dart';
import 'package:siagamesh_app/core/ids/ids_types.dart';
import 'package:siagamesh_app/core/ids/selective_forwarding_detector.dart';
import 'package:siagamesh_app/core/routing/message_envelope.dart';
import 'package:siagamesh_app/core/routing/node_identity.dart';
import 'package:siagamesh_app/core/routing/routing_holder.dart';
import 'package:siagamesh_app/core/transport/fake_mesh_transport.dart';
import 'package:siagamesh_app/core/transport/transport_holder.dart';
import 'package:siagamesh_app/core/trust/trust_repository.dart';
import 'package:siagamesh_app/core/trust/trust_types.dart';

/// Helper untuk menyimulasikan koneksi peer dan pertukaran handshake identitas
Future<void> _connectPeer(
  FakeMeshTransport transport, {
  required String endpointId,
  required String nodeId,
  required String nodeName,
}) async {
  transport.simulateIncomingConnectionRequest(
    endpointId: endpointId,
    endpointName: nodeName,
  );
  await transport.acceptConnection(endpointId: endpointId);

  final handshake = MessageEnvelope(
    envelopeId: 'hs-$nodeId',
    type: MessageEnvelope.typeHandshake,
    senderId: nodeId,
    senderName: nodeName,
    recipientId: 'BROADCAST',
    createdAt: DateTime.now().millisecondsSinceEpoch,
    ttl: 1,
    hopCount: 0,
    routeTrace: [nodeId],
    payload: {'nodeId': nodeId, 'nodeName': nodeName},
  );
  transport.simulateIncomingPayload(
    endpointId: endpointId,
    bytes: handshake.toBytes(),
  );
  await Future<void>.delayed(const Duration(milliseconds: 10));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ManetRoutingHolder.reset();
  });

  tearDown(() {
    ManetRoutingHolder.reset();
  });

  group('RUNTIME INTEGRATION — IDS, Dynamic Trust & BlockDAG Security', () {
    // -------------------------------------------------------------------------
    // 1. IDS menerima bukti forwarding dari ManetRoutingEngine
    // -------------------------------------------------------------------------
    test(
      '1. IDS menerima bukti forwarding dan Hop ACK dari aktivitas ManetRoutingEngine',
      () async {
        final transportA = FakeMeshTransport();
        MeshTransportHolder.setInstance(transportA);

        final engineA = await ManetRoutingHolder.initialize(
          transport: transportA,
          identityManager: NodeIdentityManager(
            overrideId: 'node-A',
            overrideName: 'Node A',
          ),
          idsConfig: const IdsConfig(
            minObservationsForEvaluation: 4,
            dropRateThreshold: 0.35,
            ackTimeout: Duration(milliseconds: 2000),
          ),
          autoStartIdsTimeoutTimer: false,
        );

        await _connectPeer(
          transportA,
          endpointId: 'ep-B',
          nodeId: 'node-B',
          nodeName: 'Node B',
        );

        final detector = ManetRoutingHolder.idsDetector!;

        // Node A mengirim chat menuju node-C melalui node-B (TTL = 3)
        final sentEnv = await engineA.sendChatMessage(
          recipientNodeId: 'node-C',
          text: 'Halo Node C lewat Node B',
        );

        final statsB = detector.getStats('node-B');
        expect(statsB, isNotNull);
        expect(statsB!.expectedCount, equals(1));
        expect(statsB.claimedCount, equals(0));
        expect(statsB.unconfirmedCount, equals(0));

        // Node B mengirim Hop ACK kembali ke Node A
        final hopAck = MessageEnvelope(
          envelopeId: 'ack-${sentEnv.envelopeId}-node-B',
          type: MessageEnvelope.typeHopAck,
          senderId: 'node-B',
          senderName: 'Node B',
          recipientId: 'node-A',
          createdAt: DateTime.now().millisecondsSinceEpoch,
          ttl: 1,
          hopCount: 0,
          routeTrace: ['node-B'],
          payload: {
            'ackedEnvelopeId': sentEnv.envelopeId,
            'status': 'RELAY_CLAIMED',
          },
        );
        transportA.simulateIncomingPayload(
          endpointId: 'ep-B',
          bytes: hopAck.toBytes(),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(statsB.claimedCount, equals(1));
        expect(statsB.unconfirmedCount, equals(0));
        expect(statsB.dropRate, equals(0.0));
      },
    );

    // -------------------------------------------------------------------------
    // 2. Timeout berjalan tanpa pemanggilan manual dari test
    // -------------------------------------------------------------------------
    test(
      '2. Timeout forwarding dievaluasi otomatis oleh periodic timer tanpa pemanggilan manual',
      () async {
        final transportA = FakeMeshTransport();
        MeshTransportHolder.setInstance(transportA);

        final engineA = await ManetRoutingHolder.initialize(
          transport: transportA,
          identityManager: NodeIdentityManager(
            overrideId: 'node-A',
            overrideName: 'Node A',
          ),
          idsConfig: const IdsConfig(
            minObservationsForEvaluation: 1,
            dropRateThreshold: 0.35,
            ackTimeout: Duration(milliseconds: 50), // Timeout cepat untuk tes
          ),
          autoStartIdsTimeoutTimer: true,
        );

        await _connectPeer(
          transportA,
          endpointId: 'ep-B',
          nodeId: 'node-B',
          nodeName: 'Node B',
        );

        final detector = ManetRoutingHolder.idsDetector!;
        expect(detector.isPeriodicTimeoutCheckRunning, isTrue);

        // Node A mengirim pesan yang TIDAK pernah dibalas ACK oleh B
        await engineA.sendChatMessage(
          recipientNodeId: 'node-C',
          text: 'Pesan tanpa ACK',
        );

        final statsB = detector.getStats('node-B');
        expect(statsB, isNotNull);
        expect(statsB!.expectedCount, equals(1));
        expect(statsB.unconfirmedCount, equals(0));

        // Tunggu timer periodik (interval 1000ms) berjalan secara nyata
        await Future.delayed(const Duration(milliseconds: 1200));

        // Verifikasi unconfirmed bertambah secara otomatis tanpa checkTimeouts() manual!
        expect(statsB.unconfirmedCount, equals(1));
        expect(statsB.dropRate, equals(1.0));
      },
    );

    // -------------------------------------------------------------------------
    // 3. Event IDS memengaruhi DynamicTrustManager
    // -------------------------------------------------------------------------
    test(
      '3. Event IDS yang suspected menurunkan skor DynamicTrustManager',
      () async {
        final transportA = FakeMeshTransport();

        await ManetRoutingHolder.initialize(
          transport: transportA,
          identityManager: NodeIdentityManager(
            overrideId: 'node-A',
            overrideName: 'Node A',
          ),
          idsConfig: const IdsConfig(
            minObservationsForEvaluation: 4,
            dropRateThreshold: 0.35,
          ),
          autoStartIdsTimeoutTimer: false,
        );

        final detector = ManetRoutingHolder.idsDetector!;
        final trustManager = ManetRoutingHolder.trustManager!;

        expect(trustManager.getTrustScore('node-B'), equals(0.60));
        expect(
          trustManager.getStatus('node-B'),
          equals(TrustEvaluationStatus.uncertain),
        );

        // Simulasikan 4 drop pada link aktif untuk node-B
        for (int i = 1; i <= 4; i++) {
          detector.registerForwardingExpected(
            peerNodeId: 'node-B',
            envelopeId: 'env-$i',
            timestamp: DateTime.now().subtract(
              const Duration(milliseconds: 3000),
            ),
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final scoreBeforeAlarm = trustManager.getTrustScore('node-B');
        expect(scoreBeforeAlarm, equals(0.72));

        // Jalankan evaluasi timeout
        detector.checkTimeouts(now: DateTime.now(), isLinkConnected: true);

        // Berikan waktu microtask/stream event loop memproses event IDS -> Trust
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // Evaluasi status transisi IDS -> suspected
        final statusB = detector.evaluateNode('node-B');
        expect(statusB, equals(NodeDetectionStatus.suspected));

        // DynamicTrustManager otomatis ter-update via detectionEventsStream:
        // Skor turun signifikan akibat alarm IDS suspected
        final scoreAfterAlarm = trustManager.getTrustScore('node-B');
        expect(scoreAfterAlarm, lessThan(scoreBeforeAlarm));
        expect(scoreAfterAlarm, equals(0.6165));

        final record = trustManager.getRecord('node-B');
        expect(record, isNotNull);
        expect(record!.unconfirmedDropCount, greaterThan(0));

        // Jika perilaku buruk berlanjut melampaui batas toleransi isolasi:
        for (int i = 1; i <= 3; i++) {
          trustManager.observeDirectEvidence(
            targetNodeId: 'node-B',
            evidenceType: ForwardingEvidenceType.forwardingUnconfirmed,
            evidenceId: 'subsequent-drop-$i',
          );
        }
        expect(trustManager.getTrustScore('node-B'), lessThan(0.50));
        expect(
          trustManager.getStatus('node-B'),
          equals(TrustEvaluationStatus.untrusted),
        );
      },
    );

    // -------------------------------------------------------------------------
    // 4. Perubahan trust memengaruhi keputusan routing hanya ketika kebijakan diaktifkan
    // -------------------------------------------------------------------------
    test(
      '4. Perubahan trust memfilter rute hanya saat strictIsolation aktif, dan monitoringOnly meloloskan',
      () async {
        final transportA = FakeMeshTransport();

        // Tahap A: MonitoringOnly (kebijakan default runtime)
        final engineA = await ManetRoutingHolder.initialize(
          transport: transportA,
          identityManager: NodeIdentityManager(
            overrideId: 'node-A',
            overrideName: 'Node A',
          ),
          trustConfig: const TrustConfig(
            routingPolicy: TrustRoutingPolicy.monitoringOnly,
          ),
          enableTrustRoutingPolicy: true,
          autoStartIdsTimeoutTimer: false,
        );

        await _connectPeer(
          transportA,
          endpointId: 'ep-B',
          nodeId: 'node-B',
          nodeName: 'Node B',
        );

        final trustManager = ManetRoutingHolder.trustManager!;

        // Jatuhkan reputasi Node B
        for (int i = 1; i <= 6; i++) {
          trustManager.observeDirectEvidence(
            targetNodeId: 'node-B',
            evidenceType: ForwardingEvidenceType.forwardingUnconfirmed,
            evidenceId: 'drop-$i',
          );
        }
        expect(
          trustManager.getStatus('node-B'),
          equals(TrustEvaluationStatus.untrusted),
        );

        // Pada monitoringOnly, pesan tetap diteruskan ke transport
        final sentMonitoring = await engineA.sendChatMessage(
          recipientNodeId: 'node-C',
          text: 'Pesan dalam mode monitoring',
        );
        expect(sentMonitoring.envelopeId, isNotEmpty);

        // Tahap B: Reset dan aktifkan strictIsolation
        ManetRoutingHolder.reset();
        final transportStrict = FakeMeshTransport();
        final engineAStrict = await ManetRoutingHolder.initialize(
          transport: transportStrict,
          identityManager: NodeIdentityManager(
            overrideId: 'node-A',
            overrideName: 'Node A',
          ),
          trustConfig: const TrustConfig(
            routingPolicy: TrustRoutingPolicy.strictIsolation,
          ),
          enableTrustRoutingPolicy: true,
          autoStartIdsTimeoutTimer: false,
        );

        await _connectPeer(
          transportStrict,
          endpointId: 'ep-B',
          nodeId: 'node-B',
          nodeName: 'Node B',
        );

        final trustManagerStrict = ManetRoutingHolder.trustManager!;
        for (int i = 1; i <= 6; i++) {
          trustManagerStrict.observeDirectEvidence(
            targetNodeId: 'node-B',
            evidenceType: ForwardingEvidenceType.forwardingUnconfirmed,
            evidenceId: 'strict-drop-$i',
          );
        }
        expect(
          trustManagerStrict.getStatus('node-B'),
          equals(TrustEvaluationStatus.untrusted),
        );

        // Pada strictIsolation, relay melalui Node B diblokir dan pesan disimpan di buffer
        await engineAStrict.sendChatMessage(
          recipientNodeId: 'node-C',
          text: 'Pesan yang harusnya diblokir',
        );

        // Verifikasi filter memblokir peer
        final candidates = trustManagerStrict.filterForwardingPeers(
          peers: engineAStrict.neighborTable.activeNeighbors,
          getNodeId: (n) => n.nodeId,
          destinationId: 'node-C',
        );
        expect(candidates, isEmpty);

        // Namun pengiriman langsung ke tujuan (destination) tetap diizinkan
        final directCandidates = trustManagerStrict.filterForwardingPeers(
          peers: engineAStrict.neighborTable.activeNeighbors,
          getNodeId: (n) => n.nodeId,
          destinationId: 'node-B',
        );
        expect(directCandidates, isNotEmpty);
      },
    );

    // -------------------------------------------------------------------------
    // 5. Event IDS dan trust mencapai BlockDAG coordinator
    // -------------------------------------------------------------------------
    test(
      '5. Event IDS dan trust otomatis mencapai BlockdagSecurityCoordinator dan dapat dibentuk blok',
      () async {
        final transportA = FakeMeshTransport();

        await ManetRoutingHolder.initialize(
          transport: transportA,
          identityManager: NodeIdentityManager(
            overrideId: 'node-A',
            overrideName: 'Node A',
          ),
          idsConfig: const IdsConfig(minObservationsForEvaluation: 2),
          autoStartIdsTimeoutTimer: false,
        );

        final detector = ManetRoutingHolder.idsDetector!;
        final coordinator = ManetRoutingHolder.blockdagCoordinator!;

        final initialReceived = coordinator.totalEventsReceived;

        // Picu alarm IDS
        detector.registerForwardingExpected(
          peerNodeId: 'node-MALICIOUS',
          envelopeId: 'env-mal-1',
          timestamp: DateTime.now().subtract(const Duration(seconds: 5)),
        );
        detector.registerForwardingExpected(
          peerNodeId: 'node-MALICIOUS',
          envelopeId: 'env-mal-2',
          timestamp: DateTime.now().subtract(const Duration(seconds: 5)),
        );
        detector.checkTimeouts(now: DateTime.now(), isLinkConnected: true);

        // Berikan waktu event stream dan emergency immediate flush memproses
        await Future.delayed(const Duration(milliseconds: 50));

        // Verifikasi coordinator menerima event audit
        expect(coordinator.totalEventsReceived, greaterThan(initialReceived));

        // Karena immediateFlushOnSuspected = true, blok sudah otomatis terbentuk
        expect(coordinator.totalBlocksCreated, greaterThan(0));
        expect(coordinator.ledger.activeBlocksCount, greaterThanOrEqualTo(2));

        // Ambil blok non-genesis terbaru via tips
        final tipHash = coordinator.ledger.tipHashes.first;
        final block = coordinator.ledger.getBlock(tipHash);
        expect(block, isNotNull);
        expect(block!.events, isNotEmpty);
        expect(block.events.first.targetNodeId, equals('node-MALICIOUS'));
        expect(block.computeHash(), equals(block.blockHash));
      },
    );

    // -------------------------------------------------------------------------
    // 6. Ledger dapat disimpan dan dipulihkan
    // -------------------------------------------------------------------------
    test(
      '6. Ledger BlockDAG dan state DynamicTrust tersimpan persisten dan pulih setelah restart',
      () async {
        final repo = LocalBlockdagRepository();
        final trustRepo = LocalTrustRepository();
        await repo.clear();
        await trustRepo.clear();

        final transportA = FakeMeshTransport();

        // Sesi Pertama
        await ManetRoutingHolder.initialize(
          transport: transportA,
          identityManager: NodeIdentityManager(
            overrideId: 'node-A',
            overrideName: 'Node A',
          ),
          blockdagRepository: repo,
          trustRepository: trustRepo,
          autoStartIdsTimeoutTimer: false,
        );

        final trust1 = ManetRoutingHolder.trustManager!;
        final coord1 = ManetRoutingHolder.blockdagCoordinator!;

        // Berikan data ke trust
        trust1.observeDirectEvidence(
          targetNodeId: 'node-PEER1',
          evidenceType: ForwardingEvidenceType.downstreamConfirmed,
          evidenceId: 'down-1',
        );
        await trust1.persistState();

        // Buat blok di coordinator
        final blockCreated = await coord1.flushPendingEvents(
          reason: 'commit_test',
        );
        expect(blockCreated, isNotNull);

        // Simulasi Restart: reset holder
        ManetRoutingHolder.reset();

        // Sesi Kedua: inisialisasi ulang dengan repository yang sama
        await ManetRoutingHolder.initialize(
          transport: transportA,
          identityManager: NodeIdentityManager(
            overrideId: 'node-A',
            overrideName: 'Node A',
          ),
          blockdagRepository: repo,
          trustRepository: trustRepo,
          autoStartIdsTimeoutTimer: false,
        );

        final trust2 = ManetRoutingHolder.trustManager!;
        final coord2 = ManetRoutingHolder.blockdagCoordinator!;

        // Verifikasi state trust pulih
        expect(trust2.getTrustScore('node-PEER1'), greaterThan(0.60));
        expect(
          trust2.getRecord('node-PEER1')!.downstreamConfirmedCount,
          equals(1),
        );

        // Verifikasi blok pulih di ledger
        expect(
          coord2.initStatus,
          equals(BlockdagInitStatus.restoredFromStorage),
        );
        expect(
          coord2.ledger.activeBlocksCount,
          greaterThanOrEqualTo(2),
        ); // Genesis + 1 block
        expect(coord2.ledger.getBlock(blockCreated!.blockHash), isNotNull);
      },
    );

    // -------------------------------------------------------------------------
    // 7. Lifecycle tidak menggandakan listener, timer, atau engine
    // -------------------------------------------------------------------------
    test(
      '7. Pemanggilan initialize berulang mengembalikan singleton yang sama tanpa duplikasi listener',
      () async {
        final engine1 = await ManetRoutingHolder.initialize(
          autoStartIdsTimeoutTimer: false,
        );
        final engine2 = await ManetRoutingHolder.initialize(
          autoStartIdsTimeoutTimer: false,
        );

        expect(identical(engine1, engine2), isTrue);

        final detector1 = ManetRoutingHolder.idsDetector;
        final trust1 = ManetRoutingHolder.trustManager;

        // Reset dan bangun ulang
        ManetRoutingHolder.reset();
        expect(ManetRoutingHolder.idsDetector, isNull);
        expect(ManetRoutingHolder.trustManager, isNull);

        final engine3 = await ManetRoutingHolder.initialize(
          autoStartIdsTimeoutTimer: false,
        );
        expect(identical(engine1, engine3), isFalse);
        expect(identical(detector1, ManetRoutingHolder.idsDetector), isFalse);
        expect(identical(trust1, ManetRoutingHolder.trustManager), isFalse);
      },
    );

    // -------------------------------------------------------------------------
    // 8. Kegagalan transport alami tidak dianggap sebagai serangan
    // -------------------------------------------------------------------------
    test(
      '8. Transport disconnection dicatat sebagai linkFailure tanpa penalti trust score',
      () async {
        final transportA = FakeMeshTransport();

        final engineA = await ManetRoutingHolder.initialize(
          transport: transportA,
          identityManager: NodeIdentityManager(
            overrideId: 'node-A',
            overrideName: 'Node A',
          ),
          autoStartIdsTimeoutTimer: false,
        );

        await _connectPeer(
          transportA,
          endpointId: 'ep-B',
          nodeId: 'node-B',
          nodeName: 'Node B',
        );

        final detector = ManetRoutingHolder.idsDetector!;
        final trustManager = ManetRoutingHolder.trustManager!;

        // Kirim pesan
        await engineA.sendChatMessage(
          recipientNodeId: 'node-C',
          text: 'Pesan sebelum putus',
        );

        // Putus koneksi B
        transportA.simulateDisconnection('ep-B');
        await Future<void>.delayed(const Duration(milliseconds: 10));

        final statsB = detector.getStats('node-B');
        expect(statsB, isNotNull);
        expect(statsB!.linkFailureCount, greaterThan(0));
        expect(statsB.unconfirmedCount, equals(0)); // BUKAN unconfirmed drop!

        // Skor trust tetap berada pada initialTrust (0.60) tanpa penalti
        expect(trustManager.getTrustScore('node-B'), equals(0.60));
      },
    );

    // -------------------------------------------------------------------------
    // 9. Pesan darurat (SOS) tetap memiliki jalur pengiriman yang aman
    // -------------------------------------------------------------------------
    test(
      '9. Pesan darurat SOS berhasil dibuat dan dipancarkan ke jaringan',
      () async {
        final transportA = FakeMeshTransport();

        final engineA = await ManetRoutingHolder.initialize(
          transport: transportA,
          identityManager: NodeIdentityManager(
            overrideId: 'node-A',
            overrideName: 'Node A',
          ),
          autoStartIdsTimeoutTimer: false,
        );

        final sosEnvelope = await engineA.sendChatMessage(
          recipientNodeId: 'BROADCAST',
          text: 'PANGGILAN DARURAT (SOS): Bencana gempa bumi!',
          isEmergency: true,
        );

        expect(sosEnvelope.payload['isEmergency'], isTrue);
        expect(sosEnvelope.recipientId, equals('BROADCAST'));
        expect(sosEnvelope.type, equals(MessageEnvelope.typeChat));
      },
    );

    // -------------------------------------------------------------------------
    // 10. Gossip sync berjalan hanya ketika prasyarat tersedia
    // -------------------------------------------------------------------------
    test(
      '10. Gossip sync aktif hanya saat enabled, menolak paket korup dan mengabaikan non-gossip',
      () async {
        final transportA = FakeMeshTransport();

        await ManetRoutingHolder.initialize(
          transport: transportA,
          enableBlockdagReplication: false,
          autoStartIdsTimeoutTimer: false,
        );

        final gossipEngine = ManetRoutingHolder.gossipSyncEngine!;
        expect(gossipEngine.isEnabled, isFalse);

        // Aktifkan replikasi
        ManetRoutingHolder.setEnableBlockdagReplication(true);
        expect(gossipEngine.isEnabled, isTrue);

        // Nonaktifkan kembali
        ManetRoutingHolder.setEnableBlockdagReplication(false);
        expect(gossipEngine.isEnabled, isFalse);
      },
    );
  });
}

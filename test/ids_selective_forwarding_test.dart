import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:siagamesh_app/core/ids/ids_types.dart';
import 'package:siagamesh_app/core/ids/selective_forwarding_detector.dart';
import 'package:siagamesh_app/core/ids/selective_forwarding_simulator.dart';
import 'package:siagamesh_app/core/routing/manet_routing_engine.dart';
import 'package:siagamesh_app/core/routing/message_envelope.dart';
import 'package:siagamesh_app/core/routing/mesh_experiment_logger.dart';
import 'package:siagamesh_app/core/routing/node_identity.dart';
import 'manet_routing_test.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group(
    'STAGE 5C — Pengujian Intrusion Detection System (IDS) Selective Forwarding',
    () {
      late SelectiveForwardingDetector detector;

      setUp(() {
        detector = SelectiveForwardingDetector(
          localNodeId: 'NODE-A',
          config: const IdsConfig(
            minObservationsForEvaluation: 4,
            dropRateThreshold: 0.35,
            ackTimeout: Duration(milliseconds: 200),
          ),
          activeRunId: 'TEST-IDS-01',
        );
      });

      tearDown(() {
        detector.dispose();
      });

      test(
        '1. Node normal yang kooperatif tidak ditandai sebagai malicious (status: normal)',
        () {
          const targetNodeId = 'NODE-B';

          // 6 pesan dikirim ke Node B dan seluruhnya mendapatkan konfirmasi HOP_ACK
          for (int i = 1; i <= 6; i++) {
            detector.registerForwardingExpected(
              peerNodeId: targetNodeId,
              envelopeId: 'env-$i',
            );
            detector.registerForwardingConfirmed(
              peerNodeId: targetNodeId,
              envelopeId: 'env-$i',
            );
          }

          final stats = detector.getStats(targetNodeId);
          expect(stats, isNotNull);
          expect(stats!.expectedCount, equals(6));
          expect(stats.confirmedCount, equals(6));
          expect(stats.unconfirmedCount, equals(0));
          expect(stats.dropRate, equals(0.0));
          expect(stats.currentStatus, equals(NodeDetectionStatus.normal));
        },
      );

      test(
        '2. Pola selective forwarding yang jelas menghasilkan deteksi terindikasi (status: suspected)',
        () {
          const targetNodeId = 'NODE-B';

          // 10 pesan dikirim: 4 dikonfirmasi, 6 dibiarkan timeout (60% drop rate, di atas threshold 35%)
          for (int i = 1; i <= 10; i++) {
            detector.registerForwardingExpected(
              peerNodeId: targetNodeId,
              envelopeId: 'env-$i',
              timestamp: DateTime.now().subtract(
                const Duration(milliseconds: 500),
              ),
            );
            if (i <= 4) {
              detector.registerForwardingConfirmed(
                peerNodeId: targetNodeId,
                envelopeId: 'env-$i',
              );
            }
          }

          // Jalankan pemindaian timeout
          detector.checkTimeouts(now: DateTime.now(), isLinkConnected: true);

          final stats = detector.getStats(targetNodeId);
          expect(stats, isNotNull);
          expect(stats!.expectedCount, equals(10));
          expect(stats.confirmedCount, equals(4));
          expect(stats.unconfirmedCount, equals(6));
          expect(stats.dropRate, closeTo(0.60, 0.01));
          expect(stats.currentStatus, equals(NodeDetectionStatus.suspected));

          // Verifikasi event deteksi tercatat
          expect(
            detector.detectionHistory.any(
              (e) =>
                  e.targetNodeId == targetNodeId &&
                  e.status == NodeDetectionStatus.suspected,
            ),
            isTrue,
          );
        },
      );

      test(
        '3. Satu kegagalan pesan tidak otomatis menghasilkan alarm (tahan terhadap false positive dini)',
        () {
          const targetNodeId = 'NODE-B';

          // Hanya 1 pesan dikirim dan timeout
          detector.registerForwardingExpected(
            peerNodeId: targetNodeId,
            envelopeId: 'env-single-fail',
            timestamp: DateTime.now().subtract(
              const Duration(milliseconds: 500),
            ),
          );

          detector.checkTimeouts(now: DateTime.now(), isLinkConnected: true);

          final stats = detector.getStats(targetNodeId);
          expect(stats, isNotNull);
          expect(stats!.unconfirmedCount, equals(1));
          // Karena 1 < minObservationsForEvaluation (4), status HARUS insufficientEvidence
          expect(
            stats.currentStatus,
            equals(NodeDetectionStatus.insufficientEvidence),
          );
          expect(
            detector.detectionHistory.any(
              (e) => e.status == NodeDetectionStatus.suspected,
            ),
            isFalse,
          );
        },
      );

      test(
        '4. Link disconnect menghasilkan status terpisah dari selective forwarding',
        () {
          const targetNodeId = 'NODE-B';

          // 5 pesan dikirim
          for (int i = 1; i <= 5; i++) {
            detector.registerForwardingExpected(
              peerNodeId: targetNodeId,
              envelopeId: 'env-$i',
            );
          }

          // Terjadi link failure (koneksi terputus alami)
          detector.registerLinkFailure(
            peerNodeId: targetNodeId,
            reason: 'BLUETOOTH_DISCONNECTED',
          );

          final stats = detector.getStats(targetNodeId);
          expect(stats, isNotNull);
          expect(stats!.linkFailureCount, greaterThanOrEqualTo(1));
          // Unconfirmed count TIDAK boleh bertambah karena kegagalan link alami
          expect(stats.unconfirmedCount, equals(0));
          expect(
            stats.currentStatus,
            isNot(equals(NodeDetectionStatus.suspected)),
          );
        },
      );

      test(
        '5. TTL, duplikasi, dan loop tidak dihitung sebagai selective forwarding (protocol drop)',
        () {
          const targetNodeId = 'NODE-B';

          // Daftarkan ekspektasi awal
          detector.registerForwardingExpected(
            peerNodeId: targetNodeId,
            envelopeId: 'env-ttl',
          );
          detector.registerForwardingExpected(
            peerNodeId: targetNodeId,
            envelopeId: 'env-dedup',
          );
          detector.registerForwardingExpected(
            peerNodeId: targetNodeId,
            envelopeId: 'env-loop',
          );

          // Tandai pembuangan protokol sah
          detector.registerProtocolDrop(
            peerNodeId: targetNodeId,
            envelopeId: 'env-ttl',
            reason: 'TTL_EXPIRED',
          );
          detector.registerProtocolDrop(
            peerNodeId: targetNodeId,
            envelopeId: 'env-dedup',
            reason: 'DEDUP_CACHE_HIT',
          );
          detector.registerProtocolDrop(
            peerNodeId: targetNodeId,
            envelopeId: 'env-loop',
            reason: 'ROUTE_LOOP_DETECTED',
          );

          detector.checkTimeouts(now: DateTime.now());

          final stats = detector.getStats(targetNodeId);
          expect(stats, isNotNull);
          expect(stats!.protocolDropCount, equals(3));
          // Unconfirmed count HARUS tetap 0
          expect(stats.unconfirmedCount, equals(0));
          expect(stats.dropRate, equals(0.0));
        },
      );

      test(
        '6. Event yang sama tidak diproses atau dihitung dua kali (deduplikasi obligasi)',
        () {
          const targetNodeId = 'NODE-B';

          final firstAdd = detector.registerForwardingExpected(
            peerNodeId: targetNodeId,
            envelopeId: 'env-dup-1',
          );
          final secondAdd = detector.registerForwardingExpected(
            peerNodeId: targetNodeId,
            envelopeId: 'env-dup-1',
          );

          expect(firstAdd, isTrue);
          expect(secondAdd, isFalse);

          final stats = detector.getStats(targetNodeId);
          expect(stats!.expectedCount, equals(1));
        },
      );

      test(
        '7. Kurangnya bukti forwarding menghasilkan insufficientEvidence, bukan tuduhan pasti',
        () {
          const targetNodeId = 'NODE-B';

          // 2 pesan dikirim dan dikonfirmasi (2 < minObservations = 4)
          detector.registerForwardingExpected(
            peerNodeId: targetNodeId,
            envelopeId: 'env-1',
          );
          detector.registerForwardingConfirmed(
            peerNodeId: targetNodeId,
            envelopeId: 'env-1',
          );
          detector.registerForwardingExpected(
            peerNodeId: targetNodeId,
            envelopeId: 'env-2',
          );
          detector.registerForwardingConfirmed(
            peerNodeId: targetNodeId,
            envelopeId: 'env-2',
          );

          final status = detector.evaluateNode(targetNodeId);
          expect(status, equals(NodeDetectionStatus.insufficientEvidence));
        },
      );

      test(
        '8. Perilaku routing baseline tidak berubah ketika IDS dinonaktifkan (idsDetector = null)',
        () async {
          final nodeA = VirtualMeshNode(nodeId: 'NODE-A', nodeName: 'Node A');
          final nodeB = VirtualMeshNode(nodeId: 'NODE-B', nodeName: 'Node B');
          final nodeC = VirtualMeshNode(nodeId: 'NODE-C', nodeName: 'Node C');

          // Routing engine murni tanpa IDS
          final engineA = ManetRoutingEngine(
            transport: nodeA.transport,
            identityManager: NodeIdentityManager(
              overrideId: 'NODE-A',
              overrideName: 'Node A',
            ),
            repository: nodeA.repository,
            idsDetector: null, // IDS dinonaktifkan
          );
          final engineB = ManetRoutingEngine(
            transport: nodeB.transport,
            identityManager: NodeIdentityManager(
              overrideId: 'NODE-B',
              overrideName: 'Node B',
            ),
            repository: nodeB.repository,
            idsDetector: null,
          );
          final engineC = ManetRoutingEngine(
            transport: nodeC.transport,
            identityManager: NodeIdentityManager(
              overrideId: 'NODE-C',
              overrideName: 'Node C',
            ),
            repository: nodeC.repository,
            idsDetector: null,
          );

          // Hubungkan linear A <-> B <-> C
          nodeA.transport.linkWith(
            localEndpointId: 'ep-B-on-A',
            remoteEndpointId: 'ep-A-on-B',
            remoteTransport: nodeB.transport,
            remoteNodeName: 'Node B',
          );
          nodeB.transport.linkWith(
            localEndpointId: 'ep-A-on-B',
            remoteEndpointId: 'ep-B-on-A',
            remoteTransport: nodeA.transport,
            remoteNodeName: 'Node A',
          );
          engineA.neighborTable.registerConnectedEndpoint(
            endpointId: 'ep-B-on-A',
            endpointName: 'Node B',
          );
          engineA.neighborTable.mapIdentity(
            endpointId: 'ep-B-on-A',
            nodeId: 'NODE-B',
            nodeName: 'Node B',
          );
          engineB.neighborTable.registerConnectedEndpoint(
            endpointId: 'ep-A-on-B',
            endpointName: 'Node A',
          );
          engineB.neighborTable.mapIdentity(
            endpointId: 'ep-A-on-B',
            nodeId: 'NODE-A',
            nodeName: 'Node A',
          );

          nodeB.transport.linkWith(
            localEndpointId: 'ep-C-on-B',
            remoteEndpointId: 'ep-B-on-C',
            remoteTransport: nodeC.transport,
            remoteNodeName: 'Node C',
          );
          nodeC.transport.linkWith(
            localEndpointId: 'ep-B-on-C',
            remoteEndpointId: 'ep-C-on-B',
            remoteTransport: nodeB.transport,
            remoteNodeName: 'Node B',
          );
          engineB.neighborTable.registerConnectedEndpoint(
            endpointId: 'ep-C-on-B',
            endpointName: 'Node C',
          );
          engineB.neighborTable.mapIdentity(
            endpointId: 'ep-C-on-B',
            nodeId: 'NODE-C',
            nodeName: 'Node C',
          );
          engineC.neighborTable.registerConnectedEndpoint(
            endpointId: 'ep-B-on-C',
            endpointName: 'Node B',
          );
          engineC.neighborTable.mapIdentity(
            endpointId: 'ep-B-on-C',
            nodeId: 'NODE-B',
            nodeName: 'Node B',
          );

          final completerC = Completer<MessageEnvelope>();
          final subC = engineC.incomingMessagesStream.listen(
            completerC.complete,
          );

          // A kirim pesan ke C
          await engineA.sendChatMessage(
            recipientNodeId: 'NODE-C',
            text: 'Pesan Baseline MANET',
          );
          final received = await completerC.future.timeout(
            const Duration(seconds: 2),
          );

          expect(received.recipientId, equals('NODE-C'));
          expect(received.hopCount, equals(1));
          expect(received.routeTrace, equals(['NODE-A', 'NODE-B']));

          await subC.cancel();
          engineA.dispose();
          engineB.dispose();
          engineC.dispose();
          nodeA.dispose();
          nodeB.dispose();
          nodeC.dispose();
        },
      );

      test('9. Event deteksi dicatat dengan metadata yang lengkap', () {
        final events = <IdsDetectionEvent>[];
        final sub = detector.detectionEventsStream.listen(events.add);

        // Buat kondisi suspected
        for (int i = 1; i <= 6; i++) {
          detector.registerForwardingExpected(
            peerNodeId: 'NODE-EVT',
            envelopeId: 'env-evt-$i',
            timestamp: DateTime.now().subtract(const Duration(seconds: 5)),
          );
        }
        detector.checkTimeouts(now: DateTime.now(), isLinkConnected: true);

        expect(events.isNotEmpty, isTrue);
        final evt = events.last;
        expect(evt.observerNodeId, equals('NODE-A'));
        expect(evt.targetNodeId, equals('NODE-EVT'));
        expect(evt.status, equals(NodeDetectionStatus.suspected));
        expect(evt.observedDropRate, equals(1.0));
        expect(evt.totalExpected, equals(6));
        expect(evt.totalUnconfirmed, equals(6));
        expect(evt.reason, contains('melampaui ambang'));
        expect(evt.monotonicMicros, isNonNegative);

        final json = evt.toJson();
        expect(json['status'], equals('suspected'));
        expect(json['targetNodeId'], equals('NODE-EVT'));

        sub.cancel();
      });

      test(
        '10. Data Ground Truth dan output detektor dievaluasi secara terpisah untuk metrik TP, FP, TN, FN',
        () {
          final fixture = SelectiveForwardingSimulationFixture();

          // Daftarkan ground truth independen
          fixture.registerNodeProfile(
            NodeSimulationProfile.normal('NODE-NORMAL-1'),
          );
          fixture.registerNodeProfile(
            NodeSimulationProfile.normal('NODE-NORMAL-2'),
          );
          fixture.registerNodeProfile(
            NodeSimulationProfile.selectiveDrop('NODE-ATTACKER-1'),
          );
          fixture.registerNodeProfile(
            NodeSimulationProfile.disconnected('NODE-FAULTY-LINK'),
          );

          // Prediksi yang dihasilkan detektor
          final predictions = <String, NodeDetectionStatus>{
            'NODE-NORMAL-1': NodeDetectionStatus.normal,
            'NODE-NORMAL-2': NodeDetectionStatus.normal,
            'NODE-ATTACKER-1': NodeDetectionStatus.suspected, // True Positive
            'NODE-FAULTY-LINK': NodeDetectionStatus
                .insufficientEvidence, // True Negative (tidak dituduh)
          };

          final metrics = fixture.evaluateDetectorPredictions(predictions);
          expect(metrics.truePositives, equals(1));
          expect(metrics.falsePositives, equals(0));
          expect(metrics.trueNegatives, equals(3));
          expect(metrics.falseNegatives, equals(0));
          expect(metrics.detectionRate, equals(1.0)); // Recall 100%
          expect(metrics.falsePositiveRate, equals(0.0)); // FPR 0%
        },
      );

      test('11. Reset sesi membersihkan seluruh state dan riwayat deteksi', () {
        for (int i = 1; i <= 4; i++) {
          detector.registerForwardingExpected(
            peerNodeId: 'NODE-X',
            envelopeId: 'env-$i',
            timestamp: DateTime.now().subtract(const Duration(seconds: 5)),
          );
        }
        detector.checkTimeouts(now: DateTime.now(), isLinkConnected: true);

        expect(detector.allStats.isNotEmpty, isTrue);
        expect(detector.detectionHistory.isNotEmpty, isTrue);

        detector.clear();

        expect(detector.allStats.isEmpty, isTrue);
        expect(detector.detectionHistory.isEmpty, isTrue);
      });

      test(
        '12. Integrasi End-to-End: Node A mendeteksi Selective Forwarding pada Node B (Relay Attack)',
        () async {
          final idsDetectorA = SelectiveForwardingDetector(
            localNodeId: 'NODE-A',
            config: const IdsConfig(
              minObservationsForEvaluation: 3,
              dropRateThreshold: 0.50,
              ackTimeout: Duration(milliseconds: 100),
              autoSendHopAck: true,
            ),
          );

          final nodeA = VirtualMeshNode(
            nodeId: 'NODE-A',
            nodeName: 'Pengirim A',
          );
          final nodeB = VirtualMeshNode(
            nodeId: 'NODE-B',
            nodeName: 'Relay Malicious B',
          );
          final nodeC = VirtualMeshNode(nodeId: 'NODE-C', nodeName: 'Tujuan C');

          // Engine A memiliki IDS aktif
          final engineA = ManetRoutingEngine(
            transport: nodeA.transport,
            identityManager: NodeIdentityManager(
              overrideId: 'NODE-A',
              overrideName: 'Pengirim A',
            ),
            repository: nodeA.repository,
            idsDetector: idsDetectorA,
            enableHopAck: true,
          );

          // Node B disimulasikan sebagai penyerang selective forwarding:
          // Menerima paket dari A, tetapi TIDAK meneruskan ke C dan TIDAK mengirimkan HOP_ACK
          final engineB = ManetRoutingEngine(
            transport: nodeB.transport,
            identityManager: NodeIdentityManager(
              overrideId: 'NODE-B',
              overrideName: 'Relay Malicious B',
            ),
            repository: nodeB.repository,
            enableHopAck:
                false, // Node penyerang menolak mengirim konfirmasi HOP_ACK
          );

          final engineC = ManetRoutingEngine(
            transport: nodeC.transport,
            identityManager: NodeIdentityManager(
              overrideId: 'NODE-C',
              overrideName: 'Tujuan C',
            ),
            repository: nodeC.repository,
          );

          // Hubungkan linear A <-> B dan B <-> C
          nodeA.transport.linkWith(
            localEndpointId: 'ep-B-on-A',
            remoteEndpointId: 'ep-A-on-B',
            remoteTransport: nodeB.transport,
            remoteNodeName: 'Relay Malicious B',
          );
          nodeB.transport.linkWith(
            localEndpointId: 'ep-A-on-B',
            remoteEndpointId: 'ep-B-on-A',
            remoteTransport: nodeA.transport,
            remoteNodeName: 'Pengirim A',
          );
          engineA.neighborTable.registerConnectedEndpoint(
            endpointId: 'ep-B-on-A',
            endpointName: 'Relay Malicious B',
          );
          engineA.neighborTable.mapIdentity(
            endpointId: 'ep-B-on-A',
            nodeId: 'NODE-B',
            nodeName: 'Relay Malicious B',
          );
          engineB.neighborTable.registerConnectedEndpoint(
            endpointId: 'ep-A-on-B',
            endpointName: 'Pengirim A',
          );
          engineB.neighborTable.mapIdentity(
            endpointId: 'ep-A-on-B',
            nodeId: 'NODE-A',
            nodeName: 'Pengirim A',
          );

          nodeB.transport.linkWith(
            localEndpointId: 'ep-C-on-B',
            remoteEndpointId: 'ep-B-on-C',
            remoteTransport: nodeC.transport,
            remoteNodeName: 'Tujuan C',
          );
          nodeC.transport.linkWith(
            localEndpointId: 'ep-B-on-C',
            remoteEndpointId: 'ep-C-on-B',
            remoteTransport: nodeB.transport,
            remoteNodeName: 'Relay Malicious B',
          );
          engineB.neighborTable.registerConnectedEndpoint(
            endpointId: 'ep-C-on-B',
            endpointName: 'Tujuan C',
          );
          engineB.neighborTable.mapIdentity(
            endpointId: 'ep-C-on-B',
            nodeId: 'NODE-C',
            nodeName: 'Tujuan C',
          );
          engineC.neighborTable.registerConnectedEndpoint(
            endpointId: 'ep-B-on-C',
            endpointName: 'Relay Malicious B',
          );
          engineC.neighborTable.mapIdentity(
            endpointId: 'ep-B-on-C',
            nodeId: 'NODE-B',
            nodeName: 'Relay Malicious B',
          );

          // Node A mengirim 4 pesan berturut-turut menuju C melalui Node B
          for (int i = 1; i <= 4; i++) {
            await engineA.sendChatMessage(
              recipientNodeId: 'NODE-C',
              text: 'Pesan Uji Selective Forwarding $i',
            );
          }

          // Tunggu hingga batas ackTimeout terlampaui
          await Future.delayed(const Duration(milliseconds: 250));
          idsDetectorA.checkTimeouts(
            now: DateTime.now(),
            isLinkConnected: true,
          );

          // Verifikasi bahwa IDS Node A mencurigai Node B sebagai selective forwarder
          final statusB = idsDetectorA.evaluateNode('NODE-B');
          expect(statusB, equals(NodeDetectionStatus.suspected));
          final statsB = idsDetectorA.getStats('NODE-B');
          expect(statsB, isNotNull);
          expect(statsB!.expectedCount, equals(4));
          expect(statsB.unconfirmedCount, equals(4));
          expect(statsB.dropRate, equals(1.0)); // 100% drop rate terdeteksi

          engineA.dispose();
          engineB.dispose();
          engineC.dispose();
          idsDetectorA.dispose();
          nodeA.dispose();
          nodeB.dispose();
          nodeC.dispose();
        },
      );

      test(
        '13. Batas ambang keputusan sensitivitas (drop rate tepat pada ambang 35% vs di bawah ambang 30%)',
        () {
          final testDetector = SelectiveForwardingDetector(
            localNodeId: 'NODE-A',
            config: const IdsConfig(
              minObservationsForEvaluation: 4,
              dropRateThreshold: 0.35,
              ackTimeout: Duration(milliseconds: 200),
            ),
          );

          // Kasus A: 20 paket, 6 gagal timeout = 6/20 = 30.0% (< 35.0%) -> normal
          for (int i = 1; i <= 20; i++) {
            testDetector.registerForwardingExpected(
              peerNodeId: 'NODE-BELOW',
              envelopeId: 'env-below-$i',
              timestamp: DateTime.now().subtract(const Duration(seconds: 1)),
            );
            if (i > 6) {
              testDetector.registerRelayClaimed(
                peerNodeId: 'NODE-BELOW',
                envelopeId: 'env-below-$i',
              );
            }
          }
          testDetector.checkTimeouts(
            now: DateTime.now(),
            isLinkConnected: true,
          );
          final statusBelow = testDetector.evaluateNode('NODE-BELOW');
          expect(statusBelow, equals(NodeDetectionStatus.normal));
          expect(
            testDetector.getStats('NODE-BELOW')!.dropRate,
            closeTo(0.30, 0.001),
          );

          // Kasus B: 20 paket, 7 gagal timeout = 7/20 = 35.0% (== 35.0% threshold) -> suspected
          for (int i = 1; i <= 20; i++) {
            testDetector.registerForwardingExpected(
              peerNodeId: 'NODE-EXACT',
              envelopeId: 'env-exact-$i',
              timestamp: DateTime.now().subtract(const Duration(seconds: 1)),
            );
            if (i > 7) {
              testDetector.registerRelayClaimed(
                peerNodeId: 'NODE-EXACT',
                envelopeId: 'env-exact-$i',
              );
            }
          }
          testDetector.checkTimeouts(
            now: DateTime.now(),
            isLinkConnected: true,
          );
          final statusExact = testDetector.evaluateNode('NODE-EXACT');
          expect(statusExact, equals(NodeDetectionStatus.suspected));
          expect(
            testDetector.getStats('NODE-EXACT')!.dropRate,
            closeTo(0.35, 0.001),
          );

          testDetector.dispose();
        },
      );

      test(
        '14. Penolakan ACK yang duplikat, terlambat, atau tidak cocok dengan envelope ID yang sedang dilacak',
        () {
          const peer = 'NODE-PEER-1';

          // 1. Daftarkan paket yang valid
          detector.registerForwardingExpected(
            peerNodeId: peer,
            envelopeId: 'env-tracked-1',
          );

          // 2. ACK pertama: valid -> diterima
          final firstAck = detector.registerRelayClaimed(
            peerNodeId: peer,
            envelopeId: 'env-tracked-1',
          );
          expect(firstAck, isTrue);
          expect(detector.getStats(peer)!.claimedCount, equals(1));

          // 3. ACK duplikat untuk paket yang sama: ditolak
          final dupAck = detector.registerRelayClaimed(
            peerNodeId: peer,
            envelopeId: 'env-tracked-1',
          );
          expect(dupAck, isFalse);
          expect(detector.getStats(peer)!.claimedCount, equals(1));

          // 4. ACK untuk envelope yang tidak pernah dilacak: ditolak
          final unknownAck = detector.registerRelayClaimed(
            peerNodeId: peer,
            envelopeId: 'env-ghost-unsolicited',
          );
          expect(unknownAck, isFalse);
          expect(detector.getStats(peer)!.expectedCount, equals(1));
          expect(detector.getStats(peer)!.claimedCount, equals(1));

          // 5. ACK terlambat (setelah timeout kedaluwarsa)
          detector.registerForwardingExpected(
            peerNodeId: peer,
            envelopeId: 'env-late-1',
            timestamp: DateTime.now().subtract(const Duration(seconds: 5)),
          );
          detector.checkTimeouts(now: DateTime.now(), isLinkConnected: true);
          expect(detector.getStats(peer)!.unconfirmedCount, equals(1));

          final lateAck = detector.registerRelayClaimed(
            peerNodeId: peer,
            envelopeId: 'env-late-1',
          );
          expect(lateAck, isFalse);
          expect(detector.getStats(peer)!.unconfirmedCount, equals(1));
        },
      );

      test(
        '15. Transisi status tanpa pencatatan alarm berulang (status yang sama tidak memicu log ganda)',
        () {
          const peer = 'NODE-TRANSITION';
          final recordedEvents = <IdsDetectionEvent>[];
          final sub = detector.detectionEventsStream.listen(recordedEvents.add);

          // Tahap 1: 3 paket belum mencukupi ambang observasi (3 < 4) -> tidak ada event transisi
          for (int i = 1; i <= 3; i++) {
            detector.registerForwardingExpected(
              peerNodeId: peer,
              envelopeId: 'env-t-$i',
              timestamp: DateTime.now().subtract(const Duration(seconds: 5)),
            );
          }
          detector.checkTimeouts(now: DateTime.now(), isLinkConnected: true);
          expect(recordedEvents.isEmpty, isTrue);

          // Tahap 2: Paket ke-4 timeout -> transisi dari insufficientEvidence ke suspected -> 1 event!
          detector.registerForwardingExpected(
            peerNodeId: peer,
            envelopeId: 'env-t-4',
            timestamp: DateTime.now().subtract(const Duration(seconds: 5)),
          );
          detector.checkTimeouts(now: DateTime.now(), isLinkConnected: true);
          expect(recordedEvents.length, equals(1));
          expect(
            recordedEvents.first.status,
            equals(NodeDetectionStatus.suspected),
          );

          // Tahap 3: Pemanggilan evaluasi ulang atau checkTimeouts berikutnya saat status tetap suspected -> TIDAK ada log baru!
          detector.checkTimeouts(now: DateTime.now(), isLinkConnected: true);
          detector.evaluateNode(peer);
          expect(
            recordedEvents.length,
            equals(1),
          ); // Tetap 1, tidak terjadi log spam!

          sub.cancel();
        },
      );

      test(
        '16. Integrasi event deteksi IDS ke MeshExperimentLogger dan ekspor CSV/JSON',
        () {
          final logger = MeshExperimentLogger(
            activeRunId: 'EXP-STAGE-5C2',
            activeTestType: 'IDS_INTEGRATION',
          );
          final testDetector = SelectiveForwardingDetector(
            localNodeId: 'NODE-SENDER',
            config: const IdsConfig(
              minObservationsForEvaluation: 4,
              dropRateThreshold: 0.35,
              ackTimeout: Duration(milliseconds: 100),
            ),
            experimentLogger: logger,
            simulationGroundTruth: 'maliciousSelectiveForwarder',
            activeRunId: 'EXP-STAGE-5C2',
          );

          // Trigger transisi status ke suspected (4 unconfirmed drops)
          for (int i = 1; i <= 4; i++) {
            testDetector.registerForwardingExpected(
              peerNodeId: 'NODE-MALICIOUS',
              envelopeId: 'env-log-$i',
              timestamp: DateTime.now().subtract(const Duration(seconds: 1)),
            );
          }
          testDetector.checkTimeouts(
            now: DateTime.now(),
            isLinkConnected: true,
          );

          // Verifikasi bahwa logger mencatat event idsDetection dengan transisi state
          final idsEvents = logger.events
              .where((e) => e.eventType == MeshExperimentEventType.idsDetection)
              .toList();
          expect(idsEvents.length, equals(2));
          expect(idsEvents.first.outcome, equals('normal'));
          expect(idsEvents.last.outcome, equals('suspected'));

          final evt = idsEvents.last;
          expect(evt.runId, equals('EXP-STAGE-5C2'));
          expect(evt.senderId, equals('NODE-SENDER'));
          expect(evt.recipientId, equals('NODE-MALICIOUS'));
          expect(evt.outcome, equals('suspected'));
          expect(
            evt.syntheticMetadata!['simulationGroundTruth'],
            equals('maliciousSelectiveForwarder'),
          );
          expect(
            evt.syntheticMetadata!['thresholdConfig']['dropRateThreshold'],
            equals(0.35),
          );

          // Verifikasi Ekspor CSV
          final csv = logger.toCsv();
          expect(csv, contains('idsDetection'));
          expect(csv, contains('NODE-MALICIOUS'));
          expect(csv, contains('suspected'));

          // Verifikasi Ekspor JSON
          final jsonStr = logger.toJsonString();
          expect(jsonStr, contains('"eventType":"idsDetection"'));
          expect(
            jsonStr,
            contains('"simulationGroundTruth":"maliciousSelectiveForwarder"'),
          );

          testDetector.dispose();
          logger.dispose();
        },
      );

      test(
        '17. Validasi penanganan metrik dengan penyebut nol menghasilkan nilai null (tidak terdefinisi)',
        () {
          // Kasus tidak ada node positif (TP + FN == 0)
          const metricsNoPositives = IdsMetricsEvaluator(
            truePositives: 0,
            falsePositives: 0,
            trueNegatives: 5,
            falseNegatives: 0,
          );
          expect(metricsNoPositives.detectionRate, isNull);
          expect(metricsNoPositives.falsePositiveRate, equals(0.0));

          // Kasus tidak ada node negatif (FP + TN == 0)
          const metricsNoNegatives = IdsMetricsEvaluator(
            truePositives: 3,
            falsePositives: 0,
            trueNegatives: 0,
            falseNegatives: 0,
          );
          expect(metricsNoNegatives.detectionRate, equals(1.0));
          expect(metricsNoNegatives.falsePositiveRate, isNull);
        },
      );
    },
  );
}

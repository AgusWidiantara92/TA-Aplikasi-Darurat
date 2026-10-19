import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:siagamesh_app/core/ids/ids_types.dart';
import 'package:siagamesh_app/core/routing/mesh_experiment_logger.dart';
import 'package:siagamesh_app/core/routing/message_envelope.dart';
import 'package:siagamesh_app/core/routing/neighbor_table.dart';
import 'package:siagamesh_app/core/trust/dynamic_trust_manager.dart';
import 'package:siagamesh_app/core/trust/trust_types.dart';
import 'manet_routing_test.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('STAGE 5D — Pengujian Dynamic Trust Management SiagaMesh', () {
    late DynamicTrustManager trustManager;
    late MeshExperimentLogger logger;

    setUp(() {
      logger = MeshExperimentLogger();
      trustManager = DynamicTrustManager(
        localNodeId: 'NODE-A',
        config: const TrustConfig(
          initialTrust: 0.60,
          decayAlpha: 0.70,
          isolationThreshold: 0.50,
          minObservationsForIsolation: 4,
          weightDeliveryConfirmed: 1.0,
          weightDownstreamConfirmed: 0.90,
          weightRelayClaimed: 0.60,
          weightUnconfirmedDrop: 1.0,
          routingPolicy: TrustRoutingPolicy.strictIsolation,
        ),
        experimentLogger: logger,
        activeRunId: 'TEST-TRUST-01',
      );
    });

    tearDown(() {
      trustManager.dispose();
      logger.clear();
    });

    test('1. Inisialisasi dan batas rentang skor [0.0, 1.0]', () {
      const targetNodeId = 'NODE-B';

      // Sebelum ada interaksi, skor default adalah initialTrust (0.60)
      expect(trustManager.getTrustScore(targetNodeId), equals(0.60));
      expect(
        trustManager.getStatus(targetNodeId),
        equals(TrustEvaluationStatus.uncertain),
      );

      // Uji batas atas: 50 interaksi positif berturut-turut tidak melebihi 1.0
      for (int i = 1; i <= 50; i++) {
        trustManager.observeDirectEvidence(
          targetNodeId: targetNodeId,
          evidenceType: ForwardingEvidenceType.deliveryConfirmed,
          evidenceId: 'pos-$i',
        );
      }
      expect(trustManager.getTrustScore(targetNodeId), lessThanOrEqualTo(1.0));
      expect(trustManager.getTrustScore(targetNodeId), greaterThan(0.95));

      // Reset dan uji batas bawah: 50 kegagalan berturut-turut tidak kurang dari 0.0
      trustManager.clear();
      expect(trustManager.getTrustScore(targetNodeId), equals(0.60));

      for (int i = 1; i <= 50; i++) {
        trustManager.observeDirectEvidence(
          targetNodeId: targetNodeId,
          evidenceType: ForwardingEvidenceType.forwardingUnconfirmed,
          evidenceId: 'neg-$i',
        );
      }
      expect(
        trustManager.getTrustScore(targetNodeId),
        greaterThanOrEqualTo(0.0),
      );
      expect(trustManager.getTrustScore(targetNodeId), lessThan(0.05));
    });

    test('2. Kenaikan dan kestabilan reputasi node kooperatif', () {
      const targetNodeId = 'NODE-COOP';

      // Berikan 5 konfirmasi forwarding berturut-turut
      for (int i = 1; i <= 5; i++) {
        trustManager.observeDirectEvidence(
          targetNodeId: targetNodeId,
          evidenceType: ForwardingEvidenceType.downstreamConfirmed,
          evidenceId: 'coop-$i',
        );
      }

      final score = trustManager.getTrustScore(targetNodeId);
      final record = trustManager.getRecord(targetNodeId);

      expect(record, isNotNull);
      expect(record!.totalObservations, equals(5));
      expect(record.positiveEvidenceSum, closeTo(5 * 0.90, 0.001));
      expect(record.negativeEvidenceSum, equals(0.0));
      expect(score, greaterThan(0.60));
      expect(
        trustManager.getStatus(targetNodeId),
        equals(TrustEvaluationStatus.trusted),
      );
    });

    test(
      '3. Bobot diskon Hop ACK (0.60) vs verifikasi downstream (0.90) vs E2E (1.0)',
      () {
        const nodeClaim = 'NODE-CLAIM';
        const nodeDownstream = 'NODE-DOWN';
        const nodeE2E = 'NODE-E2E';

        // Simulasikan 2 bukti positif dan 2 bukti negatif untuk masing-masing tipe bukti
        // Skenario A: Hop ACK (relayClaimed, bobot 0.60)
        for (int i = 1; i <= 2; i++) {
          trustManager.observeDirectEvidence(
            targetNodeId: nodeClaim,
            evidenceType: ForwardingEvidenceType.relayClaimed,
            evidenceId: 'claim-pos-$i',
          );
        }
        for (int i = 1; i <= 2; i++) {
          trustManager.observeDirectEvidence(
            targetNodeId: nodeClaim,
            evidenceType: ForwardingEvidenceType.forwardingUnconfirmed,
            evidenceId: 'claim-neg-$i',
          );
        }

        // Skenario B: Downstream confirmed (bobot 0.90)
        for (int i = 1; i <= 2; i++) {
          trustManager.observeDirectEvidence(
            targetNodeId: nodeDownstream,
            evidenceType: ForwardingEvidenceType.downstreamConfirmed,
            evidenceId: 'down-pos-$i',
          );
        }
        for (int i = 1; i <= 2; i++) {
          trustManager.observeDirectEvidence(
            targetNodeId: nodeDownstream,
            evidenceType: ForwardingEvidenceType.forwardingUnconfirmed,
            evidenceId: 'down-neg-$i',
          );
        }

        // Skenario C: Delivery confirmed (E2E, bobot 1.0)
        for (int i = 1; i <= 2; i++) {
          trustManager.observeDirectEvidence(
            targetNodeId: nodeE2E,
            evidenceType: ForwardingEvidenceType.deliveryConfirmed,
            evidenceId: 'e2e-pos-$i',
          );
        }
        for (int i = 1; i <= 2; i++) {
          trustManager.observeDirectEvidence(
            targetNodeId: nodeE2E,
            evidenceType: ForwardingEvidenceType.forwardingUnconfirmed,
            evidenceId: 'e2e-neg-$i',
          );
        }

        final scoreClaim = trustManager.getTrustScore(nodeClaim);
        final scoreDownstream = trustManager.getTrustScore(nodeDownstream);
        final scoreE2E = trustManager.getTrustScore(nodeE2E);

        // Verifikasi berantai: E2E > Downstream > Hop ACK klaim sepihak
        expect(scoreE2E, greaterThan(scoreDownstream));
        expect(scoreDownstream, greaterThan(scoreClaim));

        // Verifikasi pemisahan dimensi: reliabilitas respons vs forwarding terverifikasi
        final recordClaim = trustManager.getRecord(nodeClaim)!;
        expect(recordClaim.protocolResponsivenessCount, equals(2));
        expect(recordClaim.verifiedForwardingCount, equals(0));
        expect(recordClaim.unconfirmedDropCount, equals(2));

        final recordDownstream = trustManager.getRecord(nodeDownstream)!;
        expect(recordDownstream.protocolResponsivenessCount, equals(0));
        expect(recordDownstream.verifiedForwardingCount, equals(2));
        expect(recordDownstream.unconfirmedDropCount, equals(2));

        final recordE2E = trustManager.getRecord(nodeE2E)!;
        expect(recordE2E.protocolResponsivenessCount, equals(0));
        expect(recordE2E.verifiedForwardingCount, equals(2));
        expect(recordE2E.unconfirmedDropCount, equals(2));
      },
    );

    test(
      '4. Penurunan reputasi akibat selective forwarding attack hingga isolasi',
      () {
        const maliciousNode = 'NODE-ATTACKER';

        // 4 kali packet drop berturut-turut pada link aktif
        for (int i = 1; i <= 4; i++) {
          trustManager.observeDirectEvidence(
            targetNodeId: maliciousNode,
            evidenceType: ForwardingEvidenceType.forwardingUnconfirmed,
            evidenceId: 'attack-$i',
          );
        }

        final score = trustManager.getTrustScore(maliciousNode);
        expect(score, lessThan(0.50));
        expect(
          trustManager.getStatus(maliciousNode),
          equals(TrustEvaluationStatus.untrusted),
        );
      },
    );

    test(
      '5. Resistensi terhadap satu kegagalan tunggal (anti-fragility via EMA)',
      () {
        const reliableNode = 'NODE-RELIABLE';

        // Bangun reputasi tinggi dengan 8 pengiriman sukses
        for (int i = 1; i <= 8; i++) {
          trustManager.observeDirectEvidence(
            targetNodeId: reliableNode,
            evidenceType: ForwardingEvidenceType.deliveryConfirmed,
            evidenceId: 'rel-pos-$i',
          );
        }
        final highPreScore = trustManager.getTrustScore(reliableNode);
        expect(highPreScore, greaterThan(0.85));
        expect(
          trustManager.getStatus(reliableNode),
          equals(TrustEvaluationStatus.trusted),
        );

        // 1 kegagalan transmisi terjadi
        trustManager.observeDirectEvidence(
          targetNodeId: reliableNode,
          evidenceType: ForwardingEvidenceType.forwardingUnconfirmed,
          evidenceId: 'rel-fail-1',
        );

        final postScore = trustManager.getTrustScore(reliableNode);
        // Skor menurun, namun TIDAK jatuh drastis di bawah ambang isolasi 0.50
        expect(postScore, lessThan(highPreScore));
        expect(postScore, greaterThanOrEqualTo(0.50));
        expect(
          trustManager.getStatus(reliableNode),
          equals(TrustEvaluationStatus.trusted),
        );
      },
    );

    test(
      '6. Perlakuan diagnostik terhadap gangguan link radio alami (linkFailureSuspected)',
      () {
        const targetNodeId = 'NODE-LINK-FAIL';

        final initialScore = trustManager.getTrustScore(targetNodeId);

        // 5 kali tautan terputus saat transmisi (misal out-of-range radio)
        for (int i = 1; i <= 5; i++) {
          trustManager.observeDirectEvidence(
            targetNodeId: targetNodeId,
            evidenceType: ForwardingEvidenceType.linkFailureSuspected,
            evidenceId: 'link-drop-$i',
          );
        }

        final record = trustManager.getRecord(targetNodeId);
        expect(record, isNotNull);
        expect(record!.linkFailureCount, equals(5));
        expect(record.negativeEvidenceSum, equals(0.0));
        // ATURAN WAJIB: Skor trust TIDAK berkurang akibat link failure
        expect(trustManager.getTrustScore(targetNodeId), equals(initialScore));
      },
    );

    test(
      '7. Perlakuan diagnostik terhadap packet drop sah protokol (protocolDrop)',
      () {
        const targetNodeId = 'NODE-PROTO-DROP';

        final initialScore = trustManager.getTrustScore(targetNodeId);

        // 5 kali pembuangan paket sah (TTL expired, loop prevention, duplicate)
        for (int i = 1; i <= 5; i++) {
          trustManager.observeDirectEvidence(
            targetNodeId: targetNodeId,
            evidenceType: ForwardingEvidenceType.protocolDrop,
            evidenceId: 'proto-drop-$i',
          );
        }

        final record = trustManager.getRecord(targetNodeId);
        expect(record, isNotNull);
        expect(record!.protocolDropCount, equals(5));
        expect(record.negativeEvidenceSum, equals(0.0));
        // ATURAN WAJIB: Skor trust TIDAK berkurang akibat protocol drop
        expect(trustManager.getTrustScore(targetNodeId), equals(initialScore));
      },
    );

    test('8. Deduplikasi event dan jaminan idempotensi', () {
      const targetNodeId = 'NODE-IDEMP';

      // Kirim event yang sama berulang kali dengan ID yang sama
      final firstResult = trustManager.observeDirectEvidence(
        targetNodeId: targetNodeId,
        evidenceType: ForwardingEvidenceType.forwardingUnconfirmed,
        evidenceId: 'duplicate-event-123',
      );
      final scoreAfterFirst = trustManager.getTrustScore(targetNodeId);

      final secondResult = trustManager.observeDirectEvidence(
        targetNodeId: targetNodeId,
        evidenceType: ForwardingEvidenceType.forwardingUnconfirmed,
        evidenceId: 'duplicate-event-123',
      );
      final scoreAfterSecond = trustManager.getTrustScore(targetNodeId);

      expect(firstResult, isTrue);
      expect(secondResult, isFalse);
      expect(scoreAfterSecond, equals(scoreAfterFirst));
      expect(
        trustManager.getRecord(targetNodeId)!.totalObservations,
        equals(1),
      );
    });

    test('9. Penanganan bukti tidak memadai (neutral evidence)', () {
      const targetNodeId = 'NODE-NEUTRAL';

      final initialScore = trustManager.getTrustScore(targetNodeId);

      // Masukkan event IDS bertipe insufficientEvidence
      final event = IdsDetectionEvent(
        eventId: 'ids-neutral-1',
        runId: 'RUN-01',
        observerNodeId: 'NODE-A',
        targetNodeId: targetNodeId,
        status: NodeDetectionStatus.insufficientEvidence,
        observedDropRate: 0.5,
        totalExpected: 2,
        totalClaimed: 1,
        totalUnconfirmed: 1,
        totalLinkFailures: 0,
        totalProtocolDrops: 0,
        reason: 'Pengamatan belum mencukupi batas minimum evaluasi',
        timestamp: DateTime.now(),
        monotonicMicros: 1000,
      );

      final processed = trustManager.observeIdsEvent(event);
      expect(processed, isTrue);
      // Skor tidak boleh berubah sembarangan
      expect(trustManager.getTrustScore(targetNodeId), equals(initialScore));
    });

    test('10. Pembersihan status sesi (session reset)', () {
      trustManager.observeDirectEvidence(
        targetNodeId: 'NODE-B',
        evidenceType: ForwardingEvidenceType.deliveryConfirmed,
        evidenceId: 'ev-1',
      );
      trustManager.observeDirectEvidence(
        targetNodeId: 'NODE-C',
        evidenceType: ForwardingEvidenceType.forwardingUnconfirmed,
        evidenceId: 'ev-2',
      );

      expect(trustManager.allScores.length, equals(2));
      expect(trustManager.changeHistory.length, equals(2));

      trustManager.clear();

      expect(trustManager.allScores.isEmpty, isTrue);
      expect(trustManager.changeHistory.isEmpty, isTrue);
      // Skor kembali ke default
      expect(trustManager.getTrustScore('NODE-B'), equals(0.60));
    });

    test(
      '11. Pencatatan event reputasi ke MeshExperimentLogger dan ekspor CSV/JSON',
      () {
        trustManager.observeDirectEvidence(
          targetNodeId: 'NODE-LOG',
          evidenceType: ForwardingEvidenceType.deliveryConfirmed,
          evidenceId: 'ev-log-1',
        );
        trustManager.observeDirectEvidence(
          targetNodeId: 'NODE-LOG',
          evidenceType: ForwardingEvidenceType.forwardingUnconfirmed,
          evidenceId: 'ev-log-2',
        );

        final logs = logger.events;
        final trustLogs = logs
            .where((l) => l.eventType == MeshExperimentEventType.trustUpdate)
            .toList();

        expect(trustLogs.length, equals(2));
        expect(trustLogs.first.recipientId, equals('NODE-LOG'));
        expect(trustLogs.first.senderId, equals('NODE-A'));
        expect(
          trustLogs.first.syntheticMetadata?['evidenceType'],
          equals('deliveryConfirmed'),
        );
        expect(
          trustLogs.first.syntheticMetadata?['thresholdConfig'],
          isNotNull,
        );
        expect(
          trustLogs.first.syntheticMetadata?['verifiedForwardingCount'],
          equals(1),
        );
        expect(
          trustLogs.first.syntheticMetadata?['protocolResponsivenessCount'],
          equals(0),
        );

        // Ekspor CSV
        final csv = logger.toCsv();
        expect(csv, contains('trustUpdate'));
        expect(csv, contains('NODE-LOG'));

        // Ekspor JSON
        final jsonStr = logger.toJsonString();
        final decoded = jsonDecode(jsonStr) as List;
        expect(
          decoded.any((item) => item['eventType'] == 'trustUpdate'),
          isTrue,
        );
      },
    );

    test(
      '12. Kebijakan perutean: blokir untrusted relay dan rute melalui peer terpercaya',
      () {
        final now = DateTime.now();
        // Siapkan tetangga B (untrusted) dan tetangga D (trusted)
        // Node B mengalami selective forwarding
        for (int i = 1; i <= 5; i++) {
          trustManager.observeDirectEvidence(
            targetNodeId: 'NODE-B',
            evidenceType: ForwardingEvidenceType.forwardingUnconfirmed,
            evidenceId: 'b-drop-$i',
          );
        }
        expect(
          trustManager.getStatus('NODE-B'),
          equals(TrustEvaluationStatus.untrusted),
        );

        // Node D kooperatif
        for (int i = 1; i <= 5; i++) {
          trustManager.observeDirectEvidence(
            targetNodeId: 'NODE-D',
            evidenceType: ForwardingEvidenceType.deliveryConfirmed,
            evidenceId: 'd-pass-$i',
          );
        }
        expect(
          trustManager.getStatus('NODE-D'),
          equals(TrustEvaluationStatus.trusted),
        );

        final peers = [
          NeighborPeer(
            endpointId: 'ep-B',
            nodeId: 'NODE-B',
            nodeName: 'Relay B',
            connectedAt: now,
            lastSeen: now,
          ),
          NeighborPeer(
            endpointId: 'ep-D',
            nodeId: 'NODE-D',
            nodeName: 'Relay D',
            connectedAt: now,
            lastSeen: now,
          ),
        ];

        final decisions = <String, String>{};
        final filtered = trustManager.filterForwardingPeers<NeighborPeer>(
          peers: peers,
          getNodeId: (n) => n.nodeId,
          destinationId: 'NODE-C',
          onDecision: (peerId, decision, score) {
            decisions[peerId] = decision;
          },
        );

        // Node B harus diblokir, hanya Node D yang lolos sebagai kandidat relai
        expect(filtered.length, equals(1));
        expect(filtered.first.nodeId, equals('NODE-D'));
        expect(decisions['NODE-B'], equals('BLOCKED_UNTRUSTED_RELAY'));
        expect(decisions['NODE-D'], equals('APPROVED_TRUSTED_RELAY'));
      },
    );

    test(
      '13. Kebijakan penanganan saat seluruh tetangga untrusted (fallback vs isolation)',
      () {
        final now = DateTime.now();
        // Tetangga B (skor lebih rendah) dan Tetangga D (skor lebih tinggi) — keduanya di bawah ambang 0.50
        for (int i = 1; i <= 6; i++) {
          trustManager.observeDirectEvidence(
            targetNodeId: 'NODE-B',
            evidenceType: ForwardingEvidenceType.forwardingUnconfirmed,
            evidenceId: 'fb-b-$i',
          );
        }
        for (int i = 1; i <= 4; i++) {
          trustManager.observeDirectEvidence(
            targetNodeId: 'NODE-D',
            evidenceType: ForwardingEvidenceType.forwardingUnconfirmed,
            evidenceId: 'fb-d-$i',
          );
        }

        final peers = [
          NeighborPeer(
            endpointId: 'ep-B',
            nodeId: 'NODE-B',
            nodeName: 'Relay B',
            connectedAt: now,
            lastSeen: now,
          ),
          NeighborPeer(
            endpointId: 'ep-D',
            nodeId: 'NODE-D',
            nodeName: 'Relay D',
            connectedAt: now,
            lastSeen: now,
          ),
        ];

        // A. Pada kebijakan strictIsolation: tidak ada peer yang lolos (isolasi ketat)
        final isolatedPeers = trustManager.filterForwardingPeers<NeighborPeer>(
          peers: peers,
          getNodeId: (n) => n.nodeId,
          destinationId: 'NODE-C',
        );
        expect(isolatedPeers.isEmpty, isTrue);

        // B. Pada kebijakan fallbackWithWarning: peer dengan skor relatif tertinggi (Node D) dipilih
        final fallbackManager = DynamicTrustManager(
          localNodeId: 'NODE-A',
          config: trustManager.config.copyWith(
            routingPolicy: TrustRoutingPolicy.fallbackWithWarning,
          ),
        );
        for (int i = 1; i <= 6; i++) {
          fallbackManager.observeDirectEvidence(
            targetNodeId: 'NODE-B',
            evidenceType: ForwardingEvidenceType.forwardingUnconfirmed,
            evidenceId: 'fb-b-$i',
          );
        }
        for (int i = 1; i <= 4; i++) {
          fallbackManager.observeDirectEvidence(
            targetNodeId: 'NODE-D',
            evidenceType: ForwardingEvidenceType.forwardingUnconfirmed,
            evidenceId: 'fb-d-$i',
          );
        }

        String? fallbackDecision;
        final fallbackPeers = fallbackManager
            .filterForwardingPeers<NeighborPeer>(
              peers: peers,
              getNodeId: (n) => n.nodeId,
              destinationId: 'NODE-C',
              onDecision: (peerId, decision, score) {
                if (decision.startsWith('FALLBACK')) {
                  fallbackDecision = decision;
                }
              },
            );

        expect(fallbackPeers.length, equals(1));
        expect(fallbackPeers.first.nodeId, equals('NODE-D'));
        expect(fallbackDecision, equals('FALLBACK_WARNING_NO_TRUSTED_RELAY'));
        fallbackManager.dispose();
      },
    );

    test(
      '14. Integritas baseline: perutean tanpa trust routing policy (Konfigurasi A)',
      () async {
        final nodeA = VirtualMeshNode(nodeId: 'NODE-A', nodeName: 'Node A');
        final nodeB = VirtualMeshNode(nodeId: 'NODE-B', nodeName: 'Node B');
        final nodeC = VirtualMeshNode(nodeId: 'NODE-C', nodeName: 'Node C');

        try {
          // Hubungkan A <-> B <-> C secara linear
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
          nodeA.engine.neighborTable.registerConnectedEndpoint(
            endpointId: 'ep-B-on-A',
            endpointName: 'Node B',
          );
          nodeA.engine.neighborTable.mapIdentity(
            endpointId: 'ep-B-on-A',
            nodeId: 'NODE-B',
            nodeName: 'Node B',
          );
          nodeB.engine.neighborTable.registerConnectedEndpoint(
            endpointId: 'ep-A-on-B',
            endpointName: 'Node A',
          );
          nodeB.engine.neighborTable.mapIdentity(
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
          nodeB.engine.neighborTable.registerConnectedEndpoint(
            endpointId: 'ep-C-on-B',
            endpointName: 'Node C',
          );
          nodeB.engine.neighborTable.mapIdentity(
            endpointId: 'ep-C-on-B',
            nodeId: 'NODE-C',
            nodeName: 'Node C',
          );
          nodeC.engine.neighborTable.registerConnectedEndpoint(
            endpointId: 'ep-B-on-C',
            endpointName: 'Node B',
          );
          nodeC.engine.neighborTable.mapIdentity(
            endpointId: 'ep-B-on-C',
            nodeId: 'NODE-B',
            nodeName: 'Node B',
          );

          // Pastikan Konfigurasi A (enableTrustRoutingPolicy = false)
          expect(nodeA.engine.enableTrustRoutingPolicy, isFalse);

          final receivedOnC = Completer<MessageEnvelope>();
          final sub = nodeC.engine.incomingMessagesStream.listen((env) {
            if (env.recipientId == 'NODE-C') {
              receivedOnC.complete(env);
            }
          });

          await nodeA.engine.sendChatMessage(
            recipientNodeId: 'NODE-C',
            text: 'Pesan Uji Baseline',
          );

          final delivered = await receivedOnC.future.timeout(
            const Duration(seconds: 2),
          );
          expect(delivered, isNotNull);
          expect(delivered.payload['text'], equals('Pesan Uji Baseline'));
          await sub.cancel();
        } finally {
          nodeA.dispose();
          nodeB.dispose();
          nodeC.dispose();
        }
      },
    );

    test(
      '15. Uji sensitivitas parameter EMA (alpha in {0.5, 0.7, 0.9}) dan threshold',
      () {
        final alphas = [0.5, 0.7, 0.9];
        final thresholds = [0.4, 0.5, 0.6];

        final results = <double, Map<String, dynamic>>{};

        for (final alpha in alphas) {
          final mgr = DynamicTrustManager(
            localNodeId: 'NODE-A',
            config: TrustConfig(
              decayAlpha: alpha,
              initialTrust: 0.60,
              isolationThreshold: 0.50,
            ),
          );

          // Lakukan 3 drop berturut-turut
          for (int i = 1; i <= 3; i++) {
            mgr.observeDirectEvidence(
              targetNodeId: 'TARGET',
              evidenceType: ForwardingEvidenceType.forwardingUnconfirmed,
              evidenceId: 'sens-$alpha-$i',
            );
          }
          results[alpha] = {'finalScore': mgr.getTrustScore('TARGET')};
          mgr.dispose();
        }

        // Sensitivitas Alpha: alpha lebih kecil (0.5) beradaptasi lebih cepat terhadap kegagalan,
        // sehingga skor akhirnya lebih rendah daripada alpha yang lebih besar (0.9)
        final score05 = results[0.5]!['finalScore'] as double;
        final score07 = results[0.7]!['finalScore'] as double;
        final score09 = results[0.9]!['finalScore'] as double;

        expect(score05, lessThan(score07));
        expect(score07, lessThan(score09));

        // Verifikasi ambang batas isolasi
        for (final th in thresholds) {
          final cfg = TrustConfig(
            isolationThreshold: th,
            minObservationsForIsolation: 4,
          );
          final rec = TrustRecord(
            nodeId: 'NODE-TH',
            currentScore: 0.45,
            totalObservations: 4,
          );
          final status = rec.evaluateStatus(cfg);
          if (th == 0.4) {
            // 0.45 >= 0.40 -> trusted
            expect(status, equals(TrustEvaluationStatus.trusted));
          } else {
            // 0.45 < 0.50 dan 0.45 < 0.60 -> untrusted
            expect(status, equals(TrustEvaluationStatus.untrusted));
          }
        }
      },
    );
  });
}

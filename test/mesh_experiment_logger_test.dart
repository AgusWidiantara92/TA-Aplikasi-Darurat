import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:siagamesh_app/core/routing/manet_routing_engine.dart';
import 'package:siagamesh_app/core/routing/mesh_experiment_logger.dart';
import 'package:siagamesh_app/core/routing/message_envelope.dart';
import 'package:siagamesh_app/core/routing/node_identity.dart';
import 'manet_routing_test.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('STAGE 5B.3 — Unit Testing MeshExperimentLogger & Instrumentasi Eksperimen', () {
    test(
      '1. Logger mencatat metadata teknis secara akurat tanpa menyimpan teks pribadi',
      () {
        final logger = MeshExperimentLogger(
          activeRunId: 'RUN-TEST-01',
          activeTestType: '1_HOP_DIRECT',
        );

        logger.log(
          envelopeId: 'env-001',
          messageId: 'msg-001',
          senderId: 'NODE-A',
          recipientId: 'NODE-B',
          eventType: MeshExperimentEventType.created,
          hopCount: 0,
          routeTrace: ['NODE-A'],
          connectionStatus: 'CONNECTED',
          activeNeighborCount: 1,
          outcome: 'CREATED_LOCALLY',
          syntheticMetadata: {'payloadBytes': 128, 'isEmergency': false},
        );

        expect(logger.events.length, equals(1));
        final evt = logger.events.first;
        expect(evt.runId, equals('RUN-TEST-01'));
        expect(evt.testType, equals('1_HOP_DIRECT'));
        expect(evt.messageId, equals('msg-001'));
        expect(evt.eventType, equals(MeshExperimentEventType.created));
        expect(evt.hopCount, equals(0));
        expect(evt.routeTrace, equals(['NODE-A']));
        expect(evt.connectionStatus, equals('CONNECTED'));
        expect(evt.outcome, equals('CREATED_LOCALLY'));
        expect(evt.monotonicMicros, isNonNegative);

        // Pastikan format CSV valid
        final csv = logger.toCsv();
        expect(csv, contains(MeshExperimentEvent.csvHeader));
        expect(csv, contains('env-001,msg-001,NODE-A,NODE-B,created'));

        // Pastikan format JSON valid
        final jsonStr = logger.toJsonString();
        expect(jsonStr, contains('"envelopeId":"env-001"'));
        expect(jsonStr, contains('"messageId":"msg-001"'));
      },
    );

    test(
      '2. Kapasitas maksimum (bounded ring-buffer) membuang peristiwa terlama saat penuh',
      () {
        final logger = MeshExperimentLogger(maxEvents: 3);

        for (int i = 1; i <= 5; i++) {
          logger.log(
            envelopeId: 'env-$i',
            messageId: 'msg-$i',
            senderId: 'NODE-A',
            recipientId: 'NODE-B',
            eventType: MeshExperimentEventType.sentToTransport,
            hopCount: 0,
            routeTrace: ['NODE-A'],
            connectionStatus: 'CONNECTED',
            activeNeighborCount: 1,
          );
        }

        expect(logger.events.length, equals(3));
        // Hanya 3 terakhir (msg-3, msg-4, msg-5) yang tersimpan
        expect(
          logger.events.map((e) => e.messageId).toList(),
          equals(['msg-3', 'msg-4', 'msg-5']),
        );
      },
    );

    test('3. Perhitungan metrik unik terkirim, diterima, dan PDR lokal', () {
      final logger = MeshExperimentLogger();
      const runId = 'RUN-PDR-CHECK';

      // 10 pesan dibuat dan dikirim
      for (int i = 1; i <= 10; i++) {
        logger.log(
          runId: runId,
          envelopeId: 'env-$i',
          messageId: 'msg-$i',
          senderId: 'NODE-A',
          recipientId: 'NODE-B',
          eventType: MeshExperimentEventType.created,
          hopCount: 0,
          routeTrace: ['NODE-A'],
          connectionStatus: 'CONNECTED',
          activeNeighborCount: 1,
        );
        logger.log(
          runId: runId,
          envelopeId: 'env-$i',
          messageId: 'msg-$i',
          senderId: 'NODE-A',
          recipientId: 'NODE-B',
          eventType: MeshExperimentEventType.sentToTransport,
          hopCount: 0,
          routeTrace: ['NODE-A'],
          connectionStatus: 'CONNECTED',
          activeNeighborCount: 1,
        );
      }

      // 8 pesan unik berhasil sampai di tujuan
      for (int i = 1; i <= 8; i++) {
        logger.log(
          runId: runId,
          envelopeId: 'env-$i',
          messageId: 'msg-$i',
          senderId: 'NODE-A',
          recipientId: 'NODE-B',
          eventType: MeshExperimentEventType.received,
          hopCount: 1,
          routeTrace: ['NODE-A', 'NODE-B'],
          connectionStatus: 'CONNECTED',
          activeNeighborCount: 1,
          outcome: 'DELIVERED_TO_APP',
        );
      }

      expect(logger.countUniqueSentMessages(runId), equals(10));
      expect(logger.countUniqueReceivedMessages(runId), equals(8));
      expect(logger.calculateLocalPdr(runId), closeTo(80.0, 0.01));
    });

    test(
      '4. Integrasi ManetRoutingEngine mencatat siklus lengkap multi-hop A -> B -> C',
      () async {
        final loggerA = MeshExperimentLogger(
          activeRunId: 'EXP-MULTI-01',
          activeTestType: 'MULTI_HOP_RELAY',
        );
        final loggerB = MeshExperimentLogger(
          activeRunId: 'EXP-MULTI-01',
          activeTestType: 'MULTI_HOP_RELAY',
        );
        final loggerC = MeshExperimentLogger(
          activeRunId: 'EXP-MULTI-01',
          activeTestType: 'MULTI_HOP_RELAY',
        );

        final nodeA = VirtualMeshNode(nodeId: 'NODE-A', nodeName: 'Pengirim A');
        final nodeB = VirtualMeshNode(nodeId: 'NODE-B', nodeName: 'Relay B');
        final nodeC = VirtualMeshNode(nodeId: 'NODE-C', nodeName: 'Tujuan C');

        final engineA = ManetRoutingEngine(
          transport: nodeA.transport,
          identityManager: NodeIdentityManager(
            overrideId: 'NODE-A',
            overrideName: 'Pengirim A',
          ),
          repository: nodeA.repository,
          experimentLogger: loggerA,
        );
        final engineB = ManetRoutingEngine(
          transport: nodeB.transport,
          identityManager: NodeIdentityManager(
            overrideId: 'NODE-B',
            overrideName: 'Relay B',
          ),
          repository: nodeB.repository,
          experimentLogger: loggerB,
        );
        final engineC = ManetRoutingEngine(
          transport: nodeC.transport,
          identityManager: NodeIdentityManager(
            overrideId: 'NODE-C',
            overrideName: 'Tujuan C',
          ),
          repository: nodeC.repository,
          experimentLogger: loggerC,
        );

        // Bentuk topologi A <-> B dan B <-> C (A dan C tidak terhubung langsung)
        nodeA.transport.linkWith(
          localEndpointId: 'ep-B-on-A',
          remoteEndpointId: 'ep-A-on-B',
          remoteTransport: nodeB.transport,
          remoteNodeName: 'Relay B',
        );
        nodeB.transport.linkWith(
          localEndpointId: 'ep-A-on-B',
          remoteEndpointId: 'ep-B-on-A',
          remoteTransport: nodeA.transport,
          remoteNodeName: 'Pengirim A',
        );
        engineA.neighborTable.registerConnectedEndpoint(
          endpointId: 'ep-B-on-A',
          endpointName: 'Relay B',
        );
        engineA.neighborTable.mapIdentity(
          endpointId: 'ep-B-on-A',
          nodeId: 'NODE-B',
          nodeName: 'Relay B',
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
          remoteNodeName: 'Relay B',
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
          endpointName: 'Relay B',
        );
        engineC.neighborTable.mapIdentity(
          endpointId: 'ep-B-on-C',
          nodeId: 'NODE-B',
          nodeName: 'Relay B',
        );

        final completerC = Completer<MessageEnvelope>();
        final subC = engineC.incomingMessagesStream.listen(completerC.complete);

        // Node A mengirim pesan sintetis menuju Node C
        final sentEnvelope = await engineA.sendChatMessage(
          recipientNodeId: 'NODE-C',
          text: 'Eksperimen Relay Multi-Hop Sintetis',
        );

        await completerC.future.timeout(const Duration(seconds: 2));

        // Verifikasi pencatatan pada Node A
        final eventsA = loggerA.events;
        expect(
          eventsA.any((e) => e.eventType == MeshExperimentEventType.created),
          isTrue,
        );
        expect(
          eventsA.any(
            (e) => e.eventType == MeshExperimentEventType.sentToTransport,
          ),
          isTrue,
        );

        // Verifikasi pencatatan pada Node B (Relay)
        final eventsB = loggerB.events;
        expect(
          eventsB.any(
            (e) =>
                e.eventType == MeshExperimentEventType.received &&
                e.outcome == 'RELAY_TRANSIT',
          ),
          isTrue,
        );
        expect(
          eventsB.any((e) => e.eventType == MeshExperimentEventType.forwarded),
          isTrue,
        );

        // Verifikasi pencatatan pada Node C (Tujuan Akhir)
        final eventsC = loggerC.events;
        expect(
          eventsC.any(
            (e) =>
                e.eventType == MeshExperimentEventType.received &&
                e.outcome == 'DELIVERED_TO_APP',
          ),
          isTrue,
        );
        final destEvt = eventsC.firstWhere(
          (e) => e.eventType == MeshExperimentEventType.received,
        );
        expect(destEvt.hopCount, equals(1));
        expect(destEvt.routeTrace, equals(['NODE-A', 'NODE-B']));
        expect(destEvt.senderId, equals('NODE-A'));
        expect(destEvt.recipientId, equals('NODE-C'));

        // Uji deduplikasi: kirim ulang envelope yang sama ke Node C
        nodeC.transport.simulateIncomingPayload(
          endpointId: 'ep-B-on-C',
          bytes: sentEnvelope.createForwardedCopy('NODE-B').toBytes(),
        );
        await Future.delayed(const Duration(milliseconds: 50));

        expect(
          loggerC.events.any(
            (e) =>
                e.eventType == MeshExperimentEventType.rejected &&
                e.failureReason == 'DEDUP_CACHE_HIT',
          ),
          isTrue,
        );

        await subC.cancel();
        engineA.dispose();
        engineB.dispose();
        engineC.dispose();
        nodeA.dispose();
        nodeB.dispose();
        nodeC.dispose();
      },
    );

    test(
      '5. ManetRoutingEngine mencatat peristiwa antrean (queued) saat tidak ada tetangga aktif',
      () async {
        final logger = MeshExperimentLogger(
          activeRunId: 'EXP-STORE-01',
          activeTestType: 'DISTURBANCE_RECOVERY',
        );
        final node = VirtualMeshNode(
          nodeId: 'ISOLATED-A',
          nodeName: 'Isolated Node',
        );
        final engine = ManetRoutingEngine(
          transport: node.transport,
          identityManager: NodeIdentityManager(
            overrideId: 'ISOLATED-A',
            overrideName: 'Isolated Node',
          ),
          repository: node.repository,
          experimentLogger: logger,
        );

        // Node terisolasi (tidak ada tetangga) mengirim pesan
        await engine.sendChatMessage(
          recipientNodeId: 'TARGET-X',
          text: 'Pesan saat terisolasi',
        );

        final events = logger.events;
        expect(
          events.any((e) => e.eventType == MeshExperimentEventType.created),
          isTrue,
        );
        expect(
          events.any(
            (e) =>
                e.eventType == MeshExperimentEventType.queued &&
                e.failureReason == 'NO_ACTIVE_NEIGHBOR',
          ),
          isTrue,
        );

        engine.dispose();
        node.dispose();
      },
    );
  });
}

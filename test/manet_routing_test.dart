import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:siagamesh_app/core/routing/manet_routing_engine.dart';
import 'package:siagamesh_app/core/routing/message_envelope.dart';
import 'package:siagamesh_app/core/routing/neighbor_table.dart';
import 'package:siagamesh_app/core/routing/node_identity.dart';
import 'package:siagamesh_app/core/transport/fake_mesh_transport.dart';
import 'package:siagamesh_app/core/transport/mesh_transport.dart';
import 'package:siagamesh_app/features/chat/data/repositories/chat_repository.dart';

/// Simulasi transport tiruan yang dapat menghubungkan beberapa node dalam memori.
class SimulatedMeshTransport extends FakeMeshTransport {
  final Map<String, SimulatedMeshTransport> peerTransports = {};
  final Map<String, String> remoteEndpointMap = {};

  void linkWith({
    required String localEndpointId,
    required String remoteEndpointId,
    required SimulatedMeshTransport remoteTransport,
    required String remoteNodeName,
  }) {
    simulatePeerDiscovered(
      DiscoveredPeer(
        endpointId: localEndpointId,
        endpointName: remoteNodeName,
        serviceId: 'com.siagamesh.test',
        discoveredAt: DateTime.now(),
        status: PeerConnectionStatus.connected,
      ),
    );
    peerTransports[localEndpointId] = remoteTransport;
    remoteEndpointMap[localEndpointId] = remoteEndpointId;
  }

  void unlink(String localEndpointId) {
    simulateDisconnection(localEndpointId);
    peerTransports.remove(localEndpointId);
    remoteEndpointMap.remove(localEndpointId);
  }

  @override
  Future<bool> sendBytes({
    required String endpointId,
    required Uint8List bytes,
  }) async {
    final ok = await super.sendBytes(endpointId: endpointId, bytes: bytes);
    if (!ok) return false;

    final targetTransport = peerTransports[endpointId];
    final remoteEndpointId = remoteEndpointMap[endpointId];
    if (targetTransport != null && remoteEndpointId != null) {
      scheduleMicrotask(() {
        targetTransport.simulateIncomingPayload(
          endpointId: remoteEndpointId,
          bytes: bytes,
        );
      });
    }
    return true;
  }
}

/// Helper node virtual untuk pengujian MANET.
class VirtualMeshNode {
  final String nodeId;
  final String nodeName;
  final SimulatedMeshTransport transport;
  final LocalChatRepository repository;
  late final ManetRoutingEngine engine;

  VirtualMeshNode({required this.nodeId, required this.nodeName})
    : transport = SimulatedMeshTransport(),
      repository = LocalChatRepository() {
    engine = ManetRoutingEngine(
      transport: transport,
      identityManager: NodeIdentityManager(
        overrideId: nodeId,
        overrideName: nodeName,
      ),
      repository: repository,
    );
  }

  void dispose() {
    engine.dispose();
    transport.dispose();
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('STAGE 5B.2 — Pengujian Unit Routing & Forwarding Multi-Hop SiagaMesh', () {
    late VirtualMeshNode nodeA;
    late VirtualMeshNode nodeB;
    late VirtualMeshNode nodeC;

    setUp(() {
      nodeA = VirtualMeshNode(nodeId: 'NODE-A', nodeName: 'Node Relawan A');
      nodeB = VirtualMeshNode(nodeId: 'NODE-B', nodeName: 'Node Relay B');
      nodeC = VirtualMeshNode(nodeId: 'NODE-C', nodeName: 'Node Medis C');
    });

    tearDown(() {
      nodeA.dispose();
      nodeB.dispose();
      nodeC.dispose();
    });

    void connectLinearTopology() {
      // Tautan A <---> B (A dan C TIDAK terhubung langsung!)
      nodeA.transport.linkWith(
        localEndpointId: 'ep-B-on-A',
        remoteEndpointId: 'ep-A-on-B',
        remoteTransport: nodeB.transport,
        remoteNodeName: 'Node Relay B',
      );
      nodeB.transport.linkWith(
        localEndpointId: 'ep-A-on-B',
        remoteEndpointId: 'ep-B-on-A',
        remoteTransport: nodeA.transport,
        remoteNodeName: 'Node Relawan A',
      );
      nodeA.engine.neighborTable.registerConnectedEndpoint(
        endpointId: 'ep-B-on-A',
        endpointName: 'Node Relay B',
      );
      nodeA.engine.neighborTable.mapIdentity(
        endpointId: 'ep-B-on-A',
        nodeId: 'NODE-B',
        nodeName: 'Node Relay B',
      );
      nodeB.engine.neighborTable.registerConnectedEndpoint(
        endpointId: 'ep-A-on-B',
        endpointName: 'Node Relawan A',
      );
      nodeB.engine.neighborTable.mapIdentity(
        endpointId: 'ep-A-on-B',
        nodeId: 'NODE-A',
        nodeName: 'Node Relawan A',
      );

      // Tautan B <---> C
      nodeB.transport.linkWith(
        localEndpointId: 'ep-C-on-B',
        remoteEndpointId: 'ep-B-on-C',
        remoteTransport: nodeC.transport,
        remoteNodeName: 'Node Medis C',
      );
      nodeC.transport.linkWith(
        localEndpointId: 'ep-B-on-C',
        remoteEndpointId: 'ep-C-on-B',
        remoteTransport: nodeB.transport,
        remoteNodeName: 'Node Relay B',
      );
      nodeB.engine.neighborTable.registerConnectedEndpoint(
        endpointId: 'ep-C-on-B',
        endpointName: 'Node Medis C',
      );
      nodeB.engine.neighborTable.mapIdentity(
        endpointId: 'ep-C-on-B',
        nodeId: 'NODE-C',
        nodeName: 'Node Medis C',
      );
      nodeC.engine.neighborTable.registerConnectedEndpoint(
        endpointId: 'ep-B-on-C',
        endpointName: 'Node Relay B',
      );
      nodeC.engine.neighborTable.mapIdentity(
        endpointId: 'ep-B-on-C',
        nodeId: 'NODE-B',
        nodeName: 'Node Relay B',
      );
    }

    test(
      '1. Pesan dari A berhasil diteruskan oleh B dan diterima oleh C (A -> B -> C)',
      () async {
        connectLinearTopology();

        final completerC = Completer<MessageEnvelope>();
        final sub = nodeC.engine.incomingMessagesStream.listen(
          completerC.complete,
        );

        // A mengirim pesan ke C
        await nodeA.engine.sendChatMessage(
          recipientNodeId: 'NODE-C',
          text: 'Bantuan medis dibutuhkan di Sektor 2',
        );

        final receivedEnvelope = await completerC.future.timeout(
          const Duration(seconds: 2),
        );

        expect(receivedEnvelope.recipientId, equals('NODE-C'));
        expect(receivedEnvelope.senderId, equals('NODE-A'));
        expect(
          receivedEnvelope.payload['text'],
          equals('Bantuan medis dibutuhkan di Sektor 2'),
        );
        // Verifikasi hopCount dan routeTrace
        expect(receivedEnvelope.hopCount, equals(1));
        expect(receivedEnvelope.routeTrace, equals(['NODE-A', 'NODE-B']));
        expect(receivedEnvelope.ttl, equals(MessageEnvelope.defaultTtl - 1));

        // Verifikasi pesan tersimpan di ChatRepository lokal Node C
        final convs = await nodeC.repository.getConversations();
        final convA = convs.firstWhere((c) => c.peerNodeId == 'NODE-A');
        final msgsInC = await nodeC.repository.getMessages(convA.id);
        expect(
          msgsInC.any((m) => m.text == 'Bantuan medis dibutuhkan di Sektor 2'),
          isTrue,
        );
        expect(
          msgsInC.first.relayInfo,
          contains('Relay melalui 1 hop: [NODE-A → NODE-B]'),
        );

        await sub.cancel();
      },
    );

    test(
      '2. Pesan langsung (1-Hop A ke B) tidak diteruskan ke node lain',
      () async {
        connectLinearTopology();

        bool nodeCReceived = false;
        final sub = nodeC.engine.incomingMessagesStream.listen((_) {
          nodeCReceived = true;
        });

        final completerB = Completer<MessageEnvelope>();
        final subB = nodeB.engine.incomingMessagesStream.listen(
          completerB.complete,
        );

        // A mengirim pesan ke B langsung (bukan C, bukan broadcast)
        await nodeA.engine.sendChatMessage(
          recipientNodeId: 'NODE-B',
          text: 'Pesan rahasia hanya untuk Node B',
        );

        final receivedAtB = await completerB.future.timeout(
          const Duration(seconds: 2),
        );
        expect(receivedAtB.recipientId, equals('NODE-B'));
        expect(
          receivedAtB.payload['text'],
          equals('Pesan rahasia hanya untuk Node B'),
        );

        // Beri sedikit jeda mikro untuk memastikan tidak ada penerusan ke C
        await Future.delayed(const Duration(milliseconds: 100));
        expect(nodeCReceived, isFalse);

        await sub.cancel();
        await subB.cancel();
      },
    );

    test(
      '3. Pesan duplikat (envelopeId sama) ditolak oleh deduplication cache',
      () async {
        connectLinearTopology();

        int countReceivedAtC = 0;
        final subC = nodeC.engine.incomingMessagesStream.listen((_) {
          countReceivedAtC++;
        });

        final testEnvelope = MessageEnvelope(
          envelopeId: 'dup-msg-999',
          type: MessageEnvelope.typeChat,
          senderId: 'NODE-A',
          senderName: 'Node Relawan A',
          recipientId: 'NODE-C',
          createdAt: DateTime.now().millisecondsSinceEpoch,
          ttl: 5,
          hopCount: 0,
          routeTrace: ['NODE-A'],
          payload: {'messageId': 'msg-999', 'text': 'Pesan berulang'},
        );

        final bytes = testEnvelope.toBytes();

        // B menerima paket pertama kali dari A
        nodeB.transport.simulateIncomingPayload(
          endpointId: 'ep-A-on-B',
          bytes: bytes,
        );
        await Future.delayed(const Duration(milliseconds: 50));
        expect(countReceivedAtC, equals(1));

        // B menerima paket identik untuk kedua kalinya (misal dari broadcast atau pantulan)
        nodeB.transport.simulateIncomingPayload(
          endpointId: 'ep-A-on-B',
          bytes: bytes,
        );
        await Future.delayed(const Duration(milliseconds: 50));

        // C tetap hanya menerima 1 kali
        expect(countReceivedAtC, equals(1));

        await subC.cancel();
      },
    );

    test(
      '4. Batas hop / TTL mencegah penerusan tak terbatas (TTL habis dibuang)',
      () async {
        connectLinearTopology();

        bool nodeCReceived = false;
        final subC = nodeC.engine.incomingMessagesStream.listen((_) {
          nodeCReceived = true;
        });

        // Buat envelope dengan TTL = 1 ditujukan ke C (melewati B membutuhkan sisa TTL > 1)
        final zeroTtlEnvelope = MessageEnvelope(
          envelopeId: 'ttl-zero-msg',
          type: MessageEnvelope.typeChat,
          senderId: 'NODE-A',
          senderName: 'Node Relawan A',
          recipientId: 'NODE-C',
          createdAt: DateTime.now().millisecondsSinceEpoch,
          ttl:
              1, // Di B, envelope.ttl <= 1 sehingga tidak diteruskan ke hop berikutnya
          hopCount: 0,
          routeTrace: ['NODE-A'],
          payload: {
            'messageId': 'msg-ttl-zero',
            'text': 'Pesan dengan TTL habis di B',
          },
        );

        nodeB.transport.simulateIncomingPayload(
          endpointId: 'ep-A-on-B',
          bytes: zeroTtlEnvelope.toBytes(),
        );

        await Future.delayed(const Duration(milliseconds: 100));
        expect(nodeCReceived, isFalse);

        await subC.cancel();
      },
    );

    test(
      '5. Jejak rute (route trace) mendeteksi loop dan membuang paket',
      () async {
        connectLinearTopology();

        bool nodeBProcessed = false;
        final subB = nodeB.engine.forwardedMessagesStream.listen((_) {
          nodeBProcessed = true;
        });

        // Envelope yang routeTrace-nya sudah tercatat pernah melewati NODE-B
        final loopEnvelope = MessageEnvelope(
          envelopeId: 'loop-msg-777',
          type: MessageEnvelope.typeChat,
          senderId: 'NODE-A',
          senderName: 'Node Relawan A',
          recipientId: 'NODE-C',
          createdAt: DateTime.now().millisecondsSinceEpoch,
          ttl: 4,
          hopCount: 2,
          routeTrace: ['NODE-A', 'NODE-B', 'NODE-X'], // Sudah ada NODE-B!
          payload: {
            'messageId': 'msg-loop-777',
            'text': 'Pesan yang berputar kembali ke Node B',
          },
        );

        nodeB.transport.simulateIncomingPayload(
          endpointId: 'ep-A-on-B',
          bytes: loopEnvelope.toBytes(),
        );

        await Future.delayed(const Duration(milliseconds: 100));
        // Node B harus mendeteksi loop dan tidak meneruskannya
        expect(nodeBProcessed, isFalse);

        await subB.cancel();
      },
    );

    test(
      '6. Pesan tidak dipantulkan kembali ke tetangga asal (origin peer reflection prevention)',
      () async {
        connectLinearTopology();

        // Node A mengirim broadcast
        await nodeA.engine.sendChatMessage(
          recipientNodeId: 'BROADCAST',
          text: 'Peringatan siaran gempa susulan!',
        );

        await Future.delayed(const Duration(milliseconds: 100));

        // Verifikasi pada Node B: payload diteruskan ke C, TETAPI TIDAK ke endpoint A
        final payloadsSentByB = nodeB.transport.sentPayloads;
        // Periksa bahwa tidak ada payload dari B yang dikirim ke endpoint A ('ep-A-on-B')
        final sentBackToA = payloadsSentByB.any(
          (p) => p.endpointId == 'ep-A-on-B',
        );
        expect(sentBackToA, isFalse);

        // Pastikan payload dikirim ke C ('ep-C-on-B')
        final sentToC = payloadsSentByB.any((p) => p.endpointId == 'ep-C-on-B');
        expect(sentToC, isTrue);
      },
    );

    test(
      '7. Node tujuan C hanya menerima pesan satu kali meskipun disiarkan multi-jalur',
      () async {
        connectLinearTopology();

        int cReceiveCount = 0;
        final sub = nodeC.engine.incomingMessagesStream.listen((_) {
          cReceiveCount++;
        });

        final broadcastEnvelope = MessageEnvelope(
          envelopeId: 'bcast-multi-test-1',
          type: MessageEnvelope.typeChat,
          senderId: 'NODE-A',
          senderName: 'Node Relawan A',
          recipientId: 'BROADCAST',
          createdAt: DateTime.now().millisecondsSinceEpoch,
          ttl: 4,
          hopCount: 1,
          routeTrace: ['NODE-A', 'NODE-B'],
          payload: {
            'messageId': 'msg-bcast-1',
            'text': 'Informasi cuaca terkini',
          },
        );

        final bytes = broadcastEnvelope.toBytes();

        // C menerima pesan pertama kali
        nodeC.transport.simulateIncomingPayload(
          endpointId: 'ep-B-on-C',
          bytes: bytes,
        );
        await Future.delayed(const Duration(milliseconds: 50));
        expect(cReceiveCount, equals(1));

        // C menerima pesan yang sama dari jalur alternatif (simulasi)
        nodeC.transport.simulateIncomingPayload(
          endpointId: 'ep-B-on-C',
          bytes: bytes,
        );
        await Future.delayed(const Duration(milliseconds: 50));

        // C tetap mencatat pesan hanya 1 kali
        expect(cReceiveCount, equals(1));

        await sub.cancel();
      },
    );

    test(
      '8. Node perantara (B) TIDAK mencampur pesan relai ke dalam repository lokalnya',
      () async {
        connectLinearTopology();

        final completerC = Completer<MessageEnvelope>();
        final subC = nodeC.engine.incomingMessagesStream.listen(
          completerC.complete,
        );

        // A mengirim pesan ke C melalui B
        await nodeA.engine.sendChatMessage(
          recipientNodeId: 'NODE-C',
          text: 'Pesan transit privat A-ke-C',
        );

        await completerC.future.timeout(const Duration(seconds: 2));

        // Periksa ChatRepository pada Node B (Perantara)
        final convsInB = await nodeB.repository.getConversations();
        for (final conv in convsInB) {
          final messages = await nodeB.repository.getMessages(conv.id);
          final containsTransitMsg = messages.any(
            (m) => m.text == 'Pesan transit privat A-ke-C',
          );
          expect(
            containsTransitMsg,
            isFalse,
            reason:
                'Node perantara B tidak boleh menyimpan pesan transit ke percakapan lokalnya!',
          );
        }

        await subC.cancel();
      },
    );

    test(
      '9. Peer yang terputus (disconnected) tidak digunakan sebagai tautan aktif',
      () async {
        connectLinearTopology();

        // Putus hubungan B dengan C
        nodeB.transport.unlink('ep-C-on-B');
        nodeB.engine.neighborTable.markDisconnected('ep-C-on-B');

        expect(
          nodeB.engine.neighborTable.activeNeighbors.any(
            (n) => n.endpointId == 'ep-C-on-B',
          ),
          isFalse,
        );

        // A mengirim pesan ke C
        await nodeA.engine.sendChatMessage(
          recipientNodeId: 'NODE-C',
          text: 'Pesan saat jalur B-C putus',
        );

        await Future.delayed(const Duration(milliseconds: 100));

        // Verifikasi B tidak mengirim ke endpoint yang terputus
        final sentToDisconnected = nodeB.transport.sentPayloads.any(
          (p) => p.endpointId == 'ep-C-on-B',
        );
        expect(sentToDisconnected, isFalse);

        // Pesan harus tersimpan di antrean store-and-forward Node B!
        expect(
          nodeB.engine.storeAndForwardQueue.length,
          greaterThanOrEqualTo(1),
        );
      },
    );

    test(
      '10. Tujuan yang belum terjangkau mengantre di store-and-forward buffer',
      () async {
        // Node A berdiri sendiri tanpa tetangga terhubung sama sekali
        final orphanNode = VirtualMeshNode(
          nodeId: 'NODE-SOLO',
          nodeName: 'Node Terisolasi',
        );

        final envelope = await orphanNode.engine.sendChatMessage(
          recipientNodeId: 'NODE-TUJUAN-JAUH',
          text: 'Laporan darurat terisolasi',
          isEmergency: true,
        );

        // Verifikasi bahwa pesan mengantre di Store-and-Forward
        expect(orphanNode.engine.storeAndForwardQueue.length, equals(1));
        expect(
          orphanNode.engine.storeAndForwardQueue.contains(envelope.envelopeId),
          isTrue,
        );

        final pending = orphanNode.engine.storeAndForwardQueue
            .getPendingForTarget('NODE-TUJUAN-JAUH');
        expect(pending.length, equals(1));
        expect(
          pending.first.payload['text'],
          equals('Laporan darurat terisolasi'),
        );

        orphanNode.dispose();
      },
    );

    test(
      '11. Paket biner rusak, JSON korup, dan versi envelope tidak didukung diabaikan secara aman',
      () {
        final engine = nodeA.engine;

        // 11.1 JSON Rusak
        final corruptBytes = Uint8List.fromList(
          utf8.encode('{ "version": 1, corrupt_json ::: ['),
        );
        expect(
          () => nodeA.transport.simulateIncomingPayload(
            endpointId: 'ep-test',
            bytes: corruptBytes,
          ),
          returnsNormally,
        );

        // 11.2 Versi Envelope Tidak Didukung (misal version: 99)
        final unsupportedVersionEnvelope = {
          'version': 99,
          'envelopeId': 'env-future-v99',
          'type': 'CHAT_MESSAGE',
          'senderId': 'NODE-FUTURE',
          'senderName': 'Node Masa Depan',
          'recipientId': 'NODE-A',
          'createdAt': DateTime.now().millisecondsSinceEpoch,
          'ttl': 5,
          'hopCount': 0,
          'routeTrace': ['NODE-FUTURE'],
          'payload': {'text': 'Pesan format masa depan'},
        };
        final unsupportedBytes = Uint8List.fromList(
          utf8.encode(jsonEncode(unsupportedVersionEnvelope)),
        );
        expect(
          () => nodeA.transport.simulateIncomingPayload(
            endpointId: 'ep-test',
            bytes: unsupportedBytes,
          ),
          returnsNormally,
        );

        // 11.3 Payload Kosong
        expect(
          () => nodeA.transport.simulateIncomingPayload(
            endpointId: 'ep-test',
            bytes: Uint8List(0),
          ),
          returnsNormally,
        );

        // 11.4 Payload Melebihi Batas Ukuran (32 KB)
        final oversizedBytes = Uint8List(MessageEnvelope.maxPayloadBytes + 100);
        expect(
          () => nodeA.transport.simulateIncomingPayload(
            endpointId: 'ep-test',
            bytes: oversizedBytes,
          ),
          returnsNormally,
        );

        // 11.5 Envelope dengan field wajib bernilai null / tipe salah
        final malformedEnvelope = {
          'version': 1,
          'envelopeId': null,
          'type': 12345, // harusnya string
        };
        final malformedBytes = Uint8List.fromList(
          utf8.encode(jsonEncode(malformedEnvelope)),
        );
        expect(
          () => nodeA.transport.simulateIncomingPayload(
            endpointId: 'ep-test',
            bytes: malformedBytes,
          ),
          returnsNormally,
        );

        expect(engine.dedupCache.length, equals(0));
      },
    );

    test(
      '12. NodeIdentity dan NeighborTable berfungsi konsisten dan dapat dipulihkan',
      () async {
        final idMgr = NodeIdentityManager(
          overrideId: 'NODE-TEST-IDENTITY',
          overrideName: 'Identitas Uji',
        );
        expect(idMgr.localNodeId, equals('NODE-TEST-IDENTITY'));
        expect(idMgr.localNodeName, equals('Identitas Uji'));

        final table = NeighborTable();
        table.registerConnectedEndpoint(
          endpointId: 'ep-001',
          endpointName: 'Perangkat Tetangga',
        );
        table.mapIdentity(
          endpointId: 'ep-001',
          nodeId: 'NODE-NEIGHBOR-01',
          nodeName: 'Perangkat Tetangga',
        );

        expect(table.activeNeighbors.length, equals(1));
        expect(
          table.getEndpointIdForNode('NODE-NEIGHBOR-01'),
          equals('ep-001'),
        );
        expect(
          table.getNodeIdForEndpoint('ep-001'),
          equals('NODE-NEIGHBOR-01'),
        );

        table.markDisconnected('ep-001');
        expect(table.activeNeighbors.isEmpty, isTrue);
        // Ketika terputus, endpoint aktif untuk routing tidak lagi ditemukan
        expect(table.getEndpointIdForNode('NODE-NEIGHBOR-01'), isNull);
        // Namun riwayat peer tetap tercatat dengan status isConnected = false
        expect(
          table.getPeerByEndpoint('ep-001')?.nodeId,
          equals('NODE-NEIGHBOR-01'),
        );
        expect(table.getPeerByEndpoint('ep-001')?.isConnected, isFalse);
      },
    );

    test(
      '13. cancelQueuedMessage membatalkan pesan antrean store-and-forward dan mencegah flush saat peer baru terhubung',
      () async {
        final engineA = nodeA.engine;

        // Kirim pesan saat 0 peer terhubung -> pesan harus masuk antrean store-and-forward
        final env = await engineA.sendChatMessage(
          recipientNodeId: 'NODE-B',
          text: 'Pesan darurat yang akan dibatalkan',
        );

        final msgId = env.payload['messageId'] as String;
        expect(engineA.isMessageQueued(msgId), isTrue);
        expect(engineA.storeAndForwardQueue.length, equals(1));

        // Batalkan pesan dari antrean
        final cancelled = engineA.cancelQueuedMessage(msgId);
        expect(cancelled, isTrue);
        expect(engineA.isMessageQueued(msgId), isFalse);
        expect(engineA.storeAndForwardQueue.length, equals(0));

        // Membatalkan kedua kali mengembalikan false
        expect(engineA.cancelQueuedMessage(msgId), isFalse);

        // Sambungkan Node B: buktikan bahwa tidak ada pesan yang di-flush ke transport
        final prevSentPayloads = List.from(nodeA.transport.sentPayloads);
        nodeA.transport.simulatePeerDiscovered(
          DiscoveredPeer(
            endpointId: 'ep-node-b',
            endpointName: 'Node B',
            serviceId: 'com.siagamesh.emergency.mesh',
            discoveredAt: DateTime.now(),
            status: PeerConnectionStatus.connected,
          ),
        );
        // Beri waktu proses event koneksi
        await Future.delayed(const Duration(milliseconds: 50));

        // Cek payload yang dikirim ke ep-node-b setelah handshake; tidak boleh ada pesan yang dibatalkan tadi
        final newPayloads = nodeA.transport.sentPayloads.sublist(
          prevSentPayloads.length,
        );
        final containsCancelledMessage = newPayloads.any((p) {
          final str = utf8.decode(p.bytes);
          return str.contains('Pesan darurat yang akan dibatalkan');
        });
        expect(containsCancelledMessage, isFalse);
      },
    );
  });
}

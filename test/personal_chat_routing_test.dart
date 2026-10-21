import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:siagamesh_app/core/routing/manet_routing_engine.dart';
import 'package:siagamesh_app/core/routing/message_envelope.dart';
import 'package:siagamesh_app/core/routing/node_identity.dart';
import 'package:siagamesh_app/core/transport/fake_mesh_transport.dart';
import 'package:siagamesh_app/core/transport/mesh_transport.dart';
import 'package:siagamesh_app/features/chat/data/repositories/chat_repository.dart';
import 'package:siagamesh_app/features/chat/models/chat_message.dart';

/// Transport simulasi yang menghubungkan beberapa node di memori secara real-time.
class SimulatedMeshTransport extends FakeMeshTransport {
  final Map<String, SimulatedMeshTransport> peerTransports = {};
  final Map<String, String> remoteEndpointMap = {};
  final List<Uint8List> transmittedBytes = [];
  final List<String> transmittedToEndpoints = [];

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

    transmittedBytes.add(bytes);
    transmittedToEndpoints.add(endpointId);

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

/// Helper node virtual untuk pengujian komunikasi personal 1-to-1 antar-HP.
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

  group('PENGUJIAN PERBAIKAN BUG: Pesan Personal Antar-HP SiagaMesh', () {
    late VirtualMeshNode nodeA;
    late VirtualMeshNode nodeB;

    setUp(() {
      nodeA = VirtualMeshNode(nodeId: 'NODE-A', nodeName: 'Posko Relawan A');
      nodeB = VirtualMeshNode(nodeId: 'NODE-B', nodeName: 'Tim Medis B');
    });

    tearDown(() {
      nodeA.dispose();
      nodeB.dispose();
    });

    void establishDirectLink() {
      // Tautan langsung A <---> B
      nodeA.transport.linkWith(
        localEndpointId: 'ep-B-on-A',
        remoteEndpointId: 'ep-A-on-B',
        remoteTransport: nodeB.transport,
        remoteNodeName: 'Tim Medis B',
      );
      nodeB.transport.linkWith(
        localEndpointId: 'ep-A-on-B',
        remoteEndpointId: 'ep-B-on-A',
        remoteTransport: nodeA.transport,
        remoteNodeName: 'Posko Relawan A',
      );

      nodeA.engine.neighborTable.registerConnectedEndpoint(
        endpointId: 'ep-B-on-A',
        endpointName: 'Tim Medis B',
      );
      nodeA.engine.neighborTable.mapIdentity(
        endpointId: 'ep-B-on-A',
        nodeId: 'NODE-B',
        nodeName: 'Tim Medis B',
      );

      nodeB.engine.neighborTable.registerConnectedEndpoint(
        endpointId: 'ep-A-on-B',
        endpointName: 'Posko Relawan A',
      );
      nodeB.engine.neighborTable.mapIdentity(
        endpointId: 'ep-A-on-B',
        nodeId: 'NODE-A',
        nodeName: 'Posko Relawan A',
      );
    }

    test(
      '1. Pengiriman pesan personal A ke B berhasil diterima dan disimpan pada repository B',
      () async {
        establishDirectLink();

        final bReceivedCompleter = Completer<MessageEnvelope>();
        final sub = nodeB.engine.incomingMessagesStream.listen((envelope) {
          if (envelope.type == MessageEnvelope.typeChat &&
              envelope.payload['text'] == 'Halo Tim Medis B dari Posko A!') {
            bReceivedCompleter.complete(envelope);
          }
        });

        // Node A mengirim pesan personal ke Node B
        final sentEnv = await nodeA.engine.sendChatMessage(
          recipientNodeId: 'NODE-B',
          text: 'Halo Tim Medis B dari Posko A!',
        );

        expect(sentEnv.recipientId, equals('NODE-B'));

        // Tunggu hingga Node B menerima pesan melalui engine
        final receivedEnv = await bReceivedCompleter.future.timeout(
          const Duration(seconds: 2),
        );
        expect(receivedEnv.senderId, equals('NODE-A'));
        expect(
          receivedEnv.payload['text'],
          equals('Halo Tim Medis B dari Posko A!'),
        );

        // Beri jeda mikro-task untuk persistensi repositori
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // Verifikasi pesan tersimpan di ChatRepository Node B pada percakapan Posko Relawan A
        final conv = await nodeB.repository.getOrCreateConversationForNode(
          nodeId: 'NODE-A',
          nodeName: 'Posko Relawan A',
        );
        final messagesOnB = await nodeB.repository.getMessages(conv.id);
        expect(
          messagesOnB.any((m) => m.text == 'Halo Tim Medis B dari Posko A!'),
          isTrue,
        );

        final savedMsg = messagesOnB.firstWhere(
          (m) => m.text == 'Halo Tim Medis B dari Posko A!',
        );
        expect(savedMsg.isMe, isFalse);

        await sub.cancel();
      },
    );

    test(
      '2. Pengiriman pesan personal B ke A berhasil secara simetris',
      () async {
        establishDirectLink();

        final aReceivedCompleter = Completer<MessageEnvelope>();
        final sub = nodeA.engine.incomingMessagesStream.listen((envelope) {
          if (envelope.type == MessageEnvelope.typeChat &&
              envelope.payload['text'] == 'Laporan medis siap dari B!') {
            aReceivedCompleter.complete(envelope);
          }
        });

        // Node B mengirim pesan personal ke Node A
        final sentEnv = await nodeB.engine.sendChatMessage(
          recipientNodeId: 'NODE-A',
          text: 'Laporan medis siap dari B!',
        );

        expect(sentEnv.recipientId, equals('NODE-A'));

        final receivedEnv = await aReceivedCompleter.future.timeout(
          const Duration(seconds: 2),
        );
        expect(receivedEnv.senderId, equals('NODE-B'));
        expect(
          receivedEnv.payload['text'],
          equals('Laporan medis siap dari B!'),
        );

        // Beri jeda mikro-task untuk repositori
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // Verifikasi pesan tersimpan di ChatRepository Node A
        final conv = await nodeA.repository.getOrCreateConversationForNode(
          nodeId: 'NODE-B',
          nodeName: 'Tim Medis B',
        );
        final messagesOnA = await nodeA.repository.getMessages(conv.id);
        expect(
          messagesOnA.any((m) => m.text == 'Laporan medis siap dari B!'),
          isTrue,
        );

        final savedMsg = messagesOnA.firstWhere(
          (m) => m.text == 'Laporan medis siap dari B!',
        );
        expect(savedMsg.isMe, isFalse);

        await sub.cancel();
      },
    );

    test('3. Pengiriman pesan broadcast A ke B sebagai pembanding', () async {
      establishDirectLink();

      final bBroadcastCompleter = Completer<MessageEnvelope>();
      final sub = nodeB.engine.incomingMessagesStream.listen((envelope) {
        if (envelope.type == MessageEnvelope.typeChat &&
            envelope.recipientId == 'BROADCAST') {
          bBroadcastCompleter.complete(envelope);
        }
      });

      // Node A mengirim siaran broadcast
      final sentEnv = await nodeA.engine.sendChatMessage(
        recipientNodeId: 'BROADCAST',
        text: 'PERINGATAN: Gempa susulan dirasakan!',
        isEmergency: true,
      );

      expect(sentEnv.recipientId, equals('BROADCAST'));

      final receivedEnv = await bBroadcastCompleter.future.timeout(
        const Duration(seconds: 2),
      );
      expect(receivedEnv.recipientId, equals('BROADCAST'));
      expect(
        receivedEnv.payload['text'],
        equals('PERINGATAN: Gempa susulan dirasakan!'),
      );

      // Beri jeda mikro-task untuk persistensi repositori
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Verifikasi masuk ke percakapan siaran broadcast pada repository Node B
      final broadcastConv = await nodeB.repository
          .getOrCreateBroadcastConversation();
      final broadcastMsgs = await nodeB.repository.getMessages(
        broadcastConv.id,
      );
      expect(
        broadcastMsgs.any(
          (m) => m.text == 'PERINGATAN: Gempa susulan dirasakan!',
        ),
        isTrue,
      );

      await sub.cancel();
    });

    test(
      '4. Kecocokan destinationNodeId dengan node ID lokal penerima (normalisasi prefix & case-insensitivity)',
      () async {
        establishDirectLink();

        final bReceivedCompleter = Completer<MessageEnvelope>();
        final sub = nodeB.engine.incomingMessagesStream.listen((envelope) {
          if (envelope.payload['text'] == 'Pesan dengan format ID bertingkat') {
            bReceivedCompleter.complete(envelope);
          }
        });

        // A mengirim pesan menggunakan display label 'Node: #NODE-B'
        final sentEnv = await nodeA.engine.sendChatMessage(
          recipientNodeId: 'Node: #NODE-B',
          text: 'Pesan dengan format ID bertingkat',
        );

        // Engine mengkanonikalisasi recipientId menjadi NODE-B
        expect(sentEnv.recipientId, equals('NODE-B'));

        final receivedEnv = await bReceivedCompleter.future.timeout(
          const Duration(seconds: 2),
        );
        expect(receivedEnv.recipientId, equals('NODE-B'));
        expect(
          receivedEnv.payload['text'],
          equals('Pesan dengan format ID bertingkat'),
        );

        await sub.cancel();
      },
    );

    test(
      '5. Penolakan pesan personal yang memang ditujukan ke node lain (bukan untuk node lokal)',
      () async {
        // Topologi linear: A <---> B <---> C
        final nodeC = VirtualMeshNode(
          nodeId: 'NODE-C',
          nodeName: 'Posko Pengungsi C',
        );

        // Tautan A <---> B
        nodeA.transport.linkWith(
          localEndpointId: 'ep-B-on-A',
          remoteEndpointId: 'ep-A-on-B',
          remoteTransport: nodeB.transport,
          remoteNodeName: 'Tim Medis B',
        );
        nodeB.transport.linkWith(
          localEndpointId: 'ep-A-on-B',
          remoteEndpointId: 'ep-B-on-A',
          remoteTransport: nodeA.transport,
          remoteNodeName: 'Posko Relawan A',
        );
        nodeA.engine.neighborTable.registerConnectedEndpoint(
          endpointId: 'ep-B-on-A',
          endpointName: 'Tim Medis B',
        );
        nodeA.engine.neighborTable.mapIdentity(
          endpointId: 'ep-B-on-A',
          nodeId: 'NODE-B',
          nodeName: 'Tim Medis B',
        );
        nodeB.engine.neighborTable.registerConnectedEndpoint(
          endpointId: 'ep-A-on-B',
          endpointName: 'Posko Relawan A',
        );
        nodeB.engine.neighborTable.mapIdentity(
          endpointId: 'ep-A-on-B',
          nodeId: 'NODE-A',
          nodeName: 'Posko Relawan A',
        );

        // Tautan B <---> C
        nodeB.transport.linkWith(
          localEndpointId: 'ep-C-on-B',
          remoteEndpointId: 'ep-B-on-C',
          remoteTransport: nodeC.transport,
          remoteNodeName: 'Posko Pengungsi C',
        );
        nodeC.transport.linkWith(
          localEndpointId: 'ep-B-on-C',
          remoteEndpointId: 'ep-C-on-B',
          remoteTransport: nodeB.transport,
          remoteNodeName: 'Tim Medis B',
        );
        nodeB.engine.neighborTable.registerConnectedEndpoint(
          endpointId: 'ep-C-on-B',
          endpointName: 'Posko Pengungsi C',
        );
        nodeB.engine.neighborTable.mapIdentity(
          endpointId: 'ep-C-on-B',
          nodeId: 'NODE-C',
          nodeName: 'Posko Pengungsi C',
        );
        nodeC.engine.neighborTable.registerConnectedEndpoint(
          endpointId: 'ep-B-on-C',
          endpointName: 'Tim Medis B',
        );
        nodeC.engine.neighborTable.mapIdentity(
          endpointId: 'ep-B-on-C',
          nodeId: 'NODE-B',
          nodeName: 'Tim Medis B',
        );

        bool bReceivedLocally = false;
        final subB = nodeB.engine.incomingMessagesStream.listen((env) {
          if (env.payload['text'] == 'Pesan rahasia untuk Posko C') {
            bReceivedLocally = true;
          }
        });

        final cReceivedCompleter = Completer<MessageEnvelope>();
        final subC = nodeC.engine.incomingMessagesStream.listen((env) {
          if (env.payload['text'] == 'Pesan rahasia untuk Posko C') {
            cReceivedCompleter.complete(env);
          }
        });

        // A mengirim pesan personal ditujukan ke NODE-C melalui relay B
        await nodeA.engine.sendChatMessage(
          recipientNodeId: 'NODE-C',
          text: 'Pesan rahasia untuk Posko C',
        );

        // C harus menerima pesan
        final receivedOnC = await cReceivedCompleter.future.timeout(
          const Duration(seconds: 2),
        );
        expect(receivedOnC.recipientId, equals('NODE-C'));

        // Node B adalah intermediate relay: B TIDAK boleh menerima atau menampilkan pesan ini di UI/stream lokalnya
        expect(bReceivedLocally, isFalse);

        // Pastikan pesan tidak disimpan di repositori obrolan Node B
        final convsOnB = await nodeB.repository.getConversations();
        for (final conv in convsOnB) {
          final msgs = await nodeB.repository.getMessages(conv.id);
          expect(
            msgs.any((m) => m.text == 'Pesan rahasia untuk Posko C'),
            isFalse,
          );
        }

        await subB.cancel();
        await subC.cancel();
        nodeC.dispose();
      },
    );

    test(
      '6. Penyimpanan pesan masuk pada percakapan yang tepat dan migrasi dari ID sementara',
      () async {
        establishDirectLink();

        // Buat percakapan sementara sebelum identitas diketahui
        final tempConv = await nodeB.repository.getOrCreateConversationForNode(
          nodeId: 'peer-ep-A-on-B',
          nodeName: 'Posko Relawan A',
        );
        expect(tempConv.id, equals('conv-node-peer-ep-A-on-B'));

        // Kirim pesan personal dari A ke B
        await nodeA.engine.sendChatMessage(
          recipientNodeId: 'NODE-B',
          text: 'Pesan uji migrasi percakapan',
        );

        // Beri sedikit jeda mikro-task
        await Future<void>.delayed(const Duration(milliseconds: 100));

        // Saat identitas terpetakan ke NODE-A, getOrCreateConversationForNode harus memigrasikan atau mengarahkan ke NODE-A
        final realConv = await nodeB.repository.getOrCreateConversationForNode(
          nodeId: 'NODE-A',
          nodeName: 'Posko Relawan A',
        );

        final messages = await nodeB.repository.getMessages(realConv.id);
        expect(
          messages.any((m) => m.text == 'Pesan uji migrasi percakapan'),
          isTrue,
        );
      },
    );

    test(
      '7. Pemutusan dan penyambungan kembali peer mempertahankan identitas & riwayat obrolan',
      () async {
        establishDirectLink();

        // Kirim pesan pertama
        await nodeA.engine.sendChatMessage(
          recipientNodeId: 'NODE-B',
          text: 'Pesan sebelum putus koneksi',
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // Simulasikan pemutusan koneksi radio
        nodeA.transport.unlink('ep-B-on-A');
        nodeB.transport.unlink('ep-A-on-B');
        nodeA.engine.neighborTable.markDisconnected('ep-B-on-A');
        nodeB.engine.neighborTable.markDisconnected('ep-A-on-B');

        // Simulasikan penyambungan kembali dengan endpoint ID baru
        nodeA.transport.linkWith(
          localEndpointId: 'ep-B-reconnect',
          remoteEndpointId: 'ep-A-reconnect',
          remoteTransport: nodeB.transport,
          remoteNodeName: 'Tim Medis B',
        );
        nodeB.transport.linkWith(
          localEndpointId: 'ep-A-reconnect',
          remoteEndpointId: 'ep-B-reconnect',
          remoteTransport: nodeA.transport,
          remoteNodeName: 'Posko Relawan A',
        );
        nodeA.engine.neighborTable.registerConnectedEndpoint(
          endpointId: 'ep-B-reconnect',
          endpointName: 'Tim Medis B',
        );
        nodeA.engine.neighborTable.mapIdentity(
          endpointId: 'ep-B-reconnect',
          nodeId: 'NODE-B',
          nodeName: 'Tim Medis B',
        );
        nodeB.engine.neighborTable.registerConnectedEndpoint(
          endpointId: 'ep-A-reconnect',
          endpointName: 'Posko Relawan A',
        );
        nodeB.engine.neighborTable.mapIdentity(
          endpointId: 'ep-A-reconnect',
          nodeId: 'NODE-A',
          nodeName: 'Posko Relawan A',
        );

        // Kirim pesan kedua setelah sambung kembali
        await nodeA.engine.sendChatMessage(
          recipientNodeId: 'NODE-B',
          text: 'Pesan setelah terhubung kembali!',
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // Verifikasi kedua pesan tersimpan dalam riwayat percakapan yang sama di Node B
        final conv = await nodeB.repository.getOrCreateConversationForNode(
          nodeId: 'NODE-A',
          nodeName: 'Posko Relawan A',
        );
        final messages = await nodeB.repository.getMessages(conv.id);
        expect(
          messages.any((m) => m.text == 'Pesan sebelum putus koneksi'),
          isTrue,
        );
        expect(
          messages.any((m) => m.text == 'Pesan setelah terhubung kembali!'),
          isTrue,
        );
      },
    );

    test(
      '8. Status ACK dan status pengiriman konsisten (E2E ACK mengonfirmasi penerimaan di perangkat tujuan)',
      () async {
        establishDirectLink();

        // Buat percakapan di Node A
        final convA = await nodeA.repository.getOrCreateConversationForNode(
          nodeId: 'NODE-B',
          nodeName: 'Tim Medis B',
        );

        final aAckCompleter = Completer<MessageEnvelope>();
        final subA = nodeA.engine.incomingMessagesStream.listen((env) {
          if (env.type == MessageEnvelope.typeE2eAck) {
            aAckCompleter.complete(env);
          }
        });

        // Node A mengirim pesan ke Node B
        final sentEnv = await nodeA.engine.sendChatMessage(
          recipientNodeId: 'NODE-B',
          text: 'Pesan butuh konfirmasi E2E ACK',
        );
        final sentMsgId =
            sentEnv.payload['messageId'] as String? ?? sentEnv.envelopeId;

        // Simpan pesan di repositori lokal Node A sebagai pesan keluar dengan status Mengirim
        final outMessage = ChatMessage(
          id: sentMsgId,
          senderName: 'Posko Relawan A',
          text: 'Pesan butuh konfirmasi E2E ACK',
          time: '12:00',
          isMe: true,
          statusText: 'Mengirim...',
        );
        await nodeA.repository.saveMessage(convA.id, outMessage);

        // Tunggu hingga Node A menerima E2E_ACK yang dipicu otomatis oleh Node B
        final ackEnv = await aAckCompleter.future.timeout(
          const Duration(seconds: 2),
        );
        expect(ackEnv.type, equals(MessageEnvelope.typeE2eAck));
        expect(ackEnv.senderId, equals('NODE-B'));
        expect(ackEnv.recipientId, equals('NODE-A'));
        expect(ackEnv.payload['ackedMessageId'], equals(sentMsgId));

        // Beri jeda penyimpanan status di repositori
        await Future<void>.delayed(const Duration(milliseconds: 100));

        // Verifikasi status pesan pada repositori Node A diperbarui
        final updatedMsgs = await nodeA.repository.getMessages(convA.id);
        final checkedMsg = updatedMsgs.firstWhere((m) => m.id == sentMsgId);
        expect(
          checkedMsg.statusText,
          equals('Diterima di Perangkat Tujuan (E2E ACK)'),
        );

        await subA.cancel();
      },
    );

    test(
      '9. Pengiriman pesan personal tetap satu-ke-satu dan tidak bocor ke tetangga lain (bystander)',
      () async {
        // Topologi: A terhubung ke B dan A juga terhubung ke D (perangkat pihak ketiga yang tidak terlibat)
        final nodeD = VirtualMeshNode(
          nodeId: 'NODE-D',
          nodeName: 'Perangkat Lain D',
        );

        establishDirectLink();

        // Tautan A <---> D
        nodeA.transport.linkWith(
          localEndpointId: 'ep-D-on-A',
          remoteEndpointId: 'ep-A-on-D',
          remoteTransport: nodeD.transport,
          remoteNodeName: 'Perangkat Lain D',
        );
        nodeD.transport.linkWith(
          localEndpointId: 'ep-A-on-D',
          remoteEndpointId: 'ep-D-on-A',
          remoteTransport: nodeA.transport,
          remoteNodeName: 'Posko Relawan A',
        );
        nodeA.engine.neighborTable.registerConnectedEndpoint(
          endpointId: 'ep-D-on-A',
          endpointName: 'Perangkat Lain D',
        );
        nodeA.engine.neighborTable.mapIdentity(
          endpointId: 'ep-D-on-A',
          nodeId: 'NODE-D',
          nodeName: 'Perangkat Lain D',
        );
        nodeD.engine.neighborTable.registerConnectedEndpoint(
          endpointId: 'ep-A-on-D',
          endpointName: 'Posko Relawan A',
        );
        nodeD.engine.neighborTable.mapIdentity(
          endpointId: 'ep-A-on-D',
          nodeId: 'NODE-A',
          nodeName: 'Posko Relawan A',
        );

        bool dReceivedPayload = false;
        final subD = nodeD.engine.incomingMessagesStream.listen((env) {
          if (env.payload['text'] == 'Pesan rahasia 1-to-1 A ke B') {
            dReceivedPayload = true;
          }
        });

        // A mengirim pesan khusus untuk B
        await nodeA.engine.sendChatMessage(
          recipientNodeId: 'NODE-B',
          text: 'Pesan rahasia 1-to-1 A ke B',
        );

        await Future<void>.delayed(const Duration(milliseconds: 100));

        // Verifikasi node D TIDAK menerima payload
        expect(dReceivedPayload, isFalse);

        // Verifikasi transport A hanya mengirimkan bytes ke endpoint B, bukan ke endpoint D
        expect(
          nodeA.transport.transmittedToEndpoints.contains('ep-D-on-A'),
          isFalse,
        );
        expect(
          nodeA.transport.transmittedToEndpoints.contains('ep-B-on-A'),
          isTrue,
        );

        await subD.cancel();
        nodeD.dispose();
      },
    );
  });
}

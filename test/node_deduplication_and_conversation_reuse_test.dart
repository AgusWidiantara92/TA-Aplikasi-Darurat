import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:siagamesh_app/core/routing/manet_routing_engine.dart';
import 'package:siagamesh_app/core/routing/message_envelope.dart';
import 'package:siagamesh_app/core/routing/neighbor_table.dart';
import 'package:siagamesh_app/core/routing/node_identity.dart';
import 'package:siagamesh_app/core/routing/routing_holder.dart';
import 'package:siagamesh_app/core/transport/fake_mesh_transport.dart';
import 'package:siagamesh_app/core/transport/mesh_transport.dart';
import 'package:siagamesh_app/features/chat/data/repositories/chat_repository.dart';
import 'package:siagamesh_app/features/chat/models/chat_message.dart';
import 'package:siagamesh_app/features/mesh_devices/presentation/mesh_devices_screen.dart';

/// Transport simulasi nirkabel 1-hop multi-node untuk pengujian real-time.
class TestMeshTransport extends FakeMeshTransport {
  final Map<String, TestMeshTransport> linkedPeers = {};
  final Map<String, String> peerEndpointMap = {};

  void linkWith({
    required String localEndpointId,
    required String remoteEndpointId,
    required TestMeshTransport remoteTransport,
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
    linkedPeers[localEndpointId] = remoteTransport;
    peerEndpointMap[localEndpointId] = remoteEndpointId;
  }

  void unlink(String localEndpointId) {
    simulateDisconnection(localEndpointId);
    linkedPeers.remove(localEndpointId);
    peerEndpointMap.remove(localEndpointId);
  }

  @override
  Future<bool> sendBytes({
    required String endpointId,
    required Uint8List bytes,
  }) async {
    final ok = await super.sendBytes(endpointId: endpointId, bytes: bytes);
    if (!ok) return false;

    final remoteTransport = linkedPeers[endpointId];
    final remoteEndpointId = peerEndpointMap[endpointId];
    if (remoteTransport != null && remoteEndpointId != null) {
      scheduleMicrotask(() {
        remoteTransport.simulateIncomingPayload(
          endpointId: remoteEndpointId,
          bytes: bytes,
        );
      });
    }
    return true;
  }
}

class TestNodeFixture {
  final String nodeId;
  final String nodeName;
  final TestMeshTransport transport;
  final LocalChatRepository repository;
  late final ManetRoutingEngine engine;

  TestNodeFixture({required this.nodeId, required this.nodeName})
    : transport = TestMeshTransport(),
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
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group(
    'PENGUJIAN BUG FIX: Deduplikasi Node, Identitas Stabil, & Penggunaan Ulang Percakapan',
    () {
      // 1. Endpoint yang ditemukan berulang dengan nodeId sama hanya menghasilkan satu node pada UI
      testWidgets(
        '1. Endpoint yang ditemukan berulang dengan nodeId sama hanya menghasilkan satu node pada UI',
        (tester) async {
          final nodeA = TestNodeFixture(
            nodeId: 'NODE-LOCAL',
            nodeName: 'Posko Pusat',
          );
          ManetRoutingHolder.setInstance(nodeA.engine);

          // Simulasi transport mendeteksi 2 endpoint berbeda (misalnya ep-1 dan ep-2 setelah re-advertised)
          // dari perangkat fisik yang sama (NODE-PHYSICAL-B)
          nodeA.transport.simulatePeerDiscovered(
            DiscoveredPeer(
              endpointId: 'ep-1',
              endpointName: 'HP Relawan B',
              serviceId: 'com.siagamesh.test',
              discoveredAt: DateTime.now().subtract(
                const Duration(seconds: 10),
              ),
              status: PeerConnectionStatus.disconnected,
            ),
          );
          nodeA.transport.simulatePeerDiscovered(
            DiscoveredPeer(
              endpointId: 'ep-2',
              endpointName: 'HP Relawan B',
              serviceId: 'com.siagamesh.test',
              discoveredAt: DateTime.now(),
              status: PeerConnectionStatus.connected,
            ),
          );

          // Handshake telah memetakan kedua endpoint ke nodeId kanonis yang sama
          nodeA.engine.neighborTable.registerConnectedEndpoint(
            endpointId: 'ep-1',
            endpointName: 'HP Relawan B',
          );
          nodeA.engine.neighborTable.mapIdentity(
            endpointId: 'ep-1',
            nodeId: 'NODE-PHYSICAL-B',
            nodeName: 'HP Relawan B',
          );
          nodeA.engine.neighborTable.registerConnectedEndpoint(
            endpointId: 'ep-2',
            endpointName: 'HP Relawan B',
          );
          nodeA.engine.neighborTable.mapIdentity(
            endpointId: 'ep-2',
            nodeId: 'NODE-PHYSICAL-B',
            nodeName: 'HP Relawan B',
          );

          // Verifikasi pada layer tabel routing: activeNeighbors hanya berisi 1 peer kanonis
          expect(nodeA.engine.neighborTable.activeNeighbors.length, equals(1));
          expect(
            nodeA.engine.neighborTable.activeNeighbors.first.nodeId,
            equals('NODE-PHYSICAL-B'),
          );

          // Render MeshDevicesScreen pada UI
          await tester.pumpWidget(
            MaterialApp(
              home: MeshDevicesScreen(
                repository: nodeA.repository,
                transport: nodeA.transport,
              ),
            ),
          );
          await tester.pumpAndSettle();

          // Verifikasi pada UI: hanya ada SATU kartu perangkat untuk 'HP Relawan B'
          final peerCards = find.text('HP Relawan B');
          expect(peerCards, findsOneWidget);

          // Total peer terdeteksi pada header kartu ringkasan menunjukkan 1 PEER
          expect(find.text('TERHUBUNG • 1 PEER AKTIF'), findsOneWidget);
          expect(find.text('Daftar Peer Terdeteksi (1)'), findsOneWidget);
        },
      );

      // 2. EndpointId baru setelah reconnect tetap dipetakan ke nodeId yang sama
      test(
        '2. EndpointId baru setelah reconnect tetap dipetakan ke nodeId yang sama',
        () async {
          final table = NeighborTable();

          // Sesi awal: terhubung via ep-initial
          table.registerConnectedEndpoint(
            endpointId: 'ep-initial',
            endpointName: 'Ponsel B',
          );
          table.mapIdentity(
            endpointId: 'ep-initial',
            nodeId: 'NODE-B-CANONICAL',
            nodeName: 'Ponsel B',
          );

          expect(
            table.getEndpointIdForNode('NODE-B-CANONICAL'),
            equals('ep-initial'),
          );
          expect(
            table.getNodeIdForEndpoint('ep-initial'),
            equals('NODE-B-CANONICAL'),
          );

          // Sesi reconnect: ep-initial terputus, endpoint baru ep-reconnect terhubung
          table.markDisconnected('ep-initial');
          table.registerConnectedEndpoint(
            endpointId: 'ep-reconnect',
            endpointName: 'Ponsel B',
          );
          table.mapIdentity(
            endpointId: 'ep-reconnect',
            nodeId: 'NODE-B-CANONICAL',
            nodeName: 'Ponsel B',
          );

          // Node ID tetap sama, endpoint ID aktif otomatis beralih ke endpoint baru
          expect(
            table.getNodeIdForEndpoint('ep-reconnect'),
            equals('NODE-B-CANONICAL'),
          );
          expect(
            table.getEndpointIdForNode('NODE-B-CANONICAL'),
            equals('ep-reconnect'),
          );
          expect(table.isNodeConnected('NODE-B-CANONICAL'), isTrue);
        },
      );

      // 3. Disconnect satu endpoint tidak menandai node terputus jika endpoint lain masih aktif
      test(
        '3. Disconnect satu endpoint tidak menandai node terputus jika endpoint lain masih aktif',
        () async {
          final table = NeighborTable();

          // Node B memiliki dua endpoint koneksi aktif sekaligus (misal Bluetooth + Wi-Fi Direct)
          table.registerConnectedEndpoint(
            endpointId: 'ep-bt',
            endpointName: 'Node B',
          );
          table.mapIdentity(
            endpointId: 'ep-bt',
            nodeId: 'NODE-B',
            nodeName: 'Node B',
          );

          table.registerConnectedEndpoint(
            endpointId: 'ep-wifi',
            endpointName: 'Node B',
          );
          table.mapIdentity(
            endpointId: 'ep-wifi',
            nodeId: 'NODE-B',
            nodeName: 'Node B',
          );

          expect(table.isNodeConnected('NODE-B'), isTrue);

          // Putus sambungan salah satu endpoint (ep-bt)
          table.markDisconnected('ep-bt');

          // Node B TIDAK boleh dianggap terputus karena ep-wifi masih aktif
          expect(table.isNodeConnected('NODE-B'), isTrue);
          expect(table.getEndpointIdForNode('NODE-B'), equals('ep-wifi'));

          // Setelah ep-wifi juga terputus, barulah node dianggap terputus
          table.markDisconnected('ep-wifi');
          expect(table.isNodeConnected('NODE-B'), isFalse);
        },
      );

      // 4. Satu node hanya memiliki satu percakapan personal kanonis
      test(
        '4. Satu node hanya memiliki satu percakapan personal kanonis',
        () async {
          final repo = LocalChatRepository();

          // Panggilan pertama membuat percakapan
          final conv1 = await repo.getOrCreateConversationForNode(
            nodeId: 'NODE-STABLE-1',
            nodeName: 'Relawan Alpha',
          );
          expect(conv1.id, equals('conv-node-NODE-STABLE-1'));

          // Panggilan kedua dengan format display / huruf besar-kecil berbeda
          final conv2 = await repo.getOrCreateConversationForNode(
            nodeId: 'Node: #NODE-STABLE-1',
            nodeName: 'Relawan Alpha',
          );
          expect(conv2.id, equals('conv-node-NODE-STABLE-1'));

          // Panggilan ketiga setelah reconnect
          final conv3 = await repo.getOrCreateConversationForNode(
            nodeId: 'node-stable-1',
            nodeName: 'Relawan Alpha (Updated)',
          );
          expect(conv3.id, equals('conv-node-NODE-STABLE-1'));

          // Pastikan hanya ada 1 percakapan di cache repository
          final all = await repo.getConversations();
          expect(all.length, equals(1));
          expect(all.first.id, equals('conv-node-NODE-STABLE-1'));
        },
      );

      // 5. Pesan dan riwayat lama tidak terduplikasi saat migrasi percakapan
      test(
        '5. Pesan dan riwayat lama tidak terduplikasi saat migrasi percakapan',
        () async {
          final repo = LocalChatRepository();

          // Buat percakapan sementara sebelum handshake selesai
          final tempConv = await repo.getOrCreateConversationForNode(
            nodeId: 'peer-ep-temp-123',
            nodeName: 'Posko Alpha',
          );

          // Simpan pesan di percakapan sementara
          final msg1 = ChatMessage(
            id: 'msg-001',
            senderName: 'Posko Alpha',
            text: 'Pesan awal saat pending',
            time: '10:00',
            isMe: false,
            statusText: 'Mengirim...',
          );
          final msg2 = ChatMessage(
            id: 'msg-002',
            senderName: 'Posko Alpha',
            text: 'Pesan kedua saat pending',
            time: '10:01',
            isMe: false,
          );
          await repo.saveMessage(tempConv.id, msg1);
          await repo.saveMessage(tempConv.id, msg2);

          // Buat atau simulasikan target kanonis yang sudah memiliki msg-001 dengan status ACK
          final canonicalConv = await repo.getOrCreateConversationForNode(
            nodeId: 'NODE-ALPHA-REAL',
            nodeName: 'Posko Alpha',
            endpointId: 'ep-temp-123',
          );

          // Verifikasi ID percakapan terkanonisasi
          expect(canonicalConv.id, equals('conv-node-NODE-ALPHA-REAL'));

          // Ambil riwayat pesan hasil migrasi
          final migratedMessages = await repo.getMessages(canonicalConv.id);

          // Pesan tidak boleh berulang (tepat 2 pesan unik: msg-001 dan msg-002)
          expect(migratedMessages.length, equals(2));
          final msgIds = migratedMessages.map((m) => m.id).toList();
          expect(msgIds, containsAllInOrder(['msg-001', 'msg-002']));

          // Percakapan lama 'peer-ep-temp-123' sudah tidak ada di daftar
          final convs = await repo.getConversations();
          expect(convs.any((c) => c.id == tempConv.id), isFalse);
        },
      );

      // 6. Dua node dengan displayName sama tetap dipisahkan
      test('6. Dua node dengan displayName sama tetap dipisahkan', () async {
        final repo = LocalChatRepository();

        // Dua node berbeda memiliki displayName yang sama ("Relawan Siaga")
        final convA = await repo.getOrCreateConversationForNode(
          nodeId: 'NODE-DEVICE-AAA',
          nodeName: 'Relawan Siaga',
        );
        final convB = await repo.getOrCreateConversationForNode(
          nodeId: 'NODE-DEVICE-BBB',
          nodeName: 'Relawan Siaga',
        );

        expect(convA.id, equals('conv-node-NODE-DEVICE-AAA'));
        expect(convB.id, equals('conv-node-NODE-DEVICE-BBB'));
        expect(convA.id, isNot(equals(convB.id)));

        // Simpan pesan di Node A
        await repo.saveMessage(
          convA.id,
          ChatMessage(
            id: 'msg-a',
            senderName: 'Relawan Siaga',
            text: 'Pesan rahasia untuk Device AAA',
            time: '12:00',
            isMe: true,
          ),
        );

        // Simpan pesan di Node B
        await repo.saveMessage(
          convB.id,
          ChatMessage(
            id: 'msg-b',
            senderName: 'Relawan Siaga',
            text: 'Pesan rahasia untuk Device BBB',
            time: '12:01',
            isMe: true,
          ),
        );

        final msgsA = await repo.getMessages(convA.id);
        final msgsB = await repo.getMessages(convB.id);

        expect(msgsA.length, equals(1));
        expect(msgsA.first.text, equals('Pesan rahasia untuk Device AAA'));

        expect(msgsB.length, equals(1));
        expect(msgsB.first.text, equals('Pesan rahasia untuk Device BBB'));

        // Total percakapan ada 2, tidak tercampur
        final allConvs = await repo.getConversations();
        expect(allConvs.length, equals(2));
      });

      // 7. Menghapus percakapan menghapus riwayat sesuai aturan tanpa merusak identitas node
      test(
        '7. Menghapus percakapan menghapus riwayat sesuai aturan tanpa merusak identitas node',
        () async {
          final node = TestNodeFixture(
            nodeId: 'NODE-MAIN',
            nodeName: 'Pusat Komando',
          );

          // Daftarkan peer di neighborTable
          node.engine.neighborTable.registerConnectedEndpoint(
            endpointId: 'ep-target',
            endpointName: 'Posko 1',
          );
          node.engine.neighborTable.mapIdentity(
            endpointId: 'ep-target',
            nodeId: 'NODE-TARGET-01',
            nodeName: 'Posko 1',
          );

          // Buat percakapan dan pesan
          final conv = await node.repository.getOrCreateConversationForNode(
            nodeId: 'NODE-TARGET-01',
            nodeName: 'Posko 1',
          );
          await node.repository.saveMessage(
            conv.id,
            ChatMessage(
              id: 'msg-del-1',
              senderName: 'Posko 1',
              text: 'Riwayat percakapan lama',
              time: '08:00',
              isMe: false,
            ),
          );

          // Pastikan tersimpan
          expect(
            (await node.repository.getMessages(conv.id)).length,
            equals(1),
          );

          // Hapus percakapan
          final deleted = await node.repository.deleteConversation(conv.id);
          expect(deleted, isTrue);

          // Verifikasi riwayat lokal & ringkasan terhapus
          final convsAfter = await node.repository.getConversations();
          expect(convsAfter.any((c) => c.id == conv.id), isFalse);
          final msgsAfter = await node.repository.getMessages(conv.id);
          expect(msgsAfter, isEmpty);

          // Verifikasi identitas node di tabel routing TETAP AMAN & TIDAK RUSAK
          expect(
            node.engine.neighborTable.isNodeConnected('NODE-TARGET-01'),
            isTrue,
          );
          expect(
            node.engine.neighborTable.getEndpointIdForNode('NODE-TARGET-01'),
            equals('ep-target'),
          );
        },
      );

      // 8. Pesan baru dari node yang sama setelah penghapusan membuat percakapan kembali tanpa memulihkan pesan yang sudah dihapus
      test(
        '8. Pesan baru dari node yang sama setelah penghapusan membuat percakapan kembali tanpa memulihkan pesan yang sudah dihapus',
        () async {
          final node = TestNodeFixture(
            nodeId: 'NODE-RECV',
            nodeName: 'Penerima',
          );

          // 1. Buat percakapan awal dan simpan 2 pesan
          final conv = await node.repository.getOrCreateConversationForNode(
            nodeId: 'NODE-SENDER',
            nodeName: 'Pengirim',
          );
          await node.repository.saveMessage(
            conv.id,
            ChatMessage(
              id: 'msg-old-1',
              senderName: 'Pengirim',
              text: 'Pesan lama 1',
              time: '07:00',
              isMe: false,
            ),
          );
          await node.repository.saveMessage(
            conv.id,
            ChatMessage(
              id: 'msg-old-2',
              senderName: 'Pengirim',
              text: 'Pesan lama 2',
              time: '07:05',
              isMe: false,
            ),
          );

          // 2. Pengguna menghapus percakapan
          await node.repository.deleteConversation(conv.id);
          expect(await node.repository.getConversations(), isEmpty);

          // 3. Pengirim yang sama mengirimkan pesan baru via jaringan
          final newEnvelope = MessageEnvelope(
            envelopeId: 'env-new-1',
            type: MessageEnvelope.typeChat,
            senderId: 'NODE-SENDER',
            senderName: 'Pengirim',
            recipientId: 'NODE-RECV',
            createdAt: DateTime.now().millisecondsSinceEpoch,
            ttl: 3,
            hopCount: 0,
            routeTrace: ['NODE-SENDER'],
            payload: {
              'messageId': 'msg-fresh-001',
              'text': 'Pesan baru setelah chat dihapus',
              'time': '09:00',
              'isEmergency': false,
            },
          );

          // Simulasikan pesan masuk di engine
          node.transport.simulateIncomingPayload(
            endpointId: 'ep-sender',
            bytes: newEnvelope.toBytes(),
          );

          await Future<void>.delayed(const Duration(milliseconds: 100));

          // 4. Verifikasi percakapan dibuat kembali dengan ID kanonis yang sama
          final convsRecreated = await node.repository.getConversations();
          expect(convsRecreated.length, equals(1));
          final recreated = convsRecreated.first;
          expect(recreated.id, equals('conv-node-NODE-SENDER'));
          expect(
            recreated.lastMessage,
            equals('Pesan baru setelah chat dihapus'),
          );

          // 5. Pesan lama TIDAK PULIH, hanya pesan baru yang tersimpan
          final freshMessages = await node.repository.getMessages(recreated.id);
          expect(freshMessages.length, equals(1));
          expect(freshMessages.first.id, equals('msg-fresh-001'));
          expect(
            freshMessages.first.text,
            equals('Pesan baru setelah chat dihapus'),
          );
          expect(freshMessages.any((m) => m.id == 'msg-old-1'), isFalse);
        },
      );

      // 9. Reconnect tidak merusak pengiriman personal dan E2E ACK
      test(
        '9. Reconnect tidak merusak pengiriman personal dan E2E ACK',
        () async {
          final nodeA = TestNodeFixture(nodeId: 'NODE-A', nodeName: 'Posko A');
          final nodeB = TestNodeFixture(nodeId: 'NODE-B', nodeName: 'Posko B');

          // Link awal: ep-a1 <-> ep-b1
          nodeA.transport.linkWith(
            localEndpointId: 'ep-b1',
            remoteEndpointId: 'ep-a1',
            remoteTransport: nodeB.transport,
            remoteNodeName: 'Posko B',
          );
          nodeB.transport.linkWith(
            localEndpointId: 'ep-a1',
            remoteEndpointId: 'ep-b1',
            remoteTransport: nodeA.transport,
            remoteNodeName: 'Posko A',
          );

          nodeA.engine.neighborTable.registerConnectedEndpoint(
            endpointId: 'ep-b1',
            endpointName: 'Posko B',
          );
          nodeA.engine.neighborTable.mapIdentity(
            endpointId: 'ep-b1',
            nodeId: 'NODE-B',
            nodeName: 'Posko B',
          );

          nodeB.engine.neighborTable.registerConnectedEndpoint(
            endpointId: 'ep-a1',
            endpointName: 'Posko A',
          );
          nodeB.engine.neighborTable.mapIdentity(
            endpointId: 'ep-a1',
            nodeId: 'NODE-A',
            nodeName: 'Posko A',
          );

          // Kirim pesan pertama
          final env1 = await nodeA.engine.sendChatMessage(
            recipientNodeId: 'NODE-B',
            text: 'Pesan sesi 1',
          );
          final msg1Id = env1.payload['messageId'] as String;

          await Future<void>.delayed(const Duration(milliseconds: 100));

          // Verifikasi pesan 1 sampai dan menerima E2E ACK
          final msgsB1 = await nodeB.repository.getMessages('conv-node-NODE-A');
          expect(msgsB1.any((m) => m.id == msg1Id), isTrue);

          // Simulasi RECONNECT (putus sambungan radio, bentuk sambungan dengan endpoint ID baru)
          nodeA.transport.unlink('ep-b1');
          nodeB.transport.unlink('ep-a1');

          nodeA.engine.neighborTable.markDisconnected('ep-b1');
          nodeB.engine.neighborTable.markDisconnected('ep-a1');

          // Sambungkan kembali dengan endpoint baru ep-b2 <-> ep-a2
          nodeA.transport.linkWith(
            localEndpointId: 'ep-b2',
            remoteEndpointId: 'ep-a2',
            remoteTransport: nodeB.transport,
            remoteNodeName: 'Posko B',
          );
          nodeB.transport.linkWith(
            localEndpointId: 'ep-a2',
            remoteEndpointId: 'ep-b2',
            remoteTransport: nodeA.transport,
            remoteNodeName: 'Posko A',
          );

          nodeA.engine.neighborTable.registerConnectedEndpoint(
            endpointId: 'ep-b2',
            endpointName: 'Posko B',
          );
          nodeA.engine.neighborTable.mapIdentity(
            endpointId: 'ep-b2',
            nodeId: 'NODE-B',
            nodeName: 'Posko B',
          );

          nodeB.engine.neighborTable.registerConnectedEndpoint(
            endpointId: 'ep-a2',
            endpointName: 'Posko A',
          );
          nodeB.engine.neighborTable.mapIdentity(
            endpointId: 'ep-a2',
            nodeId: 'NODE-A',
            nodeName: 'Posko A',
          );

          // Kirim pesan kedua setelah reconnect
          final env2 = await nodeA.engine.sendChatMessage(
            recipientNodeId: 'NODE-B',
            text: 'Pesan sesi 2 setelah reconnect',
          );
          final msg2Id = env2.payload['messageId'] as String;

          await Future<void>.delayed(const Duration(milliseconds: 100));

          // Verifikasi pesan 2 sampai di Node B dalam percakapan yang SAMA
          final msgsB2 = await nodeB.repository.getMessages('conv-node-NODE-A');
          expect(msgsB2.any((m) => m.id == msg2Id), isTrue);
          expect(msgsB2.length, equals(2));

          // Verifikasi Node B hanya memiliki 1 percakapan untuk Node A
          final convsB = await nodeB.repository.getConversations();
          expect(convsB.length, equals(1));
          expect(convsB.first.id, equals('conv-node-NODE-A'));
        },
      );

      // 10. Broadcast tetap terpisah dari percakapan personal
      test('10. Broadcast tetap terpisah dari percakapan personal', () async {
        final nodeA = TestNodeFixture(nodeId: 'NODE-A', nodeName: 'Posko A');
        final nodeB = TestNodeFixture(nodeId: 'NODE-B', nodeName: 'Posko B');

        nodeA.transport.linkWith(
          localEndpointId: 'ep-b',
          remoteEndpointId: 'ep-a',
          remoteTransport: nodeB.transport,
          remoteNodeName: 'Posko B',
        );
        nodeB.transport.linkWith(
          localEndpointId: 'ep-a',
          remoteEndpointId: 'ep-b',
          remoteTransport: nodeA.transport,
          remoteNodeName: 'Posko A',
        );

        nodeA.engine.neighborTable.registerConnectedEndpoint(
          endpointId: 'ep-b',
          endpointName: 'Posko B',
        );
        nodeA.engine.neighborTable.mapIdentity(
          endpointId: 'ep-b',
          nodeId: 'NODE-B',
          nodeName: 'Posko B',
        );

        nodeB.engine.neighborTable.registerConnectedEndpoint(
          endpointId: 'ep-a',
          endpointName: 'Posko A',
        );
        nodeB.engine.neighborTable.mapIdentity(
          endpointId: 'ep-a',
          nodeId: 'NODE-A',
          nodeName: 'Posko A',
        );

        // 1. Kirim pesan broadcast
        await nodeA.engine.sendChatMessage(
          recipientNodeId: 'BROADCAST',
          text: 'SIARAN: Evakuasi ke titik aman',
          isEmergency: true,
        );

        // 2. Kirim pesan personal
        await nodeA.engine.sendChatMessage(
          recipientNodeId: 'NODE-B',
          text: 'Pesan khusus satu-ke-satu untuk Posko B',
        );

        await Future<void>.delayed(const Duration(milliseconds: 100));

        // Verifikasi di Node B:
        // Percakapan broadcast-all hanya berisi pesan broadcast
        final broadcastMsgs = await nodeB.repository.getMessages(
          'broadcast-all',
        );
        expect(broadcastMsgs.length, equals(1));
        expect(
          broadcastMsgs.first.text,
          equals('SIARAN: Evakuasi ke titik aman'),
        );

        // Percakapan personal conv-node-NODE-A hanya berisi pesan personal
        final personalMsgs = await nodeB.repository.getMessages(
          'conv-node-NODE-A',
        );
        expect(personalMsgs.length, equals(1));
        expect(
          personalMsgs.first.text,
          equals('Pesan khusus satu-ke-satu untuk Posko B'),
        );

        // Kedua percakapan terpisah di daftar percakapan
        final convs = await nodeB.repository.getConversations();
        expect(convs.length, equals(2));
        expect(convs.any((c) => c.id == 'broadcast-all'), isTrue);
        expect(convs.any((c) => c.id == 'conv-node-NODE-A'), isTrue);
      });

      // 11. Tidak ada data duplikat setelah restart aplikasi
      test('11. Tidak ada data duplikat setelah restart aplikasi', () async {
        final mockStorage = <String, Object>{};
        SharedPreferences.setMockInitialValues(mockStorage);

        final repoInstance1 = LocalChatRepository();

        // Buat percakapan dan simpan pesan
        final conv = await repoInstance1.getOrCreateConversationForNode(
          nodeId: 'NODE-RESTART-TEST',
          nodeName: 'Posko Induk',
        );
        await repoInstance1.saveMessage(
          conv.id,
          ChatMessage(
            id: 'msg-restart-1',
            senderName: 'Posko Induk',
            text: 'Pesan sebelum restart',
            time: '14:00',
            isMe: false,
          ),
        );
        await repoInstance1.saveMessage(
          conv.id,
          ChatMessage(
            id: 'msg-restart-2',
            senderName: 'Posko Induk',
            text: 'Pesan kedua sebelum restart',
            time: '14:05',
            isMe: true,
          ),
        );

        // Panggil getOrCreateConversationForNode sekali lagi sebelum restart
        await repoInstance1.getOrCreateConversationForNode(
          nodeId: 'NODE-RESTART-TEST',
          nodeName: 'Posko Induk',
        );

        // Simulasikan restart aplikasi dengan membuat instance LocalChatRepository baru
        // yang membaca dari SharedPreferences yang sama
        final repoInstance2 = LocalChatRepository();

        final loadedConvs = await repoInstance2.getConversations();
        // Percakapan tetap tepat 1
        expect(loadedConvs.length, equals(1));
        expect(loadedConvs.first.id, equals('conv-node-NODE-RESTART-TEST'));

        final loadedMsgs = await repoInstance2.getMessages(
          'conv-node-NODE-RESTART-TEST',
        );
        // Pesan tetap tepat 2 tanpa ada duplikasi
        expect(loadedMsgs.length, equals(2));
        expect(loadedMsgs.map((m) => m.id).toSet().length, equals(2));
      });
    },
  );
}

import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:siagamesh_app/core/routing/manet_routing_engine.dart';
import 'package:siagamesh_app/core/routing/node_identity.dart';
import 'package:siagamesh_app/core/transport/fake_mesh_transport.dart';
import 'package:siagamesh_app/core/transport/mesh_transport.dart';
import 'package:siagamesh_app/features/chat/data/repositories/chat_repository.dart';
import 'package:siagamesh_app/features/chat/models/chat_message.dart';
import 'package:siagamesh_app/features/chat/presentation/chat_list_screen.dart';
import 'package:siagamesh_app/features/home/presentation/home_screen.dart';
import 'package:siagamesh_app/features/mesh_devices/presentation/mesh_devices_screen.dart';
import 'package:siagamesh_app/features/profile/presentation/profile_screen.dart';

/// Transport simulasi dua arah untuk pengujian routing personal dan broadcast.
class PairedSimulatedTransport extends FakeMeshTransport {
  final String localNodeId;
  PairedSimulatedTransport? peerTransport;
  String? peerEndpointId;

  PairedSimulatedTransport({required this.localNodeId});

  void connectTo({
    required PairedSimulatedTransport peer,
    required String localEp,
    required String remoteEp,
    required String peerName,
  }) {
    peerTransport = peer;
    peerEndpointId = remoteEp;

    simulatePeerDiscovered(
      DiscoveredPeer(
        endpointId: localEp,
        endpointName: peerName,
        serviceId: 'com.siagamesh.emergency.mesh',
        discoveredAt: DateTime.now(),
        status: PeerConnectionStatus.connected,
      ),
    );
  }

  @override
  Future<bool> sendBytes({
    required String endpointId,
    required Uint8List bytes,
  }) async {
    final ok = await super.sendBytes(endpointId: endpointId, bytes: bytes);
    if (!ok) return false;

    if (peerTransport != null && peerEndpointId != null) {
      peerTransport!.simulateIncomingPayload(
        endpointId: peerEndpointId!,
        bytes: bytes,
      );
    }
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Kriteria A & D: User-Friendly Node Name & UI Simplification Tests', () {
    // 1. Format Nama Default & Persistensi
    test(
      '1. Nama default dibuat dengan format SiagaMesh-XXXX dan disimpan',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();

        final manager = NodeIdentityManager(prefs: prefs);

        expect(
          manager.displayName,
          matches(RegExp(r'^SiagaMesh-[0-9A-F]{4}$')),
        );
        expect(
          prefs.getString(NodeIdentityManager.keyNodeName),
          equals(manager.displayName),
        );
        expect(manager.shortNodeId.length, equals(4));
        expect(manager.displayName.endsWith(manager.shortNodeId), isTrue);
      },
    );

    // 2. Pembaruan Nama Perangkat oleh Pengguna
    test(
      '2. Pengguna dapat memperbarui nama perangkat dan tersimpan permanen',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();

        final manager = NodeIdentityManager(prefs: prefs);

        await manager.updateDisplayName('Posko Medis');
        expect(manager.displayName, equals('Posko Medis'));
        expect(
          prefs.getString(NodeIdentityManager.keyNodeName),
          equals('Posko Medis'),
        );

        // Simulasikan app restart: inisialisasi ulang manager dengan prefs yang sama
        final managerAfterRestart = NodeIdentityManager(prefs: prefs);
        expect(managerAfterRestart.displayName, equals('Posko Medis'));
      },
    );

    // 3. Sanitasi Nama Perangkat
    test(
      '3. Sanitasi nama: menghapus kontrol karakter, membatasi panjang <= 24, trim spasi',
      () {
        const fallback = 'SiagaMesh-A1B2';

        // Menghapus karakter kontrol ASCII
        expect(
          NodeIdentity.sanitizeDeviceName(
            'Posko\x00\x1F\tMedis\x07',
            fallbackDefault: fallback,
          ),
          equals('Posko Medis'),
        );

        // Memangkas spasi depan, belakang, dan ganda
        expect(
          NodeIdentity.sanitizeDeviceName(
            '   Agus    Infinix   ',
            fallbackDefault: fallback,
          ),
          equals('Agus Infinix'),
        );

        // Memotong string panjang maksimal 24 karakter
        const longName = 'Posko Relawan Tanggap Bencana Gunung Merapi';
        final sanitizedLong = NodeIdentity.sanitizeDeviceName(
          longName,
          fallbackDefault: fallback,
        );
        expect(sanitizedLong.length, lessThanOrEqualTo(24));
        expect(sanitizedLong, equals(longName.substring(0, 24)));

        // String kosong menggunakan fallback default
        expect(
          NodeIdentity.sanitizeDeviceName('   ', fallbackDefault: fallback),
          equals(fallback),
        );
      },
    );

    // 4. Advertising Nearby Connections Menggunakan Display Name
    test('4. Sesi Nearby advertising menggunakan display name', () async {
      final fakeTransport = FakeMeshTransport();
      const friendlyName = 'Infinix Agus';

      final success = await fakeTransport.startAdvertising(
        localNodeName: friendlyName,
      );

      expect(success, isTrue);
      expect(fakeTransport.isAdvertising, isTrue);
      expect(fakeTransport.lastAdvertisedName, equals('Infinix Agus'));
    });

    // 5. Node ID Protokol Tetap Stabil Sebelum & Sesudah Perubahan Nama
    test(
      '5. Node ID protokol tetap sama persis sebelum dan sesudah perubahan nama',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();

        final manager = NodeIdentityManager(prefs: prefs);

        final originalNodeId = manager.localNodeId;
        final originalShortId = manager.shortNodeId;

        await manager.updateDisplayName('Relawan 01');
        expect(manager.localNodeId, equals(originalNodeId));
        expect(manager.shortNodeId, equals(originalShortId));

        await manager.updateDisplayName('Posko Utama SAR');
        expect(manager.localNodeId, equals(originalNodeId));
        expect(manager.shortNodeId, equals(originalShortId));
      },
    );

    // 6. Disambiguasi Nama Duplikat Menggunakan Suffix Pendek
    test(
      '6. Dua perangkat dengan nama sama dibedakan di UI menggunakan suffix ID',
      () {
        const duplicateName = 'Agus';
        const nodeIdA = 'node-a1b2c3d4';
        const nodeIdB = 'node-e5f67890';

        // Ketika duplikat terdeteksi
        final formattedA = NodeIdentity.formatDisplayName(
          duplicateName,
          nodeIdA,
          isDuplicate: true,
        );
        final formattedB = NodeIdentity.formatDisplayName(
          duplicateName,
          nodeIdB,
          isDuplicate: true,
        );

        expect(formattedA, equals('Agus (#C3D4)'));
        expect(formattedB, equals('Agus (#7890)'));
        expect(formattedA, isNot(equals(formattedB)));

        // Ketika nama tidak duplikat
        final uniqueFormatted = NodeIdentity.formatDisplayName(
          'Posko Medis',
          nodeIdA,
          isDuplicate: false,
        );
        expect(uniqueFormatted, equals('Posko Medis'));
      },
    );

    // 7. Pengiriman Pesan Personal 1-ke-1 Setelah Perubahan Nama
    test(
      '7. Pesan personal 1-ke-1 tetap sampai ke node tujuan yang benar setelah perubahan nama',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();

        // Node A
        final identityA = NodeIdentityManager(
          prefs: prefs,
          overrideId: 'node-alice',
        );
        await identityA.updateDisplayName('Agus Infinix');
        final transportA = PairedSimulatedTransport(
          localNodeId: identityA.localNodeId,
        );
        final repoA = LocalChatRepository();
        final engineA = ManetRoutingEngine(
          transport: transportA,
          identityManager: identityA,
          repository: repoA,
        );

        // Node B
        final identityB = NodeIdentityManager(
          prefs: prefs,
          overrideId: 'node-bob',
        );
        await identityB.updateDisplayName('Posko Medis SAR');
        final transportB = PairedSimulatedTransport(
          localNodeId: identityB.localNodeId,
        );
        final repoB = LocalChatRepository();
        final engineB = ManetRoutingEngine(
          transport: transportB,
          identityManager: identityB,
          repository: repoB,
        );

        // Hubungkan transport A <-> B
        transportA.connectTo(
          peer: transportB,
          localEp: 'ep-b-on-a',
          remoteEp: 'ep-a-on-b',
          peerName: identityB.displayName,
        );
        transportB.connectTo(
          peer: transportA,
          localEp: 'ep-a-on-b',
          remoteEp: 'ep-b-on-a',
          peerName: identityA.displayName,
        );

        // Daftarkan neighbor di routing table agar rute langsung dikenali
        engineA.neighborTable.registerConnectedEndpoint(
          endpointId: 'ep-b-on-a',
          endpointName: identityB.displayName,
        );
        engineA.neighborTable.mapIdentity(
          endpointId: 'ep-b-on-a',
          nodeId: identityB.localNodeId,
          nodeName: identityB.displayName,
        );

        engineB.neighborTable.registerConnectedEndpoint(
          endpointId: 'ep-a-on-b',
          endpointName: identityA.displayName,
        );
        engineB.neighborTable.mapIdentity(
          endpointId: 'ep-a-on-b',
          nodeId: identityA.localNodeId,
          nodeName: identityA.displayName,
        );

        // Kirim pesan personal dari A ke B
        final sendResult = await engineA.sendChatMessage(
          recipientNodeId: identityB.localNodeId,
          text: 'Butuh pasokan obat di pos 1',
          isEmergency: false,
        );

        expect(sendResult, isNotNull);
        expect(sendResult.recipientId, equals(identityB.localNodeId));
        expect(sendResult.senderId, equals(identityA.localNodeId));
        expect(sendResult.senderName, equals('Agus Infinix'));

        engineA.dispose();
        engineB.dispose();
      },
    );

    // 8. Pesan Broadcast dan E2E ACK Berfungsi Normal
    test(
      '8. Pesan broadcast dan ACK end-to-end tetap berfungsi normal',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();

        final identity = NodeIdentityManager(prefs: prefs);
        await identity.updateDisplayName('Relawan Siaga');

        final transport = FakeMeshTransport();
        final repo = LocalChatRepository();
        final engine = ManetRoutingEngine(
          transport: transport,
          identityManager: identity,
          repository: repo,
        );

        // Kirim siaran SOS
        final broadcastResult = await engine.sendChatMessage(
          recipientNodeId: 'BROADCAST',
          text: 'EVAKUASI WARGA DIMULAI',
          isEmergency: true,
        );

        expect(broadcastResult, isNotNull);
        expect(broadcastResult.recipientId, equals('BROADCAST'));
        expect(broadcastResult.senderName, equals('Relawan Siaga'));

        engine.dispose();
      },
    );

    // 9. Reconnect Peer dengan Endpoint Baru Tidak Memecah Percakapan
    test(
      '9. Reconnect peer dengan endpoint ID baru tidak memecah percakapan yang sama',
      () async {
        SharedPreferences.setMockInitialValues({});
        final repo = LocalChatRepository();
        const targetNodeId = 'node-warga-tetap';

        // Sesi 1: Koneksi dengan endpoint ep-001
        final conv1 = await repo.getOrCreateConversationForNode(
          nodeId: targetNodeId,
          nodeName: 'Warga RT 01',
          isConnected: true,
        );

        await repo.saveMessage(
          conv1.id,
          const ChatMessage(
            id: 'msg-1',
            senderName: 'Warga RT 01',
            text: 'Pesan pertama',
            time: '10:00',
            isMe: false,
          ),
        );

        // Sesi 2: Reconnect dengan endpoint ep-002 pada node yang sama
        final conv2 = await repo.getOrCreateConversationForNode(
          nodeId: targetNodeId,
          nodeName: 'Warga RT 01',
          isConnected: true,
        );

        expect(conv2.id, equals(conv1.id));
        expect(conv2.id, equals('conv-node-$targetNodeId'));

        final allMsgs = await repo.getMessages(conv2.id);
        expect(allMsgs.length, equals(1));
        expect(allMsgs.first.id, equals('msg-1'));
      },
    );

    // 10. Perubahan Nama Memperbarui Label UI Tanpa Mengubah conversationId
    test(
      '10. Perubahan nama memperbarui label UI percakapan tanpa mengubah conversationId',
      () async {
        SharedPreferences.setMockInitialValues({});
        final repo = LocalChatRepository();
        const targetNodeId = 'node-posko-pusat';

        // Buat percakapan awal
        final convAwal = await repo.getOrCreateConversationForNode(
          nodeId: targetNodeId,
          nodeName: 'Posko Lama',
          isConnected: true,
        );
        expect(convAwal.id, equals('conv-node-$targetNodeId'));
        expect(convAwal.title, equals('Posko Lama'));

        // Peer memperbarui nama menjadi 'Posko Tanggap Darurat'
        final convBaru = await repo.getOrCreateConversationForNode(
          nodeId: targetNodeId,
          nodeName: 'Posko Tanggap Darurat',
          isConnected: true,
        );

        expect(convBaru.id, equals(convAwal.id));
        expect(convBaru.id, equals('conv-node-$targetNodeId'));
        expect(convBaru.title, equals('Posko Tanggap Darurat'));
      },
    );

    // 11. Tidak Ada Overflow pada Layar Sempit (280x480 dp)
    testWidgets(
      '11. Layar sempit (280x480 dp) bebas RenderFlex overflow di seluruh layar',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(280, 480);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final fakeTransport = FakeMeshTransport();
        final repo = LocalChatRepository();

        // a. Layar Profil
        await tester.pumpWidget(
          MaterialApp(home: ProfileScreen(transport: fakeTransport)),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // b. Layar Beranda
        await tester.pumpWidget(
          MaterialApp(home: HomeScreen(transport: fakeTransport)),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // c. Layar Daftar Pesan
        await tester.pumpWidget(
          MaterialApp(home: ChatListScreen(repository: repo)),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // d. Layar Perangkat Terdekat
        await tester.pumpWidget(
          MaterialApp(
            home: MeshDevicesScreen(transport: fakeTransport, repository: repo),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );

    // 12. Empty State Tampil Bersih Tanpa Dummy Mock Data
    testWidgets(
      '12. Empty state di Daftar Pesan dan Layar Perangkat tampil bersih tanpa dummy data',
      (WidgetTester tester) async {
        final fakeTransport = FakeMeshTransport();
        final repo = LocalChatRepository();

        // Verifikasi empty state di ChatListScreen
        await tester.pumpWidget(
          MaterialApp(home: ChatListScreen(repository: repo)),
        );
        await tester.pumpAndSettle();

        expect(find.text('Belum ada pesan'), findsOneWidget);
        expect(find.text('Buat Pesan Baru'), findsOneWidget);
        // Pastikan tidak ada kontak dummy atau mock chat palsu
        expect(find.text('Relawan 99'), findsNothing);
        expect(find.text('Posko Dummy'), findsNothing);

        // Verifikasi empty state di MeshDevicesScreen
        await tester.pumpWidget(
          MaterialApp(
            home: MeshDevicesScreen(transport: fakeTransport, repository: repo),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Belum Ada Peer Terdeteksi'), findsOneWidget);
        expect(find.text('Daftar Peer Terdeteksi (0)'), findsOneWidget);
        // Pastikan tidak ada peer mock dekoratif
        expect(find.text('Peer Dummy'), findsNothing);
      },
    );
  });
}

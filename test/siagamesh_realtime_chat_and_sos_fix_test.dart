import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:siagamesh_app/app.dart';
import 'package:siagamesh_app/core/routing/manet_routing_engine.dart';
import 'package:siagamesh_app/core/routing/message_envelope.dart';
import 'package:siagamesh_app/core/routing/node_identity.dart';
import 'package:siagamesh_app/core/routing/routing_holder.dart';
import 'package:siagamesh_app/core/transport/fake_mesh_transport.dart';
import 'package:siagamesh_app/core/transport/mesh_transport.dart';
import 'package:siagamesh_app/features/chat/data/repositories/chat_repository.dart';
import 'package:siagamesh_app/features/chat/models/chat_message.dart';
import 'package:siagamesh_app/features/chat/presentation/chat_list_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PENGUJIAN VALIDASI BUG FIX: SOS & Real-time ChatList Update (11 Kriteria)', () {
    late FakeMeshTransport fakeTransport;
    late LocalChatRepository chatRepository;
    late ManetRoutingEngine routingEngine;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      fakeTransport = FakeMeshTransport();
      chatRepository = LocalChatRepository(preferences: prefs);
      ChatRepositoryHolder.setInstance(chatRepository);

      final identityManager = NodeIdentityManager(
        prefs: prefs,
        overrideId: 'node-local-tester',
        overrideName: 'Penguji Lokal',
      );

      routingEngine = ManetRoutingEngine(
        transport: fakeTransport,
        identityManager: identityManager,
        repository: chatRepository,
      );
      ManetRoutingHolder.setInstance(routingEngine);
    });

    tearDown(() {
      routingEngine.dispose();
      chatRepository.dispose();
      fakeTransport.dispose();
    });

    testWidgets(
      '1. Pesan SOS yang dikirim muncul pada daftar Pesan tanpa menunggu balasan',
      (WidgetTester tester) async {
        // Hubungkan 1 peer agar SOS dapat langsung dikirim ke transport
        fakeTransport.simulatePeerDiscovered(
          DiscoveredPeer(
            endpointId: 'peer-alpha',
            endpointName: 'Node Relawan Alpha',
            serviceId: 'com.siagamesh.emergency.mesh',
            discoveredAt: DateTime.now(),
            status: PeerConnectionStatus.connected,
          ),
        );

        await tester.pumpWidget(
          SiagaMeshApp(transport: fakeTransport, repository: chatRepository),
        );
        await tester.pumpAndSettle();

        // 1. Kirim SOS dari Beranda
        expect(find.text('KIRIM PESAN DARURAT (SOS)'), findsOneWidget);
        await tester.tap(find.text('KIRIM PESAN DARURAT (SOS)'));
        await tester.pumpAndSettle();

        expect(find.text('SIARKAN SEKARANG'), findsOneWidget);
        await tester.tap(find.text('SIARKAN SEKARANG'));
        await tester.pumpAndSettle();

        // 2. Berpindah ke tab Pesan
        await tester.tap(find.text('Pesan'));
        await tester.pumpAndSettle();

        // 3. Verifikasi percakapan Siaran Darurat Lokal langsung tampil tanpa perlu balasan
        expect(find.text('Siaran Darurat Lokal'), findsOneWidget);
        expect(
          find.text('PANGGILAN DARURAT (SOS): Memerlukan bantuan segera!'),
          findsOneWidget,
        );
      },
    );

    test(
      '2. Pesan SOS tetap tampil jika tidak ada node lain yang membalas',
      () async {
        // Siarkan pesan SOS secara lokal
        final conv = await chatRepository.getOrCreateBroadcastConversation();
        final sosMsg = ChatMessage(
          id: 'sos-standalone-001',
          senderName: 'Anda',
          text: 'PANGGILAN DARURAT (SOS): Memerlukan bantuan segera!',
          time: '12:00',
          isMe: true,
          isEmergency: true,
          statusText: 'Disiarkan ke Transport Mesh',
        );
        await chatRepository.saveMessage(conv.id, sosMsg);

        // Pastikan percakapan dan pesan tetap ada di repository tanpa ada balasan
        final conversations = await chatRepository.getConversations();
        expect(conversations.any((c) => c.id == 'broadcast-all'), isTrue);

        final messages = await chatRepository.getMessages('broadcast-all');
        expect(messages.length, equals(1));
        expect(messages.first.id, equals('sos-standalone-001'));
        expect(messages.first.text, contains('PANGGILAN DARURAT (SOS)'));
      },
    );

    test('3. Pesan SOS berulang tidak menimpa pesan sebelumnya', () async {
      final conv = await chatRepository.getOrCreateBroadcastConversation();

      // SOS Pertama
      final sos1 = ChatMessage(
        id: 'sos-seq-001',
        senderName: 'Anda',
        text: 'PANGGILAN DARURAT (SOS): Sinyal 1',
        time: '12:01',
        isMe: true,
        isEmergency: true,
        statusText: 'Disiarkan ke Transport Mesh',
      );
      await chatRepository.saveMessage(conv.id, sos1);

      // SOS Kedua
      final sos2 = ChatMessage(
        id: 'sos-seq-002',
        senderName: 'Anda',
        text: 'PANGGILAN DARURAT (SOS): Sinyal 2',
        time: '12:02',
        isMe: true,
        isEmergency: true,
        statusText: 'Disiarkan ke Transport Mesh',
      );
      await chatRepository.saveMessage(conv.id, sos2);

      // Pastikan kedua pesan ada dan SOS 1 tidak tertimpa
      final messages = await chatRepository.getMessages(conv.id);
      expect(messages.length, equals(2));
      expect(messages[0].id, equals('sos-seq-001'));
      expect(messages[1].id, equals('sos-seq-002'));
      expect(messages[0].text, equals('PANGGILAN DARURAT (SOS): Sinyal 1'));
      expect(messages[1].text, equals('PANGGILAN DARURAT (SOS): Sinyal 2'));

      // Preview percakapan menampilkan pesan terakhir (Sinyal 2)
      final conversations = await chatRepository.getConversations();
      final bcastConv = conversations.firstWhere((c) => c.id == conv.id);
      expect(
        bcastConv.lastMessage,
        equals('PANGGILAN DARURAT (SOS): Sinyal 2'),
      );
      expect(bcastConv.time, equals('12:02'));
    });

    testWidgets(
      '4. Balasan dari node lain memperbarui preview percakapan secara langsung',
      (WidgetTester tester) async {
        // Tampilkan layar ChatListScreen
        await tester.pumpWidget(
          MaterialApp(home: ChatListScreen(repository: chatRepository)),
        );
        await tester.pumpAndSettle();

        // Awal: belum ada percakapan
        expect(find.text('Belum ada pesan'), findsOneWidget);

        // Simulasikan pesan masuk dari node lain melalui transport
        final replyEnvelope = MessageEnvelope(
          envelopeId: 'env-reply-001',
          type: MessageEnvelope.typeChat,
          senderId: 'node-relawan-sar',
          senderName: 'Tim SAR Unit 1',
          recipientId: 'BROADCAST',
          createdAt: DateTime.now().millisecondsSinceEpoch,
          ttl: 3,
          hopCount: 1,
          routeTrace: ['node-relawan-sar'],
          payload: {
            'messageId': 'msg-reply-001',
            'text': 'Tim SAR merespons, tim segera bergerak menuju titik Anda.',
            'time': '12:15',
            'isEmergency': true,
          },
        );

        // Simulasi transport menerima payload tersebut dalam asynchronous run
        await tester.runAsync(() async {
          fakeTransport.simulateIncomingPayload(
            endpointId: 'ep-sar',
            bytes: replyEnvelope.toBytes(),
          );
          await Future.delayed(const Duration(milliseconds: 100));
        });

        await tester.pumpAndSettle();

        // Preview dan judul harus langsung muncul secara real-time di UI
        expect(find.text('Siaran Darurat Lokal'), findsOneWidget);
        expect(
          find.text(
            'Tim SAR merespons, tim segera bergerak menuju titik Anda.',
          ),
          findsOneWidget,
        );
        expect(find.text('12:15'), findsOneWidget);
      },
    );

    test(
      '5. Timestamp dan urutan daftar percakapan diperbarui saat pesan baru masuk',
      () async {
        // Buat dua percakapan
        final convA = await chatRepository.getOrCreateConversationForNode(
          nodeId: 'node-alpha',
          nodeName: 'Posko Alpha',
        );
        final convB = await chatRepository.getOrCreateConversationForNode(
          nodeId: 'node-beta',
          nodeName: 'Posko Beta',
        );

        await chatRepository.saveMessage(
          convA.id,
          const ChatMessage(
            id: 'msg-a-init',
            senderName: 'Posko Alpha',
            text: 'Pesan awal Alpha',
            time: '10:00',
            isMe: false,
          ),
        );

        await chatRepository.saveMessage(
          convB.id,
          const ChatMessage(
            id: 'msg-b-init',
            senderName: 'Posko Beta',
            text: 'Pesan awal Beta',
            time: '10:05',
            isMe: false,
          ),
        );

        // Saat ini Conv B adalah yang paling baru (di posisi 0)
        var conversations = await chatRepository.getConversations();
        expect(conversations.first.id, equals(convB.id));

        // Tunggu sejenak dan kirim pesan baru ke Conv A
        await Future.delayed(const Duration(milliseconds: 10));
        await chatRepository.saveMessage(
          convA.id,
          const ChatMessage(
            id: 'msg-a-latest',
            senderName: 'Posko Alpha',
            text: 'Update darurat terbaru dari Alpha!',
            time: '10:10',
            isMe: false,
          ),
        );

        // Conv A sekarang harus otomatis pindah ke urutan paling atas (index 0)
        conversations = await chatRepository.getConversations();
        expect(conversations.first.id, equals(convA.id));
        expect(
          conversations.first.lastMessage,
          equals('Update darurat terbaru dari Alpha!'),
        );
        expect(conversations.first.time, equals('10:10'));
      },
    );

    testWidgets(
      '6. Pengguna tidak perlu membuka "Buat Pesan Baru" untuk menyegarkan daftar',
      (WidgetTester tester) async {
        // Tampilkan aplikasi dengan 3 tab
        await tester.pumpWidget(
          SiagaMeshApp(transport: fakeTransport, repository: chatRepository),
        );
        await tester.pumpAndSettle();

        // Masuk ke tab Pesan saat masih kosong
        await tester.tap(find.text('Pesan'));
        await tester.pumpAndSettle();
        expect(find.text('Belum ada pesan'), findsOneWidget);

        // Sebuah pesan masuk dari transport di background
        final incomingEnv = MessageEnvelope(
          envelopeId: 'env-bg-bcast',
          type: MessageEnvelope.typeChat,
          senderId: 'node-sar-hq',
          senderName: 'Markas SAR',
          recipientId: 'BROADCAST',
          createdAt: DateTime.now().millisecondsSinceEpoch,
          ttl: 3,
          hopCount: 0,
          routeTrace: ['node-sar-hq'],
          payload: {
            'messageId': 'msg-bg-001',
            'text': 'Evakuasi zona 1 dimulai sekarang.',
            'time': '12:30',
          },
        );

        await tester.runAsync(() async {
          fakeTransport.simulateIncomingPayload(
            endpointId: 'ep-sar-hq',
            bytes: incomingEnv.toBytes(),
          );
          await Future.delayed(const Duration(milliseconds: 100));
        });

        // Tanpa menekan tombol "Buat Pesan Baru", layar langsung terbarui
        await tester.pumpAndSettle();

        expect(find.text('Evakuasi zona 1 dimulai sekarang.'), findsOneWidget);
        expect(find.text('12:30'), findsOneWidget);
        // Tombol "Buat Pesan Baru" di empty state sudah berganti dengan item percakapan
        expect(find.text('Siaran Darurat Lokal'), findsOneWidget);
      },
    );

    testWidgets(
      '7. Pesan tetap terlihat setelah membuka lalu menutup detail percakapan',
      (WidgetTester tester) async {
        // Siapkan pesan siaran di repositori
        final conv = await chatRepository.getOrCreateBroadcastConversation();
        await chatRepository.saveMessage(
          conv.id,
          const ChatMessage(
            id: 'msg-stay-visible',
            senderName: 'Anda',
            text: 'Pesan pengujian persistensi antar-layar',
            time: '13:00',
            isMe: true,
          ),
        );

        await tester.pumpWidget(
          MaterialApp(home: ChatListScreen(repository: chatRepository)),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('Pesan pengujian persistensi antar-layar'),
          findsOneWidget,
        );

        // Buka detail percakapan
        await tester.tap(find.text('Siaran Darurat Lokal'));
        await tester.pumpAndSettle();

        expect(find.text('Detail Percakapan'), findsOneWidget);
        expect(
          find.text('Pesan pengujian persistensi antar-layar'),
          findsOneWidget,
        );

        // Kembali ke daftar percakapan
        await tester.tap(find.byIcon(Icons.arrow_back_ios_new));
        await tester.pumpAndSettle();

        // Pesan tetap tampil di daftar percakapan
        expect(
          find.text('Pesan pengujian persistensi antar-layar'),
          findsOneWidget,
        );
      },
    );

    test(
      '8. Pesan SOS dan balasan tidak terduplikasi akibat stream atau listener ganda',
      () async {
        final conv = await chatRepository.getOrCreateBroadcastConversation();
        const testMsg = ChatMessage(
          id: 'msg-dedup-check-001',
          senderName: 'Posko 1',
          text: 'Pesan uji coba deduplikasi',
          time: '13:10',
          isMe: false,
          statusText: 'Diterima',
        );

        // Simpan pesan yang sama berulang kali (simulasi double dispatch dari routing dan UI)
        await chatRepository.saveMessage(conv.id, testMsg);
        await chatRepository.saveMessage(conv.id, testMsg);
        await chatRepository.saveMessage(conv.id, testMsg);

        // Verifikasi bahwa daftar pesan di percakapan HANYA berisi 1 item
        final messages = await chatRepository.getMessages(conv.id);
        expect(messages.length, equals(1));
        expect(messages.first.id, equals('msg-dedup-check-001'));
      },
    );

    test('9. Status pesan dan E2E ACK tetap benar', () async {
      final conv = await chatRepository.getOrCreateConversationForNode(
        nodeId: 'node-target-ack',
        nodeName: 'Posko Tujuan ACK',
      );

      const initialMsg = ChatMessage(
        id: 'msg-to-be-acked',
        senderName: 'Anda',
        text: 'Mohon konfirmasi jika pesan ini sampai.',
        time: '13:20',
        isMe: true,
        statusText: 'Terkirim',
      );
      await chatRepository.saveMessage(conv.id, initialMsg);

      // Simulasikan kedatangan paket E2E ACK
      final e2eAckEnvelope = MessageEnvelope(
        envelopeId: 'ack-env-001',
        type: MessageEnvelope.typeE2eAck,
        senderId: 'node-target-ack',
        senderName: 'Posko Tujuan ACK',
        recipientId: 'node-local-tester',
        createdAt: DateTime.now().millisecondsSinceEpoch,
        ttl: 3,
        hopCount: 1,
        routeTrace: ['node-target-ack'],
        payload: {
          'ackedEnvelopeId': 'env-orig-001',
          'ackedMessageId': 'msg-to-be-acked',
          'status': 'DELIVERED_TO_DESTINATION',
        },
      );

      fakeTransport.simulateIncomingPayload(
        endpointId: 'ep-target',
        bytes: e2eAckEnvelope.toBytes(),
      );

      // Berikan waktu pemrosesan routing engine
      await Future.delayed(const Duration(milliseconds: 50));

      // Verifikasi status pesan di repository berubah menjadi E2E ACK
      final messages = await chatRepository.getMessages(conv.id);
      expect(
        messages.first.statusText,
        equals('Diterima di Perangkat Tujuan (E2E ACK)'),
      );
    });

    test(
      '10. Pesan personal satu-ke-satu tetap berfungsi dua arah dan tidak masuk broadcast',
      () async {
        // Buat percakapan personal untuk Node X
        final convPersonal = await chatRepository
            .getOrCreateConversationForNode(
              nodeId: 'node-personal-x',
              nodeName: 'Posko X',
            );
        final convBroadcast = await chatRepository
            .getOrCreateBroadcastConversation();

        // 1. Pesan keluar personal
        const outMsg = ChatMessage(
          id: 'personal-out-1',
          senderName: 'Anda',
          text: 'Pesan rahasia koordinasi ke Posko X',
          time: '13:30',
          isMe: true,
        );
        await chatRepository.saveMessage(convPersonal.id, outMsg);

        // 2. Pesan masuk personal dari Node X
        final inPersonalEnv = MessageEnvelope(
          envelopeId: 'env-in-x-1',
          type: MessageEnvelope.typeChat,
          senderId: 'node-personal-x',
          senderName: 'Posko X',
          recipientId: 'node-local-tester',
          createdAt: DateTime.now().millisecondsSinceEpoch,
          ttl: 2,
          hopCount: 0,
          routeTrace: ['node-personal-x'],
          payload: {
            'messageId': 'personal-in-1',
            'text': 'Balasan langsung dari Posko X diterima!',
            'time': '13:32',
          },
        );

        fakeTransport.simulateIncomingPayload(
          endpointId: 'ep-x',
          bytes: inPersonalEnv.toBytes(),
        );

        await Future.delayed(const Duration(milliseconds: 50));

        // Verifikasi bahwa pesan personal masuk ke percakapan personal
        final personalMessages = await chatRepository.getMessages(
          convPersonal.id,
        );
        expect(personalMessages.any((m) => m.id == 'personal-in-1'), isTrue);

        // Verifikasi bahwa pesan personal TIDAK bocor ke siaran darurat broadcast
        final broadcastMessages = await chatRepository.getMessages(
          convBroadcast.id,
        );
        expect(broadcastMessages.any((m) => m.id == 'personal-in-1'), isFalse);
        expect(broadcastMessages.any((m) => m.id == 'personal-out-1'), isFalse);
      },
    );

    test(
      '11. Data repository dan UI tetap konsisten setelah aplikasi dimulai ulang',
      () async {
        final prefs = await SharedPreferences.getInstance();

        // Tahap 1: Simpan pesan di instance repository pertama
        final repo1 = LocalChatRepository(preferences: prefs);
        final bcast1 = await repo1.getOrCreateBroadcastConversation();
        await repo1.saveMessage(
          bcast1.id,
          const ChatMessage(
            id: 'msg-restart-test-1',
            senderName: 'Anda',
            text: 'Pesan SOS sebelum restart aplikasi',
            time: '14:00',
            isMe: true,
            isEmergency: true,
          ),
        );

        final conv1 = await repo1.getOrCreateConversationForNode(
          nodeId: 'node-restart-peer',
          nodeName: 'Posko Tetangga',
        );
        await repo1.saveMessage(
          conv1.id,
          const ChatMessage(
            id: 'msg-restart-test-2',
            senderName: 'Anda',
            text: 'Pesan koordinasi personal sebelum restart',
            time: '14:05',
            isMe: true,
          ),
        );

        // Tahap 2: Buka instance repository kedua (simulasi restart aplikasi)
        final repo2 = LocalChatRepository(preferences: prefs);
        final restoredConversations = await repo2.getConversations();
        expect(restoredConversations.length, equals(2));

        final restoredBcastMsgs = await repo2.getMessages('broadcast-all');
        expect(restoredBcastMsgs.length, equals(1));
        expect(restoredBcastMsgs.first.id, equals('msg-restart-test-1'));

        final restoredPersonalMsgs = await repo2.getMessages(conv1.id);
        expect(restoredPersonalMsgs.length, equals(1));
        expect(restoredPersonalMsgs.first.id, equals('msg-restart-test-2'));

        // Tahap 3: Simpan pesan tambahan setelah restart, pastikan pesan lama TIDAK terhapus/tertimpa
        await repo2.saveMessage(
          bcast1.id,
          const ChatMessage(
            id: 'msg-restart-test-3',
            senderName: 'Anda',
            text: 'Pesan SOS kedua setelah restart aplikasi',
            time: '14:10',
            isMe: true,
            isEmergency: true,
          ),
        );

        final updatedBcastMsgs = await repo2.getMessages('broadcast-all');
        expect(updatedBcastMsgs.length, equals(2));
        expect(updatedBcastMsgs[0].id, equals('msg-restart-test-1'));
        expect(updatedBcastMsgs[1].id, equals('msg-restart-test-3'));
      },
    );
  });
}

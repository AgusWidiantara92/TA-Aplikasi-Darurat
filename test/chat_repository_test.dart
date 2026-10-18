import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:siagamesh_app/features/chat/data/repositories/chat_repository.dart';
import 'package:siagamesh_app/features/chat/models/chat_message.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('STAGE 4B — Pengujian ChatRepository & Penyimpanan Lokal', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test(
      '1. Percakapan dan pesan dapat disimpan lalu dimuat kembali',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final repository = LocalChatRepository(preferences: prefs);

        // Pastikan percakapan awal termuat
        final initialConversations = await repository.getConversations();
        expect(initialConversations.isNotEmpty, isTrue);
        expect(initialConversations.any((c) => c.id == 'conv-1'), isTrue);

        // Simpan pesan baru ke conv-1
        const testMessage = ChatMessage(
          id: 'msg-test-001',
          senderName: 'Anda',
          text: 'Laporan kondisi lapangan aman.',
          time: '11:15',
          isMe: true,
          statusText: 'Tersimpan Lokal (Simulasi)',
        );
        await repository.saveMessage('conv-1', testMessage);

        // Muat kembali pesan dari repository
        final messages = await repository.getMessages('conv-1');
        expect(messages.any((m) => m.id == 'msg-test-001'), isTrue);
        expect(
          messages.firstWhere((m) => m.id == 'msg-test-001').text,
          'Laporan kondisi lapangan aman.',
        );

        // Pastikan ringkasan percakapan diperbarui
        final updatedConversations = await repository.getConversations();
        final conv1 = updatedConversations.firstWhere((c) => c.id == 'conv-1');
        expect(conv1.lastMessage, 'Laporan kondisi lapangan aman.');
        expect(conv1.time, '11:15');
      },
    );

    test(
      '2. Pesan baru tetap ada setelah repository dibuat ulang (persistensi)',
      () async {
        final prefs = await SharedPreferences.getInstance();

        // Instance pertama repository
        final repoInstance1 = LocalChatRepository(preferences: prefs);
        const testMessage = ChatMessage(
          id: 'msg-persistent-999',
          senderName: 'Anda',
          text: 'Pesan pengujian persistensi antar-restart.',
          time: '12:00',
          isMe: true,
          statusText: 'Tersimpan Lokal (Simulasi)',
        );
        await repoInstance1.saveMessage('conv-1', testMessage);

        // Buat instance kedua (simulasi buka ulang aplikasi) menggunakan SharedPreferences yang sama
        final repoInstance2 = LocalChatRepository(preferences: prefs);
        final messagesAfterRestart = await repoInstance2.getMessages('conv-1');

        expect(
          messagesAfterRestart.any((m) => m.id == 'msg-persistent-999'),
          isTrue,
        );
        final found = messagesAfterRestart.firstWhere(
          (m) => m.id == 'msg-persistent-999',
        );
        expect(found.text, 'Pesan pengujian persistensi antar-restart.');
      },
    );

    test(
      '3. Dua node berbeda tidak saling mencampur riwayat percakapan',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final repository = LocalChatRepository(preferences: prefs);

        // Buat/ambil percakapan untuk Node A dan Node B
        final convNodeA = await repository.getOrCreateConversationForNode(
          nodeId: 'node-alpha',
          nodeName: 'Posko Alpha',
        );
        final convNodeB = await repository.getOrCreateConversationForNode(
          nodeId: 'node-beta',
          nodeName: 'Posko Beta',
        );

        // Pastikan ID percakapan berbeda
        expect(convNodeA.id, isNot(equals(convNodeB.id)));

        // Simpan pesan ke Node A
        const msgForA = ChatMessage(
          id: 'msg-a1',
          senderName: 'Anda',
          text: 'Instruksi untuk Posko Alpha',
          time: '13:00',
          isMe: true,
        );
        await repository.saveMessage(convNodeA.id, msgForA);

        // Simpan pesan ke Node B
        const msgForB = ChatMessage(
          id: 'msg-b1',
          senderName: 'Anda',
          text: 'Instruksi untuk Posko Beta',
          time: '13:05',
          isMe: true,
        );
        await repository.saveMessage(convNodeB.id, msgForB);

        // Verifikasi riwayat Node A
        final messagesA = await repository.getMessages(convNodeA.id);
        expect(
          messagesA.any((m) => m.text == 'Instruksi untuk Posko Alpha'),
          isTrue,
        );
        expect(
          messagesA.any((m) => m.text == 'Instruksi untuk Posko Beta'),
          isFalse,
        );

        // Verifikasi riwayat Node B
        final messagesB = await repository.getMessages(convNodeB.id);
        expect(
          messagesB.any((m) => m.text == 'Instruksi untuk Posko Beta'),
          isTrue,
        );
        expect(
          messagesB.any((m) => m.text == 'Instruksi untuk Posko Alpha'),
          isFalse,
        );
      },
    );

    test(
      '4. Percakapan baru tidak dibuat berulang kali untuk node yang sama',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final repository = LocalChatRepository(preferences: prefs);

        // Panggilan pertama
        final firstCall = await repository.getOrCreateConversationForNode(
          nodeId: 'node-unique-123',
          nodeName: 'Relawan Unit 123',
        );

        // Panggilan kedua untuk node yang sama
        final secondCall = await repository.getOrCreateConversationForNode(
          nodeId: 'node-unique-123',
          nodeName: 'Relawan Unit 123 Diperbarui',
        );

        // Harus mengembalikan entitas percakapan yang sama
        expect(firstCall.id, equals(secondCall.id));
        expect(firstCall.peerNodeId, equals('node-unique-123'));

        // Pastikan tidak ada duplikasi pada daftar percakapan
        final allConversations = await repository.getConversations();
        final matchedCount = allConversations
            .where(
              (c) => c.peerNodeId == 'node-unique-123' || c.id == firstCall.id,
            )
            .length;
        expect(matchedCount, equals(1));
      },
    );

    test(
      '5. Data lokal kosong atau rusak (corrupted JSON) ditangani dengan aman tanpa crash',
      () async {
        // Siapkan SharedPreferences dengan format data JSON rusak
        SharedPreferences.setMockInitialValues({
          LocalChatRepository.keyConversations:
              '{{INVALID_JSON_CORRUPTED_STRING%%',
          '${LocalChatRepository.keyMessagesPrefix}conv-1':
              '[[CORRUPTED_MESSAGES_ARRAY??',
        });

        final prefs = await SharedPreferences.getInstance();
        final repository = LocalChatRepository(preferences: prefs);

        // Pengambilan percakapan tidak boleh crash, harus fallback ke seed bawaan
        final conversations = await repository.getConversations();
        expect(conversations.isNotEmpty, isTrue);
        expect(conversations.any((c) => c.id == 'conv-1'), isTrue);

        // Pengambilan pesan conv-1 tidak boleh crash, harus fallback ke pesan awal conv-1
        final messages = await repository.getMessages('conv-1');
        expect(messages.isNotEmpty, isTrue);

        // Pengambilan ID percakapan yang tidak ada harus mengembalikan list kosong dengan aman
        final emptyMessages = await repository.getMessages('non-existent-conv');
        expect(emptyMessages.isEmpty, isTrue);
      },
    );
  });
}

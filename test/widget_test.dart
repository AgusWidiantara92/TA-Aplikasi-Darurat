import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:siagamesh_app/app.dart';
import 'package:siagamesh_app/core/routing/routing_holder.dart';
import 'package:siagamesh_app/core/transport/fake_mesh_transport.dart';
import 'package:siagamesh_app/core/transport/mesh_transport.dart';
import 'package:siagamesh_app/core/transport/transport_holder.dart';
import 'package:siagamesh_app/features/chat/data/repositories/chat_repository.dart';
import 'package:siagamesh_app/features/chat/models/chat_message.dart';

void main() {
  late FakeMeshTransport fakeTransport;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final repo = LocalChatRepository();
    await repo.clearAllData();
    ChatRepositoryHolder.setInstance(repo);
    fakeTransport = FakeMeshTransport();
    MeshTransportHolder.setInstance(fakeTransport);
    ManetRoutingHolder.reset();
  });

  testWidgets('SiagaMesh initial smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(SiagaMeshApp(transport: fakeTransport));

    expect(find.text('SiagaMesh'), findsWidgets);
    expect(find.text('KIRIM PESAN DARURAT (SOS)'), findsOneWidget);
    expect(find.text('KONEKTIVITAS MESH'), findsOneWidget);
    expect(find.text('INTERNET TIDAK DIBUTUHKAN'), findsOneWidget);
    expect(find.text('MODE SIAGA (STANDBY)'), findsOneWidget);
    expect(find.text('0 Perangkat Terdeteksi'), findsOneWidget);
  });

  testWidgets('Verifikasi akses navigasi seluruh 4 layar', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(SiagaMeshApp(transport: fakeTransport));

    // 1. Layar Beranda (default)
    expect(find.text('KIRIM PESAN DARURAT (SOS)'), findsOneWidget);
    expect(find.text('KONEKTIVITAS MESH'), findsOneWidget);

    // 2. Navigasi ke Layar Pesan (Tab Pesan)
    await tester.tap(find.text('Pesan'));
    await tester.pumpAndSettle();

    expect(find.text('Jaringan Komunikasi Darurat Offline'), findsOneWidget);
    expect(find.text('Belum ada pesan'), findsOneWidget);
    expect(find.text('Buat Pesan Baru'), findsOneWidget);

    // 3. Navigasi ke Layar Detail Percakapan (Klik Buat Pesan Baru)
    await tester.tap(find.text('Buat Pesan Baru'));
    await tester.pumpAndSettle();

    expect(find.text('Detail Percakapan'), findsOneWidget);
    expect(find.text('Siaran Darurat Lokal'), findsOneWidget);

    // Kembali ke Layar Daftar Pesan
    await tester.tap(find.byIcon(Icons.arrow_back_ios_new));
    await tester.pumpAndSettle();

    // 4. Navigasi ke Layar Perangkat (Tab Perangkat)
    await tester.tap(find.text('Perangkat'));
    await tester.pumpAndSettle();

    expect(find.text('Radar Sinyal Peer-to-Peer'), findsOneWidget);
    expect(find.text('MODE SIAGA • 0 PEER TERDETEKSI'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(find.text('Belum Ada Peer Terdeteksi'), findsOneWidget);
  });

  testWidgets('Verifikasi interaksi tombol SOS saat belum ada peer terhubung', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(SiagaMeshApp(transport: fakeTransport));

    // Tekan tombol SOS saat belum ada peer
    await tester.tap(find.text('KIRIM PESAN DARURAT (SOS)'));
    await tester.pumpAndSettle();

    // Verifikasi dialog peringatan muncul
    expect(find.text('Peringatan Darurat (SOS)'), findsOneWidget);
    expect(find.text('Simpan ke Antrean Siaran'), findsOneWidget);

    // Tekan Simpan ke Antrean Siaran
    await tester.tap(find.text('Simpan ke Antrean Siaran'));
    await tester.pumpAndSettle();

    // Verifikasi SnackBar muncul
    expect(
      find.text(
        'Pesan darurat disimpan di antrean transmisi lokal. Akan disiarkan otomatis saat peer terhubung.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Verifikasi interaksi tombol SOS saat peer terhubung', (
    WidgetTester tester,
  ) async {
    // Simulasikan peer fisik terhubung
    fakeTransport.simulatePeerDiscovered(
      DiscoveredPeer(
        endpointId: 'peer-alpha',
        endpointName: 'Node Relawan Alpha',
        serviceId: 'com.siagamesh.emergency.mesh',
        discoveredAt: DateTime.now(),
        status: PeerConnectionStatus.connected,
      ),
    );

    await tester.pumpWidget(SiagaMeshApp(transport: fakeTransport));
    await tester.pumpAndSettle();

    // Pastikan status beranda menunjukkan jaringan terhubung
    expect(find.text('JARINGAN TERHUBUNG'), findsOneWidget);

    // Tekan tombol SOS
    await tester.tap(find.text('KIRIM PESAN DARURAT (SOS)'));
    await tester.pumpAndSettle();

    // Verifikasi dialog konfirmasi siaran
    expect(find.text('Konfirmasi Siaran Darurat'), findsOneWidget);
    expect(find.text('SIARKAN SEKARANG'), findsOneWidget);

    // Tekan SIARKAN SEKARANG
    await tester.tap(find.text('SIARKAN SEKARANG'));
    await tester.pumpAndSettle();

    // Verifikasi SnackBar siaran terkirim
    expect(
      find.text(
        'Sinyal SOS darurat berhasil diserahkan ke stack transport mesh (1 peer).',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Verifikasi filter dan pencarian di Daftar Pesan', (
    WidgetTester tester,
  ) async {
    final repo = ChatRepositoryHolder.instance;
    final conv1 = await repo.getOrCreateConversationForNode(
      nodeId: 'node-alpha-001',
      nodeName: 'Posko Alpha',
      isEmergency: true,
      isConnected: true,
    );
    final conv2 = await repo.getOrCreateConversationForNode(
      nodeId: 'node-beta-002',
      nodeName: 'Relawan Beta',
      isEmergency: false,
      isConnected: false,
    );
    await repo.saveMessage(
      conv1.id,
      const ChatMessage(
        id: 'msg-1',
        senderName: 'Posko Alpha',
        text: 'Ambulans siap siaga di lokasi.',
        time: '10:00',
        isMe: false,
        isEmergency: true,
      ),
    );
    await repo.saveMessage(
      conv2.id,
      const ChatMessage(
        id: 'msg-2',
        senderName: 'Relawan Beta',
        text: 'Logistik sudah didistribusikan.',
        time: '10:05',
        isMe: false,
      ),
    );

    await tester.pumpWidget(SiagaMeshApp(transport: fakeTransport));

    // Buka Tab Pesan
    await tester.tap(find.text('Pesan'));
    await tester.pumpAndSettle();

    // Filter Semua: cek item
    expect(find.text('Posko Alpha'), findsOneWidget);
    expect(find.text('Relawan Beta'), findsOneWidget);

    // Filter Pesan Darurat
    await tester.tap(find.text('Pesan Darurat'));
    await tester.pumpAndSettle();

    expect(find.text('Posko Alpha'), findsOneWidget);
    expect(find.text('Relawan Beta'), findsNothing);

    // Filter Node Terhubung
    await tester.tap(find.text('Node Terhubung'));
    await tester.pumpAndSettle();

    expect(find.text('Posko Alpha'), findsOneWidget);
    expect(find.text('Relawan Beta'), findsNothing);

    // Kembalikan ke Semua
    await tester.tap(find.text('Semua'));
    await tester.pumpAndSettle();

    // Uji Pencarian
    await tester.enterText(find.byType(TextField), 'Alpha');
    await tester.pumpAndSettle();

    expect(find.text('Posko Alpha'), findsOneWidget);
    expect(find.text('Relawan Beta'), findsNothing);

    // Pencarian tidak ditemukan
    await tester.enterText(find.byType(TextField), 'xyz-tidak-ada');
    await tester.pumpAndSettle();

    expect(find.text('Tidak ada percakapan ditemukan'), findsOneWidget);
  });

  testWidgets(
    'Verifikasi pengiriman pesan dan tombol respons cepat di Detail Percakapan',
    (WidgetTester tester) async {
      final repo = ChatRepositoryHolder.instance;
      await repo.getOrCreateConversationForNode(
        nodeId: 'node-sar-unit',
        nodeName: 'Posko SAR Lapangan',
      );

      await tester.pumpWidget(SiagaMeshApp(transport: fakeTransport));

      // Buka Pesan -> Posko SAR Lapangan
      await tester.tap(find.text('Pesan'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Posko SAR Lapangan'));
      await tester.pumpAndSettle();

      // Ketik pesan manual
      await tester.enterText(
        find.byType(TextField),
        'Laporan: Posisi aman terkendali',
      );
      await tester.tap(find.text('Kirim'));
      await tester.pumpAndSettle();

      expect(find.text('Laporan: Posisi aman terkendali'), findsOneWidget);

      // Respons Cepat: Kondisi Aman
      await tester.tap(find.text('Kondisi Aman'));
      await tester.pumpAndSettle();

      expect(
        find.text('Kondisi saat ini aman dan terkendali.'),
        findsOneWidget,
      );

      // Respons Cepat: Kirim Lokasi
      await tester.tap(find.text('Kirim Lokasi'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Titik Kumpul Evakuasi'), findsOneWidget);
    },
  );

  testWidgets(
    'Verifikasi tombol Buat Pesan Baru membuka halaman siaran kosong',
    (WidgetTester tester) async {
      await tester.pumpWidget(SiagaMeshApp(transport: fakeTransport));

      await tester.tap(find.text('Pesan'));
      await tester.pumpAndSettle();

      // Pada empty state, tombol Buat Pesan Baru langsung terlihat
      expect(find.text('Belum ada pesan'), findsOneWidget);
      await tester.tap(find.text('Buat Pesan Baru'));
      await tester.pumpAndSettle();

      // Verifikasi berada di halaman siaran baru
      expect(find.text('Siaran Darurat Lokal'), findsOneWidget);
      expect(find.text('Belum ada pesan siaran'), findsOneWidget);

      // Kirim pesan pertama
      await tester.enterText(find.byType(TextField), 'Siaran darurat uji coba');
      await tester.tap(find.text('Kirim'));
      await tester.pumpAndSettle();

      expect(find.text('Siaran darurat uji coba'), findsOneWidget);
      expect(find.text('Belum ada pesan siaran'), findsNothing);
    },
  );

  testWidgets('Verifikasi interaksi pada Layar Perangkat dengan peer fisik riil', (
    WidgetTester tester,
  ) async {
    // Simulasikan 2 peer fisik
    fakeTransport.simulatePeerDiscovered(
      DiscoveredPeer(
        endpointId: 'node-sar-1',
        endpointName: 'Posko Relawan SAR',
        serviceId: 'com.siagamesh.emergency.mesh',
        discoveredAt: DateTime.now(),
        status: PeerConnectionStatus.connected,
      ),
    );
    fakeTransport.simulatePeerDiscovered(
      DiscoveredPeer(
        endpointId: 'node-warga-2',
        endpointName: 'Warga Blok B',
        serviceId: 'com.siagamesh.emergency.mesh',
        discoveredAt: DateTime.now(),
        status: PeerConnectionStatus.disconnected,
      ),
    );

    await tester.pumpWidget(SiagaMeshApp(transport: fakeTransport));

    await tester.tap(find.text('Perangkat'));
    await tester.pumpAndSettle();

    // Verifikasi radar sinyal peer-to-peer
    expect(find.text('Radar Sinyal Peer-to-Peer'), findsOneWidget);

    // Drag ke atas untuk melihat daftar peer
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();

    expect(find.text('Daftar Peer Terdeteksi (2)'), findsOneWidget);

    // Klik tombol Kirim Pesan pada peer terhubung
    expect(find.text('Kirim Pesan'), findsOneWidget);
    await tester.tap(find.text('Kirim Pesan'));
    await tester.pumpAndSettle();

    expect(find.text('Detail Percakapan'), findsOneWidget);
    expect(find.text('Posko Relawan SAR'), findsOneWidget);

    // Kembali ke Layar Perangkat
    await tester.tap(find.byIcon(Icons.arrow_back_ios_new));
    await tester.pumpAndSettle();

    // Drag sedikit ke atas agar tombol Hubungkan terlihat bebas dari bottom nav
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();

    // Peer kedua (Warga Blok B) yang belum terhubung memiliki tombol Hubungkan
    expect(find.text('Hubungkan'), findsOneWidget);
    await tester.tap(find.text('Hubungkan'));
    await tester.pumpAndSettle();

    // Memverifikasi request koneksi riil pada fake transport
    expect(
      fakeTransport.currentPeers
          .firstWhere((p) => p.endpointId == 'node-warga-2')
          .status,
      PeerConnectionStatus.connecting,
    );
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:siagamesh_app/app.dart';

void main() {
  testWidgets('SiagaMesh initial smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const SiagaMeshApp());

    expect(find.text('SiagaMesh'), findsWidgets);
    expect(find.text('KIRIM PESAN DARURAT (SOS)'), findsOneWidget);
    expect(find.text('KONEKTIVITAS MESH'), findsOneWidget);
    expect(find.text('INTERNET TIDAK DIBUTUHKAN'), findsOneWidget);
  });

  testWidgets('Verifikasi akses navigasi seluruh 4 layar', (WidgetTester tester) async {
    await tester.pumpWidget(const SiagaMeshApp());

    // 1. Layar Beranda (default)
    expect(find.text('KIRIM PESAN DARURAT (SOS)'), findsOneWidget);
    expect(find.text('KONEKTIVITAS MESH'), findsOneWidget);

    // 2. Navigasi ke Layar Pesan (Tab Pesan)
    await tester.tap(find.text('Pesan'));
    await tester.pumpAndSettle();

    expect(find.text('Jaringan Darurat Offline (Demo UI)'), findsOneWidget);
    expect(find.text('Posko Medis Darurat'), findsOneWidget);

    // 3. Navigasi ke Layar Detail Percakapan (Klik item percakapan)
    await tester.tap(find.text('Posko Medis Darurat'));
    await tester.pumpAndSettle();

    expect(find.text('Detail Percakapan'), findsOneWidget);
    expect(find.text('Data Telemetri Lokasi'), findsOneWidget);

    // Kembali ke Layar Daftar Pesan
    await tester.tap(find.byIcon(Icons.arrow_back_ios_new));
    await tester.pumpAndSettle();

    // 4. Navigasi ke Layar Perangkat (Tab Perangkat)
    await tester.tap(find.text('Perangkat'));
    await tester.pumpAndSettle();

    expect(find.text('Radar Sinyal Peer-to-Peer'), findsOneWidget);
    expect(find.text('PENCARIAN AKTIF • 5 NODE TERDETEKSI (SIMULASI)'), findsOneWidget);
  });

  testWidgets('Verifikasi interaksi tombol SOS dan dialog konfirmasi', (WidgetTester tester) async {
    await tester.pumpWidget(const SiagaMeshApp());

    // Tekan tombol SOS
    await tester.tap(find.text('KIRIM PESAN DARURAT (SOS)'));
    await tester.pumpAndSettle();

    // Verifikasi dialog muncul
    expect(find.text('Simulasi SOS'), findsOneWidget);
    expect(find.text('Uji Simulasi SOS'), findsOneWidget);

    // Tekan Uji Simulasi SOS
    await tester.tap(find.text('Uji Simulasi SOS'));
    await tester.pumpAndSettle();

    // Verifikasi SnackBar muncul
    expect(find.text('Peringatan SOS tersimpan di memori lokal (Mode Demonstrasi).'), findsOneWidget);
  });

  testWidgets('Verifikasi filter dan pencarian di Daftar Pesan', (WidgetTester tester) async {
    await tester.pumpWidget(const SiagaMeshApp());

    // Buka Tab Pesan
    await tester.tap(find.text('Pesan'));
    await tester.pumpAndSettle();

    // Filter Semua (4): cek item awal
    expect(find.text('Posko Medis Darurat'), findsOneWidget);
    expect(find.text('Tim SAR Wilayah II'), findsOneWidget);
    expect(find.text('Ahmed Fauzi'), findsOneWidget);

    // Drag list view ke atas untuk melihat item ke-4
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(find.text('Relawan Dapur Umum'), findsOneWidget);

    // Kembalikan scroll ke atas
    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pumpAndSettle();

    // Filter Pesan Darurat (1)
    await tester.tap(find.text('Pesan Darurat (1)'));
    await tester.pumpAndSettle();

    expect(find.text('Posko Medis Darurat'), findsOneWidget);
    expect(find.text('Tim SAR Wilayah II'), findsNothing);
    expect(find.text('Ahmed Fauzi'), findsNothing);

    // Filter Node Terhubung (3 node langsung)
    await tester.tap(find.text('Node Terhubung'));
    await tester.pumpAndSettle();

    expect(find.text('Posko Medis Darurat'), findsOneWidget);
    expect(find.text('Tim SAR Wilayah II'), findsOneWidget);
    expect(find.text('Ahmed Fauzi'), findsOneWidget);
    expect(find.text('Relawan Dapur Umum'), findsNothing);

    // Kembalikan ke Semua (4)
    await tester.tap(find.text('Semua (4)'));
    await tester.pumpAndSettle();

    // Uji Pencarian
    await tester.enterText(find.byType(TextField), 'Ahmed');
    await tester.pumpAndSettle();

    expect(find.text('Ahmed Fauzi'), findsOneWidget);
    expect(find.text('Posko Medis Darurat'), findsNothing);

    // Pencarian tidak ditemukan
    await tester.enterText(find.byType(TextField), 'xyz-tidak-ada');
    await tester.pumpAndSettle();

    expect(find.text('Tidak ada percakapan ditemukan'), findsOneWidget);
  });

  testWidgets('Verifikasi pengiriman pesan dan tombol respons cepat di Detail Percakapan', (WidgetTester tester) async {
    await tester.pumpWidget(const SiagaMeshApp());

    // Buka Pesan -> Posko Medis Darurat
    await tester.tap(find.text('Pesan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Posko Medis Darurat'));
    await tester.pumpAndSettle();

    // Ketik pesan simulasi manual
    await tester.enterText(find.byType(TextField), 'Laporan: Posisi aman terkendali');
    await tester.tap(find.text('Kirim'));
    await tester.pumpAndSettle();

    expect(find.text('Laporan: Posisi aman terkendali'), findsOneWidget);

    // Respons Cepat: Kondisi Aman
    await tester.tap(find.text('Kondisi Aman'));
    await tester.pumpAndSettle();

    expect(find.text('Kondisi saat ini aman dan terkendali.'), findsOneWidget);

    // Respons Cepat: Kirim Lokasi
    await tester.tap(find.text('Kirim Lokasi'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Titik Kumpul Evakuasi'), findsOneWidget);
  });

  testWidgets('Verifikasi tombol Buat Pesan Baru membuka halaman siaran kosong', (WidgetTester tester) async {
    await tester.pumpWidget(const SiagaMeshApp());

    await tester.tap(find.text('Pesan'));
    await tester.pumpAndSettle();

    // Drag list view ke atas untuk memunculkan tombol Buat Pesan Baru
    await tester.drag(find.byType(ListView), const Offset(0, -350));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Buat Pesan Baru'));
    await tester.pumpAndSettle();

    // Verifikasi berada di halaman siaran baru
    expect(find.text('Siaran Darurat Lokal (Simulasi)'), findsOneWidget);
    expect(find.text('Belum ada pesan siaran'), findsOneWidget);

    // Kirim pesan pertama
    await tester.enterText(find.byType(TextField), 'Siaran darurat uji coba');
    await tester.tap(find.text('Kirim'));
    await tester.pumpAndSettle();

    expect(find.text('Siaran darurat uji coba'), findsOneWidget);
    expect(find.text('Belum ada pesan siaran'), findsNothing);
  });

  testWidgets('Verifikasi interaksi pada Layar Perangkat', (WidgetTester tester) async {
    await tester.pumpWidget(const SiagaMeshApp());

    await tester.tap(find.text('Perangkat'));
    await tester.pumpAndSettle();

    // Drag sedikit ke atas untuk melihat node Posko Relawan Utama
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();

    // Klik tombol Kirim Pesan pada node Posko Relawan Utama
    expect(find.text('Kirim Pesan'), findsWidgets);
    await tester.tap(find.text('Kirim Pesan').first);
    await tester.pumpAndSettle();

    expect(find.text('Detail Percakapan'), findsOneWidget);
    expect(find.text('Posko Relawan Utama'), findsOneWidget);

    // Kembali ke Layar Perangkat
    await tester.tap(find.byIcon(Icons.arrow_back_ios_new));
    await tester.pumpAndSettle();

    // Drag lebih lanjut ke bawah untuk melihat node Galaxy A54
    await tester.drag(find.byType(ListView), const Offset(0, -250));
    await tester.pumpAndSettle();

    expect(find.text('Hubungkan'), findsOneWidget);
    await tester.tap(find.text('Hubungkan'));
    await tester.pumpAndSettle();

    expect(find.text('Simulasi jabat tangan dengan Galaxy A54...'), findsOneWidget);
  });
}

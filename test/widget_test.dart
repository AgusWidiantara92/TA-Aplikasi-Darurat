import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:siagamesh_app/app.dart';

void main() {
  testWidgets('SiagaMesh initial smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const SiagaMeshApp());

    expect(find.text('SiagaMesh'), findsWidgets);
    expect(find.text('KIRIM PESAN DARURAT (SOS)'), findsOneWidget);
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
    expect(find.text('PEMINDAIAN AKTIF • 4 NODE TERDETEKSI (SIMULASI)'), findsOneWidget);
  });
}

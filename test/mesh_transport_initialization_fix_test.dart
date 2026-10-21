import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:siagamesh_app/core/routing/routing_holder.dart';
import 'package:siagamesh_app/core/transport/connectivity_prerequisite_service.dart';
import 'package:siagamesh_app/core/transport/fake_mesh_transport.dart';
import 'package:siagamesh_app/core/transport/mesh_transport.dart';
import 'package:siagamesh_app/core/transport/transport_diagnostics.dart';
import 'package:siagamesh_app/core/transport/transport_holder.dart';
import 'package:siagamesh_app/features/chat/data/repositories/chat_repository.dart';
import 'package:siagamesh_app/features/mesh_devices/presentation/mesh_devices_screen.dart';

void main() {
  group('BUG FIX SiagaMesh — Audit & Validasi Inisialisasi Transport Mesh', () {
    late FakeMeshTransport fakeTransport;
    late FakeConnectivityPrerequisiteService fakePrereq;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final repo = LocalChatRepository();
      await repo.clearAllData();
      ChatRepositoryHolder.setInstance(repo);

      fakeTransport = FakeMeshTransport();
      MeshTransportHolder.setInstance(fakeTransport);
      ManetRoutingHolder.reset();

      fakePrereq = FakeConnectivityPrerequisiteService(
        currentResult: const PrerequisiteCheckResult(
          status: PrerequisiteStatus.ready,
          permissionsGranted: true,
          bluetoothEnabled: true,
        ),
      );
      ConnectivityPrerequisiteHolder.setInstance(fakePrereq);
    });

    tearDown(() {
      fakeTransport.dispose();
      ConnectivityPrerequisiteHolder.reset();
    });

    Future<void> pumpDevicesScreen(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: MeshDevicesScreen(
            transport: fakeTransport,
            prerequisiteService: fakePrereq,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('1. Izin tersedia: pemindaian dapat langsung dimulai', (
      WidgetTester tester,
    ) async {
      await pumpDevicesScreen(tester);

      // Klik tombol Mulai Pindai pada kontrol radio
      await tester.tap(find.text('Mulai Pindai'));
      await tester.pumpAndSettle();

      expect(fakeTransport.isDiscovering, isTrue);
      expect(find.text('Pindai: AKTIF'), findsOneWidget);
      expect(find.text('MEMINDAI • 0 PEER TERDETEKSI'), findsOneWidget);
      // Tidak boleh memunculkan dialog error
      expect(find.text('Gagal Memulai Koneksi'), findsNothing);
      expect(find.text('Inisialisasi Mesh Gagal'), findsNothing);
    });

    testWidgets(
      '2. Izin ditolak: menampilkan dialog "Izin Diperlukan" dan tombol Buka Pengaturan',
      (WidgetTester tester) async {
        fakePrereq.currentResult = const PrerequisiteCheckResult(
          status: PrerequisiteStatus.permissionRequired,
          permissionsGranted: false,
          missingPermissions: ['android.permission.BLUETOOTH_SCAN'],
        );
        fakePrereq.requestPermissionsReturnValue = false;

        await pumpDevicesScreen(tester);

        await tester.tap(find.text('Mulai Pindai'));
        await tester.pumpAndSettle();

        expect(find.text('Izin Diperlukan'), findsOneWidget);
        expect(find.text('Buka Pengaturan'), findsOneWidget);
        expect(fakeTransport.isDiscovering, isFalse);
      },
    );

    testWidgets(
      '3. Bluetooth tidak aktif: menampilkan dialog "Bluetooth Belum Aktif"',
      (WidgetTester tester) async {
        fakePrereq.currentResult = const PrerequisiteCheckResult(
          status: PrerequisiteStatus.bluetoothDisabled,
          permissionsGranted: true,
          bluetoothEnabled: false,
        );

        await pumpDevicesScreen(tester);

        await tester.tap(find.text('Mulai Pindai'));
        await tester.pumpAndSettle();

        expect(find.text('Bluetooth Belum Aktif'), findsOneWidget);
        expect(
          find.textContaining('Bluetooth belum aktif. Aktifkan Bluetooth'),
          findsOneWidget,
        );
        expect(find.text('Buka Pengaturan'), findsOneWidget);
        expect(find.text('Coba Lagi'), findsOneWidget);
        expect(find.text('Nanti'), findsOneWidget);

        // Uji aksi buka pengaturan bluetooth
        await tester.tap(find.text('Buka Pengaturan'));
        await tester.pumpAndSettle();
        expect(fakePrereq.openBluetoothSettingsCalled, isTrue);
      },
    );

    testWidgets(
      '4. Kegagalan startAdvertising: menampilkan dialog "Gagal Memulai Koneksi" dengan opsi Coba Lagi',
      (WidgetTester tester) async {
        fakeTransport.failNextStartAdvertising = true;
        fakeTransport.advertisingFailureReport = TransportDiagnosticReport(
          operation: 'startAdvertising',
          category: TransportFailureCategory.transportInitFailed,
          statusCode: 8007,
          timestamp: DateTime.now(),
          userFriendlyMessage:
              'Gagal menginisialisasi layanan koneksi terdekat.',
          suggestedAction: 'Coba lagi dalam beberapa saat.',
        );

        await pumpDevicesScreen(tester);

        await tester.tap(find.text('Mulai Siaran'));
        await tester.pumpAndSettle();

        expect(find.text('Gagal Memulai Koneksi'), findsOneWidget);
        expect(
          find.text(
            'Gagal menginisialisasi layanan koneksi terdekat. Pastikan radio nirkabel aktif dan coba lagi.',
          ),
          findsOneWidget,
        );
        expect(find.text('Coba Lagi'), findsOneWidget);
        expect(find.text('Nanti'), findsOneWidget);
        expect(fakeTransport.isAdvertising, isFalse);
      },
    );

    testWidgets(
      '5. Kegagalan startDiscovery: menampilkan dialog "Gagal Memulai Koneksi" tanpa klaim sepihak',
      (WidgetTester tester) async {
        fakeTransport.failNextStartDiscovery = true;
        fakeTransport.discoveryFailureReport = TransportDiagnosticReport(
          operation: 'startDiscovery',
          category: TransportFailureCategory.radioUnavailable,
          statusCode: 8007,
          timestamp: DateTime.now(),
          userFriendlyMessage:
              'Radio nirkabel perangkat mengalami kendala saat memulai koneksi.',
          suggestedAction: 'Pastikan radio aktif dan coba lagi.',
        );

        await pumpDevicesScreen(tester);

        await tester.tap(find.text('Mulai Pindai'));
        await tester.pumpAndSettle();

        expect(find.text('Gagal Memulai Koneksi'), findsOneWidget);
        expect(
          find.text(
            'Radio nirkabel perangkat mengalami kendala saat memulai koneksi. Pastikan radio aktif dan coba lagi.',
          ),
          findsOneWidget,
        );
        expect(fakeTransport.isDiscovering, isFalse);
      },
    );

    testWidgets(
      '6. Operasi advertising atau discovery yang sudah berjalan diakui sebagai kondisi aktif (bukan error)',
      (WidgetTester tester) async {
        fakeTransport.simulateAlreadyDiscovering = true;

        await pumpDevicesScreen(tester);

        await tester.tap(find.text('Mulai Pindai'));
        await tester.pumpAndSettle();

        // Tidak boleh menampilkan dialog popup error
        expect(find.text('Gagal Memulai Koneksi'), findsNothing);
        expect(find.text('Inisialisasi Mesh Gagal'), findsNothing);
        expect(fakeTransport.isDiscovering, isTrue);
        expect(find.text('Pindai: AKTIF'), findsOneWidget);
      },
    );

    testWidgets(
      '7. Pemanggilan ulang (Coba Lagi) setelah kegagalan berhasil memulihkan operasi',
      (WidgetTester tester) async {
        fakeTransport.failNextStartDiscovery = true;

        await pumpDevicesScreen(tester);

        await tester.tap(find.text('Mulai Pindai'));
        await tester.pumpAndSettle();

        expect(find.text('Gagal Memulai Koneksi'), findsOneWidget);

        // Pulihkan transport agar pemanggilan ulang berhasil
        fakeTransport.failNextStartDiscovery = false;

        await tester.tap(find.text('Coba Lagi'));
        await tester.pumpAndSettle();

        // Dialog tertutup dan pemindaian aktif
        expect(find.text('Gagal Memulai Koneksi'), findsNothing);
        expect(fakeTransport.isDiscovering, isTrue);
        expect(find.text('Pindai: AKTIF'), findsOneWidget);
      },
    );

    testWidgets(
      '8. Penanganan exception tidak dikenal menghasilkan pesan umum yang aman tanpa data sensitif',
      (WidgetTester tester) async {
        fakeTransport.failNextStartDiscovery = true;
        fakeTransport.discoveryFailureReport = TransportDiagnosticReport(
          operation: 'startDiscovery',
          category: TransportFailureCategory.unknown,
          nativeMessage: 'Internal crash in proprietary radio daemon 0x88',
          timestamp: DateTime.now(),
          userFriendlyMessage:
              'Terjadi kendala saat memulai layanan koneksi terdekat.',
          suggestedAction: 'Coba lagi dalam beberapa saat.',
        );

        await pumpDevicesScreen(tester);

        await tester.tap(find.text('Mulai Pindai'));
        await tester.pumpAndSettle();

        expect(find.text('Gagal Memulai Koneksi'), findsOneWidget);
        expect(
          find.text(
            'Terjadi kendala saat memulai layanan koneksi terdekat. Silakan coba kembali.',
          ),
          findsOneWidget,
        );
        // Pesan internal teknis tidak diekspos secara mentah di pesan dialog UI
        expect(
          find.textContaining('Internal crash in proprietary radio daemon'),
          findsNothing,
        );
      },
    );

    testWidgets(
      '9. Discovery berhasil tanpa peer: menampilkan empty state "Belum Ada Perangkat Ditemukan", BUKAN popup error',
      (WidgetTester tester) async {
        await pumpDevicesScreen(tester);

        await tester.tap(find.text('Mulai Pindai'));
        await tester.pumpAndSettle();

        expect(fakeTransport.isDiscovering, isTrue);
        expect(find.text('Gagal Memulai Koneksi'), findsNothing);
        expect(find.text('Inisialisasi Mesh Gagal'), findsNothing);

        // Scroll untuk melihat empty state
        await tester.drag(find.byType(ListView), const Offset(0, -300));
        await tester.pumpAndSettle();

        expect(find.text('Belum Ada Perangkat Ditemukan'), findsOneWidget);
        expect(
          find.textContaining('Perangkat sekitar belum terdeteksi.'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      '10. Penghentian transport dan inisialisasi kembali bekerja bersih',
      (WidgetTester tester) async {
        await pumpDevicesScreen(tester);

        // Mulai discovery
        await tester.tap(find.text('Mulai Pindai'));
        await tester.pumpAndSettle();
        expect(fakeTransport.isDiscovering, isTrue);

        // Hentikan discovery
        await tester.tap(find.text('Pindai: AKTIF'));
        await tester.pumpAndSettle();
        expect(fakeTransport.isDiscovering, isFalse);
        expect(fakeTransport.stopDiscoveryCallCount, equals(1));

        // Mulai kembali
        await tester.tap(find.text('Mulai Pindai'));
        await tester.pumpAndSettle();
        expect(fakeTransport.isDiscovering, isTrue);
        expect(fakeTransport.startDiscoveryCallCount, equals(2));
      },
    );

    testWidgets(
      '11. Pencegahan operasi duplikat (guard flag) saat proses sedang berjalan',
      (WidgetTester tester) async {
        await pumpDevicesScreen(tester);

        // Tap sekali
        await tester.tap(find.text('Mulai Pindai'));
        await tester.pumpAndSettle();

        expect(fakeTransport.startDiscoveryCallCount, equals(1));
      },
    );

    testWidgets(
      '12. Konsistensi status UI dengan hasil operasi transport (Siaran vs Terhubung)',
      (WidgetTester tester) async {
        await pumpDevicesScreen(tester);

        // Mulai siaran
        await tester.tap(find.text('Mulai Siaran'));
        await tester.pumpAndSettle();

        expect(fakeTransport.isAdvertising, isTrue);
        expect(find.text('MENYIARKAN • NODE TERLIHAT'), findsOneWidget);
        // Belum ada peer yang terhubung
        expect(find.text('TERHUBUNG'), findsOneWidget);
        expect(fakeTransport.connectedPeers.isEmpty, isTrue);

        // Simulasikan 1 peer terhubung
        fakeTransport.simulatePeerDiscovered(
          DiscoveredPeer(
            endpointId: 'ep-node-b',
            endpointName: 'Node B Relawan',
            serviceId: 'com.siagamesh.emergency.mesh',
            discoveredAt: DateTime.now(),
            status: PeerConnectionStatus.connected,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('TERHUBUNG • 1 PEER AKTIF'), findsOneWidget);
      },
    );

    test(
      '13. Parser TransportDiagnostics mengekstrak kode status dan mengkategorikan error dengan benar',
      () {
        final pe1 = PlatformException(
          code: 'Failure',
          message: '8002: STATUS_ALREADY_DISCOVERING',
        );
        expect(TransportDiagnostics.extractStatusCode(pe1), equals(8002));
        expect(
          TransportDiagnostics.categorizeError(error: pe1),
          equals(TransportFailureCategory.alreadyRunning),
        );

        final pe2 = PlatformException(
          code: 'Failure',
          message: '8036: STATUS_MISSING_PERMISSION_ACCESS_FINE_LOCATION',
        );
        expect(TransportDiagnostics.extractStatusCode(pe2), equals(8036));
        expect(
          TransportDiagnostics.categorizeError(error: pe2),
          equals(TransportFailureCategory.permissionDenied),
        );

        final pe3 = PlatformException(
          code: 'Failure',
          message: '8007: STATUS_RADIO_ERROR',
        );
        expect(TransportDiagnostics.extractStatusCode(pe3), equals(8007));
        expect(
          TransportDiagnostics.categorizeError(error: pe3),
          equals(TransportFailureCategory.radioUnavailable),
        );

        final pe4 = PlatformException(
          code: 'Failure',
          message: '8050: API_CONNECTION_FAILED_ALREADY_IN_USE',
        );
        expect(TransportDiagnostics.extractStatusCode(pe4), equals(8050));
        expect(
          TransportDiagnostics.categorizeError(error: pe4),
          equals(TransportFailureCategory.connectionConflict),
        );
      },
    );
  });
}

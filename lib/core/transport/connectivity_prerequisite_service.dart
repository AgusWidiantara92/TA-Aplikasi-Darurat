import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Status kesiapan prasyarat konektivitas radio dan izin perangkat.
enum PrerequisiteStatus {
  /// Seluruh izin dan radio (Bluetooth) aktif dan siap digunakan.
  ready,

  /// Izin sistem belum diberikan, namun masih dapat diminta melalui runtime dialog.
  permissionRequired,

  /// Izin sistem telah ditolak permanen, memerlukan pengalihan ke Pengaturan Aplikasi.
  permissionPermanentlyDenied,

  /// Radio Bluetooth mati atau belum aktif.
  bluetoothDisabled,

  /// Layanan Google Play Services tidak tersedia atau perlu diperbarui.
  googlePlayServicesUnavailable,

  /// Terjadi kesalahan internal atau platform tidak didukung.
  error,
}

/// Hasil diagnosa status prasyarat konektivitas perangkat.
class PrerequisiteCheckResult {
  final PrerequisiteStatus status;
  final bool permissionsGranted;
  final bool bluetoothEnabled;
  final bool permanentlyDenied;
  final bool locationEnabled;
  final bool googlePlayServicesAvailable;
  final int googlePlayServicesStatusCode;
  final List<String> missingPermissions;
  final String? errorMessage;
  final int? androidVersion;

  const PrerequisiteCheckResult({
    required this.status,
    this.permissionsGranted = true,
    this.bluetoothEnabled = true,
    this.permanentlyDenied = false,
    this.locationEnabled = true,
    this.googlePlayServicesAvailable = true,
    this.googlePlayServicesStatusCode = 0,
    this.missingPermissions = const [],
    this.errorMessage,
    this.androidVersion,
  });

  /// Mengembalikan `true` jika perangkat siap untuk memindai atau menyiarkan sinyal.
  bool get isReady => status == PrerequisiteStatus.ready;

  /// Representasi snapshot untuk keperluan logging diagnostik.
  Map<String, dynamic> toSnapshot() => {
    'status': status.name,
    'permissionsGranted': permissionsGranted,
    'bluetoothEnabled': bluetoothEnabled,
    'permanentlyDenied': permanentlyDenied,
    'locationEnabled': locationEnabled,
    'googlePlayServicesAvailable': googlePlayServicesAvailable,
    'googlePlayServicesStatusCode': googlePlayServicesStatusCode,
    'missingPermissions': missingPermissions,
    'androidVersion': androidVersion,
  };
}

/// Kontrak layanan pemeriksaan prasyarat konektivitas nirkabel dan izin sistem.
abstract class ConnectivityPrerequisiteService {
  Future<PrerequisiteCheckResult> checkPrerequisites();
  Future<bool> requestPermissions();
  Future<bool> openAppSettings();
  Future<bool> openBluetoothSettings();
  Future<bool> isBluetoothEnabled();
}

/// Implementasi Android berbasis Native Platform Channel (`com.siagamesh.app/device_settings`).
class AndroidConnectivityPrerequisiteService
    implements ConnectivityPrerequisiteService {
  static const MethodChannel _channel = MethodChannel(
    'com.siagamesh.app/device_settings',
  );

  @override
  Future<PrerequisiteCheckResult> checkPrerequisites() async {
    // Pada lingkungan non-Android (misalnya unit test desktop), anggap siap
    if (!kIsWeb && !Platform.isAndroid) {
      return const PrerequisiteCheckResult(status: PrerequisiteStatus.ready);
    }

    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'checkPrerequisites',
      );
      if (res == null) {
        return const PrerequisiteCheckResult(
          status: PrerequisiteStatus.error,
          errorMessage: 'Platform channel mengembalikan null',
        );
      }

      final permissionsGranted = res['permissionsGranted'] as bool? ?? false;
      final bluetoothEnabled = res['bluetoothEnabled'] as bool? ?? false;
      final permanentlyDenied = res['permanentlyDenied'] as bool? ?? false;
      final locationEnabled = res['locationEnabled'] as bool? ?? true;
      final gmsAvailable = res['googlePlayServicesAvailable'] as bool? ?? true;
      final gmsStatusCode = res['googlePlayServicesStatusCode'] as int? ?? 0;
      final androidVersion = res['androidVersion'] as int?;
      final rawMissing = res['missingPermissions'] as List<dynamic>? ?? [];
      final missingPermissions = rawMissing.map((e) => e.toString()).toList();

      if (!permissionsGranted) {
        if (permanentlyDenied) {
          return PrerequisiteCheckResult(
            status: PrerequisiteStatus.permissionPermanentlyDenied,
            permissionsGranted: false,
            bluetoothEnabled: bluetoothEnabled,
            permanentlyDenied: true,
            locationEnabled: locationEnabled,
            googlePlayServicesAvailable: gmsAvailable,
            googlePlayServicesStatusCode: gmsStatusCode,
            missingPermissions: missingPermissions,
            androidVersion: androidVersion,
          );
        }
        return PrerequisiteCheckResult(
          status: PrerequisiteStatus.permissionRequired,
          permissionsGranted: false,
          bluetoothEnabled: bluetoothEnabled,
          permanentlyDenied: false,
          locationEnabled: locationEnabled,
          googlePlayServicesAvailable: gmsAvailable,
          googlePlayServicesStatusCode: gmsStatusCode,
          missingPermissions: missingPermissions,
          androidVersion: androidVersion,
        );
      }

      if (!bluetoothEnabled) {
        return PrerequisiteCheckResult(
          status: PrerequisiteStatus.bluetoothDisabled,
          permissionsGranted: true,
          bluetoothEnabled: false,
          permanentlyDenied: false,
          locationEnabled: locationEnabled,
          googlePlayServicesAvailable: gmsAvailable,
          googlePlayServicesStatusCode: gmsStatusCode,
          missingPermissions: missingPermissions,
          androidVersion: androidVersion,
        );
      }

      if (!gmsAvailable) {
        return PrerequisiteCheckResult(
          status: PrerequisiteStatus.googlePlayServicesUnavailable,
          permissionsGranted: true,
          bluetoothEnabled: bluetoothEnabled,
          permanentlyDenied: false,
          locationEnabled: locationEnabled,
          googlePlayServicesAvailable: false,
          googlePlayServicesStatusCode: gmsStatusCode,
          missingPermissions: missingPermissions,
          androidVersion: androidVersion,
          errorMessage:
              'Google Play Services tidak siap (kode: $gmsStatusCode)',
        );
      }

      return PrerequisiteCheckResult(
        status: PrerequisiteStatus.ready,
        permissionsGranted: true,
        bluetoothEnabled: true,
        locationEnabled: locationEnabled,
        googlePlayServicesAvailable: true,
        googlePlayServicesStatusCode: gmsStatusCode,
        androidVersion: androidVersion,
      );
    } catch (e) {
      debugPrint('[PrerequisiteService] Gagal memeriksa prasyarat: $e');
      return PrerequisiteCheckResult(
        status: PrerequisiteStatus.error,
        errorMessage: e.toString(),
      );
    }
  }

  @override
  Future<bool> requestPermissions() async {
    if (!kIsWeb && !Platform.isAndroid) return true;
    try {
      final granted = await _channel.invokeMethod<bool>('requestPermissions');
      return granted ?? false;
    } catch (e) {
      debugPrint('[PrerequisiteService] Gagal meminta izin: $e');
      return false;
    }
  }

  @override
  Future<bool> openAppSettings() async {
    if (!kIsWeb && !Platform.isAndroid) return true;
    try {
      final res = await _channel.invokeMethod<bool>('openAppSettings');
      return res ?? false;
    } catch (e) {
      debugPrint('[PrerequisiteService] Gagal membuka pengaturan aplikasi: $e');
      return false;
    }
  }

  @override
  Future<bool> openBluetoothSettings() async {
    if (!kIsWeb && !Platform.isAndroid) return true;
    try {
      final res = await _channel.invokeMethod<bool>('openBluetoothSettings');
      return res ?? false;
    } catch (e) {
      debugPrint(
        '[PrerequisiteService] Gagal membuka pengaturan Bluetooth: $e',
      );
      return false;
    }
  }

  @override
  Future<bool> isBluetoothEnabled() async {
    if (!kIsWeb && !Platform.isAndroid) return true;
    try {
      final res = await _channel.invokeMethod<bool>('isBluetoothEnabled');
      return res ?? false;
    } catch (e) {
      debugPrint('[PrerequisiteService] Gagal mengecek status Bluetooth: $e');
      return false;
    }
  }
}

/// Implementasi tiruan (Fake) untuk pengujian unit dan widget.
class FakeConnectivityPrerequisiteService
    implements ConnectivityPrerequisiteService {
  PrerequisiteCheckResult currentResult;
  bool requestPermissionsReturnValue;
  bool openAppSettingsCalled = false;
  bool openBluetoothSettingsCalled = false;
  int requestPermissionsCallCount = 0;
  int checkPrerequisitesCallCount = 0;

  FakeConnectivityPrerequisiteService({
    this.currentResult = const PrerequisiteCheckResult(
      status: PrerequisiteStatus.ready,
      permissionsGranted: true,
      bluetoothEnabled: true,
    ),
    this.requestPermissionsReturnValue = true,
  });

  @override
  Future<PrerequisiteCheckResult> checkPrerequisites() async {
    checkPrerequisitesCallCount++;
    return currentResult;
  }

  @override
  Future<bool> requestPermissions() async {
    requestPermissionsCallCount++;
    return requestPermissionsReturnValue;
  }

  @override
  Future<bool> openAppSettings() async {
    openAppSettingsCalled = true;
    return true;
  }

  @override
  Future<bool> openBluetoothSettings() async {
    openBluetoothSettingsCalled = true;
    return true;
  }

  @override
  Future<bool> isBluetoothEnabled() async {
    return currentResult.bluetoothEnabled;
  }
}

/// Singleton penampung [ConnectivityPrerequisiteService] agar mudah diinjeksi pada test.
class ConnectivityPrerequisiteHolder {
  static ConnectivityPrerequisiteService? _instance;

  static ConnectivityPrerequisiteService get instance {
    _instance ??= AndroidConnectivityPrerequisiteService();
    return _instance!;
  }

  static void setInstance(ConnectivityPrerequisiteService service) {
    _instance = service;
  }

  static void reset() {
    _instance = null;
  }
}

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'mesh_transport.dart';

/// Utilitas diagnosa dan parser error untuk lapisan transport nirkabel Nearby Connections.
class TransportDiagnostics {
  /// Ekstraksi kode status numerik Google Play Services Nearby Connections dari pesan exception.
  ///
  /// Contoh format:
  /// - "8001: STATUS_ALREADY_ADVERTISING" -> 8001
  /// - "8002: STATUS_ALREADY_DISCOVERING" -> 8002
  /// - "8036: STATUS_MISSING_PERMISSION_ACCESS_FINE_LOCATION" -> 8036
  /// - "8007: STATUS_RADIO_ERROR" -> 8007
  /// - "8050: API_CONNECTION_FAILED_ALREADY_IN_USE" -> 8050
  /// - "16: API_UNAVAILABLE" -> 16
  /// - "17: API_NOT_CONNECTED" -> 17
  static int? extractStatusCode(dynamic error) {
    if (error == null) return null;
    final text = error is PlatformException
        ? '${error.code} ${error.message ?? ""} ${error.details ?? ""}'
        : error.toString();

    final match = RegExp(r'\b(8\d{3}|1[67])\b').firstMatch(text);
    if (match != null) {
      return int.tryParse(match.group(1)!);
    }
    return null;
  }

  /// Mengklasifikasikan error ke dalam [TransportFailureCategory] berdasarkan
  /// status code, tipe exception, dan kata kunci pesan native.
  static TransportFailureCategory categorizeError({
    required dynamic error,
    int? statusCode,
    bool? isBluetoothEnabled,
    bool? permissionsGranted,
    bool? googlePlayServicesAvailable,
  }) {
    final code = statusCode ?? extractStatusCode(error);
    final errorStr = (error?.toString() ?? '').toUpperCase();

    // 1. Periksa kode status spesifik Google Nearby Connections
    if (code != null) {
      switch (code) {
        case 8001: // STATUS_ALREADY_ADVERTISING
        case 8002: // STATUS_ALREADY_DISCOVERING
          return TransportFailureCategory.alreadyRunning;

        case 8034: // STATUS_MISSING_PERMISSION_ACCESS_COARSE_LOCATION
        case 8035: // STATUS_MISSING_PERMISSION_ACCESS_WIFI_STATE
        case 8036: // STATUS_MISSING_PERMISSION_ACCESS_FINE_LOCATION
        case 8037: // STATUS_MISSING_PERMISSION_BLUETOOTH_SCAN
        case 8038: // STATUS_MISSING_PERMISSION_BLUETOOTH_ADVERTISE
        case 8039: // STATUS_MISSING_PERMISSION_BLUETOOTH_CONNECT
          return TransportFailureCategory.permissionDenied;

        case 8007: // STATUS_RADIO_ERROR
          return TransportFailureCategory.radioUnavailable;

        case 8008: // STATUS_BLUETOOTH_ERROR
          return TransportFailureCategory.bluetoothDisabled;

        case 8050: // API_CONNECTION_FAILED_ALREADY_IN_USE
          return TransportFailureCategory.connectionConflict;

        case 16: // API_UNAVAILABLE
        case 17: // API_NOT_CONNECTED
          return TransportFailureCategory.googlePlayServicesUnavailable;
      }
    }

    // 2. Periksa petunjuk dari snapshot prasyarat
    if (permissionsGranted == false) {
      return TransportFailureCategory.permissionDenied;
    }
    if (isBluetoothEnabled == false) {
      return TransportFailureCategory.bluetoothDisabled;
    }
    if (googlePlayServicesAvailable == false) {
      return TransportFailureCategory.googlePlayServicesUnavailable;
    }

    // 3. Periksa kata kunci string pada exception
    if (errorStr.contains('ALREADY_ADVERTISING') ||
        errorStr.contains('ALREADY_DISCOVERING') ||
        errorStr.contains('STATUS_ALREADY')) {
      return TransportFailureCategory.alreadyRunning;
    }

    if (errorStr.contains('PERMISSION') ||
        errorStr.contains('SECURITYEXCEPTION')) {
      return TransportFailureCategory.permissionDenied;
    }

    if (errorStr.contains('BLUETOOTH_DISABLED') ||
        errorStr.contains('BLUETOOTH OFF')) {
      return TransportFailureCategory.bluetoothDisabled;
    }

    if (errorStr.contains('RADIO_ERROR') ||
        errorStr.contains('RADIO UNAVAILABLE')) {
      return TransportFailureCategory.radioUnavailable;
    }

    if (errorStr.contains('PLAY SERVICES') ||
        errorStr.contains('GMS') ||
        errorStr.contains('API_NOT_CONNECTED')) {
      return TransportFailureCategory.googlePlayServicesUnavailable;
    }

    if (errorStr.contains('ALREADY_IN_USE') || errorStr.contains('CONFLICT')) {
      return TransportFailureCategory.connectionConflict;
    }

    if (errorStr.contains('INIT') || errorStr.contains('INITIALIZATION')) {
      return TransportFailureCategory.transportInitFailed;
    }

    return TransportFailureCategory.unknown;
  }

  /// Membuat [TransportDiagnosticReport] lengkap untuk kegagalan operasi.
  static TransportDiagnosticReport createReport({
    required String operation,
    required dynamic error,
    required Map<String, dynamic> prerequisitesSnapshot,
    required Map<String, dynamic> transportStateSnapshot,
  }) {
    final statusCode = extractStatusCode(error);
    final category = categorizeError(
      error: error,
      statusCode: statusCode,
      isBluetoothEnabled: prerequisitesSnapshot['bluetoothEnabled'] as bool?,
      permissionsGranted: prerequisitesSnapshot['permissionsGranted'] as bool?,
      googlePlayServicesAvailable:
          prerequisitesSnapshot['googlePlayServicesAvailable'] as bool?,
    );

    final platformCode = error is PlatformException ? error.code : null;
    final nativeMessage = error is PlatformException
        ? error.message
        : (error?.toString() ?? '');

    final userFriendlyMessage = _getUserFriendlyMessage(
      category: category,
      statusCode: statusCode,
    );
    final suggestedAction = _getSuggestedAction(category);

    return TransportDiagnosticReport(
      operation: operation,
      category: category,
      exceptionType: error?.runtimeType.toString(),
      platformCode: platformCode,
      statusCode: statusCode,
      nativeMessage: nativeMessage,
      prerequisitesSnapshot: prerequisitesSnapshot,
      transportStateSnapshot: transportStateSnapshot,
      timestamp: DateTime.now(),
      userFriendlyMessage: userFriendlyMessage,
      suggestedAction: suggestedAction,
    );
  }

  static String _getUserFriendlyMessage({
    required TransportFailureCategory category,
    int? statusCode,
  }) {
    switch (category) {
      case TransportFailureCategory.permissionDenied:
        return 'Izin perangkat sekitar atau Bluetooth belum diberikan.';
      case TransportFailureCategory.bluetoothDisabled:
        return 'Bluetooth belum aktif pada perangkat ini.';
      case TransportFailureCategory.radioUnavailable:
        return 'Radio nirkabel perangkat mengalami kendala saat memulai koneksi.';
      case TransportFailureCategory.googlePlayServicesUnavailable:
        return 'Layanan Google Play tidak tersedia atau perlu diperbarui.';
      case TransportFailureCategory.alreadyRunning:
        return 'Layanan koneksi sudah aktif.';
      case TransportFailureCategory.connectionConflict:
        return 'Layanan nirkabel sedang digunakan oleh proses lain atau terjadi konflik koneksi.';
      case TransportFailureCategory.transportInitFailed:
        return 'Gagal menginisialisasi layanan koneksi terdekat.';
      case TransportFailureCategory.unknown:
        return 'Terjadi kendala saat memulai layanan koneksi terdekat.';
    }
  }

  static String _getSuggestedAction(TransportFailureCategory category) {
    switch (category) {
      case TransportFailureCategory.permissionDenied:
        return 'Buka Pengaturan aplikasi untuk memberikan izin Nearby/Bluetooth.';
      case TransportFailureCategory.bluetoothDisabled:
        return 'Aktifkan Bluetooth pada perangkat lalu coba lagi.';
      case TransportFailureCategory.radioUnavailable:
        return 'Pastikan radio nirkabel aktif dan coba beberapa saat lagi.';
      case TransportFailureCategory.googlePlayServicesUnavailable:
        return 'Periksa status Google Play Services pada perangkat Anda.';
      case TransportFailureCategory.alreadyRunning:
        return 'Layanan sudah berjalan normal.';
      case TransportFailureCategory.connectionConflict:
        return 'Hentikan aplikasi lain yang menggunakan radio atau coba lagi.';
      case TransportFailureCategory.transportInitFailed:
      case TransportFailureCategory.unknown:
        return 'Coba lagi dalam beberapa saat.';
    }
  }

  /// Mencatat log diagnostik lengkap ke konsol debug secara aman (tanpa data sensitif).
  static void logDiagnostic(TransportDiagnosticReport report) {
    debugPrint(
      '[TransportDiagnostics] === LAPORAN DIAGNOSTIK: ${report.operation} ===\n'
      '  Kategori           : ${report.category.name}\n'
      '  Exception Type     : ${report.exceptionType ?? "-"}\n'
      '  Platform Code      : ${report.platformCode ?? "-"}\n'
      '  Status Code        : ${report.statusCode ?? "-"}\n'
      '  Pesan Asli         : ${report.nativeMessage ?? "-"}\n'
      '  Snapshot Prasyarat : ${report.prerequisitesSnapshot}\n'
      '  State Transport    : ${report.transportStateSnapshot}\n'
      '  Saran Tindakan     : ${report.suggestedAction}\n'
      '==============================================================',
    );
  }

  /// Mencatat log saat operasi dimulai.
  static void logOperationStart({
    required String operation,
    required Map<String, dynamic> transportStateSnapshot,
    required Map<String, dynamic> prerequisitesSnapshot,
  }) {
    debugPrint(
      '[TransportDiagnostics] Memulai operasi "$operation" | '
      'State Transport: $transportStateSnapshot | '
      'Prasyarat: $prerequisitesSnapshot',
    );
  }
}

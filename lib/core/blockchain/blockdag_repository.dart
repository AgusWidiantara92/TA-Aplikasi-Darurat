/// Repositori penyimpanan lokal persisten untuk BlockDAG Ledger SiagaMesh.
///
/// Bertanggung jawab untuk:
/// 1. Menyimpan dan memulihkan seluruh state aktif ledger (blok, checkpoint, tips, dan antrean event).
/// 2. Menjaga isolasi data dengan versi skema data eksplisit dan validasi integritas versi.
/// 3. Membedakan secara tegas antara instalasi kosong, pemulihan sukses, storage tidak tersedia,
///    data korup, dan versi skema tidak didukung.
library;

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'blockchain_types.dart';

/// Status hasil pemuatan state BlockDAG dari penyimpanan persisten.
enum BlockdagLoadStatus {
  /// State berhasil dimuat dan divalidasi dengan integritas versi skema yang cocok.
  success,

  /// Penyimpanan tersedia namun belum ada state tersimpan (instalasi baru yang sah).
  empty,

  /// Penyimpanan lokal tidak dapat diakses atau terjadi kegagalan I/O.
  storageUnavailable,

  /// Data JSON atau struktur payload korup, malformed, atau tidak dapat di-parse.
  corruptedData,

  /// Versi skema tidak didukung atau terjadi ketidakcocokan versi skema antara preferensi dan isi state.
  unsupportedVersion,
}

/// Objek hasil operasi pemuatan state dari [BlockdagRepository].
class BlockdagLoadResult {
  final BlockdagLoadStatus status;
  final BlockdagPersistedState? state;
  final String? errorMessage;
  final int? detectedSchemaVersion;

  const BlockdagLoadResult({
    required this.status,
    this.state,
    this.errorMessage,
    this.detectedSchemaVersion,
  });

  factory BlockdagLoadResult.success(BlockdagPersistedState state) =>
      BlockdagLoadResult(status: BlockdagLoadStatus.success, state: state);

  factory BlockdagLoadResult.empty() =>
      const BlockdagLoadResult(status: BlockdagLoadStatus.empty);

  factory BlockdagLoadResult.storageUnavailable([String? message]) =>
      BlockdagLoadResult(
        status: BlockdagLoadStatus.storageUnavailable,
        errorMessage: message,
      );

  factory BlockdagLoadResult.corruptedData([String? message]) =>
      BlockdagLoadResult(
        status: BlockdagLoadStatus.corruptedData,
        errorMessage: message,
      );

  factory BlockdagLoadResult.unsupportedVersion({
    required int detectedVersion,
    String? message,
  }) => BlockdagLoadResult(
    status: BlockdagLoadStatus.unsupportedVersion,
    detectedSchemaVersion: detectedVersion,
    errorMessage: message,
  );

  bool get isSuccess => status == BlockdagLoadStatus.success && state != null;
  bool get isEmpty => status == BlockdagLoadStatus.empty;
  bool get isStorageUnavailable =>
      status == BlockdagLoadStatus.storageUnavailable;
  bool get isCorrupted => status == BlockdagLoadStatus.corruptedData;
  bool get isUnsupportedVersion =>
      status == BlockdagLoadStatus.unsupportedVersion;
}

/// Kontrak repositori persistensi untuk BlockDAG ledger.
abstract class BlockdagRepository {
  /// Memuat state ledger dengan hasil terperinci yang membedakan kondisi kosong,
  /// sukses, storage tidak tersedia, data korup, dan versi tidak didukung.
  Future<BlockdagLoadResult> loadResult();

  /// Memuat state ledger dari penyimpanan persisten.
  /// Mengembalikan state jika berhasil, atau `null` jika tidak ada/gagal.
  Future<BlockdagPersistedState?> loadState();

  /// Menyimpan seluruh state aktif ledger secara persisten.
  /// Mengembalikan `true` jika penyimpanan berhasil, atau `false` jika penulisan gagal.
  Future<bool> saveState(BlockdagPersistedState state);

  /// Menghapus seluruh data ledger lokal yang tersimpan (untuk pengujian atau reset sesi).
  Future<bool> clear();

  /// Menandakan apakah pemanggilan terakhir mendeteksi data korup/rusak di disk.
  bool get lastLoadCorrupted => false;
}

/// Implementasi [BlockdagRepository] menggunakan [SharedPreferences] lokal.
class LocalBlockdagRepository implements BlockdagRepository {
  static const int currentSchemaVersion = 1;
  static const Set<int> supportedSchemaVersions = {1};
  static const String keySchemaVersion = 'siagamesh_blockdag_version';
  static const String keyState = 'siagamesh_blockdag_state';

  final SharedPreferences? _injectedPreferences;
  bool simulateStorageUnavailable;
  bool _lastLoadCorrupted = false;

  LocalBlockdagRepository({
    SharedPreferences? preferences,
    this.simulateStorageUnavailable = false,
  }) : _injectedPreferences = preferences;

  @override
  bool get lastLoadCorrupted => _lastLoadCorrupted;

  Future<SharedPreferences?> _getPrefs() async {
    if (simulateStorageUnavailable) {
      return null;
    }
    if (_injectedPreferences != null) {
      return _injectedPreferences;
    }
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<BlockdagLoadResult> loadResult() async {
    _lastLoadCorrupted = false;
    final prefs = await _getPrefs();
    if (prefs == null) {
      return BlockdagLoadResult.storageUnavailable(
        'Penyimpanan lokal (SharedPreferences) tidak dapat diakses atau gagal diinisialisasi',
      );
    }

    final rawJson = prefs.getString(keyState);
    if (rawJson == null || rawJson.trim().isEmpty) {
      return BlockdagLoadResult.empty();
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(rawJson);
    } catch (e) {
      _lastLoadCorrupted = true;
      return BlockdagLoadResult.corruptedData(
        'Format JSON di penyimpanan korup: $e',
      );
    }

    if (decoded is! Map) {
      _lastLoadCorrupted = true;
      return BlockdagLoadResult.corruptedData(
        'Format root JSON bukan objek Map (tipe: ${decoded.runtimeType})',
      );
    }

    final map = Map<String, dynamic>.from(decoded);

    // 1. Validasi konsistensi versi skema
    final rawVersionInState = map['schemaVersion'];
    if (rawVersionInState == null) {
      _lastLoadCorrupted = true;
      return BlockdagLoadResult.corruptedData(
        'Field schemaVersion hilang dari serialized state',
      );
    }

    final versionInState = (rawVersionInState as num).toInt();
    if (versionInState <= 0) {
      _lastLoadCorrupted = true;
      return BlockdagLoadResult.corruptedData(
        'Field schemaVersion bernilai tidak valid: $versionInState',
      );
    }

    final versionInPrefs = prefs.getInt(keySchemaVersion);
    if (versionInPrefs != null && versionInPrefs != versionInState) {
      _lastLoadCorrupted = true;
      return BlockdagLoadResult.corruptedData(
        'Ketidakcocokan versi skema antara metadata preference ($versionInPrefs) dan isi state ($versionInState)',
      );
    }

    // 2. Periksa apakah versi didukung
    if (!supportedSchemaVersions.contains(versionInState)) {
      _lastLoadCorrupted = false;
      return BlockdagLoadResult.unsupportedVersion(
        detectedVersion: versionInState,
        message:
            'Versi skema $versionInState tidak didukung oleh aplikasi saat ini (versi didukung: $supportedSchemaVersions)',
      );
    }

    // 3. Deserialisasi dan validasi isi state
    try {
      final state = BlockdagPersistedState.fromMap(map);
      _lastLoadCorrupted = false;
      return BlockdagLoadResult.success(state);
    } catch (e) {
      _lastLoadCorrupted = true;
      return BlockdagLoadResult.corruptedData(
        'Gagal memvalidasi struktur state BlockDAG: $e',
      );
    }
  }

  @override
  Future<BlockdagPersistedState?> loadState() async {
    final result = await loadResult();
    return result.state;
  }

  @override
  Future<bool> saveState(BlockdagPersistedState state) async {
    final prefs = await _getPrefs();
    if (prefs == null) return false;

    try {
      final encoded = jsonEncode(state.toMap());
      final successState = await prefs.setString(keyState, encoded);
      final successVersion = await prefs.setInt(
        keySchemaVersion,
        state.schemaVersion,
      );
      return successState && successVersion;
    } catch (_) {
      // Penanganan eksplisit jika terjadi kegagalan penulisan disk
      return false;
    }
  }

  @override
  Future<bool> clear() async {
    final prefs = await _getPrefs();
    if (prefs == null) return false;

    try {
      await prefs.remove(keyState);
      await prefs.remove(keySchemaVersion);
      return true;
    } catch (_) {
      return false;
    }
  }
}

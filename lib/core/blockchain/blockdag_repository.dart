/// Repositori penyimpanan lokal persisten untuk BlockDAG Ledger SiagaMesh.
///
/// Bertanggung jawab untuk:
/// 1. Menyimpan dan memulihkan seluruh state aktif ledger (blok, checkpoint, tips, dan antrean event).
/// 2. Menjaga isolasi data dengan versi skema data eksplisit dan validasi integritas versi.
/// 3. Membedakan secara tegas antara instalasi kosong, pemulihan sukses, storage tidak tersedia,
///    data korup, dan versi skema tidak didukung.
/// 4. Menjamin integritas commit dan pemulihan kegagalan penulisan parsial (partial-write recovery)
///    menggunakan arsitektur Dual-Slot (A/B) Staged Commit dengan SHA-256 checksum dan atomic pointer.
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

/// Implementasi [BlockdagRepository] menggunakan [SharedPreferences] lokal
/// dengan proteksi Dual-Slot Staged Commit terhadap partial-write failure.
class LocalBlockdagRepository implements BlockdagRepository {
  static const int currentSchemaVersion = 1;
  static const Set<int> supportedSchemaVersions = {1};

  // Kunci preferensi legacy untuk kompatibilitas mundur
  static const String keySchemaVersion = 'siagamesh_blockdag_version';
  static const String keyState = 'siagamesh_blockdag_state';

  // Kunci Dual-Slot Staged Commit (Stage 5E.4.4.2)
  static const String keyActiveSlot = 'siagamesh_blockdag_active_slot';
  static const String slotA = 'slot_a';
  static const String slotB = 'slot_b';
  static const String keySlotA = 'siagamesh_blockdag_state_slot_a';
  static const String keySlotB = 'siagamesh_blockdag_state_slot_b';

  final SharedPreferences? _injectedPreferences;
  bool simulateStorageUnavailable;
  bool _lastLoadCorrupted = false;

  /// Hook pengujian: simulasi kegagalan penulisan staging slot (sebelum commit pointer diperbarui).
  bool simulateStagingWriteFailure = false;

  /// Hook pengujian: simulasi kegagalan pembaruan commit pointer (setelah staging slot berhasil ditulis).
  bool simulatePointerCommitFailure = false;

  /// Hook pengujian: simulasi exception saat penulisan ke disk (I/O error atau platform channel failure).
  bool simulateSaveException = false;

  LocalBlockdagRepository({
    SharedPreferences? preferences,
    this.simulateStorageUnavailable = false,
  }) : _injectedPreferences = preferences;

  @override
  bool get lastLoadCorrupted => _lastLoadCorrupted;

  /// Membaca penanda slot aktif saat ini ('slot_a', 'slot_b', atau null jika belum ada).
  Future<String?> getActiveSlot() async {
    final prefs = await _getPrefs();
    return prefs?.getString(keyActiveSlot);
  }

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

    // 1. Periksa apakah sistem dual-slot aktif
    final activeSlot = prefs.getString(keyActiveSlot);
    if (activeSlot != null) {
      if (activeSlot != slotA && activeSlot != slotB) {
        _lastLoadCorrupted = true;
        return BlockdagLoadResult.corruptedData(
          'Nilai keyActiveSlot tidak valid: $activeSlot (harus $slotA atau $slotB)',
        );
      }

      final activeKey = (activeSlot == slotA) ? keySlotA : keySlotB;
      final rawSlotJson = prefs.getString(activeKey);
      if (rawSlotJson != null && rawSlotJson.trim().isNotEmpty) {
        return _validateAndDecodeSlotPayload(rawSlotJson, prefs);
      }

      // Pointer ada tetapi slot yang ditunjuk kosong/hilang
      _lastLoadCorrupted = true;
      return BlockdagLoadResult.corruptedData(
        'Slot aktif ($activeSlot) tidak ditemukan atau bernilai kosong pada penyimpanan persisten',
      );
    }

    // 2. Jika belum ada keyActiveSlot, periksa penyimpanan legacy (Stage 5E.3.x)
    return _loadLegacyResult(prefs);
  }

  /// Memvalidasi integritas envelope dual-slot, checksum SHA-256, versi skema, dan deserialisasi state.
  BlockdagLoadResult _validateAndDecodeSlotPayload(
    String rawSlotJson,
    SharedPreferences prefs,
  ) {
    dynamic decoded;
    try {
      decoded = jsonDecode(rawSlotJson);
    } catch (e) {
      _lastLoadCorrupted = true;
      return BlockdagLoadResult.corruptedData(
        'Format JSON pada slot aktif korup: $e',
      );
    }

    if (decoded is! Map) {
      _lastLoadCorrupted = true;
      return BlockdagLoadResult.corruptedData(
        'Format root JSON slot bukan objek Map (tipe: ${decoded.runtimeType})',
      );
    }

    final envelope = Map<String, dynamic>.from(decoded);

    // 1. Validasi schemaVersion pada envelope
    final rawEnvVersion = envelope['schemaVersion'];
    if (rawEnvVersion == null) {
      _lastLoadCorrupted = true;
      return BlockdagLoadResult.corruptedData(
        'Field schemaVersion hilang dari envelope slot',
      );
    }
    if (rawEnvVersion is! num) {
      _lastLoadCorrupted = true;
      return BlockdagLoadResult.corruptedData(
        'Field schemaVersion pada envelope slot harus bertipe numerik integer, ditemukan: ${rawEnvVersion.runtimeType}',
      );
    }
    final num numEnvVersion = rawEnvVersion;
    if (numEnvVersion is double) {
      if (numEnvVersion.isNaN || numEnvVersion.isInfinite) {
        _lastLoadCorrupted = true;
        return BlockdagLoadResult.corruptedData(
          'Field schemaVersion pada envelope slot tidak boleh bernilai NaN atau Infinity',
        );
      }
      if (numEnvVersion != numEnvVersion.truncateToDouble()) {
        _lastLoadCorrupted = true;
        return BlockdagLoadResult.corruptedData(
          'Field schemaVersion pada envelope slot tidak boleh bernilai pecahan, ditemukan: $numEnvVersion',
        );
      }
    }
    final envVersion = numEnvVersion.toInt();
    if (envVersion <= 0) {
      _lastLoadCorrupted = true;
      return BlockdagLoadResult.corruptedData(
        'Field schemaVersion pada envelope slot bernilai tidak valid: $envVersion',
      );
    }

    // 2. Validasi field state
    final rawState = envelope['state'];
    if (rawState == null || rawState is! Map) {
      _lastLoadCorrupted = true;
      return BlockdagLoadResult.corruptedData(
        'Field state pada envelope slot hilang atau bukan objek Map',
      );
    }
    final stateMap = Map<String, dynamic>.from(rawState);

    // 3. Validasi schemaVersion di dalam state dan kecocokannya dengan envelope
    final rawStateVersion = stateMap['schemaVersion'];
    if (rawStateVersion == null) {
      _lastLoadCorrupted = true;
      return BlockdagLoadResult.corruptedData(
        'Field schemaVersion hilang dari serialized state di dalam slot',
      );
    }
    if (rawStateVersion is! num) {
      _lastLoadCorrupted = true;
      return BlockdagLoadResult.corruptedData(
        'Field schemaVersion pada state slot harus bertipe numerik integer, ditemukan: ${rawStateVersion.runtimeType}',
      );
    }
    final num numStateVersion = rawStateVersion;
    if (numStateVersion is double) {
      if (numStateVersion.isNaN || numStateVersion.isInfinite) {
        _lastLoadCorrupted = true;
        return BlockdagLoadResult.corruptedData(
          'Field schemaVersion pada state slot tidak boleh bernilai NaN atau Infinity',
        );
      }
      if (numStateVersion != numStateVersion.truncateToDouble()) {
        _lastLoadCorrupted = true;
        return BlockdagLoadResult.corruptedData(
          'Field schemaVersion pada state slot tidak boleh bernilai pecahan, ditemukan: $numStateVersion',
        );
      }
    }
    final stateVersion = numStateVersion.toInt();
    if (stateVersion <= 0) {
      _lastLoadCorrupted = true;
      return BlockdagLoadResult.corruptedData(
        'Field schemaVersion pada state slot bernilai tidak valid: $stateVersion',
      );
    }

    if (envVersion != stateVersion) {
      _lastLoadCorrupted = true;
      return BlockdagLoadResult.corruptedData(
        'Ketidakcocokan versi skema antara envelope ($envVersion) dan isi state ($stateVersion)',
      );
    }

    // 4. Validasi metadata preference jika ada
    int? versionInPrefs;
    try {
      versionInPrefs = prefs.getInt(keySchemaVersion);
    } catch (_) {
      _lastLoadCorrupted = true;
      return BlockdagLoadResult.corruptedData(
        'Nilai keySchemaVersion pada SharedPreferences korup atau bukan integer',
      );
    }
    if (versionInPrefs != null && versionInPrefs != envVersion) {
      _lastLoadCorrupted = true;
      return BlockdagLoadResult.corruptedData(
        'Ketidakcocokan versi skema antara metadata preference ($versionInPrefs) dan isi state ($envVersion)',
      );
    }

    // 5. Validasi integritas checksum SHA-256
    final rawChecksum = envelope['checksum'];
    if (rawChecksum == null ||
        rawChecksum is! String ||
        rawChecksum.trim().isEmpty) {
      _lastLoadCorrupted = true;
      return BlockdagLoadResult.corruptedData(
        'Field checksum hilang atau tidak valid pada envelope slot',
      );
    }
    final computedChecksum = computeSha256(canonicalJsonEncode(stateMap));
    if (rawChecksum != computedChecksum) {
      _lastLoadCorrupted = true;
      return BlockdagLoadResult.corruptedData(
        'Integritas checksum slot aktif gagal: hash payload tidak cocok ($rawChecksum vs $computedChecksum)',
      );
    }

    // 6. Periksa dukungan versi skema
    if (!supportedSchemaVersions.contains(envVersion)) {
      _lastLoadCorrupted = false;
      return BlockdagLoadResult.unsupportedVersion(
        detectedVersion: envVersion,
        message:
            'Versi skema $envVersion tidak didukung oleh aplikasi saat ini (versi didukung: $supportedSchemaVersions)',
      );
    }

    // 7. Deserialisasi objek state
    try {
      final state = BlockdagPersistedState.fromMap(stateMap);
      _lastLoadCorrupted = false;
      return BlockdagLoadResult.success(state);
    } catch (e) {
      _lastLoadCorrupted = true;
      return BlockdagLoadResult.corruptedData(
        'Gagal memvalidasi struktur state BlockDAG: $e',
      );
    }
  }

  /// Pemuatan fallback untuk data legacy (Stage 5E.3.x tanpa dual-slot pointer).
  BlockdagLoadResult _loadLegacyResult(SharedPreferences prefs) {
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

    if (rawVersionInState is! num) {
      _lastLoadCorrupted = true;
      return BlockdagLoadResult.corruptedData(
        'Field schemaVersion harus bertipe numerik integer, ditemukan: ${rawVersionInState.runtimeType}',
      );
    }

    final num numVersionInState = rawVersionInState;
    if (numVersionInState is double) {
      if (numVersionInState.isNaN || numVersionInState.isInfinite) {
        _lastLoadCorrupted = true;
        return BlockdagLoadResult.corruptedData(
          'Field schemaVersion tidak boleh bernilai NaN atau Infinity',
        );
      }
      if (numVersionInState != numVersionInState.truncateToDouble()) {
        _lastLoadCorrupted = true;
        return BlockdagLoadResult.corruptedData(
          'Field schemaVersion tidak boleh bernilai pecahan, ditemukan: $numVersionInState',
        );
      }
    }

    final versionInState = numVersionInState.toInt();
    if (versionInState <= 0) {
      _lastLoadCorrupted = true;
      return BlockdagLoadResult.corruptedData(
        'Field schemaVersion bernilai tidak valid: $versionInState',
      );
    }

    int? versionInPrefs;
    try {
      versionInPrefs = prefs.getInt(keySchemaVersion);
    } catch (_) {
      _lastLoadCorrupted = true;
      return BlockdagLoadResult.corruptedData(
        'Nilai keySchemaVersion pada SharedPreferences korup atau bukan integer',
      );
    }

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

    if (simulateSaveException) {
      throw Exception(
        'Simulated repository write exception (disk I/O failure)',
      );
    }

    try {
      // 1. Tentukan target staging slot (kebalikan dari slot aktif saat ini)
      final currentActive = prefs.getString(keyActiveSlot);
      final targetSlot = (currentActive == slotA) ? slotB : slotA;
      final targetKey = (targetSlot == slotA) ? keySlotA : keySlotB;

      if (simulateStagingWriteFailure) {
        return false;
      }

      // 2. Siapkan envelope kanonikal lengkap dengan checksum SHA-256
      final stateMap = state.toMap();
      final stateCanonicalJson = canonicalJsonEncode(stateMap);
      final checksum = computeSha256(stateCanonicalJson);

      final envelope = <String, dynamic>{
        'schemaVersion': state.schemaVersion,
        'state': stateMap,
        'checksum': checksum,
        'committedAt': DateTime.now().toUtc().toIso8601String(),
      };
      final envelopeJson = jsonEncode(envelope);

      // 3. Tulis envelope ke staging slot yang tidak aktif
      final stagingSuccess = await prefs.setString(targetKey, envelopeJson);
      if (!stagingSuccess) {
        return false;
      }

      if (simulatePointerCommitFailure) {
        return false;
      }

      // 4. Commit Step: Alihkan pointer slot aktif ke staging slot yang baru
      final commitSuccess = await prefs.setString(keyActiveSlot, targetSlot);
      if (!commitSuccess) {
        return false;
      }

      // 5. Sinkronisasi legacy keys untuk kompatibilitas mundur
      try {
        await prefs.setString(keyState, jsonEncode(stateMap));
        await prefs.setInt(keySchemaVersion, state.schemaVersion);
      } catch (_) {
        // Sinkronisasi legacy bersifat best-effort; slot utama sudah ter-commit
      }

      return true;
    } catch (_) {
      // Tangkap kegagalan I/O atau platform channel tanpa membiarkan exception lolos
      return false;
    }
  }

  @override
  Future<bool> clear() async {
    final prefs = await _getPrefs();
    if (prefs == null) return false;

    try {
      await prefs.remove(keyActiveSlot);
      await prefs.remove(keySlotA);
      await prefs.remove(keySlotB);
      await prefs.remove(keyState);
      await prefs.remove(keySchemaVersion);
      return true;
    } catch (_) {
      return false;
    }
  }
}

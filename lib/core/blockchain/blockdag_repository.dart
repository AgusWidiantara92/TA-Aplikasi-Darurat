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

  /// Dua slot penyimpanan memuat state valid yang berbeda tanpa adanya pointer otoritatif;
  /// pemuatan dihentikan untuk mencegah forking atau kehilangan data secara diam-diam.
  ambiguousState,
}

/// Objek hasil operasi pemuatan state dari [BlockdagRepository].
class BlockdagLoadResult {
  final BlockdagLoadStatus status;
  final BlockdagPersistedState? state;
  final String? errorMessage;
  final int? detectedSchemaVersion;
  final bool isRecoveredFromAlternate;
  final String? activeSlot;
  final String? recoveredSlot;

  const BlockdagLoadResult({
    required this.status,
    this.state,
    this.errorMessage,
    this.detectedSchemaVersion,
    this.isRecoveredFromAlternate = false,
    this.activeSlot,
    this.recoveredSlot,
  });

  factory BlockdagLoadResult.success(
    BlockdagPersistedState state, {
    String? activeSlot,
  }) => BlockdagLoadResult(
    status: BlockdagLoadStatus.success,
    state: state,
    activeSlot: activeSlot,
    isRecoveredFromAlternate: false,
  );

  factory BlockdagLoadResult.recoveredAlternate(
    BlockdagPersistedState state, {
    required String recoveredSlot,
    String? message,
  }) => BlockdagLoadResult(
    status: BlockdagLoadStatus.success,
    state: state,
    recoveredSlot: recoveredSlot,
    isRecoveredFromAlternate: true,
    errorMessage: message,
  );

  factory BlockdagLoadResult.ambiguousState([String? message]) =>
      BlockdagLoadResult(
        status: BlockdagLoadStatus.ambiguousState,
        errorMessage: message,
      );

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
  bool get isAmbiguous => status == BlockdagLoadStatus.ambiguousState;
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

/// Status validasi integritas internal untuk satu slot dual-slot.
class _SlotValidation {
  final bool isValid;
  final bool isEmpty;
  final bool isCorrupted;
  final bool isUnsupportedVersion;
  final int? schemaVersion;
  final BlockdagPersistedState? state;
  final String? errorMessage;

  const _SlotValidation({
    required this.isValid,
    this.isEmpty = false,
    this.isCorrupted = false,
    this.isUnsupportedVersion = false,
    this.schemaVersion,
    this.state,
    this.errorMessage,
  });

  factory _SlotValidation.empty() =>
      const _SlotValidation(isValid: false, isEmpty: true);

  factory _SlotValidation.corrupted(String message) =>
      _SlotValidation(isValid: false, isCorrupted: true, errorMessage: message);

  factory _SlotValidation.unsupported(int version, String message) =>
      _SlotValidation(
        isValid: false,
        isUnsupportedVersion: true,
        schemaVersion: version,
        errorMessage: message,
      );

  factory _SlotValidation.valid(BlockdagPersistedState state, int version) =>
      _SlotValidation(isValid: true, state: state, schemaVersion: version);
}

/// Implementasi [BlockdagRepository] menggunakan [SharedPreferences] lokal
/// dengan proteksi Dual-Slot Staged Commit terhadap partial-write failure.
class LocalBlockdagRepository implements BlockdagRepository {
  static const int currentSchemaVersion = 1;
  static const Set<int> supportedSchemaVersions = {1};

  // Kunci preferensi legacy untuk kompatibilitas mundur
  static const String keySchemaVersion = 'siagamesh_blockdag_version';
  static const String keyState = 'siagamesh_blockdag_state';

  // Kunci Dual-Slot Staged Commit (Stage 5E.4.4.2 & 5E.4.4.3)
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

  /// Hook pengujian: simulasi kegagalan verifikasi baca-ulang (read-back verification failure).
  bool simulateReadBackFailure = false;

  /// Hook pengujian: simulasi kegagalan pembaruan commit pointer (setelah staging slot berhasil ditulis).
  bool simulatePointerCommitFailure = false;

  /// Hook pengujian: simulasi exception saat penulisan ke disk (I/O error atau platform channel failure).
  bool simulateSaveException = false;

  /// Melacak slot yang terakhir kali terbukti valid dan memuat state otoritatif.
  String? _authoritativeSlot;

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

    final activeSlot = prefs.getString(keyActiveSlot);

    // KASUS 1: Pointer activeSlot menunjuk ke slot yang valid ('slot_a' atau 'slot_b')
    if (activeSlot == slotA || activeSlot == slotB) {
      final activeKey = (activeSlot == slotA) ? keySlotA : keySlotB;
      final alternateSlot = (activeSlot == slotA) ? slotB : slotA;
      final alternateKey = (alternateSlot == slotA) ? keySlotA : keySlotB;

      final activeVal = _validateSlot(prefs.getString(activeKey), prefs);

      // 1.1 Jika slot aktif valid, gunakan langsung
      if (activeVal.isValid) {
        _authoritativeSlot = activeSlot;
        _lastLoadCorrupted = false;
        return BlockdagLoadResult.success(
          activeVal.state!,
          activeSlot: activeSlot,
        );
      }

      // 1.2 Jika slot aktif memiliki unsupportedVersion, BERHENTI! JANGAN downgrade ke alternate slot!
      if (activeVal.isUnsupportedVersion) {
        _authoritativeSlot = activeSlot;
        _lastLoadCorrupted = false;
        return BlockdagLoadResult.unsupportedVersion(
          detectedVersion: activeVal.schemaVersion!,
          message: activeVal.errorMessage,
        );
      }

      // 1.3 Slot aktif korup atau hilang/kosong: periksa alternate slot untuk pemulihan aman!
      final altVal = _validateSlot(prefs.getString(alternateKey), prefs);
      if (altVal.isValid) {
        _authoritativeSlot = alternateSlot;
        _lastLoadCorrupted = false; // Pemulihan sukses dari alternate slot
        return BlockdagLoadResult.recoveredAlternate(
          altVal.state!,
          recoveredSlot: alternateSlot,
          message:
              'Slot aktif ($activeSlot) ${activeVal.isEmpty ? "kosong/hilang" : "korup"}, berhasil memulihkan snapshot valid dari alternate slot ($alternateSlot)',
        );
      }

      // 1.4 Jika alternate slot juga unsupportedVersion
      if (altVal.isUnsupportedVersion) {
        _authoritativeSlot = alternateSlot;
        _lastLoadCorrupted = false;
        return BlockdagLoadResult.unsupportedVersion(
          detectedVersion: altVal.schemaVersion!,
          message: altVal.errorMessage,
        );
      }

      // 1.5 Kedua slot tidak dapat digunakan (korup atau kosong)
      _lastLoadCorrupted = true;
      if (activeVal.isEmpty && altVal.isEmpty) {
        return BlockdagLoadResult.corruptedData(
          'Slot aktif ($activeSlot) dan alternate slot ($alternateSlot) tidak ditemukan atau kosong',
        );
      }
      return BlockdagLoadResult.corruptedData(
        activeVal.errorMessage ??
            altVal.errorMessage ??
            'Slot aktif ($activeSlot) dan alternate slot ($alternateSlot) keduanya korup',
      );
    }

    // KASUS 2: activeSlot tidak null tetapi nilainya tidak valid (misal: "slot_c", "invalid_slot")
    // ATAU activeSlot == null (instalasi belum termigrasi / pointer hilang)
    final valA = _validateSlot(prefs.getString(keySlotA), prefs);
    final valB = _validateSlot(prefs.getString(keySlotB), prefs);

    // 2.1 Jika kedua slot kosong:
    if (valA.isEmpty && valB.isEmpty) {
      if (activeSlot != null) {
        // Pointer ada tapi stringnya tidak valid, dan tidak ada data slot
        _lastLoadCorrupted = true;
        return BlockdagLoadResult.corruptedData(
          'Nilai keyActiveSlot tidak valid: $activeSlot (harus $slotA atau $slotB)',
        );
      }
      // activeSlot == null dan kedua slot kosong -> periksa format legacy
      return _loadLegacyResult(prefs);
    }

    // 2.2 Jika kedua slot valid:
    if (valA.isValid && valB.isValid) {
      final jsonA = canonicalJsonEncode(valA.state!.toMap());
      final jsonB = canonicalJsonEncode(valB.state!.toMap());
      if (jsonA == jsonB) {
        // Kedua slot identik secara semantik: pulihkan dari slot_a
        _authoritativeSlot = slotA;
        _lastLoadCorrupted = false;
        return BlockdagLoadResult.recoveredAlternate(
          valA.state!,
          recoveredSlot: slotA,
          message:
              'Pointer slot aktif tidak valid atau hilang, kedua slot identik, memulihkan state dari $slotA',
        );
      } else {
        // KEDUA SLOT VALID TAPI MEMUAT STATE BERBEDA: AMBIGUOUS STATE!
        // Berhenti tanpa menimpa penyimpanan atau memicu Genesis fallback.
        _lastLoadCorrupted = false;
        return BlockdagLoadResult.ambiguousState(
          'Pointer slot aktif hilang atau tidak valid ($activeSlot), dan kedua slot ($slotA & $slotB) memuat snapshot valid yang berbeda (state ambigu).',
        );
      }
    }

    // 2.3 Jika salah satu slot valid dan yang lainnya kosong/korup:
    if (valA.isValid && !valB.isValid) {
      _authoritativeSlot = slotA;
      _lastLoadCorrupted = false;
      return BlockdagLoadResult.recoveredAlternate(
        valA.state!,
        recoveredSlot: slotA,
        message:
            'Pointer slot aktif tidak valid atau hilang ($activeSlot), berhasil memulihkan state valid dari $slotA',
      );
    }
    if (valB.isValid && !valA.isValid) {
      _authoritativeSlot = slotB;
      _lastLoadCorrupted = false;
      return BlockdagLoadResult.recoveredAlternate(
        valB.state!,
        recoveredSlot: slotB,
        message:
            'Pointer slot aktif tidak valid atau hilang ($activeSlot), berhasil memulihkan state valid dari $slotB',
      );
    }

    // 2.4 Jika ada slot unsupportedVersion
    if (valA.isUnsupportedVersion) {
      _authoritativeSlot = slotA;
      _lastLoadCorrupted = false;
      return BlockdagLoadResult.unsupportedVersion(
        detectedVersion: valA.schemaVersion!,
        message: valA.errorMessage,
      );
    }
    if (valB.isUnsupportedVersion) {
      _authoritativeSlot = slotB;
      _lastLoadCorrupted = false;
      return BlockdagLoadResult.unsupportedVersion(
        detectedVersion: valB.schemaVersion!,
        message: valB.errorMessage,
      );
    }

    // 2.5 Kedua slot korup
    _lastLoadCorrupted = true;
    return BlockdagLoadResult.corruptedData(
      'Pointer slot aktif tidak valid ($activeSlot) dan kedua slot korup',
    );
  }

  /// Memvalidasi slot: integritas JSON, envelope, schemaVersion, checksum, dan deserialisasi state.
  _SlotValidation _validateSlot(String? rawSlotJson, SharedPreferences prefs) {
    if (rawSlotJson == null || rawSlotJson.trim().isEmpty) {
      return _SlotValidation.empty();
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(rawSlotJson);
    } catch (e) {
      return _SlotValidation.corrupted('Format JSON pada slot korup: $e');
    }

    if (decoded is! Map) {
      return _SlotValidation.corrupted(
        'Format root JSON slot bukan objek Map (tipe: ${decoded.runtimeType})',
      );
    }

    final envelope = Map<String, dynamic>.from(decoded);

    // 1. Validasi schemaVersion pada envelope
    final rawEnvVersion = envelope['schemaVersion'];
    if (rawEnvVersion == null) {
      return _SlotValidation.corrupted(
        'Field schemaVersion hilang dari envelope slot',
      );
    }
    if (rawEnvVersion is! num) {
      return _SlotValidation.corrupted(
        'Field schemaVersion pada envelope slot harus bertipe numerik integer, ditemukan: ${rawEnvVersion.runtimeType}',
      );
    }
    final num numEnvVersion = rawEnvVersion;
    if (numEnvVersion is double) {
      if (numEnvVersion.isNaN || numEnvVersion.isInfinite) {
        return _SlotValidation.corrupted(
          'Field schemaVersion pada envelope slot tidak boleh bernilai NaN atau Infinity',
        );
      }
      if (numEnvVersion != numEnvVersion.truncateToDouble()) {
        return _SlotValidation.corrupted(
          'Field schemaVersion pada envelope slot tidak boleh bernilai pecahan, ditemukan: $numEnvVersion',
        );
      }
    }
    final envVersion = numEnvVersion.toInt();
    if (envVersion <= 0) {
      return _SlotValidation.corrupted(
        'Field schemaVersion pada envelope slot bernilai tidak valid: $envVersion',
      );
    }

    // 2. Validasi field state
    final rawState = envelope['state'];
    if (rawState == null || rawState is! Map) {
      return _SlotValidation.corrupted(
        'Field state pada envelope slot hilang atau bukan objek Map',
      );
    }
    final stateMap = Map<String, dynamic>.from(rawState);

    // 3. Validasi schemaVersion di dalam state dan kecocokannya dengan envelope
    final rawStateVersion = stateMap['schemaVersion'];
    if (rawStateVersion == null) {
      return _SlotValidation.corrupted(
        'Field schemaVersion hilang dari serialized state di dalam slot',
      );
    }
    if (rawStateVersion is! num) {
      return _SlotValidation.corrupted(
        'Field schemaVersion pada state slot harus bertipe numerik integer, ditemukan: ${rawStateVersion.runtimeType}',
      );
    }
    final num numStateVersion = rawStateVersion;
    if (numStateVersion is double) {
      if (numStateVersion.isNaN || numStateVersion.isInfinite) {
        return _SlotValidation.corrupted(
          'Field schemaVersion pada state slot tidak boleh bernilai NaN atau Infinity',
        );
      }
      if (numStateVersion != numStateVersion.truncateToDouble()) {
        return _SlotValidation.corrupted(
          'Field schemaVersion pada state slot tidak boleh bernilai pecahan, ditemukan: $numStateVersion',
        );
      }
    }
    final stateVersion = numStateVersion.toInt();
    if (stateVersion <= 0) {
      return _SlotValidation.corrupted(
        'Field schemaVersion pada state slot bernilai tidak valid: $stateVersion',
      );
    }

    if (envVersion != stateVersion) {
      return _SlotValidation.corrupted(
        'Ketidakcocokan versi skema antara envelope ($envVersion) dan isi state ($stateVersion)',
      );
    }

    // 4. Validasi metadata preference jika ada
    int? versionInPrefs;
    try {
      versionInPrefs = prefs.getInt(keySchemaVersion);
    } catch (_) {
      return _SlotValidation.corrupted(
        'Nilai keySchemaVersion pada SharedPreferences korup atau bukan integer',
      );
    }
    if (versionInPrefs != null && versionInPrefs != envVersion) {
      return _SlotValidation.corrupted(
        'Ketidakcocokan versi skema antara metadata preference ($versionInPrefs) dan isi state ($envVersion)',
      );
    }

    // 5. Validasi integritas checksum SHA-256
    final rawChecksum = envelope['checksum'];
    if (rawChecksum == null ||
        rawChecksum is! String ||
        rawChecksum.trim().isEmpty) {
      return _SlotValidation.corrupted(
        'Field checksum hilang atau tidak valid pada envelope slot',
      );
    }
    final computedChecksum = computeSha256(canonicalJsonEncode(stateMap));
    if (rawChecksum != computedChecksum) {
      return _SlotValidation.corrupted(
        'Integritas checksum slot aktif gagal: hash payload tidak cocok ($rawChecksum vs $computedChecksum)',
      );
    }

    // 6. Periksa dukungan versi skema
    if (!supportedSchemaVersions.contains(envVersion)) {
      return _SlotValidation.unsupported(
        envVersion,
        'Versi skema $envVersion tidak didukung oleh aplikasi saat ini (versi didukung: $supportedSchemaVersions)',
      );
    }

    // 7. Deserialisasi objek state
    try {
      final state = BlockdagPersistedState.fromMap(stateMap);
      return _SlotValidation.valid(state, envVersion);
    } catch (e) {
      return _SlotValidation.corrupted(
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
      // 1. Tentukan target staging slot (kebalikan dari slot otoritatif saat ini)
      String baseSlot;
      if (_authoritativeSlot == slotA || _authoritativeSlot == slotB) {
        baseSlot = _authoritativeSlot!;
      } else {
        final currentActive = prefs.getString(keyActiveSlot);
        if (currentActive == slotA || currentActive == slotB) {
          final activeKey = (currentActive == slotA) ? keySlotA : keySlotB;
          final activeVal = _validateSlot(prefs.getString(activeKey), prefs);
          if (activeVal.isValid) {
            baseSlot = currentActive!;
          } else {
            final altSlot = (currentActive == slotA) ? slotB : slotA;
            final altKey = (altSlot == slotA) ? keySlotA : keySlotB;
            final altVal = _validateSlot(prefs.getString(altKey), prefs);
            if (altVal.isValid) {
              baseSlot = altSlot;
            } else {
              baseSlot = currentActive!;
            }
          }
        } else {
          baseSlot = slotB; // sehingga targetSlot awal menjadi slotA
        }
      }

      final targetSlot = (baseSlot == slotA) ? slotB : slotA;
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

      // 4. Staged Commit Read-Back Verification (Stage 5E.4.4.3)
      if (simulateReadBackFailure) {
        return false;
      }

      final readBackJson = prefs.getString(targetKey);
      if (readBackJson == null || readBackJson.trim().isEmpty) {
        return false;
      }

      final readBackVal = _validateSlot(readBackJson, prefs);
      if (!readBackVal.isValid || readBackVal.state == null) {
        return false;
      }

      final readBackCanonical = canonicalJsonEncode(readBackVal.state!.toMap());
      if (readBackCanonical != stateCanonicalJson) {
        return false;
      }

      if (simulatePointerCommitFailure) {
        return false;
      }

      // 5. Commit Step: Alihkan pointer slot aktif ke staging slot yang baru diverifikasi
      final commitSuccess = await prefs.setString(keyActiveSlot, targetSlot);
      if (!commitSuccess) {
        return false;
      }
      _authoritativeSlot = targetSlot;

      // 6. Sinkronisasi legacy keys untuk kompatibilitas mundur
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
    _authoritativeSlot = null;
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

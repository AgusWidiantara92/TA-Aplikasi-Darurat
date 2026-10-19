/// Repositori penyimpanan lokal persisten untuk BlockDAG Ledger SiagaMesh.
///
/// Bertanggung jawab untuk:
/// 1. Menyimpan dan memulihkan seluruh state aktif ledger (blok, checkpoint, tips, dan antrean event).
/// 2. Menjaga isolasi data dengan versi skema data eksplisit.
/// 3. Menangani kegagalan I/O dan korupsi data secara aman tanpa menyebabkan crash.
library;

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'blockchain_types.dart';

/// Kontrak repositori persistensi untuk BlockDAG ledger.
abstract class BlockdagRepository {
  /// Memuat state ledger dari penyimpanan persisten.
  /// Mengembalikan `null` jika data belum ada atau jika terjadi kerusakan format data.
  Future<BlockdagPersistedState?> loadState();

  /// Menyimpan seluruh state aktif ledger secara persisten.
  /// Mengembalikan `true` jika penyimpanan berhasil, atau `false` jika penulisan gagal.
  Future<bool> saveState(BlockdagPersistedState state);

  /// Menghapus seluruh data ledger lokal yang tersimpan (untuk pengujian atau reset sesi).
  Future<bool> clear();

  /// Menandakan apakah proses [loadState] terakhir mendeteksi data korup/rusak di disk.
  bool get lastLoadCorrupted => false;
}

/// Implementasi [BlockdagRepository] menggunakan [SharedPreferences] lokal.
class LocalBlockdagRepository implements BlockdagRepository {
  static const int currentSchemaVersion = 1;
  static const String keySchemaVersion = 'siagamesh_blockdag_version';
  static const String keyState = 'siagamesh_blockdag_state';

  final SharedPreferences? _injectedPreferences;
  bool _lastLoadCorrupted = false;

  LocalBlockdagRepository({SharedPreferences? preferences})
    : _injectedPreferences = preferences;

  @override
  bool get lastLoadCorrupted => _lastLoadCorrupted;

  Future<SharedPreferences?> _getPrefs() async {
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
  Future<BlockdagPersistedState?> loadState() async {
    _lastLoadCorrupted = false;
    final prefs = await _getPrefs();
    if (prefs == null) return null;

    final rawJson = prefs.getString(keyState);
    if (rawJson == null || rawJson.trim().isEmpty) {
      return null;
    }

    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is Map<String, dynamic>) {
        return BlockdagPersistedState.fromMap(decoded);
      } else if (decoded is Map) {
        return BlockdagPersistedState.fromMap(
          Map<String, dynamic>.from(decoded),
        );
      }
      _lastLoadCorrupted = true;
      return null;
    } catch (_) {
      // Penanganan eksplisit jika file atau format JSON di disk korup:
      // Catat status korupsi dan kembalikan null secara aman agar pemanggil dapat meregenerasi state baru.
      _lastLoadCorrupted = true;
      return null;
    }
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

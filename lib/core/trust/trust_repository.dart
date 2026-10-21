import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Kontrak repositori penyimpanan persisten untuk subsistem Dynamic Trust.
abstract class TrustRepository {
  /// Menyimpan seluruh state reputasi node secara persisten.
  Future<bool> saveState(Map<String, dynamic> state);

  /// Memuat state reputasi tersimpan dari penyimpanan persisten.
  Future<Map<String, dynamic>?> loadState();

  /// Menghapus seluruh data reputasi yang tersimpan.
  Future<bool> clear();
}

/// Implementasi [TrustRepository] berbasis [SharedPreferences] lokal.
class LocalTrustRepository implements TrustRepository {
  static const int currentSchemaVersion = 1;
  static const String keyTrustState = 'siagamesh_trust_state_v1';

  final SharedPreferences? _injectedPreferences;

  LocalTrustRepository({SharedPreferences? preferences})
    : _injectedPreferences = preferences;

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
  Future<bool> saveState(Map<String, dynamic> state) async {
    try {
      final prefs = await _getPrefs();
      if (prefs == null) return false;
      return await prefs.setString(keyTrustState, jsonEncode(state));
    } catch (_) {
      return false;
    }
  }

  @override
  Future<Map<String, dynamic>?> loadState() async {
    try {
      final prefs = await _getPrefs();
      if (prefs == null) return null;
      final raw = prefs.getString(keyTrustState);
      if (raw == null || raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> clear() async {
    try {
      final prefs = await _getPrefs();
      if (prefs == null) return false;
      return await prefs.remove(keyTrustState);
    } catch (_) {
      return false;
    }
  }
}

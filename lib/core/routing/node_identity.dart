import 'dart:async';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';

/// Representasi identitas node aplikasi SiagaMesh yang stabil dan terpisah
/// dari identitas endpoint sementara lapisan transport nirkabel.
class NodeIdentity {
  final String id;
  final String name;

  const NodeIdentity({required this.id, required this.name});

  /// Mengembalikan suffix 4 karakter kapital dari ID node (contoh: `#A7F2`).
  String get shortId {
    if (id.length <= 4) return id.toUpperCase();
    return id.substring(id.length - 4).toUpperCase();
  }

  /// Nama ramah pengguna yang ditampilkan pada UI (contoh: "Agus", "Infinix").
  String get displayName => name;

  /// Memformat nama tampilan dengan suffix pendek node ID jika terdapat nama duplikat.
  static String formatDisplayName(
    String peerName,
    String? nodeId, {
    String? endpointId,
    bool isDuplicate = false,
  }) {
    final clean = peerName.trim();
    if (!isDuplicate) return clean;
    final suffix = (nodeId != null && nodeId.trim().isNotEmpty)
        ? (nodeId.length >= 4
              ? nodeId.substring(nodeId.length - 4).toUpperCase()
              : nodeId.toUpperCase())
        : (endpointId != null && endpointId.length >= 4
              ? endpointId.substring(endpointId.length - 4).toUpperCase()
              : endpointId ?? '');
    return suffix.isNotEmpty ? '$clean (#$suffix)' : clean;
  }

  /// Sanitasi nama perangkat: menghapus karakter kontrol, membatasi panjang
  /// maksimal 24 karakter, dan merapikan spasi berlebih.
  static String sanitizeDeviceName(
    String rawName, {
    required String fallbackDefault,
  }) {
    // Ganti whitespace tabs dan newlines dengan spasi terlebih dahulu
    var cleaned = rawName.replaceAll(RegExp(r'[\t\r\n]'), ' ');
    // Hapus karakter kontrol ASCII (0x00-0x1F, 0x7F)
    cleaned = cleaned.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '');
    // Rapatkan spasi ganda dan trim
    cleaned = cleaned.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (cleaned.isEmpty) {
      return fallbackDefault;
    }
    if (cleaned.length > 24) {
      cleaned = cleaned.substring(0, 24).trim();
    }
    return cleaned;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NodeIdentity &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'NodeIdentity(id: $id, name: $name)';
}

/// Pengelola identitas node lokal persisten.
///
/// Menyimpan identitas ke [SharedPreferences] agar konsisten lintas sesi restart
/// aplikasi, dan mendukung pembaruan nama perangkat yang ramah pengguna secara dinamis.
class NodeIdentityManager {
  static const String keyNodeId = 'siagamesh_local_node_id';
  static const String keyNodeName = 'siagamesh_local_node_name';

  final SharedPreferences? _prefs;
  late NodeIdentity _currentIdentity;
  final StreamController<NodeIdentity> _identityController =
      StreamController<NodeIdentity>.broadcast();

  NodeIdentityManager({
    SharedPreferences? prefs,
    String? overrideId,
    String? overrideName,
  }) : _prefs = prefs {
    if (overrideId != null) {
      final defaultName =
          'SiagaMesh-${overrideId.length >= 4 ? overrideId.substring(overrideId.length - 4).toUpperCase() : overrideId.toUpperCase()}';
      _currentIdentity = NodeIdentity(
        id: overrideId,
        name: overrideName ?? defaultName,
      );
    } else {
      _initIdentity();
    }
  }

  void _initIdentity() {
    final savedId = _prefs?.getString(keyNodeId);
    final savedName = _prefs?.getString(keyNodeName);

    if (savedId != null && savedId.isNotEmpty) {
      final defaultName =
          'SiagaMesh-${savedId.length >= 4 ? savedId.substring(savedId.length - 4).toUpperCase() : savedId.toUpperCase()}';
      _currentIdentity = NodeIdentity(
        id: savedId,
        name: savedName != null && savedName.trim().isNotEmpty
            ? savedName.trim()
            : defaultName,
      );
    } else {
      // Buat identitas acak yang stabil
      final randomHex = Random()
          .nextInt(0xFFFFFF)
          .toRadixString(16)
          .padLeft(6, '0');
      final newId = 'node-$randomHex';
      final newName =
          'SiagaMesh-${newId.substring(newId.length - 4).toUpperCase()}';

      _currentIdentity = NodeIdentity(id: newId, name: newName);
      _prefs?.setString(keyNodeId, newId);
      _prefs?.setString(keyNodeName, newName);
    }
  }

  /// Stream pembaruan identitas lokal saat nama perangkat diubah pengguna.
  Stream<NodeIdentity> get identityStream => _identityController.stream;

  NodeIdentity get currentIdentity => _currentIdentity;

  String get localNodeId => _currentIdentity.id;

  String get localNodeName => _currentIdentity.name;

  String get displayName => _currentIdentity.name;

  String get shortNodeId => _currentIdentity.shortId;

  /// Memperbarui nama tampilan perangkat (displayName).
  ///
  /// Nama akan disanitasi (maksimal 24 karakter, tanpa karakter kontrol, spasi dirapikan).
  /// Disimpan ke [SharedPreferences] dan memancarkan pembaruan ke [identityStream].
  Future<String> updateDisplayName(String newName) async {
    final defaultFallback =
        'SiagaMesh-${localNodeId.length >= 4 ? localNodeId.substring(localNodeId.length - 4).toUpperCase() : localNodeId.toUpperCase()}';
    final sanitized = NodeIdentity.sanitizeDeviceName(
      newName,
      fallbackDefault: defaultFallback,
    );

    _currentIdentity = NodeIdentity(id: _currentIdentity.id, name: sanitized);

    if (_prefs != null) {
      await _prefs.setString(keyNodeName, sanitized);
    } else {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(keyNodeName, sanitized);
      } catch (_) {}
    }

    if (!_identityController.isClosed) {
      _identityController.add(_currentIdentity);
    }

    return sanitized;
  }

  /// Memuat ulang data dari [SharedPreferences] jika diperbarui secara eksternal.
  Future<void> reloadFromPrefs() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    final savedId = prefs.getString(keyNodeId);
    final savedName = prefs.getString(keyNodeName);
    if (savedId != null && savedId.isNotEmpty) {
      final defaultName =
          'SiagaMesh-${savedId.length >= 4 ? savedId.substring(savedId.length - 4).toUpperCase() : savedId.toUpperCase()}';
      _currentIdentity = NodeIdentity(
        id: savedId,
        name: savedName != null && savedName.trim().isNotEmpty
            ? savedName.trim()
            : defaultName,
      );
      if (!_identityController.isClosed) {
        _identityController.add(_currentIdentity);
      }
    }
  }

  void dispose() {
    _identityController.close();
  }
}

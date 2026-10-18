import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';

/// Representasi identitas node aplikasi SiagaMesh yang stabil dan terpisah
/// dari identitas endpoint sementara lapisan transport nirkabel.
class NodeIdentity {
  final String id;
  final String name;

  const NodeIdentity({required this.id, required this.name});

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
/// aplikasi, dan mendukung penetapan ID/Nama secara eksplisit untuk pengujian unit.
class NodeIdentityManager {
  static const String keyNodeId = 'siagamesh_local_node_id';
  static const String keyNodeName = 'siagamesh_local_node_name';

  final SharedPreferences? _prefs;
  late NodeIdentity _currentIdentity;

  NodeIdentityManager({
    SharedPreferences? prefs,
    String? overrideId,
    String? overrideName,
  }) : _prefs = prefs {
    if (overrideId != null) {
      _currentIdentity = NodeIdentity(
        id: overrideId,
        name: overrideName ?? 'SiagaMesh-$overrideId',
      );
    } else {
      _initIdentity();
    }
  }

  void _initIdentity() {
    final savedId = _prefs?.getString(keyNodeId);
    final savedName = _prefs?.getString(keyNodeName);

    if (savedId != null && savedId.isNotEmpty) {
      _currentIdentity = NodeIdentity(
        id: savedId,
        name: savedName ?? 'SiagaMesh-${savedId.substring(savedId.length - 4)}',
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

  NodeIdentity get currentIdentity => _currentIdentity;

  String get localNodeId => _currentIdentity.id;

  String get localNodeName => _currentIdentity.name;
}

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../../core/constants/app_colors.dart';
import '../../models/chat_conversation.dart';
import '../../models/chat_message.dart';

/// Kontrak repositori untuk pengelolaan percakapan dan pesan SiagaMesh.
abstract class ChatRepository {
  /// Mengambil seluruh percakapan yang tersimpan secara lokal.
  Future<List<ChatConversation>> getConversations();

  /// Mengambil seluruh pesan untuk ID percakapan tertentu.
  Future<List<ChatMessage>> getMessages(String conversationId);

  /// Menyimpan pesan baru ke dalam percakapan dan memperbarui ringkasan percakapan.
  Future<void> saveMessage(String conversationId, ChatMessage message);

  /// Mencari percakapan yang berasosiasi dengan node mesh tertentu, atau membuatnya jika belum ada.
  Future<ChatConversation> getOrCreateConversationForNode({
    required String nodeId,
    required String nodeName,
    bool isEmergency = false,
    bool isConnected = true,
  });

  /// Mencari atau membuat percakapan kanal siaran darurat lokal.
  Future<ChatConversation> getOrCreateBroadcastConversation();

  /// Menghapus seluruh data lokal percakapan dan pesan (untuk pengujian atau reset).
  Future<void> clearAllData();
}

/// Implementasi [ChatRepository] lokal dengan cache memori dan penyimpanan persisten via [SharedPreferences].
class LocalChatRepository implements ChatRepository {
  static const int currentSchemaVersion = 1;
  static const String keySchemaVersion = 'siagamesh_schema_version';
  static const String keyConversations = 'siagamesh_conversations';
  static const String keyMessagesPrefix = 'siagamesh_messages_';

  final SharedPreferences? _injectedPreferences;
  bool _isLoadedFromDisk = false;

  late List<ChatConversation> _conversationsCache;
  final Map<String, List<ChatMessage>> _messagesCache = {};

  LocalChatRepository({SharedPreferences? preferences})
    : _injectedPreferences = preferences {
    _conversationsCache = [];
    _initFromDisk();
  }

  // --- Seed Data Bawaan (Kosong secara default, hanya pesan riil yang disimpan) ---
  static const List<ChatConversation> defaultConversations = [];

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

  Future<void> _initFromDisk() async {
    final prefs = await _getPrefs();
    if (prefs == null) {
      _isLoadedFromDisk = true;
      return;
    }

    try {
      final rawConvJson = prefs.getString(keyConversations);
      if (rawConvJson != null && rawConvJson.trim().isNotEmpty) {
        final decoded = jsonDecode(rawConvJson);
        if (decoded is List) {
          // Bersihkan data dummy bawaan lama jika pernah tersimpan di cache disk
          _conversationsCache = decoded
              .whereType<Map<String, dynamic>>()
              .map((item) => ChatConversation.fromJson(item))
              .where(
                (c) => !const {
                  'conv-1',
                  'conv-2',
                  'conv-3',
                  'conv-4',
                }.contains(c.id),
              )
              .toList();
        }
      }
    } catch (_) {
      // Penanganan jika JSON korup: tetap gunakan cache memori yang aman
      _conversationsCache = [];
    } finally {
      _isLoadedFromDisk = true;
    }
  }

  @override
  Future<List<ChatConversation>> getConversations() async {
    if (!_isLoadedFromDisk) {
      await _initFromDisk();
    }
    return List<ChatConversation>.from(_conversationsCache);
  }

  @override
  Future<List<ChatMessage>> getMessages(String conversationId) async {
    if (!_isLoadedFromDisk) {
      await _initFromDisk();
    }

    if (_messagesCache.containsKey(conversationId)) {
      return List<ChatMessage>.from(_messagesCache[conversationId]!);
    }

    final prefs = await _getPrefs();
    if (prefs != null) {
      final key = '$keyMessagesPrefix$conversationId';
      final rawJson = prefs.getString(key);
      if (rawJson != null && rawJson.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(rawJson);
          if (decoded is List) {
            final msgs = decoded
                .whereType<Map<String, dynamic>>()
                .map((item) => ChatMessage.fromJson(item))
                .toList();
            _messagesCache[conversationId] = msgs;
            return List<ChatMessage>.from(msgs);
          }
        } catch (_) {}
      }
    }

    _messagesCache[conversationId] = [];
    return [];
  }

  @override
  Future<void> saveMessage(String conversationId, ChatMessage message) async {
    final currentMessages = _messagesCache.putIfAbsent(
      conversationId,
      () => [],
    );
    currentMessages.add(message);

    final summaryText = message.text.isNotEmpty
        ? message.text
        : (message.telemetryData != null
              ? '[Data Telemetri Lokasi]'
              : 'Pesan Darurat');

    final index = _conversationsCache.indexWhere((c) => c.id == conversationId);
    if (index != -1) {
      _conversationsCache[index] = _conversationsCache[index].copyWith(
        lastMessage: summaryText,
        time: message.time,
      );
    }

    final prefs = await _getPrefs();
    if (prefs != null) {
      await _persistMessages(prefs, conversationId, currentMessages);
      await _persistConversations(prefs);
    }
  }

  @override
  Future<ChatConversation> getOrCreateConversationForNode({
    required String nodeId,
    required String nodeName,
    bool isEmergency = false,
    bool isConnected = true,
  }) async {
    final targetId = 'conv-node-$nodeId';
    for (final conv in _conversationsCache) {
      if (conv.peerNodeId == nodeId || conv.id == targetId) {
        return conv;
      }
    }

    final newConv = ChatConversation(
      id: targetId,
      title: nodeName,
      nodeId: 'Node: #${nodeId.toUpperCase()}',
      peerNodeId: nodeId,
      lastMessage: 'Belum ada pesan',
      time: 'Baru saja',
      unreadCount: 0,
      badgeText: isEmergency ? 'DARURAT' : 'Node Sekitar',
      badgeBgColor: isEmergency
          ? AppColors.emergencyRed
          : AppColors.surfaceSubtle,
      badgeTextColor: isEmergency ? Colors.white : AppColors.primaryNavy,
      statusLabel: isConnected ? 'Tersambung' : 'Tersedia',
      isEmergency: isEmergency,
      isConnectedNode: isConnected,
    );

    _conversationsCache.add(newConv);
    _messagesCache[targetId] = [];

    final prefs = await _getPrefs();
    if (prefs != null) {
      await _persistConversations(prefs);
    }

    return newConv;
  }

  @override
  Future<ChatConversation> getOrCreateBroadcastConversation() async {
    const broadcastId = 'broadcast-all';
    for (final conv in _conversationsCache) {
      if (conv.id == broadcastId) {
        return conv;
      }
    }

    const broadcastConv = ChatConversation(
      id: broadcastId,
      title: 'Siaran Darurat Lokal',
      nodeId: 'Broadcast ID: #ALL-NODES',
      lastMessage: '',
      time: 'Sekarang',
      badgeText: 'SIARAN',
      badgeBgColor: AppColors.accentPillBg,
      badgeTextColor: AppColors.accentBlue,
      statusLabel: 'Siaran',
      isEmergency: true,
      isConnectedNode: true,
    );

    _conversationsCache.add(broadcastConv);
    _messagesCache[broadcastId] = [];

    final prefs = await _getPrefs();
    if (prefs != null) {
      await _persistConversations(prefs);
    }

    return broadcastConv;
  }

  @override
  Future<void> clearAllData() async {
    _conversationsCache = [];
    _messagesCache.clear();

    final prefs = await _getPrefs();
    if (prefs != null) {
      final keys = prefs.getKeys();
      for (final key in keys) {
        if (key.startsWith('siagamesh_')) {
          await prefs.remove(key);
        }
      }
    }
  }

  Future<void> _persistConversations(SharedPreferences prefs) async {
    try {
      await prefs.setInt(keySchemaVersion, currentSchemaVersion);
      final jsonList = _conversationsCache.map((c) => c.toJson()).toList();
      await prefs.setString(keyConversations, jsonEncode(jsonList));
    } catch (_) {}
  }

  Future<void> _persistMessages(
    SharedPreferences prefs,
    String conversationId,
    List<ChatMessage> list,
  ) async {
    try {
      await prefs.setInt(keySchemaVersion, currentSchemaVersion);
      final key = '$keyMessagesPrefix$conversationId';
      final jsonList = list.map((m) => m.toJson()).toList();
      await prefs.setString(key, jsonEncode(jsonList));
    } catch (_) {}
  }
}

/// Tempat penyimpanan instance singleton [ChatRepository] aplikasi.
class ChatRepositoryHolder {
  static ChatRepository? _instance;

  static ChatRepository get instance => _instance ??= LocalChatRepository();

  static void setInstance(ChatRepository? repo) {
    _instance = repo;
  }
}

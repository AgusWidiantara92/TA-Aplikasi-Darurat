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
    _conversationsCache = List<ChatConversation>.from(defaultConversations);
    _initFromDisk();
  }

  // --- Seed Data Bawaan ---

  static final List<ChatConversation> defaultConversations = [
    const ChatConversation(
      id: 'conv-1',
      title: 'Posko Medis Darurat',
      nodeId: 'Node ID: #MED-0041',
      peerNodeId: 'node-med-0041',
      lastMessage: 'Ambulans darurat sedang menuju titik koordinat...',
      time: '10:33',
      unreadCount: 1,
      badgeText: 'DARURAT',
      badgeBgColor: AppColors.emergencyRed,
      badgeTextColor: Colors.white,
      statusLabel: 'Darurat',
      isEmergency: true,
      isConnectedNode: true,
    ),
    const ChatConversation(
      id: 'conv-2',
      title: 'Tim SAR Wilayah II',
      nodeId: 'Node ID: #SAR-0012',
      peerNodeId: 'node-sar-0012',
      lastMessage: 'Konfirmasi: Rute evakuasi jembatan timur aman dilalui...',
      time: '10:14',
      badgeText: 'Terverifikasi',
      badgeBgColor: AppColors.accentPillBg,
      badgeTextColor: AppColors.accentBlue,
      statusLabel: 'Dibaca',
      isConnectedNode: true,
    ),
    const ChatConversation(
      id: 'conv-3',
      title: 'Ahmed Fauzi',
      nodeId: 'Jarak: 35 meter',
      peerNodeId: 'node-ahmed-fauzi',
      lastMessage: 'Kami memiliki cadangan air bersih di blok C...',
      time: '09:48',
      badgeText: 'Dekat Anda',
      badgeBgColor: AppColors.surfaceSubtle,
      badgeTextColor: AppColors.primaryNavy,
      statusLabel: 'Terkirim',
      isConnectedNode: true,
    ),
    const ChatConversation(
      id: 'conv-4',
      title: 'Relawan Dapur Umum',
      nodeId: 'Saluran Komunitas',
      lastMessage: 'Distribusi logistik tahap pertama dimulai pukul 11:00...',
      time: '08:15',
      badgeText: 'Pengumuman',
      badgeBgColor: AppColors.surfaceSubtle,
      badgeTextColor: AppColors.textSecondary,
      statusLabel: 'Selesai',
      isConnectedNode: false,
    ),
  ];

  static final List<ChatMessage> defaultConv1Messages = [
    const ChatMessage(
      id: 'm1',
      senderName: 'Posko SAR Unit 1',
      text:
          'Halo! Kami mendeteksi sinyal SOS dari perangkat Anda di radius 350 meter. Apakah ada korban yang memerlukan pertolongan darurat?',
      time: '10:30',
      isMe: false,
      relayInfo: 'Ditransmisi melalui multi-hop relay #01 (Simulasi)',
    ),
    const ChatMessage(
      id: 'm2',
      senderName: 'Anda',
      text:
          'Benar, ada 2 orang lansia dan 1 balita membutuhkan evakuasi perahu karet karena air sudah mencapai 1.5 meter.',
      time: '10:32',
      isMe: true,
      statusText: 'Terkirim • E2E Confirmed (Simulasi)',
    ),
    const ChatMessage(
      id: 'm3',
      senderName: 'Anda',
      text: 'Data Telemetri Koordinat Lokasi Darurat',
      time: '10:32',
      isMe: true,
      telemetryData: TelemetryData(
        locationName: 'SDN 01 Pagi (Lantai 2)',
        latitude: -6.2088,
        longitude: 106.8456,
        accuracy: 'Akurasi GPS Medis: ±5m (Simulasi)',
        priority: 'PRIORITAS TINGGI',
        validationInfo: 'Validasi Lewat: Berhasil (Simulasi)',
      ),
    ),
    const ChatMessage(
      id: 'm4',
      senderName: 'Posko SAR Unit 1',
      text:
          'Informasi diterima. Perahu evakuasi No. 04 sedang meluncur ke titik SDN 01. Harap tetap di titik tertinggi.',
      time: '10:33',
      isMe: false,
      relayInfo: 'Terverifikasi Konsensus SAR Lapangan (Simulasi)',
    ),
  ];

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
    if (prefs == null) return;

    try {
      final rawConvJson = prefs.getString(keyConversations);
      if (rawConvJson != null && rawConvJson.trim().isNotEmpty) {
        final decoded = jsonDecode(rawConvJson);
        if (decoded is List) {
          _conversationsCache = decoded
              .whereType<Map<String, dynamic>>()
              .map((item) => ChatConversation.fromJson(item))
              .toList();
        }
      } else {
        await _persistConversations(prefs);
      }

      final conv1Key =
          '$keyMessagesPrefix'
          'conv-1';
      final rawConv1 = prefs.getString(conv1Key);
      if (rawConv1 != null && rawConv1.trim().isNotEmpty) {
        final decoded = jsonDecode(rawConv1);
        if (decoded is List) {
          _messagesCache['conv-1'] = decoded
              .whereType<Map<String, dynamic>>()
              .map((item) => ChatMessage.fromJson(item))
              .toList();
        }
      } else {
        await _persistMessages(prefs, 'conv-1', defaultConv1Messages);
      }
    } catch (_) {
      // Penanganan jika JSON korup: tetap gunakan cache memori yang aman
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

    if (conversationId == 'conv-1') {
      _messagesCache[conversationId] = List<ChatMessage>.from(
        defaultConv1Messages,
      );
      return List<ChatMessage>.from(defaultConv1Messages);
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
      title: 'Siaran Darurat Lokal (Simulasi)',
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
    _conversationsCache = List<ChatConversation>.from(defaultConversations);
    _messagesCache.clear();
    _messagesCache['conv-1'] = List<ChatMessage>.from(defaultConv1Messages);

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

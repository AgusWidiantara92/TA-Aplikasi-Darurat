import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../../core/constants/app_colors.dart';
import '../../models/chat_conversation.dart';
import '../../models/chat_message.dart';

/// Tipe peristiwa perubahan data pada ChatRepository.
enum ChatChangeType {
  conversationCreated,
  conversationUpdated,
  conversationDeleted,
  messageAdded,
  messageUpdated,
  messageDeleted,
  conversationRead,
  dataCleared,
}

/// Model peristiwa perubahan repository untuk keperluan reaktivitas granular & diagnostik.
class ChatRepositoryEvent {
  final ChatChangeType type;
  final String conversationId;
  final String? messageId;
  final DateTime timestamp;

  ChatRepositoryEvent({
    required this.type,
    required this.conversationId,
    this.messageId,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

/// Kontrak repositori untuk pengelolaan percakapan dan pesan SiagaMesh.
abstract class ChatRepository {
  /// Stream pembaruan daftar percakapan secara real-time.
  Stream<List<ChatConversation>> get conversationsStream =>
      const Stream.empty();

  /// Stream peristiwa perubahan repository untuk reaktivitas granular & audit log.
  Stream<ChatRepositoryEvent> get repositoryEventsStream =>
      const Stream.empty();

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

  /// Menghapus percakapan dan seluruh riwayat pesan lokalnya tanpa merusak identitas node atau trust.
  Future<bool> deleteConversation(String conversationId) async => false;

  /// Menghapus pesan dari percakapan berdasarkan ID dan memperbarui ringkasan percakapan.
  Future<bool> deleteMessage(String conversationId, String messageId);

  /// Memperbarui status teks pesan (misalnya saat menerima ACK).
  Future<bool> updateMessageStatus(
    String conversationId,
    String messageId,
    String newStatusText,
  ) async => false;

  /// Menandai seluruh pesan dalam percakapan sebagai terbaca (mereset unreadCount).
  Future<void> markConversationAsRead(String conversationId) async {}

  /// Menghapus seluruh data lokal percakapan dan pesan (untuk pengujian atau reset).
  Future<void> clearAllData();

  /// Melepaskan sumber daya stream controller jika diperlukan.
  void dispose() {}
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

  final StreamController<List<ChatConversation>>
  _conversationsStreamController =
      StreamController<List<ChatConversation>>.broadcast();
  final StreamController<ChatRepositoryEvent> _repositoryEventsController =
      StreamController<ChatRepositoryEvent>.broadcast();

  LocalChatRepository({SharedPreferences? preferences})
    : _injectedPreferences = preferences {
    _conversationsCache = [];
    _initFromDisk();
  }

  // --- Seed Data Bawaan (Kosong secara default, hanya pesan riil yang disimpan) ---
  static const List<ChatConversation> defaultConversations = [];

  @override
  Stream<List<ChatConversation>> get conversationsStream =>
      _conversationsStreamController.stream;

  @override
  Stream<ChatRepositoryEvent> get repositoryEventsStream =>
      _repositoryEventsController.stream;

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

  void _sortConversations() {
    _conversationsCache.sort((a, b) {
      final aTs = a.lastActivityTimestamp ?? 0;
      final bTs = b.lastActivityTimestamp ?? 0;
      if (aTs != bTs) {
        return bTs.compareTo(aTs);
      }
      return 0;
    });
  }

  void _notifyConversationsChanged([ChatRepositoryEvent? event]) {
    _sortConversations();
    if (!_conversationsStreamController.isClosed) {
      _conversationsStreamController.add(
        List<ChatConversation>.unmodifiable(_conversationsCache),
      );
    }
    if (event != null && !_repositoryEventsController.isClosed) {
      _repositoryEventsController.add(event);
    }
  }

  void _logDiag({
    required String stage,
    required String convId,
    String? msgId,
    bool? isMe,
    String? status,
    String? extra,
  }) {
    debugPrint(
      '[SiagaMesh-Diag] Stage=$stage | convId=$convId'
      '${msgId != null ? ' | msgId=$msgId' : ''}'
      '${isMe != null ? ' | isMe=$isMe' : ''}'
      '${status != null ? ' | status=$status' : ''}'
      '${extra != null ? ' | extra=$extra' : ''}',
    );
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
          _sortConversations();
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
    if (!_isLoadedFromDisk) {
      await _initFromDisk();
    }

    // Pastikan seluruh riwayat disk terhubung di memori agar tidak tertimpa
    List<ChatMessage> currentMessages;
    if (_messagesCache.containsKey(conversationId)) {
      currentMessages = _messagesCache[conversationId]!;
    } else {
      currentMessages = await getMessages(conversationId);
      _messagesCache[conversationId] = currentMessages;
    }

    // Deduplikasi pesan berdasarkan ID agar event ganda tidak menambah baris pesan duplikat
    final existingIdx = currentMessages.indexWhere((m) => m.id == message.id);
    if (existingIdx != -1) {
      currentMessages[existingIdx] = message;
    } else {
      currentMessages.add(message);
    }

    final summaryText = message.text.isNotEmpty
        ? message.text
        : (message.telemetryData != null
              ? '[Data Telemetri Lokasi]'
              : 'Pesan Darurat');

    final nowMs = DateTime.now().millisecondsSinceEpoch;

    // Temukan atau buat entitas percakapan di daftar percakapan
    int convIdx = _conversationsCache.indexWhere((c) => c.id == conversationId);
    if (convIdx == -1) {
      if (conversationId == 'broadcast-all' || conversationId == 'broadcast') {
        final bcast = await getOrCreateBroadcastConversation();
        convIdx = _conversationsCache.indexWhere((c) => c.id == bcast.id);
      } else {
        final cleanId = conversationId.replaceFirst('conv-node-', '');
        final nodeConv = await getOrCreateConversationForNode(
          nodeId: cleanId,
          nodeName:
              message.senderName.isNotEmpty && message.senderName != 'Anda'
              ? message.senderName
              : 'Node #$cleanId',
          isEmergency: message.isEmergency,
        );
        convIdx = _conversationsCache.indexWhere((c) => c.id == nodeConv.id);
      }
    }

    if (convIdx != -1) {
      final existingConv = _conversationsCache.removeAt(convIdx);
      final updatedConv = existingConv.copyWith(
        lastMessage: summaryText,
        time: message.time,
        isEmergency: message.isEmergency ? true : existingConv.isEmergency,
        unreadCount: (!message.isMe)
            ? (existingConv.unreadCount + 1)
            : existingConv.unreadCount,
        lastActivityTimestamp: nowMs,
      );
      // Pindahkan percakapan yang baru aktif ke urutan teratas
      _conversationsCache.insert(0, updatedConv);
    }

    final prefs = await _getPrefs();
    if (prefs != null) {
      await _persistMessages(prefs, conversationId, currentMessages);
      await _persistConversations(prefs);
    }

    _logDiag(
      stage: 'REPO_SAVE_MESSAGE',
      convId: conversationId,
      msgId: message.id,
      isMe: message.isMe,
      status: message.statusText,
    );

    _notifyConversationsChanged(
      ChatRepositoryEvent(
        type: existingIdx != -1
            ? ChatChangeType.messageUpdated
            : ChatChangeType.messageAdded,
        conversationId: conversationId,
        messageId: message.id,
      ),
    );
  }

  @override
  Future<bool> deleteConversation(String conversationId) async {
    if (!_isLoadedFromDisk) {
      await _initFromDisk();
    }

    final index = _conversationsCache.indexWhere(
      (c) => c.id.toLowerCase() == conversationId.toLowerCase(),
    );
    if (index == -1) return false;

    final removedConv = _conversationsCache.removeAt(index);
    final targetId = removedConv.id;

    // Bersihkan riwayat pesan dari cache memori
    _messagesCache.remove(targetId);
    _messagesCache.remove(conversationId);

    // Bersihkan riwayat dari penyimpanan persisten SharedPreferences
    final prefs = await _getPrefs();
    if (prefs != null) {
      await _persistConversations(prefs);
      await prefs.remove('$keyMessagesPrefix$targetId');
      if (targetId.toLowerCase() != conversationId.toLowerCase()) {
        await prefs.remove('$keyMessagesPrefix$conversationId');
      }
    }

    _logDiag(
      stage: 'REPO_DELETE_CONVERSATION',
      convId: targetId,
      status: 'DELETED',
    );

    _notifyConversationsChanged(
      ChatRepositoryEvent(
        type: ChatChangeType.conversationDeleted,
        conversationId: targetId,
      ),
    );

    return true;
  }

  @override
  Future<bool> deleteMessage(String conversationId, String messageId) async {
    if (!_isLoadedFromDisk) {
      await _initFromDisk();
    }

    final currentMessages = _messagesCache.containsKey(conversationId)
        ? _messagesCache[conversationId]!
        : await getMessages(conversationId);

    final initialCount = currentMessages.length;
    currentMessages.removeWhere((m) => m.id == messageId);
    final removed = currentMessages.length < initialCount;

    if (removed) {
      final index = _conversationsCache.indexWhere(
        (c) => c.id == conversationId,
      );
      if (index != -1) {
        if (currentMessages.isNotEmpty) {
          final lastMsg = currentMessages.last;
          final summaryText = lastMsg.text.isNotEmpty
              ? lastMsg.text
              : (lastMsg.telemetryData != null
                    ? '[Data Telemetri Lokasi]'
                    : 'Pesan Darurat');
          _conversationsCache[index] = _conversationsCache[index].copyWith(
            lastMessage: summaryText,
            time: lastMsg.time,
            lastActivityTimestamp: DateTime.now().millisecondsSinceEpoch,
          );
        } else {
          _conversationsCache[index] = _conversationsCache[index].copyWith(
            lastMessage: 'Belum ada pesan',
            time: 'Baru saja',
          );
        }
      }

      final prefs = await _getPrefs();
      if (prefs != null) {
        await _persistMessages(prefs, conversationId, currentMessages);
        await _persistConversations(prefs);
      }

      _notifyConversationsChanged(
        ChatRepositoryEvent(
          type: ChatChangeType.messageDeleted,
          conversationId: conversationId,
          messageId: messageId,
        ),
      );
    }

    return removed;
  }

  @override
  Future<bool> updateMessageStatus(
    String conversationId,
    String messageId,
    String newStatusText,
  ) async {
    if (!_isLoadedFromDisk) {
      await _initFromDisk();
    }

    // 1. Cari pada conversationId yang diberikan (atau variasi case-insensitive)
    String resolvedConvId = conversationId;
    if (!_messagesCache.containsKey(conversationId)) {
      for (final key in _messagesCache.keys) {
        if (key.toLowerCase() == conversationId.toLowerCase()) {
          resolvedConvId = key;
          break;
        }
      }
    }

    List<ChatMessage> currentMessages =
        _messagesCache.containsKey(resolvedConvId)
        ? _messagesCache[resolvedConvId]!
        : await getMessages(resolvedConvId);

    int index = currentMessages.indexWhere((m) => m.id == messageId);

    // 2. Jika tidak ditemukan pada conversationId tersebut, cari di seluruh cache percakapan (karena messageId unik)
    if (index == -1) {
      for (final entry in _messagesCache.entries) {
        final foundIdx = entry.value.indexWhere((m) => m.id == messageId);
        if (foundIdx != -1) {
          resolvedConvId = entry.key;
          currentMessages = entry.value;
          index = foundIdx;
          break;
        }
      }
    }

    if (index != -1) {
      currentMessages[index] = currentMessages[index].copyWith(
        statusText: newStatusText,
      );

      final prefs = await _getPrefs();
      if (prefs != null) {
        await _persistMessages(prefs, resolvedConvId, currentMessages);
      }

      _logDiag(
        stage: 'REPO_UPDATE_STATUS',
        convId: resolvedConvId,
        msgId: messageId,
        status: newStatusText,
      );

      _notifyConversationsChanged(
        ChatRepositoryEvent(
          type: ChatChangeType.messageUpdated,
          conversationId: resolvedConvId,
          messageId: messageId,
        ),
      );
      return true;
    }
    return false;
  }

  @override
  Future<ChatConversation> getOrCreateConversationForNode({
    required String nodeId,
    required String nodeName,
    bool isEmergency = false,
    bool isConnected = true,
    String? endpointId,
  }) async {
    if (!_isLoadedFromDisk) {
      await _initFromDisk();
    }

    // Normalisasi nodeId: bersihkan display prefix 'Node: #' jika ada
    final cleanNodeId = nodeId
        .replaceFirst(RegExp(r'^Node:\s*#?', caseSensitive: false), '')
        .trim();
    final targetId = 'conv-node-$cleanNodeId';

    // 1. Cari percakapan kanonis yang sudah ada secara case-insensitive
    for (int i = 0; i < _conversationsCache.length; i++) {
      final conv = _conversationsCache[i];
      if (conv.peerNodeId?.toLowerCase() == cleanNodeId.toLowerCase() ||
          conv.id.toLowerCase() == targetId.toLowerCase() ||
          conv.nodeId.toLowerCase() == cleanNodeId.toLowerCase()) {
        final updated = conv.copyWith(
          title: nodeName.isNotEmpty ? nodeName : conv.title,
          peerNodeId: cleanNodeId,
          isConnectedNode: isConnected,
          statusLabel: isConnected ? 'Tersambung' : conv.statusLabel,
          isEmergency: isEmergency ? true : conv.isEmergency,
        );
        _conversationsCache[i] = updated;
        _notifyConversationsChanged(
          ChatRepositoryEvent(
            type: ChatChangeType.conversationUpdated,
            conversationId: updated.id,
          ),
        );
        return updated;
      }
    }

    // 2. Periksa apakah ada percakapan sementara ('peer-$ep' atau 'pending-$ep')
    // yang dapat dimigrasikan secara aman ke canonical node ID ini
    if (!cleanNodeId.startsWith('peer-') &&
        !cleanNodeId.startsWith('pending-')) {
      for (int i = 0; i < _conversationsCache.length; i++) {
        final conv = _conversationsCache[i];
        final pId = conv.peerNodeId ?? '';
        final isTemp =
            pId.startsWith('peer-') ||
            pId.startsWith('pending-') ||
            conv.id.startsWith('conv-node-peer-');
        if (!isTemp) continue;

        // Cocokkan berdasarkan endpointId jika ada
        bool isMatch = false;
        if (endpointId != null && endpointId.isNotEmpty) {
          isMatch =
              pId == 'peer-$endpointId' ||
              pId == 'pending-$endpointId' ||
              conv.id == 'conv-node-peer-$endpointId';
        }

        // Jika endpointId tidak disediakan langsung, periksa kesesuaian nama
        // asalkan tidak ada konflik dengan entri kanonis lain
        if (!isMatch && endpointId == null) {
          if (conv.title.toLowerCase() == nodeName.toLowerCase() &&
              nodeName.isNotEmpty) {
            isMatch = true;
          }
        }

        if (isMatch) {
          final oldId = conv.id;
          final updated = conv.copyWith(
            id: targetId,
            peerNodeId: cleanNodeId,
            nodeId: 'Node: #${cleanNodeId.toUpperCase()}',
            isConnectedNode: isConnected,
            statusLabel: isConnected ? 'Tersambung' : conv.statusLabel,
            isEmergency: isEmergency ? true : conv.isEmergency,
          );
          _conversationsCache[i] = updated;

          // Migrasikan riwayat pesan tanpa duplikasi & pertahankan urutan serta status E2E ACK
          final existingTargetMsgs =
              _messagesCache[targetId] ?? await getMessages(targetId);
          final oldMsgs =
              _messagesCache.remove(oldId) ?? await getMessages(oldId);

          final Map<String, ChatMessage> dedupedMap = {};
          for (final m in oldMsgs) {
            dedupedMap[m.id] = m;
          }
          for (final m in existingTargetMsgs) {
            if (dedupedMap.containsKey(m.id)) {
              final prev = dedupedMap[m.id]!;
              final mHasAck = m.statusText?.contains('ACK') ?? false;
              final prevHasAck = prev.statusText?.contains('ACK') ?? false;
              if (mHasAck && !prevHasAck) {
                dedupedMap[m.id] = m;
              }
            } else {
              dedupedMap[m.id] = m;
            }
          }

          final mergedMessages = dedupedMap.values.toList();
          _messagesCache[targetId] = mergedMessages;

          if (mergedMessages.isNotEmpty) {
            final lastMsg = mergedMessages.last;
            final summaryText = lastMsg.text.isNotEmpty
                ? lastMsg.text
                : (lastMsg.telemetryData != null
                      ? '[Data Telemetri Lokasi]'
                      : 'Pesan Darurat');
            _conversationsCache[i] = updated.copyWith(
              lastMessage: summaryText,
              time: lastMsg.time,
            );
          }

          final prefs = await _getPrefs();
          if (prefs != null) {
            await _persistConversations(prefs);
            final keyOld = '$keyMessagesPrefix$oldId';
            await prefs.remove(keyOld);
            await _persistMessages(prefs, targetId, mergedMessages);
          }

          _notifyConversationsChanged(
            ChatRepositoryEvent(
              type: ChatChangeType.conversationUpdated,
              conversationId: updated.id,
            ),
          );
          return _conversationsCache[i];
        }
      }
    }

    // 3. Buat percakapan baru dengan peerNodeId riil
    final newConv = ChatConversation(
      id: targetId,
      title: nodeName,
      nodeId: 'Node: #${cleanNodeId.toUpperCase()}',
      peerNodeId: cleanNodeId,
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
      lastActivityTimestamp: DateTime.now().millisecondsSinceEpoch,
    );

    _conversationsCache.add(newConv);
    _messagesCache.putIfAbsent(targetId, () => []);

    final prefs = await _getPrefs();
    if (prefs != null) {
      await _persistConversations(prefs);
    }

    _notifyConversationsChanged(
      ChatRepositoryEvent(
        type: ChatChangeType.conversationCreated,
        conversationId: newConv.id,
      ),
    );

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

    final broadcastConv = ChatConversation(
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
      lastActivityTimestamp: DateTime.now().millisecondsSinceEpoch,
    );

    _conversationsCache.add(broadcastConv);
    _messagesCache.putIfAbsent(broadcastId, () => []);

    final prefs = await _getPrefs();
    if (prefs != null) {
      await _persistConversations(prefs);
    }

    _notifyConversationsChanged(
      ChatRepositoryEvent(
        type: ChatChangeType.conversationCreated,
        conversationId: broadcastConv.id,
      ),
    );

    return broadcastConv;
  }

  @override
  Future<void> markConversationAsRead(String conversationId) async {
    if (!_isLoadedFromDisk) {
      await _initFromDisk();
    }

    final index = _conversationsCache.indexWhere((c) => c.id == conversationId);
    if (index != -1 && _conversationsCache[index].unreadCount > 0) {
      _conversationsCache[index] = _conversationsCache[index].copyWith(
        unreadCount: 0,
      );
      final prefs = await _getPrefs();
      if (prefs != null) {
        await _persistConversations(prefs);
      }
      _notifyConversationsChanged(
        ChatRepositoryEvent(
          type: ChatChangeType.conversationRead,
          conversationId: conversationId,
        ),
      );
    }
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

    _notifyConversationsChanged(
      ChatRepositoryEvent(type: ChatChangeType.dataCleared, conversationId: ''),
    );
  }

  @override
  void dispose() {
    _conversationsStreamController.close();
    _repositoryEventsController.close();
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

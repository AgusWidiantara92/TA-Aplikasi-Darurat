import 'dart:async';
import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/routing/node_identity.dart';
import '../../../core/widgets/app_header.dart';
import '../../../core/widgets/siagamesh_dialog.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/repositories/chat_repository.dart';
import '../models/chat_conversation.dart';
import '../models/chat_message.dart';
import 'chat_detail_screen.dart';

/// Layar Daftar Percakapan SiagaMesh yang bersih, ringkas, dan ramah pengguna.
class ChatListScreen extends StatefulWidget {
  final ChatRepository? repository;

  const ChatListScreen({super.key, this.repository});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  late ChatRepository _repository;
  StreamSubscription<List<ChatConversation>>? _conversationsSub;
  final TextEditingController _searchController = TextEditingController();
  List<ChatConversation> _conversations = [];
  int _selectedFilterIndex = 0;

  final List<String> _filters = const [
    'Semua',
    'Pesan Darurat',
    'Node Terhubung',
  ];

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? ChatRepositoryHolder.instance;
    _conversations = [];
    _loadConversations();
    _subscribeToConversations();
  }

  void _subscribeToConversations() {
    _conversationsSub?.cancel();
    _conversationsSub = _repository.conversationsStream.listen((updatedList) {
      if (!mounted) return;
      setState(() {
        _conversations = updatedList;
      });
      debugPrint(
        '[SiagaMesh-Diag] ChatListScreen updated from stream: count=${updatedList.length}',
      );
    });
  }

  @override
  void didUpdateWidget(covariant ChatListScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.repository != oldWidget.repository) {
      _repository = widget.repository ?? ChatRepositoryHolder.instance;
      _loadConversations();
      _subscribeToConversations();
    }
  }

  Future<void> _loadConversations() async {
    final loaded = await _repository.getConversations();
    if (!mounted) return;
    setState(() {
      _conversations = loaded;
    });
  }

  List<ChatConversation> get _filteredConversations {
    final query = _searchController.text.toLowerCase();
    return _conversations.where((conv) {
      final matchesQuery =
          conv.title.toLowerCase().contains(query) ||
          conv.lastMessage.toLowerCase().contains(query) ||
          conv.nodeId.toLowerCase().contains(query);

      if (!matchesQuery) return false;

      if (_selectedFilterIndex == 1) {
        return conv.isEmergency;
      } else if (_selectedFilterIndex == 2) {
        return conv.isConnectedNode;
      }
      return true;
    }).toList();
  }

  String _getInitials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts[0].isEmpty) return '?';
    if (parts.length == 1) {
      final w = parts[0];
      return w.substring(0, w.length >= 2 ? 2 : 1).toUpperCase();
    }
    return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
  }

  void _openChatDetail(
    ChatConversation conversation, {
    List<ChatMessage>? initialMessages,
  }) async {
    // Reset status unread saat membuka percakapan
    _repository.markConversationAsRead(conversation.id);

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatDetailScreen(
          conversationId: conversation.id,
          conversationTitle: conversation.title,
          nodeId: conversation.nodeId,
          peerNodeId: conversation.peerNodeId ?? conversation.nodeId,
          isEmergency: conversation.isEmergency,
          initialMessages: initialMessages,
          repository: _repository,
        ),
      ),
    );
    _loadConversations();
  }

  void _confirmDeleteConversation(ChatConversation conv) {
    SiagaMeshDialog.show(
      context: context,
      icon: Icons.delete_outline_rounded,
      iconColor: AppColors.emergencyRed,
      title: 'Hapus Percakapan?',
      message:
          'Seluruh riwayat pesan percakapan dengan "${conv.title}" akan dihapus dari penyimpanan lokal. Identitas node dan kunci jaringan tetap aman.',
      actions: [
        SiagaMeshDialogAction(
          label: 'Hapus',
          isPrimary: true,
          onPressed: () async {
            Navigator.pop(context);
            await _repository.deleteConversation(conv.id);
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Percakapan "${conv.title}" berhasil dihapus.'),
                duration: const Duration(seconds: 2),
              ),
            );
          },
        ),
        SiagaMeshDialogAction(
          label: 'Batal',
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _conversationsSub?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Hitung kemunculan nama untuk mendeteksi nama duplikat
    final nameCounts = <String, int>{};
    for (final c in _conversations) {
      final key = c.title.trim().toLowerCase();
      nameCounts[key] = (nameCounts[key] ?? 0) + 1;
    }

    final filtered = _filteredConversations;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // Header Utama
            const AppHeader(),

            // Konten Scrollable
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 84),
                children: [
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Jaringan Komunikasi Darurat Offline',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ),
                  // Kolom Pencarian
                  TextField(
                    controller: _searchController,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: 'Cari percakapan atau kontak...',
                      prefixIcon: const Icon(
                        Icons.search,
                        size: 20,
                        color: AppColors.textMuted,
                      ),
                      suffixIcon: _searchController.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 18),
                              onPressed: () {
                                _searchController.clear();
                                setState(() {});
                              },
                            )
                          : null,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),

                  // Filter Chips Ringkas
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: List.generate(_filters.length, (index) {
                        final isSelected = _selectedFilterIndex == index;
                        return Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(
                              _filters[index],
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: isSelected
                                    ? FontWeight.bold
                                    : FontWeight.w500,
                                color: isSelected
                                    ? Colors.white
                                    : AppColors.textSecondary,
                              ),
                            ),
                            selected: isSelected,
                            selectedColor: AppColors.primaryNavy,
                            backgroundColor: AppColors.surface,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            onSelected: (selected) {
                              if (selected) {
                                setState(() => _selectedFilterIndex = index);
                              }
                            },
                          ),
                        );
                      }),
                    ),
                  ),

                  const SizedBox(height: 12),

                  if (_conversations.isEmpty) ...[
                    // Empty State Bersih
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        vertical: 36,
                        horizontal: 20,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: AppColors.borderLight),
                      ),
                      child: Column(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: const BoxDecoration(
                              color: AppColors.surfaceSubtle,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.chat_bubble_outline_rounded,
                              size: 36,
                              color: AppColors.textMuted,
                            ),
                          ),
                          const SizedBox(height: 14),
                          const Text(
                            'Belum ada pesan',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: AppColors.primaryNavy,
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'Belum ada riwayat percakapan darurat atau siaran lokal yang tersimpan.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.textSecondary,
                              height: 1.4,
                            ),
                          ),
                          const SizedBox(height: 18),
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 22,
                                vertical: 12,
                              ),
                              backgroundColor: AppColors.primaryNavy,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            onPressed: () async {
                              final broadcastConv = await _repository
                                  .getOrCreateBroadcastConversation();
                              if (!mounted) return;
                              _openChatDetail(broadcastConv);
                            },
                            icon: const Icon(
                              Icons.add_comment_outlined,
                              size: 18,
                            ),
                            label: const Text(
                              'Buat Pesan Baru',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ] else ...[
                    // Daftar Percakapan Ramah Pengguna
                    ...filtered.map((conv) {
                      final isBroadcast =
                          conv.id == 'broadcast-all' || conv.id == 'broadcast';
                      final isDup =
                          (nameCounts[conv.title.trim().toLowerCase()] ?? 0) >
                          1;
                      final displayTitle = NodeIdentity.formatDisplayName(
                        conv.title,
                        conv.peerNodeId,
                        isDuplicate: isDup,
                      );
                      final initials = isBroadcast
                          ? '📢'
                          : _getInitials(conv.title);

                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: AppColors.borderLight),
                        ),
                        child: InkWell(
                          onTap: () => _openChatDetail(conv),
                          onLongPress: () => _confirmDeleteConversation(conv),
                          borderRadius: BorderRadius.circular(14),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                // Avatar Berinisial
                                CircleAvatar(
                                  radius: 20,
                                  backgroundColor: isBroadcast
                                      ? AppColors.emergencyRed
                                      : AppColors.primaryNavy,
                                  child: Text(
                                    initials,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                // Detail Percakapan
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          Flexible(
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Flexible(
                                                  child: Text(
                                                    displayTitle,
                                                    style: const TextStyle(
                                                      fontSize: 14,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      color:
                                                          AppColors.primaryNavy,
                                                    ),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ),
                                                const SizedBox(width: 6),
                                                StatusBadge(
                                                  label: isBroadcast
                                                      ? 'SIARAN'
                                                      : (conv.isConnectedNode
                                                            ? 'TERHUBUNG'
                                                            : 'NODE'),
                                                  backgroundColor: isBroadcast
                                                      ? AppColors
                                                            .emergencyRedLight
                                                      : (conv.isConnectedNode
                                                            ? AppColors
                                                                  .successGreenLight
                                                            : AppColors
                                                                  .surfaceSubtle),
                                                  textColor: isBroadcast
                                                      ? AppColors.emergencyRed
                                                      : (conv.isConnectedNode
                                                            ? AppColors
                                                                  .successGreen
                                                            : AppColors
                                                                  .textSecondary),
                                                  fontSize: 9,
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 6,
                                                        vertical: 2,
                                                      ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          Text(
                                            conv.time,
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: conv.isEmergency
                                                  ? AppColors.emergencyRed
                                                  : AppColors.textMuted,
                                              fontWeight: conv.isEmergency
                                                  ? FontWeight.bold
                                                  : FontWeight.normal,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        conv.lastMessage.isNotEmpty
                                            ? conv.lastMessage
                                            : 'Belum ada pesan',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: AppColors.textPrimary,
                                          height: 1.3,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                                if (conv.unreadCount > 0) ...[
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: AppColors.primaryNavy,
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      '${conv.unreadCount}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      );
                    }),

                    if (filtered.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 28),
                        child: Center(
                          child: Column(
                            children: [
                              Icon(
                                Icons.search_off,
                                size: 32,
                                color: AppColors.textMuted,
                              ),
                              SizedBox(height: 6),
                              Text(
                                'Tidak ada percakapan ditemukan',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                    const SizedBox(height: 10),

                    // Tombol Tambah Pesan Baru
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        backgroundColor: AppColors.primaryNavy,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () async {
                        final broadcastConv = await _repository
                            .getOrCreateBroadcastConversation();
                        if (!mounted) return;
                        _openChatDetail(broadcastConv);
                      },
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Buat Pesan Baru'),
                    ),
                  ],

                  const SizedBox(height: 16),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

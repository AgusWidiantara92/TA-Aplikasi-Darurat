import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/widgets/app_header.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/repositories/chat_repository.dart';
import '../models/chat_conversation.dart';
import '../models/chat_message.dart';
import 'chat_detail_screen.dart';

/// Layar Daftar Pesan sesuai referensi Layar 3 pada desain.jpg.
class ChatListScreen extends StatefulWidget {
  final ChatRepository? repository;

  const ChatListScreen({super.key, this.repository});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  int _selectedFilterIndex = 0;
  final TextEditingController _searchController = TextEditingController();

  late ChatRepository _repository;
  late List<ChatConversation> _conversations;

  final List<String> _filters = const [
    'Semua (4)',
    'Pesan Darurat (1)',
    'Node Terhubung',
  ];

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? ChatRepositoryHolder.instance;
    _conversations = List<ChatConversation>.from(
      LocalChatRepository.defaultConversations,
    );
    _loadConversations();
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

  void _openChatDetail(
    ChatConversation conversation, {
    List<ChatMessage>? initialMessages,
  }) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatDetailScreen(
          conversationId: conversation.id,
          conversationTitle: conversation.title,
          nodeId: conversation.nodeId,
          isEmergency: conversation.isEmergency,
          initialMessages: initialMessages,
          repository: _repository,
        ),
      ),
    );
    _loadConversations();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  // Banner Protokol SiagaMesh
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.primaryNavy,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '• PROTOKOL SIAGAMESH AKTIF',
                                style: TextStyle(
                                  color: AppColors.accentCyan,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                              ),
                              const SizedBox(height: 3),
                              const Text(
                                'Jaringan Komunikasi Darurat Offline',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                'Pesan offline langsung antar-perangkat via Nearby Connections tanpa internet.',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.75),
                                  fontSize: 11,
                                  height: 1.3,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.12),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.cell_tower,
                            color: AppColors.accentCyan,
                            size: 20,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Kolom Pencarian
                  TextField(
                    controller: _searchController,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: 'Cari percakapan atau ID perangkat...',
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
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Filter Chips
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
                              borderRadius: BorderRadius.circular(20),
                              side: BorderSide(
                                color: isSelected
                                    ? AppColors.primaryNavy
                                    : AppColors.borderLight,
                              ),
                            ),
                            showCheckmark: false,
                            onSelected: (val) {
                              if (val) {
                                setState(() {
                                  _selectedFilterIndex = index;
                                });
                              }
                            },
                          ),
                        );
                      }),
                    ),
                  ),

                  const SizedBox(height: 12),

                  // List Item Percakapan
                  ..._filteredConversations.map((conv) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: InkWell(
                        onTap: () => _openChatDetail(conv),
                        borderRadius: BorderRadius.circular(16),
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: AppColors.surface,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: AppColors.borderLight),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Expanded(
                                    child: Row(
                                      children: [
                                        Flexible(
                                          child: Text(
                                            conv.title,
                                            style: const TextStyle(
                                              fontSize: 15,
                                              fontWeight: FontWeight.bold,
                                              color: AppColors.primaryNavy,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        StatusBadge(
                                          label: conv.badgeText,
                                          backgroundColor: conv.badgeBgColor,
                                          textColor: conv.badgeTextColor,
                                          fontSize: 10,
                                          padding: const EdgeInsets.symmetric(
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
                              const SizedBox(height: 6),
                              Text(
                                conv.lastMessage,
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: AppColors.textPrimary,
                                  height: 1.3,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 10),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    conv.nodeId,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: AppColors.textMuted,
                                    ),
                                  ),
                                  if (conv.unreadCount > 0)
                                    Container(
                                      padding: const EdgeInsets.all(6),
                                      decoration: const BoxDecoration(
                                        color: AppColors.primaryNavy,
                                        shape: BoxShape.circle,
                                      ),
                                      child: Text(
                                        '${conv.unreadCount}',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    )
                                  else if (conv.statusLabel != null)
                                    Text(
                                      conv.statusLabel!,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: AppColors.textSecondary,
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }),

                  if (_filteredConversations.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 36),
                      child: Center(
                        child: Column(
                          children: [
                            Icon(
                              Icons.search_off,
                              size: 36,
                              color: AppColors.textMuted,
                            ),
                            SizedBox(height: 8),
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

                  const SizedBox(height: 12),

                  // Tombol Buat Pesan Baru
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      backgroundColor: AppColors.primaryNavy,
                    ),
                    onPressed: () async {
                      final broadcastConv = await _repository
                          .getOrCreateBroadcastConversation();
                      if (!mounted) return;
                      _openChatDetail(broadcastConv);
                    },
                    child: const Text('Buat Pesan Baru'),
                  ),

                  const SizedBox(height: 20),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

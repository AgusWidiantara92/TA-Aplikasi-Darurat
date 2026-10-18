import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/widgets/app_header.dart';
import '../../../core/widgets/status_badge.dart';
import '../models/chat_conversation.dart';
import '../models/chat_message.dart';
import 'chat_detail_screen.dart';

/// Layar Daftar Pesan sesuai referensi Layar 3 pada desain.jpg.
class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  int _selectedFilterIndex = 0;
  final TextEditingController _searchController = TextEditingController();

  final List<String> _filters = const [
    'Semua (4)',
    'Pesan Darurat (1)',
    'Node Terhubung',
  ];

  final List<ChatConversation> _conversations = const [
    ChatConversation(
      id: 'conv-1',
      title: 'Posko Medis Darurat',
      nodeId: 'Node ID: #MED-0041',
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
    ChatConversation(
      id: 'conv-2',
      title: 'Tim SAR Wilayah II',
      nodeId: 'Node ID: #SAR-0012',
      lastMessage: 'Konfirmasi: Rute evakuasi jembatan timur aman dilalui...',
      time: '10:14',
      badgeText: 'Terverifikasi',
      badgeBgColor: AppColors.accentPillBg,
      badgeTextColor: AppColors.accentBlue,
      statusLabel: 'Dibaca',
      isConnectedNode: true,
    ),
    ChatConversation(
      id: 'conv-3',
      title: 'Ahmed Fauzi',
      nodeId: 'Jarak: 35 meter',
      lastMessage: 'Kami memiliki cadangan air bersih di blok C...',
      time: '09:48',
      badgeText: 'Dekat Anda',
      badgeBgColor: AppColors.surfaceSubtle,
      badgeTextColor: AppColors.primaryNavy,
      statusLabel: 'Terkirim',
      isConnectedNode: true,
    ),
    ChatConversation(
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
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatDetailScreen(
          conversationTitle: conversation.title,
          nodeId: conversation.nodeId,
          isEmergency: conversation.isEmergency,
          initialMessages: initialMessages,
        ),
      ),
    );
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
                  // Banner Protokol SiagaMesh (Penjelasan Simulasi)
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
                                'Jaringan Darurat Offline (Demo UI)',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                'Pesan terkirim langsung antar ponsel tanpa internet (Simulasi UI). Komunikasi radio fisik belum diimplementasikan.',
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
                    onPressed: () {
                      _openChatDetail(
                        const ChatConversation(
                          id: 'new-conv',
                          title: 'Siaran Darurat Lokal (Simulasi)',
                          nodeId: 'Broadcast ID: #ALL-NODES',
                          lastMessage: '',
                          time: 'Sekarang',
                          badgeText: 'SIARAN',
                          badgeBgColor: AppColors.accentPillBg,
                          badgeTextColor: AppColors.accentBlue,
                        ),
                        initialMessages: const [],
                      );
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

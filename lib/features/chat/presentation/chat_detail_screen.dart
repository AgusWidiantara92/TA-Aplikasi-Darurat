import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/widgets/status_badge.dart';
import '../models/chat_message.dart';

/// Layar Detail Percakapan sesuai referensi Layar 2 pada desain.jpg.
class ChatDetailScreen extends StatefulWidget {
  final String conversationTitle;
  final String nodeId;
  final bool isEmergency;

  const ChatDetailScreen({
    super.key,
    required this.conversationTitle,
    required this.nodeId,
    this.isEmergency = false,
  });

  @override
  State<ChatDetailScreen> createState() => _ChatDetailScreenState();
}

class _ChatDetailScreenState extends State<ChatDetailScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  late List<ChatMessage> _messages;

  @override
  void initState() {
    super.initState();
    _messages = [
      const ChatMessage(
        id: 'm1',
        senderName: 'Posko SAR Unit 1',
        text:
            'Halo! Kami mendeteksi sinyal SOS dari perangkat Anda di radius 350 meter. Apakah ada korban yang memerlukan pertolongan darurat?',
        time: '10:11',
        isMe: false,
        relayInfo: 'Diteruskan melalui Node Daisy-401 (Simulasi)',
      ),
      const ChatMessage(
        id: 'm2',
        senderName: 'Anda',
        text:
            'Benar, ada 2 orang lansia dan 1 balita membutuhkan evakuasi perahu karet karena air sudah mencapai 1.5 meter.',
        time: '10:12',
        isMe: true,
        statusText: 'Tersimpan Lokal (Simulasi) • E2E Mock',
      ),
      const ChatMessage(
        id: 'm3',
        senderName: 'Anda',
        text: 'Data Telemetri Koordinat Lokasi Darurat',
        time: '10:12',
        isMe: true,
        telemetryData: TelemetryData(
          locationName: 'SDN 01 Pagi (Lantai 2)',
          latitude: -6.2088,
          longitude: 106.8456,
          accuracy: '<4m (Simulasi)',
          priority: 'PRIORITAS TINGGI',
          validationInfo: 'Lewat 3 Berbagi (Simulasi)',
        ),
      ),
      const ChatMessage(
        id: 'm4',
        senderName: 'Posko SAR Unit 1',
        text:
            'Informasi diterima. Perahu evakuasi No. 04 sedang meluncur ke titik SDN 01. Harap tetap di titik tertinggi.',
        time: '10:13',
        isMe: false,
        relayInfo: 'Terkonfirmasi Konsensus SAR Lapangan (Simulasi)',
      ),
    ];
  }

  void _sendMessage({String? customText, TelemetryData? telemetry}) {
    final text = customText ?? _messageController.text.trim();
    if (text.isEmpty && telemetry == null) return;

    final now = DateTime.now();
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    setState(() {
      _messages.add(
        ChatMessage(
          id: 'user-${DateTime.now().millisecondsSinceEpoch}',
          senderName: 'Anda',
          text: text,
          time: timeStr,
          isMe: true,
          statusText: 'Tersimpan Lokal (Simulasi)',
          telemetryData: telemetry,
        ),
      );
      if (customText == null) {
        _messageController.clear();
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent + 80,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        titleSpacing: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Detail Percakapan',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.bold,
            color: AppColors.primaryNavy,
          ),
        ),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 16),
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: AppColors.primaryNavy,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.person, color: Colors.white, size: 18),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Status Protokol Jaringan (Pill Banner)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: AppColors.accentPillBg,
              child: Row(
                children: const [
                  Icon(Icons.hub_outlined, size: 14, color: AppColors.accentBlue),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'PROTOKOL SIAGAMESH: P2P Simulasi (Tanpa Internet) [AKTIF]',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.accentPillText,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Kartu Identitas Kontak / Node Penerima
            Container(
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.borderLight),
              ),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppColors.surfaceSubtle,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.emergency_outlined, color: AppColors.emergencyRed, size: 24),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                widget.conversationTitle,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.primaryNavy,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 6),
                            if (widget.isEmergency)
                              StatusBadge(
                                label: 'SOS',
                                backgroundColor: AppColors.emergencyRed,
                                textColor: Colors.white,
                                fontSize: 9,
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Terhubung (Simulasi) • Sinyal Kuat • ${widget.nodeId}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.textSecondary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Pembatas Hari
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                'HARI INI • JANGKAUAN LOKAL TERBUKA (SIMULASI)',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textMuted,
                  letterSpacing: 0.5,
                ),
              ),
            ),

            // Area Pesan
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  final msg = _messages[index];
                  return _buildMessageItem(msg);
                },
              ),
            ),

            // Quick Response Chips
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              color: AppColors.surface,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _buildQuickActionChip(
                      label: 'Kirim Lokasi',
                      icon: Icons.my_location,
                      onTap: () {
                        _sendMessage(
                          customText: 'Data Telemetri Koordinat Lokasi Darurat',
                          telemetry: const TelemetryData(
                            locationName: 'Titik Kumpul Evakuasi (Simulasi)',
                            latitude: -6.2000,
                            longitude: 106.8500,
                            accuracy: '<5m (Simulasi)',
                            priority: 'DARURAT',
                            validationInfo: 'Simulasi Terverifikasi GPS',
                          ),
                        );
                      },
                    ),
                    const SizedBox(width: 8),
                    _buildQuickActionChip(
                      label: 'Kondisi Aman',
                      icon: Icons.verified_user_outlined,
                      onTap: () => _sendMessage(customText: 'Kondisi saat ini aman dan terkendali.'),
                    ),
                    const SizedBox(width: 8),
                    _buildQuickActionChip(
                      label: 'Butuh Bantuan Medis',
                      icon: Icons.medical_services_outlined,
                      isAlert: true,
                      onTap: () => _sendMessage(customText: 'Membutuhkan bantuan medis darurat segera!'),
                    ),
                  ],
                ),
              ),
            ),

            // Input Pesan
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: const BoxDecoration(
                color: AppColors.surface,
                border: Border(
                  top: BorderSide(color: AppColors.borderLight),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      decoration: const InputDecoration(
                        hintText: 'Ketik pesan (simulasi)...',
                        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: () => _sendMessage(),
                    borderRadius: BorderRadius.circular(24),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: AppColors.primaryNavy,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: const Text(
                        'Kirim',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickActionChip({
    required String label,
    required IconData icon,
    required VoidCallback onTap,
    bool isAlert = false,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isAlert ? AppColors.emergencyRedLight : AppColors.surfaceSubtle,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isAlert ? AppColors.emergencyRed.withValues(alpha: 0.3) : AppColors.borderLight,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 13,
              color: isAlert ? AppColors.emergencyRed : AppColors.primaryNavy,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: isAlert ? AppColors.emergencyRed : AppColors.primaryNavy,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageItem(ChatMessage msg) {
    if (msg.telemetryData != null) {
      return _buildTelemetryCard(msg);
    }

    final isMe = msg.isMe;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          // Header Pengirim & Waktu
          Padding(
            padding: const EdgeInsets.only(left: 4, right: 4, bottom: 4),
            child: Text(
              '${msg.senderName} • ${msg.time}',
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: AppColors.textMuted,
              ),
            ),
          ),
          // Gelembung Pesan
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.78,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: isMe ? AppColors.primaryNavy : AppColors.surface,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(isMe ? 16 : 4),
                bottomRight: Radius.circular(isMe ? 4 : 16),
              ),
              border: isMe ? null : Border.all(color: AppColors.borderLight),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Text(
              msg.text,
              style: TextStyle(
                fontSize: 13,
                color: isMe ? Colors.white : AppColors.textPrimary,
                height: 1.35,
              ),
            ),
          ),
          // Status Footer / Rute Relai
          if (msg.relayInfo != null || msg.statusText != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4, right: 4),
              child: Text(
                msg.relayInfo ?? msg.statusText ?? '',
                style: const TextStyle(
                  fontSize: 10,
                  color: AppColors.textMuted,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTelemetryCard(ChatMessage msg) {
    final tele = msg.telemetryData!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 4, bottom: 4),
            child: Text(
              '${msg.senderName} • ${msg.time}',
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: AppColors.textMuted,
              ),
            ),
          ),
          Container(
            width: MediaQuery.of(context).size.width * 0.85,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.emergencyRed.withValues(alpha: 0.4)),
              boxShadow: [
                BoxShadow(
                  color: AppColors.emergencyRed.withValues(alpha: 0.05),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Data Telemetri Lokasi',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: AppColors.primaryNavy,
                      ),
                    ),
                    StatusBadge(
                      label: tele.priority,
                      backgroundColor: AppColors.emergencyRedLight,
                      textColor: AppColors.emergencyRed,
                      fontSize: 9,
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'TERKONFIRMASI GPS INDEPENDEN (SIMULASI)',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: AppColors.accentBlue,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Koordinat Darurat: ${tele.locationName}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${tele.latitude}, ${tele.longitude}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textSecondary,
                        fontFamily: 'monospace',
                      ),
                    ),
                    Text(
                      'Akurasi: ${tele.accuracy}',
                      style: const TextStyle(
                        fontSize: 10,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
                const Divider(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Pengirim: Node Anda',
                      style: TextStyle(fontSize: 10, color: AppColors.textMuted),
                    ),
                    Text(
                      tele.validationInfo,
                      style: const TextStyle(
                        fontSize: 10,
                        color: AppColors.accentBlue,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

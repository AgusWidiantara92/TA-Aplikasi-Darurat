import 'dart:async';
import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/routing/manet_routing_engine.dart';
import '../../../core/routing/message_envelope.dart';
import '../../../core/routing/routing_holder.dart';
import '../../../core/transport/mesh_transport.dart';
import '../../../core/transport/transport_holder.dart';
import '../../../core/widgets/siagamesh_dialog.dart';
import '../data/repositories/chat_repository.dart';
import '../models/chat_message.dart';

/// Layar Detail Percakapan SiagaMesh yang bersih, responsif, dan ramah pengguna.
class ChatDetailScreen extends StatefulWidget {
  final String? conversationId;
  final String? conversationTitle;
  final String? nodeId;
  final String? peerNodeId;
  final bool isEmergency;
  final List<ChatMessage>? initialMessages;
  final ChatRepository? repository;
  final MeshTransport? transport;
  final ManetRoutingEngine? routingEngine;
  final String? peerEndpointId;

  const ChatDetailScreen({
    super.key,
    this.conversationId,
    this.conversationTitle,
    this.nodeId,
    this.peerNodeId,
    this.isEmergency = false,
    this.initialMessages,
    this.repository,
    this.transport,
    this.routingEngine,
    this.peerEndpointId,
  });

  @override
  State<ChatDetailScreen> createState() => _ChatDetailScreenState();
}

class _ChatDetailScreenState extends State<ChatDetailScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  late List<ChatMessage> _messages;
  late ChatRepository _repository;
  late MeshTransport _transport;
  late ManetRoutingEngine _routingEngine;
  StreamSubscription<MessageEnvelope>? _incomingEnvelopeSub;
  StreamSubscription<TransportPayload>? _payloadSub;

  String get effectiveRecipientNodeId {
    if (widget.peerNodeId != null && widget.peerNodeId!.trim().isNotEmpty) {
      final raw = widget.peerNodeId!.trim();
      return raw
          .replaceFirst(RegExp(r'^Node:\s*#?', caseSensitive: false), '')
          .trim();
    }
    if (widget.nodeId != null && widget.nodeId!.trim().isNotEmpty) {
      final raw = widget.nodeId!.trim();
      return raw
          .replaceFirst(RegExp(r'^Node:\s*#?', caseSensitive: false), '')
          .trim();
    }
    return '';
  }

  bool get isBroadcastScreen {
    final convId = widget.conversationId?.toLowerCase() ?? '';
    final nodeStr = (widget.nodeId ?? '').toUpperCase();
    final peerStr = (widget.peerNodeId ?? '').toUpperCase();
    final titleStr = (widget.conversationTitle ?? '').toUpperCase();

    if (convId == 'broadcast-all' || convId == 'broadcast') {
      return true;
    }
    if (peerStr == 'BROADCAST' || peerStr == '#ALL-NODES') {
      return true;
    }
    if (nodeStr.contains('BROADCAST') || nodeStr.contains('#ALL-NODES')) {
      return true;
    }
    if (titleStr.contains('SIARAN') &&
        (convId.isEmpty || convId.contains('broadcast'))) {
      return true;
    }

    return false;
  }

  String get conversationTitle {
    if (widget.conversationTitle != null &&
        widget.conversationTitle!.isNotEmpty) {
      return widget.conversationTitle!;
    }
    if (isBroadcastScreen) {
      return 'Siaran Darurat Lokal';
    }
    if (widget.peerNodeId != null && widget.peerNodeId!.isNotEmpty) {
      return widget.peerNodeId!;
    }
    return widget.nodeId ?? 'Node Sekitar';
  }

  bool get _isConnected {
    if (isBroadcastScreen) {
      return _transport.connectedPeers.isNotEmpty;
    }
    final directEp = _routingEngine.neighborTable.getEndpointIdForNode(
      effectiveRecipientNodeId,
    );
    if (directEp != null) {
      return _transport.connectedPeers.any((p) => p.endpointId == directEp);
    }
    if (widget.peerEndpointId != null) {
      return _transport.connectedPeers.any(
        (p) => p.endpointId == widget.peerEndpointId,
      );
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    _messages = widget.initialMessages != null
        ? List.from(widget.initialMessages!)
        : [];
    _repository = widget.repository ?? ChatRepositoryHolder.instance;
    _transport = widget.transport ?? MeshTransportHolder.instance;
    _routingEngine = widget.routingEngine ?? ManetRoutingHolder.instance;

    _loadMessagesFromRepository();
    _listenToIncomingPayloads();

    final targetConvId = _resolveConversationId();
    if (targetConvId != null) {
      _repository.markConversationAsRead(targetConvId);
    }
  }

  void _listenToIncomingPayloads() {
    _incomingEnvelopeSub = _routingEngine.incomingMessagesStream.listen((
      envelope,
    ) async {
      if (!mounted) return;

      // Tangani event E2E_ACK: perbarui status pesan di UI secara real-time
      if (envelope.type == MessageEnvelope.typeE2eAck) {
        final ackedMsgId = envelope.payload['ackedMessageId'] as String?;
        if (ackedMsgId != null) {
          final idx = _messages.indexWhere((m) => m.id == ackedMsgId);
          if (idx != -1) {
            setState(() {
              _messages[idx] = _messages[idx].copyWith(
                statusText: 'Diterima di Perangkat Tujuan (E2E ACK)',
              );
            });
          }
        }
        return;
      }

      if (envelope.type != MessageEnvelope.typeChat) return;

      final isBroadcast =
          envelope.recipientId.trim().toUpperCase() == 'BROADCAST';
      final isRelevant =
          (isBroadcastScreen && isBroadcast) ||
          (!isBroadcastScreen &&
              !isBroadcast &&
              (envelope.senderId.trim().toLowerCase() ==
                      effectiveRecipientNodeId.toLowerCase() ||
                  envelope.senderId.trim().toLowerCase() ==
                      (widget.peerNodeId ?? '').toLowerCase() ||
                  (widget.conversationId != null &&
                      widget.conversationId!.toLowerCase().contains(
                        envelope.senderId.trim().toLowerCase(),
                      ))));

      if (!isRelevant) return;

      final messageId =
          envelope.payload['messageId'] as String? ?? envelope.envelopeId;

      if (_messages.any((m) => m.id == messageId)) return;

      final text = envelope.payload['text'] as String? ?? '';
      final timeStr = envelope.payload['time'] as String? ?? 'Baru saja';
      final isEmergency = envelope.payload['isEmergency'] as bool? ?? false;

      TelemetryData? telemetry;
      if (envelope.payload['telemetry'] != null &&
          envelope.payload['telemetry'] is Map<String, dynamic>) {
        try {
          telemetry = TelemetryData.fromJson(
            envelope.payload['telemetry'] as Map<String, dynamic>,
          );
        } catch (_) {}
      }

      final incomingMessage = ChatMessage(
        id: messageId,
        senderName: envelope.senderName,
        text: text,
        time: timeStr,
        isMe: false,
        isEmergency: isEmergency,
        statusText: isBroadcast ? 'Diterima (Siaran)' : 'Diterima',
        telemetryData: telemetry,
      );

      final targetConvId = _resolveConversationId();
      if (targetConvId != null) {
        await _repository.saveMessage(targetConvId, incomingMessage);
      }

      if (!mounted) return;
      setState(() {
        if (!_messages.any((m) => m.id == incomingMessage.id)) {
          _messages.add(incomingMessage);
        }
      });

      _scrollToBottom();
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _loadMessagesFromRepository() async {
    final targetConvId = _resolveConversationId();
    if (targetConvId == null) return;

    final loaded = await _repository.getMessages(targetConvId);
    if (!mounted) return;

    setState(() {
      if (_messages.isEmpty) {
        _messages = loaded;
      } else {
        final existingIds = _messages.map((m) => m.id).toSet();
        for (final m in loaded) {
          if (!existingIds.contains(m.id)) {
            _messages.add(m);
          }
        }
      }
    });
  }

  String? _resolveConversationId() {
    if (widget.conversationId != null && widget.conversationId!.isNotEmpty) {
      return widget.conversationId;
    }
    if (isBroadcastScreen) {
      return 'broadcast-all';
    }
    final peerId = effectiveRecipientNodeId;
    if (peerId.isNotEmpty && !peerId.startsWith('Node:')) {
      return 'conv-node-$peerId';
    }
    return null;
  }

  bool get _isBroadcastScreen => isBroadcastScreen;

  void _confirmDeleteConversation() {
    SiagaMeshDialog.show(
      context: context,
      icon: Icons.delete_outline_rounded,
      iconColor: AppColors.emergencyRed,
      title: 'Hapus Percakapan?',
      message:
          'Seluruh riwayat pesan percakapan ini akan dihapus dari penyimpanan lokal. Identitas node dan kunci jaringan tetap aman.',
      actions: [
        SiagaMeshDialogAction(
          label: 'Hapus',
          isPrimary: true,
          onPressed: () async {
            Navigator.pop(context); // Tutup dialog
            final targetConvId =
                _resolveConversationId() ??
                (isBroadcastScreen
                    ? 'broadcast-all'
                    : 'conv-node-$effectiveRecipientNodeId');
            await _repository.deleteConversation(targetConvId);
            if (!mounted) return;
            Navigator.pop(context); // Kembali ke layar sebelumnya
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Percakapan berhasil dihapus dari riwayat lokal.',
                ),
                duration: Duration(seconds: 2),
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

  void _confirmDeleteBroadcastMessage(ChatMessage msg) {
    SiagaMeshDialog.show(
      context: context,
      icon: Icons.delete_outline_rounded,
      iconColor: AppColors.emergencyRed,
      title: 'Hapus Pesan Broadcast?',
      message:
          'Pesan ini akan dihapus dari riwayat lokal. Pesan yang sudah diterima perangkat lain tidak ikut terhapus.',
      actions: [
        SiagaMeshDialogAction(
          label: 'Hapus',
          isDestructive: true,
          onPressed: () async {
            Navigator.pop(context);
            await _deleteBroadcastMessage(msg);
          },
        ),
        SiagaMeshDialogAction(
          label: 'Batal',
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );
  }

  Future<void> _deleteBroadcastMessage(ChatMessage msg) async {
    final targetConvId = _resolveConversationId() ?? 'broadcast-all';

    // 1. Batalkan dari antrean store-and-forward routing engine jika ada
    _routingEngine.cancelQueuedMessage(msg.id);

    // 2. Hapus dari ChatRepository lokal dan SharedPreferences
    await _repository.deleteMessage(targetConvId, msg.id);

    // 3. Perbarui state UI lokal
    if (!mounted) return;
    setState(() {
      _messages.removeWhere((m) => m.id == msg.id);
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Pesan broadcast berhasil dihapus dari riwayat lokal.'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _sendMessage({String? customText, TelemetryData? telemetry}) async {
    final text = customText ?? _messageController.text.trim();
    if (text.isEmpty && telemetry == null) return;

    final now = DateTime.now();
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    final isBroadcast = isBroadcastScreen;
    final recipientNodeId = isBroadcast
        ? 'BROADCAST'
        : effectiveRecipientNodeId;

    final envelope = await _routingEngine.sendChatMessage(
      recipientNodeId: recipientNodeId,
      text: text,
      telemetry: telemetry,
      isEmergency: widget.isEmergency,
    );

    String statusText;
    final isDirectNeighbor =
        _routingEngine.neighborTable.getEndpointIdForNode(recipientNodeId) !=
        null;
    if (isDirectNeighbor) {
      statusText = 'Terkirim';
    } else if (_routingEngine.neighborTable.activeNeighbors.isNotEmpty) {
      statusText = isBroadcast ? 'Disiarkan' : 'Terkirim';
    } else if (_routingEngine.storeAndForwardQueue.contains(
      envelope.envelopeId,
    )) {
      statusText = 'Mengirim';
    } else {
      statusText = 'Mengirim';
    }

    final messageId =
        envelope.payload['messageId'] as String? ??
        'user-${DateTime.now().millisecondsSinceEpoch}';

    final newMessage = ChatMessage(
      id: messageId,
      senderName: 'Anda',
      text: text,
      time: timeStr,
      isMe: true,
      statusText: statusText,
      telemetryData: telemetry,
      isEmergency: widget.isEmergency,
    );

    final targetConvId = _resolveConversationId();
    if (targetConvId != null) {
      await _repository.saveMessage(targetConvId, newMessage);
    }

    if (!mounted) return;
    setState(() {
      if (!_messages.any((m) => m.id == newMessage.id)) {
        _messages.add(newMessage);
      }
      if (customText == null) {
        _messageController.clear();
      }
    });

    _scrollToBottom();
  }

  String _formatConciseStatus(ChatMessage msg) {
    final status = msg.statusText ?? '';
    if (status.contains('E2E ACK') ||
        status.contains('Diterima di Perangkat Tujuan')) {
      return 'Diterima';
    }
    if (status.contains('Terkirim') || status.contains('Disiarkan')) {
      return 'Terkirim';
    }
    if (status.contains('Mengantre') ||
        status.contains('Buffer') ||
        status.contains('Mengirim')) {
      return 'Mengirim';
    }
    if (status.contains('Gagal')) {
      return 'Gagal';
    }
    if (status.contains('Diterima')) {
      return 'Diterima';
    }
    return status.isNotEmpty ? status : (msg.isMe ? 'Terkirim' : 'Diterima');
  }

  void _showTechnicalDetailsModal(BuildContext context) {
    final targetId = _resolveConversationId() ?? 'broadcast-all';
    final isDirect = _isConnected;

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Detail Teknis Percakapan',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: AppColors.primaryNavy,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const Divider(height: 16),
              _buildTechDetailRow(
                'Tujuan / Penerima',
                effectiveRecipientNodeId,
              ),
              _buildTechDetailRow('ID Percakapan', targetId),
              _buildTechDetailRow(
                'Koneksi Radio',
                isDirect ? '1-Hop Langsung Terhubung' : 'Routing Multi-Hop',
              ),
              _buildTechDetailRow('Verifikasi Paket', 'SACJ-v1 Header HMAC'),
              _buildTechDetailRow(
                'Status Keamanan',
                'IDS & Dynamic Trust Monitoring',
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTechDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
            ),
          ),
          Expanded(
            child: SelectableText(
              value.isNotEmpty ? value : '-',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: AppColors.primaryNavy,
              ),
            ),
          ),
        ],
      ),
    );
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

  @override
  void dispose() {
    _incomingEnvelopeSub?.cancel();
    _payloadSub?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final initials = isBroadcastScreen ? '📢' : _getInitials(conversationTitle);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        titleSpacing: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: isBroadcastScreen
                  ? AppColors.emergencyRed
                  : AppColors.primaryNavy,
              child: Text(
                initials,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Detail Percakapan',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textMuted,
                      letterSpacing: 0.5,
                    ),
                  ),
                  Text(
                    conversationTitle,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: AppColors.primaryNavy,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    isBroadcastScreen
                        ? 'Jangkauan Siaran Lokal'
                        : (_isConnected
                              ? 'Tersambung Langsung'
                              : 'Dalam Jangkauan'),
                    style: TextStyle(
                      fontSize: 11,
                      color: _isConnected
                          ? AppColors.successGreen
                          : AppColors.textMuted,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            key: const Key('action_delete_conversation'),
            icon: const Icon(
              Icons.delete_outline,
              size: 20,
              color: AppColors.emergencyRed,
            ),
            tooltip: 'Hapus Percakapan',
            onPressed: _confirmDeleteConversation,
          ),
          IconButton(
            icon: const Icon(
              Icons.info_outline,
              size: 20,
              color: AppColors.primaryNavy,
            ),
            tooltip: 'Detail Teknis',
            onPressed: () => _showTechnicalDetailsModal(context),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Area Daftar Pesan
            Expanded(
              child: _messages.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: const BoxDecoration(
                                color: AppColors.surfaceSubtle,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.chat_bubble_outline_rounded,
                                size: 32,
                                color: AppColors.textMuted,
                              ),
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              'Belum ada pesan siaran',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: AppColors.primaryNavy,
                              ),
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'Ketik pesan atau gunakan respons cepat di bawah untuk memulai transmisi pesan.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 12,
                                color: AppColors.textSecondary,
                                height: 1.4,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
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
                            locationName: 'Titik Kumpul Evakuasi',
                            latitude: -6.2000,
                            longitude: 106.8500,
                            accuracy: 'Akurasi: Terverifikasi',
                            priority: 'DARURAT',
                            validationInfo: 'Verifikasi: SACJ HMAC',
                          ),
                        );
                      },
                    ),
                    const SizedBox(width: 8),
                    _buildQuickActionChip(
                      label: 'Kondisi Aman',
                      icon: Icons.verified_user_outlined,
                      onTap: () => _sendMessage(
                        customText: 'Kondisi saat ini aman dan terkendali.',
                      ),
                    ),
                    const SizedBox(width: 8),
                    _buildQuickActionChip(
                      label: 'Butuh Bantuan Medis',
                      icon: Icons.medical_services_outlined,
                      isAlert: true,
                      onTap: () => _sendMessage(
                        customText: 'Membutuhkan bantuan medis darurat segera!',
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Baris Input Pesan
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: const BoxDecoration(
                color: AppColors.surface,
                border: Border(top: BorderSide(color: AppColors.borderLight)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      decoration: const InputDecoration(
                        hintText: 'Ketik pesan darurat...',
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: () => _sendMessage(),
                    borderRadius: BorderRadius.circular(24),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
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
          color: isAlert
              ? AppColors.emergencyRedLight
              : AppColors.surfaceSubtle,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isAlert
                ? AppColors.emergencyRed.withValues(alpha: 0.3)
                : AppColors.borderLight,
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
    final conciseStatus = _formatConciseStatus(msg);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: isMe
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          // Header Pengirim & Waktu & Tombol Hapus jika broadcast
          Padding(
            padding: const EdgeInsets.only(left: 4, right: 4, bottom: 3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${msg.senderName} • ${msg.time}',
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textMuted,
                  ),
                ),
                if (_isBroadcastScreen) ...[
                  const SizedBox(width: 8),
                  InkWell(
                    key: Key('delete_msg_${msg.id}'),
                    onTap: () => _confirmDeleteBroadcastMessage(msg),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 1,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Icon(
                            Icons.delete_outline,
                            size: 13,
                            color: AppColors.emergencyRed,
                          ),
                          SizedBox(width: 2),
                          Text(
                            'Hapus',
                            style: TextStyle(
                              fontSize: 10,
                              color: AppColors.emergencyRed,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          // Gelembung Pesan
          GestureDetector(
            onLongPress: _isBroadcastScreen
                ? () => _confirmDeleteBroadcastMessage(msg)
                : null,
            child: Container(
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
              child: Column(
                crossAxisAlignment: isMe
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                children: [
                  Text(
                    msg.text,
                    style: TextStyle(
                      fontSize: 13,
                      color: isMe ? Colors.white : AppColors.textPrimary,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 3),
                  // Indikator Status Singkat
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        conciseStatus,
                        style: TextStyle(
                          fontSize: 9,
                          color: isMe
                              ? Colors.white.withValues(alpha: 0.7)
                              : AppColors.textMuted,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (isMe && conciseStatus == 'Diterima') ...[
                        const SizedBox(width: 3),
                        Icon(
                          Icons.done_all,
                          size: 11,
                          color: Colors.white.withValues(alpha: 0.8),
                        ),
                      ] else if (isMe && conciseStatus == 'Terkirim') ...[
                        const SizedBox(width: 3),
                        Icon(
                          Icons.done,
                          size: 11,
                          color: Colors.white.withValues(alpha: 0.7),
                        ),
                      ],
                    ],
                  ),
                ],
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
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 4, bottom: 3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${msg.senderName} • ${msg.time}',
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textMuted,
                  ),
                ),
                if (_isBroadcastScreen) ...[
                  const SizedBox(width: 8),
                  InkWell(
                    key: Key('delete_telemetry_${msg.id}'),
                    onTap: () => _confirmDeleteBroadcastMessage(msg),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 1,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Icon(
                            Icons.delete_outline,
                            size: 13,
                            color: AppColors.emergencyRed,
                          ),
                          SizedBox(width: 2),
                          Text(
                            'Hapus',
                            style: TextStyle(
                              fontSize: 10,
                              color: AppColors.emergencyRed,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Container(
            width: MediaQuery.of(context).size.width * 0.78,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.emergencyRedLight,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: AppColors.emergencyRed.withValues(alpha: 0.4),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: const [
                    Icon(
                      Icons.location_on,
                      color: AppColors.emergencyRed,
                      size: 16,
                    ),
                    SizedBox(width: 4),
                    Text(
                      'KOORDINAT DARURAT',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: AppColors.emergencyRed,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  tele.locationName,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: AppColors.primaryNavy,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Lat: ${tele.latitude.toStringAsFixed(4)}, Lon: ${tele.longitude.toStringAsFixed(4)}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

import 'dart:async';
import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/routing/manet_routing_engine.dart';
import '../../../core/routing/routing_holder.dart';
import '../../../core/transport/mesh_transport.dart';
import '../../../core/transport/transport_holder.dart';
import '../../../core/widgets/app_header.dart';
import '../../../core/widgets/siagamesh_dialog.dart';
import '../../../core/widgets/status_badge.dart';
import '../../chat/data/repositories/chat_repository.dart';
import '../../chat/models/chat_conversation.dart';
import '../../chat/models/chat_message.dart';
import '../../chat/presentation/chat_detail_screen.dart';

/// Layar Beranda (Home) yang disederhanakan, intuitif, dan ramah pengguna.
class HomeScreen extends StatefulWidget {
  final VoidCallback? onNavigateToMessages;
  final VoidCallback? onNavigateToDevices;
  final MeshTransport? transport;
  final ManetRoutingEngine? routingEngine;
  final ChatRepository? repository;

  const HomeScreen({
    super.key,
    this.onNavigateToMessages,
    this.onNavigateToDevices,
    this.transport,
    this.routingEngine,
    this.repository,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late MeshTransport _transport;
  late ManetRoutingEngine _routingEngine;
  late ChatRepository _repository;
  StreamSubscription<List<DiscoveredPeer>>? _peersSub;
  StreamSubscription<TransportConnectionEvent>? _eventsSub;
  StreamSubscription<List<ChatConversation>>? _conversationsSub;
  List<DiscoveredPeer> _peers = [];
  List<ChatConversation> _recentConversations = [];
  bool _isAdvertising = false;
  bool _isDiscovering = false;
  bool _isSendingSos = false;

  @override
  void initState() {
    super.initState();
    _transport = widget.transport ?? MeshTransportHolder.instance;
    _routingEngine = widget.routingEngine ?? ManetRoutingHolder.instance;
    _repository = widget.repository ?? ChatRepositoryHolder.instance;
    _peers = _transport.currentPeers;
    _isAdvertising = _transport.isAdvertising;
    _isDiscovering = _transport.isDiscovering;

    _loadRecentConversations();

    _conversationsSub = _repository.conversationsStream.listen((_) {
      _loadRecentConversations();
    });

    _peersSub = _transport.discoveredPeersStream.listen((peers) {
      if (!mounted) return;
      setState(() {
        _peers = peers;
        _isAdvertising = _transport.isAdvertising;
        _isDiscovering = _transport.isDiscovering;
      });
      _loadRecentConversations();
    });

    _eventsSub = _transport.connectionEventsStream.listen((_) {
      if (!mounted) return;
      setState(() {
        _peers = _transport.currentPeers;
        _isAdvertising = _transport.isAdvertising;
        _isDiscovering = _transport.isDiscovering;
      });
      _loadRecentConversations();
    });
  }

  Future<void> _loadRecentConversations() async {
    try {
      final list = await _repository.getConversations();
      if (!mounted) return;
      setState(() {
        _recentConversations = list.take(3).toList();
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _conversationsSub?.cancel();
    _peersSub?.cancel();
    _eventsSub?.cancel();
    super.dispose();
  }

  List<DiscoveredPeer> get _dedupedPeers {
    final Map<String, DiscoveredPeer> grouped = {};
    for (final peer in _peers) {
      final resolvedNodeId = _routingEngine.neighborTable.getNodeIdForEndpoint(
        peer.endpointId,
      );
      final key =
          resolvedNodeId != null && !resolvedNodeId.startsWith('pending-')
          ? 'node:${resolvedNodeId.toLowerCase()}'
          : 'ep:${peer.endpointId}';
      if (!grouped.containsKey(key)) {
        grouped[key] = peer;
      } else {
        final current = grouped[key]!;
        if (peer.status == PeerConnectionStatus.connected &&
            current.status != PeerConnectionStatus.connected) {
          grouped[key] = peer;
        } else if (peer.status == current.status &&
            peer.discoveredAt.isAfter(current.discoveredAt)) {
          grouped[key] = peer;
        }
      }
    }
    return grouped.values.toList();
  }

  List<DiscoveredPeer> get _connectedPeers => _dedupedPeers
      .where((p) => p.status == PeerConnectionStatus.connected)
      .toList();

  String _getInitials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts[0].isEmpty) return '?';
    if (parts.length == 1) {
      final w = parts[0];
      return w.substring(0, w.length >= 2 ? 2 : 1).toUpperCase();
    }
    return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
  }

  Future<void> _dispatchEmergencySos({required bool isQueued}) async {
    setState(() {
      _isSendingSos = true;
    });

    final now = DateTime.now();
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    try {
      final envelope = await _routingEngine.sendChatMessage(
        recipientNodeId: 'BROADCAST',
        text: 'PANGGILAN DARURAT (SOS): Memerlukan bantuan segera!',
        isEmergency: true,
      );

      final messageId =
          envelope.payload['messageId'] as String? ?? envelope.envelopeId;

      final chatMsg = ChatMessage(
        id: messageId,
        senderName: 'Anda',
        text: 'PANGGILAN DARURAT (SOS): Memerlukan bantuan segera!',
        time: timeStr,
        isMe: true,
        isEmergency: true,
        statusText: isQueued
            ? 'Tersimpan di Buffer Transmisi'
            : 'Disiarkan ke Transport Mesh',
      );

      final broadcastConv = await _repository
          .getOrCreateBroadcastConversation();
      await _repository.saveMessage(broadcastConv.id, chatMsg);
      await _loadRecentConversations();

      debugPrint(
        '[SiagaMesh-Diag] SOS successfully dispatched and stored: msgId=$messageId convId=${broadcastConv.id}',
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppColors.primaryNavy,
          content: Text(
            isQueued
                ? 'Pesan darurat disimpan di antrean transmisi lokal. Akan disiarkan otomatis saat peer terhubung.'
                : 'Sinyal SOS darurat berhasil diserahkan ke stack transport mesh (${_connectedPeers.length} peer).',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      // Pertahankan riwayat lokal dengan status gagal sesuai kebijakan aplikasi
      try {
        final failedMsg = ChatMessage(
          id: 'sos-failed-${DateTime.now().millisecondsSinceEpoch}',
          senderName: 'Anda',
          text: 'PANGGILAN DARURAT (SOS): Memerlukan bantuan segera!',
          time: timeStr,
          isMe: true,
          isEmergency: true,
          statusText: 'Gagal Terkirim',
        );
        final broadcastConv = await _repository
            .getOrCreateBroadcastConversation();
        await _repository.saveMessage(broadcastConv.id, failedMsg);
        await _loadRecentConversations();
      } catch (_) {}

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppColors.emergencyRed,
          content: Text('Gagal mengirimkan sinyal darurat: $e'),
          duration: const Duration(seconds: 3),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSendingSos = false;
        });
      }
    }
  }

  void _showSosDialog(BuildContext context) {
    final connected = _connectedPeers;

    if (connected.isEmpty) {
      SiagaMeshDialog.show(
        context: context,
        icon: Icons.warning_amber_rounded,
        iconColor: AppColors.emergencyRed,
        title: 'Belum Ada Perangkat Terhubung',
        message:
            'Siaran darurat belum dapat dikirim ke peer lain secara langsung karena tidak ada perangkat yang terhubung saat ini. Anda dapat menyimpannya ke antrean lokal agar otomatis terkirim begitu peer terhubung.',
        actions: [
          SiagaMeshDialogAction(
            label: 'Simpan ke Antrean',
            isDestructive: true,
            onPressed: () {
              Navigator.pop(context);
              _dispatchEmergencySos(isQueued: true);
            },
          ),
          SiagaMeshDialogAction(
            label: 'Buka Perangkat',
            isOutlined: true,
            onPressed: () {
              Navigator.pop(context);
              widget.onNavigateToDevices?.call();
            },
          ),
          SiagaMeshDialogAction(
            label: 'Batal',
            onPressed: () => Navigator.pop(context),
          ),
        ],
      );
    } else {
      SiagaMeshDialog.show(
        context: context,
        icon: Icons.emergency_share,
        iconColor: AppColors.emergencyRed,
        title: 'Konfirmasi Siaran Darurat',
        message:
            'Kirim sinyal darurat SOS dengan prioritas tertinggi ke ${connected.length} peer terhubung langsung?',
        actions: [
          SiagaMeshDialogAction(
            label: 'SIARKAN SEKARANG',
            isDestructive: true,
            onPressed: () {
              Navigator.pop(context);
              _dispatchEmergencySos(isQueued: false);
            },
          ),
          SiagaMeshDialogAction(
            label: 'Batal',
            onPressed: () => Navigator.pop(context),
          ),
        ],
      );
    }
  }

  void _openChatWithPeer(DiscoveredPeer peer) async {
    final routing = _routingEngine;
    final resolvedNodeId = routing.neighborTable.getNodeIdForEndpoint(
      peer.endpointId,
    );
    final targetNodeId = resolvedNodeId ?? 'peer-${peer.endpointId}';

    final conv = await _repository.getOrCreateConversationForNode(
      nodeId: targetNodeId,
      nodeName: peer.endpointName,
      isConnected: peer.status == PeerConnectionStatus.connected,
    );

    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatDetailScreen(
          conversationId: conv.id,
          conversationTitle: conv.title,
          nodeId: conv.nodeId,
          peerNodeId: resolvedNodeId ?? conv.peerNodeId ?? targetNodeId,
          isEmergency: false,
          repository: _repository,
          transport: _transport,
          routingEngine: routing,
          peerEndpointId: peer.endpointId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final connected = _connectedPeers;
    final isScanning = _isDiscovering || _isAdvertising;

    // Satu badge status jaringan terpadu (Sesuai Kriteria B.1)
    final String networkStatusLabel;
    final Color networkStatusBg;
    final Color networkStatusColor;
    final IconData networkStatusIcon;

    if (connected.isNotEmpty) {
      networkStatusLabel = 'JARINGAN TERHUBUNG';
      networkStatusBg = AppColors.successGreenLight;
      networkStatusColor = AppColors.successGreen;
      networkStatusIcon = Icons.wifi_tethering;
    } else if (_isDiscovering) {
      networkStatusLabel = 'SEDANG MEMINDAI PEER';
      networkStatusBg = AppColors.accentPillBg;
      networkStatusColor = AppColors.accentBlue;
      networkStatusIcon = Icons.search;
    } else if (_isAdvertising) {
      networkStatusLabel = 'SIARAN AKTIF';
      networkStatusBg = AppColors.accentPillBg;
      networkStatusColor = AppColors.accentBlue;
      networkStatusIcon = Icons.sensors;
    } else {
      networkStatusLabel = 'MODE SIAGA (STANDBY)';
      networkStatusBg = AppColors.surfaceSubtle;
      networkStatusColor = AppColors.textSecondary;
      networkStatusIcon = Icons.wifi_tethering_off;
    }

    final String connectionCardTitle = connected.isNotEmpty
        ? '${connected.length} Perangkat Terhubung Langsung'
        : (isScanning ? 'Sedang Memindai Peer...' : 'Siaga (Belum Terhubung)');

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 84),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. Nama Aplikasi SiagaMesh & Avatar Profil
              const AppHeader(),

              const SizedBox(height: 2),

              // 2. Satu Badge Status Jaringan Nyata
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: StatusBadge(
                  label: networkStatusLabel,
                  backgroundColor: networkStatusBg,
                  textColor: networkStatusColor,
                  icon: networkStatusIcon,
                  fontSize: 11,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                ),
              ),

              const SizedBox(height: 14),

              // Sapaan Singkat
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Halo, ${ManetRoutingHolder.displayName}',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: AppColors.primaryNavy,
                        letterSpacing: -0.4,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Komunikasi darurat nirkabel langsung antar-perangkat tanpa internet.',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // 3. Tombol Utama Pesan Darurat (SOS) yang Jelas
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: InkWell(
                  onTap: _isSendingSos ? null : () => _showSosDialog(context),
                  borderRadius: BorderRadius.circular(20),
                  child: Ink(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      vertical: 16,
                      horizontal: 16,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.primaryNavy,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.primaryNavy.withValues(alpha: 0.2),
                          blurRadius: 14,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (_isSendingSos)
                              const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    Colors.white,
                                  ),
                                ),
                              )
                            else
                              const Icon(
                                Icons.emergency_share,
                                color: Colors.white,
                                size: 22,
                              ),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text(
                                'KIRIM PESAN DARURAT (SOS)',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          connected.isNotEmpty
                              ? 'Siarkan ke ${connected.length} peer terhubung langsung'
                              : 'Tekan untuk menyiarkan sinyal darurat ke perangkat sekitar',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.8),
                            fontSize: 11,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // 4. Ringkasan Perangkat Terhubung (Konektivitas Mesh)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
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
                        children: [
                          const Expanded(
                            child: Text(
                              'KONEKTIVITAS MESH',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: AppColors.textMuted,
                                letterSpacing: 0.5,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          InkWell(
                            onTap: widget.onNavigateToDevices,
                            child: const Padding(
                              padding: EdgeInsets.symmetric(vertical: 2),
                              child: Text(
                                'Kelola →',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.accentBlue,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        connectionCardTitle,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: AppColors.primaryNavy,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          StatusBadge(
                            label:
                                '${_dedupedPeers.length} Perangkat Terdeteksi',
                            backgroundColor: AppColors.surfaceSubtle,
                            textColor: AppColors.primaryNavy,
                            icon: Icons.devices,
                            fontSize: 11,
                          ),
                          const StatusBadge(
                            label: 'INTERNET TIDAK DIBUTUHKAN',
                            backgroundColor: AppColors.successGreenLight,
                            textColor: AppColors.successGreen,
                            icon: Icons.check_circle_outline,
                            fontSize: 10,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // 5. Perangkat Terhubung / Percakapan Terkini
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        connected.isNotEmpty
                            ? 'Perangkat Terhubung (${connected.length})'
                            : 'Percakapan Terkini',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: AppColors.primaryNavy,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    InkWell(
                      onTap: widget.onNavigateToMessages,
                      child: const Text(
                        'Lihat Semua',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.accentBlue,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 8),

              if (connected.isNotEmpty) ...[
                // Tampilkan peer terhubung langsung
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    children: connected.map((peer) {
                      final initials = _getInitials(peer.endpointName);
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: AppColors.successGreen.withValues(
                              alpha: 0.3,
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 18,
                              backgroundColor: AppColors.primaryNavy,
                              child: Text(
                                initials,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    peer.endpointName,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                      color: AppColors.primaryNavy,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 2),
                                  const Text(
                                    'Terhubung langsung via Bluetooth/Wi-Fi',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: AppColors.successGreen,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.primaryNavy,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 6,
                                ),
                                minimumSize: const Size(0, 32),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              onPressed: () => _openChatWithPeer(peer),
                              child: const Text(
                                'Kirim Pesan',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ] else if (_recentConversations.isNotEmpty) ...[
                // Tampilkan percakapan terkini
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    children: _recentConversations.map((conv) {
                      final isBroadcast =
                          conv.id == 'broadcast-all' || conv.id == 'broadcast';
                      final initials = isBroadcast
                          ? '📢'
                          : _getInitials(conv.title);

                      return InkWell(
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => ChatDetailScreen(
                                conversationId: conv.id,
                                conversationTitle: conv.title,
                                nodeId: conv.nodeId,
                                peerNodeId: conv.peerNodeId ?? conv.nodeId,
                                isEmergency: conv.isEmergency,
                                repository: _repository,
                                transport: _transport,
                                routingEngine: _routingEngine,
                              ),
                            ),
                          ).then((_) => _loadRecentConversations());
                        },
                        borderRadius: BorderRadius.circular(14),
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.surface,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: AppColors.borderLight),
                          ),
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 18,
                                backgroundColor: isBroadcast
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
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        Flexible(
                                          child: Text(
                                            conv.title,
                                            style: const TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.bold,
                                              color: AppColors.primaryNavy,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        Text(
                                          conv.time,
                                          style: const TextStyle(
                                            fontSize: 10,
                                            color: AppColors.textMuted,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      conv.lastMessage.isNotEmpty
                                          ? conv.lastMessage
                                          : 'Belum ada pesan',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: AppColors.textSecondary,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ] else ...[
                // Empty state sederhana dan bersahabat
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      vertical: 20,
                      horizontal: 16,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppColors.borderLight),
                    ),
                    child: Column(
                      children: [
                        const Icon(
                          Icons.cell_tower,
                          color: AppColors.textMuted,
                          size: 28,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Belum Ada Aktivitas Percakapan',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: AppColors.primaryNavy,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Gunakan tombol SOS di atas atau buka tab Perangkat untuk mulai menghubungkan ponsel sekitar.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.textSecondary,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}

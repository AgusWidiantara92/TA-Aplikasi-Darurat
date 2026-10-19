import 'dart:async';
import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/routing/manet_routing_engine.dart';
import '../../../core/routing/routing_holder.dart';
import '../../../core/transport/mesh_transport.dart';
import '../../../core/transport/transport_holder.dart';
import '../../../core/widgets/app_header.dart';
import '../../../core/widgets/status_badge.dart';
import '../../chat/data/repositories/chat_repository.dart';
import '../../chat/models/chat_message.dart';

/// Layar Beranda (Home) terhubung dengan state jaringan MANET dan transport riil.
class HomeScreen extends StatefulWidget {
  final VoidCallback? onNavigateToMessages;
  final VoidCallback? onNavigateToDevices;
  final MeshTransport? transport;
  final ManetRoutingEngine? routingEngine;

  const HomeScreen({
    super.key,
    this.onNavigateToMessages,
    this.onNavigateToDevices,
    this.transport,
    this.routingEngine,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late MeshTransport _transport;
  late ManetRoutingEngine _routingEngine;
  StreamSubscription<List<DiscoveredPeer>>? _peersSub;
  StreamSubscription<TransportConnectionEvent>? _eventsSub;
  List<DiscoveredPeer> _peers = [];
  bool _isAdvertising = false;
  bool _isDiscovering = false;
  bool _isSendingSos = false;
  TransportConnectionEvent? _lastEvent;

  @override
  void initState() {
    super.initState();
    _transport = widget.transport ?? MeshTransportHolder.instance;
    _routingEngine = widget.routingEngine ?? ManetRoutingHolder.instance;
    _peers = _transport.currentPeers;
    _isAdvertising = _transport.isAdvertising;
    _isDiscovering = _transport.isDiscovering;

    _peersSub = _transport.discoveredPeersStream.listen((peers) {
      if (!mounted) return;
      setState(() {
        _peers = peers;
        _isAdvertising = _transport.isAdvertising;
        _isDiscovering = _transport.isDiscovering;
      });
    });

    _eventsSub = _transport.connectionEventsStream.listen((event) {
      if (!mounted) return;
      setState(() {
        _lastEvent = event;
        _peers = _transport.currentPeers;
        _isAdvertising = _transport.isAdvertising;
        _isDiscovering = _transport.isDiscovering;
      });
    });
  }

  @override
  void dispose() {
    _peersSub?.cancel();
    _eventsSub?.cancel();
    super.dispose();
  }

  List<DiscoveredPeer> get _connectedPeers =>
      _peers.where((p) => p.status == PeerConnectionStatus.connected).toList();

  Future<void> _dispatchEmergencySos({required bool isQueued}) async {
    setState(() {
      _isSendingSos = true;
    });

    try {
      final envelope = await _routingEngine.sendChatMessage(
        recipientNodeId: 'BROADCAST',
        text: 'PANGGILAN DARURAT (SOS): Memerlukan bantuan segera!',
        isEmergency: true,
      );

      final messageId =
          envelope.payload['messageId'] as String? ?? envelope.envelopeId;
      final now = DateTime.now();
      final timeStr =
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

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

      final repo = ChatRepositoryHolder.instance;
      final broadcastConv = await repo.getOrCreateBroadcastConversation();
      await repo.saveMessage(broadcastConv.id, chatMsg);

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
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Row(
            children: const [
              Icon(
                Icons.warning_amber_rounded,
                color: AppColors.emergencyRed,
                size: 28,
              ),
              SizedBox(width: 8),
              Text(
                'Peringatan Darurat (SOS)',
                style: TextStyle(
                  color: AppColors.primaryNavy,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Text(
                'Belum ada perangkat sekitar yang terhubung ke jaringan mesh saat ini.',
                style: TextStyle(
                  fontSize: 14,
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(height: 10),
              Text(
                'Pesan darurat dapat disimpan ke antrean transmisi lokal untuk segera disiarkan saat perangkat lain terhubung, atau buka tab Perangkat untuk mencari node terdekat.',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                  height: 1.4,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Batal'),
            ),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppColors.primaryNavy),
              ),
              onPressed: () {
                Navigator.pop(ctx);
                widget.onNavigateToDevices?.call();
              },
              child: const Text(
                'Buka Perangkat',
                style: TextStyle(color: AppColors.primaryNavy),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.emergencyRed,
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                Navigator.pop(ctx);
                _dispatchEmergencySos(isQueued: true);
              },
              child: const Text('Simpan ke Antrean Siaran'),
            ),
          ],
        ),
      );
    } else {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Row(
            children: const [
              Icon(
                Icons.emergency_share,
                color: AppColors.emergencyRed,
                size: 28,
              ),
              SizedBox(width: 8),
              Text(
                'Konfirmasi Siaran Darurat',
                style: TextStyle(
                  color: AppColors.primaryNavy,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
            ],
          ),
          content: Text(
            'Kirim sinyal darurat SOS dengan prioritas tertinggi ke ${connected.length} peer terhubung langsung?',
            style: const TextStyle(fontSize: 14, color: AppColors.textPrimary),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Batal'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.emergencyRed,
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                Navigator.pop(ctx);
                _dispatchEmergencySos(isQueued: false);
              },
              child: const Text('SIARKAN SEKARANG'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final connected = _connectedPeers;
    final isScanning = _isDiscovering || _isAdvertising;

    // Tentukan status teks dan banner berdasarkan keadaan transport riil
    final String bannerText;
    final IconData bannerIcon;
    final Color bannerColor;
    final Color bannerTextColor;

    final String networkStatusLabel;
    final Color networkStatusBg;
    final Color networkStatusColor;

    if (connected.isNotEmpty) {
      bannerText =
          'Jaringan Terhubung: ${connected.length} peer aktif dalam jangkauan radio.';
      bannerIcon = Icons.check_circle_outline;
      bannerColor = AppColors.successGreenLight;
      bannerTextColor = AppColors.successGreen;

      networkStatusLabel = 'JARINGAN TERHUBUNG';
      networkStatusBg = AppColors.successGreenLight;
      networkStatusColor = AppColors.successGreen;
    } else if (_isDiscovering) {
      bannerText =
          'Pencarian Aktif: Memindai perangkat sekitar via Bluetooth LE & Wi-Fi Direct.';
      bannerIcon = Icons.search;
      bannerColor = AppColors.accentPillBg;
      bannerTextColor = AppColors.accentPillText;

      networkStatusLabel = 'SEDANG MEMINDAI';
      networkStatusBg = AppColors.accentPillBg;
      networkStatusColor = AppColors.accentBlue;
    } else if (_isAdvertising) {
      bannerText = 'Siaran Aktif: Perangkat terlihat oleh node di sekitar.';
      bannerIcon = Icons.sensors;
      bannerColor = AppColors.accentPillBg;
      bannerTextColor = AppColors.accentPillText;

      networkStatusLabel = 'SIARAN AKTIF';
      networkStatusBg = AppColors.accentPillBg;
      networkStatusColor = AppColors.accentBlue;
    } else if (_lastEvent != null &&
        _lastEvent!.status == PeerConnectionStatus.disconnected &&
        _peers.isEmpty) {
      bannerText =
          'Koneksi Terputus: Tidak ada peer terhubung. Buka tab Perangkat untuk memindai ulang.';
      bannerIcon = Icons.link_off;
      bannerColor = AppColors.warningOrangeLight;
      bannerTextColor = AppColors.warningOrange;

      networkStatusLabel = 'KONEKSI TERPUTUS';
      networkStatusBg = AppColors.warningOrangeLight;
      networkStatusColor = AppColors.warningOrange;
    } else {
      bannerText =
          'Mode Siaga: Jaringan mesh offline siap diaktifkan melalui tab Perangkat.';
      bannerIcon = Icons.info_outline;
      bannerColor = AppColors.accentPillBg;
      bannerTextColor = AppColors.accentPillText;

      networkStatusLabel = 'MODE SIAGA (STANDBY)';
      networkStatusBg = AppColors.accentPillBg;
      networkStatusColor = AppColors.accentBlue;
    }

    final String connectionCardTitle = connected.isNotEmpty
        ? 'Jaringan Lokal Terhubung'
        : (isScanning ? 'Sedang Memindai Peer...' : 'Siaga (Belum Terhubung)');

    final String connectionCardPill = connected.isNotEmpty
        ? 'P2P Terhubung'
        : (isScanning ? 'P2P Memindai' : 'P2P Siaga');

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header Aplikasi
              const AppHeader(),

              // Banner Status Operasional Riil
              Container(
                width: double.infinity,
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: bannerColor,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: bannerTextColor.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(bannerIcon, size: 16, color: bannerTextColor),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        bannerText,
                        style: TextStyle(
                          fontSize: 12,
                          color: bannerTextColor,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 8),

              // Baris Status Jaringan & Frekuensi Nirkabel Nyata
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    StatusBadge(
                      label: networkStatusLabel,
                      backgroundColor: networkStatusBg,
                      textColor: networkStatusColor,
                      icon: Icons.wifi_tethering,
                    ),
                    const StatusBadge(
                      label: 'Wi-Fi Direct / BLE',
                      backgroundColor: AppColors.surfaceSubtle,
                      textColor: AppColors.textSecondary,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // Sapaan & Subtitle
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text(
                      'Halo, apa yang bisa kami bantu?',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: AppColors.primaryNavy,
                        letterSpacing: -0.4,
                      ),
                    ),
                    SizedBox(height: 6),
                    Text(
                      'Kirim pesan darurat ke perangkat sekitar tanpa kuota internet.',
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.textSecondary,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // Tombol Utama SOS (Emergency CTA)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: InkWell(
                  onTap: _isSendingSos ? null : () => _showSosDialog(context),
                  borderRadius: BorderRadius.circular(24),
                  child: Ink(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      vertical: 18,
                      horizontal: 16,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.primaryNavy,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.primaryNavy.withValues(alpha: 0.25),
                          blurRadius: 16,
                          offset: const Offset(0, 6),
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
                                size: 20,
                              ),
                            const SizedBox(width: 8),
                            const Text(
                              'KIRIM PESAN DARURAT (SOS)',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          connected.isNotEmpty
                              ? 'Prioritas transmisi ke ${connected.length} peer terhubung langsung'
                              : 'Siap menyiarkan sinyal bahaya ke seluruh node terdekat',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.75),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // Kartu 1: Konektivitas Mesh Riil
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: InkWell(
                  onTap: widget.onNavigateToMessages,
                  borderRadius: BorderRadius.circular(18),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: AppColors.borderLight),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'KONEKTIVITAS MESH',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textMuted,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  connectionCardTitle,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.primaryNavy,
                                  ),
                                ),
                              ],
                            ),
                            StatusBadge(
                              label: connectionCardPill,
                              backgroundColor: AppColors.accentPillBg,
                              textColor: AppColors.accentBlue,
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            StatusBadge(
                              label: '${_peers.length} Perangkat Terdeteksi',
                              backgroundColor: AppColors.surfaceSubtle,
                              textColor: AppColors.primaryNavy,
                              icon: Icons.devices,
                              fontSize: 11,
                            ),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: StatusBadge(
                                label: 'INTERNET TIDAK DIBUTUHKAN',
                                backgroundColor: AppColors.successGreenLight,
                                textColor: AppColors.successGreen,
                                icon: Icons.check_circle_outline,
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        const Divider(height: 1),
                        const SizedBox(height: 14),
                        // Parameter Teknis Riil (Jujur sesuai hardware & protokol)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            _buildMetricColumn(
                              'Kekuatan Hop',
                              connected.isNotEmpty
                                  ? '1-Hop Langsung'
                                  : 'Tidak diukur',
                              connected.isNotEmpty
                                  ? AppColors.successGreen
                                  : AppColors.textMuted,
                            ),
                            _buildMetricColumn(
                              'Keamanan',
                              'SACJ-v1 HMAC Auth',
                              AppColors.primaryNavy,
                            ),
                            _buildMetricColumn(
                              'Baterai Node',
                              'Sensor OS (Tidak terbaca)',
                              AppColors.textMuted,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // Kartu 2: Radar Sinyal Warga (Perangkat Terdekat)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.primaryNavy,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'RADAR SINYAL WARGA',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: AppColors.accentCyan,
                              letterSpacing: 0.5,
                            ),
                          ),
                          StatusBadge(
                            label: '${_peers.length} Terdeteksi',
                            backgroundColor: Colors.white.withValues(
                              alpha: 0.15,
                            ),
                            textColor: Colors.white,
                            fontSize: 10,
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Perangkat Terdekat',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Lacak relawan & warga di radius sinyal radio aktif untuk koordinasi darurat langsung.',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.8),
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Jangkauan Radio Fisik',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: AppColors.accentCyan,
                                  ),
                                ),
                                Text(
                                  '1-Hop Direct (~10-100m)',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white.withValues(alpha: 0.9),
                                  ),
                                ),
                              ],
                            ),
                            TextButton(
                              style: TextButton.styleFrom(
                                padding: EdgeInsets.zero,
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: widget.onNavigateToDevices,
                              child: const Text(
                                'Buka Pemetaan →',
                                style: TextStyle(
                                  color: AppColors.accentCyan,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMetricColumn(String label, String value, Color valueColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 3),
        Text(
          value,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: valueColor,
          ),
        ),
      ],
    );
  }
}

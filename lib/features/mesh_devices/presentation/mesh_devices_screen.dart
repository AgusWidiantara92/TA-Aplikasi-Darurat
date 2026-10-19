import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/transport/mesh_transport.dart';
import '../../../core/transport/transport_holder.dart';
import '../../../core/widgets/app_header.dart';
import '../../../core/widgets/status_badge.dart';
import '../../chat/data/repositories/chat_repository.dart';
import '../../chat/presentation/chat_detail_screen.dart';
import 'widgets/radar_widget.dart';

/// Layar Perangkat Terdekat & Radar sesuai referensi Layar 4 pada desain.jpg.
class MeshDevicesScreen extends StatefulWidget {
  final ChatRepository? repository;
  final MeshTransport? transport;

  const MeshDevicesScreen({super.key, this.repository, this.transport});

  @override
  State<MeshDevicesScreen> createState() => _MeshDevicesScreenState();
}

class _MeshDevicesScreenState extends State<MeshDevicesScreen> {
  late ChatRepository _repository;
  late MeshTransport _transport;
  StreamSubscription<List<DiscoveredPeer>>? _peersSub;
  StreamSubscription<TransportConnectionEvent>? _eventsSub;
  List<DiscoveredPeer> _physicalPeers = [];
  bool _isAdvertising = false;
  bool _isDiscovering = false;
  TransportConnectionEvent? _lastEvent;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? ChatRepositoryHolder.instance;
    _transport = widget.transport ?? MeshTransportHolder.instance;
    _isAdvertising = _transport.isAdvertising;
    _isDiscovering = _transport.isDiscovering;
    _physicalPeers = _transport.currentPeers;

    _peersSub = _transport.discoveredPeersStream.listen((peers) {
      if (!mounted) return;
      setState(() {
        _physicalPeers = peers;
        _isAdvertising = _transport.isAdvertising;
        _isDiscovering = _transport.isDiscovering;
      });
    });

    _eventsSub = _transport.connectionEventsStream.listen((event) {
      if (!mounted) return;
      setState(() {
        _lastEvent = event;
        _physicalPeers = _transport.currentPeers;
        _isAdvertising = _transport.isAdvertising;
        _isDiscovering = _transport.isDiscovering;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '[Transport 1-Hop] ${event.endpointName}: ${event.status.name} ${event.details ?? ""}',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    });
  }

  @override
  void dispose() {
    _peersSub?.cancel();
    _eventsSub?.cancel();
    super.dispose();
  }

  void _toggleAdvertising() async {
    if (_isAdvertising) {
      await _transport.stopAdvertising();
      if (!mounted) return;
      setState(() {
        _isAdvertising = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Siaran (Advertising) 1-hop dihentikan.'),
          duration: Duration(seconds: 1),
        ),
      );
    } else {
      final success = await _transport.startAdvertising(
        localNodeName:
            'SiagaMesh-${DateTime.now().millisecondsSinceEpoch % 1000}',
      );
      if (!mounted) return;
      setState(() {
        _isAdvertising = success;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success
                ? 'Siaran (Advertising) 1-hop AKTIF.'
                : 'Gagal mengaktifkan siaran (Periksa izin Bluetooth/Lokasi).',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _toggleDiscovery() async {
    if (_isDiscovering) {
      await _transport.stopDiscovery();
      if (!mounted) return;
      setState(() {
        _isDiscovering = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Pemindaian (Discovery) 1-hop dihentikan.'),
          duration: Duration(seconds: 1),
        ),
      );
    } else {
      final success = await _transport.startDiscovery();
      if (!mounted) return;
      setState(() {
        _isDiscovering = success;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success
                ? 'Pemindaian (Discovery) 1-hop AKTIF.'
                : 'Gagal memulai pemindaian (Periksa izin Bluetooth/Lokasi).',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _connectToPhysicalPeer(DiscoveredPeer peer) async {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Meminta koneksi 1-hop ke ${peer.endpointName}...'),
        duration: const Duration(seconds: 1),
      ),
    );
    await _transport.requestConnection(
      endpointId: peer.endpointId,
      localNodeName: 'SiagaMesh-User',
    );
  }

  void _disconnectPhysicalPeer(DiscoveredPeer peer) async {
    await _transport.disconnect(endpointId: peer.endpointId);
  }

  void _openChatWithPhysicalPeer(DiscoveredPeer peer) async {
    final conv = await _repository.getOrCreateConversationForNode(
      nodeId: 'peer-${peer.endpointId}',
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
          isEmergency: false,
          repository: _repository,
          transport: _transport,
          peerEndpointId: peer.endpointId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final blips = <RadarBlip>[];
    for (int i = 0; i < _physicalPeers.length; i++) {
      final peer = _physicalPeers[i];
      final angle =
          (i *
              (2 *
                  math.pi /
                  (_physicalPeers.isEmpty ? 1 : _physicalPeers.length))) +
          0.5;
      final distance = peer.status == PeerConnectionStatus.connected
          ? 0.45
          : (peer.status == PeerConnectionStatus.connecting ? 0.65 : 0.85);
      final color = peer.status == PeerConnectionStatus.connected
          ? AppColors.successGreen
          : (peer.status == PeerConnectionStatus.connecting
                ? AppColors.warningOrange
                : AppColors.accentBlue);
      blips.add(
        RadarBlip(
          label: peer.endpointName.length > 10
              ? peer.endpointName.substring(0, 10)
              : peer.endpointName,
          angle: angle,
          distanceFactor: distance,
          color: color,
        ),
      );
    }

    final connectedCount = _transport.connectedPeers.length;
    final availableCount = _physicalPeers
        .where((p) => p.status != PeerConnectionStatus.connected)
        .length;

    final String statusLabel;
    if (connectedCount > 0) {
      statusLabel = 'TERHUBUNG • $connectedCount PEER AKTIF';
    } else if (_isDiscovering) {
      statusLabel = 'MEMINDAI • ${_physicalPeers.length} PEER TERDETEKSI';
    } else if (_isAdvertising) {
      statusLabel = 'MENYIARKAN • NODE TERLIHAT';
    } else if (_lastEvent != null &&
        _lastEvent!.status == PeerConnectionStatus.disconnected &&
        _physicalPeers.isEmpty) {
      statusLabel = 'KONEKSI TERPUTUS • SIAGA';
    } else {
      statusLabel = 'MODE SIAGA • ${_physicalPeers.length} PEER TERDETEKSI';
    }

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
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                children: [
                  // Banner Card Biru Gelap
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.primaryNavy,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          statusLabel,
                          style: const TextStyle(
                            color: AppColors.accentCyan,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Perangkat Terdekat',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Memindai perangkat sekitar via Bluetooth LE & Wi-Fi Direct otomatis dalam jaringan mesh independen tanpa internet.',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.8),
                            fontSize: 12,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 14),

                  // Statistik Cepat (3 Kolom)
                  Row(
                    children: [
                      Expanded(
                        child: _buildMetricTile(
                          number: '$connectedCount',
                          label: 'TERHUBUNG',
                          color: AppColors.successGreen,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildMetricTile(
                          number: '$availableCount',
                          label: 'TERSEDIA',
                          color: AppColors.accentBlue,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildMetricTile(
                          number: '${_physicalPeers.length}',
                          label: 'TOTAL PEER',
                          color: AppColors.primaryNavy,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 14),

                  // Visualisasi Radar P2P
                  RadarWidget(
                    blips: blips,
                    isScanning: _isDiscovering || _isAdvertising,
                  ),

                  const SizedBox(height: 18),

                  // Bagian Kontrol Radio Transport Fisik 1-Hop
                  _buildRadioControls(),

                  const SizedBox(height: 18),

                  // Judul Bagian Peer
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Daftar Peer Terdeteksi (${_physicalPeers.length})',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: AppColors.primaryNavy,
                        ),
                      ),
                      StatusBadge(
                        label: _physicalPeers.isNotEmpty
                            ? '${_physicalPeers.length} TERDETEKSI'
                            : 'KOSONG',
                        backgroundColor: _physicalPeers.isNotEmpty
                            ? AppColors.accentPillBg
                            : AppColors.surfaceSubtle,
                        textColor: _physicalPeers.isNotEmpty
                            ? AppColors.accentBlue
                            : AppColors.textMuted,
                        fontSize: 9,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 10),

                  // Daftar Peer atau Empty State
                  if (_physicalPeers.isEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        vertical: 24,
                        horizontal: 16,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: AppColors.borderLight),
                      ),
                      child: Column(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: const BoxDecoration(
                              color: AppColors.surfaceSubtle,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.wifi_tethering_off_rounded,
                              size: 32,
                              color: AppColors.textMuted,
                            ),
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'Belum Ada Peer Terdeteksi',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: AppColors.primaryNavy,
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'Aktifkan Siaran di satu perangkat dan Pindai di perangkat lainnya untuk membentuk koneksi mesh 1-hop nirkabel (tanpa internet).',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.textSecondary,
                              height: 1.4,
                            ),
                          ),
                          if (!_isDiscovering) ...[
                            const SizedBox(height: 14),
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                side: const BorderSide(
                                  color: AppColors.primaryNavy,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              onPressed: _toggleDiscovery,
                              icon: const Icon(
                                Icons.search,
                                size: 16,
                                color: AppColors.primaryNavy,
                              ),
                              label: const Text(
                                'Mulai Pemindaian Sekarang',
                                style: TextStyle(
                                  color: AppColors.primaryNavy,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    )
                  else
                    ..._physicalPeers.map(
                      (peer) => _buildPhysicalPeerCard(peer),
                    ),

                  const SizedBox(height: 16),

                  // Tombol Pindai Perangkat Sekitar
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      backgroundColor: _isDiscovering
                          ? AppColors.surfaceSubtle
                          : AppColors.primaryNavy,
                      foregroundColor: _isDiscovering
                          ? AppColors.primaryNavy
                          : Colors.white,
                      elevation: _isDiscovering ? 0 : 2,
                      side: _isDiscovering
                          ? const BorderSide(color: AppColors.borderLight)
                          : null,
                    ),
                    onPressed: _toggleDiscovery,
                    child: Text(
                      _isDiscovering
                          ? 'Hentikan Pemindaian'
                          : 'Pindai Perangkat Sekitar',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),

                  const SizedBox(height: 6),

                  const Center(
                    child: Text(
                      'Koneksi peer-to-peer menggunakan Nearby Connections tanpa kuota internet.',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.textMuted,
                      ),
                    ),
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

  Widget _buildMetricTile({
    required String number,
    required String label,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Column(
        children: [
          Text(
            number,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: AppColors.textMuted,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRadioControls() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.accentBlue.withValues(alpha: 0.3)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
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
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: (_isAdvertising || _isDiscovering)
                          ? AppColors.successGreen
                          : AppColors.textMuted,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'Kontrol Radio Mesh 1-Hop',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: AppColors.primaryNavy,
                    ),
                  ),
                ],
              ),
              const StatusBadge(
                label: 'Nearby P2P_CLUSTER',
                backgroundColor: AppColors.accentPillBg,
                textColor: AppColors.accentBlue,
                fontSize: 9,
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Komunikasi langsung nirkabel antar-perangkat Android via Bluetooth LE dan Wi-Fi Direct.',
            style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    backgroundColor: _isAdvertising
                        ? AppColors.accentBlue.withValues(alpha: 0.1)
                        : Colors.transparent,
                    side: BorderSide(
                      color: _isAdvertising
                          ? AppColors.accentBlue
                          : AppColors.borderLight,
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: _toggleAdvertising,
                  child: Text(
                    _isAdvertising ? 'Siaran: AKTIF' : 'Mulai Siaran',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: _isAdvertising
                          ? AppColors.accentBlue
                          : AppColors.primaryNavy,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    backgroundColor: _isDiscovering
                        ? AppColors.primaryNavy.withValues(alpha: 0.1)
                        : Colors.transparent,
                    side: BorderSide(
                      color: _isDiscovering
                          ? AppColors.primaryNavy
                          : AppColors.borderLight,
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: _toggleDiscovery,
                  child: Text(
                    _isDiscovering ? 'Pindai: AKTIF' : 'Mulai Pindai',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: AppColors.primaryNavy,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPhysicalPeerCard(DiscoveredPeer peer) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: peer.status == PeerConnectionStatus.connected
              ? AppColors.successGreen.withValues(alpha: 0.5)
              : AppColors.borderLight,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: peer.status == PeerConnectionStatus.connected
                  ? AppColors.successGreen.withValues(alpha: 0.15)
                  : AppColors.accentBlue.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.phone_android,
              size: 20,
              color: peer.status == PeerConnectionStatus.connected
                  ? AppColors.successGreen
                  : AppColors.accentBlue,
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
                ),
                const SizedBox(height: 2),
                Text(
                  peer.status == PeerConnectionStatus.connected
                      ? 'ID: #${peer.endpointId} • Terhubung Langsung'
                      : (peer.status == PeerConnectionStatus.connecting
                            ? 'ID: #${peer.endpointId} • Menghubungkan...'
                            : 'ID: #${peer.endpointId} • Sinyal Terdeteksi'),
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (peer.status == PeerConnectionStatus.connected) ...[
            InkWell(
              onTap: () => _openChatWithPhysicalPeer(peer),
              borderRadius: BorderRadius.circular(16),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: AppColors.primaryNavy,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Text(
                  'Kirim Pesan',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            InkWell(
              onTap: () => _disconnectPhysicalPeer(peer),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(
                  Icons.close,
                  size: 18,
                  color: AppColors.emergencyRed,
                ),
              ),
            ),
          ] else if (peer.status == PeerConnectionStatus.connecting) ...[
            const StatusBadge(
              label: 'Menghubungkan...',
              backgroundColor: AppColors.warningOrangeLight,
              textColor: AppColors.warningOrange,
              fontSize: 9,
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            ),
          ] else ...[
            InkWell(
              onTap: () => _connectToPhysicalPeer(peer),
              borderRadius: BorderRadius.circular(16),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: AppColors.accentPillBg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: AppColors.accentBlue.withValues(alpha: 0.4),
                  ),
                ),
                child: const Text(
                  'Hubungkan',
                  style: TextStyle(
                    color: AppColors.accentBlue,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

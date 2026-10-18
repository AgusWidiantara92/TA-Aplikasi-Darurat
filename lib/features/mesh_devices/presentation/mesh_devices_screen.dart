import 'dart:async';
import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/transport/mesh_transport.dart';
import '../../../core/transport/transport_holder.dart';
import '../../../core/widgets/app_header.dart';
import '../../../core/widgets/status_badge.dart';
import '../../chat/data/repositories/chat_repository.dart';
import '../../chat/presentation/chat_detail_screen.dart';
import '../models/mesh_node.dart';
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
  bool _isScanning = false;

  late ChatRepository _repository;
  late MeshTransport _transport;
  StreamSubscription<List<DiscoveredPeer>>? _peersSub;
  StreamSubscription<TransportConnectionEvent>? _eventsSub;
  List<DiscoveredPeer> _physicalPeers = [];
  bool _isAdvertising = false;
  bool _isDiscovering = false;
  late List<MeshNode> _nodes;

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
      });
    });

    _eventsSub = _transport.connectionEventsStream.listen((event) {
      if (!mounted) return;
      setState(() {
        _physicalPeers = _transport.currentPeers;
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

    _loadInitialNodes();
  }

  @override
  void dispose() {
    _peersSub?.cancel();
    _eventsSub?.cancel();
    super.dispose();
  }

  void _loadInitialNodes() {
    _nodes = const [
      MeshNode(
        id: 'node-1',
        name: 'Posko Relawan Utama',
        distanceText: 'Jarak: ~15 meter • Sinyal Kuat',
        signalQuality: 'Kuat',
        status: MeshNodeStatus.connected,
        subInfo: 'Kanal Darurat Aktif',
        isEmergencyChannel: true,
        radarAngle: 0.8,
        radarRadiusRatio: 0.45,
      ),
      MeshNode(
        id: 'node-2',
        name: 'Repeater SAR Sektor 2',
        distanceText: 'Jarak: ~45 meter • Sinyal Baik',
        signalQuality: 'Baik',
        status: MeshNodeStatus.connected,
        subInfo: 'Jalur Relai Otomatis',
        radarAngle: 2.2,
        radarRadiusRatio: 0.65,
      ),
      MeshNode(
        id: 'node-3',
        name: 'Galaxy A54',
        distanceText: 'Jarak: ~30 meter • Siap Tersambung',
        signalQuality: 'Cukup',
        status: MeshNodeStatus.available,
        subInfo: 'Otentikasi Siap',
        radarAngle: 3.8,
        radarRadiusRatio: 0.78,
      ),
      MeshNode(
        id: 'node-4',
        name: 'Redmi Note 12',
        distanceText: 'Jarak: ~50 meter',
        signalQuality: 'Lemah',
        status: MeshNodeStatus.connecting,
        subInfo: 'Proses negosiasi...',
        radarAngle: 5.1,
        radarRadiusRatio: 0.9,
      ),
    ];
  }

  void _triggerSimulatedScan() {
    setState(() {
      _isScanning = true;
    });

    Future.delayed(const Duration(milliseconds: 1200), () {
      if (!mounted) return;
      setState(() {
        _isScanning = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Pemindaian simulasi selesai. Ditemukan 4 node (Data Mock).',
          ),
          duration: Duration(seconds: 2),
        ),
      );
    });
  }

  void _navigateToChat(MeshNode node) async {
    final conv = await _repository.getOrCreateConversationForNode(
      nodeId: node.id,
      nodeName: node.name,
      isEmergency: node.isEmergencyChannel,
      isConnected: node.status == MeshNodeStatus.connected,
    );
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatDetailScreen(
          conversationId: conv.id,
          conversationTitle: conv.title,
          nodeId: conv.nodeId,
          isEmergency: conv.isEmergency,
          repository: _repository,
        ),
      ),
    );
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
    final blips = [
      const RadarBlip(
        label: 'SAR-2',
        angle: 2.2,
        distanceFactor: 0.65,
        color: AppColors.accentBlue,
      ),
      const RadarBlip(
        label: 'A01',
        angle: 0.8,
        distanceFactor: 0.45,
        color: AppColors.emergencyRed,
      ),
      const RadarBlip(
        label: 'Warga',
        angle: 3.8,
        distanceFactor: 0.78,
        color: AppColors.successGreen,
      ),
    ];

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
                        const Text(
                          'PENCARIAN AKTIF • 5 NODE TERDETEKSI (SIMULASI)',
                          style: TextStyle(
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
                          'Memindai perangkat sekitar via Bluetooth LE & Wi-Fi Aware otomatis dalam jaringan mesh independen (Simulasi UI).',
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
                          number: '3',
                          label: 'TERHUBUNG',
                          color: AppColors.primaryNavy,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildMetricTile(
                          number: '2',
                          label: 'TERSEDIA',
                          color: AppColors.accentBlue,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildMetricTile(
                          number: '~120m',
                          label: 'RENTANG MESH',
                          color: AppColors.primaryNavy,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 14),

                  // Visualisasi Radar P2P
                  RadarWidget(blips: blips),

                  const SizedBox(height: 18),

                  // Bagian Eksperimen Transport Fisik 1-Hop
                  _buildPhysicalTransportSection(),

                  const SizedBox(height: 18),

                  // Judul Bagian Node
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: const [
                      Text(
                        'Daftar Node Terjangkau',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: AppColors.primaryNavy,
                        ),
                      ),
                      StatusBadge(
                        label: 'KAPASITAS PENUH (DEMO)',
                        backgroundColor: AppColors.surfaceSubtle,
                        textColor: AppColors.textSecondary,
                        fontSize: 9,
                        padding: EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 10),

                  // Daftar Node
                  ..._nodes.map((node) => _buildNodeCard(node)),

                  const SizedBox(height: 14),

                  // Tombol Pindai Ulang Perangkat
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      backgroundColor: AppColors.primaryNavy,
                    ),
                    onPressed: _isScanning ? null : _triggerSimulatedScan,
                    child: _isScanning
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.white,
                              ),
                            ),
                          )
                        : const Text(
                            'Pindai Ulang Perangkat (Simulasi)',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                  ),

                  const SizedBox(height: 6),

                  const Center(
                    child: Text(
                      'Pembaruan otomatis berikutnya setiap 10 detik (Simulasi)',
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

  Widget _buildNodeCard(MeshNode node) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  node.name,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: AppColors.primaryNavy,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  node.distanceText,
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    if (node.isEmergencyChannel) ...[
                      Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                          color: AppColors.emergencyRed,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                    ],
                    Text(
                      node.subInfo,
                      style: TextStyle(
                        fontSize: 11,
                        color: node.isEmergencyChannel
                            ? AppColors.emergencyRed
                            : AppColors.textMuted,
                        fontWeight: node.isEmergencyChannel
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _buildStatusPill(node.status),
              const SizedBox(height: 6),
              _buildActionButton(node),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusPill(MeshNodeStatus status) {
    switch (status) {
      case MeshNodeStatus.connected:
        return const StatusBadge(
          label: 'Terhubung',
          backgroundColor: AppColors.accentPillBg,
          textColor: AppColors.accentBlue,
          fontSize: 9,
          padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        );
      case MeshNodeStatus.available:
        return const StatusBadge(
          label: 'Tersedia',
          backgroundColor: AppColors.surfaceSubtle,
          textColor: AppColors.textSecondary,
          fontSize: 9,
          padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        );
      case MeshNodeStatus.connecting:
        return const StatusBadge(
          label: 'Menghubungkan...',
          backgroundColor: AppColors.warningOrangeLight,
          textColor: AppColors.warningOrange,
          fontSize: 9,
          padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        );
    }
  }

  Widget _buildActionButton(MeshNode node) {
    if (node.status == MeshNodeStatus.connected) {
      return InkWell(
        onTap: () => _navigateToChat(node),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
      );
    } else if (node.status == MeshNodeStatus.available) {
      return InkWell(
        onTap: () {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Simulasi jabat tangan dengan ${node.name}...'),
              duration: const Duration(seconds: 1),
            ),
          );
        },
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
      );
    } else {
      return const Text(
        'Menunggu jabat tangan',
        style: TextStyle(
          fontSize: 10,
          color: AppColors.textMuted,
          fontStyle: FontStyle.italic,
        ),
      );
    }
  }

  Widget _buildPhysicalTransportSection() {
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
                    'Transport Fisik 1-Hop',
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
            'Eksperimen koneksi langsung antar-perangkat Android tanpa internet atau router.',
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
          const SizedBox(height: 12),
          Text(
            'Peer Fisik Terdeteksi (${_physicalPeers.length})',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: AppColors.primaryNavy,
            ),
          ),
          const SizedBox(height: 6),
          if (_physicalPeers.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surfaceSubtle,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Text(
                'Belum ada peer fisik terdeteksi. Aktifkan Siaran di satu HP dan Pindai di HP lainnya.',
                style: TextStyle(fontSize: 11, color: AppColors.textMuted),
                textAlign: TextAlign.center,
              ),
            )
          else
            ..._physicalPeers.map((peer) => _buildPhysicalPeerCard(peer)),
        ],
      ),
    );
  }

  Widget _buildPhysicalPeerCard(DiscoveredPeer peer) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surfaceSubtle,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: peer.status == PeerConnectionStatus.connected
              ? AppColors.successGreen.withValues(alpha: 0.5)
              : AppColors.borderLight,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
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
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  peer.endpointName,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: AppColors.primaryNavy,
                  ),
                ),
                Text(
                  'ID: #${peer.endpointId} • 1-Hop Direct',
                  style: const TextStyle(
                    fontSize: 10,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          if (peer.status == PeerConnectionStatus.connected) ...[
            InkWell(
              onTap: () => _openChatWithPhysicalPeer(peer),
              borderRadius: BorderRadius.circular(14),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: AppColors.primaryNavy,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Text(
                  'Pesan 1-Hop',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            InkWell(
              onTap: () => _disconnectPhysicalPeer(peer),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(
                  Icons.close,
                  size: 16,
                  color: AppColors.emergencyRed,
                ),
              ),
            ),
          ] else if (peer.status == PeerConnectionStatus.connecting) ...[
            const StatusBadge(
              label: 'Menghubungkan',
              backgroundColor: AppColors.warningOrangeLight,
              textColor: AppColors.warningOrange,
              fontSize: 9,
              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            ),
          ] else ...[
            InkWell(
              onTap: () => _connectToPhysicalPeer(peer),
              borderRadius: BorderRadius.circular(14),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: AppColors.accentPillBg,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: AppColors.accentBlue.withValues(alpha: 0.4),
                  ),
                ),
                child: const Text(
                  'Hubungkan',
                  style: TextStyle(
                    color: AppColors.accentBlue,
                    fontSize: 10,
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

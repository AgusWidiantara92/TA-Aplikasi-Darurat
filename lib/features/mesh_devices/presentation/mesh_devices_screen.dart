import 'dart:async';
import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/routing/node_identity.dart';
import '../../../core/routing/routing_holder.dart';
import '../../../core/transport/connectivity_prerequisite_service.dart';
import '../../../core/transport/mesh_transport.dart';
import '../../../core/transport/transport_holder.dart';
import '../../../core/widgets/app_header.dart';
import '../../../core/widgets/siagamesh_dialog.dart';
import '../../../core/widgets/status_badge.dart';
import '../../chat/data/repositories/chat_repository.dart';
import '../../chat/presentation/chat_detail_screen.dart';

/// Layar Perangkat Terdekat yang bersih, intuitif, dan ramah pengguna tanpa radar dekoratif.
class MeshDevicesScreen extends StatefulWidget {
  final ChatRepository? repository;
  final MeshTransport? transport;
  final ConnectivityPrerequisiteService? prerequisiteService;

  const MeshDevicesScreen({
    super.key,
    this.repository,
    this.transport,
    this.prerequisiteService,
  });

  @override
  State<MeshDevicesScreen> createState() => _MeshDevicesScreenState();
}

class _MeshDevicesScreenState extends State<MeshDevicesScreen>
    with WidgetsBindingObserver {
  late ChatRepository _repository;
  late MeshTransport _transport;
  late ConnectivityPrerequisiteService _prerequisiteService;
  StreamSubscription<List<DiscoveredPeer>>? _peersSub;
  StreamSubscription<TransportConnectionEvent>? _eventsSub;
  List<DiscoveredPeer> _physicalPeers = [];
  bool _isAdvertising = false;
  bool _isDiscovering = false;
  bool _isDialogShowing = false;
  bool _isOperating = false;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? ChatRepositoryHolder.instance;
    _transport = widget.transport ?? MeshTransportHolder.instance;
    _prerequisiteService =
        widget.prerequisiteService ?? ConnectivityPrerequisiteHolder.instance;
    WidgetsBinding.instance.addObserver(this);

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
        _physicalPeers = _transport.currentPeers;
        _isAdvertising = _transport.isAdvertising;
        _isDiscovering = _transport.isDiscovering;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${event.endpointName}: ${event.status.name} ${event.details ?? ""}',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      setState(() {
        _isAdvertising = _transport.isAdvertising;
        _isDiscovering = _transport.isDiscovering;
        _physicalPeers = _transport.currentPeers;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _peersSub?.cancel();
    _eventsSub?.cancel();
    super.dispose();
  }

  Future<void> _showPrerequisiteDialog({
    required String title,
    required String message,
    required List<SiagaMeshDialogAction> actions,
    IconData icon = Icons.info_outline_rounded,
    Color? iconColor,
  }) async {
    if (_isDialogShowing || !mounted) return;
    _isDialogShowing = true;
    try {
      await SiagaMeshDialog.show(
        context: context,
        icon: icon,
        iconColor: iconColor ?? AppColors.primaryNavy,
        title: title,
        message: message,
        actions: actions,
      );
    } finally {
      _isDialogShowing = false;
    }
  }

  Future<bool> _ensurePrerequisitesMet({required VoidCallback onRetry}) async {
    final check = await _prerequisiteService.checkPrerequisites();

    if (check.isReady) {
      return true;
    }

    if (check.status == PrerequisiteStatus.permissionPermanentlyDenied) {
      await _showPrerequisiteDialog(
        title: 'Izin Diperlukan',
        message:
            'SiagaMesh memerlukan izin Nearby/Bluetooth untuk mencari perangkat tanpa internet. Buka Pengaturan aplikasi untuk mengaktifkannya.',
        icon: Icons.security_rounded,
        iconColor: AppColors.emergencyRed,
        actions: [
          SiagaMeshDialogAction(
            label: 'Buka Pengaturan',
            isPrimary: true,
            onPressed: () {
              Navigator.pop(context);
              _prerequisiteService.openAppSettings();
            },
          ),
          SiagaMeshDialogAction(
            label: 'Batal',
            onPressed: () => Navigator.pop(context),
          ),
        ],
      );
      return false;
    }

    if (check.status == PrerequisiteStatus.permissionRequired) {
      final granted = await _prerequisiteService.requestPermissions();
      if (granted) {
        final recheck = await _prerequisiteService.checkPrerequisites();
        if (recheck.isReady) {
          return true;
        } else if (recheck.status == PrerequisiteStatus.bluetoothDisabled) {
          return _handleBluetoothDisabled(onRetry);
        }
      }

      final recheck = await _prerequisiteService.checkPrerequisites();
      if (recheck.permanentlyDenied) {
        await _showPrerequisiteDialog(
          title: 'Izin Diperlukan',
          message:
              'SiagaMesh memerlukan izin Nearby/Bluetooth untuk mencari perangkat tanpa internet. Buka Pengaturan aplikasi untuk mengaktifkannya.',
          icon: Icons.security_rounded,
          iconColor: AppColors.emergencyRed,
          actions: [
            SiagaMeshDialogAction(
              label: 'Buka Pengaturan',
              isPrimary: true,
              onPressed: () {
                Navigator.pop(context);
                _prerequisiteService.openAppSettings();
              },
            ),
            SiagaMeshDialogAction(
              label: 'Batal',
              onPressed: () => Navigator.pop(context),
            ),
          ],
        );
      } else {
        await _showPrerequisiteDialog(
          title: 'Izin Diperlukan',
          message:
              'SiagaMesh memerlukan izin perangkat sekitar (Bluetooth & Wi-Fi) untuk mencari perangkat tanpa internet.',
          icon: Icons.security_rounded,
          iconColor: AppColors.primaryNavy,
          actions: [
            SiagaMeshDialogAction(
              label: 'Buka Pengaturan',
              isPrimary: true,
              onPressed: () {
                Navigator.pop(context);
                _prerequisiteService.openAppSettings();
              },
            ),
            SiagaMeshDialogAction(
              label: 'Coba Lagi',
              isOutlined: true,
              onPressed: () {
                Navigator.pop(context);
                onRetry();
              },
            ),
            SiagaMeshDialogAction(
              label: 'Nanti',
              onPressed: () => Navigator.pop(context),
            ),
          ],
        );
      }
      return false;
    }

    if (check.status == PrerequisiteStatus.bluetoothDisabled) {
      return _handleBluetoothDisabled(onRetry);
    }

    await _showPrerequisiteDialog(
      title: 'Koneksi Belum Siap',
      message:
          'SiagaMesh memerlukan akses konektivitas untuk mencari perangkat di sekitar. Periksa izin aplikasi serta pengaturan Bluetooth dan Wi-Fi, kemudian coba kembali.',
      icon: Icons.bluetooth_disabled_rounded,
      iconColor: AppColors.warningOrange,
      actions: [
        SiagaMeshDialogAction(
          label: 'Buka Pengaturan',
          isPrimary: true,
          onPressed: () {
            Navigator.pop(context);
            _prerequisiteService.openAppSettings();
          },
        ),
        SiagaMeshDialogAction(
          label: 'Coba Lagi',
          isOutlined: true,
          onPressed: () {
            Navigator.pop(context);
            onRetry();
          },
        ),
        SiagaMeshDialogAction(
          label: 'Nanti',
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );
    return false;
  }

  Future<bool> _handleBluetoothDisabled(VoidCallback onRetry) async {
    await _showPrerequisiteDialog(
      title: 'Bluetooth Belum Aktif',
      message:
          'Bluetooth belum aktif. Aktifkan Bluetooth pada perangkat Anda untuk mendeteksi dan menghubungkan node di sekitar.',
      icon: Icons.bluetooth_disabled_rounded,
      iconColor: AppColors.warningOrange,
      actions: [
        SiagaMeshDialogAction(
          label: 'Buka Pengaturan',
          isPrimary: true,
          onPressed: () {
            Navigator.pop(context);
            _prerequisiteService.openBluetoothSettings();
          },
        ),
        SiagaMeshDialogAction(
          label: 'Coba Lagi',
          isOutlined: true,
          onPressed: () {
            Navigator.pop(context);
            onRetry();
          },
        ),
        SiagaMeshDialogAction(
          label: 'Nanti',
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );
    return false;
  }

  Future<void> _showDiagnosticFailureDialog({
    required TransportDiagnosticReport report,
    required VoidCallback onRetry,
  }) async {
    if (_isDialogShowing || !mounted) return;
    _isDialogShowing = true;

    String action = report.suggestedAction;
    if (report.category == TransportFailureCategory.transportInitFailed &&
        report.operation == 'startAdvertising') {
      action = 'Pastikan radio nirkabel aktif dan coba lagi.';
    } else if (report.category == TransportFailureCategory.unknown) {
      action = 'Silakan coba kembali.';
    } else if (action.isEmpty) {
      action = 'Coba lagi dalam beberapa saat.';
    }

    final String message = '${report.userFriendlyMessage} $action'.trim();

    try {
      await SiagaMeshDialog.show(
        context: context,
        icon: Icons.error_outline_rounded,
        iconColor: AppColors.emergencyRed,
        title: 'Gagal Memulai Koneksi',
        message: message,
        actions: [
          SiagaMeshDialogAction(
            label: 'Coba Lagi',
            isPrimary: true,
            onPressed: () {
              Navigator.pop(context);
              onRetry();
            },
          ),
          SiagaMeshDialogAction(
            label: 'Nanti',
            onPressed: () => Navigator.pop(context),
          ),
        ],
      );
    } finally {
      _isDialogShowing = false;
    }
  }

  void _toggleAdvertising() async {
    if (_isOperating) return;
    _isOperating = true;

    bool needsFailureDialog = false;
    TransportDiagnosticReport? failureReport;

    if (_isAdvertising) {
      await _transport.stopAdvertising();
      if (!mounted) return;
      setState(() {
        _isAdvertising = false;
      });
      _isOperating = false;
    } else {
      final ready = await _ensurePrerequisitesMet(onRetry: _toggleAdvertising);
      if (!ready || !mounted) {
        _isOperating = false;
        return;
      }

      // Gunakan nama ramah pengguna (displayName) untuk advertising
      final localName = ManetRoutingHolder.displayName;
      final success = await _transport.startAdvertising(
        localNodeName: localName,
      );

      if (!mounted) {
        _isOperating = false;
        return;
      }
      setState(() {
        _isAdvertising = success;
      });

      if (!success) {
        failureReport = _transport.lastDiagnosticReport;
        needsFailureDialog = true;
      }
      _isOperating = false;

      if (needsFailureDialog && failureReport != null) {
        _showDiagnosticFailureDialog(
          report: failureReport,
          onRetry: _toggleAdvertising,
        );
      }
    }
  }

  void _toggleDiscovery() async {
    if (_isOperating) return;
    _isOperating = true;

    bool needsFailureDialog = false;
    TransportDiagnosticReport? failureReport;

    if (_isDiscovering) {
      await _transport.stopDiscovery();
      if (!mounted) return;
      setState(() {
        _isDiscovering = false;
      });
      _isOperating = false;
    } else {
      final ready = await _ensurePrerequisitesMet(onRetry: _toggleDiscovery);
      if (!ready || !mounted) {
        _isOperating = false;
        return;
      }

      final success = await _transport.startDiscovery();
      if (!mounted) {
        _isOperating = false;
        return;
      }
      setState(() {
        _isDiscovering = success;
      });

      if (!success) {
        failureReport = _transport.lastDiagnosticReport;
        needsFailureDialog = true;
      }
      _isOperating = false;

      if (needsFailureDialog && failureReport != null) {
        _showDiagnosticFailureDialog(
          report: failureReport,
          onRetry: _toggleDiscovery,
        );
      }
    }
  }

  void _connectToPhysicalPeer(DiscoveredPeer peer) async {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Meminta koneksi ke ${peer.endpointName}...'),
        duration: const Duration(seconds: 1),
      ),
    );
    await _transport.requestConnection(
      endpointId: peer.endpointId,
      localNodeName: ManetRoutingHolder.displayName,
    );
  }

  void _disconnectPhysicalPeer(DiscoveredPeer peer) async {
    await _transport.disconnect(endpointId: peer.endpointId);
  }

  void _openChatWithPhysicalPeer(DiscoveredPeer peer) async {
    final routing = ManetRoutingHolder.instance;
    final resolvedNodeId = routing.neighborTable.getNodeIdForEndpoint(
      peer.endpointId,
    );
    final targetNodeId = resolvedNodeId ?? 'peer-${peer.endpointId}';

    final conv = _repository is LocalChatRepository
        ? await (_repository as LocalChatRepository)
              .getOrCreateConversationForNode(
                nodeId: targetNodeId,
                nodeName: peer.endpointName,
                isConnected: peer.status == PeerConnectionStatus.connected,
                endpointId: peer.endpointId,
              )
        : await _repository.getOrCreateConversationForNode(
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
          peerEndpointId:
              routing.neighborTable.getEndpointIdForNode(targetNodeId) ??
              peer.endpointId,
        ),
      ),
    );
  }

  /// Menduplikasi daftar peer yang ditemukan berdasarkan identitas node kanonis.
  List<DiscoveredPeer> _deduplicatePeers(List<DiscoveredPeer> peers) {
    final routing = ManetRoutingHolder.instance;
    final Map<String, DiscoveredPeer> grouped = {};

    for (final peer in peers) {
      final resolvedNodeId = routing.neighborTable.getNodeIdForEndpoint(
        peer.endpointId,
      );
      // Gunakan nodeId terverifikasi jika ada, atau endpointId jika masih pending
      // Jangan pernah gunakan displayName agar dua perangkat berbeda dengan nama sama tidak digabungkan
      final key =
          resolvedNodeId != null && !resolvedNodeId.startsWith('pending-')
          ? 'node:${resolvedNodeId.toLowerCase()}'
          : 'ep:${peer.endpointId}';

      if (!grouped.containsKey(key)) {
        grouped[key] = peer;
      } else {
        final current = grouped[key]!;
        // Prioritaskan endpoint yang sedang terhubung aktif
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
  Widget build(BuildContext context) {
    final dedupedPeers = _deduplicatePeers(_physicalPeers);
    final connectedCount = dedupedPeers
        .where((p) => p.status == PeerConnectionStatus.connected)
        .length;
    final totalCount = dedupedPeers.length;

    // Status label terpadu
    final String statusLabel;
    if (connectedCount > 0) {
      statusLabel = 'TERHUBUNG • $connectedCount PEER AKTIF';
    } else if (_isDiscovering) {
      statusLabel = 'MEMINDAI • $totalCount PEER TERDETEKSI';
    } else if (_isAdvertising) {
      statusLabel = 'MENYIARKAN • NODE TERLIHAT';
    } else {
      statusLabel = 'MODE SIAGA • $totalCount PEER TERDETEKSI';
    }

    // Hitung kemunculan nama untuk deteksi nama duplikat antar perangkat unik
    final nameCounts = <String, int>{};
    for (final p in dedupedPeers) {
      final key = p.endpointName.trim().toLowerCase();
      nameCounts[key] = (nameCounts[key] ?? 0) + 1;
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
                  // Kartu Ringkasan Perangkat
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
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(
                                statusLabel,
                                style: const TextStyle(
                                  color: AppColors.accentCyan,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (_isDiscovering)
                              const Icon(
                                Icons.sync,
                                size: 14,
                                color: AppColors.accentCyan,
                              ),
                          ],
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
                        const Text(
                          'Komunikasi langsung nirkabel antar-perangkat via Bluetooth LE dan Wi-Fi Direct tanpa internet.',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Statistik Cepat Ringkas (2 Kolom)
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
                          number: '$totalCount',
                          label: 'TOTAL TERDETEKSI',
                          color: AppColors.primaryNavy,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 14),

                  // Kontrol Radio Nirkabel
                  _buildRadioControls(),

                  const SizedBox(height: 16),

                  // Header Daftar Peer
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          'Daftar Peer Terdeteksi ($totalCount)',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: AppColors.primaryNavy,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      StatusBadge(
                        label: dedupedPeers.isNotEmpty
                            ? '$totalCount TERDETEKSI'
                            : 'KOSONG',
                        backgroundColor: dedupedPeers.isNotEmpty
                            ? AppColors.accentPillBg
                            : AppColors.surfaceSubtle,
                        textColor: dedupedPeers.isNotEmpty
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

                  // Daftar Peer atau Empty State Bersih
                  if (dedupedPeers.isEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        vertical: 28,
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
                          Text(
                            _isDiscovering
                                ? 'Belum Ada Perangkat Ditemukan'
                                : 'Belum Ada Peer Terdeteksi',
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: AppColors.primaryNavy,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _isDiscovering
                                ? 'Perangkat sekitar belum terdeteksi. Pastikan perangkat lain juga menjalankan SiagaMesh dan berada dalam jangkauan.'
                                : 'Aktifkan Siaran di satu perangkat dan Pindai di perangkat lainnya untuk membentuk koneksi mesh 1-hop nirkabel (tanpa internet).',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.textSecondary,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    ...dedupedPeers.map((peer) {
                      final routing = ManetRoutingHolder.instance;
                      final resolvedNodeId = routing.neighborTable
                          .getNodeIdForEndpoint(peer.endpointId);
                      final isDup =
                          (nameCounts[peer.endpointName.trim().toLowerCase()] ??
                              0) >
                          1;
                      return _buildPhysicalPeerCard(
                        peer,
                        resolvedNodeId: resolvedNodeId,
                        isDuplicate: isDup,
                      );
                    }),

                  const SizedBox(height: 14),

                  // Tombol Pindai Perangkat Sekitar Utama
                  ElevatedButton.icon(
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
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: _toggleDiscovery,
                    icon: _isDiscovering
                        ? const Icon(Icons.stop_circle_outlined, size: 18)
                        : const Icon(Icons.search, size: 18),
                    label: Text(
                      _isDiscovering
                          ? 'Hentikan Pemindaian'
                          : 'Pindai Perangkat Sekitar',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
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
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
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
              fontSize: 17,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          const SizedBox(height: 2),
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
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Row(
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
                  borderRadius: BorderRadius.circular(10),
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
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: _toggleDiscovery,
              child: Text(
                _isDiscovering ? 'Pindai: AKTIF' : 'Mulai Pindai',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: AppColors.primaryNavy,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhysicalPeerCard(
    DiscoveredPeer peer, {
    String? resolvedNodeId,
    bool isDuplicate = false,
  }) {
    final initials = _getInitials(peer.endpointName);
    final displayTitle = NodeIdentity.formatDisplayName(
      peer.endpointName,
      resolvedNodeId,
      endpointId: peer.endpointId,
      isDuplicate: isDuplicate,
    );

    final isConnected = peer.status == PeerConnectionStatus.connected;
    final isConnecting = peer.status == PeerConnectionStatus.connecting;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isConnected
              ? AppColors.successGreen.withValues(alpha: 0.4)
              : AppColors.borderLight,
        ),
      ),
      child: Row(
        children: [
          // Avatar Berinisial
          CircleAvatar(
            radius: 19,
            backgroundColor: isConnected
                ? AppColors.successGreen
                : (isConnecting
                      ? AppColors.warningOrange
                      : AppColors.primaryNavy),
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
          // Info Peer
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayTitle,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: AppColors.primaryNavy,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  isConnected
                      ? 'Terhubung Langsung'
                      : (isConnecting
                            ? 'Menghubungkan...'
                            : 'Sinyal Ditemukan'),
                  style: TextStyle(
                    fontSize: 11,
                    color: isConnected
                        ? AppColors.successGreen
                        : (isConnecting
                              ? AppColors.warningOrange
                              : AppColors.textMuted),
                    fontWeight: isConnected
                        ? FontWeight.w600
                        : FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Tombol Aksi
          if (isConnected) ...[
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
              onPressed: () => _openChatWithPhysicalPeer(peer),
              child: const Text(
                'Kirim Pesan',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(
                Icons.close,
                size: 18,
                color: AppColors.emergencyRed,
              ),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              tooltip: 'Putuskan Koneksi',
              onPressed: () => _disconnectPhysicalPeer(peer),
            ),
          ] else if (isConnecting) ...[
            const StatusBadge(
              label: 'Menghubungkan...',
              backgroundColor: AppColors.warningOrangeLight,
              textColor: AppColors.warningOrange,
              fontSize: 9,
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            ),
          ] else ...[
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.accentBlue,
                side: BorderSide(
                  color: AppColors.accentBlue.withValues(alpha: 0.5),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                minimumSize: const Size(0, 32),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: () => _connectToPhysicalPeer(peer),
              child: const Text(
                'Hubungkan',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

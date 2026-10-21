import 'dart:async';
import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/routing/node_identity.dart';
import '../../../core/routing/routing_holder.dart';
import '../../../core/transport/mesh_transport.dart';
import '../../../core/transport/transport_holder.dart';
import '../../../core/widgets/status_badge.dart';

/// Layar Profil dan Pengaturan Nama Perangkat SiagaMesh.
class ProfileScreen extends StatefulWidget {
  final MeshTransport? transport;

  const ProfileScreen({super.key, this.transport});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late MeshTransport _transport;
  StreamSubscription<NodeIdentity>? _identitySub;
  StreamSubscription<TransportConnectionEvent>? _eventsSub;
  String _displayName = '';
  String _shortNodeId = '';
  String _fullNodeId = '';
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _transport = widget.transport ?? MeshTransportHolder.instance;
    _loadIdentity();

    _identitySub = ManetRoutingHolder.identityStream.listen((identity) {
      if (!mounted) return;
      setState(() {
        _displayName = identity.displayName;
        _shortNodeId = identity.shortId;
        _fullNodeId = identity.id;
      });
    });

    _eventsSub = _transport.connectionEventsStream.listen((_) {
      if (!mounted) return;
      setState(() {});
    });
  }

  void _loadIdentity() {
    setState(() {
      _displayName = ManetRoutingHolder.displayName;
      _shortNodeId = ManetRoutingHolder.shortNodeId;
      _fullNodeId = ManetRoutingHolder.localNodeId;
    });
  }

  @override
  void dispose() {
    _identitySub?.cancel();
    _eventsSub?.cancel();
    super.dispose();
  }

  String _getInitials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts[0].isEmpty) return 'SM';
    if (parts.length == 1) {
      final w = parts[0];
      return w.substring(0, w.length >= 2 ? 2 : 1).toUpperCase();
    }
    return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
  }

  Future<void> _showEditNameDialog() async {
    final textController = TextEditingController(text: _displayName);
    final formKey = GlobalKey<FormState>();
    String? localError;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: AppColors.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              title: Row(
                children: const [
                  Icon(Icons.badge_outlined, color: AppColors.primaryNavy),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Ubah Nama Perangkat',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: AppColors.primaryNavy,
                      ),
                    ),
                  ),
                ],
              ),
              content: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Nama ini akan terlihat oleh perangkat SiagaMesh lain di sekitar Anda saat komunikasi offline.',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: textController,
                      maxLength: 24,
                      autofocus: true,
                      decoration: InputDecoration(
                        labelText: 'Nama Perangkat',
                        hintText: 'Contoh: Agus, Infinix, Posko Medis',
                        errorText: localError,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Nama tidak boleh kosong';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        _buildSuggestionChip('Agus', textController),
                        _buildSuggestionChip('Infinix', textController),
                        _buildSuggestionChip('Posko Medis', textController),
                        _buildSuggestionChip('Relawan 01', textController),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Batal'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryNavy,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: () async {
                    if (formKey.currentState?.validate() ?? false) {
                      final input = textController.text.trim();
                      Navigator.pop(ctx);
                      await _saveNewName(input);
                    }
                  },
                  child: const Text('Simpan'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildSuggestionChip(String text, TextEditingController controller) {
    return ActionChip(
      label: Text(text, style: const TextStyle(fontSize: 11)),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      onPressed: () {
        controller.text = text;
        controller.selection = TextSelection.fromPosition(
          TextPosition(offset: text.length),
        );
      },
    );
  }

  Future<void> _saveNewName(String newName) async {
    setState(() => _isSaving = true);
    try {
      final saved = await ManetRoutingHolder.updateDisplayName(newName);
      if (!mounted) return;
      setState(() {
        _displayName = saved;
        _isSaving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppColors.primaryNavy,
          content: Text('Nama perangkat diperbarui menjadi "$saved".'),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppColors.emergencyRed,
          content: Text('Gagal menyimpan nama: $e'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final connectedCount = _transport.connectedPeers.length;
    final initials = _getInitials(_displayName);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        titleSpacing: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Profil & Identitas Perangkat',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.bold,
            color: AppColors.primaryNavy,
          ),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 8),

              // Avatar Berinisial Besar
              Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  color: AppColors.primaryNavy,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primaryNavy.withValues(alpha: 0.2),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Center(
                  child: Text(
                    initials,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // Nama Perangkat Utama
              Text(
                _displayName.isNotEmpty ? _displayName : 'SiagaMesh',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: AppColors.primaryNavy,
                ),
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 4),

              // Suffix Singkat
              Text(
                'ID Perangkat: #$_shortNodeId',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textMuted,
                  fontWeight: FontWeight.w500,
                ),
              ),

              const SizedBox(height: 18),

              // Kartu Pengaturan Nama Perangkat
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.borderLight),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'NAMA PERANGKAT',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textMuted,
                            letterSpacing: 0.5,
                          ),
                        ),
                        if (_isSaving)
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _displayName,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: AppColors.primaryNavy,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Nama ini akan terlihat oleh perangkat SiagaMesh lain di sekitar. Anda dapat menggunakan nama orang, tipe ponsel, atau posko relawan.',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: AppColors.primaryNavy),
                          foregroundColor: AppColors.primaryNavy,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        onPressed: _showEditNameDialog,
                        icon: const Icon(Icons.edit_outlined, size: 16),
                        label: const Text(
                          'Ubah Nama',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 14),

              // Kartu Status Konektivitas
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.borderLight),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'STATUS JARINGAN OFFLINE',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textMuted,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        StatusBadge(
                          label: connectedCount > 0
                              ? 'TERHUBUNG ($connectedCount PEER)'
                              : 'MODE SIAGA',
                          backgroundColor: connectedCount > 0
                              ? AppColors.successGreenLight
                              : AppColors.surfaceSubtle,
                          textColor: connectedCount > 0
                              ? AppColors.successGreen
                              : AppColors.textSecondary,
                          icon: connectedCount > 0
                              ? Icons.wifi_tethering
                              : Icons.wifi_tethering_off,
                        ),
                        const StatusBadge(
                          label: 'P2P Cluster',
                          backgroundColor: AppColors.accentPillBg,
                          textColor: AppColors.accentBlue,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      connectedCount > 0
                          ? 'Perangkat ini terhubung langsung dengan $connectedCount node tetangga nirkabel offline.'
                          : 'Tidak ada sesi koneksi langsung saat ini. Buka tab Perangkat untuk memindai.',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 14),

              // Bagian Detail Teknis (Dapat Diperluas)
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.borderLight),
                ),
                child: Theme(
                  data: Theme.of(
                    context,
                  ).copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    title: const Text(
                      'Detail Teknis Protokol',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: AppColors.primaryNavy,
                      ),
                    ),
                    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    children: [
                      _buildTechRow('Protokol MANET Node ID', _fullNodeId),
                      const SizedBox(height: 8),
                      _buildTechRow('Format Paket', 'SACJ-v1 Header HMAC'),
                      const SizedBox(height: 8),
                      _buildTechRow(
                        'Keamanan IDS',
                        'Selective Forwarding Detection (Active)',
                      ),
                      const SizedBox(height: 8),
                      _buildTechRow(
                        'Trust Management',
                        'Dynamic Trust Scoring (EMA)',
                      ),
                      const SizedBox(height: 8),
                      _buildTechRow(
                        'Konsensus Audit',
                        'Lightweight BlockDAG Ledger',
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTechRow(String title, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 10, color: AppColors.textMuted),
        ),
        const SizedBox(height: 2),
        SelectableText(
          value,
          style: const TextStyle(
            fontSize: 12,
            fontFamily: 'monospace',
            fontWeight: FontWeight.bold,
            color: AppColors.primaryNavy,
          ),
        ),
      ],
    );
  }
}

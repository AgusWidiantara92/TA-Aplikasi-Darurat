import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/widgets/app_header.dart';
import '../../../core/widgets/status_badge.dart';

/// Layar Beranda (Home) sesuai referensi Layar 1 pada desain.jpg.
class HomeScreen extends StatelessWidget {
  final VoidCallback? onNavigateToMessages;
  final VoidCallback? onNavigateToDevices;

  const HomeScreen({
    super.key,
    this.onNavigateToMessages,
    this.onNavigateToDevices,
  });

  void _showSosDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: const [
            Icon(
              Icons.warning_amber_rounded,
              color: AppColors.emergencyRed,
              size: 28,
            ),
            SizedBox(width: 8),
            Text(
              'Simulasi SOS',
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
              'Tombol ini adalah simulasi pengiriman pesan darurat (SOS) untuk keperluan penelitian.',
              style: TextStyle(fontSize: 14, color: AppColors.textPrimary),
            ),
            SizedBox(height: 12),
            Text(
              'Pada tahap ini, transmisi radio offline belum dilakukan. Paket darurat belum disiarkan ke perangkat nyata.',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Tutup'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.emergencyRed,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  backgroundColor: AppColors.primaryNavy,
                  content: Text(
                    'Peringatan SOS tersimpan di memori lokal (Mode Demonstrasi).',
                  ),
                ),
              );
            },
            child: const Text('Uji Simulasi SOS'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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

              // Banner Status Peringatan Simulasi
              Container(
                width: double.infinity,
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: AppColors.accentPillBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.accentCyanLight),
                ),
                child: Row(
                  children: const [
                    Icon(
                      Icons.info_outline,
                      size: 16,
                      color: AppColors.accentBlue,
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Mode Demonstrasi: data & komunikasi bersifat mock.',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.accentPillText,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 8),

              // Baris Status Frekuensi & Siaga
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    StatusBadge(
                      label: 'STATUS SIAGA DARURAT (DEMO)',
                      backgroundColor: AppColors.accentCyanLight,
                      textColor: AppColors.accentBlue,
                      icon: Icons.wifi_tethering,
                    ),
                    StatusBadge(
                      label: 'Frekuensi 915 MHz (Mock)',
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
                  children: [
                    const Text(
                      'Halo, apa yang bisa kami bantu?',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: AppColors.primaryNavy,
                        letterSpacing: -0.4,
                      ),
                    ),
                    const SizedBox(height: 6),
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
                  onTap: () => _showSosDialog(context),
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
                          children: const [
                            Icon(
                              Icons.emergency_share,
                              color: Colors.white,
                              size: 20,
                            ),
                            SizedBox(width: 8),
                            Text(
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
                          'Prioritas transmisi ke seluruh node dalam jangkauan (Simulasi)',
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

              // Kartu 1: Konektivitas Mesh (Simulasi)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: InkWell(
                  onTap: onNavigateToMessages,
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
                              children: const [
                                Text(
                                  'KONEKTIVITAS MESH',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textMuted,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                                SizedBox(height: 2),
                                Text(
                                  'Jaringan Lokal Aktif',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.primaryNavy,
                                  ),
                                ),
                              ],
                            ),
                            StatusBadge(
                              label: 'Mode P2P Demo',
                              backgroundColor: AppColors.accentPillBg,
                              textColor: AppColors.accentBlue,
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            StatusBadge(
                              label: '4 Perangkat Sekitar',
                              backgroundColor: AppColors.surfaceSubtle,
                              textColor: AppColors.primaryNavy,
                              icon: Icons.devices,
                              fontSize: 11,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
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
                        // Parameter Teknis (Mock)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            _buildMetricColumn(
                              'Kekuatan Hop',
                              'Optimal (0.8 detik)',
                              AppColors.successGreen,
                            ),
                            _buildMetricColumn(
                              'Enkripsi',
                              'AES-256 GCM (Mock)',
                              AppColors.primaryNavy,
                            ),
                            _buildMetricColumn(
                              'Baterai Node',
                              '94% Siap',
                              AppColors.primaryNavy,
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
                            label: '8 Terdeteksi (Simulasi)',
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
                                  'Cakupan Radius Wilayah',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: AppColors.accentCyan,
                                  ),
                                ),
                                Text(
                                  '2.1km Persegi (Simulasi)',
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
                              onPressed: onNavigateToDevices,
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

import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../../core/constants/app_colors.dart';

/// Data titik blip pada visualisasi radar sinyal.
class RadarBlip {
  final String label;
  final double angle; // dalam radian
  final double distanceFactor; // 0.0 (pusat) hingga 1.0 (lingkaran terluar)
  final Color color;

  const RadarBlip({
    required this.label,
    required this.angle,
    required this.distanceFactor,
    this.color = AppColors.accentBlue,
  });
}

/// Widget visualisasi radar sinyal P2P menggunakan CustomPainter.
class RadarWidget extends StatelessWidget {
  final List<RadarBlip> blips;
  final bool isScanning;

  const RadarWidget({super.key, required this.blips, this.isScanning = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceSubtle,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: const [
              Text(
                'Radar Sinyal Peer-to-Peer',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: AppColors.primaryNavy,
                ),
              ),
              Text(
                'Wi-Fi Direct / BLE',
                style: TextStyle(
                  fontSize: 10,
                  color: AppColors.textMuted,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 180,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CustomPaint(
                  size: const Size(double.infinity, 180),
                  painter: _RadarPainter(blips: blips),
                ),
                if (blips.isEmpty)
                  Positioned(
                    bottom: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        isScanning
                            ? 'Sedang memindai sinyal sekitar...'
                            : 'Belum ada perangkat terdeteksi di radar',
                        style: const TextStyle(
                          fontSize: 10,
                          color: AppColors.textMuted,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: const [
              Text(
                'Protokol: MANET P2P_CLUSTER',
                style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
              ),
              Text(
                'Nearby Connections',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  final List<RadarBlip> blips;

  _RadarPainter({required this.blips});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = math.min(size.width / 2, size.height / 2) - 16;

    final ringPaint = Paint()
      ..color = AppColors.accentBlue.withValues(alpha: 0.18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    final crossPaint = Paint()
      ..color = AppColors.accentBlue.withValues(alpha: 0.12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    // Gambar lingkaran konsentris
    for (int i = 1; i <= 3; i++) {
      final r = maxRadius * (i / 3);
      canvas.drawCircle(center, r, ringPaint);
    }

    // Gambar garis sumbu silang
    canvas.drawLine(
      Offset(center.dx - maxRadius, center.dy),
      Offset(center.dx + maxRadius, center.dy),
      crossPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - maxRadius),
      Offset(center.dx, center.dy + maxRadius),
      crossPaint,
    );

    // Titik pusat (Node perangkat Anda)
    final centerDotPaint = Paint()
      ..color = AppColors.primaryNavy
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, 5, centerDotPaint);

    final centerRingPaint = Paint()
      ..color = AppColors.accentCyan.withValues(alpha: 0.4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawCircle(center, 10, centerRingPaint);

    // Gambar titik node (blip)
    final textPainter = TextPainter(textDirection: TextDirection.ltr);

    for (final blip in blips) {
      final r = maxRadius * blip.distanceFactor;
      final x = center.dx + r * math.cos(blip.angle);
      final y = center.dy + r * math.sin(blip.angle);
      final blipOffset = Offset(x, y);

      // Lingkaran luar berdenyut
      final pulsePaint = Paint()
        ..color = blip.color.withValues(alpha: 0.25)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(blipOffset, 8, pulsePaint);

      // Titik inti blip
      final dotPaint = Paint()
        ..color = blip.color
        ..style = PaintingStyle.fill;
      canvas.drawCircle(blipOffset, 4, dotPaint);

      // Label teks node
      textPainter.text = TextSpan(
        text: blip.label,
        style: const TextStyle(
          color: AppColors.primaryNavy,
          fontSize: 9,
          fontWeight: FontWeight.bold,
          backgroundColor: Colors.white70,
        ),
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(x - (textPainter.width / 2), y + 10));
    }
  }

  @override
  bool shouldRepaint(covariant _RadarPainter oldDelegate) => true;
}

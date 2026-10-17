import 'package:flutter/material.dart';
import '../constants/app_colors.dart';
import 'status_badge.dart';

/// Header konsisten di bagian atas layar sesuai referensi desain.jpg:
/// Judul "SiagaMesh", badge "MESH MODE", dan avatar profil.
class AppHeader extends StatelessWidget {
  final VoidCallback? onProfileTap;

  const AppHeader({
    super.key,
    this.onProfileTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              const Text(
                'SiagaMesh',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: AppColors.primaryNavy,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(width: 8),
              StatusBadge(
                label: 'MESH MODE (SIMULASI)',
                backgroundColor: AppColors.accentPillBg,
                textColor: AppColors.accentPillText,
                fontSize: 10,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              ),
            ],
          ),
          InkWell(
            onTap: onProfileTap ??
                () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Profil Pengguna (Mode Demonstrasi)'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
            borderRadius: BorderRadius.circular(20),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppColors.primaryNavy,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.borderLight, width: 1.5),
              ),
              child: const Icon(
                Icons.person,
                color: Colors.white,
                size: 20,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

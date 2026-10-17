import 'package:flutter/material.dart';

/// Palet warna utama aplikasi SiagaMesh berdasarkan referensi desain.jpg.
class AppColors {
  AppColors._();

  // Warna Dominan (Navy)
  static const Color primaryNavy = Color(0xFF0B2240);
  static const Color primaryNavyDark = Color(0xFF07172B);
  static const Color primaryNavyLight = Color(0xFF16345A);

  // Aksen Sekunder (Cyan / Biru Terang)
  static const Color accentBlue = Color(0xFF2F80ED);
  static const Color accentCyan = Color(0xFF38BDF8);
  static const Color accentCyanLight = Color(0xFFE0F2FE);
  static const Color accentPillBg = Color(0xFFEBF4FF);
  static const Color accentPillText = Color(0xFF1D4ED8);

  // Indikator Peringatan / Darurat (Coral / Red)
  static const Color emergencyRed = Color(0xFFEB5757);
  static const Color emergencyRedLight = Color(0xFFFDEDED);
  static const Color emergencyRedDark = Color(0xFFB91C1C);

  // Indikator Aman / Aktif (Green)
  static const Color successGreen = Color(0xFF27AE60);
  static const Color successGreenLight = Color(0xFFE8F5E9);

  // Indikator Peringatan Sedang (Orange / Amber)
  static const Color warningOrange = Color(0xFFF2994A);
  static const Color warningOrangeLight = Color(0xFFFFF7ED);

  // Latar Belakang & Permukaan
  static const Color background = Color(0xFFF8FAFC);
  static const Color surface = Colors.white;
  static const Color surfaceSubtle = Color(0xFFF1F5F9);
  static const Color borderLight = Color(0xFFE2E8F0);

  // Tipografi & Teks
  static const Color textPrimary = Color(0xFF0F172A);
  static const Color textSecondary = Color(0xFF64748B);
  static const Color textMuted = Color(0xFF94A3B8);
  static const Color textOnPrimary = Colors.white;
}

import 'package:flutter/material.dart';
import '../constants/app_colors.dart';

/// Konfigurasi tombol aksi untuk [SiagaMeshDialog].
class SiagaMeshDialogAction {
  final String label;
  final VoidCallback onPressed;
  final bool isPrimary;
  final bool isDestructive;
  final bool isOutlined;
  final Color? customColor;

  const SiagaMeshDialogAction({
    required this.label,
    required this.onPressed,
    this.isPrimary = false,
    this.isDestructive = false,
    this.isOutlined = false,
    this.customColor,
  });
}

/// Dialog standar SiagaMesh yang responsif dan anti-overflow.
///
/// Memastikan baris judul dibungkus [Expanded], konten dibungkus [SingleChildScrollView],
/// dan tombol aksi disusun secara vertikal ([Column] dengan lebar penuh) sehingga
/// tidak terjadi RenderFlex overflow pada layar perangkat dengan lebar terbatas.
class SiagaMeshDialog extends StatelessWidget {
  final IconData? icon;
  final Color? iconColor;
  final String title;
  final String? message;
  final Widget? contentWidget;
  final List<SiagaMeshDialogAction> actions;

  const SiagaMeshDialog({
    super.key,
    this.icon,
    this.iconColor,
    required this.title,
    this.message,
    this.contentWidget,
    required this.actions,
  });

  /// Menampilkan [SiagaMeshDialog] secara modal.
  static Future<T?> show<T>({
    required BuildContext context,
    IconData? icon,
    Color? iconColor,
    required String title,
    String? message,
    Widget? contentWidget,
    required List<SiagaMeshDialogAction> actions,
    bool barrierDismissible = true,
  }) {
    return showDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (ctx) => SiagaMeshDialog(
        icon: icon,
        iconColor: iconColor,
        title: title,
        message: message,
        contentWidget: contentWidget,
        actions: actions,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      backgroundColor: AppColors.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Baris Judul dengan Ikon dan Text yang dibungkus Expanded
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (icon != null) ...[
                    Icon(
                      icon,
                      color: iconColor ?? AppColors.primaryNavy,
                      size: 26,
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        color: AppColors.primaryNavy,
                        fontWeight: FontWeight.bold,
                        fontSize: 17,
                      ),
                      softWrap: true,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // Area Konten yang dapat digulir jika teks panjang
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (message != null)
                        Text(
                          message!,
                          style: const TextStyle(
                            fontSize: 13,
                            color: AppColors.textPrimary,
                            height: 1.4,
                          ),
                        ),
                      if (contentWidget != null) ...[
                        if (message != null) const SizedBox(height: 10),
                        contentWidget!,
                      ],
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 18),

              // Daftar Tombol Aksi disusun vertikal agar tidak overflow
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: actions.map((action) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _buildActionButton(context, action),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActionButton(
    BuildContext context,
    SiagaMeshDialogAction action,
  ) {
    if (action.isDestructive) {
      return ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.emergencyRed,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
        onPressed: action.onPressed,
        child: Text(
          action.label,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      );
    }

    if (action.isPrimary) {
      return ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: action.customColor ?? AppColors.primaryNavy,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
        onPressed: action.onPressed,
        child: Text(
          action.label,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      );
    }

    if (action.isOutlined) {
      return OutlinedButton(
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: action.customColor ?? AppColors.primaryNavy),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
        onPressed: action.onPressed,
        child: Text(
          action.label,
          style: TextStyle(
            color: action.customColor ?? AppColors.primaryNavy,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
    }

    // Default tombol sekunder / batal / nanti
    return TextButton(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.textSecondary,
        padding: const EdgeInsets.symmetric(vertical: 10),
      ),
      onPressed: action.onPressed,
      child: Text(action.label),
    );
  }
}

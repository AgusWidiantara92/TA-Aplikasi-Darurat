import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app.dart';
import 'core/routing/routing_holder.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Mengunci orientasi potret dan mengatur warna status bar
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ),
  );

  // Inisialisasi bootstrap subsistem keamanan dan perutean MANET
  await ManetRoutingHolder.initialize();

  runApp(const SiagaMeshApp());
}

// Dart imports:
import 'dart:io';

// Flutter imports:
import 'package:flutter/material.dart';
// Package imports:
import 'package:package_info_plus/package_info_plus.dart';

// Project imports:
import 'gui/app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final packageInfo = await PackageInfo.fromPlatform();

  final env = Platform.environment;

  const debugEnv = bool.fromEnvironment("DEBUG", defaultValue: false);
  const romsEnv = String.fromEnvironment("ROMS", defaultValue: "");
  const discEnv = String.fromEnvironment("DISC", defaultValue: "");
  const romEnv = String.fromEnvironment("ROM", defaultValue: "");
  final config = Config(
    debug: debugEnv,
    roms: romsEnv.split(",").where((s) => s.isNotEmpty).toList(),
    disc: discEnv,
    rom: romEnv,
    discDir: env['DISC_DIR'] ?? '',
  );

  runApp(MyApp(title: "fnesemu ${packageInfo.version}", config: config));
}

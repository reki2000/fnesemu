// Dart imports:
import 'dart:io';

// Flutter imports:
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
// Package imports:
import 'package:package_info_plus/package_info_plus.dart';

// Project imports:
import 'gui/app.dart';
import 'gui/storage.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final packageInfo = await PackageInfo.fromPlatform();

  // environment variables are not available on web
  final env = kIsWeb ? const <String, String>{} : Platform.environment;

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

  final storage = await Storage.open();

  runApp(MyApp(
      title: "fnesemu ${packageInfo.version}",
      storage: storage,
      config: config));
}

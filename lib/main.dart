// Dart imports:

// Flutter imports:
import 'package:flutter/material.dart';
// Package imports:
import 'package:package_info_plus/package_info_plus.dart';

// Project imports:
import 'gui/app.dart';
import 'gui/storage.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final packageInfo = await PackageInfo.fromPlatform();

  const debugEnv = bool.fromEnvironment("DEBUG", defaultValue: false);
  const config = Config(debug: debugEnv);

  final storage = await Storage.open();

  runApp(MyApp(
      title: "fnesemu ${packageInfo.version}",
      storage: storage,
      config: config));
}

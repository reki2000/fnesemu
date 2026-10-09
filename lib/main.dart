import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

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

import 'package:flutter/material.dart';
import 'package:fnesemu_core/app_api.dart';

import 'gui/app.dart';
import 'gui/storage.dart';

// the version given by --dart-define=APP_VERSION=... at build time
const _version = String.fromEnvironment('APP_VERSION');

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  logs.sink = (event) => debugPrint(event.toString());

  const debugEnv = bool.fromEnvironment("DEBUG", defaultValue: false);
  const config = Config(debug: debugEnv);

  final storage = await Storage.open();

  runApp(MyApp(
      title: _version.isEmpty ? "fnesemu" : "fnesemu $_version",
      storage: storage,
      config: config));
}

import 'package:web/web.dart' as web;

/// the OS, the browser and the logical processors
Future<Map<String, Object?>> hostInfo() async {
  final navigator = web.window.navigator;
  return {
    'os': 'web',
    'osVersion': navigator.userAgent,
    'cores': navigator.hardwareConcurrency,
  };
}

/// the clock of the CPU in MHz now; browsers do not tell it
Future<int?> currentCpuMHz() async => null;

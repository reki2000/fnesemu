import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

/// the OS, the CPU model, the logical processors and their highest clocks
Future<Map<String, Object?>> hostInfo() async {
  final info = <String, Object?>{
    'os': Platform.operatingSystem,
    'osVersion': Platform.operatingSystemVersion,
    'cores': Platform.numberOfProcessors,
  };
  try {
    if (Platform.isLinux || Platform.isAndroid) {
      info.addAll(await _linux());
    } else if (Platform.isWindows) {
      info.addAll(await _windows());
    } else if (Platform.isMacOS || Platform.isIOS) {
      info.addAll(_apple());
    }
  } catch (_) {
    // the record keeps what could be read
  }
  return info;
}

/// the highest current clock of the CPUs in MHz, where the OS tells it
Future<int?> currentCpuMHz() async {
  if (!Platform.isLinux && !Platform.isAndroid) return null;
  try {
    final clocks = _cpuFiles('scaling_cur_freq');
    if (clocks.isNotEmpty) return clocks.reduce((a, b) => a > b ? a : b);
    final mhz = _cpuinfo('cpu MHz').map(double.tryParse).nonNulls;
    return mhz.isEmpty ? null : mhz.reduce((a, b) => a > b ? a : b).round();
  } catch (_) {
    return null;
  }
}

List<String> _cpuinfo(String key) => [
      for (final line in File('/proc/cpuinfo').readAsLinesSync())
        if (line.split(':').first.trim() == key)
          line.substring(line.indexOf(':') + 1).trim()
    ];

/// a cpufreq file of each CPU, in MHz
List<int> _cpuFiles(String name) => [
      for (var i = 0; i < Platform.numberOfProcessors; i++)
        if (File('/sys/devices/system/cpu/cpu$i/cpufreq/$name') case final f
            when f.existsSync())
          int.parse(f.readAsStringSync().trim()) ~/ 1000
    ];

/// the clusters of clocks, such as 4x1800+2x2350+2x2850
String? _clusters(List<int> mhz) {
  if (mhz.isEmpty) return null;
  final counts = <int, int>{};
  for (final m in mhz) {
    counts[m] = (counts[m] ?? 0) + 1;
  }
  final keys = counts.keys.toList()..sort();
  return keys.map((m) => '${counts[m]}x$m').join('+');
}

Future<String?> _getprop(String name) async {
  final r = await Process.run('getprop', [name]);
  final value = (r.stdout as String).trim();
  return value.isEmpty ? null : value;
}

Future<Map<String, Object?>> _linux() async {
  final model =
      _cpuinfo('model name').firstOrNull ?? _cpuinfo('Hardware').firstOrNull;
  final info = <String, Object?>{
    if (model != null) 'cpu': model,
    'cpuMaxMHz': _clusters(_cpuFiles('cpuinfo_max_freq')) ??
        _cpuinfo('cpu MHz').map(double.tryParse).nonNulls.firstOrNull?.round(),
  };
  if (Platform.isAndroid) {
    for (final (key, prop) in const [
      ('device', 'ro.product.model'),
      ('soc', 'ro.soc.model'),
      ('socMaker', 'ro.soc.manufacturer'),
      ('board', 'ro.board.platform'),
    ]) {
      if (await _getprop(prop) case final value?) info[key] = value;
    }
  }
  return info;
}

Future<Map<String, Object?>> _windows() async {
  final r = await Process.run(
      'reg',
      [
        'query',
        r'HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0',
      ],
      stdoutEncoding: const SystemEncoding());
  final info = <String, Object?>{};
  for (final line in LineSplitter.split(r.stdout as String)) {
    final parts = line.trim().split(RegExp(r'\s{2,}|\t'));
    if (parts.length < 3) continue;
    if (parts[0] == 'ProcessorNameString') info['cpu'] = parts[2].trim();
    if (parts[0] == '~MHz') info['cpuMaxMHz'] = int.tryParse(parts[2]);
  }
  final hex = info['cpuMaxMHz'] == null
      ? RegExp(r'~MHz\s+REG_DWORD\s+0x([0-9a-fA-F]+)')
          .firstMatch(r.stdout as String)
      : null;
  if (hex != null) info['cpuMaxMHz'] = int.parse(hex.group(1)!, radix: 16);
  return info;
}

typedef _SysctlC = Int32 Function(
    Pointer<Uint8>, Pointer<Uint8>, Pointer<IntPtr>, Pointer<Uint8>, IntPtr);
typedef _Sysctl = int Function(
    Pointer<Uint8>, Pointer<Uint8>, Pointer<IntPtr>, Pointer<Uint8>, int);

Map<String, Object?> _apple() {
  final lib = DynamicLibrary.process();
  final sysctl = lib.lookupFunction<_SysctlC, _Sysctl>('sysctlbyname');
  final malloc = lib.lookupFunction<Pointer<Uint8> Function(IntPtr),
      Pointer<Uint8> Function(int)>('malloc');
  final free = lib.lookupFunction<Void Function(Pointer<Uint8>),
      void Function(Pointer<Uint8>)>('free');

  // the raw bytes of a sysctl value, or null when the name is unknown
  List<int>? read(String name) {
    final key = utf8.encode(name);
    final cName = malloc(key.length + 1);
    final value = malloc(256);
    final size = malloc(sizeOf<IntPtr>()).cast<IntPtr>();
    try {
      cName.asTypedList(key.length + 1)
        ..setAll(0, key)
        ..[key.length] = 0;
      size.value = 256;
      if (sysctl(cName, value, size, nullptr, 0) != 0) return null;
      return value.asTypedList(size.value).toList();
    } finally {
      free(cName);
      free(value);
      free(size.cast());
    }
  }

  String? text(String name) {
    final bytes = read(name);
    if (bytes == null) return null;
    final end = bytes.indexOf(0);
    return utf8.decode(end < 0 ? bytes : bytes.sublist(0, end)).trim();
  }

  int? number(String name) {
    final bytes = read(name);
    if (bytes == null || bytes.isEmpty) return null;
    var value = 0;
    for (var i = bytes.length - 1; i >= 0; i--) {
      value = value << 8 | bytes[i];
    }
    return value;
  }

  final hz = number('hw.cpufrequency_max');
  return {
    if (text('machdep.cpu.brand_string') case final cpu?) 'cpu': cpu,
    // iOS: the model identifier such as iPad11,3; macOS: the CPU type
    if (text('hw.machine') case final machine?) 'machine': machine,
    if (text('hw.model') case final model?) 'model': model,
    if (number('hw.perflevel0.logicalcpu') case final p?) 'performanceCores': p,
    if (number('hw.perflevel1.logicalcpu') case final e?) 'efficiencyCores': e,
    if (hz != null) 'cpuMaxMHz': hz ~/ 1000000,
  };
}

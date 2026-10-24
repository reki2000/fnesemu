import 'dart:convert';
import 'dart:io';

const defaultBenchmarkLock = '/tmp/claude-1000/fnesemu-bench.lock';

/// Waits for the external start signal or holds flock until released.
Future<Process?> acquireBenchmarkLock(String? path, {String? syncDir}) async {
  if (syncDir != null) {
    File('$syncDir/ready.$pid').writeAsStringSync('');
    while (!File('$syncDir/go').existsSync()) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    return null;
  }
  if (path == null) return null;
  final process = await Process.start(
      'flock', [path, 'sh', '-c', 'echo locked; read release']);
  try {
    final ready = await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first;
    if (ready != 'locked') throw StateError('The lock $path was not acquired');
    return process;
  } catch (_) {
    await releaseBenchmarkLock(process);
    rethrow;
  }
}

Future<void> releaseBenchmarkLock(Process? process) async {
  if (process == null) return;
  await process.stdin.close();
  await process.exitCode;
}

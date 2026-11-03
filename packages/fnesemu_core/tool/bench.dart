// Synthetic benchmarks of the emulator cores that need no BIOS, ROM or disc images.
//
// usage: dart build cli -t tool/bench.dart -o /tmp/bench
//        /tmp/bench/bundle/bin/bench <core|all> [workload|all] [rounds]
//        cores: ps, n64, ps2, dc, gba
//        (with no workload the default workload of the core runs: ps cpu, n64 cpu, ps2 ee, dc cpu; the default rounds is 5)
//        (the jit workloads need the native library that dart build cli bundles; an executable from dart compile exe cannot load it)
//        (dart run tool/bench.dart ... also works, but its times are JIT VM times; build the AOT executable to decide speed, as in tool/dart_aot_tips.md)
//
// A new core adds one file under tool/bench/ with its workloads and one entry in tool/bench/registry.dart.
//
// Every workload prints a checksum that a faster version must keep equal.
import 'bench/registry.dart';
import 'bench/workload.dart';

void _runWorkload(String core, String name, BenchWorkload workload, int rounds) {
  final run = workload.run;
  int? checksum;
  var best = double.infinity;
  for (var round = 0; round < rounds; round++) {
    final sw = Stopwatch()..start();
    final (hashOf, count) = run();
    sw.stop();
    final hash = hashOf();
    checksum ??= hash;
    if (hash != checksum) {
      throw StateError('checksum changed between rounds: $hash');
    }
    final ms = sw.elapsedMicroseconds / 1000;
    if (ms < best) best = ms;
    print('round $round: ${ms.toStringAsFixed(1)} ms '
        '(${(count / (ms / 1000)).toStringAsFixed(0)} ${workload.unit}/s)');
  }
  print('$core/$name: best ${best.toStringAsFixed(1)} ms, checksum $checksum');
}

void _runCore(
    String core, Map<String, BenchWorkload> workloads, String? name, int rounds) {
  final workloadName = name ?? workloads.keys.first;
  if (workloadName == 'all') {
    for (final entry in workloads.entries) {
      _runWorkload(core, entry.key, entry.value, rounds);
    }
    return;
  }
  final workload = workloads[workloadName];
  if (workload == null) {
    throw ArgumentError('unknown workload: $workloadName');
  }
  _runWorkload(core, workloadName, workload, rounds);
}

void main(List<String> args) {
  if (args.isEmpty) {
    throw ArgumentError('usage: bench <core|all> [workload|all] [rounds]');
  }
  final coreName = args[0];
  final workloadName = args.length > 1 ? args[1] : null;
  final rounds = args.length > 2 ? int.parse(args[2]) : 5;
  if (coreName == 'all') {
    var found = false;
    for (final entry in benchCores.entries) {
      if (workloadName != null &&
          workloadName != 'all' &&
          !entry.value.containsKey(workloadName)) {
        continue;
      }
      found = true;
      _runCore(entry.key, entry.value, workloadName, rounds);
    }
    if (!found) {
      throw ArgumentError('unknown workload: $workloadName');
    }
    return;
  }
  final workloads = benchCores[coreName];
  if (workloads == null) {
    throw ArgumentError('unknown core: $coreName');
  }
  _runCore(coreName, workloads, workloadName, rounds);
}

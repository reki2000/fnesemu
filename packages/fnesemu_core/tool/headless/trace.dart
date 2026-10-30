import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fnesemu_core/src/core.dart';
import 'package:fnesemu_core/src/internal/tracer.dart';
import 'package:fnesemu_core/src/types.dart';

import 'options.dart';
import 'session.dart';

const traceUsage = """
trace <core> <media...> [options]: records the instructions of each cpu through the
  tracer of the debugger
  --warmup N         frames to run before recording (default: 0)
  --load-state FILE  restore a state saved by run or bench before the warmup
  --from-pc HEX      after the warmup, start recording when the pc of cpu 0 is HEX
  --steps N          debugger steps to record (default: 30000)
  -o, --out DIR      output directory (default: /tmp/core_headless_trace)
  writes, for each cpu, cpuN.raw.jsonl (every instruction) and cpuN.<mode>.log
  (the tracer output in each repeat mode), and statistics.json and trace.md (an
  excerpt of each mode)""";

Future<void> trace(List<String> args) async {
  final o = Options.parse(args,
      valued: {...mediaValued, "--warmup", "--load-state", "--from-pc", "--steps", "--out"},
      flags: mediaFlags,
      aliases: {...mediaAliases, "-o": "--out"});
  final (name, files) = coreAndFiles(o);
  final warmup = o.integer("--warmup", 0);
  final budget = o.integer("--steps", 30000);
  final fromPc = o["--from-pc"] == null
      ? null
      : int.tryParse(o["--from-pc"]!.replaceFirst("0x", ""), radix: 16) ??
          (throw UsageError("--from-pc takes a hex address"));
  final dir = o["--out"] ?? "/tmp/core_headless_trace";
  Directory(dir).createSync(recursive: true);

  final s = await Session.open(name, files, o, recordAudio: false);
  final core = s.core;
  final loadState = o["--load-state"];
  if (loadState != null) s.loadState(loadState);
  while (s.frame < warmup) {
    if (!await s.stepFrame()) throw StateError("stopped during the warmup");
  }
  // steps as the debugger does while logging: several cores run more than
  // one instruction in exec(false)
  Future<ExecResult> step() async {
    final r = core.exec(true);
    if (s.endsFrame(r)) await s.endFrame();
    return r;
  }

  if (fromPc != null) {
    while (core.programCounter(0) != fromPc) {
      if ((await step()).stopped) throw StateError("stopped before the pc");
    }
  }
  final captures = [
    for (final cpu in core.cpuInfos) _CpuCapture(cpu, "$dir/cpu${cpu.no}")
  ];
  var steps = 0;
  var stopped = false;
  final startFrame = s.frame;
  for (; steps < budget; steps++) {
    for (final capture in captures) {
      capture.record(core);
    }
    final result = await step();
    for (final capture in captures) {
      capture.complete(core, result);
    }
    if (result.stopped) {
      stopped = true;
      steps++;
      break;
    }
  }

  final statistics = <Map<String, Object?>>[];
  final report = StringBuffer("# Trace of $name ${files.join(" ")}\n\n")
    ..writeln("Recorded from frame $startFrame"
        "${fromPc == null ? "" : " at pc ${fromPc.toRadixString(16)}"}: "
        "$steps steps, stopped: $stopped. Each excerpt is copied from the "
        "debugger trace format.\n");
  for (final capture in captures) {
    await capture.finish();
    statistics.add({
      "core": name,
      "files": files,
      "fromFrame": startFrame,
      "fromPc": fromPc,
      "steps": steps,
      "stopped": stopped,
      ...capture.statistics,
    });
    report
      ..writeln("## ${capture.cpu.name}")
      ..writeln()
      ..writeln("CPU instructions: ${capture.instructions}.\n")
      ..writeln(capture.excerpts());
  }
  File("$dir/statistics.json")
      .writeAsStringSync(const JsonEncoder.withIndent("  ").convert(statistics));
  File("$dir/trace.md").writeAsStringSync(report.toString());
  stdout.writeln("$steps steps; "
      "${captures.map((c) => "${c.cpu.name}: ${c.instructions} instructions").join("; ")} -> $dir");
}

class _CpuCapture {
  final CpuInfo cpu;
  final String prefix;
  final _raw = <String>[];
  final _output = <TraceRepeatMode, List<String>>{};
  final _streams = <StreamController<String>>[];
  final _tracers = <TraceRepeatMode, Tracer>{};
  TraceLog? _pending;
  int instructions = 0;

  _CpuCapture(this.cpu, this.prefix) {
    for (final mode in TraceRepeatMode.values) {
      final output = _output[mode] = [];
      final stream = StreamController<String>(sync: true)
        ..stream.listen(output.add);
      _streams.add(stream);
      _tracers[mode] = Tracer(stream.sink, mode: mode);
    }
  }

  void record(Core core) {
    if (_pending != null) return;
    final log = core.trace(cpu.no);
    _pending = TraceLog(
        log.pc, log.cycle, log.disasm, log.regs, List<int>.of(log.state),
        flow: log.flow,
        frame: log.frame,
        scanline: log.scanline,
        instructionKey: log.instructionKey);
  }

  void complete(Core core, ExecResult result) {
    if (!result.executed(cpu.no)) return;
    final log = _pending!;
    _pending = null;
    instructions++;
    final nextPc = result.stopped ? null : core.programCounter(cpu.no);
    _raw.add(jsonEncode({
      'pc': log.pc,
      'nextPc': nextPc,
      'cycle': log.cycle,
      'frame': log.frame,
      'scanline': log.scanline,
      'disasm': log.disasm,
      'regs': log.regs,
      'state': log.state,
      'instructionKey': log.instructionKey,
      'flow': {
        'kind': log.flow.kind.name,
        'target': log.flow.target,
        'returnAddress': log.flow.returnAddress,
        'delaySlots': log.flow.delaySlots,
      },
    }));
    for (final tracer in _tracers.values) {
      tracer.addTraceLog(log, nextPc: nextPc);
    }
  }

  int get pathSummaries => _output[TraceRepeatMode.path]!
      .where((s) => s.startsWith('...loop'))
      .length;

  Map<String, Object> get statistics => {
        'cpu': cpu.no,
        'cpuName': cpu.name,
        'instructions': instructions,
        for (final mode in TraceRepeatMode.values)
          mode.name: {
            'lines': _output[mode]!.length,
            'summaries':
                _output[mode]!.where((s) => s.startsWith('...loop')).length,
          }
      };

  Future<void> finish() async {
    File('$prefix.raw.jsonl').writeAsStringSync('${_raw.join('\n')}\n');
    for (final mode in TraceRepeatMode.values) {
      _tracers[mode]!.finish();
      final output = _output[mode]!;
      final accounted = output.fold<int>(0, (count, line) {
        final match = RegExp(r'skipped (\d+) lines').firstMatch(line);
        return count + (match == null ? 1 : int.parse(match[1]!));
      });
      if (accounted != instructions) {
        throw StateError('${mode.name}: accounted $accounted / $instructions');
      }
      File('$prefix.${mode.name}.log').writeAsStringSync(output.join());
    }
    for (final stream in _streams) {
      await stream.close();
    }
  }

  String excerpts() {
    final report = StringBuffer();
    for (final mode in TraceRepeatMode.values) {
      final output = _output[mode]!;
      final summary = output.indexWhere((s) => s.startsWith('...loop'));
      final start = summary < 0 ? 0 : (summary - 2).clamp(0, output.length);
      final end = (start + 9).clamp(0, output.length);
      report
        ..writeln('### ${mode.name}: ${output.length} displayed lines')
        ..writeln()
        ..writeln('```text')
        ..write(output.sublist(start, end).join())
        ..writeln('```')
        ..writeln();
    }
    return report.toString();
  }
}

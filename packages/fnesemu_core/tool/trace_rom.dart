// Capture real ROM execution through the same Tracer used by the debugger.
// ROM paths belong in a local JSON manifest, not in this source file.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fnesemu_core/core_factory.dart';
import 'package:fnesemu_core/src/core.dart';
import 'package:fnesemu_core/src/internal/tracer.dart';
import 'package:fnesemu_core/src/sram.dart';
import 'package:fnesemu_core/src/types.dart';

import 'cdrom_drive.dart';
import 'local_disc.dart';

/// Manifest: [{"system":"nes", "rom":"/path/sample.nes",
/// "bios":["/path/bios"], "disc":"/path/disc.chd",
/// "warmupFrames":0, "steps":30000}]. BIOS/disc fields are optional.
/// Writes raw and compressed logs per CPU, an excerpt report and statistics.
Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln('usage: trace_rom <manifest.json> <output-directory>');
    exitCode = 64;
    return;
  }
  final samples = jsonDecode(File(args[0]).readAsStringSync()) as List;
  final directory = Directory(args[1])..createSync(recursive: true);
  final statistics = <Map<String, Object?>>[];
  final report = StringBuffer('# Actual ROM trace samples\n\n')
    ..writeln('Each excerpt is copied from the debugger trace format. '
        'Only middle cycles are omitted. `elapsed` is the difference between '
        'the first and last pre-instruction clock snapshots.\n');
  for (var index = 0; index < samples.length; index++) {
    final sample = samples[index] as Map<String, dynamic>;
    final id = sample['system'] as String;
    final label = '${index.toString().padLeft(2, '0')}-$id';
    try {
      final core = CoreFactory.of(id)..setSram(Sram());
      final bios = [
        for (final path in sample['bios'] as List? ?? [])
          File(path as String).readAsBytesSync()
      ];
      SimpleCdromDrive? drive;
      if (sample['disc'] case final String path) {
        drive = SimpleCdromDrive();
        await drive.insert(localDisc(path));
        if (!drive.status.isReady) throw StateError('disc is not ready');
        core.setCdromDrive(drive);
      }
      if (bios.isNotEmpty) core.setBiosFiles(bios);
      if (sample['rom'] case final String path) {
        core.setRom(_readRom(path, id));
      }
      if (!['gba', 'mdcd', '32x'].contains(id)) core.reset();
      final warmup = sample['warmupFrames'] as int? ?? 0;
      for (var frame = 0; frame < warmup; frame++) {
        final result = core.runFrame(core.scanlinesInFrame);
        if (result.stopped) throw StateError('stopped during warmup');
        await drive?.settle();
      }
      final captures = [
        for (final cpu in core.cpuInfos)
          _CpuCapture(cpu, '${directory.path}/$label-cpu${cpu.no}')
      ];
      final budget = sample['steps'] as int? ?? 30000;
      var steps = 0, lines = 0;
      var stopped = false;
      for (; steps < budget; steps++) {
        for (final capture in captures) {
          capture.record(core);
        }
        // Match Debugger.stepInstructions while logging: several cores batch
        // multiple instructions in exec(false).
        final result = core.exec(true);
        for (final capture in captures) {
          capture.complete(core, result);
        }
        if (result.stopped) {
          stopped = true;
          steps++;
          break;
        }
        if (result.scanlineRendered && ++lines == core.scanlinesInFrame) {
          lines = 0;
          await drive?.settle();
        }
      }
      for (final capture in captures) {
        await capture.finish();
        statistics.add({
          'sample': label,
          'system': id,
          'rom': sample['rom'],
          'disc': sample['disc'],
          'bios': sample['bios'],
          'warmupFrames': warmup,
          'steps': steps,
          'stopped': stopped,
          ...capture.statistics,
        });
        report
          ..writeln('## $label / ${capture.cpu.name}')
          ..writeln()
          ..writeln('ROM: ${sample['rom'] ?? '(BIOS/disc boot)'}  ')
          ..writeln('Disc: ${sample['disc'] ?? '(none)'}  ')
          ..writeln('Warmup: $warmup frames; execution steps: $steps; '
              'CPU instructions: ${capture.instructions}; stopped: $stopped.\n')
          ..writeln(capture.excerpts());
      }
      stdout.writeln('$label: $steps steps; '
          '${captures.map((c) => '${c.cpu.name}: ${c.instructions} instructions / ${c.pathSummaries} path summaries').join('; ')}');
    } catch (error, stack) {
      exitCode = 1;
      statistics.add({'sample': label, 'system': id, 'error': '$error'});
      report.writeln('## $label\n\nCapture failed: $error\n');
      stderr.writeln('$label: $error\n$stack');
    }
    File('${directory.path}/statistics.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(statistics));
    File('${directory.path}/samples.md').writeAsStringSync(report.toString());
  }
}

Uint8List _readRom(String path, String system) {
  final bytes = File(path).readAsBytesSync();
  if (!path.toLowerCase().endsWith('.zip')) return bytes;
  final files = ZipDecoder().decodeBytes(bytes).files.where((f) => f.isFile);
  final extensions = CoreFactory.system(system).extensions;
  final rom = files
      .where((f) => extensions
          .any((extension) => f.name.toLowerCase().endsWith('.$extension')))
      .firstOrNull;
  if (rom == null) throw FormatException('no $system ROM in archive');
  return Uint8List.fromList(rom.content);
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

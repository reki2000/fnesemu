/// The benchmark archive: a zip or 7z file with `bench.json`, the saved
/// states to time, and the ROMs and BIOS files they need. Discs are not in
/// the archive; the app finds them among the ROM directories by the media
/// identity of the state.
///
/// `bench.json` lists the scenes in the order they run:
///
///     {"scenes": [{
///       "name": "ps2-scene",      // the name in the results
///       "core": "ps2",            // a CoreSystem id
///       "state": "ps2/a.state",   // a Core.saveState image in the archive
///       "rom": "nes/a.nes",       // optional: the ROM in the archive
///       "bios": ["ps2/bios.bin"], // optional: the BIOS files in order
///       "disc": "a.chd",          // optional: the name of the disc file
///       "warmup": 60,             // frames run before the measurement
///       "measure": 600,           // frames measured
///       "target": 60              // optional: the frame rate of the hardware
///     }]}
library;

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:cdrom_image/cdrom_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fnesemu_core/app_api.dart';
import 'package:mp_bigfile_picker/mp_bigfile_picker.dart';

import 'rom_archive.dart';
import 'seven_zip.dart';

/// the files of a benchmark archive
abstract class BenchArchive {
  List<String> get names;
  Future<Uint8List> read(String name);
  Future<void> close();

  /// opens [file], a zip or a 7z archive
  static Future<BenchArchive> open(RandomReadFile file) async {
    final length = await file.length();
    if (isSevenZip(file.name)) {
      final zip = await SevenZip.open(length, file.read);
      return _SevenZipArchive(file, zip);
    }
    if (isZip(file.name)) {
      final bytes = await file.read(0, length);
      await file.close();
      return _ZipArchive(ZipDecoder().decodeBytes(bytes, verify: true));
    }
    await file.close();
    throw FormatException('not a zip or 7z archive: ${file.name}');
  }
}

class _SevenZipArchive implements BenchArchive {
  final RandomReadFile _file;
  final SevenZip _zip;
  final Map<String, SevenZipEntry> _entries;

  _SevenZipArchive(this._file, this._zip)
      : _entries = {
          for (final e in _zip.entries)
            if (!e.isDirectory) e.name: e
        };

  @override
  List<String> get names => _entries.keys.toList();

  @override
  Future<Uint8List> read(String name) {
    final entry = _entries[name];
    if (entry == null) throw FormatException('$name is not in the archive');
    return _zip.read(entry);
  }

  @override
  Future<void> close() => _file.close();
}

class _ZipArchive implements BenchArchive {
  final Archive _archive;
  _ZipArchive(this._archive);

  @override
  List<String> get names => [
        for (final f in _archive)
          if (f.isFile) f.name
      ];

  @override
  Future<Uint8List> read(String name) async {
    final file = _archive.findFile(name);
    if (file == null || !file.isFile) {
      throw FormatException('$name is not in the archive');
    }
    return Uint8List.fromList(file.content as List<int>);
  }

  @override
  Future<void> close() async {}
}

/// one scene of `bench.json`
class BenchScene {
  final String name, core, state;
  final String? rom, disc;
  final List<String> bios;
  final int warmup, measure, target;

  const BenchScene(
      {required this.name,
      required this.core,
      required this.state,
      this.rom,
      this.disc,
      this.bios = const [],
      this.warmup = 60,
      this.measure = 600,
      this.target = 60});

  factory BenchScene.fromJson(Map<String, dynamic> json) => BenchScene(
      name: json['name'] as String? ?? json['state'] as String,
      core: json['core'] as String,
      state: json['state'] as String,
      rom: json['rom'] as String?,
      disc: json['disc'] as String?,
      bios: [for (final b in json['bios'] as List? ?? const []) b as String],
      warmup: json['warmup'] as int? ?? 60,
      measure: json['measure'] as int? ?? 600,
      target: json['target'] as int? ?? 60);

  /// the scenes of the text of `bench.json`
  static List<BenchScene> parse(String text) {
    final json = jsonDecode(text) as Map<String, dynamic>;
    return [
      for (final s in json['scenes'] as List)
        BenchScene.fromJson(s as Map<String, dynamic>)
    ];
  }
}

/// the result of one scene: its timing, or why it did not run
class BenchResult {
  final BenchScene scene;
  final BenchmarkTiming? timing;
  final String? error;

  /// whether the core ran with the JIT, and the CPU clock in MHz right after
  /// the measurement, which shows thermal throttling
  final bool? jit;
  final int? cpuMHzEnd;

  const BenchResult(this.scene,
      {this.timing, this.error, this.jit, this.cpuMHzEnd});

  double get fps => timing?.fps ?? 0;

  /// the line of the speed map results; [host] describes the machine: its
  /// OS, CPU and GPU
  Map<String, Object?> record(
          {required String machine,
          required String version,
          required DateTime date,
          Map<String, Object?> host = const {}}) =>
      {
        'date': date.toIso8601String().substring(0, 10),
        'machine': machine,
        'commit': version,
        'core': scene.core,
        'case': scene.name,
        if (timing case final t?) ...{
          'fps': double.parse(t.fps.toStringAsFixed(1)),
          'msPerFrame': double.parse(
              (t.frames == 0 ? 0 : t.wallUs / 1000 / t.frames)
                  .toStringAsFixed(2)),
          'coreFps': double.parse(t.coreFps.toStringAsFixed(1)),
          'frames': t.frames,
        },
        if (error != null) 'error': error,
        'target': scene.target,
        if (jit != null) 'jit': jit,
        if (cpuMHzEnd != null) 'cpuMHzEnd': cpuMHzEnd,
        'platform': benchPlatform,
        if (host.isNotEmpty) 'host': host,
      };
}

/// the platform in the results, such as android or web-ios
String get benchPlatform =>
    '${kIsWeb ? 'web-' : ''}${defaultTargetPlatform.name}';

/// how likely [path] is the disc [name]: 0 for the same file name, 1 for
/// the same name with another extension, 2 for another disc image, 3 for a
/// file that may be a disc image, and null for a file that is not a disc
int? discRank(String name, String path) {
  if (DiscFileKind.of(path) == DiscFileKind.notImage) return null;
  String base(String p) => p.split(RegExp(r'[/\\]')).last.toLowerCase();
  String stem(String p) {
    final b = base(p);
    final dot = b.lastIndexOf('.');
    return dot <= 0 ? b : b.substring(0, dot);
  }

  if (base(path) == base(name)) return 0;
  if (stem(path) == stem(name)) return 1;
  return DiscFileKind.of(path) == DiscFileKind.image ? 2 : 3;
}

/// the results of a benchmark run, with the device name for the speed map
/// and a button that copies the results as lines of JSON
class BenchResultsDialog extends StatefulWidget {
  final List<BenchResult> results;
  final String machine;
  final String version;
  final DateTime date;
  final Map<String, Object?> host;

  /// receives the device name when the dialog closes
  final void Function(String machine) onMachine;

  const BenchResultsDialog(
      {super.key,
      required this.results,
      required this.machine,
      required this.version,
      required this.date,
      this.host = const {},
      required this.onMachine});

  @override
  State<BenchResultsDialog> createState() => _BenchResultsDialogState();
}

class _BenchResultsDialogState extends State<BenchResultsDialog> {
  late final _machine = TextEditingController(text: widget.machine);

  String get _lines => widget.results
      .map((r) => jsonEncode(r.record(
          machine: _machine.text,
          version: widget.version,
          date: widget.date,
          host: widget.host)))
      .join('\n');

  @override
  void dispose() {
    _machine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Benchmark'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                    key: const ValueKey('bench-machine'),
                    controller: _machine,
                    decoration: const InputDecoration(labelText: 'Device')),
                const SizedBox(height: 8),
                Text(
                    [
                      widget.host['cpu'] ?? widget.host['machine'],
                      if (widget.host['cpuMaxMHz'] case final mhz?) '$mhz MHz',
                      widget.host['gpu'],
                    ].nonNulls.join(' · '),
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 12),
                for (final r in widget.results)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(children: [
                      Expanded(
                          child: Text('${r.scene.core}  ${r.scene.name}',
                              overflow: TextOverflow.ellipsis)),
                      Text(r.timing == null
                          ? r.error ?? 'failed'
                          : '${r.fps.toStringAsFixed(1)} fps  '
                              '${(100 * r.fps / r.scene.target).round()}%'),
                    ]),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: _lines));
                if (context.mounted) {
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                      const SnackBar(content: Text('Copied the results')));
                }
              },
              child: const Text('Copy')),
          TextButton(
              onPressed: () {
                widget.onMachine(_machine.text);
                Navigator.of(context).pop();
              },
              child: const Text('Close')),
        ],
      );
}

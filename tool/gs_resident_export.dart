import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ps2/gs/gs.dart';
import 'package:fnesemu_core/src/core/ps2/state.dart';

import 'gs_resident/batch.dart';

void main(List<String> args) {
  if (args.length != 2) {
    throw ArgumentError('usage: gs_resident_export TRACE DISPFB2');
  }
  final directory = args[0];
  final manifest =
      jsonDecode(File('$directory/manifest.json').readAsStringSync()) as Map;
  if (manifest['version'] != 3 || manifest['endianness'] != 'little') {
    throw const FormatException('incompatible GS trace');
  }
  final gs = Gs()
    ..loadState(StateReader(File('$directory/gs-start.bin').readAsBytesSync(),
        'gs-frame-trace', 3, 0));
  File('$directory/resident-start.bin')
      .writeAsBytesSync(residentCheckpoint(gs));
  final stream = Uint32List.sublistView(
      File('$directory/gs-stream.bin').readAsBytesSync());
  if (stream.lengthInBytes != (manifest['events'] as int) * 16) {
    throw const FormatException('incomplete command stream');
  }
  final encoder = GsResidentBatchEncoder(gs);
  gs.residentSink = encoder;
  final clock = Stopwatch()..start();
  for (var at = 0; at < stream.length; at += 4) {
    final op = stream[at];
    if (op == 2) {
      gs.hostWord(stream[at + 2]);
      continue;
    }
    final register = stream[at + 1];
    final value = stream[at + 2] | stream[at + 3] << 32;
    switch (op) {
      case 0:
        gs.writeRegister(register, value);
      case 1:
        gs.writePrivileged(register, value);
      case 4:
        gs.vblank();
      case 5:
        gs.setQ(value);
      default:
        throw UnsupportedError('GS event $op');
    }
  }
  final batch = encoder.finish(int.parse(args[1]));
  clock.stop();
  if (batch.draws != manifest['draws']) {
    throw StateError('incomplete draw stream');
  }
  File('$directory/resident-commands.bin').writeAsBytesSync(batch.commands);
  File('$directory/resident-aux.bin').writeAsBytesSync(batch.auxiliary);
  stdout.writeln(jsonEncode({
    'draws': batch.draws,
    'drawDispatches': batch.drawDispatches,
    'uploads': batch.uploads,
    'paletteLoads': batch.paletteLoads,
    'width': batch.width,
    'height': batch.height,
    'encodeMs': clock.elapsedMicroseconds / 1000,
  }));
}

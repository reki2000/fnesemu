// Records the GS command stream of one PS2 frame, without the per-draw
// packets of tool/gs_frame_check.dart, so that a frame with many draws stays
// small.
//
// dart run tool/gs_trace_record.dart STATE FRAME OUTPUT MEDIA...
//
// The core loads STATE, runs up to the frame before FRAME, and records frame
// FRAME. OUTPUT gets gs-start.bin and gs-end.bin (the GS state before and
// after, in the format of tool/gs_frame_check.dart), gs-stream.bin (16 bytes
// per event: operation, register, value), reference.png (the core's picture)
// and manifest.json.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ps2/gs/gs.dart';
import 'package:fnesemu_core/src/core/ps2/ps2.dart';
import 'package:fnesemu_core/src/core/ps2/state.dart';

import 'headless/options.dart';
import 'headless/session.dart';

const traceVersion = 3;

Uint8List gsState(Gs gs) {
  final writer = StateWriter('gs-frame-trace', traceVersion, 0);
  gs.saveState(writer);
  return writer.take();
}

Future<void> main(List<String> args) async {
  if (args.length < 4) {
    stderr.writeln('usage: STATE FRAME OUTPUT MEDIA...');
    exit(64);
  }
  final target = int.parse(args[1]);
  final directory = args[2];
  final session = await Session.open(
      'ps2',
      args.sublist(3),
      Options.parse(['--frame-runner'],
          flags: mediaFlags, valued: mediaValued),
      recordAudio: false);
  session.loadState(args[0]);
  if (target <= session.frame) {
    throw ArgumentError('the frame must follow the state');
  }
  while (session.frame < target - 1) {
    if (!await session.stepFrame()) throw StateError('core stopped');
    session.core.imageBuffer();
  }
  Directory(directory).createSync(recursive: true);
  final gs = (session.core as Ps2).io.gs;
  File('$directory/gs-start.bin').writeAsBytesSync(gsState(gs));
  final events = BytesBuilder(copy: false);
  final event = ByteData(16);
  var count = 0;
  gsCommandRecorder = (op, reg, value) {
    event.setUint32(0, op, Endian.little);
    event.setUint32(4, reg, Endian.little);
    event.setInt64(8, value, Endian.little);
    events.add(Uint8List.fromList(event.buffer.asUint8List()));
    count++;
  };
  try {
    if (!await session.stepFrame()) throw StateError('core stopped');
    savePng(session.core.imageBuffer(), '$directory/reference.png');
  } finally {
    gsCommandRecorder = null;
  }
  File('$directory/gs-stream.bin').writeAsBytesSync(events.takeBytes());
  File('$directory/gs-end.bin').writeAsBytesSync(gsState(gs));
  final manifest = {'version': traceVersion, 'frame': target, 'events': count};
  File('$directory/manifest.json').writeAsStringSync(jsonEncode(manifest));
  stdout.writeln(jsonEncode(manifest));
  session.core.dispose();
  exit(0);
}

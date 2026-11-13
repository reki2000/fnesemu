// Replays a GS frame trace of packages/fnesemu_core/tool/gs_trace_record.dart.
import 'dart:io';
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ps2/gs/gs.dart';
import 'package:fnesemu_core/src/core/ps2/state.dart';

const traceVersion = 3;

Gs loadGs(String path) => Gs()
  ..loadState(StateReader(
      File(path).readAsBytesSync(), 'gs-frame-trace', traceVersion, 0));

/// Issues the events of gs-stream.bin of [directory] to [gs].
void replay(Gs gs, String directory) {
  final bytes =
      ByteData.sublistView(File('$directory/gs-stream.bin').readAsBytesSync());
  final transfer = Int64List(2);
  for (var at = 0; at < bytes.lengthInBytes; at += 16) {
    final op = bytes.getUint32(at, Endian.little);
    final register = bytes.getUint32(at + 4, Endian.little);
    final value = bytes.getInt64(at + 8, Endian.little);
    switch (op) {
      case 0:
        gs.writeRegister(register, value);
      case 1:
        gs.writePrivileged(register, value);
      case 2:
        gs.hostWord(value);
      case 3:
        gs.readQuad(transfer);
      case 4:
        gs.vblank();
      case 5:
        gs.setQ(value);
      default:
        throw FormatException('unknown GS operation $op');
    }
  }
}

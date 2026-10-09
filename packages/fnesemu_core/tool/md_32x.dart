import 'dart:io';

import 'package:fnesemu_core/core/md/md.dart';

/// Headless md 32x smoke runner with externally supplied boot ROMs.
void main(List<String> args) {
  if (args.length < 4 || args.length > 5) {
    stderr.writeln(
        'Usage: dart run tool/md_32x.dart <cart.32x> <256-byte main boot> <2048-byte master boot> <1024-byte slave boot> [frames]');
    exitCode = 64;
    return;
  }
  final frames = args.length == 5 ? int.tryParse(args[4]) : 600;
  if (frames == null || frames <= 0) {
    stderr.writeln('frames must be a positive integer');
    exitCode = 64;
    return;
  }
  final md = Md(expansionBoot: true)
    ..setExpansionBootRoms(
        main: File(args[1]).readAsBytesSync(),
        master: File(args[2]).readAsBytesSync(),
        slave: File(args[3]).readAsBytesSync())
    ..setRom(File(args[0]).readAsBytesSync());
  final target = frames * md.scanlinesInFrame * md.clocksInScanline;
  while (true) {
    final result = md.exec(false);
    if (result.stopped) {
      stderr.writeln(md.dump());
      exitCode = 1;
      return;
    }
    if (result.elapsedClocks >= target) break;
  }
  stdout.writeln(md.dump());
}

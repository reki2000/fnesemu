import 'dart:io';

import '../core/md/md.dart';
import '../disc/loader.dart';

/// Headless BIOS/disc smoke runner. No copyrighted BIOS or media is bundled.
void main(List<String> args) {
  if (args.length < 2 || args.length > 3) {
    stderr.writeln(
        'Usage: dart run lib/tools/md_cdrom.dart <128 KiB BIOS> <disc.cue|disc.iso|disc.bin> [frames]');
    exitCode = 64;
    return;
  }
  final frames = args.length == 3 ? int.tryParse(args[2]) : 600;
  if (frames == null || frames <= 0) {
    stderr.writeln('frames must be a positive integer');
    exitCode = 64;
    return;
  }
  final disc = DiscLoader.load(args[1]);
  if (disc.isEmpty) {
    stderr.writeln('Could not load disc: ${args[1]}');
    exitCode = 66;
    return;
  }
  final md = Md(cdBoot: true)
    ..setDisc(disc)
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

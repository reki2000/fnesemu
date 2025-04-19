import 'dart:io';

import 'ps.dart';

main(List<String> args) {
  Ps core = Ps();
  final bios = File(args[0]).readAsBytesSync();
  core.setRom(bios);
  core.reset();

  if (args.length > 1) {
    final exe = File(args[1]).readAsBytesSync();
    core.setRom(exe);
  }

  for (int i = 0; i < core.systemClockHz * 10; i++) {
    core.exec(false);
  }
}

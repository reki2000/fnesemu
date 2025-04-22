import 'dart:io';

import '../../disc/loader.dart';
import 'ps.dart';

main(List<String> args) {
  Ps core = Ps();
  final bios = File(args[0]).readAsBytesSync();
  core.setRom(bios);
  core.reset();

  final disc = DiscLoader.load(args[1]);
  core.onReadDisc(disc.read);

  if (args.length > 2) {
    final exe = File(args[2]).readAsBytesSync();
    core.setRom(exe);
  }

  for (int i = 0; i < core.systemClockHz * 10; i++) {
    core.exec(false);
  }
}

import 'dart:io';

import '../../disc/loader.dart';
import 'ps.dart';

int runSeconds = 10;

main(List<String> args) {
  if (args.length < 2) {
    print(
        "Usage: dart ps_test.dart [-n runSeconds] <bios file> <disc file> [<exe file>]");
    return;
  }

  if (args[0] == "-n") {
    runSeconds = int.parse(args[1]);
    args = args.sublist(2);
  }

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

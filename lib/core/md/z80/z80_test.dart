import 'package:fnesemu/core/md/z80/z80_debug.dart';

import '../bus_z80.dart';
import 'z80.dart';

void main() {
  final bus = BusZ80();
  final cpu = Z80(bus);
  bus.ram[0] = 0x3e; // ld a, 0x12
  bus.ram[1] = 0x12;

  cpu.exec();

  for (int i = 0; i < 10; i++) {
    cpu.exec();
    print(cpu.trace());
  }
}

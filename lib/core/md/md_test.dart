import 'dart:typed_data';

import 'package:fnesemu/core/md/md.dart';

void bench0() {
  final startAt = DateTime.now();

  for (var i = 0; i < 0x10000 * 3; i++) {
    // print(md.dump());
    md.exec(true);
  }

  final elapsed = DateTime.now().difference(startAt);
  print('elapsed: ${elapsed.inMilliseconds}ms');
}

final md = Md();

int main() {
  final rom = Uint8List(0x10000);

  final code = [
    0x46, 0xfc, 0x23, 0x00, // move #0x2300, sr
    0x41, 0xf9, 0x00, 0xff, 0x00, 0x00, // lea 0xff0000, a0
    0x70, 0x00, // move.l #0, d0
    0x30, 0xfc, 0x00, 0x00, // move #0, (a0)+
    0x55, 0x40, // subq.w #2, d0
    0x66, 0x00, 0xff, 0xf6 // bne 0x2
  ];

  for (var i = 0; i < code.length; i++) {
    rom[i + 0x200] = code[i];
  }

  // Set m68000 reset vector to 0x200
  rom[0x4] = 0x00;
  rom[0x5] = 0x00;
  rom[0x6] = 0x02;
  rom[0x7] = 0x00;

  md.setRom(rom);

  bench0();

  return 0;
}

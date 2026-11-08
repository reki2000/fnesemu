import 'dart:typed_data';

import 'package:fnesemu_core/src/core/nes/mapper/mapper.dart';
import 'package:fnesemu_core/src/core/nes/mapper/mmc5.dart';
import 'package:test/test.dart';

// 64 x 8k prg banks and 256 x 1k chr banks, every byte holds its bank number
class _Mmc5 {
  final m = MapperMmc5();
  bool irq = false;
  final sram = Uint8List(64 * 1024);

  _Mmc5() {
    final prg = Uint8List(64 * 8192);
    for (int i = 0; i < prg.length; i++) {
      prg[i] = i ~/ 8192;
    }
    final chr = Uint8List(256 * 1024);
    for (int i = 0; i < chr.length; i++) {
      chr[i] = i ~/ 1024;
    }
    m
      ..setRom(chr, prg)
      ..holdIrq = ((h) => irq = h)
      ..mirror = ((_) {})
      ..setSramRw((a) => sram[a & 0xffff], (a, v) => sram[a & 0xffff] = v)
      ..init();
  }

  void w(int addr, int v) => m.write(addr, v);
  int r(int addr) => m.read(addr);

  int pattern(int addr, int phase) {
    m.fetchPhase = phase;
    final v = m.readVram(addr);
    m.fetchPhase = Mapper.fetchBg;
    return v;
  }

  int vram(int addr) => pattern(addr, Mapper.fetchCpu);

  // the nametable fetches of one scanline as the ppu model issues them:
  // tile 0, 2 dummy reads and the following tiles
  void scanline() {
    m.fetchPhase = Mapper.fetchBg;
    m.readVram(0x2000);
    m.readVram(0x23c0);
    m.readVram(0x2001);
    m.readVram(0x2001);
    for (int i = 1; i < 33; i++) {
      m.readVram(0x2000 + i);
      m.readVram(0x23c0);
    }
    m.handleClock(0);
  }

  void idleLine() => m.handleClock(0);
}

void main() {
  test('prg banking modes', () {
    final s = _Mmc5();
    // power on: the last bank at $e000
    expect(s.r(0xe000), 63);

    s.w(0x5100, 3);
    s.w(0x5114, 0x84);
    s.w(0x5115, 0x85);
    s.w(0x5116, 0x86);
    s.w(0x5117, 0x87);
    expect([0x8000, 0xa000, 0xc000, 0xe000].map(s.r), [4, 5, 6, 7]);

    s.w(0x5100, 0); // 32k: the bank bits below 4 are ignored
    s.w(0x5117, 0x8f);
    expect([0x8000, 0xa000, 0xc000, 0xe000].map(s.r), [12, 13, 14, 15]);

    s.w(0x5100, 1); // 2 x 16k
    s.w(0x5115, 0x86);
    s.w(0x5117, 0x8a);
    expect([0x8000, 0xa000, 0xc000, 0xe000].map(s.r), [6, 7, 10, 11]);

    s.w(0x5100, 2); // 16k + 8k + 8k
    s.w(0x5115, 0x84);
    s.w(0x5116, 0x88);
    s.w(0x5117, 0x8f);
    expect([0x8000, 0xa000, 0xc000, 0xe000].map(s.r), [4, 5, 8, 15]);
  });

  test('scanline irq is detected from the nametable fetches', () {
    final s = _Mmc5();
    s.w(0x5203, 3);
    s.w(0x5204, 0x80);

    // not rendering: not in frame
    s.idleLine();
    expect(s.r(0x5204) & 0x40, 0);

    s.scanline(); // line 0: starts the frame
    expect(s.irq, isFalse);
    s.scanline(); // line 1
    s.scanline(); // line 2
    expect(s.irq, isFalse);
    s.scanline(); // line 3 = the compare value
    expect(s.irq, isTrue);

    // the status register: pending + in frame, reading acknowledges
    expect(s.r(0x5204), 0xc0);
    expect(s.irq, isFalse);
    expect(s.r(0x5204) & 0x80, 0);

    // the frame ends when the ppu stops fetching
    s.idleLine();
    expect(s.r(0x5204) & 0x40, 0);

    // the next frame starts counting from 0 again
    s.scanline();
    s.scanline();
    expect(s.irq, isFalse);
  });

}

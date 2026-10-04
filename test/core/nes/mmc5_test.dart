import 'dart:typed_data';

import 'package:fnesemu/core/nes/mapper/mapper.dart';
import 'package:fnesemu/core/nes/mapper/mmc5.dart';
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

  test('prg ram is mapped by bank and protected until unlocked', () {
    final s = _Mmc5();
    s.w(0x5113, 1);
    s.w(0x6000, 0xab); // protected
    expect(s.r(0x6000), 0);
    s.w(0x5102, 2);
    s.w(0x5103, 1);
    s.w(0x6000, 0xab);
    expect(s.r(0x6000), 0xab);
    expect(s.sram[0x2000], 0xab);

    // ram selected at $8000 (bit 7 clear)
    s.w(0x5100, 3);
    s.w(0x5114, 0x01);
    expect(s.r(0x8000), 0xab);
    s.w(0x8001, 0xcd);
    expect(s.sram[0x2001], 0xcd);
  });

  test('chr banking modes with separate sprite and background sets', () {
    final s = _Mmc5();
    s.w(0x5101, 3);
    for (int i = 0; i < 8; i++) {
      s.w(0x5120 + i, 10 + i);
    }
    for (int i = 0; i < 4; i++) {
      s.w(0x5128 + i, 100 + i);
    }
    // 8x8 sprites: the set A is used for the background as well
    expect(
        [for (int i = 0; i < 8; i++) s.pattern(i * 0x400, Mapper.fetchBg)],
        [10, 11, 12, 13, 14, 15, 16, 17]);

    s.m.ppuCtl = 0x20; // 8x16 sprites
    expect(
        [for (int i = 0; i < 8; i++) s.pattern(i * 0x400, Mapper.fetchBg)],
        [100, 101, 102, 103, 100, 101, 102, 103]);
    expect(
        [for (int i = 0; i < 8; i++) s.pattern(i * 0x400, Mapper.fetchSprite)],
        [10, 11, 12, 13, 14, 15, 16, 17]);

    // the cpu uses the set that was written last
    expect(s.vram(0), 100);
    s.w(0x5120, 10);
    expect(s.vram(0), 10);

    // 4k mode
    s.w(0x5101, 1);
    s.w(0x5123, 5);
    s.w(0x5127, 6);
    expect([0x0000, 0x0400, 0x1000, 0x1c00].map((a) => s.pattern(a, Mapper.fetchSprite)),
        [20, 21, 24, 27]);

    // 2k mode
    s.w(0x5101, 2);
    s.w(0x5121, 1);
    s.w(0x5123, 2);
    s.w(0x5125, 3);
    s.w(0x5127, 4);
    expect(
        [0x0000, 0x0400, 0x0800, 0x1000, 0x1c00]
            .map((a) => s.pattern(a, Mapper.fetchSprite)),
        [2, 3, 4, 6, 9]);

    // 8k mode
    s.w(0x5101, 0);
    s.w(0x5127, 2);
    expect([0x0000, 0x1c00].map((a) => s.pattern(a, Mapper.fetchSprite)), [16, 23]);

    // the upper bits
    s.w(0x5101, 3);
    s.w(0x5130, 1);
    s.w(0x5120, 3);
    expect(s.pattern(0, Mapper.fetchSprite), 3 + 256 - 256); // wraps by the rom size
  });

  test('multiplier', () {
    final s = _Mmc5();
    s.w(0x5205, 0x10);
    s.w(0x5206, 0x20);
    expect(s.r(0x5205), 0x00);
    expect(s.r(0x5206), 0x02);
    s.w(0x5205, 0xff);
    s.w(0x5206, 0xff);
    expect(s.r(0x5205) | s.r(0x5206) << 8, 0xfe01);
  });

  test('nametable mapping: ciram, exram and fill mode', () {
    final s = _Mmc5();
    s.w(0x5104, 0);
    s.w(0x5105, 0xe4); // NT0: ciram0, NT1: ciram1, NT2: exram, NT3: fill
    s.m.writeVram(0x2000, 0x11);
    s.m.writeVram(0x2400, 0x22);
    s.m.writeVram(0x2800, 0x33);
    expect([0x2000, 0x2400, 0x2800].map(s.vram), [0x11, 0x22, 0x33]);

    s.w(0x5106, 0x77);
    s.w(0x5107, 2);
    expect(s.vram(0x2c00), 0x77);
    expect(s.vram(0x2fc0), 0xaa); // the color replicated to the 4 quadrants
    s.m.writeVram(0x2c00, 0x99); // fill mode is read only
    expect(s.vram(0x2c00), 0x77);

    // the nametable can mirror ciram page 0 everywhere
    s.w(0x5105, 0x00);
    expect([0x2000, 0x2400, 0x2800, 0x2c00].map(s.vram), [0x11, 0x11, 0x11, 0x11]);
  });

  test('exram modes', () {
    final s = _Mmc5();
    s.w(0x5104, 2); // ram
    s.w(0x5c10, 0x5a);
    expect(s.r(0x5c10), 0x5a);
    s.w(0x5104, 3); // read only ram
    s.w(0x5c10, 0x11);
    expect(s.r(0x5c10), 0x5a);
    s.w(0x5104, 0); // nametable: not readable by the cpu
    expect(s.r(0x5c10), 0xff);
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

  test('irq is only raised when enabled', () {
    final s = _Mmc5();
    s.w(0x5203, 1);
    s.scanline();
    s.scanline();
    expect(s.irq, isFalse);
    s.w(0x5204, 0x80); // enabling releases / raises with the pending flag
    expect(s.irq, isTrue);
    s.w(0x5204, 0x00);
    expect(s.irq, isFalse);
  });

  test('extended attribute mode: per tile chr bank and palette', () {
    final s = _Mmc5();
    s.w(0x5104, 2);
    s.w(0x5c05, 0x42); // palette 1, 4k chr bank 2
    s.w(0x5104, 1);
    s.m.fetchPhase = Mapper.fetchBg;
    s.m.readVram(0x2005); // the nametable byte of the tile
    // the pattern of that tile comes from the 4k bank 2 (1k banks 8-11)
    expect(s.m.readVram(0x0010), 8);
    expect(s.m.readVram(0x0c10), 11);
    // the attribute is the palette bits of the exram byte
    expect(s.m.readVram(0x23c1), 0x55);
  });

  test('vertical split screen: the left tiles come from exram and its chr bank',
      () {
    final s = _Mmc5();
    s.scanline(); // in frame (exram is writable as a nametable while rendering)
    s.w(0x5c00, 0x41);
    s.w(0x5c01, 0x42);
    s.w(0x5200, 0x84); // enabled, left side, 4 tiles
    s.w(0x5202, 0x10); // 4k chr bank 16 (1k banks 64-67)
    s.m.writeVram(0x2004, 0x55); // ciram: used right of the split (ntMap 0)

    s.m.fetchPhase = Mapper.fetchBg;
    expect(s.m.readVram(0x2000), 0x41); // column 0: exram
    expect(s.m.readVram(0x0000), 64); // its pattern: the split chr bank
    s.m.readVram(0x23c0);
    expect(s.m.readVram(0x2001), 0x42); // column 1
    s.m.readVram(0x0000);
    s.m.readVram(0x23c0);
    s.m.readVram(0x2002);
    s.m.readVram(0x2003);
    expect(s.m.readVram(0x2004), 0x55); // column 4: the normal nametable
    // the normal chr set is used again
    s.w(0x5127, 9);
    s.m.readVram(0x0000);
  });

  test('pulse channels and pcm produce sound', () {
    final s = _Mmc5();
    s.w(0x5015, 1);
    s.w(0x5000, 0xbf); // duty 2, halt, constant volume 15
    s.w(0x5002, 0x10);
    s.w(0x5003, 0x08);
    final out = s.m.handleApu(1800);
    expect(out.any((v) => v > 0), isTrue);
    expect(s.r(0x5015) & 1, 1);

    s.w(0x5015, 0); // disabling clears the length counter
    expect(s.r(0x5015) & 1, 0);

    s.w(0x5011, 0x80);
    final pcm = s.m.handleApu(1800);
    expect(pcm.every((v) => v > 0), isTrue);
  });
}

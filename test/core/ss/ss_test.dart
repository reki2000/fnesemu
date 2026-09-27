import 'dart:typed_data';

import 'package:fnesemu/core/disc.dart';
import 'package:fnesemu/core/sram.dart';
import 'package:fnesemu/core/ss/cpu.dart';
import 'package:fnesemu/core/ss/ss.dart';
import 'package:test/test.dart';

class _TestCpu extends NullCpu {
  _TestCpu(super.bus, {super.master});

  int irl = 0;
  int nmiCount = 0;

  @override
  void setIrl(int level) => irl = level;

  @override
  void nmi() => nmiCount++;
}

Ss _newSs() {
  final ss = Ss(cpuFactory: (bus, master) => _TestCpu(bus, master: master))
    ..setSram(Sram())
    ..setRom(Uint8List(0x80000));
  ss.reset();
  return ss;
}

// in-memory mode 1 disc with an ISO9660 file system
class _TestDisc extends Disc {
  final sectors = <Uint8List>[];

  static const fileLba = 20;
  static const fileSize = 4096;

  _TestDisc() {
    for (int lba = 0; lba < 40; lba++) {
      sectors.add(_sector(lba, Uint8List(2048)));
    }

    // primary volume descriptor
    final pvd = Uint8List(2048);
    pvd[0] = 1;
    pvd.setRange(1, 6, "CD001".codeUnits);
    _dirRecord(pvd, 156, 18, 2048, true, "\x00");
    sectors[16] = _sector(16, pvd);

    // root directory
    final dir = Uint8List(2048);
    int o = 0;
    o += _dirRecord(dir, o, 18, 2048, true, "\x00");
    o += _dirRecord(dir, o, 18, 2048, true, "\x01");
    _dirRecord(dir, o, fileLba, fileSize, false, "FILE.BIN;1");
    sectors[18] = _sector(18, dir);

    // file body
    for (int s = 0; s < 2; s++) {
      final data = Uint8List(2048);
      for (int i = 0; i < 2048; i++) {
        data[i] = (s * 7 + i) & 0xff;
      }
      sectors[fileLba + s] = _sector(fileLba + s, data);
    }
  }

  static int _dirRecord(
      Uint8List buf, int o, int lba, int size, bool dir, String name) {
    final len = 33 + name.length + (name.length.isEven ? 1 : 0);
    final d = ByteData.sublistView(buf);
    buf[o] = len;
    d.setUint32(o + 2, lba, Endian.little);
    d.setUint32(o + 6, lba);
    d.setUint32(o + 10, size, Endian.little);
    d.setUint32(o + 14, size);
    buf[o + 25] = dir ? 2 : 0;
    buf[o + 32] = name.length;
    buf.setRange(o + 33, o + 33 + name.length, name.codeUnits);
    return len;
  }

  static Uint8List _sector(int lba, Uint8List data) {
    final raw = Uint8List(Disc.sectorSize);
    raw.setRange(0, 12, Disc.sync);
    final (m, s, f) = Disc.lbaToMsf(lba, addLeadIn: true);
    int bcd(int v) => (v ~/ 10) << 4 | v % 10;
    raw[12] = bcd(m);
    raw[13] = bcd(s);
    raw[14] = bcd(f);
    raw[15] = 1;
    raw.setRange(16, 16 + 2048, data);
    return raw;
  }

  @override
  Uint8List read(int sector) {
    final lba = sector - 150;
    return lba >= 0 && lba < sectors.length ? sectors[lba] : Uint8List(0);
  }

  @override
  int get trackCount => 1;

  @override
  int get totalSectors => sectors.length;

  @override
  int startLba(int trackNo) => 0;

  @override
  bool get isEmpty => false;

  @override
  bool isAudio(int trackNo) => false;
}

void main() {
  group('scu', () {
    test('interrupt level and acknowledge', () {
      final ss = _newSs();
      final master = ss.master as _TestCpu;

      ss.bus.write32(0x25fe00a0, 0); // unmask all
      ss.scu.onVBlankIn();
      expect(master.irl, 0xf);

      ss.scu.onSystemManager();
      expect(master.irl, 0xf);

      expect(master.onIrlAck(), 0x40);
      expect(master.irl, 0x8);
      expect(master.onIrlAck(), 0x47);
      expect(master.irl, 0);
    });

    test('masked interrupt is not delivered', () {
      final ss = _newSs();
      final master = ss.master as _TestCpu;

      ss.bus.write32(0x25fe00a0, 0xbffe); // only vblank-in enabled
      ss.scu.onHBlankIn();
      expect(master.irl, 0);
      ss.scu.onVBlankIn();
      expect(master.irl, 0xf);
    });

    test('slave receives vblank-in and hblank-in', () {
      final ss = _newSs();
      final slave = ss.slave as _TestCpu;

      ss.scu.onHBlankIn();
      expect(slave.irl, 2);
      ss.scu.onVBlankIn();
      expect(slave.irl, 6);
      expect(slave.onIrlAck(), 0x43);
      expect(slave.onIrlAck(), 0x41);
      expect(slave.irl, 0);
    });

    test('direct DMA from work RAM to VDP1 VRAM', () {
      final ss = _newSs();
      for (int i = 0; i < 16; i++) {
        ss.bus.write8(0x26000000 + i, i + 1);
      }

      ss.bus.write32(0x25fe0000, 0x06000000); // D0R
      ss.bus.write32(0x25fe0004, 0x05c00100); // D0W
      ss.bus.write32(0x25fe0008, 16); // D0C
      ss.bus.write32(0x25fe000c, 0x101); // read +4, write +2
      ss.bus.write32(0x25fe0014, 0x7); // manual start
      ss.bus.write32(0x25fe0010, 0x101); // enable + start

      for (int i = 0; i < 16; i++) {
        expect(ss.vdp1.vram[0x100 + i], i + 1);
      }
      expect(ss.scu.ist & (1 << 11), isNot(0));
    });

    test('indirect DMA', () {
      final ss = _newSs();
      for (int i = 0; i < 8; i++) {
        ss.bus.write8(0x26001000 + i, 0xa0 + i);
        ss.bus.write8(0x26002000 + i, 0xb0 + i);
      }
      // table: count, dst, src (bit31 = end)
      final table = [
        4, 0x25e00000, 0x26001000, //
        8, 0x25e00010, 0x26002000 | 0x80000000,
      ];
      for (int i = 0; i < table.length; i++) {
        ss.bus.write32(0x26003000 + i * 4, table[i]);
      }

      ss.bus.write32(0x25fe0024, 0x06003000); // D1W: table address
      ss.bus.write32(0x25fe002c, 0x101);
      ss.bus.write32(0x25fe0034, 0x01000007); // indirect, manual
      ss.bus.write32(0x25fe0030, 0x101);

      expect(ss.vdp2.vram.sublist(0, 4), [0xa0, 0xa1, 0xa2, 0xa3]);
      expect(ss.vdp2.vram.sublist(0x10, 0x18),
          [for (int i = 0; i < 8; i++) 0xb0 + i]);
      expect(ss.scu.ist & (1 << 10), isNot(0));
    });

    test('dsp program execution', () {
      final ss = _newSs();

      ss.bus.write32(0x25fe0080, 0x8000); // load PC = 0
      for (final op in [
        0x94000003, // MVI #3, PL
        0x00060000, // MOV M0, A
        0x10040000, // ADD, MOV ALU, A
        0x00003109, // MOV ALL, MC1
        0xf8000000, // ENDI
      ]) {
        ss.bus.write32(0x25fe0084, op);
      }
      ss.bus.write32(0x25fe0088, 0x00); // bank 0, addr 0
      ss.bus.write32(0x25fe008c, 10);

      ss.bus.write32(0x25fe0080, 0x18000); // execute from PC = 0
      ss.scu.dsp.exec(100);

      expect(ss.scu.dsp.data[1][0], 13);
      expect(ss.scu.dsp.ct[1], 1);
      expect(ss.scu.dsp.executing, false);
      expect(ss.scu.ist & (1 << 5), isNot(0));

      final ppaf = ss.bus.read32(0x25fe0080);
      expect(ppaf & (1 << 18), isNot(0)); // E flag
    });

    test('dsp loop with LPS', () {
      final ss = _newSs();
      ss.bus.write32(0x25fe0080, 0x8000);
      for (final op in [
        0xa8000003, // MVI #3, LOP
        0xe8000000, // LPS
        0x00001101, // MOV #1, MC1 (repeated LOP+1 times)
        0xf0000000, // END
      ]) {
        ss.bus.write32(0x25fe0084, op);
      }
      ss.bus.write32(0x25fe0080, 0x18000);
      ss.scu.dsp.exec(100);

      expect(ss.scu.dsp.ct[1], 4);
      expect(ss.scu.dsp.data[1].sublist(0, 5), [1, 1, 1, 1, 0]);
    });
  });

  group('vdp', () {
    test('NBG0 256 color cell', () {
      final ss = _newSs();
      final b = ss.bus;

      b.write16(0x25f80000, 0x8000); // TVMD: display on, 320x224
      b.write16(0x25f80020, 0x0001); // BGON: NBG0
      b.write16(0x25f80028, 0x0010); // CHCTLA: NBG0 256 colors
      b.write16(0x25f80030, 0x8000); // PNCN0: 1 word
      b.write16(0x25f800f8, 0x0007); // PRINA

      b.write16(0x25e00000, 0x0200); // pattern (0,0): char 0x200 (0x4000)
      for (int i = 0; i < 8; i++) {
        b.write8(0x25e04000 + i, i + 1); // row 0 dots 1..8
      }
      b.write16(0x25f00002, 0x001f); // color 1: red
      b.write16(0x25f00004, 0x03e0); // color 2: green

      ss.vdp2.renderLine(0);
      final fb = ss.vdp2.imageBuffer.buffer.buffer.asUint32List();
      expect(fb[0], 0xff0000ff);
      expect(fb[1], 0xff00ff00);
    });

    test('VDP1 polygon and sprite composed on VDP2 sprite layer', () {
      final ss = _newSs();
      final b = ss.bus;

      void cmd(int index, Map<int, int> words) {
        for (final e in words.entries) {
          b.write16(0x25c00000 + index * 0x20 + e.key, e.value);
        }
      }

      cmd(0, {0x00: 0x0009, 0x14: 319, 0x16: 223}); // system clip
      cmd(1, {0x00: 0x000a, 0x0c: 0, 0x0e: 0}); // local coordinate
      cmd(2, {
        0x00: 0x0004, // polygon
        0x04: 0x00c0,
        0x06: 0x801f,
        0x0c: 10, 0x0e: 10, 0x10: 20, 0x12: 10, //
        0x14: 20, 0x16: 20, 0x18: 10, 0x1a: 20,
      });
      cmd(3, {
        0x00: 0x0000, // normal sprite
        0x04: 0x0028, // RGB
        0x08: 0x1000 >> 3,
        0x0a: 0x0108, // 8x8
        0x0c: 100, 0x0e: 100,
      });
      cmd(4, {0x00: 0x8000});

      for (int i = 0; i < 64; i++) {
        b.write16(0x25c01000 + i * 2, i == 0 ? 0 : 0x83e0);
      }

      b.write16(0x25d00004, 1); // PTMR: draw now

      final fb = ss.vdp1.drawFb;
      expect(fb[15 * 512 + 15], 0x801f);
      expect(fb[9 * 512 + 15], 0);
      expect(fb[100 * 512 + 100], 0);
      expect(fb[100 * 512 + 101], 0x83e0);
      expect(fb[107 * 512 + 107], 0x83e0);
      expect(fb[108 * 512 + 108], 0);
      expect(ss.vdp1.readReg(0x10) & 2, 2);

      ss.vdp1.onVBlankIn(); // swap buffers

      b.write16(0x25f80000, 0x8000);
      b.write16(0x25f800e0, 0x0020); // SPCTL: mixed RGB
      b.write16(0x25f800f0, 0x0007); // PRISA
      ss.vdp2.renderLine(15);
      final out = ss.vdp2.imageBuffer.buffer.buffer.asUint32List();
      expect(out[15 * 320 + 15], 0xff0000ff);
    });

    test('draw end interrupt is delayed', () {
      final ss = _newSs();
      ss.bus.write32(0x25fe00a0, 0);
      ss.bus.write16(0x25c00000, 0x8000);
      ss.bus.write16(0x25d00004, 1);
      expect(ss.scu.ist & (1 << 13), 0);
      ss.vdp1.exec(100000);
      expect(ss.scu.ist & (1 << 13), isNot(0));
    });
  });

  group('smpc', () {
    test('intback status and peripheral', () {
      final ss = _newSs();
      final b = ss.bus;

      b.write8(0x20100001, 0x01); // IREG0: status
      b.write8(0x20100003, 0x08); // IREG1: peripheral
      b.write8(0x20100005, 0xf0);
      b.write8(0x20100063, 0x01); // SF
      b.write8(0x2010001f, 0x10); // INTBACK
      ss.smpc.exec(1000);

      expect(b.read8(0x20100063), 0); // SF
      expect(b.read8(0x20100021) & 0x80, 0x80); // OREG0
      expect(b.read8(0x20100061) & 0x20, 0x20); // SR: more data
      expect(ss.scu.ist & (1 << 7), isNot(0));

      ss.padDown(0, ss.buttons[5]); // start
      b.write8(0x20100001, 0x80); // continue
      expect(b.read8(0x20100021), 0xf1);
      expect(b.read8(0x20100023), 0x02);
      expect(b.read8(0x20100025), 0xf7); // start pressed
      expect(b.read8(0x20100027), 0xff);
    });

    test('sound cpu on runs 68000 program', () {
      final ss = _newSs();
      final b = ss.bus;

      final prog = [
        0x0007, 0xfff0, 0x0000, 0x0400, // vectors: SSP, PC
      ];
      for (int i = 0; i < prog.length; i++) {
        b.write16(0x25a00000 + i * 2, prog[i]);
      }
      final code = [0x33fc, 0x1234, 0x0000, 0x1000, 0x60fe];
      for (int i = 0; i < code.length; i++) {
        b.write16(0x25a00400 + i * 2, code[i]);
      }

      b.write8(0x2010001f, 0x06); // SNDON
      ss.smpc.exec(1000);

      final samples = Float32List(1000);
      ss.scsp.exec(256 * 10, samples, 0);
      expect(b.read16(0x25a01000), 0x1234);
    });
  });

  group('scsp', () {
    test('key on produces sound', () {
      final ss = _newSs();
      final b = ss.bus;

      for (int i = 0; i < 128; i++) {
        b.write16(0x25a01000 + i * 2, i < 64 ? 0x4000 : 0xc000);
      }

      const slot = 0x25b00000;
      b.write16(slot + 0x02, 0x1000); // SA
      b.write16(slot + 0x04, 0); // LSA
      b.write16(slot + 0x06, 127); // LEA
      b.write16(slot + 0x08, 0x001f); // AR
      b.write16(slot + 0x0a, 0x001f); // RR
      b.write16(slot + 0x0c, 0x0000); // TL
      b.write16(slot + 0x10, 0x0000); // pitch
      b.write16(slot + 0x16, 0xe000); // DISDL = 7
      b.write16(0x25b00400, 0x000f); // MVOL
      b.write16(slot + 0x00, 0x1820); // KYONEX | KYONB | loop

      final out = Float32List(2000);
      ss.scsp.exec(256 * 500, out, 0);
      expect(out.any((v) => v.abs() > 0.01), true);
    });
  });

  group('cdblock', () {
    Ss withDisc() {
      final ss = _newSs();
      ss.setDisc(_TestDisc());
      return ss;
    }

    void command(Ss ss, int c1, int c2, int c3, int c4) {
      ss.bus.write16(0x25890008, ~0x0001 & 0xffff); // clear CMOK
      ss.bus.write16(0x25890018, c1);
      ss.bus.write16(0x2589001c, c2);
      ss.bus.write16(0x25890020, c3);
      ss.bus.write16(0x25890024, c4);
    }

    int cr(Ss ss, int n) => ss.bus.read16(0x25890018 + n * 4);

    test('signature after reset', () {
      final ss = withDisc();
      expect([for (int i = 0; i < 4; i++) cr(ss, i)],
          [0x0043, 0x4442, 0x4c4f, 0x434b]);
    });

    test('get TOC', () {
      final ss = withDisc();
      command(ss, 0x0200, 0, 0, 0);
      expect(ss.bus.read16(0x25890008) & 0x3, 0x3); // CMOK | DRDY
      expect(cr(ss, 1), 0xcc);

      final toc = [
        for (int i = 0; i < 0xcc; i++) ss.bus.read16(0x25818000)
      ];
      expect(toc[0] << 16 | toc[1], 0x41000096);
      expect(toc[101 * 2] << 16 | toc[101 * 2 + 1], 0x41000000 | 40 + 150);

      command(ss, 0x0600, 0, 0, 0);
      expect(cr(ss, 1), 0xcc);
    });

    test('file info and read file', () {
      final ss = withDisc();

      command(ss, 0x7300, 0, 0, 2);
      final info = [for (int i = 0; i < 6; i++) ss.bus.read16(0x25818000)];
      expect(info[0] << 16 | info[1], _TestDisc.fileLba + 150);
      expect(info[2] << 16 | info[3], _TestDisc.fileSize);
      command(ss, 0x0600, 0, 0, 0);

      command(ss, 0x7400, 0, 0x0000, 2); // read file 2 via filter 0
      ss.cdblock.exec(28636360 ~/ 150 * 4);
      expect(ss.bus.read16(0x25890008) & 0x0200, 0x0200); // EFLS

      command(ss, 0x5100, 0, 0x0000, 0); // get sector number
      expect(cr(ss, 3), 2);

      command(ss, 0x6300, 0, 0x0000, 2); // get then delete
      final data = [
        for (int i = 0; i < 1024; i++) ss.bus.read32(0x25818000)
      ];
      expect(data[0], 0x00010203);
      expect(data[512], 0x07080900 | 0x0a);
      command(ss, 0x0600, 0, 0, 0);
      expect(cr(ss, 1), 2048); // words

      command(ss, 0x5100, 0, 0x0000, 0);
      expect(cr(ss, 3), 0);
    });

    test('play with filter range and periodic report', () {
      final ss = withDisc();
      command(ss, 0x3000, 0, 0x0000, 0); // CD -> filter 0
      command(ss, 0x1000 | 0x80, 150 + 16, 0x0080, 3); // play FAD 166, 3 sectors
      expect(cr(ss, 0) >> 8, 0x03); // PLAY
      ss.cdblock.exec(28636360 ~/ 150 * 5);
      expect(ss.bus.read16(0x25890008) & 0x0010, 0x0010); // PEND

      command(ss, 0x5100, 0, 0x0000, 0);
      expect(cr(ss, 3), 3);
      command(ss, 0x5400, 0, 0x0000, 0); // sector info
      expect(cr(ss, 1), 166);

      cr(ss, 3); // host has read the response
      ss.cdblock.exec(28636360 ~/ 30);
      expect(cr(ss, 0) >> 8, 0x21); // periodic, PAUSE
    });
  });

  group('core', () {
    test('runs frames without cpu', () {
      final ss = _newSs();
      ss.bus.write16(0x25f80000, 0x8000);
      int lines = 0;
      while (lines < ss.scanlinesInFrame * 2) {
        if (ss.exec(false).scanlineRendered) lines++;
      }
      expect(ss.vdp2.frame, 2);
      expect(ss.imageBuffer().width, 320);
    });
  });
}

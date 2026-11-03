import 'dart:typed_data';

import 'package:fnesemu_core/src/cdrom.dart';
import 'package:fnesemu_core/src/core/ss/cpu.dart';
import 'package:fnesemu_core/src/core/ss/ss.dart';
import 'package:fnesemu_core/src/sram.dart';
import 'package:test/test.dart';

import '../../support/fake_cdrom_drive.dart';
import '../pad_helper.dart';

class _TestCpu extends NullCpu {
  _TestCpu(super.bus, {super.master});

  int irl = 0;
  int nmiCount = 0;

  @override
  void setIrl(int level) => irl = level;

  @override
  void nmi() => nmiCount++;
}

class _SliceCpu extends _TestCpu {
  _SliceCpu(super.bus, {super.master});
  final budgets = <int>[];
  @override
  bool run(int targetClocks) {
    budgets.add(targetClocks - clocks);
    return super.run(targetClocks);
  }
}

Ss _newSs() {
  final ss = Ss(cpuFactory: (bus, master) => _TestCpu(bus, master: master))
    ..setSram(Sram())
    ..setRom(Uint8List(0x80000));
  ss.reset();
  return ss;
}

// in-memory mode 1 disc with an ISO9660 file system
class _TestDisc {
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
    final raw = Uint8List(cdSectorSize);
    raw.setRange(0, 12, cdSync);
    final (m, s, f) = Msf.ofLba(lba).parts();
    int bcd(int v) => (v ~/ 10) << 4 | v % 10;
    raw[12] = bcd(m);
    raw[13] = bcd(s);
    raw[14] = bcd(f);
    raw[15] = 1;
    raw.setRange(16, 16 + 2048, data);
    return raw;
  }
}

void main() {

  group('scu', () {

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

  });

  group('vdp', () {

  });

  group('smpc', () {

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
      ss.setCdromDrive(FakeCdromDrive(_TestDisc().sectors));
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

      final toc = [for (int i = 0; i < 0xcc; i++) ss.bus.read16(0x25818000)];
      expect(toc[0] << 16 | toc[1], 0x41000096);
      expect(toc[101 * 2] << 16 | toc[101 * 2 + 1], 0x41000000 | 40 + 150);

      command(ss, 0x0600, 0, 0, 0);
      expect(cr(ss, 1), 0xcc);
    });

  });

  group('core', () {
  });
}

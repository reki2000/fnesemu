import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ps2/gif.dart';
import 'package:fnesemu_core/src/core/ps2/gs/gs.dart';
import 'package:fnesemu_core/src/core/ps2/gs/gs_memory.dart';
import 'package:test/test.dart';

const _offset = 2048 << 4;

int _xyz(num x, num y, [int z = 0]) =>
    ((x * 16).round() + _offset) |
    (((y * 16).round() + _offset) << 16) |
    (z << 32);

int _rgba(int r, int g, int b, [int a = 0x80]) =>
    r | (g << 8) | (b << 16) | (a << 24);

int _frame(int fbp, int fbw, int psm, [int mask = 0]) =>
    fbp | (fbw << 16) | (psm << 24) | (mask << 32);

/// a GS with a 64x64 CT32 frame at block 0 and nothing else enabled
Gs _gs({int psm = GsPsm.ct32}) {
  final gs = Gs();
  gs.writeRegister(0x4c, _frame(0, 1, psm));
  gs.writeRegister(0x18, _offset | (_offset << 32));
  gs.writeRegister(0x40, 63 << 16 | 63 << 48);
  return gs;
}

int _px(Gs gs, int x, int y, [int psm = GsPsm.ct32]) =>
    gs.mem.read(psm, 0, 1, x, y);

void _sprite(Gs gs, num x0, num y0, num x1, num y1, int color,
    {int z = 0, int prim = 6}) {
  gs.writeRegister(0x00, prim);
  gs.writeRegister(0x01, color);
  gs.writeRegister(0x05, _xyz(x0, y0, z));
  gs.writeRegister(0x05, _xyz(x1, y1, z));
}

void main() {
  group('transfers', () {
    test('host to local and back in PSMCT32', () {
      final gs = _gs();
      gs.writeRegister(0x50, 0 | (1 << 16) | (0 << 24) | (0 << 32) | (1 << 48));
      gs.writeRegister(0x51, 0);
      gs.writeRegister(0x52, 3 | (2 << 32));
      gs.writeRegister(0x53, 0);
      for (var i = 0; i < 6; i++) {
        gs.hostWord(0x100 + i);
      }
      expect(_px(gs, 0, 0), 0x100);
      expect(_px(gs, 2, 0), 0x102);
      expect(_px(gs, 0, 1), 0x103);
      expect(_px(gs, 2, 1), 0x105);
      // read back
      gs.writeRegister(0x50, 0 | (1 << 16) | (0 << 24));
      gs.writeRegister(0x51, 0);
      gs.writeRegister(0x52, 3 | (2 << 32));
      gs.writeRegister(0x53, 1);
      final out = Int64List(2);
      gs.readQuad(out);
      expect(out[0], (0x101 << 32) | 0x100);
      expect(out[1], (0x103 << 32) | 0x102);
    });

    test('24-bit pixels are packed across words', () {
      final gs = _gs();
      gs.writeRegister(0x50, (1 << 32) * 0 | (1 << 48) | (1 << 56));
      gs.writeRegister(0x52, 4 | (1 << 32));
      gs.writeRegister(0x53, 0);
      // pixels 0x030201, 0x060504, 0x090807, 0x0c0b0a
      gs.hostWord(0x04030201);
      gs.hostWord(0x08070605);
      gs.hostWord(0x0c0b0a09);
      expect(gs.mem.read(GsPsm.ct24, 0, 1, 0, 0), 0x030201);
      expect(gs.mem.read(GsPsm.ct24, 0, 1, 1, 0), 0x060504);
      expect(gs.mem.read(GsPsm.ct24, 0, 1, 3, 0), 0x0c0b0a);
    });

    test('8-bit pixels use four to a word and the transfer stops at the end',
        () {
      final gs = _gs();
      gs.writeRegister(0x50, (1 << 48) | (GsPsm.t8 << 56));
      gs.writeRegister(0x52, 3 | (1 << 32));
      gs.writeRegister(0x53, 0);
      gs.hostWord(0x44332211);
      gs.hostWord(0x88776655);
      expect(gs.mem.read(GsPsm.t8, 0, 1, 2, 0), 0x33);
      expect(gs.mem.read(GsPsm.t8, 0, 1, 3, 0), 0);
    });

    test('local to local copy', () {
      final gs = _gs();
      gs.mem.write(GsPsm.ct32, 0, 1, 1, 1, 0xabcdef01);
      gs.writeRegister(
          0x50, 0 | (1 << 16) | (0 << 24) | (32 << 32) | (1 << 48));
      gs.writeRegister(0x51, 1 | (1 << 16) | (4 << 32) | (5 << 48));
      gs.writeRegister(0x52, 1 | (1 << 32));
      gs.writeRegister(0x53, 2);
      expect(gs.mem.read(GsPsm.ct32, 32, 1, 4, 5), 0xabcdef01);
    });

    test('a local copy follows the transmission order of TRXPOS', () {
      final gs = _gs();
      for (var x = 0; x < 4; x++) {
        gs.mem.write(GsPsm.ct32, 0, 1, x, 0, x + 1);
      }
      gs.writeRegister(0x50, (1 << 16) | (1 << 48));
      // right to left, so the copy one pixel to the right does not smear
      gs.writeRegister(0x51, (1 << 32) | (2 << 59));
      gs.writeRegister(0x52, 4 | (1 << 32));
      gs.writeRegister(0x53, 2);
      expect([for (var x = 0; x < 5; x++) _px(gs, x, 0)], [1, 1, 2, 3, 4]);
    });
  });

  group('drawing', () {
    test('a sprite covers the pixels whose centres are inside', () {
      final gs = _gs();
      _sprite(gs, 2, 3, 6, 5, _rgba(10, 20, 30));
      var count = 0;
      for (var y = 0; y < 64; y++) {
        for (var x = 0; x < 64; x++) {
          final inside = x >= 2 && x < 6 && y >= 3 && y < 5;
          if (inside) count++;
          expect(_px(gs, x, y), inside ? _rgba(10, 20, 30) : 0,
              reason: '($x,$y)');
        }
      }
      expect(count, 8);
    });

    test('fractional sprite corners follow pixel centres', () {
      final gs = _gs();
      _sprite(gs, 1.5, 0, 3.5, 1, _rgba(1, 2, 3));
      // pixel centres 1.5 (inclusive), 2.5; 3.5 is excluded
      expect(_px(gs, 1, 0), _rgba(1, 2, 3));
      expect(_px(gs, 2, 0), _rgba(1, 2, 3));
      expect(_px(gs, 3, 0), 0);
      expect(_px(gs, 0, 0), 0);
    });

    test('two triangles of a quad cover every pixel exactly once', () {
      final gs = _gs();
      // additive blend: Cs + Cd
      gs.writeRegister(0x42, 0 | (2 << 2) | (2 << 4) | (1 << 6) | (0x80 << 32));
      gs.writeRegister(0x01, _rgba(0x20, 0x20, 0x20));
      gs.writeRegister(0x00, 3 | 0x40);
      for (final (x, y) in [(3, 3), (21.25, 4), (4.5, 17.75)]) {
        gs.writeRegister(0x05, _xyz(x, y));
      }
      for (final (x, y) in [(21.25, 4), (22, 20), (4.5, 17.75)]) {
        gs.writeRegister(0x05, _xyz(x, y));
      }
      var covered = 0, doubled = 0;
      for (var y = 0; y < 30; y++) {
        for (var x = 0; x < 30; x++) {
          final c = _px(gs, x, y) & 0xff;
          if (c > 0) covered++;
          if (c > 0x20) doubled++;
        }
      }
      expect(covered, greaterThan(150));
      expect(doubled, 0, reason: 'the shared edge must not be drawn twice');
    });

    test('a list triangle ends at its third vertex even without a kick', () {
      final gs = _gs();
      gs.writeRegister(0x01, _rgba(0x20, 0x20, 0x20));
      gs.writeRegister(0x00, 3);
      // the first triangle is culled: its last vertex goes to XYZ3
      gs.writeRegister(0x05, _xyz(0, 0));
      gs.writeRegister(0x05, _xyz(20, 0));
      gs.writeRegister(0x0d, _xyz(0, 20));
      gs.writeRegister(0x05, _xyz(25, 5));
      gs.writeRegister(0x05, _xyz(30, 25));
      expect(_px(gs, 18, 6), 0, reason: 'no triangle mixes the two');
      gs.writeRegister(0x05, _xyz(5, 25));
      expect(_px(gs, 20, 20), _rgba(0x20, 0x20, 0x20));
      expect(_px(gs, 2, 2), 0);
    });

    test('Gouraud shading interpolates colours', () {
      final gs = _gs();
      gs.writeRegister(0x00, 3 | 0x08);
      gs.writeRegister(0x01, _rgba(0, 0, 0));
      gs.writeRegister(0x05, _xyz(0, 0));
      gs.writeRegister(0x01, _rgba(200, 0, 0));
      gs.writeRegister(0x05, _xyz(40, 0));
      gs.writeRegister(0x01, _rgba(0, 0, 0));
      gs.writeRegister(0x05, _xyz(0, 40));
      final left = _px(gs, 1, 1) & 0xff, mid = _px(gs, 20, 1) & 0xff;
      expect(left, lessThan(10));
      expect(mid, inInclusiveRange(90, 110));
    });

    test('depth test rejects a farther sprite and the Z buffer is written', () {
      final gs = _gs();
      gs.writeRegister(0x4e, 64 | ((GsPsm.z32 - 0x30) << 24));
      gs.writeRegister(0x47, (1 << 16) | (2 << 17)); // ZTE, GEQUAL
      _sprite(gs, 0, 0, 4, 4, _rgba(1, 1, 1), z: 1000);
      _sprite(gs, 0, 0, 4, 4, _rgba(2, 2, 2), z: 500);
      expect(_px(gs, 1, 1), _rgba(1, 1, 1));
      _sprite(gs, 0, 0, 4, 4, _rgba(3, 3, 3), z: 1500);
      expect(_px(gs, 1, 1), _rgba(3, 3, 3));
      expect(gs.mem.read(GsPsm.z32, 64 * 32, 1, 1, 1), 1500);
    });

    test('alpha blending mixes with the destination', () {
      final gs = _gs();
      _sprite(gs, 0, 0, 4, 4, _rgba(200, 100, 0, 0xff));
      // Cv = (Cs - Cd) * As >> 7 + Cd
      gs.writeRegister(0x42, 0 | (1 << 2) | (0 << 4) | (1 << 6));
      gs.writeRegister(0x01, _rgba(0, 100, 200, 0x40));
      gs.writeRegister(0x00, 6 | 0x40);
      gs.writeRegister(0x05, _xyz(0, 0));
      gs.writeRegister(0x05, _xyz(4, 4));
      final p = _px(gs, 1, 1);
      expect(p & 0xff, 100);
      expect((p >> 8) & 0xff, 100);
      expect((p >> 16) & 0xff, 100);
    });

    test('dithering adds the DIMX entry to a 16-bit frame', () {
      final gs = _gs(psm: GsPsm.ct16);
      gs.writeRegister(0x44, 3); // +3 at (0, 0)
      gs.writeRegister(0x45, 1);
      _sprite(gs, 0, 0, 2, 2, _rgba(5, 0, 0));
      expect(_px(gs, 0, 0, GsPsm.ct16) & 31, 1);
      expect(_px(gs, 1, 0, GsPsm.ct16) & 31, 0);
    });

    test('the destination alpha test passes every pixel of a 24-bit frame', () {
      final gs = _gs(psm: GsPsm.ct24);
      gs.writeRegister(0x47, (1 << 14) | (1 << 15) | (1 << 16) | (1 << 17));
      _sprite(gs, 0, 0, 2, 2, _rgba(0x12, 0x34, 0x56));
      expect(_px(gs, 0, 0, GsPsm.ct24), 0x563412);
    });

    test('frame mask keeps masked bits', () {
      final gs = _gs();
      _sprite(gs, 0, 0, 2, 2, _rgba(0xff, 0xff, 0xff, 0xff));
      gs.writeRegister(0x4c, _frame(0, 1, 0, 0x0000ffff));
      _sprite(gs, 0, 0, 2, 2, _rgba(0, 0, 0, 0));
      expect(_px(gs, 0, 0), 0x0000ffff);
    });

    test('16-bit frames pack 5551', () {
      final gs = _gs(psm: GsPsm.ct16);
      _sprite(gs, 0, 0, 2, 2, _rgba(0xf8, 0x80, 0x08, 0x80));
      expect(_px(gs, 0, 0, GsPsm.ct16), 0x861f);
    });

    test('alpha test with FB_ONLY style failure skips the pixel', () {
      final gs = _gs();
      gs.writeRegister(0x47, 1 | (6 << 1) | (0x80 << 4)); // ATE, GREATER 0x80
      _sprite(gs, 0, 0, 2, 2, _rgba(5, 5, 5, 0x80));
      expect(_px(gs, 0, 0), 0);
      _sprite(gs, 0, 0, 2, 2, _rgba(5, 5, 5, 0x81));
      expect(_px(gs, 0, 0), _rgba(5, 5, 5, 0x81));
    });
  });

  group('texturing', () {
    void upload(Gs gs, int bp, int psm, int w, int h, List<int> words,
        {int bw = 1}) {
      gs.writeRegister(0x50, (bp << 32) | (bw << 48) | (psm << 56));
      gs.writeRegister(0x51, 0);
      gs.writeRegister(0x52, w | (h << 32));
      gs.writeRegister(0x53, 0);
      for (final word in words) {
        gs.hostWord(word);
      }
    }

    int tex0(int bp, int bw, int psm, int tw, int th,
            {int tfx = 1,
            int tcc = 1,
            int cbp = 0,
            int cpsm = 0,
            int csa = 0,
            int cld = 1}) =>
        bp |
        (bw << 14) |
        (psm << 20) |
        (tw << 26) |
        (th << 30) |
        (tcc << 34) |
        (tfx << 35) |
        (cbp << 37) |
        (cpsm << 51) |
        (csa << 56) |
        (cld << 61);

    test('a LOD above 0 samples the mipmap level that MIPTBP1 points to', () {
      final gs = _gs();
      upload(gs, 100, GsPsm.ct32, 4, 4, List.filled(16, _rgba(10, 0, 0)));
      upload(gs, 200, GsPsm.ct32, 2, 2, List.filled(4, _rgba(20, 0, 0)));
      gs.writeRegister(0x06, tex0(100, 1, GsPsm.ct32, 2, 2));
      // TEX1: LCM (fixed K), MXL 1, MMIN nearest mipmap nearest, K 1.0
      gs.writeRegister(0x14, 1 | (1 << 2) | (2 << 6) | (16 << 32));
      gs.writeRegister(0x34, 200 | (1 << 14));
      gs.writeRegister(0x00, 6 | 0x10 | 0x100);
      gs.writeRegister(0x03, 0);
      gs.writeRegister(0x05, _xyz(10, 10));
      gs.writeRegister(0x03, (4 * 16) | ((4 * 16) << 16));
      gs.writeRegister(0x05, _xyz(14, 14));
      expect(_px(gs, 11, 11) & 0xff, 20);
      // K 0 uses level 0
      gs.writeRegister(0x14, 1 | (1 << 2) | (2 << 6));
      gs.writeRegister(0x05, _xyz(10, 10));
      gs.writeRegister(0x05, _xyz(14, 14));
      expect(_px(gs, 11, 11) & 0xff, 10);
    });

    test('a decal sprite maps texels one to one', () {
      final gs = _gs();
      upload(gs, 100, GsPsm.ct32, 4, 4, [
        for (var i = 0; i < 16; i++) _rgba(i * 10, 0, 0, 0xff),
      ]);
      gs.writeRegister(0x06, tex0(100, 1, GsPsm.ct32, 2, 2));
      gs.writeRegister(0x00, 6 | 0x10 | 0x100); // TME, FST
      gs.writeRegister(0x03, 0 | (0 << 16));
      gs.writeRegister(0x05, _xyz(10, 10));
      gs.writeRegister(0x03, (4 * 16) | ((4 * 16) << 16));
      gs.writeRegister(0x05, _xyz(14, 14));
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          expect(_px(gs, 10 + x, 10 + y) & 0xff, (y * 4 + x) * 10,
              reason: '($x,$y)');
        }
      }
    });

    test('a Z buffer read as a texture and drawn as a frame keeps its value',
        () {
      final gs = _gs();
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          gs.mem.write(GsPsm.z24, 100, 1, x, y, 0x123456 + y * 4 + x);
        }
      }
      gs.writeRegister(0x4c, _frame(6, 1, GsPsm.z24));
      gs.writeRegister(0x06, tex0(100, 1, GsPsm.z24, 2, 2));
      gs.writeRegister(0x00, 6 | 0x10 | 0x100); // TME, FST
      gs.writeRegister(0x03, 0);
      gs.writeRegister(0x05, _xyz(0, 0));
      gs.writeRegister(0x03, (4 * 16) | ((4 * 16) << 16));
      gs.writeRegister(0x05, _xyz(4, 4));
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          expect(gs.mem.read(GsPsm.z24, 6 * 32, 1, x, y), 0x123456 + y * 4 + x,
              reason: '($x,$y)');
        }
      }
    });

    test('ST coordinates are divided by Q', () {
      final gs = _gs();
      upload(gs, 100, GsPsm.ct32, 2, 2,
          [_rgba(10, 0, 0), _rgba(20, 0, 0), _rgba(30, 0, 0), _rgba(40, 0, 0)]);
      gs.writeRegister(0x06, tex0(100, 1, GsPsm.ct32, 1, 1));
      gs.writeRegister(0x00, 6 | 0x10);
      final one = Float32List(2)..[0] = 1.0;
      int bits(double v) {
        final d = ByteData(4)..setFloat32(0, v);
        return d.getUint32(0);
      }

      gs.writeRegister(0x01, _rgba(0x80, 0x80, 0x80) | (bits(2.0) << 32));
      gs.writeRegister(0x02, bits(0) | (bits(0) << 32));
      gs.writeRegister(0x05, _xyz(0, 0));
      gs.writeRegister(0x02, bits(2.0) | (bits(2.0) << 32)); // s/q = 1
      gs.writeRegister(0x05, _xyz(2, 2));
      expect(_px(gs, 0, 0) & 0xff, 10);
      expect(_px(gs, 1, 1) & 0xff, 40);
      expect(one[0], 1.0);
    });

    test('an indexed texture reads its palette', () {
      final gs = _gs();
      // a 16x16 CSM1 palette at block 200 in CT32, where the image position
      // of an entry swaps bits 3 and 4 of the index
      final palette = List.filled(256, 0);
      int at(int entry) =>
          (entry & ~0x18) | (entry & 8) << 1 | (entry & 16) >> 1;
      palette[at(3)] = _rgba(255, 0, 0, 0xff);
      palette[at(4)] = _rgba(0, 0, 255, 0xff);
      palette[at(8)] = _rgba(0, 255, 0, 0xff);
      palette[at(16)] = _rgba(255, 255, 255, 0xff);
      upload(gs, 200, GsPsm.ct32, 16, 16, palette);
      upload(gs, 300, GsPsm.t8, 4, 1, [0x10080403]);
      gs.writeRegister(0x06, tex0(300, 1, GsPsm.t8, 2, 0, cbp: 200));
      gs.writeRegister(0x00, 6 | 0x10 | 0x100);
      gs.writeRegister(0x03, 0);
      gs.writeRegister(0x05, _xyz(0, 0));
      gs.writeRegister(0x03, (4 * 16) | (1 * 16 << 16));
      gs.writeRegister(0x05, _xyz(4, 1));
      expect(_px(gs, 0, 0) & 0xffffff, 0x0000ff);
      expect(_px(gs, 1, 0) & 0xffffff, 0xff0000);
      expect(_px(gs, 2, 0) & 0xffffff, 0x00ff00);
      expect(_px(gs, 3, 0) & 0xffffff, 0xffffff);
    });

    test('a 4-bit texture reads 16 palette entries at CSA', () {
      final gs = _gs();
      // an 8x2 CSM1 palette in CT16: entry 1 = red, entry 9 = blue
      upload(gs, 200, GsPsm.ct16, 8, 2,
          [0x001f << 16, 0, 0, 0, 0x7c00 << 16, 0, 0, 0]);
      upload(gs, 300, GsPsm.t4, 2, 1, [0x91]);
      gs.writeRegister(
          0x06, tex0(300, 1, GsPsm.t4, 1, 0, cbp: 200, cpsm: 2, csa: 2));
      // CLD 0 keeps the loaded entries although CBP changes
      gs.writeRegister(0x06,
          tex0(300, 1, GsPsm.t4, 1, 0, cbp: 900, cpsm: 2, csa: 2, cld: 0));
      gs.writeRegister(0x00, 6 | 0x10 | 0x100);
      gs.writeRegister(0x03, 0);
      gs.writeRegister(0x05, _xyz(0, 0));
      gs.writeRegister(0x03, (2 * 16) | (1 * 16 << 16));
      gs.writeRegister(0x05, _xyz(2, 1));
      expect(_px(gs, 0, 0) & 0xffffff, 0x0000f8);
      expect(_px(gs, 1, 0) & 0xffffff, 0xf80000);
    });

    test('modulate scales the texel by the vertex colour', () {
      final gs = _gs();
      upload(gs, 100, GsPsm.ct32, 1, 1, [_rgba(200, 100, 50, 0x80)]);
      gs.writeRegister(0x06, tex0(100, 1, GsPsm.ct32, 0, 0, tfx: 0));
      gs.writeRegister(0x00, 6 | 0x10 | 0x100);
      gs.writeRegister(0x01, _rgba(0x40, 0x80, 0xff, 0x80));
      gs.writeRegister(0x03, 0);
      gs.writeRegister(0x05, _xyz(0, 0));
      gs.writeRegister(0x03, 16 | (16 << 16));
      gs.writeRegister(0x05, _xyz(1, 1));
      final p = _px(gs, 0, 0);
      expect(p & 0xff, 100);
      expect((p >> 8) & 0xff, 100);
      expect((p >> 16) & 0xff, (50 * 0xff) >> 7);
    });
  });

  group('GIF', () {
    int tag(int nloop, int flg, int nreg, int regs,
            {bool eop = true, int prim = -1}) =>
        nloop |
        (eop ? 1 << 15 : 0) |
        (prim >= 0 ? (1 << 46) | (prim << 47) : 0) |
        (flg << 58) |
        (nreg << 60);

    test('packed A+D writes general registers', () {
      final gs = _gs();
      final path = GifPath(gs);
      path.put(tag(2, 0, 1, 0xe), 0xe);
      path.put(_frame(5, 2, 0), 0x4c);
      path.put(0x1234, 0x50);
      expect(gs.contexts[0].frame, _frame(5, 2, 0));
      expect(gs.bitbltbuf, 0x1234);
      expect(path.busy, isFalse);
    });

    test('a tag sets Q to 1.0 and NLOOP 0 ignores PRIM', () {
      final gs = _gs();
      final path = GifPath(gs);
      gs.writeRegister(0x00, 3);
      gs.setQ(0x40000000);
      path.put(tag(0, 0, 1, 0xe, prim: 6), 0xe);
      expect(gs.prim, 3);
      expect(gs.qBits, 0x3f800000);
    });

    test('packed RGBAQ and XYZ2 draw a sprite', () {
      final gs = _gs();
      final path = GifPath(gs);
      // PRIM sprite via PRE, then RGBAQ, XYZ2, XYZ2 per loop
      path.put(tag(1, 0, 3, 0x551, prim: 6), 0x551);
      path.put(0x10 | (0x20 << 32), 0x30 | (0x80 << 32));
      path.put(_xyz(0, 0) & 0xffff | ((_xyz(0, 0) >> 16 & 0xffff) << 32), 0);
      path.put((_xyz(2, 2) & 0xffff) | ((_xyz(2, 2) >> 16 & 0xffff) << 32), 0);
      expect(_px(gs, 1, 1), _rgba(0x10, 0x20, 0x30));
    });

    test('image data goes to the transfer', () {
      final gs = _gs();
      gs.writeRegister(0x50, (1 << 48));
      gs.writeRegister(0x52, 2 | (2 << 32));
      gs.writeRegister(0x53, 0);
      final path = GifPath(gs);
      path.put(tag(1, 2, 0, 0), 0);
      expect(path.busy, isTrue);
      path.put(7 | (8 << 32), 9 | (10 << 32));
      expect(_px(gs, 0, 0), 7);
      expect(_px(gs, 1, 1), 10);
      expect(path.busy, isFalse);
    });

    test('reglist carries two registers per quadword', () {
      final gs = _gs();
      final path = GifPath(gs);
      // registers 0x0a (FOG) is not needed; use TEX0_1 (6) and CLAMP_1 (8)
      path.put(tag(1, 1, 2, 0x86), 0x86);
      path.put(0x1111, 0x2222);
      expect(gs.contexts[0].tex0, 0x1111);
      expect(gs.contexts[0].clamp, 0x2222);
    });
  });

  group('status', () {
    test('vblank sets CSR and interrupts unless masked', () {
      final gs = _gs();
      var interrupts = 0;
      gs.onInterrupt = () => interrupts++;
      gs.writePrivileged(0x12001010, 0); // unmask all
      gs.vblank();
      expect(gs.readPrivileged(0x12001000) & 8, 8);
      expect(interrupts, 1);
      gs.writePrivileged(0x12001000, 8); // clear
      expect(gs.readPrivileged(0x12001000) & 8, 0);
      gs.writePrivileged(0x12001010, 1 << 11); // mask VSINT
      gs.vblank();
      expect(interrupts, 1);
    });

    test('FINISH sets its flag', () {
      final gs = _gs();
      gs.writePrivileged(0x12001010, 0);
      gs.writeRegister(0x61, 0);
      expect(gs.readPrivileged(0x12001000) & 2, 2);
    });

    test('the display circuit is read into the image', () {
      final gs = _gs();
      _sprite(gs, 0, 0, 8, 8, _rgba(9, 8, 7));
      gs.writePrivileged(0x12000000, 1); // PMODE EN1
      gs.writePrivileged(0x12000070, 0 | (1 << 9)); // DISPFB1: FBP 0, FBW 1
      gs.writePrivileged(0x12000080, (63 << 32) | (31 << 44)); // 64x32
      final image = gs.image();
      expect((image.width, image.height), (64, 32));
      expect(image.buffer[0], 0xff000000 | (7 << 16) | (8 << 8) | 9);
      expect(image.buffer[63], 0xff000000);
    });

    test('a display taller than the visible lines is cut', () {
      final gs = _gs();
      gs.writePrivileged(0x12000000, 1);
      gs.writePrivileged(0x12000070, 1 << 9);
      gs.writePrivileged(0x12000080, (63 << 32) | (831 << 44));
      expect(gs.image().height, 240);
      gs.writePrivileged(0x12000020, 3); // SMODE2: interlaced
      expect(gs.image().height, 480);
    });
  });
}

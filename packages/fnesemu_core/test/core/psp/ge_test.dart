import 'dart:typed_data';

import 'package:fnesemu_core/src/core/psp/allegrex.dart';
import 'package:fnesemu_core/src/core/psp/ge.dart';
import 'package:fnesemu_core/src/core/psp/memory.dart';
import 'package:fnesemu_core/src/core/psp/psp.dart';
import 'package:fnesemu_core/src/types.dart';
import 'package:test/test.dart';

import 'fixture.dart';

int _floatBits(double value) {
  final data = ByteData(4)..setFloat32(0, value);
  return data.getUint32(0);
}

/// A vertex type for through-mode sprites with float texture
/// coordinates, a 32-bit color and float positions (24 bytes).
const _spriteType = 0x800000 | 0x03 | 0x1c | 0x180;

int _cmd(int op, int arg) => (op << 24) | (arg & 0xffffff);

/// Writes a display list and two sprite vertices into memory and returns
/// the list address. The frame buffer is VRAM offset 0, 512 wide, 8888.
int _writeList(PspMemory mem, List<int> commands, int color) {
  const listAt = 0x08800000;
  const verticesAt = 0x08801000;
  final words = <int>[
    _cmd(0x10, 0x080000), // BASE: the RAM segment, shifted by 8
    _cmd(0x9c, 0), // frame buffer pointer
    _cmd(0x9d, 512), // frame buffer width
    _cmd(0xd2, 3), // frame buffer format 8888
    _cmd(0x01, verticesAt & 0xffffff), // vertex address
    _cmd(0x12, _spriteType),
    ...commands,
    _cmd(0x0f, 0), // FINISH
    _cmd(0x0c, 0), // END
  ];
  for (var i = 0; i < words.length; i++) {
    mem.write32(listAt + i * 4, words[i]);
  }
  void vertex(int at, double x, double y, double u, double v) {
    mem.write32(at, _floatBits(u));
    mem.write32(at + 4, _floatBits(v));
    mem.write32(at + 8, color);
    mem.write32(at + 12, _floatBits(x));
    mem.write32(at + 16, _floatBits(y));
    mem.write32(at + 20, _floatBits(0));
  }

  vertex(verticesAt, 10, 20, 0, 0);
  vertex(verticesAt + 24, 30, 40, 2, 2);
  return listAt;
}

void main() {
  group('display lists', () {
    late PspMemory mem;
    late PspGe ge;
    late Allegrex cpu;

    setUp(() {
      mem = PspMemory();
      ge = PspGe(mem);
      cpu = Allegrex(mem);
    });

    /// The color bits of a pixel; its alpha bits hold the stencil.
    int pixel(int x, int y) =>
        mem.read32(0x04000000 + (y * 512 + x) * 4) & 0xffffff;

    test('a clear-mode sprite fills its rectangle', () {
      final list = _writeList(
          mem,
          [
            _cmd(0xd3, 0x101), // clear mode: enable, color buffer
            _cmd(0x04, 0x60002), // two sprite vertices
          ],
          0xff0000ff);
      final id = ge.enqueue(cpu, list, 0);
      expect(ge.listState(id), PspGe.stateDone);
      expect(pixel(10, 20), 0x0000ff);
      expect(pixel(29, 39), 0x0000ff);
      expect(pixel(30, 40), 0);
      expect(pixel(0, 0), 0);
    });

    test('the stencil test gates the color and its operations write alpha',
        () {
      int raw(int x, int y) => mem.read32(0x04000000 + (y * 512 + x) * 4);
      mem.write32(0x04000000 + (20 * 512 + 10) * 4, 0x00112233);
      mem.write32(0x04000000 + (20 * 512 + 12) * 4, 0x5a112233);
      final list = _writeList(
          mem,
          [
            _cmd(0x24, 1), // stencil test on
            _cmd(0xdc, 2 | 0x5a << 8 | 0xff << 16), // equal to 0x5a
            _cmd(0xdd, 3 | 4 << 16), // fail: invert, pass: increment
            _cmd(0x04, 0x60002),
          ],
          0xff0000ff);
      ge.enqueue(cpu, list, 0);
      expect(raw(12, 20), 0x5b0000ff); // passed: red, stencil + 1
      expect(raw(10, 20), 0xff112233); // failed: kept, stencil inverted
    });

    test('without the stencil test a 5551 draw keeps alpha and the mask',
        () {
      int raw(int x, int y) => mem.read16(0x04000000 + (y * 512 + x) * 2);
      mem.write16(0x04000000 + (20 * 512 + 10) * 2, 0x801f);
      final list = _writeList(
          mem,
          [
            _cmd(0xd2, 1), // frame buffer format 5551
            _cmd(0xe8, 0x0000ff), // the pixel mask protects red
            _cmd(0x04, 0x60002),
          ],
          0xff00ff00);
      ge.enqueue(cpu, list, 0);
      expect(raw(10, 20), 0x83ff); // red and alpha kept, green drawn
      expect(raw(12, 20), 0x03e0);
    });

    test('a jump after ORIGIN is relative to the ORIGIN command', () {
      final list = _writeList(
          mem,
          [
            _cmd(0x10, 0), // BASE 0: the jump target is the offset alone
            _cmd(0x14, 0), // ORIGIN
            _cmd(0x08, 0x10), // JUMP over the two ENDs
            _cmd(0x0c, 0),
            _cmd(0x0c, 0),
            _cmd(0x13, 0), // OFFSETADDR 0: vertices are not list-relative
            _cmd(0x10, 0x080000),
            _cmd(0xd3, 0x101),
            _cmd(0x04, 0x60002),
          ],
          0xff0000ff);
      ge.enqueue(cpu, list, 0);
      expect(pixel(10, 20), 0x0000ff);
    });

    test('a primitive continues from where the previous one ended', () {
      final list = _writeList(
          mem,
          [
            _cmd(0xd3, 0x101),
            _cmd(0x04, 0x60002), // the two vertices of _writeList
            _cmd(0x04, 0x60002), // the next two, written below
          ],
          0xff0000ff);
      // a second sprite from (50, 60) to (70, 80) right after the first
      void vertex(int at, double x, double y) {
        mem.write32(at + 8, 0xff00ff00);
        mem.write32(at + 12, _floatBits(x));
        mem.write32(at + 16, _floatBits(y));
        mem.write32(at + 20, _floatBits(0));
      }

      vertex(0x08801000 + 48, 50, 60);
      vertex(0x08801000 + 72, 70, 80);
      ge.enqueue(cpu, list, 0);
      expect(pixel(10, 20), 0x0000ff);
      expect(pixel(50, 60), 0x00ff00);
    });

    test('a vertex without a color takes the material color', () {
      // two through-mode vertices of 16-bit positions alone (6 bytes each)
      const plainAt = 0x08802000;
      for (final (i, (x, y)) in [(10, 20), (30, 40)].indexed) {
        mem.write16(plainAt + i * 6, x);
        mem.write16(plainAt + i * 6 + 2, y);
        mem.write16(plainAt + i * 6 + 4, 0);
      }
      final list = _writeList(
          mem,
          [
            _cmd(0x01, plainAt & 0xffffff),
            _cmd(0x12, 0x800100),
            _cmd(0x55, 0x302010), // ambient color
            _cmd(0x58, 0xff), // ambient alpha
            _cmd(0x04, 0x60002),
          ],
          0xffffffff);
      ge.enqueue(cpu, list, 0);
      expect(pixel(10, 20), 0x302010);
    });

    test('alpha blending mixes by the source alpha', () {
      mem.write32(0x04000000 + (20 * 512 + 10) * 4, 0xff0000ff); // red
      final list = _writeList(
          mem,
          [
            _cmd(0x21, 1), // blending on
            _cmd(0xdf, 0x032), // add, source alpha, one minus source alpha
            _cmd(0x04, 0x60002),
          ],
          0x80ff0000); // blue at half alpha
      ge.enqueue(cpu, list, 0);
      final pixel10 = pixel(10, 20);
      expect(pixel10 & 0xff, closeTo(0x7f, 1));
      expect((pixel10 >> 16) & 0xff, closeTo(0x80, 1));
    });

    test('a textured sprite samples the texture', () {
      // A 2x2 texture at VRAM offset 0x10000: red, green, blue, white.
      const texAt = 0x10000;
      mem.write32(0x04000000 + texAt, 0xff0000ff);
      mem.write32(0x04000000 + texAt + 4, 0xff00ff00);
      mem.write32(0x04000000 + texAt + 8, 0xffff0000);
      mem.write32(0x04000000 + texAt + 12, 0xffffffff);
      final list = _writeList(
          mem,
          [
            _cmd(0xa0, texAt), // texture pointer
            _cmd(0xa8, 2), // texture buffer width
            _cmd(0xb8, 0x101), // texture size 2x2
            _cmd(0xc3, 3), // texture format 8888
            _cmd(0x48, 0x3f8000), // texture scale 1.0
            _cmd(0x49, 0x3f8000),
            _cmd(0xc9, 3), // texture function: replace
            _cmd(0x1e, 1), // texture map enable
            _cmd(0x04, 0x60002),
          ],
          0xffffffff);
      ge.enqueue(cpu, list, 0);
      expect(pixel(10, 20), 0x0000ff);
      expect(pixel(29, 20), 0x00ff00);
      expect(pixel(10, 39), 0xff0000);
      expect(pixel(29, 39), 0xffffff);
    });

    test('a palette texture resolves through the loaded CLUT', () {
      const texAt = 0x10000;
      mem.vram[texAt] = 0;
      mem.vram[texAt + 1] = 1;
      const clutAt = 0x04020000;
      mem.write32(clutAt, 0xff000000);
      mem.write32(clutAt + 4, 0xffffffff);
      final list = _writeList(
          mem,
          [
            _cmd(0xa0, texAt),
            _cmd(0xa8, 2),
            _cmd(0xb8, 0x001), // texture size 2x1
            _cmd(0xc3, 5), // texture format T8
            _cmd(0xb0, clutAt & 0xffffff), // CLUT pointer, low bits
            _cmd(0xb1, (clutAt >> 24) << 16), // CLUT pointer, high bits
            _cmd(0xc5, 0xff03), // CLUT format 8888, mask 0xff
            _cmd(0xc4, 1), // load one CLUT block
            _cmd(0x48, 0x3f8000),
            _cmd(0x49, 0x3f8000),
            _cmd(0xc9, 3),
            _cmd(0x1e, 1),
            _cmd(0x04, 0x60002),
          ],
          0xffffffff);
      ge.enqueue(cpu, list, 0);
      expect(pixel(10, 20), 0x000000);
      expect(pixel(29, 20), 0xffffff);
    });

    test('a swizzled 4-bit texture reads its texels by block', () {
      // 64x16 texels, 32 bytes a row: texel (32, 0) starts the second
      // 16-byte block, which follows the first block's eight rows.
      const texAt = 0x10000;
      mem.vram[texAt + 128] = 0x01; // texels 32 and 33: indices 1 and 0
      mem.vram[texAt + 16] = 0x10; // where a linear layout would look
      const clutAt = 0x04020000;
      mem.write32(clutAt, 0xff000000);
      mem.write32(clutAt + 4, 0xffffffff);
      final list = _writeList(
          mem,
          [
            _cmd(0xa0, texAt),
            _cmd(0xa8, 64),
            _cmd(0xb8, 0x406), // texture size 64x16
            _cmd(0xc3, 4), // texture format T4
            _cmd(0xc2, 1), // swizzled
            _cmd(0xb0, clutAt & 0xffffff),
            _cmd(0xb1, (clutAt >> 24) << 16),
            _cmd(0xc5, 0xff03),
            _cmd(0xc4, 1),
            _cmd(0x48, 0x3f8000),
            _cmd(0x49, 0x3f8000),
            _cmd(0x4a, 0x420000), // texture offset u 32.0
            _cmd(0xc9, 3),
            _cmd(0x1e, 1),
            _cmd(0x04, 0x60002),
          ],
          0xffffffff);
      ge.enqueue(cpu, list, 0);
      expect(pixel(10, 20), 0xffffff);
      expect(pixel(29, 20), 0x000000);
    });

    test('a narrow swizzled texture steps its lines by a block width', () {
      // 16x16 texels, 8 bytes a row: line 1 starts at byte 16 of the
      // block, not at byte 8.
      const texAt = 0x10000;
      mem.vram[texAt + 16] = 0x01; // texels (0, 1) and (1, 1): 1 and 0
      mem.vram[texAt + 8] = 0x10; // where a linear layout would look
      const clutAt = 0x04020000;
      mem.write32(clutAt, 0xff000000);
      mem.write32(clutAt + 4, 0xffffffff);
      final list = _writeList(
          mem,
          [
            _cmd(0xa0, texAt),
            _cmd(0xa8, 16),
            _cmd(0xb8, 0x404), // texture size 16x16
            _cmd(0xc3, 4), // texture format T4
            _cmd(0xc2, 1), // swizzled
            _cmd(0xb0, clutAt & 0xffffff),
            _cmd(0xb1, (clutAt >> 24) << 16),
            _cmd(0xc5, 0xff03),
            _cmd(0xc4, 1),
            _cmd(0x48, 0x3f8000),
            _cmd(0x49, 0x3f8000),
            _cmd(0x4b, 0x3f8000), // texture offset v 1.0
            _cmd(0xc9, 3),
            _cmd(0x1e, 1),
            _cmd(0x04, 0x60002),
          ],
          0xffffffff);
      ge.enqueue(cpu, list, 0);
      expect(pixel(10, 20), 0xffffff);
      expect(pixel(29, 20), 0x000000);
    });

    test('a 16-bit index texture reads its palette', () {
      const texAt = 0x10000;
      // texels 0 and 1: indices 0x101 and 0x100, whose low byte the
      // mask keeps
      mem.vram[texAt] = 0x01;
      mem.vram[texAt + 1] = 0x01;
      mem.vram[texAt + 3] = 0x01;
      const clutAt = 0x04020000;
      mem.write32(clutAt, 0xff000000);
      mem.write32(clutAt + 4, 0xffffffff);
      final list = _writeList(
          mem,
          [
            _cmd(0xa0, texAt),
            _cmd(0xa8, 16),
            _cmd(0xb8, 0x404), // texture size 16x16
            _cmd(0xc3, 6), // texture format T16
            _cmd(0xb0, clutAt & 0xffffff),
            _cmd(0xb1, (clutAt >> 24) << 16),
            _cmd(0xc5, 0xff03),
            _cmd(0xc4, 1),
            _cmd(0x48, 0x3f8000),
            _cmd(0x49, 0x3f8000),
            _cmd(0xc9, 3),
            _cmd(0x1e, 1),
            _cmd(0x04, 0x60002),
          ],
          0xffffffff);
      ge.enqueue(cpu, list, 0);
      expect(pixel(10, 20), 0xffffff);
      expect(pixel(29, 20), 0x000000);
    });

    test('a stalled list resumes when its stall address moves', () {
      final list = _writeList(
          mem,
          [
            _cmd(0xd3, 0x101),
            _cmd(0x04, 0x60002),
          ],
          0xff0000ff);
      // The list has 6 fixed words before the PRIM at index 7.
      final stall = list + 7 * 4;
      final id = ge.enqueue(cpu, list, stall);
      expect(ge.listState(id), PspGe.stateStalled);
      expect(pixel(10, 20), 0);
      expect(ge.updateStall(cpu, id, 0), 0);
      expect(ge.listState(id), PspGe.stateDone);
      expect(pixel(10, 20), 0x0000ff);
    });

    test('a transformed triangle lands through the viewport offset', () {
      const listAt = 0x08800000;
      const verticesAt = 0x08801000;
      int farg(double value) => _floatBits(value) >> 8;
      // Identity in the packed three-per-column upload form: the
      // diagonal sits at stream positions 0, 4 and 8.
      List<int> packed(int numberOp, int dataOp, List<double> diag,
          List<double> column3) {
        final stream = <double>[
          diag[0], 0, 0, //
          0, diag[1], 0, //
          0, 0, diag[2], //
          ...column3,
        ];
        return [
          _cmd(numberOp, 0),
          for (final v in stream) _cmd(dataOp, farg(v)),
        ];
      }

      final words = <int>[
        _cmd(0x10, 0x080000), // BASE
        _cmd(0x9c, 0), // frame buffer pointer
        _cmd(0x9d, 512), // frame buffer width
        _cmd(0xd2, 3), // frame buffer format 8888
        _cmd(0x01, verticesAt & 0xffffff),
        _cmd(0x12, 0x1c | 0x180), // color 8888, float positions, 3D
        _cmd(0x42, farg(240)), // viewport scale x
        _cmd(0x43, farg(-136)), // viewport scale y flips
        _cmd(0x44, 0), // viewport scale z
        _cmd(0x45, farg(2048)), // viewport center x
        _cmd(0x46, farg(2048)), // viewport center y
        _cmd(0x47, 0), // viewport center z
        _cmd(0x4c, 1808 * 16), // offset x in 12.4 fixed point
        _cmd(0x4d, 1912 * 16), // offset y
        // Projection: a full 4x4 identity upload.
        _cmd(0x3e, 0),
        for (var i = 0; i < 16; i++)
          _cmd(0x3f, farg(i % 5 == 0 ? 1 : 0)),
        // View: identity. World: identity plus a +0.5 x translation in
        // the fourth column.
        ...packed(0x3c, 0x3d, [1, 1, 1], [0, 0, 0]),
        ...packed(0x3a, 0x3b, [1, 1, 1], [0.5, 0, 0]),
        _cmd(0x04, 0x30003), // three triangle vertices
        _cmd(0x0f, 0),
        _cmd(0x0c, 0),
      ];
      for (var i = 0; i < words.length; i++) {
        mem.write32(listAt + i * 4, words[i]);
      }
      void vertex(int at, double x, double y) {
        mem.write32(at, 0xff00ff00);
        mem.write32(at + 4, _floatBits(x));
        mem.write32(at + 8, _floatBits(y));
        mem.write32(at + 12, _floatBits(0));
      }

      vertex(verticesAt, -0.5, -0.5);
      vertex(verticesAt + 16, 0.5, -0.5);
      vertex(verticesAt + 32, 0, 0.5);
      final id = ge.enqueue(cpu, listAt, 0);
      expect(ge.listState(id), PspGe.stateDone);
      // The world translation moves the triangle to screen (240..480,
      // 68..204): x = ndc * 240 + 240, y = -136 * ndc + 136.
      expect(pixel(360, 190), 0x00ff00);
      expect(pixel(360, 80), 0x00ff00);
      expect(pixel(245, 100), 0);
      expect(pixel(300, 250), 0);
      expect(pixel(10, 10), 0);
    });

    test('a triangle is cut at the near plane', () {
      const listAt = 0x08800000;
      const verticesAt = 0x08801000;
      int farg(double value) => _floatBits(value) >> 8;
      // Identity in the packed three-per-column upload form: the
      // diagonal sits at stream positions 0, 4 and 8.
      List<int> packed(int numberOp, int dataOp, List<double> diag,
          List<double> column3) {
        final stream = <double>[
          diag[0], 0, 0, //
          0, diag[1], 0, //
          0, 0, diag[2], //
          ...column3,
        ];
        return [
          _cmd(numberOp, 0),
          for (final v in stream) _cmd(dataOp, farg(v)),
        ];
      }

      final words = <int>[
        _cmd(0x10, 0x080000), // BASE
        _cmd(0x9c, 0), // frame buffer pointer
        _cmd(0x9d, 512), // frame buffer width
        _cmd(0xd2, 3), // frame buffer format 8888
        _cmd(0x01, verticesAt & 0xffffff),
        _cmd(0x12, 0x1c | 0x180), // color 8888, float positions, 3D
        _cmd(0x42, farg(240)), // viewport scale x
        _cmd(0x43, farg(-136)), // viewport scale y flips
        _cmd(0x44, 0), // viewport scale z
        _cmd(0x45, farg(2048)), // viewport center x
        _cmd(0x46, farg(2048)), // viewport center y
        _cmd(0x47, 0), // viewport center z
        _cmd(0x4c, 1808 * 16), // offset x in 12.4 fixed point
        _cmd(0x4d, 1912 * 16), // offset y
        // Projection: a full 4x4 identity upload.
        _cmd(0x3e, 0),
        for (var i = 0; i < 16; i++)
          _cmd(0x3f, farg(i % 5 == 0 ? 1 : 0)),
        ...packed(0x3c, 0x3d, [1, 1, 1], [0, 0, 0]),
        ...packed(0x3a, 0x3b, [1, 1, 1], [0, 0, 0]),
        _cmd(0x04, 0x30003), // three triangle vertices
        _cmd(0x0f, 0),
        _cmd(0x0c, 0),
      ];
      for (var i = 0; i < words.length; i++) {
        mem.write32(listAt + i * 4, words[i]);
      }
      void vertex(int at, double x, double y, double z) {
        mem.write32(at, 0xff00ff00);
        mem.write32(at + 4, _floatBits(x));
        mem.write32(at + 8, _floatBits(y));
        mem.write32(at + 12, _floatBits(z));
      }

      // the top vertex lies in front of the near plane z = -w; the edges
      // toward it cross the plane a third of the way, at y = -1/6
      vertex(verticesAt, -0.5, -0.5, 0);
      vertex(verticesAt + 16, 0.5, -0.5, 0);
      vertex(verticesAt + 32, 0, 0.5, -3);
      final id = ge.enqueue(cpu, listAt, 0);
      expect(ge.listState(id), PspGe.stateDone);
      // y = -136 * ndc + 136: the kept part spans 159..204
      expect(pixel(240, 190), 0x00ff00);
      expect(pixel(240, 165), 0x00ff00);
      expect(pixel(240, 150), 0);
      expect(pixel(240, 95), 0);
    });

    test('a block transfer copies pixels inside video memory', () {
      const src = 0x10000, dst = 0x20000;
      for (var i = 0; i < 4; i++) {
        mem.write32(0x04000000 + src + i * 4, 0xa0 + i);
      }
      final list = _writeList(
          mem,
          [
            _cmd(0xb2, src), // transfer source
            _cmd(0xb3, 16), // source pitch
            _cmd(0xb4, dst), // transfer destination
            _cmd(0xb5, 16), // destination pitch
            _cmd(0xeb, 0), // source position
            _cmd(0xec, 0), // destination position
            _cmd(0xee, 3), // size 4x1
            _cmd(0xea, 1), // start, 32-bit pixels
          ],
          0);
      ge.enqueue(cpu, list, 0);
      for (var i = 0; i < 4; i++) {
        expect(mem.read32(0x04000000 + dst + i * 4), 0xa0 + i);
      }
    });
  });

  group('guest programs', () {
    test('a program draws through the system calls', () {
      final bytes = _buildGeProgram();
      final core = Psp()..setRom(bytes);
      var result = core.runFrame(286);
      var frames = 1;
      while (!result.stopped && frames < 60) {
        result = core.runFrame(286);
        frames++;
      }
      expect(result.stopped, isTrue);
      expect(core.mem.read32(0x08900208), greaterThan(0)); // the list id
      expect(core.mem.read32(0x08900200), 0); // DrawSync: done
      expect(core.mem.read32(0x08900204), 0); // ListSync: done
      final at = 0x04000000 + (25 * 512 + 25) * 4;
      expect(core.mem.read32(at), 0xff00ff00);
    });

    test('a program plays audio through the channels', () {
      final bytes = _buildAudioProgram();
      final core = Psp();
      final captured = <double>[];
      core.onAudio((AudioBuffer buffer) {
        captured.addAll(buffer.buffer.map((s) => s.toDouble()));
      });
      core.setRom(bytes);
      var result = core.runFrame(286);
      var frames = 1;
      while (!result.stopped && frames < 60) {
        result = core.runFrame(286);
        frames++;
      }
      expect(result.stopped, isTrue);
      expect(core.mem.read32(0x08900080), 0); // the reserved channel
      expect(core.mem.read32(0x08900100), 4); // rest after one block
      expect(core.mem.read32(0x08900104), 8); // rest after two blocks
      expect(core.mem.read32(0x08900108), 8); // the rest length call
      expect(core.mem.read32(0x0890010c), 0); // the release result
      expect(captured.length, greaterThanOrEqualTo(16));
      for (var i = 0; i < 16; i++) {
        expect(captured[i], closeTo(0.5, 0.01));
      }
    });

    test('a program re-locking its own lwmutex fails instead of hanging',
        () {
      final bytes = _buildLwMutexProgram();
      final core = Psp()..setRom(bytes);
      var result = core.runFrame(286);
      var frames = 1;
      while (!result.stopped && frames < 60) {
        result = core.runFrame(286);
        frames++;
      }
      expect(result.stopped, isTrue);
      expect(core.mem.read32(0x08900100), 0); // create
      expect(core.mem.read32(0x08900104), 0); // first lock
      expect(core.mem.read32(0x08900108), 0x800201b9); // re-lock fails
      expect(core.mem.read32(0x0890010c), 0); // unlock
      expect(core.mem.read32(0x08900110), 0); // the mutex still works
    });

    test('the system time counts microseconds', () {
      final bytes = _buildSystemTimeProgram();
      final core = Psp()..setRom(bytes);
      var result = core.runFrame(286);
      var frames = 1;
      while (!result.stopped && frames < 60) {
        result = core.runFrame(286);
        frames++;
      }
      expect(result.stopped, isTrue);
      int at(int offset) => core.mem.read32(0x08900000 + offset);
      final first = at(0) | at(4) << 32;
      final second = at(8) | at(12) << 32;
      // A 2 ms delay lies between the two GetSystemTime calls, and the
      // low and wide forms read the clock after them.
      expect(second - first, greaterThanOrEqualTo(2000));
      expect(at(16), greaterThanOrEqualTo(at(8)));
      expect(at(20) | at(24) << 32, greaterThanOrEqualTo(second));
    });
  });
}

const _nidEnQueue = 0xab49e76a;
const _nidDrawSync = 0xb287bd61;
const _nidListSync = 0x03444eb4;
const _nidExitGame = 0x05572a5f;
const _nidDelayThread = 0xceadeb47;
const _nidChReserve = 0x5ec81c55;
const _nidOutput = 0x136caf51;
const _nidGetRestLen = 0xb011b7ff;
const _nidChRelease = 0x6fc46853;
const _nidCreateLwMutex = 0x19cff145;
const _nidLockLwMutex = 0xbea46419;
const _nidUnlockLwMutex = 0x15b6446b;
const _nidGetSystemTime = 0xdb738f35;
const _nidGetSystemTimeLow = 0x369ed59d;
const _nidGetSystemTimeWide = 0x82bc5777;

/// Emits code that stores each of [words] at [base] in order.
void _storeWords(Asm a, int base, List<int> words) {
  a.li(Reg.t0, base);
  for (var i = 0; i < words.length; i++) {
    a.li(Reg.t1, words[i]);
    a.sw(Reg.t1, i * 4, Reg.t0);
  }
}

Uint8List _buildGeProgram() {
  const imports = [
    ('sceGe_user', [_nidEnQueue, _nidDrawSync, _nidListSync]),
    ('LoadExecForUser', [_nidExitGame]),
  ];
  List<int> assemble(Map<String, int> stubs) {
    int stub(String lib, int nid) => stubs['$lib/$nid'] ?? 0;
    final a = Asm(0x08800000);
    _storeWords(a, 0x08900000, [
      _cmd(0x10, 0x080000),
      _cmd(0x9c, 0),
      _cmd(0x9d, 512),
      _cmd(0xd2, 3),
      _cmd(0xd3, 0x301), // clear the color and the stencil
      _cmd(0x01, 0x08900040 & 0xffffff),
      _cmd(0x12, _spriteType),
      _cmd(0x04, 0x60002),
      _cmd(0x0f, 0),
      _cmd(0x0c, 0),
    ]);
    // Two clear-sprite vertices: (0, 0) and (100, 50), green.
    _storeWords(a, 0x08900040, [
      0,
      0,
      0xff00ff00,
      0,
      0,
      0,
      0,
      0,
      0xff00ff00,
      _floatBits(100),
      _floatBits(50),
      0,
    ]);
    a.li(Reg.a0, 0x08900000);
    a.li(Reg.a1, 0);
    a.jal(stub('sceGe_user', _nidEnQueue));
    a.nop();
    a.addiu(Reg.s0, Reg.v0, 0);
    a.li(Reg.a0, 0);
    a.jal(stub('sceGe_user', _nidDrawSync));
    a.nop();
    a.li(Reg.t0, 0x08900200);
    a.sw(Reg.v0, 0, Reg.t0);
    a.addiu(Reg.a0, Reg.s0, 0);
    a.li(Reg.a1, 0);
    a.jal(stub('sceGe_user', _nidListSync));
    a.nop();
    a.sw(Reg.v0, 4, Reg.t0);
    a.sw(Reg.s0, 8, Reg.t0);
    a.jal(stub('LoadExecForUser', _nidExitGame));
    a.nop();
    return a.finish();
  }

  final (_, probe) = buildTestElf(code: assemble(const {}), imports: imports);
  final (bytes, _) =
      buildTestElf(code: assemble(probe.stubOf), imports: imports);
  return bytes;
}

Uint8List _buildAudioProgram() {
  const imports = [
    ('sceAudio', [_nidChReserve, _nidOutput, _nidGetRestLen, _nidChRelease]),
    ('ThreadManForUser', [_nidDelayThread]),
    ('LoadExecForUser', [_nidExitGame]),
  ];
  List<int> assemble(Map<String, int> stubs) {
    int stub(String lib, int nid) => stubs['$lib/$nid'] ?? 0;
    final a = Asm(0x08800000);
    // Four stereo frames at half volume in the sample buffer.
    _storeWords(a, 0x08900000, [
      0x40004000,
      0x40004000,
      0x40004000,
      0x40004000,
    ]);
    a.li(Reg.a0, -1);
    a.li(Reg.a1, 4);
    a.li(Reg.a2, 0);
    a.jal(stub('sceAudio', _nidChReserve));
    a.nop();
    a.addiu(Reg.s0, Reg.v0, 0);
    a.li(Reg.t0, 0x08900080);
    a.sw(Reg.v0, 0, Reg.t0);
    for (final offset in [0x100, 0x104]) {
      a.addiu(Reg.a0, Reg.s0, 0);
      a.li(Reg.a1, 0x8000);
      a.li(Reg.a2, 0x08900000);
      a.jal(stub('sceAudio', _nidOutput));
      a.nop();
      a.li(Reg.t0, 0x08900000 + offset);
      a.sw(Reg.v0, 0, Reg.t0);
    }
    a.addiu(Reg.a0, Reg.s0, 0);
    a.jal(stub('sceAudio', _nidGetRestLen));
    a.nop();
    a.li(Reg.t0, 0x08900108);
    a.sw(Reg.v0, 0, Reg.t0);
    a.addiu(Reg.a0, Reg.s0, 0);
    a.jal(stub('sceAudio', _nidChRelease));
    a.nop();
    a.li(Reg.t0, 0x0890010c);
    a.sw(Reg.v0, 0, Reg.t0);
    // Let at least one refresh pass so the mix is flushed.
    a.li(Reg.a0, 20000);
    a.jal(stub('ThreadManForUser', _nidDelayThread));
    a.nop();
    a.jal(stub('LoadExecForUser', _nidExitGame));
    a.nop();
    return a.finish();
  }

  final (_, probe) = buildTestElf(code: assemble(const {}), imports: imports);
  final (bytes, _) =
      buildTestElf(code: assemble(probe.stubOf), imports: imports);
  return bytes;
}

Uint8List _buildLwMutexProgram() {
  const imports = [
    (
      'ThreadManForUser',
      [_nidCreateLwMutex, _nidLockLwMutex, _nidUnlockLwMutex]
    ),
    ('LoadExecForUser', [_nidExitGame]),
  ];
  List<int> assemble(Map<String, int> stubs) {
    int stub(String lib, int nid) => stubs['$lib/$nid'] ?? 0;
    final a = Asm(0x08800000);
    a.li(Reg.s0, 0x08900000); // the workarea
    a.li(Reg.s1, 0x08900100); // the results
    a.addiu(Reg.a0, Reg.s0, 0);
    a.li(Reg.a1, 0);
    a.li(Reg.a2, 0); // no recursive attribute
    a.li(Reg.a3, 0);
    a.jal(stub('ThreadManForUser', _nidCreateLwMutex));
    a.nop();
    a.sw(Reg.v0, 0, Reg.s1);
    for (final offset in [4, 8]) {
      a.addiu(Reg.a0, Reg.s0, 0);
      a.li(Reg.a1, 1);
      a.li(Reg.a2, 0);
      a.jal(stub('ThreadManForUser', _nidLockLwMutex));
      a.nop();
      a.sw(Reg.v0, offset, Reg.s1);
    }
    a.addiu(Reg.a0, Reg.s0, 0);
    a.li(Reg.a1, 1);
    a.jal(stub('ThreadManForUser', _nidUnlockLwMutex));
    a.nop();
    a.sw(Reg.v0, 12, Reg.s1);
    a.addiu(Reg.a0, Reg.s0, 0);
    a.li(Reg.a1, 1);
    a.li(Reg.a2, 0);
    a.jal(stub('ThreadManForUser', _nidLockLwMutex));
    a.nop();
    a.sw(Reg.v0, 16, Reg.s1);
    a.jal(stub('LoadExecForUser', _nidExitGame));
    a.nop();
    return a.finish();
  }

  final (_, probe) = buildTestElf(code: assemble(const {}), imports: imports);
  final (bytes, _) =
      buildTestElf(code: assemble(probe.stubOf), imports: imports);
  return bytes;
}

Uint8List _buildSystemTimeProgram() {
  const imports = [
    (
      'ThreadManForUser',
      [
        _nidGetSystemTime,
        _nidGetSystemTimeLow,
        _nidGetSystemTimeWide,
        _nidDelayThread,
      ]
    ),
    ('LoadExecForUser', [_nidExitGame]),
  ];
  List<int> assemble(Map<String, int> stubs) {
    int stub(String lib, int nid) => stubs['$lib/$nid'] ?? 0;
    final a = Asm(0x08800000);
    a.li(Reg.s0, 0x08900000); // the results
    a.addiu(Reg.a0, Reg.s0, 0);
    a.jal(stub('ThreadManForUser', _nidGetSystemTime));
    a.nop();
    a.li(Reg.a0, 2000);
    a.jal(stub('ThreadManForUser', _nidDelayThread));
    a.nop();
    a.addiu(Reg.a0, Reg.s0, 8);
    a.jal(stub('ThreadManForUser', _nidGetSystemTime));
    a.nop();
    a.jal(stub('ThreadManForUser', _nidGetSystemTimeLow));
    a.nop();
    a.sw(Reg.v0, 16, Reg.s0);
    a.jal(stub('ThreadManForUser', _nidGetSystemTimeWide));
    a.nop();
    a.sw(Reg.v0, 20, Reg.s0);
    a.sw(Reg.v1, 24, Reg.s0);
    a.jal(stub('LoadExecForUser', _nidExitGame));
    a.nop();
    return a.finish();
  }

  final (_, probe) = buildTestElf(code: assemble(const {}), imports: imports);
  final (bytes, _) =
      buildTestElf(code: assemble(probe.stubOf), imports: imports);
  return bytes;
}

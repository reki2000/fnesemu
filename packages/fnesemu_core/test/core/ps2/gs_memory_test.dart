import 'package:fnesemu_core/src/core/ps2/gs/gs_memory.dart';
import 'package:test/test.dart';

// page size in pixels (width, height) and units per page
const _pages = {
  GsPsm.ct32: (64, 32, 2048),
  GsPsm.ct24: (64, 32, 2048),
  GsPsm.z32: (64, 32, 2048),
  GsPsm.t8h: (64, 32, 2048),
  GsPsm.t4hl: (64, 32, 2048),
  GsPsm.ct16: (64, 64, 4096),
  GsPsm.ct16s: (64, 64, 4096),
  GsPsm.z16: (64, 64, 4096),
  GsPsm.z16s: (64, 64, 4096),
  GsPsm.t8: (128, 64, 8192),
  GsPsm.t4: (128, 128, 16384),
};

void main() {
  for (final entry in _pages.entries) {
    test('psm 0x${entry.key.toRadixString(16)}: a page maps one to one', () {
      final (w, h, units) = entry.value;
      final seen = <int>{};
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final i = GsMemory.unitIndex(entry.key, 0, 2, x, y);
          expect(i, inInclusiveRange(0, units - 1), reason: '($x,$y)');
          expect(seen.add(i), isTrue, reason: '($x,$y) collides');
        }
      }
      expect(seen.length, units);
    });
  }

  test('pages follow the buffer width', () {
    // PSMCT32: the second page of a row is 2048 words after the first
    expect(GsMemory.unitIndex(GsPsm.ct32, 0, 2, 64, 0), 2048);
    expect(GsMemory.unitIndex(GsPsm.ct32, 0, 2, 0, 32), 4096);
    expect(GsMemory.unitIndex(GsPsm.ct32, 4, 1, 0, 0), 256);
  });

  test('PSMCT32 block and column order', () {
    // block 1 is the second block of the first block row
    expect(GsMemory.unitIndex(GsPsm.ct32, 0, 1, 8, 0), 64);
    expect(GsMemory.unitIndex(GsPsm.ct32, 0, 1, 16, 0), 4 * 64);
    expect(GsMemory.unitIndex(GsPsm.ct32, 0, 1, 0, 8), 2 * 64);
    // inside a block: 8x2 columns of 16 words
    expect(GsMemory.unitIndex(GsPsm.ct32, 0, 1, 1, 0), 1);
    expect(GsMemory.unitIndex(GsPsm.ct32, 0, 1, 0, 1), 2);
    expect(GsMemory.unitIndex(GsPsm.ct32, 0, 1, 0, 2), 16);
  });

  test('Z formats use the opposite block quadrant', () {
    expect(GsMemory.unitIndex(GsPsm.z32, 0, 1, 0, 0), 24 * 64);
    expect(GsMemory.unitIndex(GsPsm.z16, 0, 1, 0, 0), 24 * 64 * 2);
  });

  test('pixels round trip in every format', () {
    final mem = GsMemory();
    for (final psm in _pages.keys) {
      final max = (1 << GsPsm.pixelBits(psm)) - 1;
      for (var i = 0; i < 40; i++) {
        final x = (i * 37) % 120, y = (i * 53) % 90;
        final v = (i * 0x9e3779b1 + 5) & max;
        mem.write(psm, 3, 2, x, y, v);
        expect(mem.read(psm, 3, 2, x, y), v, reason: 'psm $psm ($x,$y)');
      }
    }
  });

  test('the 8H and 4H formats share the upper bits of a PSMCT32 word', () {
    final mem = GsMemory();
    mem.write(GsPsm.ct32, 0, 1, 5, 3, 0x11223344);
    mem.write(GsPsm.t8h, 0, 1, 5, 3, 0xab);
    expect(mem.read(GsPsm.ct32, 0, 1, 5, 3), 0xab223344);
    mem.write(GsPsm.t4hh, 0, 1, 5, 3, 0x7);
    mem.write(GsPsm.t4hl, 0, 1, 5, 3, 0x9);
    expect(mem.read(GsPsm.ct32, 0, 1, 5, 3), 0x79223344);
    expect(mem.read(GsPsm.t4hl, 0, 1, 5, 3), 9);
    mem.write(GsPsm.ct24, 0, 1, 5, 3, 0xffffff);
    expect(mem.read(GsPsm.ct32, 0, 1, 5, 3), 0x79ffffff);
  });

  test('the page tables give the same index as the layout', () {
    final mem = GsMemory();
    for (final psm in [..._pages.keys, GsPsm.ct24, GsPsm.z24, GsPsm.t4hh]) {
      for (final (bp, bw) in [(0, 1), (37, 3), (512, 10)]) {
        for (var y = 0; y < 300; y += 7) {
          for (var x = 0; x < 700; x += 5) {
            expect(mem.index(psm, bp, bw, x, y),
                GsMemory.unitIndex(psm, bp, bw, x, y),
                reason: 'psm $psm bp $bp bw $bw ($x,$y)');
          }
        }
      }
    }
  });
}

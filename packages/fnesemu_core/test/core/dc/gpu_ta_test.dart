import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/dc.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/util/uint8list.dart';
import 'package:test/test.dart';

void main() {
  const reg = 0xa05f8000, object = 0x100000, parameter = 0x200000;
  const copy = 0x20800000; // Source one, destination zero, no fog.
  late DcBus bus;
  int bits(double value) {
    final data = ByteData(4)..setFloat32(0, value, Endian.little);
    return data.getUint32(0, Endian.little);
  }

  void packet(List<int> words, {bool sq = false}) {
    final bytes = Uint8List(32);
    for (final (i, word) in words.indexed) {
      bytes.setUint32LE(i * 4, word);
    }
    if (sq) {
      bus.write32(0xff000038, 0x10);
      for (var i = 0; i < 32; i += 4) {
        bus.write32(0xe0000000 + i, bytes.getUint32LE(i));
      }
      bus.transferStoreQueue(0xe0000000);
    } else {
      bus.gpu.writePolygon(bytes);
    }
  }

  void initialize(
      {int clip = 0,
      int allocation = 1,
      int limit = object + 0xffe0,
      int next = object + 0x1000}) {
    bus.write32(reg + 8, 0);
    for (final entry in [
      (0x124, object),
      (0x128, parameter),
      (0x12c, limit),
      (0x130, parameter + 0xfffc),
      (0x13c, clip),
      (0x140, allocation),
      (0x164, next)
    ]) {
      bus.write32(reg + entry.$1, entry.$2);
    }
    bus.write32(reg + 0x144, 0x80000000);
  }

  void header({int pcw = 0x80800000, int isp = 0xe0000000, int tsp = copy}) =>
      packet([pcw, isp, tsp, 0]);
  void vertex(double x, double y,
          {double z = 1, int color = 0xffff0000, bool end = false}) =>
      packet([
        end ? 0xf0000000 : 0xe0000000,
        bits(x),
        bits(y),
        bits(z),
        color,
        0,
        0,
        0
      ]);
  void triangle({int color = 0xffff0000, double z = 1}) {
    vertex(0, 0, color: color, z: z);
    vertex(32, 0, color: color, z: z);
    vertex(0, 32, color: color, z: z, end: true);
  }

  int word(int offset) => bus.gpu.vram.getUint32LE(offset);
  void put(int offset, List<int> words) {
    for (final (i, value) in words.indexed) {
      bus.gpu.vram.setUint32LE(offset + i * 4, value);
    }
  }

  void prepareRender({int color = 0xff000000, int mode = 6}) {
    // A self-authored flat background plane, selected through the normal CORE tag.
    put(parameter + 0x8000,
        [0xe0000000, copy, 0, 0, 0, 0, color, 0, 0, 0, color, 0, 0, 0, color]);
    for (final entry in [
      (0x20, parameter),
      (0x2c, 0x9000),
      (0x48, mode),
      (0x4c, 16),
      (0x60, 0x400000),
      (0x68, 31 << 16),
      (0x6c, 31 << 16),
      (0x8c, (1 << 24) | ((0x8000 >> 2) << 3)),
      (0x88, 0)
    ]) {
      bus.write32(reg + entry.$1, entry.$2);
    }
    put(0x9000, [0x80000000, object, 0x80000000, 0x80000000, 0x80000000]);
  }

  setUp(() => bus = DcBus());

  test('TA register masks, initialization and read-only current pointers', () {
    initialize();
    expect(bus.read32(reg + 0x138), parameter);
    expect(bus.read32(reg + 0x134), object + 0x1000);
    expect(bus.read32(reg + 0x144), 0);
    bus.write32(reg + 0x138, 0);
    expect(bus.read32(reg + 0x138), parameter);
    bus.write32(reg + 0x124, 0xffffffff);
    expect(bus.read32(reg + 0x124), 0xffffe0);
    expect(() => bus.read16(reg + 0x124), throwsA(isA<DcUnsupported>()));
  });

  test('TA stores a documented strip pointer, packed parameters and end marker',
      () {
    initialize();
    header();
    triangle();
    packet([0]);
    expect(word(object), (1 << 30) | (1 << 21));
    expect(word(object + 4), 0xf0000000);
    expect(word(parameter), 0xe0000000);
    expect(word(parameter + 4), copy);
    expect(word(parameter + 12), bits(0));
    expect(word(parameter + 24), 0xffff0000);
    expect(bus.read32(reg + 0x138), parameter + 60);
    expect(bus.systemBus.normalStatus & 0x80, 0x80);
  });

  test('store queues and channel DMA reach the same write-only polygon FIFO',
      () {
    initialize();
    packet([0x80800000, 0xe0000000, copy], sq: true);
    triangle();
    packet([0], sq: true);
    expect(word(object + 4), 0xf0000000);
    expect(() => bus.read32(0xb0000000), throwsA(isA<DcUnsupported>()));
    expect(() => bus.write32(0xb0000000, 0), throwsA(isA<DcUnsupported>()));
    initialize();
    final bytes = Uint8List(32)
      ..setUint32LE(0, 0x80800000)
      ..setUint32LE(4, 0xe0000000)
      ..setUint32LE(8, copy);
    bus.ram.setAll(0x10000, bytes);
    for (final entry in [
      (0, 0x0c010000),
      (4, 0x10000000),
      (8, 1),
      (12, 0x1445),
      (0x40, 1)
    ]) {
      bus.write32(0xffa00000 + entry.$1, entry.$2);
    }
    bus.tickMasterClocks(2);
    triangle();
    packet([0]);
    expect(word(object), (1 << 30) | (1 << 21));
  });

  test('TA converts floating color and intensity with clamping', () {
    initialize();
    header(pcw: 0x80800010);
    for (var i = 0; i < 3; i++) {
      packet([
        i == 2 ? 0xf0000000 : 0xe0000000,
        bits(i == 1 ? 20 : 0),
        bits(i == 2 ? 20 : 0),
        bits(1),
        bits(1),
        bits(0.5),
        bits(-1),
        bits(2)
      ]);
    }
    expect(word(parameter + 24), 0xff7f00ff);
    header(pcw: 0x80800020);
    // Replace the face with an independently known red half-intensity shade.
    packet(
        [0x80800020, 0xe0000000, copy, 0, bits(1), bits(1), bits(0), bits(0)]);
    for (var i = 0; i < 3; i++) {
      packet([
        i == 2 ? 0xf0000000 : 0xe0000000,
        bits(i == 1 ? 20 : 0),
        bits(i == 2 ? 20 : 0),
        bits(1),
        0,
        0,
        bits(0.5)
      ]);
    }
    expect(word(parameter + 60 + 24), 0xff7f0000);
  });

  test('user clipping and fully offscreen primitives do not consume parameters',
      () {
    initialize(clip: 1);
    packet([0x20000000, 0, 0, 0, 1, 0, 1, 0]);
    header(pcw: 0x80820000);
    vertex(0, 0);
    vertex(31, 0);
    vertex(0, 31, end: true);
    expect(bus.read32(reg + 0x138), parameter);
    vertex(32, 0);
    vertex(63, 0);
    vertex(32, 31, end: true);
    packet([0]);
    expect(word(object), 0xf0000000);
    expect(word(object + 32) & 0x40000000, 0x40000000);
    expect(bus.read32(reg + 0x138), parameter + 60);
  });

  test('TA partitions infinite strips and preserves winding between partitions',
      () {
    initialize();
    header();
    vertex(0, 0);
    vertex(32, 0);
    vertex(0, 32);
    vertex(32, 32, end: true);
    packet([0]);
    expect(bus.read32(reg + 0x138), parameter + 120);
    expect(word(parameter + 60 + 12),
        bits(0)); // C precedes B on the odd triangle.
    expect(word(parameter + 60 + 16), bits(32));
    expect(word(parameter + 60 + 28), bits(32));
  });

  test('multi-triangle partitions produce per-tile masks and compact vertices',
      () {
    initialize(clip: 1);
    header(pcw: 0x80840000);
    vertex(0, 0);
    vertex(0, 31);
    vertex(32, 0);
    vertex(63, 31, end: true);
    packet([0]);
    expect(bus.read32(reg + 0x138), parameter + 76);
    expect(word(object) & 0x7e000000, 0x60000000);
    expect(word(object + 32) & 0x7e000000, 0x60000000);
  });

  test('OPB overflow links additional blocks and preserves the end marker', () {
    initialize();
    header();
    for (var i = 0; i < 8; i++) {
      triangle();
    }
    packet([0]);
    expect(word(object + 28), 0xe0000000 | (object + 0x1000));
    expect(word(object + 0x1004), 0xf0000000);
    expect(bus.read32(reg + 0x134), object + 0x1020);
  });

  test('object and parameter limits report distinct errors without completion',
      () {
    initialize();
    bus.write32(reg + 0x130, parameter + 4);
    header();
    expect(triangle, throwsA(isA<DcUnsupported>()));
    expect(bus.systemBus.errorStatus & 4, 4);
    expect(bus.systemBus.normalStatus & 0x80, 0);
    bus = DcBus();
    initialize(limit: object, next: object + 32);
    header();
    for (var i = 0; i < 7; i++) {
      triangle();
    }
    expect(triangle, throwsA(isA<DcUnsupported>()));
    expect(bus.systemBus.errorStatus & 8, 8);
  });

  test(
      'list continuation retains parameter/allocation cursors and changes initial OPBs',
      () {
    initialize();
    header();
    triangle();
    packet([0]);
    bus.write32(reg + 0x124, object + 32);
    bus.write32(reg + 0x160, 0x80000000);
    header();
    triangle();
    packet([0]);
    expect(word(object + 32) & 0x1fffff, 60 >> 2);
    expect(bus.read32(reg + 0x138), parameter + 120);
    expect(bus.read32(reg + 0x134), object + 0x1000);
  });

  test('render consumes VRAM lists and commits pixels before completion IRQ',
      () {
    initialize();
    header();
    triangle();
    packet([0]);
    prepareRender();
    bus.write32(reg + 0x14, 1);
    expect(bus.gpu.render.busy, isTrue);
    expect(word(0x400000), 0);
    bus.tickMasterClocks(1);
    expect(word(0x400000), 0);
    bus.tickMasterClocks(1);
    expect(word(0x400000 + (1 * 32 + 1) * 4), 0xffff0000);
    expect(word(0x400000 + (31 * 32 + 31) * 4), 0xff000000);
    expect(bus.systemBus.normalStatus & 7, 7);
    expect(bus.gpu.render.busy, isFalse);
    bus.write32(reg + 0xe8, 0);
    bus.write32(reg + 0x44, 13);
    bus.write32(reg + 0x50, 0x400000);
    bus.write32(reg + 0x5c, 31 | (31 << 10) | (1 << 20));
    expect(bus.gpu.image().buffer[33], 0xff0000ff);
  });

  test(
      'CORE re-reads guest modified vertex colors rather than a host primitive list',
      () {
    initialize();
    header();
    triangle();
    packet([0]);
    prepareRender();
    bus.write32(0xa5200000 + 56, 0xff00ff00);
    bus.write32(reg + 0x14, 0);
    bus.tickMasterClocks(2);
    expect(word(0x400000 + 132), 0xff00ff00);
  });

  test('Gouraud color is interpolated while flat color uses the third vertex',
      () {
    initialize();
    header(pcw: 0x80800002);
    vertex(0, 0, color: 0xffff0000);
    vertex(32, 0, color: 0xff00ff00);
    vertex(0, 32, color: 0xff0000ff, end: true);
    packet([0]);
    prepareRender();
    bus.write32(reg + 0x14, 1);
    bus.tickMasterClocks(2);
    expect(word(0x400000), 0xfff70404);
  });

  test('depth comparisons and Z write disable determine opaque visibility', () {
    for (final entry in [(0x80000000, 0xff0000ff), (0x84000000, 0xff00ff00)]) {
      bus = DcBus();
      initialize();
      header(isp: entry.$1);
      triangle(z: 2);
      header(isp: 0x80000000);
      triangle(z: 1, color: 0xff0000ff);
      // A later closer triangle passes only if the first write was inhibited.
      header(isp: 0x80000000);
      triangle(z: 1.5, color: 0xff00ff00);
      packet([0]);
      prepareRender();
      bus.write32(reg + 0x14, 1);
      bus.tickMasterClocks(2);
      expect(
          word(0x400000 + 132), entry.$1 == 0x80000000 ? 0xffff0000 : entry.$2);
    }
  });

  test('all seven framebuffer pack modes use documented component bits', () {
    const color = 0x9aabcdef;
    final expected = [
      0x573d,
      0xae7d,
      0x9ace,
      0xd73d,
      0xabcdef,
      0x00abcdef,
      color
    ];
    for (var mode = 0; mode < 7; mode++) {
      bus = DcBus();
      initialize();
      header(tsp: copy | 0x100000);
      triangle(color: color);
      packet([0]);
      prepareRender(mode: mode);
      bus.write32(reg + 0x14, 1);
      bus.tickMasterClocks(2);
      final bytes = mode < 4
          ? 2
          : mode == 4
              ? 3
              : 4;
      final value = bytes == 2
          ? bus.gpu.vram.getUint16LE(0x400000)
          : word(0x400000) & (mode == 4 ? 0xffffff : 0xffffffff);
      expect(value, expected[mode], reason: 'mode $mode');
    }
  });

  test('descending OPB allocation follows the HOLLY2 mode bit', () {
    initialize(allocation: 0x100001, limit: object, next: object + 0x1000);
    header();
    for (var i = 0; i < 15; i++) {
      triangle();
    }
    packet([0]);
    expect(word(object + 28), 0xe0000000 | (object + 0x1000));
    expect(word(object + 0x101c), 0xe0000000 | (object + 0xfe0));
    expect(word(object + 0xfe4), 0xf0000000);
    expect(bus.read32(reg + 0x134), object + 0xfc0);
  });

  test('illegal sequences raise the parameter error without a false list end',
      () {
    initialize();
    expect(() => packet([0]), throwsA(isA<DcUnsupported>()));
    expect(bus.systemBus.errorStatus & 16, 16);
    header();
    triangle();
    packet([0]);
    bus.write32(0xa05f6900, 0x80);
    expect(header, throwsA(isA<DcUnsupported>()));
    expect(bus.systemBus.normalStatus & 0x80, 0);
  });

  test(
      'object-list-set reuses existing VRAM data without generating ISP parameters',
      () {
    initialize();
    header();
    triangle();
    packet([0]);
    final pointer = word(object);
    initialize();
    packet([0x40000000, pointer, 0, 0, 0, 0, 0, 0]);
    packet([0]);
    expect(bus.read32(reg + 0x138), parameter);
    prepareRender();
    bus.write32(reg + 0x14, 1);
    bus.tickMasterClocks(2);
    expect(word(0x400000 + 132), 0xffff0000);
  });

  test('partitioned strip winding survives negative-face culling', () {
    initialize();
    header(isp: 0xf0000000);
    vertex(0, 0);
    vertex(32, 0);
    vertex(0, 32);
    vertex(32, 32, end: true, color: 0xff0000ff);
    packet([0]);
    prepareRender();
    bus.write32(reg + 0x14, 1);
    bus.tickMasterClocks(2);
    expect(word(0x400000 + 132), 0xffff0000);
    expect(word(0x400000 + (30 * 32 + 30) * 4), 0xff0000ff);
  });

  test('pre-sorted translucent lists blend with independently checked factors',
      () {
    initialize(allocation: 0x101);
    header();
    triangle();
    packet([0]);
    header(pcw: 0x82800000, tsp: 0x94900000);
    triangle(color: 0x800000ff);
    packet([0]);
    prepareRender();
    put(0x900c, [object + 32]);
    bus.write32(reg + 0x98, 1);
    bus.write32(reg + 0x14, 1);
    bus.tickMasterClocks(2);
    expect(word(0x400000 + 132), 0xbf7f0080);
    expect(bus.systemBus.normalStatus & 0x280, 0x280);
  });

  test('type-2 region headers select pre-sort mode and five list pointers', () {
    initialize(allocation: 0x100);
    header(pcw: 0x82800000);
    triangle(color: 0xff00ff00);
    packet([0]);
    prepareRender();
    bus.write32(reg + 0x7c, 0x200000);
    put(0x9000,
        [0xa0000000, 0x80000000, 0x80000000, object, 0x80000000, 0x80000000]);
    bus.write32(reg + 0x14, 1);
    bus.tickMasterClocks(2);
    expect(word(0x400000 + 132), 0xff00ff00);
  });

  test(
      'region deadlines commit tiles in order and interrupt only after the last',
      () {
    initialize(clip: 1);
    header();
    vertex(0, 0);
    vertex(64, 0);
    vertex(0, 32, end: true);
    packet([0]);
    prepareRender();
    bus.write32(reg + 0x4c, 32);
    bus.write32(reg + 0x68, 63 << 16);
    put(0x9000, [
      0,
      object,
      0x80000000,
      0x80000000,
      0x80000000,
      0x80000004,
      object + 32,
      0x80000000,
      0x80000000,
      0x80000000
    ]);
    bus.write32(reg + 0x14, 1);
    bus.tickMasterClocks(2);
    expect(bus.systemBus.normalStatus & 7, 0);
    expect(word(0x400000 + 32 * 4), 0);
    bus.tickMasterClocks(2);
    expect(word(0x400000 + 32 * 4), 0xffff0000);
    expect(bus.systemBus.normalStatus & 7, 7);
  });

  test(
      'self-authored SH4 ROM configures TA, sends store queues and renders an image',
      () {
    final code = <int>[];
    void load(int register, int value) {
      if (code.length.isOdd) code.add(9);
      // Local literal island: MOV.L @(1,PC),Rn; BRA next; NOP; padding; literal.
      code.addAll([
        0xd001 | (register << 8),
        0xa003,
        9,
        9,
        value & 0xffff,
        (value >> 16) & 0xffff
      ]);
    }

    void write(int address, int value) {
      load(0, address);
      load(3, value);
      code.add(0x2032);
    }

    for (final entry in [
      (8, 0),
      (0x124, object),
      (0x128, parameter),
      (0x12c, object + 0xffe0),
      (0x130, parameter + 0xfffc),
      (0x13c, 0),
      (0x140, 1),
      (0x164, object + 0x1000),
      (0x144, 0x80000000)
    ]) {
      write(reg + entry.$1, entry.$2);
    }
    write(0xff000038, 0x10);
    final packets = <List<int>>[
      [0x80800000, 0xe0000000, copy, 0, 0, 0, 0, 0],
      [0xe0000000, bits(0), bits(0), bits(1), 0xffff0000, 0, 0, 0],
      [0xe0000000, bits(32), bits(0), bits(1), 0xffff0000, 0, 0, 0],
      [0xf0000000, bits(0), bits(32), bits(1), 0xffff0000, 0, 0, 0],
      List.filled(8, 0),
    ];
    load(4, 0xe0000000);
    for (final packet in packets) {
      code.add(0x6043); // MOV R4,R0.
      for (final word in packet) {
        load(3, word);
        code.addAll([0x2032, 0x7004]);
      }
      code.add(0x0483); // PREF @R4 sends the completed store queue.
    }
    final background = [
      0xe0000000,
      copy,
      0,
      0,
      0,
      0,
      0xff000000,
      0,
      0,
      0,
      0xff000000,
      0,
      0,
      0,
      0xff000000
    ];
    for (final (i, word) in background.indexed) {
      write(0xa5008000 + parameter + 4 * i, word);
    }
    final region = [0x80000000, object, 0x80000000, 0x80000000, 0x80000000];
    for (final (i, word) in region.indexed) {
      write(0xa5009000 + 4 * i, word);
    }
    for (final entry in [
      (0x20, parameter),
      (0x2c, 0x9000),
      (0x48, 6),
      (0x4c, 16),
      (0x60, 0x400000),
      (0x68, 31 << 16),
      (0x6c, 31 << 16),
      (0x8c, (1 << 24) | ((0x8000 >> 2) << 3)),
      (0x88, 0),
      (0xe8, 0),
      (0x44, 13),
      (0x50, 0x400000),
      (0x5c, 31 | (31 << 10) | (1 << 20)),
      (0x14, 1)
    ]) {
      write(reg + entry.$1, entry.$2);
    }
    write(0xac030000, 1);
    code.addAll([0xaffe, 9]);
    final rom = Uint8List(code.length * 2);
    for (final (i, opcode) in code.indexed) {
      rom.setUint16LE(i * 2, opcode);
    }
    final core = Dc()..setRom(rom);
    var steps = 0;
    while (core.bus.ram.getUint32LE(0x30000) == 0 && steps++ < 3000) {
      expect(core.exec(false).stopped, isFalse, reason: core.stopReason);
    }
    expect(core.bus.ram.getUint32LE(0x30000), 1);
    expect(core.bus.systemBus.normalStatus & 0x87, 0x87);
    final image = core.bus.gpu.image();
    expect((image.width, image.height), (32, 32));
    expect(image.buffer[33], 0xff0000ff);
    expect(image.buffer.last, 0xff000000);
  });

  test(
      'framebuffer writes through the 64-bit aperture interleave physical banks',
      () {
    initialize();
    header();
    triangle();
    packet([0]);
    prepareRender();
    bus.write32(reg + 0x60, 0x1600000);
    bus.write32(reg + 0x14, 1);
    bus.tickMasterClocks(2);
    expect(bus.read32(0xa4600000), 0xffff0000);
    expect(bus.read32(0xa4600004), 0xffff0000);
    expect(word(0x300000), 0xffff0000);
    expect(word(0x700000), 0xffff0000);
    expect(word(0x600000), 0);
  });

  test('multipass regions retain the tile until the final accumulator flush',
      () {
    initialize();
    header();
    triangle();
    packet([0]);
    prepareRender();
    put(0x9000, [
      0x10000000,
      object,
      0x80000000,
      0x80000000,
      0x80000000,
      0xc0000000,
      0x80000000,
      0x80000000,
      0x80000000,
      0x80000000
    ]);
    bus.write32(reg + 0x14, 1);
    bus.tickMasterClocks(2);
    expect(word(0x400000 + 132), 0);
    expect(bus.systemBus.normalStatus & 7, 0);
    bus.tickMasterClocks(2);
    expect(word(0x400000 + 132), 0xffff0000);
    expect(bus.systemBus.normalStatus & 7, 7);
  });
}

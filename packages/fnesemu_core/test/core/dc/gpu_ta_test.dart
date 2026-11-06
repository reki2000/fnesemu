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
        0x12345678,
        0,
        color,
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
    expect(bus.read16(reg + 0x124), 0xffe0);
    expect(() => bus.read16(reg + 0x125), throwsA(isA<DcUnsupported>()));
  });

  test('TA stores a documented strip pointer, packed parameters and end marker',
      () {
    initialize();
    header();
    triangle(color: 0x80402010);
    packet([0]);
    expect(word(object), (1 << 30) | (1 << 21));
    expect(word(object + 4), 0xf0000000);
    expect(word(parameter), 0xe0000000);
    expect(word(parameter + 4), copy);
    expect(word(parameter + 12), bits(0));
    expect(word(parameter + 24), 0x80402010);
    expect(bus.read32(reg + 0x138), parameter + 60);
    expect(bus.systemBus.normalStatus & 0x80, 0x80);
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
      [0xe0000000, bits(0), bits(0), bits(1), 0, 0, 0xffff0000, 0],
      [0xe0000000, bits(32), bits(0), bits(1), 0, 0, 0xffff0000, 0],
      [0xf0000000, bits(0), bits(32), bits(1), 0, 0, 0xffff0000, 0],
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
    addTearDown(core.dispose);
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


}

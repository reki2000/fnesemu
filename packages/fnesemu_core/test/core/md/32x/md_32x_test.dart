import 'dart:typed_data';

import 'package:fnesemu_core/core_factory.dart';
import 'package:fnesemu_core/src/components/sh2/jit/jit.dart';
import 'package:fnesemu_core/src/core/md/32x/md_32x.dart';
import 'package:fnesemu_core/src/core/md/32x/video.dart';
import 'package:fnesemu_core/src/core/md/md.dart';
import 'package:test/test.dart';

Uint8List boot(int length, int instruction) {
  final bytes = Uint8List(length);
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, 0x100);
  data.setUint32(4, 0x0603ff00);
  data.setUint16(0x100, instruction);
  data.setUint16(0x102, 0xaffe);
  data.setUint16(0x104, 9);
  return bytes;
}

Md32x adapter() {
  final machine = Md32x();
  addTearDown(machine.dispose);
  machine.setBootRoms(
      main: Uint8List(256),
      master: boot(2048, 0xe12a),
      slave: boot(1024, 0xe207));
  return machine;
}

Uint8List cartridge() {
  final bytes = Uint8List(0x400);
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, 0xff8000);
  data.setUint32(4, 0x880300);
  bytes.setAll(0x100, '32X'.codeUnits);
  bytes.setAll(0x1f0, 'JUE'.codeUnits);
  data.setUint16(0x300, 0x60fe);
  return bytes;
}

void main() {
  final probe = Sh2Jit.create();
  final native = probe != null;
  probe?.dispose();
  test('CPU profiling excludes native execution and preserves CPU state', () {
    final expected = adapter(), actual = adapter();
    for (final machine in [expected, actual]) {
      final bytes = ByteData.sublistView(machine.ram);
      bytes.setUint16(0x200, 0x7101);
      bytes.setUint16(0x202, 0xaffd);
      bytes.setUint16(0x204, 9);
      machine.cpus[0].pc = 0x06000200;
    }
    final cpu = actual.cpus[0];
    final stats = cpu.jit!.diagnostics.enableExecutionStats();
    expect(cpu.run(400), isTrue);
    expect(expected.cpus[0].run(400), isTrue);
    expect(cpu.dump(), expected.cpus[0].dump());
    expect(cpu.clocks, expected.cpus[0].clocks);
    expect(actual.ram, expected.ram);
    expect(cpu.jit!.compiledClocks, greaterThan(0));
    expect(stats.cpuClocks + cpu.jit!.compiledClocks, cpu.clocks);
    expect(stats.cpuDispatches, greaterThan(0));
    cpu.jit!.diagnostics.disableExecutionStats();
    expect(cpu.executionStats, isNull);
  }, skip: !native);
  test('sleeping CPU clocks remain separate when an interrupt wakes it', () {
    final machine = adapter();
    final cpu = machine.cpus[0];
    final bytes = ByteData.sublistView(machine.ram);
    bytes.setUint16(0x200, 0x001b);
    bytes.setUint32(0x1100, 0x06000202);
    cpu.pc = 0x06000200;
    cpu.vbr = 0x06001000;
    cpu.sr = 0;
    final stats = cpu.jit!.diagnostics.enableExecutionStats();
    expect(cpu.exec(), isTrue);
    expect(stats.cpuDispatches, 1);
    expect(cpu.exec(), isTrue);
    expect(stats.idleClocks, 1);
    expect(stats.cpuDispatches, 1);
    cpu.setInterrupt(2, 64);
    expect(cpu.exec(), isTrue);
    expect(stats.cpuDispatches, 2);
    expect(stats.idleClocks, 1);
    expect(stats.cpuClocks + stats.idleClocks, cpu.clocks);
    expect(cpu.pc, 0x06000202);
    expect((stats.report()['memory'] as List).map((e) => e['kind']),
        containsAll(['fetch', 'read', 'write']));
  }, skip: !native);
  test('unaligned SH-2 memory replays the original bus access', () {
    final expected = Md32x(jit: false),
        actual = Md32x(jit: true, sliceClocks: 1);
    addTearDown(expected.dispose);
    addTearDown(actual.dispose);
    for (final a in [expected, actual]) {
      final bytes = ByteData.sublistView(a.ram);
      bytes.setUint16(0x200, 0x61c1);
      bytes.setUint16(0x202, 9);
      bytes.setUint32(0x1000, 0x11223344);
      a.cpus[0].r[12] = 0x06001001;
    }
    for (var iteration = 0; iteration < 8; iteration++) {
      for (final a in [expected, actual]) {
        a.cpus[0].pc = 0x06000200;
        expect(a.cpus[0].exec(), isTrue);
      }
      expect(actual.cpus[0].r[1], 0x2233);
      expect(actual.cpus[0].dump(), expected.cpus[0].dump());
    }
    expect(actual.cpus[0].jit!.compiledClocks, 0);
  }, skip: native ? false : 'No big-endian native backend');
  test('optional SH-2 recompilation preserves instruction alternation', () {
    final expected = Md32x(jit: false),
        actual = Md32x(jit: true, sliceClocks: 1);
    addTearDown(expected.dispose);
    addTearDown(actual.dispose);
    for (final a in [expected, actual]) {
      a.setBootRoms(
          main: Uint8List(256), master: boot(2048, 9), slave: boot(1024, 9));
      final data = ByteData.sublistView(a.ram);
      for (var i = 0; i < 2; i++) {
        final offset = i * 32;
        data.setUint16(offset, 0x7101);
        data.setUint16(offset + 2, 0xaffd);
        data.setUint16(offset + 4, 9);
        a.cpus[i].pc = 0x06000000 + offset;
      }
      a.control = 3;
    }
    for (var target = 1; target < 150; target += 3) {
      for (final a in [expected, actual]) {
        for (var i = 0; i < 2; i++) {
          while (a.cpus[i].clocks < target) {
            expect(a.cpus[i].exec(), isTrue);
          }
        }
      }
      for (var i = 0; i < 2; i++) {
        expect(actual.cpus[i].dump(), expected.cpus[i].dump());
        expect(actual.cpus[i].clocks, expected.cpus[i].clocks);
      }
    }
    expect(actual.ram, expected.ram);
    expect(actual.cpus[0].jit!.compiledClocks, greaterThan(0));
    expect(actual.cpus[1].jit!.compiledClocks, greaterThan(0));
    final before = actual.cpus[0].jit!.compiledClocks;
    expect(actual.cpus[0].exec(compiled: false), isTrue);
    expect(actual.cpus[0].jit!.compiledClocks, before);
  }, skip: native ? false : 'No big-endian native backend');

  test('communication reads continue natively and observe peer updates', () {
    final expected = Md32x(jit: false), actual = Md32x(jit: true);
    addTearDown(expected.dispose);
    addTearDown(actual.dispose);
    for (final a in [expected, actual]) {
      final bytes = ByteData.sublistView(a.ram);
      for (var i = 0; i < 4; i++) {
        bytes.setUint16(i * 2, 0x6141 + ((i == 3 ? 4 : i) << 8));
      }
      bytes.setUint16(8, 0xffff);
      bytes.setUint16(10, 9);
      a.cpus[0].r[4] = 0x20004020;
    }
    for (var pass = 0; pass < 12; pass++) {
      for (final a in [expected, actual]) {
        a.writeMain16(0xa15120, 0x8000 + pass);
        a.cpus[0].pc = 0x06000000;
        expect(a.cpus[0].run(a.cpus[0].clocks + 4), isTrue);
      }
      expect(actual.cpus[0].dump(), expected.cpus[0].dump());
    }
    final jit = actual.cpus[0].jit!;
    final entries = jit.rt.nativeEntries;
    final clocks = jit.compiledClocks;
    actual.cpus[0].pc = 0x06000000;
    actual.cpus[0].run(actual.cpus[0].clocks + 4);
    expect(jit.rt.nativeEntries - entries, 1);
    expect(jit.compiledClocks - clocks, 4);
    expect(actual.cpus[0].r[1], 0xffff800b);
    expected.cpus[0].pc = 0x06000000;
    expected.cpus[0].run(expected.cpus[0].clocks + 4);
    // Switching the same PC to FIFO reads must replay each read exactly once.
    for (final a in [expected, actual]) {
      a.writeMain16(0xa15106, 4);
      a.writeMain16(0xa15110, 4);
      for (var word = 0; word < 4; word++) {
        a.writeMain16(0xa15112, 0x100 + word);
      }
      a.cpus[0].r[4] = 0x20004012;
      a.cpus[0].pc = 0x06000000;
      expect(a.cpus[0].run(a.cpus[0].clocks + 4), isTrue);
      expect(a.readSh16(0x20004012, 0), 0xffff);
      expect(a.readSh16(0x20004010, 0), 0);
    }
    expect(actual.cpus[0].dump(), expected.cpus[0].dump());
  }, skip: native ? false : 'No native backend');

  test('guarded literal pointers update after host writes and exclude FIFO', () {
    final expected = Md32x(jit: false), actual = Md32x(jit: true);
    addTearDown(expected.dispose);
    addTearDown(actual.dispose);
    for (final a in [expected, actual]) {
      final code = ByteData.sublistView(a.ram);
      for (final (i, op) in [0xd407, 0x6141, 0x6241, 9, 0xffff, 9].indexed) {
        code.setUint16(i * 2, op);
      }
      code.setUint32(32, 0x20004020);
      a.writeMain16(0xa15120, 42);
      a.writeMain16(0xa15124, 99);
    }
    void pass() {
      for (final a in [expected, actual]) {
        a.cpus[0].pc = 0x06000000;
        expect(a.cpus[0].run(a.cpus[0].clocks + 4), isTrue);
      }
      expect(actual.cpus[0].dump(), expected.cpus[0].dump());
    }
    for (var warm = 0; warm < 12; warm++) {
      pass();
    }
    final jit = actual.cpus[0].jit!;
    final entries = jit.rt.nativeEntries;
    final clocks = jit.compiledClocks;
    pass();
    expect(jit.rt.nativeEntries - entries, 1);
    expect(jit.compiledClocks - clocks, 4);
    for (final a in [expected, actual]) {
      ByteData.sublistView(a.ram).setUint32(32, 0x20004024);
    }
    pass();
    expect(actual.cpus[0].r[1], 99);
    for (final a in [expected, actual]) {
      ByteData.sublistView(a.ram).setUint32(32, 0x20004012);
      a.writeMain16(0xa15106, 4);
      a.writeMain16(0xa15110, 2);
      a.writeMain16(0xa15112, 0x101);
      a.writeMain16(0xa15112, 0x102);
    }
    pass();
    expect(actual.cpus[0].r[1], 0x101);
    expect(actual.cpus[0].r[2], 0x102);
  }, skip: native ? false : 'No native backend');

  test('private cache code remains interpreted with native JIT enabled', () {
    final expected = Md32x(jit: false), actual = Md32x(jit: true);
    addTearDown(expected.dispose);
    addTearDown(actual.dispose);
    for (final a in [expected, actual]) {
      final bytes = ByteData.sublistView(a.cacheData[0]);
      bytes.setUint16(0x100, 0x7101);
      bytes.setUint16(0x102, 0xaffd);
      bytes.setUint16(0x104, 9);
      a.cpus[0].pc = 0xc0000100;
      expect(a.cpus[0].run(200), isTrue);
    }
    expect(actual.cpus[0].dump(), expected.cpus[0].dump());
    expect(actual.cpus[0].clocks, expected.cpus[0].clocks);
    expect(actual.cpus[0].r[1], 50);
    expect(actual.cpus[0].jit!.compiledClocks, 0);
  }, skip: native ? false : 'No big-endian native backend');

  test('idle yielding is optional for adapters without an idle detector', () {
    for (final stop in [true, false]) {
      final jit = Sh2Jit.create(compileThreshold: 1, stopOnNoStore: stop)!;
      addTearDown(jit.dispose);
      final ram = jit.rt.alloc(0x1000);
      final bytes = ByteData.sublistView(ram);
      bytes.setUint16(0, 0x7101);
      bytes.setUint16(2, 0xaffd);
      bytes.setUint16(4, 9);
      jit.map(0x06000000, ram.length, ram);
      jit.attach((at) => bytes.getUint16(at & 0xfff));
      final result = jit.run(0x06000000, 32)!;
      expect(result.$1, 0x06000000);
      expect(result.$2, stop ? 4 : 32);
      expect(jit.regs[1], stop ? 1 : 8);
    }
  }, skip: native ? false : 'No big-endian native backend');

  test('batched native execution matches CPU across deadlines and debug steps',
      () {
    for (final quantum in [32, 64]) {
      final expected = Md32x(jit: false, sliceClocks: quantum);
      final actual = Md32x(jit: true, sliceClocks: quantum);
      addTearDown(expected.dispose);
      addTearDown(actual.dispose);
      for (final a in [expected, actual]) {
        a.setBootRoms(
            main: Uint8List(256), master: boot(2048, 9), slave: boot(1024, 9));
        final data = ByteData.sublistView(a.ram);
        for (var i = 0; i < 2; i++) {
          final offset = i * 32;
          data.setUint16(offset, 0x7101);
          data.setUint16(offset + 2, 0x2c12);
          data.setUint16(offset + 4, 0xaffc);
          data.setUint16(offset + 6, 9);
          a.cpus[i].pc = 0x06000000 + offset;
          a.cpus[i].r[12] = 0x06001000 + i * 4;
        }
        a.control = 3;
      }
      for (var target = 1; target < 600; target += 36) {
        for (final a in [expected, actual]) {
          expect(a.advance(target, Md32x.clockHz).$1, isTrue);
        }
        for (var i = 0; i < 2; i++) {
          // Compiled blocks may overshoot the deadline. The CPUs write
          // separate words here, so each reference CPU can catch up alone.
          expected.cpus[i].run(actual.cpus[i].clocks, compiled: false);
          expect(actual.cpus[i].dump(), expected.cpus[i].dump());
          expect(actual.cpus[i].clocks, expected.cpus[i].clocks);
        }
        expect(actual.ram, expected.ram);
      }
      expect(actual.cpus[0].jit!.compiledClocks, greaterThan(0));
      final clocks = actual.cpus.map((c) => c.clocks).toList();
      final compiled = actual.cpus.map((c) => c.jit!.compiledClocks).toList();
      expect(actual.advance(1000, Md32x.clockHz, step: true).$1, isTrue);
      for (var i = 0; i < 2; i++) {
        expect(actual.cpus[i].clocks - clocks[i], inInclusiveRange(1, 2));
        expect(actual.cpus[i].jit!.compiledClocks, compiled[i]);
      }
    }
  }, skip: native ? false : 'No big-endian native backend');

  test('.32x selection enables the adapter without a 32X cartridge header', () {
    final rom = cartridge()..setAll(0x100, 'CARTRIDGE       '.codeUnits);
    final md = (CoreFactory.of('32x') as Md)..setRom(rom);
    addTearDown(md.dispose);
    expect(md.expansion, isNotNull);
    expect(md.expansion!.rom.length, rom.length);
  });

  test('normal cartridges do not create a 32x adapter or track opacity', () {
    final rom = cartridge();
    rom.setAll(0x100, 'CARTRIDGE       '.codeUnits);
    ByteData.sublistView(rom).setUint32(4, 0x300);
    final md = Md()..setRom(rom);
    addTearDown(md.dispose);
    for (int i = 0; i < 100; i++) {
      expect(md.exec(false).stopped, isFalse);
    }
    expect(md.expansion, isNull);
    expect(md.vdp.trackOpacity, isFalse);
  });
  test('loading an ordinary cartridge removes the adapter bus', () {
    final md = Md()..setRom(cartridge());
    addTearDown(md.dispose);
    expect(md.expansion, isNotNull);
    final ram = md.busM68.ram;
    final normal = cartridge()..setAll(0x100, 'CARTRIDGE       '.codeUnits);
    ByteData.sublistView(normal).setUint32(4, 0x300);
    md.setRom(normal);
    expect(md.expansion, isNull);
    expect(md.busM68.ram, same(ram));
    expect(md.cpuM68.bus, same(md.busM68));
    expect(md.busZ80.busM68, same(md.busM68));
    expect(md.vdp.bus, same(md.busM68));
    expect(md.exec(false).stopped, isFalse);
  });

  test('disabled and reset-held adapters freeze all peripherals', () {
    final a = adapter();
    a.pwm.write(2, 5);
    a.pwm.write(4, 3);
    a.video.writeRegister(8, 42);
    final pc = a.cpus[0].pc;
    for (final control in [0, 1]) {
      a.writeMain16(0xa15100, control);
      expect(a.advance(10000, Md32x.clockHz), (true, false, false));
      a.beginLine(0);
      expect(a.cpus[0].pc, pc);
      expect(a.pwm.left.length, 1);
      expect(a.video.busy, isTrue);
      expect(a.video.vblank, isTrue);
    }
    a.writeMain16(0xa15100, 3);
    expect(a.advance(10001, Md32x.clockHz), (true, true, true));
    expect(a.cpus[0].r[1], 42);
    expect(a.cpus[1].r[2], 7);
    expect(a.pwm.left.length, 1); // no catch-up work for the paused interval
  });
  test('released adapter requires boot ROMs', () {
    final a = Md32x()..writeMain16(0xa15100, 3);
    addTearDown(a.dispose);
    expect(a.advance(1, Md32x.clockHz).$1, isFalse);
    expect(a.stoppedReason, contains('boot ROMs'));
  });
  test('both CPUs share SDRAM and communication ports through uncached aliases',
      () {
    final a = adapter();
    a.buses[0].write32(0x26000010, 0x12345678);
    expect(a.buses[1].read32(0x06000010), 0x12345678);
    a.writeMain16(0xa15120, 0xabcd);
    expect(a.readSh16(0x4020, 0), 0xabcd);
    a.writeSh16(0x4022, 0x5678, 1);
    expect(a.readMain16(0xa15122), 0x5678);
    expect(a.readMain16(0xa130ec), 0x4d41);
  });
  test('SH-2 cache data arrays are writable, private, and reset with the CPUs',
      () {
    final a = adapter();
    a.buses[1].write32(0xc00005f0, 0x12345678);
    expect(a.buses[1].read32(0xc00005f0), 0x12345678);
    expect(a.buses[0].read32(0xc00005f0), 0);
    a.buses[0].write8(0xc00005f1, 0xab);
    expect(a.buses[0].read16(0xc00005f0), 0x00ab);
    a.reset();
    expect(a.buses[1].read32(0xc00005f0), 0);
  });
  test('SH-2 associative cache purges preserve polygon data in SDRAM', () {
    final a = adapter();
    for (final bus in a.buses) {
      // reference game purges each cache line of a queued polygon before
      // reading it through the cached SDRAM address.
      for (var offset = 0; offset < 64; offset += 4) {
        bus.write32(0x26038000 + offset, 0x12345678 + offset);
      }
      for (var offset = 0; offset < 64; offset += 16) {
        bus.write32(0x46038000 + offset, 0);
      }
      bus.write8(0x46038001, 0);
      bus.write16(0x46038002, 0);
      for (var offset = 0; offset < 64; offset += 4) {
        expect(bus.read32(0x06038000 + offset), 0x12345678 + offset);
        expect(bus.read32(0x26038000 + offset), 0x12345678 + offset);
      }
      // P2 reads also do not expose external RAM as an alias.
      expect(bus.read8(0x46038000), 0xff);
      expect(bus.read16(0x46038000), 0xffff);
      expect(bus.read32(0x46038000), 0xffffffff);
    }
  });
  test('video ownership and word-only palettes are enforced', () {
    final a = adapter();
    a.writeMain16(0xa15202, 0x1234);
    a.writeMain8(0xa15203, 0xff);
    a.writeSh16(0x4202, 0xffff, 0);
    expect(a.video.palette[1], 0x1234);
    a.writeMain16(0xa15100, 0x8003);
    a.writeMain16(0xa15202, 0xffff);
    a.writeSh16(0x4202, 0x5678, 0);
    expect(a.video.palette[1], 0x5678);
    expect(a.readMain16(0xa15202), 0xffff);
    expect(a.readSh16(0x4000, 0) & 0x20f, 0x200);
  });
  test('DREQ FIFO holds four words and decrements transfer length', () {
    final a = adapter();
    a.writeMain16(0xa15106, 4);
    a.writeMain16(0xa15110, 4);
    for (int i = 0; i < 5; i++) {
      a.writeMain16(0xa15112, i + 10);
    }
    expect(a.readMain16(0xa15106) & 0x8000, 0x8000);
    for (int i = 0; i < 4; i++) {
      expect(a.readSh16(0x4012, 0), i + 10);
    }
    expect(a.readMain16(0xa15110), 0);
    expect(a.readSh16(0x4012, 1), 0xffff);
  });
  test('ROM windows and RV select the cartridge owner', () {
    final a = adapter()..setRom(Uint8List.fromList([1, 2, 3, 4]));
    a.writeMain16(0xa15100, 3);
    expect(a.readMain16(0x880000), 0x0102);
    expect(a.readSh16(0x02000000, 0), 0x0102);
    expect(a.mapsMain(0x200), isTrue);
    a.writeMain16(0xa15106, 1);
    expect(a.mapsMain(0x200), isFalse);
    expect(a.readSh16(0x02000000, 0), 0xffff);
  });
  test('MD scheduling exposes both SH-2 CPUs and executes synthetic boot code',
      () {
    final md = Md(expansionBoot: true)
      ..setExpansionBootRoms(
          main: Uint8List(256),
          master: boot(2048, 0xe12a),
          slave: boot(1024, 0xe207))
      ..setRom(cartridge());
    addTearDown(md.dispose);
    md.busM68.write16(0xa15100, 3);
    for (int i = 0; i < 100; i++) {
      expect(md.exec(false).stopped, isFalse);
    }
    expect(md.expansion!.cpus[0].r[1], 42);
    expect(md.expansion!.cpus[1].r[2], 7);
    expect(md.cpuInfos.length, 4);
    expect(md.vdp.trackOpacity, isTrue);
  });
  test('command and VBlank IRQs honor masks and clear independently', () {
    final a = adapter();
    a.writeMain16(0xa15100, 3);
    a.writeMain16(0xa15102, 1);
    a.cpus[0].sr = 0;
    // Unmask command and VBlank; handlers live in shared SDRAM.
    a.buses[0].write32(0x06000100 + 68 * 4, 0x06001000);
    a.buses[0].write32(0x06000100 + 70 * 4, 0x06002000);
    a.cpus[0].vbr = 0x06000100;
    a.writeSh16(0x4000, 10, 0);
    a.beginLine(224);
    expect(a.cpus[0].exec(), isTrue);
    expect(a.cpus[0].pc, 0x06002000);
    a.writeSh16(0x4016, 0, 0); // clear VBlank
    a.cpus[0].sr = 0;
    expect(a.cpus[0].exec(), isTrue);
    expect(a.cpus[0].pc, 0x06001000);
    a.writeSh16(0x401a, 0, 0); // clear command
    expect(a.readMain16(0xa15102), 0);
  });
  test('fill wraps within its page and completes only while active', () {
    final a = adapter();
    a.video.writeRegister(4, 2);
    a.video.writeRegister(6, 0x12ff);
    a.video.writeRegister(8, 0xabcd);
    for (final address in [0x12ff, 0x1200, 0x1201]) {
      expect(a.video.readFrame8(address * 2), 0xab);
      expect(a.video.readFrame8(address * 2 + 1), 0xcd);
    }
    expect(a.video.fillAddress, 0x1202);
    a.advance(100, Md32x.clockHz);
    expect(a.video.busy, isTrue);
    a.writeMain16(0xa15100, 3);
    a.advance(110, Md32x.clockHz);
    expect(a.video.busy, isFalse);
  });
  test('PWM FIFO bounds, routing and interrupt interval', () {
    final a = adapter();
    a.pwm.write(0, 0x105);
    a.pwm.write(2, 5);
    for (int i = 0; i < 4; i++) {
      a.pwm.write(4, 4);
      a.pwm.write(6, 0);
    }
    expect(a.pwm.read(4), 0x8000);
    a.pwm.tick(4);
    expect(a.pwm.left.length, 2);
    expect(a.pwm.sample(), (1.0, -1.0));
    a.pwm.tick(8);
    expect(a.pwm.read(4), 0x4000);
  });
  test('reset retains supplied boot ROMs and shared RAM', () {
    final a = adapter();
    a.ram[0] = 42;
    a.writeMain16(0xa15100, 3);
    a.advance(10, Md32x.clockHz);
    a.reset();
    expect(a.enabled, isFalse);
    expect(a.biosLoaded, isTrue);
    expect(a.cpus[0].pc, 0x100);
    expect(a.ram[0], 42);
    expect(a.pwm.left, isEmpty);
  });
  test('framebuffer swap waits for VBlank and overwrite ignores zero bytes',
      () {
    final v = ExpansionVideo();
    v.writeFrame8(0, 0x12);
    v.writeFrame8(0, 0, overwrite: true);
    expect(v.readFrame8(0), 0x12);
    v.writeRegister(0, 1);
    v.beginLine(0);
    v.writeRegister(10, 1);
    expect(v.displayBank, 0);
    v.beginLine(224);
    expect(v.displayBank, 1);
  });
  test('indexed, direct and RLE pixels respect MD opacity and priority', () {
    final v = ExpansionVideo();
    final frame = v.frames[0];
    frame[1] = 0x80; // pixels at byte 256
    v.palette[1] = 0x801f;
    final md = Uint32List(320 * 224)..fillRange(0, 320 * 224, 0xff123456);
    final opaque = Uint8List(320 * 224)..fillRange(0, 320 * 224, 1);
    v.mode = 1;
    frame[256] = 1;
    v.renderLine(0, md, opaque, 320);
    expect(v.output[0], 0xff0000ff);
    expect(v.output[1], md[1]);
    opaque[1] = 0;
    v.renderLine(0, md, opaque, 320);
    expect(v.output[1], 0xff000000); // palette zero is an opaque black pixel
    v.mode = 2;
    frame[256] = 0x83;
    frame[257] = 0xe0;
    v.renderLine(0, md, opaque, 320);
    expect(v.output[0], 0xff00ff00);
    v.mode = 3;
    frame[256] = 2;
    frame[257] = 1;
    v.renderLine(0, md, opaque, 320);
    expect(v.output.take(3), everyElement(0xff0000ff));
  });
}

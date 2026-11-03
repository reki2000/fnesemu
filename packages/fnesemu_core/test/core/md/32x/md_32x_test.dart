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

  test('MAC.W and MAC.L match the interpreter with and without saturation', () {
    for (final saturate in [false, true]) {
      final expected = Md32x(jit: false), actual = Md32x(jit: true);
      addTearDown(expected.dispose);
      addTearDown(actual.dispose);
      for (final a in [expected, actual]) {
        final bytes = ByteData.sublistView(a.ram);
        bytes.setUint16(0, 0x021f); // mac.l @r1+,@r2+
        bytes.setUint16(2, 0x421f); // mac.w @r1+,@r2+
        bytes.setUint16(4, 0x4310); // dt r3
        bytes.setUint16(6, 0x8bfb); // bf 0x06000000
        bytes.setUint16(8, 0xaffe); // bra 0x06000008
        bytes.setUint16(10, 9); // nop
        var seed = 12345;
        for (var i = 0x100; i < 0x400; i += 4) {
          seed = (seed * 1103515245 + 12345) & 0x7fffffff;
          bytes.setUint32(i, seed ^ (seed << 15) & 0xffffffff);
        }
        final cpu = a.cpus[0];
        cpu.pc = 0x06000000;
        cpu.r[1] = 0x06000100;
        cpu.r[2] = 0x06000200;
        cpu.r[3] = 40;
        cpu.sr = saturate ? 0xf2 : 0xf0;
        expect(cpu.run(2000), isTrue);
      }
      expect(actual.cpus[0].dump(), expected.cpus[0].dump(),
          reason: 'saturate $saturate');
      expect(actual.cpus[0].jit!.compiledClocks, greaterThan(0));
    }
  }, skip: native ? false : 'No big-endian native backend');

  test('.32x selection enables the adapter without a 32X cartridge header', () {
    final rom = cartridge()..setAll(0x100, 'CARTRIDGE       '.codeUnits);
    final md = (CoreFactory.of('32x') as Md)..setRom(rom);
    addTearDown(md.dispose);
    expect(md.expansion, isNotNull);
    expect(md.expansion!.rom.length, rom.length);
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
}

import 'dart:typed_data';

import 'package:fnesemu/core/core_factory.dart';
import 'package:fnesemu/core/md/32x/md_32x.dart';
import 'package:fnesemu/core/md/32x/video.dart';
import 'package:fnesemu/core/md/md.dart';
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

Md32x adapter() => Md32x()
  ..setBootRoms(
      main: Uint8List(256),
      master: boot(2048, 0xe12a),
      slave: boot(1024, 0xe207));

Uint8List cartridge() {
  final bytes = Uint8List(0x400);
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, 0xff8000);
  data.setUint32(4, 0x880300);
  bytes.setAll(0x100, 'SEGA 32X'.codeUnits);
  bytes.setAll(0x1f0, 'JUE'.codeUnits);
  data.setUint16(0x300, 0x60fe);
  return bytes;
}

void main() {
  test('.32x selection enables the adapter without a 32X cartridge header', () {
    final rom = cartridge()
      ..setAll(0x100, 'SEGA GENESIS    '.codeUnits);
    final md = (CoreFactory.of('32x') as Md)..setRom(rom);
    expect(md.expansion, isNotNull);
    expect(md.expansion!.rom.length, rom.length);
  });

  test('normal cartridges do not create a 32x adapter or track opacity', () {
    final rom = cartridge();
    rom.setAll(0x100, 'SEGA GENESIS    '.codeUnits);
    ByteData.sublistView(rom).setUint32(4, 0x300);
    final md = Md()..setRom(rom);
    for (int i = 0; i < 100; i++) {
      expect(md.exec(false).stopped, isFalse);
    }
    expect(md.expansion, isNull);
    expect(md.vdp.trackOpacity, isFalse);
  });
  test('loading an ordinary cartridge removes the adapter bus', () {
    final md = Md()..setRom(cartridge());
    expect(md.expansion, isNotNull);
    final ram = md.busM68.ram;
    final normal = cartridge()..setAll(0x100, 'SEGA GENESIS    '.codeUnits);
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

@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:fnesemu_core/src/core/sms/bus.dart';
import 'package:fnesemu_core/src/core/sms/sms.dart';
import 'package:fnesemu_core/src/util/state.dart';
import 'package:test/test.dart';

// builds a rom image from the code blocks placed at their addresses
Uint8List _rom(Map<int, List<int>> blocks, {int size = 0x8000}) {
  final rom = Uint8List(size);
  for (final MapEntry(key: addr, value: code) in blocks.entries) {
    rom.setRange(addr, addr + code.length, code);
  }
  return rom;
}

// sets the VDP registers from the table at 0x0050, then runs [body] and
// waits for interrupts. the interrupt handler counts frames at 0xc000
Uint8List _program(List<int> registers, List<int> body) => _rom({
      0x0000: [
        0xf3, // di
        0x31, 0xf0, 0xdf, // ld sp, $dff0
        0xed, 0x56, // im 1
        0x21, 0x50, 0x00, // ld hl, $0050
        0x06, registers.length, // ld b, n
        0x0e, 0xbf, // ld c, $bf
        0xed, 0xb3, // otir
        0xc3, 0x00, 0x01, // jp $0100
      ],
      0x0038: [
        0xf5, // push af
        0xdb, 0xbf, // in a, ($bf)
        0x3a, 0x00, 0xc0, // ld a, ($c000)
        0x3c, // inc a
        0x32, 0x00, 0xc0, // ld ($c000), a
        0xf1, // pop af
        0xfb, // ei
        0xc9, // ret
      ],
      0x0050: registers,
      0x0100: [
        ...body,
        0xfb, // ei
        0x76, // halt
        0x18, 0xfd, // jr -3
      ],
    });

// out ($bf) with the two bytes of a VDP command
List<int> _command(int low, int high) =>
    [0x3e, low, 0xd3, 0xbf, 0x3e, high, 0xd3, 0xbf];

List<int> _data(int value) => [0x3e, value, 0xd3, 0xbe];

Uint8List _mode4Rom() => _program([
      0x04, 0x80, 0x60, 0x81, 0xff, 0x82, 0xff, 0x83, 0xff, 0x84, //
      0xff, 0x85, 0xfb, 0x86, 0x00, 0x87, 0x00, 0x88, 0x00, 0x89, 0xff, 0x8a,
    ], [
      ..._command(0x00, 0x40), // vram 0x0000
      0x06, 0x08, // ld b, 8
      ..._data(0xff), 0xaf, 0xd3, 0xbe, 0xd3, 0xbe, 0xd3, 0xbe, // color 1
      0x10, 0xf3, // djnz
      ..._command(0x01, 0xc0), // cram 1
      ..._data(0x03), // red
    ]);

void _frames(Sms sms, int frames) {
  for (var i = 0; i < frames; i++) {
    expect(sms.runFrame(sms.scanlinesInFrame).stopped, isFalse);
  }
}

void main() {
  test('SMS restores into a fresh instance and continues frames and audio',
      () {
    final original = Sms(SmsModel.standard)..setRom(_mode4Rom());
    _frames(original, 2);
    original.bus.write(0xffff, 5); // slot 2 bank register
    original.bus.write(0xfffc, 0x08); // map the cartridge RAM into slot 2
    original.bus.write(0x8010, 0x42);
    original.bus.psg.write8(0x85);
    original.bus.psg.write8(0x12);
    original.bus.psg.write8(0x91);
    final state = original.saveState();

    final restored = Sms(SmsModel.standard)..setRom(_mode4Rom());
    final ram = restored.bus.ram, vram = restored.vdp.vram;
    restored.loadState(state);
    expect(restored.saveState(), state);
    expect(restored.bus.ram, same(ram));
    expect(restored.vdp.vram, same(vram));
    expect(restored.bus.read(0x8010), 0x42);

    final pcmA = <double>[], pcmB = <double>[];
    original.onAudio((audio) => pcmA.addAll(audio.buffer));
    restored.onAudio((audio) => pcmB.addAll(audio.buffer));
    _frames(original, 3);
    _frames(restored, 3);
    expect(restored.saveState(), original.saveState());
    expect(restored.imageBuffer().buffer, original.imageBuffer().buffer);
    expect(restored.bus.ram[0], original.bus.ram[0]);
    expect(pcmA, isNotEmpty);
    expect(pcmB, pcmA);
  });

  test('the domestic console restores its FM sound state', () {
    final original = Sms(SmsModel.mk3)..setRom(Uint8List(0x8000));
    final bus = original.bus;
    void reg(int addr, int value) {
      bus.output(0xf0, addr);
      bus.output(0xf1, value);
    }

    bus.output(0xf2, 1); // mix the FM sound in
    reg(0x30, 0x10); // channel 0: violin, full volume
    reg(0x10, 0x20); // A4: F-number 288, block 4
    reg(0x20, 0x19);
    _frames(original, 2);
    final state = original.saveState();

    final restored = Sms(SmsModel.mk3)..setRom(Uint8List(0x8000));
    restored.loadState(state);
    expect(restored.saveState(), state);

    final buffersA = <Float32List>[], buffersB = <Float32List>[];
    original.onAudio((audio) => buffersA.add(audio.buffer));
    restored.onAudio((audio) => buffersB.add(audio.buffer));
    _frames(original, 3);
    _frames(restored, 3);
    expect(restored.saveState(), original.saveState());
    expect(buffersA, isNotEmpty);
    expect(buffersB, buffersA);
    final peak =
        buffersB.last.fold(0.0, (m, v) => v.abs() > m ? v.abs() : m);
    expect(peak, greaterThan(0.01));
  });

  test('the portable console restores the link port and the PSG stereo', () {
    Uint8List rom() {
      final bytes = Uint8List(0x8000);
      bytes.setAll(0x7ff0, 'TMR '.codeUnits);
      bytes[0x7fff] = 0x6c; // export region
      return bytes;
    }

    final original = Sms(SmsModel.gg)..setRom(rom());
    _frames(original, 1);
    original.bus.output(0x01, 0x5a);
    original.bus.output(0x06, 0x0f);
    final state = original.saveState();

    final restored = Sms(SmsModel.gg)..setRom(rom());
    restored.loadState(state);
    expect(restored.saveState(), state);
    expect(restored.bus.input(0x01), 0x5a);
    expect(restored.bus.input(0x06), 0x0f);
    _frames(original, 2);
    _frames(restored, 2);
    expect(restored.saveState(), original.saveState());
    expect(restored.imageBuffer().buffer, original.imageBuffer().buffer);
  });

  test('model and media mismatches fail before mutation', () {
    final original = Sms(SmsModel.standard)..setRom(_mode4Rom());
    _frames(original, 1);
    final state = original.saveState();

    final otherRom = Sms(SmsModel.standard)..setRom(_mode4Rom());
    otherRom.bus.rom[0x400] = 1;
    for (final other in [
      Sms(SmsModel.mk3)..setRom(_mode4Rom()),
      Sms(SmsModel.gg)..setRom(_mode4Rom()),
      otherRom,
    ]) {
      final before = other.saveState();
      expect(() => other.loadState(state), throwsA(isA<StateMismatch>()));
      expect(other.saveState(), before);
    }

    final restored = Sms(SmsModel.standard)..setRom(_mode4Rom());
    final before = restored.saveState();
    expect(() => restored.loadState(state.sublist(0, state.length - 10)),
        throwsA(isA<StateMismatch>()));
    expect(restored.saveState(), before);
  });
}

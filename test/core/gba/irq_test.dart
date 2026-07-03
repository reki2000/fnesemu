import 'dart:typed_data';

import 'package:fnesemu/core/gba/bus.dart';
import 'package:fnesemu/core/gba/gba.dart';
import 'package:test/test.dart';

import 'arm7_asm.dart';

/// End-to-end tests for the IRQ delivery chain a real BIOS relies on:
/// VBlank raise -> HALT wake -> CPU exception entry -> BIOS-style dispatcher
/// (`ldr pc, [r0, #-4]` via the 0x03FFFFFC IWRAM mirror) -> user handler
/// (acks IF, sets the BIOS flags word at 0x03007FF8) -> return via
/// `subs pc, lr, #4`.
///
/// The synthetic BIOS mirrors the structure of the real one closely enough
/// that a hang in IntrWait-style wait loops should reproduce here.

Uint8List _words(List<int> words) {
  final b = Uint8List(words.length * 4);
  for (var i = 0; i < words.length; i++) {
    final w = words[i];
    b[i * 4] = w & 0xff;
    b[i * 4 + 1] = (w >> 8) & 0xff;
    b[i * 4 + 2] = (w >> 16) & 0xff;
    b[i * 4 + 3] = (w >> 24) & 0xff;
  }
  return b;
}

/// minimal BIOS: reset stub sets up the banked stacks and jumps to the cart;
/// the IRQ vector runs the same dispatcher sequence as the official BIOS.
Uint8List _buildBios() {
  const resetIdx = 8; // word index of the reset stub
  const dispatchIdx = 21; // word index of the IRQ dispatcher

  final words = <int>[
    // exception vectors
    aB(resetIdx - 0 - 2), // 0x00 reset
    aBSelf, // 0x04 undefined
    aBSelf, // 0x08 swi (unused here)
    aBSelf, // 0x0c prefetch abort
    aBSelf, // 0x10 data abort
    aBSelf, // 0x14 (reserved)
    aB(dispatchIdx - 6 - 2), // 0x18 irq
    aBSelf, // 0x1c fiq

    // reset stub: set sp for irq/svc, then sys mode with IRQ enabled
    aMsrCtlI(0xd2), // irq mode, I+F set
    aMovI(13, 0xa0),
    aOrrI(13, 13, 0x7f, rot4: 12),
    aOrrI(13, 13, 3, rot4: 4), // sp_irq = 0x03007fa0
    aMsrCtlI(0xd3), // svc mode
    aMovI(13, 0xe0),
    aOrrI(13, 13, 0x7f, rot4: 12),
    aOrrI(13, 13, 3, rot4: 4), // sp_svc = 0x03007fe0
    aMsrCtlI(0x5f), // sys mode, IRQ enabled
    aMovI(13, 0),
    aOrrI(13, 13, 0x7f, rot4: 12),
    aOrrI(13, 13, 3, rot4: 4), // sp_sys = 0x03007f00
    aMovI(15, 8, rot4: 4), // pc = 0x08000000 (cartridge entry)

    // irq dispatcher (same shape as the official BIOS handler)
    aStm(13, 0x500f, pre: true, up: false, wb: true), // stmdb sp!,{r0-r3,r12,lr}
    aMovI(0, 4, rot4: 4), // r0 = 0x04000000
    aAddI(14, 15, 0), // lr = the ldm below
    aLdr(15, 0, 4, up: false), // ldr pc, [r0,#-4] -> [0x03FFFFFC] mirror
    aLdm(13, 0x500f, wb: true), // ldmia sp!,{r0-r3,r12,lr}
    aSubI(15, 14, 4, s: true), // subs pc, lr, #4
  ];
  assert(words[resetIdx] == aMsrCtlI(0xd2));
  assert(words[dispatchIdx] == aStm(13, 0x500f, pre: true, up: false, wb: true));
  return _words(words);
}

const _handlerIdx = 32; // user IRQ handler at ROM word 32 (0x08000080)
const _thumbIdx = 24; // thumb wait loop at ROM word 24 (0x08000060)

/// user IRQ handler: ack IF and OR the bits into the BIOS flags word
/// (0x03007FF8), like every SDK-generated game handler does.
final _handler = <int>[
  aMovI(0, 4, rot4: 4), // 0x04000000
  aAddI(0, 0, 2, rot4: 12), // +0x200
  aAddI(0, 0, 2), // -> 0x04000202 (IF)
  aLdrh(1, 0, 0),
  aStrh(1, 0, 0), // acknowledge
  aMovI(2, 0xf8),
  aOrrI(2, 2, 0x7f, rot4: 12),
  aOrrI(2, 2, 3, rot4: 4), // r2 = 0x03007ff8
  aLdr(3, 2, 0),
  aOrrR(3, 3, 1),
  aStr(3, 2, 0), // biosFlags |= IF
  aBx(14),
];

/// common ROM prologue: install the handler pointer at 0x03007FFC and enable
/// the VBlank interrupt (DISPSTAT.3, IE.0, IME). Leaves r0=0x03007ff8,
/// r2=0x04000000, r6=0x02000000.
final _prologue = <int>[
  aMovI(0, 0xf8),
  aOrrI(0, 0, 0x7f, rot4: 12),
  aOrrI(0, 0, 3, rot4: 4), // r0 = 0x03007ff8
  ...aMovI32(1, 0x08000000 + _handlerIdx * 4),
  aStr(1, 0, 4), // [0x03007ffc] = handler
  aMovI(2, 4, rot4: 4), // r2 = 0x04000000
  aMovI(3, 8),
  aStr(3, 2, 4), // DISPSTAT = 8 (VBlank IRQ enable)
  aMovI(3, 1),
  aStr(3, 2, 0x200), // IE = 1 (VBlank)
  aStr(3, 2, 0x208), // IME = 1
  aMovI(6, 2, rot4: 4), // r6 = 0x02000000 (result)
];

Uint8List _buildRom(List<int> main) {
  final words = [..._prologue, ...main];
  assert(words.length <= _thumbIdx);
  while (words.length < _handlerIdx) {
    words.add(aNop);
  }
  words.addAll(_handler);
  return _words(words);
}

/// run [gba] until the ROM writes its result to 0x02000000.
int _runUntilResult(Gba gba, {int maxExec = 500000}) {
  for (var i = 0; i < maxExec; i++) {
    gba.exec(false);
    final v = gba.bus.read32(0x02000000);
    if (v != 0) return v;
  }
  fail('ROM never reported a result: likely stuck waiting for the IRQ\n'
      '${gba.dump()}');
}

Gba _boot(Uint8List rom) {
  final gba = Gba();
  gba.bus.loadBios(_buildBios());
  gba.setRom(rom); // resets; with a BIOS loaded it boots from vector 0
  return gba;
}

void main() {
  test('POSTFLG byte write does not halt, HALTCNT byte write does', () {
    final bus = Bus();
    // the BIOS writes POSTFLG=1 at boot while IE/IF/IME are still zero; if
    // this entered HALT the CPU could never wake up (regression: pc stuck in
    // the BIOS startup around 0x194c).
    bus.write8(0x04000300, 1);
    expect(bus.halted, false);
    expect(bus.read8(0x04000300), 1);
    bus.write8(0x04000301, 0);
    expect(bus.halted, true);
  });

  test('halt wakes on VBlank and the BIOS-style dispatcher runs the handler',
      () {
    final rom = _buildRom([
      aMovI(4, 0),
      aStrb(4, 2, 0x301), // HALTCNT: halt until an interrupt
      aLdr(5, 0, 0), // BIOS flags set by the handler
      aStr(5, 6, 0), // result -> 0x02000000
      aBSelf,
    ]);

    final v = _runUntilResult(_boot(rom));
    expect(v & 1, 1, reason: 'VBlank bit missing in BIOS flags (0x03007FF8)');
  });

  test('IRQ interrupts a thumb wait loop (IntrWait-style polling)', () {
    // thumb loop: while ([0x03007ff8] == 0) {}; then store it to 0x02000000
    final thumb = [
      tLdrI(1, 0, 0), // ldr r1, [r0]
      tCmpI(1, 0),
      tBCond(condEq, -4), // beq back to the ldr
      tStrI(1, 6, 0), // result -> [r6]
      tBSelf,
    ];
    if (thumb.length.isOdd) thumb.add(tNop);

    final main = <int>[
      ...aMovI32(1, 0x08000000 + _thumbIdx * 4 + 1),
      aBx(1),
    ];
    // place the thumb code at its fixed slot
    final words = [..._prologue, ...main];
    assert(words.length <= _thumbIdx);
    while (words.length < _thumbIdx) {
      words.add(aNop);
    }
    for (var i = 0; i < thumb.length; i += 2) {
      words.add(thumb[i] | (thumb[i + 1] << 16));
    }
    while (words.length < _handlerIdx) {
      words.add(aNop);
    }
    words.addAll(_handler);

    final v = _runUntilResult(_boot(_words(words)));
    expect(v & 1, 1, reason: 'VBlank bit missing in BIOS flags (0x03007FF8)');
  });
}

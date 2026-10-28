import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ps2/bus.dart';
import 'package:fnesemu_core/src/core/ps2/ee_io.dart';
import 'package:fnesemu_core/src/core/ps2/iop/iop_io.dart';
import 'package:fnesemu_core/src/core/ps2/iop/iop_memory.dart';
import 'package:test/test.dart';

const _d1 = 0x1000e000;
const _sif0 = 0x1000c000, _sif1 = 0x1000c400;

class _System {
  final bus = Ps2Bus();
  late final EeIo ee;
  final IopMemory iopMem = IopMemory(Uint8List(0x400000));
  late final IopIo iop;

  _System() {
    ee = EeIo(bus);
    bus.io = ee;
    iop = IopIo(iopMem, ee.sif);
    bus.write32(_d1, 1); // DMAE
    iop.write(0x1f8010f0, 4, 0xffffffff);
    iop.write(0x1f801570, 4, 0xffffffff);
  }
}

void main() {
  cdvdTests();
  test('SIF1 delivers an EE packet to IOP memory', () {
    final s = _System();
    // EE chain tag at 0x1000: end tag with 3 quads. The first is the IOP tag
    // (address 0x4000, end, 6 words), followed by two quads of data.
    final b = s.bus;
    b.write64(0x1000, 3 | (7 << 28) | (0x1010 << 32));
    b.write64(0x1010, 0x4000 | (1 << 31) | (6 << 32));
    for (var i = 0; i < 8; i++) {
      b.write32(0x1020 + i * 4, 0x100 + i);
    }
    b.write32(_sif1 + 0x30, 0x1000);
    b.write32(_sif1, 0x104); // chain mode, start
    expect(s.ee.sif.sif1Fifo.length, 12);

    s.iop.write(0x1f801500 + 0x10 * 3 + 8, 4, (1 << 24) | (1 << 30) | 0x200);
    for (var i = 0; i < 6; i++) {
      expect(s.iopMem.read32(0x4000 + i * 4), 0x100 + i);
    }
    expect(s.ee.sif.sif1Fifo, isEmpty);
  });

  test('SIF0 delivers IOP data to EE memory', () {
    final s = _System();
    // IOP chain tag at 0x100: data at 0x200, 5 words, end; EE tag: end tag,
    // 2 quads to EE address 0x3000
    s.iopMem.write32(0x100, 0x200 | (1 << 31));
    s.iopMem.write32(0x104, 5);
    s.iopMem.write32(0x108, 2 | (7 << 28));
    s.iopMem.write32(0x10c, 0x3000);
    for (var i = 0; i < 5; i++) {
      s.iopMem.write32(0x200 + i * 4, 0x50 + i);
    }
    // the EE channel is started first and has to wait
    s.bus.write32(_sif0, (1 << 8) | (1 << 2));
    expect(s.bus.read32(_sif0) & 0x100, 0x100);
    s.iop.write(0x1f801500 + 0x10 * 2 + 0xc, 4, 0x100);
    s.iop.write(0x1f801500 + 0x10 * 2 + 8, 4, (1 << 24) | (1 << 10));
    s.ee.dmac.service();
    for (var i = 0; i < 5; i++) {
      expect(s.bus.read32(0x3000 + i * 4), 0x50 + i);
    }
    expect(s.bus.read32(_sif0) & 0x100, 0);
  });

  test('mailbox flags are set by one side and cleared by the other', () {
    final s = _System();
    s.iop.write(0x1d000030, 4, 0x30000); // IOP sets SMFLG
    expect(s.bus.read32(0x1000f230), 0x30000);
    s.bus.write32(0x1000f230, 0x10000); // the EE clears a bit
    expect(s.bus.read32(0x1000f230), 0x20000);
    s.bus.write32(0x1000f220, 0x8); // the EE sets MSFLG
    expect(s.iop.read(0x1d000020, 4), 8);
    s.iop.write(0x1d000020, 4, 0x8);
    expect(s.iop.read(0x1d000020, 4), 0);
  });

  test('IOP interrupts need I_MASK and I_CTRL', () {
    final s = _System();
    s.iop.raise(IopIrq.dma);
    expect(s.iop.asserted, false);
    s.iop.write(0x1f801074, 4, 1 << IopIrq.dma);
    s.iop.write(0x1f801078, 4, 1);
    expect(s.iop.asserted, true);
    s.iop.write(0x1f801070, 4, ~(1 << IopIrq.dma));
    expect(s.iop.asserted, false);
  });

  test('IOP timer reaches its target and raises an interrupt', () {
    final s = _System();
    s.iop.write(0x1f801108, 4, 100); // timer 0 target... base 0x1f801100
    s.iop.write(0x1f801100 + 8, 4, 100);
    s.iop.write(0x1f801100 + 4, 4, 0x18); // IRQ at target, reset at target
    s.iop.advanceTimers(150);
    expect(s.iop.stat & (1 << IopIrq.timer0), isNot(0));
    expect(s.iop.read(0x1f801100, 4), 50);
  });
}

void cdvdTests() {
  test('CDVD reports ready and answers S commands', () {
    final s = _System();
    expect(s.iop.read(0x1f402005, 1), 0x4e);
    expect(s.iop.read(0x1f402017, 1), 0x40);
    s.iop.write(0x1f402016, 1, 0x03);
    expect(s.iop.read(0x1f402017, 1), 0);
    expect(s.iop.read(0x1f402018, 1), 0);
    expect(s.iop.read(0x1f402017, 1), 0x40);
  });
}

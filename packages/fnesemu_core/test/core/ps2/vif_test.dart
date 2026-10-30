import 'package:fnesemu_core/src/core/ps2/bus.dart';
import 'package:fnesemu_core/src/core/ps2/ee_io.dart';
import 'package:fnesemu_core/src/core/ps2/r5900/r5900.dart';
import 'package:test/test.dart';

const _upperNop = 0x000002ff, _lowerNop = 0x8000033c;

(Ps2Bus, EeIo) _setup() {
  final bus = Ps2Bus();
  final io = EeIo(bus);
  bus.io = io;
  return (bus, io);
}

/// feeds 32-bit words to a VIF through its FIFO window
void _send(Ps2Bus bus, int fifo, List<int> words) {
  final padded = [...words];
  while (padded.length % 4 != 0) {
    padded.add(0);
  }
  for (var i = 0; i < padded.length; i += 4) {
    bus.write64(fifo, padded[i] | (padded[i + 1] << 32));
    bus.write64(fifo + 8, padded[i + 2] | (padded[i + 3] << 32));
  }
}

void main() {
  const fifo1 = 0x10005000;

  test('UNPACK V4-32 writes vectors to VU1 data memory', () {
    final (bus, io) = _setup();
    _send(bus, fifo1, [
      0x6c000000 | (2 << 16), // UNPACK V4-32, num 2, address 0
      1, 2, 3, 4, 5, 6, 7, 8,
    ]);
    expect(io.vu1.data.sublist(0, 8), [1, 2, 3, 4, 5, 6, 7, 8]);
  });

  test('UNPACK S-8 signed replicates a byte', () {
    final (bus, io) = _setup();
    _send(bus, fifo1, [0x62000000 | (1 << 16) | 4, 0xff]);
    expect(io.vu1.data.sublist(16, 20), List.filled(4, 0xffffffff));
  });

  test('an interrupt bit raises VIF1 and stalls the next code until STC', () {
    final (bus, io) = _setup();
    _send(bus, fifo1, [
      0x81000101, // STCYCL 1, 1 with the interrupt bit
      0x07000005, // MARK 5 runs during the stall
      0x01000404, // STCYCL 4, 4 waits
    ]);
    expect(io.intc.stat & (1 << 5), isNot(0));
    expect(io.vif1.mark, 5);
    expect(io.vif1.cl, 1);
    expect(bus.read32(0x10003c00) & 0xc00, 0xc00);
    bus.write32(0x10003c10, 8); // FBRST: STC
    expect(io.vif1.cl, 4);
    expect(bus.read32(0x10003c00) & 0xc00, 0);
  });

  test('ERR.MII disables the interrupt bit', () {
    final (bus, io) = _setup();
    bus.write32(0x10003c20, 1);
    _send(bus, fifo1, [0x81000101, 0x01000404]);
    expect(io.intc.stat & (1 << 5), 0);
    expect(io.vif1.cl, 4);
  });

  test('MPG loads microcode and MSCAL runs it', () {
    final (bus, io) = _setup();
    // program: ADDx vf1 = vf0 + vf0 (upper, E bit) is overkill; use a plain
    // pair that terminates immediately via the E bit
    _send(bus, fifo1, [
      0x4a000000 | (2 << 16), // MPG, 2 doublewords at address 0
      _lowerNop, _upperNop | (1 << 30),
      _lowerNop, _upperNop,
      0x14000000, // MSCAL 0
    ]);
    expect(io.vu1.micro[0], _lowerNop);
    expect(io.vu1.micro[1], _upperNop | (1 << 30));
  });

  test('COP2 moves between GPRs, VU0 registers and control registers', () {
    final bus = Ps2Bus();
    final io = EeIo(bus);
    bus.io = io;
    final cpu = R5900(bus)..vu0 = io.vu0;
    cpu.gpr[2 * 8] = 0x1111111122222222;
    cpu.gpr[2 * 8 + 1] = 0x3333333344444444;
    // QMTC2 t0, vf5 ; QMFC2 t1, vf5 ; CTC2 t0, vi3 ; CFC2 t2, vi3
    int cop2(int rs, int rt, int rd) =>
        (0x12 << 26) | (rs << 21) | (rt << 16) | (rd << 11);
    final code = [
      cop2(5, 8, 5),
      cop2(1, 9, 5),
      cop2(6, 8, 3),
      cop2(2, 10, 3),
    ];
    for (var i = 0; i < code.length; i++) {
      bus.write32(i * 4, code[i]);
    }
    cpu.pc = 0;
    cpu.nextPc = 4;
    for (var i = 0; i < code.length; i++) {
      cpu.step();
    }
    expect(io.vu0.vf.sublist(20, 24),
        [0x22222222, 0x11111111, 0x44444444, 0x33333333]);
    expect(cpu.gpr[2 * 9], 0x1111111122222222);
    expect(io.vu0.vi[3], 0x2222);
    expect(cpu.gpr[2 * 10], 0x2222);
  });
}

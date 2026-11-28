import 'dart:async';
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

class _CaseSkip implements Exception {
  const _CaseSkip();
}

void main() {
  // Aggregated cases: the per-case tests of this file are collected
  // in this table and executed by the aggregated test(s) at the end of
  // main; every case name stays visible here and in the run output.
  final aggCases = <(String, FutureOr<void> Function())>[];
  final aggTeardowns = <void Function()>[];
  void aggCase(String name, FutureOr<void> Function() body) =>
      aggCases.add((name, body));
  Future<void> runAggCases(
      Iterable<(String, FutureOr<void> Function())> cases) async {
    for (final (name, body) in cases) {
      print('case: $name');
      try {
        await body();
      } on _CaseSkip {
        print('skipped: $name');
      } finally {
        for (final teardown in aggTeardowns) {
          teardown();
        }
        aggTeardowns.clear();
      }
    }
  }

  const fifo1 = 0x10005000;

  aggCase('UNPACK V4-32 writes vectors to VU1 data memory', () {
    final (bus, io) = _setup();
    _send(bus, fifo1, [
      0x6c000000 | (2 << 16), // UNPACK V4-32, num 2, address 0
      1, 2, 3, 4, 5, 6, 7, 8,
    ]);
    expect(io.vu1.data.sublist(0, 8), [1, 2, 3, 4, 5, 6, 7, 8]);
  });

  aggCase('UNPACK S-8 signed replicates a byte', () {
    final (bus, io) = _setup();
    _send(bus, fifo1, [0x62000000 | (1 << 16) | 4, 0xff]);
    expect(io.vu1.data.sublist(16, 20), List.filled(4, 0xffffffff));
  });

  aggCase('UNPACK formats, modes and skipping writes match a model', () {
    const rowInit = [0x10, 0xfffffff0, 0x7fffffff, 3];
    for (final fmt in [0, 1, 2, 4, 5, 6, 8, 9, 10, 12, 13, 14]) {
      for (final unsigned in [false, true]) {
        for (final mode in [0, 1, 2]) {
          for (final (cl, wl) in [(1, 1), (4, 4), (3, 2)]) {
            final (bus, io) = _setup();
            io.vu1.data.fillRange(0, 64, 0xdeadbeef);
            final comps = (fmt >> 2) + 1, bits = 32 >> (fmt & 3);
            const num = 5;
            final words = List<int>.generate(
                (num * comps * bits + 31) >> 5,
                (k) => (0x9e3779b9 * (k + 1) + fmt * 0x01010101) & 0xffffffff);
            _send(bus, fifo1, [
              0x30000000, ...rowInit, // STROW
              0x05000000 | mode, // STMOD
              0x01000000 | wl << 8 | cl, // STCYCL
              (0x60 | fmt) << 24 | num << 16 | (unsigned ? 1 << 14 : 0),
              ...words,
            ]);
            final expected = List<int>.filled(64, 0xdeadbeef);
            final row = List.of(rowInit);
            var pos = 0;
            int element() {
              var v = (words[pos >> 5] >>> (pos & 31)) &
                  (bits == 32 ? 0xffffffff : (1 << bits) - 1);
              if (bits < 32 && !unsigned) v = v.toSigned(bits) & 0xffffffff;
              pos += bits;
              return v;
            }

            for (var i = 0; i < num; i++) {
              final dest = (i ~/ wl) * cl + i % wl;
              final e = [for (var c = 0; c < comps; c++) element()];
              for (var c = 0; c < 4; c++) {
                var v = comps == 1 ? e[0] : (c < comps ? e[c] : 0);
                if (mode != 0) v = (v + row[c]) & 0xffffffff;
                if (mode == 2) row[c] = v;
                expected[dest * 4 + c] = v;
              }
            }
            expect(io.vu1.data.sublist(0, 64), expected,
                reason: 'fmt $fmt unsigned $unsigned mode $mode cl $cl wl $wl');
            expect(io.vif1.row, row, reason: 'row of fmt $fmt mode $mode');
          }
        }
      }
    }
  });

  aggCase('a filling write reads CL of WL vectors and fills the rest', () {
    final (bus, io) = _setup();
    _send(bus, fifo1, [
      0x30000000, 9, 9, 9, 9, // STROW 9
      0x20000000, 0x5500, // STMASK: the second vector of a cycle takes ROW
      0x01000201, // STCYCL CL 1, WL 2
      0x7c040000, // UNPACK V4-32 with mask, num 4, address 0
      1, 2, 3, 4, 5, 6, 7, 8,
      0x07000003, // MARK 3 follows the two data vectors
    ]);
    expect(io.vu1.data.sublist(0, 16), [
      1, 2, 3, 4, 9, 9, 9, 9, //
      5, 6, 7, 8, 9, 9, 9, 9,
    ]);
    expect(io.vif1.mark, 3);
  });

  aggCase('an interrupt bit raises VIF1 and stalls the next code until STC', () {
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

  aggCase('STP stalls after the current code and FBK at once', () {
    final (bus, io) = _setup();
    bus.write32(0x10003c10, 4); // STP while idle
    _send(bus, fifo1, [0x07000001]);
    expect(io.vif1.mark, 0);
    expect(bus.read32(0x10003c00) & 0x300, 0x100);
    bus.write32(0x10003c10, 8);
    expect(io.vif1.mark, 1);
    bus.write32(0x10003c10, 2); // FBK
    _send(bus, fifo1, [0x07000002]);
    expect(io.vif1.mark, 1);
    expect(bus.read32(0x10003c00) & 0x300, 0x200);
    bus.write32(0x10003c10, 8);
    expect(io.vif1.mark, 2);
  });

  aggCase('an undefined code stalls with ER1 unless ME1 is set', () {
    final (bus, io) = _setup();
    _send(bus, fifo1, [0x08000000, 0x07000003]);
    expect(io.vif1.mark, 0);
    expect(bus.read32(0x10003c00) & (1 << 13), isNonZero);
    bus.write32(0x10003c10, 8);
    expect(io.vif1.mark, 3);
    bus.write32(0x10003c20, 4); // ME1
    _send(bus, fifo1, [0x08000000, 0x07000004]);
    expect(io.vif1.mark, 4);
  });


  aggCase('MSKPATH3 sets the PATH3 mask of the GIF', () {
    final (bus, io) = _setup();
    _send(bus, fifo1, [0x06008000]);
    expect(bus.read32(0x10003020) & 2, 2);
    _send(bus, fifo1, [0x06000000]);
    expect(bus.read32(0x10003020) & 2, 0);
  });


  aggCase('MPG loads microcode and MSCAL runs it', () {
    final (bus, io) = _setup();
    // program: ADDx vf1 = vf0 + vf0 (upper, E bit) is overkill; use a plain
    // pair that terminates immediately via the E bit
    _send(bus, fifo1, [
      0x4a000000 | (2 << 16), // MPG, 2 doublewords at address 0
      _lowerNop, _upperNop | (1 << 30),
      _lowerNop, _upperNop,
      0x14000000, // MSCAL 0
    ]);
    expect(io.vu1.readMicro(0), _lowerNop);
    expect(io.vu1.readMicro(1), _upperNop | (1 << 30));
  });

  aggCase('COP2 moves between GPRs, VU0 registers and control registers', () {
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

  const chunkCount = 1;
  final chunkSize = (aggCases.length + chunkCount - 1) ~/ chunkCount;
  for (var part = 0; part < chunkCount; part++) {
    final partCases =
        aggCases.skip(part * chunkSize).take(chunkSize).toList();
    if (partCases.isEmpty) continue;
    test('aggregated cases ${part + 1} of $chunkCount', () async {
      await runAggCases(partCases);
    }, timeout: const Timeout(Duration(minutes: 10)));
  }
}

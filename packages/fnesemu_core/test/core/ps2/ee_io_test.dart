import 'package:fnesemu_core/src/core/ps2/bus.dart';
import 'package:fnesemu_core/src/core/ps2/dmac.dart';
import 'package:fnesemu_core/src/core/ps2/ee_io.dart';
import 'package:fnesemu_core/src/core/ps2/intc.dart';
import 'package:test/test.dart';

const _timer0 = 0x10000000, _timer1 = 0x10000800;
const _dmaCtrl = 0x1000e000, _dmaStat = 0x1000e010;

(Ps2Bus, EeIo) _setup() {
  final bus = Ps2Bus();
  final io = EeIo(bus);
  bus.io = io;
  return (bus, io);
}

int _tag(int qwc, int id, int addr, {bool irq = false}) =>
    qwc | (id << 28) | (irq ? 1 << 31 : 0) | (addr << 32);

void main() {
  gsDmaTests();
  group('INTC', () {
    test('I_STAT clears and I_MASK toggles on write', () {
      final (bus, io) = _setup();
      io.intc.raise(Intc.vblankStart);
      expect(bus.read32(0x1000f000), 1 << 2);
      bus.write32(0x1000f010, 1 << 2);
      expect(io.intc.asserted, isTrue);
      bus.write32(0x1000f000, 1 << 2);
      expect(io.intc.asserted, isFalse);
      bus.write32(0x1000f010, 1 << 2);
      expect(bus.read32(0x1000f010), 0);
    });
  });

  test('byte accesses reach a part of a 32-bit register', () {
    final (bus, io) = _setup();
    bus.write32(0x1000a000, 0x0001); // D2_CHCR without STR
    bus.write32(0x1000e020, 0x12345678); // D_PCR
    expect(bus.read8(0x1000a001), 0);
    expect(bus.read8(0x1000e022), 0x34);
    expect(bus.read16(0x1000e022), 0x1234);
    bus.write8(0x1000e021, 0xab);
    expect(io.dmac.pcr, 0x1234ab78);
    // the bytes a narrow write to D_STAT does not cover are left alone
    io.dmac.stat = 0x5;
    bus.write8(0x1000e010, 0x4);
    expect(io.dmac.stat, 0x1);
    bus.write8(0x1000e012, 0x4);
    expect(io.dmac.stat, 0x40001);
  });

  test('LABEL sets the masked bits of LBLID, read as the upper word', () {
    final (bus, io) = _setup();
    io.gs.writeRegister(0x60, 0x0000ffff00001234); // SIGNAL
    io.gs.writeRegister(0x62, 0x000000ff00000056); // LABEL
    io.gs.writeRegister(0x62, 0x0000ff0000003400); // LABEL
    expect(bus.read32(0x12001080), 0x1234);
    expect(bus.read32(0x12001084), 0x3456);
    bus.write32(0x12001084, 0x99);
    expect(io.gs.siglblid, 0x0000009900001234);
  });

  group('timers', () {
    test('count at the bus clock only while enabled', () {
      final (bus, io) = _setup();
      io.timers.advance(10);
      expect(bus.read32(_timer0), 0);
      bus.write32(_timer0 + 0x10, 0x80);
      io.timers.advance(10);
      expect(bus.read32(_timer0), 10);
    });

    test('prescalers divide the bus clock', () {
      final (bus, io) = _setup();
      bus.write32(_timer0 + 0x10, 0x81); // bus / 16
      io.timers.advance(40);
      expect(bus.read32(_timer0), 2);
      io.timers.advance(8);
      expect(bus.read32(_timer0), 3);
    });

    test('compare raises its interrupt and zero return clears the count', () {
      final (bus, io) = _setup();
      bus.write32(_timer1 + 0x20, 100);
      bus.write32(_timer1 + 0x10, 0x80 | 0x40 | 0x100);
      io.timers.advance(250);
      expect(io.intc.stat & (1 << (Intc.timer0 + 1)), isNonZero);
      expect(bus.read32(_timer1), 50);
      expect(bus.read32(_timer1 + 0x10) & (1 << 10), isNonZero);
      bus.write32(_timer1 + 0x10, 0x80 | 0x40 | 0x100 | (1 << 10));
      expect(bus.read32(_timer1 + 0x10) & (1 << 10), 0);
    });

    test('overflow is detected in a large step', () {
      final (bus, io) = _setup();
      bus.write32(_timer0 + 0x10, 0x80 | 0x200);
      bus.write32(_timer0, 0xfff0);
      io.timers.advance(0x20);
      expect(bus.read32(_timer0), 0x10);
      expect(bus.read32(_timer0 + 0x10) & (1 << 11), isNonZero);
      expect(io.intc.stat & (1 << Intc.timer0), isNonZero);
    });

    test('hblank clocked timers count scanlines', () {
      final (bus, io) = _setup();
      bus.write32(_timer0 + 0x10, 0x83);
      io.timers.advance(1000);
      io.timers.hblank();
      io.timers.hblank();
      expect(bus.read32(_timer0), 2);
    });
  });

  group('DMAC', () {
    void enable(Ps2Bus bus) => bus.write32(_dmaCtrl, 1);

    test('normal mode copies memory to the scratchpad', () {
      final (bus, io) = _setup();
      enable(bus);
      for (var i = 0; i < 4; i++) {
        bus.write64(0x2000 + i * 8, 0x1111 * (i + 1));
      }
      bus.write32(0x1000d480, 0x40); // SADR
      bus.write32(0x1000d410, 0x2000); // MADR
      bus.write32(0x1000d420, 2); // QWC
      bus.write32(0x1000d400, 0x100); // STR
      expect(bus.read64(0x70000040), 0x1111);
      expect(bus.read64(0x70000058), 0x4444);
      expect(io.dmac.channels[9].qwc, 0);
      expect(bus.read32(0x1000d400) & 0x100, 0);
      expect(bus.read32(_dmaStat) & (1 << 9), isNonZero);
    });

    test('a transfer does not start while DMAE is clear', () {
      final (bus, _) = _setup();
      bus.write32(0x1000d410, 0x2000);
      bus.write32(0x1000d420, 1);
      bus.write64(0x2000, 7);
      bus.write32(0x1000d400, 0x100);
      expect(bus.read64(0x70000000), 0);
    });

    test('the interrupt follows CIS and CIM', () {
      final (bus, io) = _setup();
      enable(bus);
      bus.write32(0x1000d410, 0x2000);
      bus.write32(0x1000d420, 1);
      bus.write32(0x1000d400, 0x100);
      expect(io.dmac.asserted, isFalse);
      bus.write32(_dmaStat, 1 << (16 + 9)); // unmask channel 9
      expect(io.dmac.asserted, isTrue);
      bus.write32(_dmaStat, 1 << 9); // clear CIS
      expect(io.dmac.asserted, isFalse);
    });

    test('source chain follows cnt, ref and end tags to a device', () {
      final (bus, io) = _setup();
      enable(bus);
      final received = <int>[];
      io.dmac.endpoints[Dmac.gif] = _Collector(received);
      // tag 0 at 0x1000: cnt, 1 quadword follows at 0x1010
      bus.write64(0x1000, _tag(1, 1, 0));
      bus.write64(0x1010, 0xa1);
      // tag at 0x1020: ref, 1 quadword at 0x3000
      bus.write64(0x1020, _tag(1, 3, 0x3000));
      bus.write64(0x3000, 0xb1);
      // tag at 0x1030: end, 1 quadword follows
      bus.write64(0x1030, _tag(1, 7, 0));
      bus.write64(0x1040, 0xc1);
      bus.write32(0x1000a030, 0x1000); // TADR of the GIF channel
      bus.write32(0x1000a000, 0x104); // STR, chain mode
      expect(received, [0xa1, 0xb1, 0xc1]);
      // the channel finishes one bus clock per quadword later
      io.dmac.advance(2);
      expect(bus.read32(0x1000a000) & 0x100, isNonZero);
      io.dmac.advance(1);
      expect(bus.read32(0x1000a000) & 0x100, 0);
      expect(bus.read32(_dmaStat) & 4, isNonZero);
    });

    test('a source chain to the scratchpad transfers the tags with TTE', () {
      final (bus, _) = _setup();
      enable(bus);
      bus.write64(0x1000, _tag(1, 3, 0x3000)); // ref
      bus.write64(0x3000, 0xb1);
      bus.write64(0x1010, _tag(1, 0, 0x3010)); // refe
      bus.write64(0x3010, 0xb2);
      bus.write32(0x1000d480, 0x100); // SADR
      bus.write32(0x1000d430, 0x1000); // TADR
      bus.write32(0x1000d400, 0x104); // STR, chain mode
      expect(bus.read64(0x70000100), 0xb1);
      expect(bus.read64(0x70000110), 0xb2);
      bus.write32(0x1000d480, 0x200);
      bus.write32(0x1000d430, 0x1000);
      bus.write32(0x1000d400, 0x144); // with TTE
      expect(bus.read64(0x70000200), _tag(1, 3, 0x3000));
      expect(bus.read64(0x70000210), 0xb1);
      expect(bus.read64(0x70000220), _tag(1, 0, 0x3010));
      expect(bus.read64(0x70000230), 0xb2);
    });

    test('a masked PATH3 keeps 16 quadwords in the GIF FIFO', () {
      final (bus, io) = _setup();
      enable(bus);
      // one packet: a tag that writes PRIM 5, then 19 NOP quadwords
      bus.write64(0x2000, 19 | (1 << 15) | (1 << 46) | (5 << 47) | (1 << 60));
      bus.write64(0x2008, 0xf);
      bus.write32(0x10003010, 1); // GIF_MODE: mask PATH3
      bus.write32(0x1000a010, 0x2000);
      bus.write32(0x1000a020, 20);
      bus.write32(0x1000a000, 0x100);
      io.dmac.advance(100);
      expect(io.gs.prim, 0);
      expect(bus.read32(0x10003020) >> 24, 16);
      expect(bus.read32(0x1000a000) & 0x100, isNonZero);
      bus.write32(0x10003010, 0);
      io.dmac.advance(100);
      expect(io.gs.prim, 5);
      expect(bus.read32(0x10003020) >> 24, 0);
      expect(bus.read32(0x1000a000) & 0x100, 0);
    });

    test('VIF1 waits at FLUSHA until PATH3 finishes', () {
      final (bus, io) = _setup();
      enable(bus);
      // PATH3: one GIF packet of 2 quadwords
      bus.write64(0x2000, 1 | (1 << 15) | (1 << 60));
      bus.write64(0x2008, 0xe);
      bus.write64(0x2010, 0x123);
      bus.write64(0x2018, 0x3f); // TEXFLUSH
      bus.write32(0x1000a010, 0x2000);
      bus.write32(0x1000a020, 2);
      bus.write32(0x1000a000, 0x100);
      // VIF1: FLUSHA, then MARK 5
      bus.write32(0x3000, 0x13000000);
      bus.write32(0x3004, 0x07000005);
      bus.write32(0x3008, 0);
      bus.write32(0x300c, 0);
      bus.write32(0x10009010, 0x3000);
      bus.write32(0x10009020, 1);
      bus.write32(0x10009000, 0x101);
      expect(io.vif1.mark, 0);
      io.dmac.advance(2);
      expect(io.vif1.mark, 5);
    });

    test('the MFIFO drain follows fromSPR through the ring', () {
      final (bus, io) = _setup();
      final received = <int>[];
      io.dmac.endpoints[Dmac.gif] = _Collector(received);
      bus.write32(_dmaCtrl, 1 | 3 << 2); // GIF drains the MFIFO
      bus.write32(0x1000e050, 0x10000); // RBOR
      bus.write32(0x1000e040, 0x30); // RBSR: 4 quadwords
      bus.write32(0x1000d010, 0x10000); // fromSPR MADR
      bus.write32(0x1000a030, 0x10000);
      bus.write32(0x1000a000, 0x104); // the ring is empty
      expect(received, isEmpty);
      expect(bus.read32(_dmaStat) & 1 << 14, isNonZero);

      void fromSpr(int sadr, List<int> quads) {
        for (var i = 0; i < quads.length; i++) {
          bus.write64(0x70000000 + sadr + i * 16, quads[i]);
        }
        bus.write32(0x1000d080, sadr);
        bus.write32(0x1000d020, quads.length);
        bus.write32(0x1000d000, 0x100);
      }

      fromSpr(0, [_tag(1, 1, 0), 0xa1]);
      expect(received, [0xa1]);
      // the packet wraps at the end of the ring
      fromSpr(0x20, [_tag(2, 1, 0), 0xb1, 0xb2]);
      expect(received, [0xa1, 0xb1, 0xb2]);
      expect(bus.read64(0x10000), 0xb2);
      expect(io.dmac.channels[Dmac.fromSpr].madr, 0x10010);
      expect(io.dmac.channels[Dmac.gif].tadr, 0x10010);
      expect(bus.read32(0x1000a000) & 0x100, isNonZero);
    });

    test('call and ret use the address stack', () {
      final (bus, io) = _setup();
      enable(bus);
      final received = <int>[];
      io.dmac.endpoints[Dmac.gif] = _Collector(received);
      bus.write64(0x1000, _tag(1, 5, 0x2000)); // call 0x2000, data at 0x1010
      bus.write64(0x1010, 1);
      bus.write64(0x2000, _tag(1, 6, 0)); // ret, data at 0x2010
      bus.write64(0x2010, 2);
      bus.write64(0x1020, _tag(1, 7, 0)); // end after returning
      bus.write64(0x1030, 3);
      bus.write32(0x1000a030, 0x1000);
      bus.write32(0x1000a000, 0x104);
      expect(received, [1, 2, 3]);
    });

    test('a REFS packet of the stall drain waits for D_STADR', () {
      final (bus, io) = _setup();
      bus.write32(_dmaCtrl, 1 | 2 << 6); // GIF is the stall drain
      final received = <int>[];
      io.dmac.endpoints[Dmac.gif] = _Collector(received);
      bus.write64(0x1000, _tag(1, 4, 0x2000)); // refs 0x2000
      bus.write64(0x1010, _tag(1, 4, 0x2010)); // refs 0x2010
      bus.write64(0x1020, _tag(0, 7, 0)); // end
      bus.write64(0x2000, 1);
      bus.write64(0x2010, 2);
      bus.write32(0x1000e060, 0x2000); // D_STADR
      bus.write32(0x1000a030, 0x1000);
      bus.write32(0x1000a000, 0x104);
      expect(received, isEmpty);
      expect(bus.read32(_dmaStat) & 1 << 13, isNonZero);
      bus.write32(0x1000e060, 0x2010);
      expect(received, [1]);
      expect(bus.read32(0x1000a000) & 0x100, isNonZero);
      bus.write32(0x1000e060, 0x2020);
      expect(received, [1, 2]);
      io.dmac.advance(16);
      expect(bus.read32(0x1000a000) & 0x100, 0);
    });

    test('the stall source moves D_STADR', () {
      final (bus, io) = _setup();
      bus.write32(_dmaCtrl, 1 | 2 << 4 | 2 << 6); // fromSPR to GIF
      final received = <int>[];
      io.dmac.endpoints[Dmac.gif] = _Collector(received);
      bus.write64(0x1000, _tag(1, 4, 0x2000)); // refs 0x2000
      bus.write64(0x1010, _tag(0, 7, 0));
      bus.write32(0x1000e060, 0x2000);
      bus.write32(0x1000a030, 0x1000);
      bus.write32(0x1000a000, 0x104);
      expect(received, isEmpty);
      bus.write64(0x70000000, 7);
      bus.write32(0x1000d010, 0x2000); // fromSPR MADR
      bus.write32(0x1000d020, 1);
      bus.write32(0x1000d000, 0x100);
      expect(bus.read32(0x1000e060), 0x2010);
      expect(received, [7]);
    });

    test('a tag with IRQ stops a chain when TIE is set', () {
      final (bus, io) = _setup();
      enable(bus);
      final received = <int>[];
      io.dmac.endpoints[Dmac.gif] = _Collector(received);
      bus.write64(0x1000, _tag(1, 1, 0, irq: true));
      bus.write64(0x1010, 9);
      bus.write64(0x1020, _tag(1, 7, 0));
      bus.write64(0x1030, 10);
      bus.write32(0x1000a030, 0x1000);
      bus.write32(0x1000a000, 0x104 | 0x80);
      expect(received, [9]);
    });

    test('a chain started with QWC transfers it before the tag at TADR', () {
      final (bus, io) = _setup();
      enable(bus);
      final received = <int>[];
      final gate = _Gate(received)..room = 1;
      io.dmac.endpoints[Dmac.toIpu] = gate;
      bus.write64(0x1000, _tag(3, 3, 0x3000)); // ref
      bus.write64(0x1010, _tag(1, 7, 0)); // end
      bus.write64(0x1020, 0xc1);
      for (var i = 0; i < 3; i++) {
        bus.write64(0x3000 + i * 16, 0xa1 + i);
      }
      bus.write32(0x1000b430, 0x1000);
      bus.write32(0x1000b400, 0x105);
      expect(received, [0xa1]);
      // the tag was read: TADR points past it
      expect(bus.read32(0x1000b430), 0x1010);
      expect(bus.read32(0x1000b410), 0x3010);

      // stop and start again from the saved registers
      final chcr = bus.read32(0x1000b400);
      final qwc = bus.read32(0x1000b420);
      bus.write32(0x1000b400, chcr & ~0x100);
      bus.write32(0x1000b410, 0x3010);
      bus.write32(0x1000b420, qwc);
      gate.room = 10;
      bus.write32(0x1000b400, chcr);
      expect(received, [0xa1, 0xa2, 0xa3, 0xc1]);
      expect(bus.read32(0x1000b400) & 0x100, 0);
    });
  });
}

/// takes [room] quadwords, then waits
class _Gate extends DmaEndpoint {
  final List<int> received;
  int room = 0;
  _Gate(this.received);

  @override
  bool get canPut => room > 0;

  @override
  void put(int low, int high) {
    received.add(low);
    room--;
  }
}

class _Collector extends DmaEndpoint {
  final List<int> received;
  _Collector(this.received);

  @override
  void put(int low, int high) => received.add(low);
}

void gsDmaTests() {
  for (final tte in [false, true]) {
    test(
        'a DMA chain through the GIF draws into local memory'
        '${tte ? ' and skips the tags with TTE' : ''}', () {
      final (bus, io) = _setup();
      bus.write32(_dmaCtrl, 1);
      // GS setup through A+D: FRAME_1 and XYOFFSET_1
      var a = 0x2000;
      void qw(int lo, int hi) {
        bus.write64(a, lo);
        bus.write64(a + 8, hi);
        a += 16;
      }

      // DMA tag: cnt, 5 quadwords follow
      qw(6 | (1 << 28), 0);
      qw(2 | (1 << 15) | (1 << 60), 0xe); // GIF tag: A+D
      qw(0 | (1 << 16) | (0 << 24), 0x4c); // FRAME_1: FBW 1
      qw((63 << 16) | (63 << 48), 0x40); // SCISSOR_1
      // second GIF packet: sprite via PACKED PRIM(PRE) + RGBAQ + XYZ2 x2
      qw(1 | (1 << 15) | (1 << 46) | (6 << 47) | (3 << 60), 0x551);
      qw(0x40 | (0x50 << 32), 0x60 | (0x80 << 32));
      qw(0, 0);
      // DMA tag: end, 1 quadword for the last vertex
      qw(1 | (7 << 28), 0);
      qw((2 * 16) | ((2 * 16) << 32), 0); // XYZ2 (offset still zero)
      bus.write32(0x1000a030, 0x2000);
      bus.write32(0x1000a000, tte ? 0x144 : 0x104);
      expect(io.gs.contexts[0].frame & 0xffffffff, 1 << 16);
      expect(io.gs.mem.read(0, 0, 1, 1, 1), 0x80605040);
      expect(io.gs.mem.read(0, 0, 1, 2, 2), 0);
    });
  }
}

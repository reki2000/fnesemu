import 'package:fnesemu/util/int.dart';

import 'bus.dart';

/// per-channel DMA/HDMA register state. the same 8 registers serve both
/// general DMA and HDMA (real hardware reuses them; see class doc on [Dma]).
class DmaChannel {
  int dmap = 0; // $43n0: direction/indirect/inc-dec/pattern
  int bbad = 0; // $43n1: B-bus address low byte (page $21xx)
  int a1tAddr = 0; // $43n2/3: A-bus 16-bit address
  int a1bBank = 0; // $43n4: A-bus bank
  int dasLen = 0; // $43n5/6: DMA byte count; HDMA indirect addr low16
  int dasbBank = 0; // $43n7: HDMA indirect address bank
  int a2aAddr = 0; // $43n8/9: HDMA table current address (within a1bBank)
  int ntrl = 0; // $43na: HDMA line-counter byte (bit7=repeat, bits0-6=count)

  bool hdmaActive = false;
  int linesRemaining = 0;
  final lineBuf = List<int>.filled(4, 0);
}

/// DMA/HDMA controller covering $4300-$437F plus the $420B/$420C triggers.
///
/// General DMA ($420B): performed instantly (no CPU/DMA cycle interleaving)
/// when triggered; an approximate cycle cost is added to the CPU clock so
/// frame timing stays roughly plausible.
///
/// HDMA ($420C): processed once per scanline via [hdmaScanline], called from
/// Snes.exec() right before that line renders, so PPU registers it writes
/// (scroll, color math, mode7 matrix, etc.) take effect for that line.
class Dma {
  final Bus bus;
  Dma(this.bus);

  final channels = List.generate(8, (_) => DmaChannel());
  int hdmaEnableMask = 0;

  // B-bus offset pattern per dmap's 3-bit transfer-mode field. Patterns 6/7
  // are undocumented and alias 0/1 (common convention; rarely if ever used).
  static const _pattern = [
    [0],
    [0, 1],
    [0, 0],
    [0, 0, 1, 1],
    [0, 1, 2, 3],
    [0, 1, 0, 1],
    [0],
    [0, 1],
  ];

  void reset() {
    for (final c in channels) {
      c.dmap = 0;
      c.bbad = 0;
      c.a1tAddr = 0;
      c.a1bBank = 0;
      c.dasLen = 0;
      c.dasbBank = 0;
      c.a2aAddr = 0;
      c.ntrl = 0;
      c.hdmaActive = false;
      c.linesRemaining = 0;
    }
    hdmaEnableMask = 0;
  }

  // -------------------------------------------------------- $4300-$437F
  void write(int addr, int val) {
    val &= 0xff;
    final c = channels[(addr.shr4) & 0x07];
    switch (addr & 0x0f) {
      case 0x0:
        c.dmap = val;
        break;
      case 0x1:
        c.bbad = val;
        break;
      case 0x2:
        c.a1tAddr = c.a1tAddr.setL8(val);
        break;
      case 0x3:
        c.a1tAddr = c.a1tAddr.setH8(val);
        break;
      case 0x4:
        c.a1bBank = val;
        break;
      case 0x5:
        c.dasLen = c.dasLen.setL8(val);
        break;
      case 0x6:
        c.dasLen = c.dasLen.setH8(val);
        break;
      case 0x7:
        c.dasbBank = val;
        break;
      case 0x8:
        c.a2aAddr = c.a2aAddr.setL8(val);
        break;
      case 0x9:
        c.a2aAddr = c.a2aAddr.setH8(val);
        break;
      case 0xa:
        c.ntrl = val;
        break;
      default:
        break; // $43nb-$43nf: unused
    }
  }

  int read(int addr) {
    final c = channels[(addr.shr4) & 0x07];
    switch (addr & 0x0f) {
      case 0x0:
        return c.dmap;
      case 0x1:
        return c.bbad;
      case 0x2:
        return c.a1tAddr.mask8;
      case 0x3:
        return c.a1tAddr.shr8;
      case 0x4:
        return c.a1bBank;
      case 0x5:
        return c.dasLen.mask8;
      case 0x6:
        return c.dasLen.shr8;
      case 0x7:
        return c.dasbBank;
      case 0x8:
        return c.a2aAddr.mask8;
      case 0x9:
        return c.a2aAddr.shr8;
      case 0xa:
        return c.ntrl;
      default:
        return 0;
    }
  }

  // ---------------------------------------------- general DMA ($420B)
  void runDma(int enableMask) {
    int totalBytes = 0;
    for (int ch = 0; ch < 8; ch++) {
      if (!enableMask.bit(ch)) continue;
      final c = channels[ch];
      final pattern = _pattern[c.dmap & 0x07];
      final fromPpu = c.dmap.bit7; // 1 = B-bus -> A-bus (read PPU)
      final fixed = c.dmap.bit3;
      final decrement = c.dmap.bit4;

      int aAddr = c.a1tAddr;
      final count = c.dasLen == 0 ? 0x10000 : c.dasLen;
      totalBytes += count;

      for (int i = 0; i < count; i++) {
        final bAddr = 0x2100 | ((c.bbad + pattern[i % pattern.length]) & 0xff);
        final aFull = (c.a1bBank.shl16) | aAddr;
        if (fromPpu) {
          bus.write(aFull, bus.read(bAddr));
        } else {
          bus.write(bAddr, bus.read(aFull));
        }
        if (!fixed) {
          aAddr = (decrement ? aAddr.dec : aAddr.inc) & 0xffff;
        }
      }
      c.a1tAddr = aAddr;
      c.dasLen = 0;
    }
    // approximate timing: ~8 master cycles/byte + per-channel overhead,
    // converted to the CPU's own cycle units (master/6, see Snes.cpuClock)
    bus.cpu.cycle += (totalBytes * 8) ~/ 6;
  }

  // -------------------------------------------------------------- HDMA
  /// called once per frame, right before scanline 0 is processed.
  void hdmaInit() {
    for (int ch = 0; ch < 8; ch++) {
      final c = channels[ch];
      if (!hdmaEnableMask.bit(ch)) {
        c.hdmaActive = false;
        continue;
      }
      c.a2aAddr = c.a1tAddr;
      c.hdmaActive = true;
      _readEntry(c);
    }
  }

  void _readEntry(DmaChannel c) {
    final raw = bus.read((c.a1bBank.shl16) | c.a2aAddr);
    c.a2aAddr = c.a2aAddr.inc.mask16;
    if (raw == 0) {
      c.hdmaActive = false;
      return;
    }
    c.ntrl = raw;
    c.linesRemaining = (raw & 0x7f) == 0 ? 128 : (raw & 0x7f);

    if (c.dmap.bit6) {
      // indirect: the next 2 bytes are a pointer (combined with dasbBank)
      final lo = bus.read((c.a1bBank.shl16) | c.a2aAddr);
      c.a2aAddr = c.a2aAddr.inc.mask16;
      final hi = bus.read((c.a1bBank.shl16) | c.a2aAddr);
      c.a2aAddr = c.a2aAddr.inc.mask16;
      c.dasLen = lo | hi.shl8;
    }

    if (!raw.bit7) {
      // non-repeat: fetch this entry's data once now; held for every line
      _fetchLineData(c);
    }
  }

  void _fetchLineData(DmaChannel c) {
    final pattern = _pattern[c.dmap & 0x07];
    final indirect = c.dmap.bit6;
    final srcBank = indirect ? c.dasbBank : c.a1bBank;
    final srcAddr = indirect ? c.dasLen : c.a2aAddr;
    for (int k = 0; k < pattern.length; k++) {
      c.lineBuf[k] = bus.read((srcBank.shl16) | ((srcAddr + k) & 0xffff));
    }
    if (indirect) {
      c.dasLen = (c.dasLen + pattern.length) & 0xffff;
    } else {
      c.a2aAddr = (c.a2aAddr + pattern.length) & 0xffff;
    }
  }

  /// called once per scanline (0..224), right before that line renders.
  void hdmaScanline() {
    for (int ch = 0; ch < 8; ch++) {
      final c = channels[ch];
      if (!c.hdmaActive) continue;

      final pattern = _pattern[c.dmap & 0x07];
      if (c.ntrl.bit7) _fetchLineData(c); // repeat: fresh data every line

      for (int k = 0; k < pattern.length; k++) {
        final bAddr = 0x2100 | ((c.bbad + pattern[k]) & 0xff);
        bus.write(bAddr, c.lineBuf[k]);
      }

      c.linesRemaining--;
      if (c.linesRemaining <= 0) _readEntry(c);
    }
  }
}

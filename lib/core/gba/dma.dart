import 'package:fnesemu/util/int.dart';

import 'bus.dart';
import 'irq.dart';

/// GBA DMA controller (4 channels, registers 0x40000B0..0x40000DF).
///
/// Stage 3 implements immediate, VBlank and HBlank timing with block transfers.
/// Sound FIFO (special) timing for channels 1/2 is wired in Stage 5; video
/// capture (channel 3 special) is not supported yet.
class Dma {
  final Bus bus;
  final Irq irq;
  Dma(this.bus, this.irq);

  // programmed registers (built up from 16-bit writes)
  final _src = List<int>.filled(4, 0); // SAD
  final _dst = List<int>.filled(4, 0); // DAD
  final _count = List<int>.filled(4, 0); // CNT_L
  final _control = List<int>.filled(4, 0); // CNT_H

  // internal latched values used during a transfer
  final _srcLatch = List<int>.filled(4, 0);
  final _dstLatch = List<int>.filled(4, 0);
  final _countLatch = List<int>.filled(4, 0);

  static const _timingImmediate = 0;
  static const _timingVBlank = 1;
  static const _timingHBlank = 2;
  static const _timingSpecial = 3;

  int _timing(int ch) => (_control[ch] >> 12) & 3;

  // --- register access (offset relative to 0xb0) ----------------------------

  int read16(int reg) {
    final ch = (reg - 0xb0) ~/ 12;
    final within = (reg - 0xb0) % 12;
    // SAD/DAD/CNT_L are write-only; only CNT_H reads back.
    return within == 10 ? _control[ch] : 0;
  }

  void write16(int reg, int data) {
    final ch = (reg - 0xb0) ~/ 12;
    final within = (reg - 0xb0) % 12;
    data &= 0xffff;
    switch (within) {
      case 0:
        _src[ch] = _src[ch].setL16(data);
        break;
      case 2:
        _src[ch] = _src[ch].setH16(data);
        break;
      case 4:
        _dst[ch] = _dst[ch].setL16(data);
        break;
      case 6:
        _dst[ch] = _dst[ch].setH16(data);
        break;
      case 8:
        _count[ch] = data;
        break;
      case 10:
        final wasEnabled = _control[ch].bit15;
        _control[ch] = data;
        if (!wasEnabled && data.bit15) {
          _latch(ch);
          if (_timing(ch) == _timingImmediate) _transfer(ch);
        }
        break;
    }
  }

  void _latch(int ch) {
    _srcLatch[ch] = _src[ch] & (ch == 0 ? 0x07ffffff : 0x0fffffff);
    _dstLatch[ch] = _dst[ch] & (ch == 3 ? 0x0fffffff : 0x07ffffff);
    _countLatch[ch] = _maskedCount(ch);
  }

  int _maskedCount(int ch) {
    final max = ch == 3 ? 0x10000 : 0x4000;
    final c = _count[ch] & (max - 1);
    return c == 0 ? max : c;
  }

  void _transfer(int ch) {
    final ctrl = _control[ch];
    final word = ctrl.bit10; // 0=16bit, 1=32bit
    final dstCtrl = (ctrl >> 5) & 3;
    final srcCtrl = (ctrl >> 7) & 3;
    final step = word ? 4 : 2;

    int src = _srcLatch[ch];
    int dst = _dstLatch[ch];
    final count = _countLatch[ch];

    for (int i = 0; i < count; i++) {
      if (word) {
        bus.write32(dst, bus.read32(src));
      } else {
        bus.write16(dst, bus.read16(src));
      }
      src = (src + _delta(srcCtrl, step)).mask32;
      dst = (dst + _delta(dstCtrl, step)).mask32;
    }

    // source always advances; destination keeps its value unless it reloads
    _srcLatch[ch] = src;
    if (dstCtrl != 3) _dstLatch[ch] = dst;

    if (ctrl.bit14) irq.raise(IrqBit.dma0 + ch);

    final repeat = ctrl.bit9;
    if (!repeat || _timing(ch) == _timingImmediate) {
      _control[ch] = ctrl & ~0x8000; // clear enable
    } else {
      // repeating DMA: reload count, and the destination too in mode 3
      _countLatch[ch] = _maskedCount(ch);
      if (dstCtrl == 3) {
        _dstLatch[ch] = _dst[ch] & (ch == 3 ? 0x0fffffff : 0x07ffffff);
      }
    }
  }

  int _delta(int ctrl, int step) => switch (ctrl) {
        1 => -step, // decrement
        2 => 0, // fixed
        _ => step, // 0=increment, 3=increment+reload (src 3 prohibited)
      };

  void _triggerTiming(int timing) {
    for (int ch = 0; ch < 4; ch++) {
      if (_control[ch].bit15 && _timing(ch) == timing) {
        _transfer(ch);
      }
    }
  }

  void onVBlank() => _triggerTiming(_timingVBlank);
  void onHBlank() => _triggerTiming(_timingHBlank);

  /// the APU asks for a FIFO refill: any enabled channel 1/2 in special timing
  /// whose destination is [fifoAddr] transfers four 32-bit words (dest fixed).
  void requestSoundFifo(int fifoAddr) {
    final dest = fifoAddr & 0x0fffffff;
    for (int ch = 1; ch <= 2; ch++) {
      final ctrl = _control[ch];
      if (!ctrl.bit15 || _timing(ch) != _timingSpecial) continue;
      if ((_dst[ch] & 0x0fffffff) != dest) continue;

      final srcCtrl = (ctrl >> 7) & 3;
      int src = _srcLatch[ch];
      for (int i = 0; i < 4; i++) {
        bus.write32(fifoAddr, bus.read32(src));
        src = (src + _delta(srcCtrl, 4)).mask32;
      }
      _srcLatch[ch] = src;
      if (ctrl.bit14) irq.raise(IrqBit.dma0 + ch);
    }
  }

  void reset() {
    for (int ch = 0; ch < 4; ch++) {
      _src[ch] = 0;
      _dst[ch] = 0;
      _count[ch] = 0;
      _control[ch] = 0;
      _srcLatch[ch] = 0;
      _dstLatch[ch] = 0;
      _countLatch[ch] = 0;
    }
  }
}

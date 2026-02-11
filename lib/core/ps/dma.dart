import 'package:fnesemu/util/int.dart';

import '../../util/debug.dart';
import 'bus.dart';
import 'interrupt.dart';

class DmaChannel {
  final int ioAddr;
  final int ch;

  final int clocks;

  int _startAddr = 0;
  int get startAddr => _startAddr;
  set startAddr(int value) {
    _startAddr = value;
    addr = value & 0x7ffffc;
  }

  int get blockCtrl => size | amount << 16;
  set blockCtrl(int value) {
    size = value & 0xffff;
    if (size == 0) {
      size = 0x10000;
    }
    initialSize = size;
    amount = value >> 16;
  }

  int _channelCtrl = 0;
  int get channelCtrl => _channelCtrl.setBit(24, running);

  set channelCtrl(int value) {
    _channelCtrl = value;
    syncMode = value >> 9 & 0x03;
    toRam = !value.bit0;
    incr = value.bit1 ? -4 : 4;
    running = value.bit24;
  }

  int syncMode = 0;
  int size = 0;
  int initialSize = 0;
  int amount = 0;
  int addr = 0;

  bool enabled = false;

  bool running = false;

  bool useInterrupt = false;
  bool interruptOnChunks = false;

  bool toRam = false;
  int incr = 0;

  DmaChannel(this.ch, this.ioAddr, this.clocks);

  void reset() {
    _startAddr = 0;
    _channelCtrl = 0;
    size = 0;
    initialSize = 0;
    amount = 0;
    addr = 0;
    enabled = false;
    running = false;
    useInterrupt = false;
    interruptOnChunks = false;
    toRam = false;
    incr = 0;
  }

  String dump() => "DMA$ch: ${running ? "R" : "-"} "
      "${enabled ? "E" : "-"} "
      "${useInterrupt ? "I" : "-"}${interruptOnChunks ? "C" : "-"}  "
      "${toRam ? "->${addr.hex32}" : "${addr.hex32}->"} "
      "mode:$syncMode sz:${size.hex24} am:${amount.hex16} incr:$incr "
      "c:${_channelCtrl.hex32} bl:${blockCtrl.hex32} sa:${startAddr.hex32}";
}

class Dma {
  Bus bus; // Bus reference - will be injected

  Dma(this.bus);

  final List<DmaChannel> channels = [
    DmaChannel(0, 0x1f801820, 1),
    DmaChannel(1, 0x1f801820, 1),
    DmaChannel(2, 0x1f801810, 1),
    DmaChannel(3, 1, 24),
    DmaChannel(4, 1, 4),
    DmaChannel(5, 0, 20),
    DmaChannel(6, 1, 1)
  ];

  int _control = 0;
  int get control => _control;
  set control(int value) {
    _control = value;
    for (var ch = 0; ch < 7; ch++) {
      channels[ch].enabled = (value >> (3 + ch * 4)).bit0;

      // debugLog(
      //     "DMA$ch: controlled   ${channels[ch].dump()} pc:${bus.cpu.pc.hex32} ra:${bus.cpu.r[31].hex32} clk:${bus.gpu.frame}:${bus.gpu.scanline}:${bus.cpu.clocks}");
    }
  }

  int _interrupt = 0;
  int get interrupt => _interrupt;
  set interrupt(int value) {
    final irqFlags = _interrupt &
        0x7f000000 &
        ~(value & 0x7f000000); // reset flags at value = 1
    final bit31 = value.bit15 ||
        (value.bit23 && (irqFlags >> 24 & value >> 16 & 0x7f) != 0);
    _interrupt = irqFlags | (value & 0x00ff807f).setBit(31, bit31);

    for (var ch = 0; ch < 7; ch++) {
      final modeMask = 0x00001 << ch;
      final useMask = 0x10000 << ch;
      channels[ch].useInterrupt = value & useMask != 0 && value.bit23;
      channels[ch].interruptOnChunks = value & modeMask != 0;
    }
  }

  void reset() {
    control = 0;
    interrupt = 0;
    for (var ch = 0; ch < 7; ch++) {
      channels[ch].reset();
    }
  }

  void transfer32(int ch, DmaChannel d) {
    switch (ch) {
      case 0:
        if (!d.toRam && bus.mdec.dataInAck) {
          final data = bus.read32(d.addr);
          // debugLog(
          //     "DMA0: MDEC DMA [${d.addr.hex32}]=0x${data.hex32} ${d.dump()}");
          bus.mdec.writeCommand(data);
        }

      case 1:
        if (d.toRam && bus.mdec.dataOutAck) {
          bus.write32(d.addr, bus.mdec.readData());
        }

      case 3:
        // CDROM
        // debugLog("DMA3: CDROM DMA ${d.dump()}");
        if (d.toRam) {
          bus.write16(d.addr, bus.cdrom.readBuffer16());
          bus.write16(d.addr.inc2, bus.cdrom.readBuffer16());
        }

      case 4:
        if (d.toRam) {
          bus.write16(d.addr, bus.spu.readFifo16());
          bus.write16(d.addr.inc2, bus.spu.readFifo16());
        } else {
          bus.spu.writeFifo16(bus.read16(d.addr));
          bus.spu.writeFifo16(bus.read16(d.addr.inc2));
        }

      default:
        d.toRam
            ? bus.write32(d.addr, bus.read32(d.ioAddr))
            : bus.write32(d.ioAddr, bus.read32(d.addr));
    }
  }

  void exec(int count) {
    for (int ch = 0; ch < 7; ch++) {
      final d = channels[ch];

      if (!d.enabled || !d.running) {
        continue;
      }

      // debugLog("DMA$ch: started   ${d.dump()} ra:${bus.cpu.r[31].hex32}");

      if (ch == 6) {
        // OTC
        if (d.syncMode != 0 || !d.toRam) {
          continue;
        }

        for (d.size--; d.size > 0; d.size--) {
          final writeAddr = d.addr;
          d.addr = d.addr.dec4 & 0x1ffffc;
          bus.write32(writeAddr, d.addr);
        }

        bus.write32(d.addr, 0xffffff);
        completeDma(ch);
        continue;
      }

      switch (d.syncMode) {
        case 0: // Burst
          while (count > 0) {
            transfer32(ch, d);
            d.addr += d.incr;

            d.size--;
            if (d.size <= 0) {
              completeDma(ch);
              break;
            }

            count -= d.clocks;
          }

        case 1: // Slice
          while (count > 0) {
            transfer32(ch, d);
            d.addr += d.incr;

            d.size--;
            if (d.size <= 0) {
              d.amount--;

              if (d.amount <= 0) {
                completeDma(ch);
                break;
              }

              completeDma(ch, partial: true);

              d.size = d.initialSize;
            }

            count -= d.clocks;
          }

        case 2: // Linked List
          while (d.addr.mask24 != 0xffffff) {
            final node = bus.read32(d.addr);

            if (node == 0) {
              debugLog(
                  "DMA$ch: node is zero. aborted. ${d.dump()} ra:${bus.cpu.r[31].hex32}");
              break;
            }

            for (int i = 0; i < node >> 24; i++) {
              d.addr = (d.addr + d.incr) & 0x1ffffc;
              final val = bus.read32(d.addr);
              bus.write32(d.ioAddr, val);
            }

            d.addr = node.mask24;

            completeDma(ch, partial: true);
          }

          completeDma(ch);
      }
    }
  }

  void completeDma(int ch, {bool partial = false}) {
    final d = channels[ch];

    if (!partial) {
      d.running = false;

      // if (ch == 0 || ch == 1 || ch == 3) {
      //   // MDEC
      //   debugLog(
      //       "DMA$ch: completed ${_control.hex32} ${_interrupt.hex32} ${d.dump()}");
      // }
    }

    if (d.useInterrupt && (!partial || d.interruptOnChunks)) {
      _interrupt = _interrupt.setBit(24 + ch, true);
      // debugLog(
      //     "DMA$ch: irq cnt:${_control.hex32} int:${_interrupt.hex32} ${d.dump()}");
      bus.setIrq(Interrupt.dma);
    }
  }
}

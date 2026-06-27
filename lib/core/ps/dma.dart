import 'package:fnesemu/util/debug.dart';
import 'package:fnesemu/util/int.dart';
import 'bus.dart';
import 'interrupt.dart';

const List<int> debugLogChannel = [];

class DmaChannel {
  final int ioAddr;
  final int ch;

  final int clocks;

  int priority = 0;

  int _startAddr = 0;
  int get startAddr => _startAddr;
  set startAddr(int value) {
    _startAddr = value;
    addr = value & 0x7ffffc;
  }

  int get blockCtrl => size | amount.shl16;
  set blockCtrl(int value) {
    size = value & 0xffff;
    if (size == 0) {
      size = 0x10000;
    }
    initialSize = size;
    amount = value.shr16;
  }

  int _channelCtrl = 0;
  int get channelCtrl => _channelCtrl.setBit(24, running);

  set channelCtrl(int value) {
    _channelCtrl = value & 0x71770703;

    syncMode = value.shr9 & 0x03;
    toRam = !value.bit0;
    incr = value.bit1 ? -4 : 4;
    if (ch == 6) {
      syncMode = 0;
      toRam = true;
      incr = -4;
    }

    running = value.bit24 && (syncMode == 0 ? value.bit28 : true);
    if (running && (debugLogChannel.contains(ch))) {
      debugLog("DMA$ch: started   ${dump()} ");
    }
  }

  int syncMode = 0;
  int size = 0;
  int initialSize = 0;
  int amount = 0;
  int addr = 0;

  bool enabled = false;

  bool running = false;

  bool irqOnComplete = false;
  bool irqOnChunks = false;

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
    irqOnComplete = false;
    irqOnChunks = false;
    toRam = false;
    incr = 0;
    priority = 0;
  }

  String dump() => "DMA$ch: pr:$priority ${running ? "R" : "-"} "
      "${enabled ? "E" : "-"} "
      "${irqOnComplete ? "I" : "-"}${irqOnChunks ? "C" : "-"}  "
      "${toRam ? "->${addr.x8}" : "${addr.x8}->"} "
      "mode:$syncMode sz:${size.x6} am:${amount.x4} incr:$incr "
      "c:${_channelCtrl.x8} bl:${blockCtrl.x8} sa:${startAddr.x8}";
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
      channels[ch].enabled = value.bit3;
      channels[ch].priority = value & 0x07;
      value >>= 4;
      // debugLog(
      //     "DMA$ch: controlled   ${channels[ch].dump()} pc:${bus.cpu.pc.x8} ra:${bus.cpu.r[31].x8}");
    }
  }

  int _interrupt = 0;
  int get interrupt => _interrupt.setBit(31, _bit31());
  void setInterrupt(int addr, int value) {
    _interrupt = switch (addr) {
      0 ||
      1 ||
      2 =>
        _interrupt.masked(0xff.shl(addr.shl3), value.shl(addr.shl3)),
      3 => _interrupt & (~value.shl24 | 0xffffff),
      _ =>
        throw "illegal DMA interrupt addr:${addr.x8} value:${value.x8}",
    };
    // debugLog(
    //     "DMA: interrupt set addr:$addr value:${value.x2} -> ${_interrupt.x8} ");

    for (var ch = 0; ch < 7; ch++) {
      channels[ch].irqOnComplete = _interrupt.bit(ch + 16);
      channels[ch].irqOnChunks = _interrupt.bit(ch);
    }
  }

  bool _irqPending = false;

  bool _bit31() =>
      _interrupt.bit15 || (_interrupt.bit23 && (_interrupt & 0x7f000000) != 0);

  void reset() {
    for (var ch = 0; ch < 7; ch++) {
      channels[ch].reset();
    }
    control = 0x07654321;
    _interrupt = 0;
    _irqPending = false;
  }

  bool transfer32(int ch, DmaChannel d) {
    switch (ch) {
      case 0:
        if (!d.toRam) {
          if (!bus.mdec.dataInAck) {
            return false;
          }
          final data = bus.read32(d.addr);
          // debugLog(
          //     "DMA0: MDEC DMA [${d.addr.x8}]=0x${data.x8} ${d.dump()}");
          bus.mdec.writeCommand(data);
        }

      case 1:
        if (d.toRam) {
          if (!bus.mdec.dataOutAck) {
            return false;
          }
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

    return true;
  }

  void exec(int count) {
    // find highest priority channel
    for (final d in channels) {
      if (!d.enabled || !d.running) {
        continue;
      }

      if (d.ch == 6) {
        // OTC
        for (d.size--; d.size > 0; d.size--) {
          final writeAddr = d.addr;
          d.addr = d.addr.dec4 & 0x1ffffc;
          bus.write32(writeAddr, d.addr);
        }

        bus.write32(d.addr, 0xffffff);
        completeDma(d.ch);
        continue;
      }

      switch (d.syncMode) {
        case 0: // Burst.
          while (count > 0) {
            transfer32(d.ch, d);
            d.addr += d.incr;

            d.size--;
            if (d.size <= 0) {
              completeDma(d.ch);
              break;
            }
            // count -= d.clocks; // dma should lock the bus
          }

        case 1: // Slice
          while (count > 0) {
            if (!transfer32(d.ch, d)) {
              break;
            }
            d.addr += d.incr;

            d.size--;
            if (d.size <= 0) {
              d.amount--;

              if (d.amount <= 0) {
                completeDma(d.ch);
                break;
              }

              d.size = d.initialSize;
              if (d.ch == 1) {
                break; // hack for chopping
              }
            }
            // count -= d.clocks; // dma should lock the bus
          }

        case 2: // Linked List
          while (d.addr.mask24 != 0xffffff) {
            final node = bus.read32(d.addr);

            if (node == 0) {
              debugLog(
                  "DMA${d.ch}: node is zero. aborted. ${d.dump()} ra:${bus.cpu.r[31].x8}");
              break;
            }

            for (int i = 0; i < node.shr24; i++) {
              d.addr = (d.addr + d.incr) & 0x1ffffc;
              final val = bus.read32(d.addr);
              bus.write32(d.ioAddr, val);
            }

            d.addr = node.mask24;
          }
          // debugLog(
          //     "DMA${d.ch}: completed linked list. ${d.dump()} ra:${bus.cpu.r[31].x8}");

          completeDma(d.ch);
      }
    }

    if (_irqPending) {
      _irqPending = false;
      bus.setIrq(Interrupt.dma);
    }
  }

  void completeDma(int ch) {
    final d = channels[ch];

    d.running = false;

    // if (ch == 1) {
    //   debugLog("dma: complete ch1, mdec:${bus.mdec.dump()} ");
    // }
    if (debugLogChannel.contains(ch)) {
      debugLog(
          "DMA$ch: completed ${d.dump()} ctl:${_control.x8} int:${_interrupt.x8} ");
    }

    if (d.irqOnComplete) {
      _interrupt = _interrupt.setBit(24 + ch, true);
      _irqPending = _bit31();
    }
    // bus.setIrq(Interrupt.dma);
    // if (!oldBit31 && _bit31()) {
    //   // debugLog(
    //   //     "DMA$ch: irq cnt:${_control.x8} int:${_interrupt.x8} ${d.dump()}");
    //   irqPending = true;
    // }
  }
}

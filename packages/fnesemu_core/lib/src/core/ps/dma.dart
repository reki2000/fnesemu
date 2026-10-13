import '../../util/debug.dart';
import '../../util/int.dart';
import 'bus.dart';
import 'interrupt.dart';

final _log = DebugLog('ps.dma');

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
    size = value.mask16;
    if (size == 0) {
      size = 0x10000;
    }
    initialSize = size;
    amount = value.shr16;
  }

  int _channelCtrl = 0;
  int get channelCtrl => _channelCtrl.setBit(24, running);

  set channelCtrl(int value) {
    // OTC: only bit24, 28, 30 are writable, bit1 is always set
    _channelCtrl = ch == 6 ? value & 0x51000000 | 0x02 : value & 0x71770703;

    syncMode = value.shr9.mask2;
    toRam = !value.bit0;
    incr = value.bit1 ? -4 : 4;
    if (ch == 6) {
      syncMode = 0;
      toRam = true;
      incr = -4;
    }

    running = value.bit24 && (syncMode == 0 ? value.bit28 : true);
    if (running) {
      _channelCtrl &= ~0x10000000; // start trigger is cleared when started
    }
    if (running && (debugLogChannel.contains(ch))) {
      _log.debugc(() => "DMA$ch: started   ${dump()} ");
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

  final List<DmaChannel> channels = List.of([
    DmaChannel(0, 0x1f801820, 1),
    DmaChannel(1, 0x1f801820, 1),
    DmaChannel(2, 0x1f801810, 1),
    DmaChannel(3, 1, 24),
    DmaChannel(4, 1, 4),
    DmaChannel(5, 0, 20),
    DmaChannel(6, 1, 1),
  ], growable: false);

  /// false when no channel is enabled and running, [exec] has nothing to do
  bool _active = true;

  /// writes the channel control register of [ch], which may start it
  void setChannelCtrl(int ch, int value) {
    channels[ch].channelCtrl = value;
    _active = true;
  }

  int _control = 0;
  int get control => _control;
  set control(int value) {
    _control = value;
    _active = true;
    for (var ch = 0; ch < 7; ch++) {
      channels[ch].enabled = value.bit3;
      channels[ch].priority = value.mask3;
      value >>= 4;
      // _log.debugc(() =>
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
      _ => throw "illegal DMA interrupt addr:${addr.x8} value:${value.x8}",
    };
    // _log.debugc(() =>
    //     "interrupt set addr:$addr value:${value.x2} -> ${_interrupt.x8} ");

    for (var ch = 0; ch < 7; ch++) {
      channels[ch].irqOnComplete = _interrupt.bit(ch + 16);
      channels[ch].irqOnChunks = _interrupt.bit(ch);
    }
  }

  bool _irqPending = false;

  bool _bit31() =>
      _interrupt.bit15 ||
      (_interrupt.bit23 && (_interrupt.shr8 & _interrupt & 0x7f0000) != 0);

  void reset() {
    for (var ch = 0; ch < 7; ch++) {
      channels[ch].reset();
    }
    control = 0x07654321;
    _interrupt = 0;
    _irqPending = false;
    _active = true;
  }

  bool transfer32(int ch, DmaChannel d) {
    switch (ch) {
      case 0:
        if (!d.toRam) {
          if (!bus.mdec.dataInAck) {
            return false;
          }
          final data = bus.read32(d.addr);
          // _log.debugc(() =>
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
        // _log.debugc(() => "DMA3: CDROM DMA ${d.dump()}");
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
    if (!_active) {
      return;
    }

    // find highest priority channel
    final channels = this.channels;
    for (int ch = 0; ch < channels.length; ch++) {
      final d = channels[ch];
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
            d.addr = (d.addr + d.incr) & 0x1ffffc;

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
            d.addr = (d.addr + d.incr) & 0x1ffffc;

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
          while (!d.addr.bit23) {
            final node = bus.read32(d.addr);

            if (node == 0) {
              _log.debugc(() =>
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
          // _log.debugc(() =>
          //     "DMA${d.ch}: completed linked list. ${d.dump()} ra:${bus.cpu.r[31].x8}");

          completeDma(d.ch);
      }
    }

    _active = false;
    for (int ch = 0; ch < channels.length; ch++) {
      if (channels[ch].enabled && channels[ch].running) {
        _active = true;
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
    //   _log.debugc(() => "complete ch1, mdec:${bus.mdec.dump()} ");
    // }
    if (debugLogChannel.contains(ch)) {
      _log.debugc(() =>
          "DMA$ch: completed ${d.dump()} ctl:${_control.x8} int:${_interrupt.x8} ");
    }

    if (d.irqOnComplete) {
      final prev = _bit31();
      _interrupt = _interrupt.setBit(24 + ch, true);
      // irq is raised on the rising edge of the master flag
      if (!prev && _bit31()) {
        _irqPending = true;
      }
    }
    // bus.setIrq(Interrupt.dma);
    // if (!oldBit31 && _bit31()) {
    //   // _log.debugc(() =>
    //   //     "DMA$ch: irq cnt:${_control.x8} int:${_interrupt.x8} ${d.dump()}");
    //   irqPending = true;
    // }
  }
}

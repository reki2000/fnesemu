part of 'bus.dart';

extension DmaController on Bus {
  void transfer32(int ch, Dma d) {
    switch (ch) {
      case 0:
        if (!d.toRam && mdec.dataInAck) {
          final data = read32(d.addr);
          // debugLog(
          //     "DMA0: MDEC DMA [${d.addr.hex32}]=0x${data.hex32} ${d.dump()}");
          mdec.writeCommand(data);
        }

      case 1:
        if (d.toRam && mdec.dataOutAck) {
          write32(d.addr, mdec.readData());
        }

      case 3:
        // CDROM
        // debugLog("DMA3: CDROM DMA ${d.dump()}");
        if (d.toRam) {
          write16(d.addr, cdrom.readBuffer16());
          write16(d.addr.inc2, cdrom.readBuffer16());
        }

      case 4:
        if (d.toRam) {
          write16(d.addr, spu.readFifo16());
          write16(d.addr.inc2, spu.readFifo16());
        } else {
          spu.writeFifo16(read16(d.addr));
          spu.writeFifo16(read16(d.addr.inc2));
        }

      default:
        d.toRam
            ? write32(d.addr, read32(d.ioAddr))
            : write32(d.ioAddr, read32(d.addr));
    }
  }

  void execDma(int count) {
    for (int ch = 0; ch < 7; ch++) {
      final d = dma[ch];

      if (!d.enabled || !d.running) {
        continue;
      }

      // debugLog("DMA$ch: started   ${d.dump()} ra:${cpu.r[31].hex32}");

      if (ch == 6) {
        // OTC
        if (d.syncMode != 0 || !d.toRam) {
          continue;
        }

        for (d.size--; d.size > 0; d.size--) {
          final writeAddr = d.addr;
          d.addr = d.addr.dec4 & 0x1ffffc;
          write32(writeAddr, d.addr);
        }

        write32(d.addr, 0xffffff);
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
            final node = read32(d.addr);

            if (node == 0) {
              debugLog(
                  "DMA$ch: node is zero. aborted. ${d.dump()} ra:${cpu.r[31].hex32}");
              break;
            }

            for (int i = 0; i < node >> 24; i++) {
              d.addr = (d.addr + d.incr) & 0x1ffffc;
              final val = read32(d.addr);
              write32(d.ioAddr, val);
            }

            d.addr = node.mask24;

            completeDma(ch, partial: true);
          }

          completeDma(ch);
      }
    }
  }

  void completeDma(int ch, {bool partial = false}) {
    final d = dma[ch];

    if (!partial) {
      d.running = false;

      // if (ch == 0 || ch == 1 || ch == 3) {
      //   // MDEC
      //   debugLog(
      //       "DMA$ch: completed ${_dmaControl.hex32} ${_dmaInterrupt.hex32} ${d.dump()}");
      // }
    }

    if (d.useInterrupt && (!partial || d.intterruptOnChunks)) {
      _dmaInterrupt = _dmaInterrupt.setBit(24 + ch, true);
      // debugLog(
      //     "DMA$ch: irq cnt:${_dmaControl.hex32} int:${_dmaInterrupt.hex32} ${d.dump()}");
      setIrq(Interrupt.dma);
    }
  }
}

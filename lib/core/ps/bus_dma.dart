part of 'bus.dart';

extension DmaController on Bus {
  void execDma(int count) {
    for (int ch = 0; ch < 7; ch++) {
      final d = dma[ch];

      if (d.ioAddr == 0) {
        continue;
      }

      if (!d.enabled || !d.running) {
        continue;
      }

      // debugLog("DMA$ch: started   ${d.dump()} ra:${cpu.r[31].hex32}");

      if (ch == 6) {
        if (d.syncMode != 0 || !d.toRam) {
          continue;
        }

        if (d.size == 0) {
          d.size = 0x10000;
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
        case 0:
          if (d.size == 0) d.size = 0x10000;
          while (d.size > 0) {
            if (ch == 4) {
              // SPU
              if (d.toRam) {
                write16(d.addr, spu.readFifo16());
                write16(d.addr.inc2, spu.readFifo16());
              } else {
                spu.writeFifo16(read16(d.addr));
                spu.writeFifo16(read16(d.addr.inc2));
              }
            } else if (ch == 3) {
              // CDROM
              // debugLog("DMA3: CDROM DMA ${d.dump()}");
              if (d.toRam) {
                write16(d.addr, cdrom.readBuffer16());
                write16(d.addr.inc2, cdrom.readBuffer16());
              }
            } else {
              d.toRam
                  ? write32(d.addr, read32(d.ioAddr))
                  : write32(d.ioAddr, read32(d.addr));
            }
            d.addr += d.incr;
            d.size--;
          }

          completeDma(ch);

        case 1:
          while (d.amount-- > 0) {
            for (int i = 0; i < d.size; i++) {
              d.toRam
                  ? write32(d.addr, read32(d.ioAddr))
                  : write32(d.ioAddr, read32(d.addr));
              d.addr += d.incr;
            }

            completeDma(ch, partial: true);
          }

          completeDma(ch);

        case 2:
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

      // if (ch == 3) {
      //   debugLog("DMA$ch: completed ${d.dump()}");
      // }
    }

    if (d.useInterrupt && (!partial || d.intterruptOnChunks)) {
      _dmaInterrupt.setBit(24 + ch, true);
      setIrq(Interrupt.dma);
    }
  }
}

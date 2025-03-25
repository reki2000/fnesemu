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

      // debugLog("DMA$ch: started   ${d.dump()}");

      // otc fills memory with 0xff
      if (ch == 6) {
        if (d.syncMode != 0 || !d.toRam) {
          continue;
        }

        if (d.size == 0) d.size = 0x10000;
        while (d.size > 1) {
          final writeAddr = d.addr;
          d.addr = (d.addr + d.incr) & 0x1ffffc;
          write32(writeAddr, d.addr);
          d.size--;
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
                write16(d.addr, spu.readRam16());
                write16(d.addr.inc2, spu.readRam16());
              } else {
                spu.writeFifo16(read16(d.addr));
                spu.writeFifo16(read16(d.addr.inc2));
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

            for (int i = 0; i < node >> 24; i++) {
              d.addr = (d.addr + d.incr) & 0x1ffffc;
              write32(d.ioAddr, read32(d.addr));
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
      // debugLog("DMA$ch: completed ${d.dump()}");
    }

    if (d.useInterrupt && (!partial || d.intterruptOnChunks)) {
      _dmaInterrupt.setBit(24 + ch, true);
    }
  }
}

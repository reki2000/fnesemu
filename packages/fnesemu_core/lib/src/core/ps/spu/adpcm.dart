part of 'voice.dart';

extension VoiceAdpcmDecoder on Voice {

  void decodeBlock() {
    final log = logCounter > 0 && _addr >= 0x1000;
    if (log) {
      _log.debugc(() =>
          "SPU${no.d2z}: addr:${_addr.x6} ram:${spu.ram.sublist(_addr, _addr + 16).map((e) => e.x2).join(" ")}");
    }

    spu.checkIrqRange(_addr, 16);
    final header = spu.ram[_addr] | spu.ram[_addr + 1].shl8;
    final loop = header.shr8;

    if (loop.bit2) {
      repeatAddr = _addr;
    }

    int shift = header.mask4;
    shift = (shift > 12) ? 9 : shift;

    final filter = header.shr4.mask3;

    final f = filter.min(4);
    final c1 = spuAdpcmFilter1[f], c2 = spuAdpcmFilter2[f];

    _addr += 2;

    for (int i = 0; i < Voice.blockOldSize; i++) {
      _block[i] = _block[i + Voice.blockSize];
    }

    for (int i = Voice.blockOldSize;
        i < Voice.blockSize + Voice.blockOldSize;
        i++) {
      final raw = spu.ram[_addr] >> (i.bit0 ? 4 : 0);
      final shifted = raw.rel4 << (12 - shift);
      final filtered =
          shifted + (c1 * _block[i - 1] + c2 * _block[i - 2] + 32).shr6;
      final val = filtered.clip(-0x8000, 0x7fff);
      if (log) {
        _log.debugc(() =>
            "SPU${no.d2z}: decode:$i raw:${raw.x2} shifted:$shifted filtered:$filtered val:$val");
      }

      _block[i] = val;

      if (i.bit0) {
        _addr++;
      }
    }

    if (loop.bit0) {
      endx = true;
      _addr = repeatAddr;
      if (!loop.bit1 && !noise) {
        adsrVolume = 0;
        keyOff();
      }
    }

    if (log) {
      _log.debugc(() =>
          "SPU${no.d2z}: addr:${_addr.x6} block:${_block.map((e) => e.x4).join(" ")}");
      logCounter--;
    }
  }

}

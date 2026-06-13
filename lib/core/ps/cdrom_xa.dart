part of 'cdrom.dart';

extension CdromXA on Cdrom {
  static const _xaFilters = [(0, 0), (60, 0), (115, -52), (98, -55)];

  // convert 4bit/8bit unsigned value to signed sample, then apply ADPCM decoding
  int decodeXaAdpcm(int value, int shift, int k0, int k1, int old, int older) {
    final s = (value << shift).rel16;

    // apply filter
    final sample = s + (old * k0 + older * k1 + 32) ~/ 64;

    // clip to 16bit signed
    return sample.max(-32768).min(32767);
  }

  void decodeXa() {
    isXaAdpcmBusy = false;

    final submode = rawSector[18];
    final codingInfo = rawSector[19];

    // audio(bit2) + real-time(bit6) must be set
    if (submode & 0x44 != 0x44) return;
    if (!isXaAdpcmEnabled) return;

    // debugLog("cdrom: decode XA ${dumpSector(sector)} "
    //     "submode=${submode.hex8} coding=${codingInfo.hex8} "
    //     "xaAdpcm=$isXaAdpcmEnabled filter=${isXaFilterEnabled ? "$file:$channel" : "no"}:${rawSector[16]}:${rawSector[17]}");

    // filter by channel/file
    if (isXaFilterEnabled &&
        (rawSector[16] != file || rawSector[17] != channel)) {
      return;
    }

    isXaAdpcmBusy = true;

    final isStereo = codingInfo & 0x03 == 1;
    xaSampleRate = (codingInfo >> 2 & 0x03) == 0 ? 37800 : 18900;
    final isSampleRate18900 = xaSampleRate == 18900;
    final is8bit = (codingInfo >> 4 & 0x03) == 1;

    final buf = List<int>.filled(28, 0);
    // final debugBuffer = [
    //   List<int>.empty(growable: true),
    //   List<int>.empty(growable: true)
    // ];

    // sector header: 12(sync) + 3(addr) + 1(mode) + 8(subheader×2) = 24
    // sector data: 18 packets of 128 bytes, 16 bytes header + 28 * 4 bytes data
    for (int packet = 0; packet < 18; packet++) {
      final packetBase = 24 + packet * 128;
      final packetData = rawSector.sublist(packetBase, packetBase + 128);

      for (int unit = 0; unit < (is8bit ? 4 : 8); unit++) {
        final param = packetData[4 + unit];
        final shift = 12 - (param.mask4 > 12 ? 9 : param.mask4);
        final filter = (param >> 4) & 0x03;
        final (k0, k1) = _xaFilters[filter];

        final oldIndex = !isStereo
            ? 0
            : unit.isEven
                ? 1
                : 2;

        // if (packet == 0 && unit == 0) {
        //   debugLog(
        //       "cdrom: xa: coding:${codingInfo.hex8} ${xaSampleRate}Hz ${is8bit ? "8" : "4"}bit "
        //       "${isStereo ? "stereo" : "mono  "} shift:$shift filter:$filter");
        // }

        for (int i = 0; i < 28; i++) {
          if (is8bit) {
            final byte = packetData[16 + i * 4 + unit];
            buf[i] = decodeXaAdpcm(
                byte.rel8, shift, k0, k1, xaOld[oldIndex], xaOldest[oldIndex]);
          } else {
            final byte = packetData[16 + i * 4 + unit ~/ 2];
            final data = unit.isEven ? byte.rel4 : byte.shr4.rel4;
            buf[i] = decodeXaAdpcm(
                data, shift, k0, k1, xaOld[oldIndex], xaOldest[oldIndex]);
          }
          xaOldest[oldIndex] = xaOld[oldIndex];
          xaOld[oldIndex] = buf[i];
        }

        // merge into xaBuffer, stereo: u0=L, u1=R ..., mono: all L=R
        if (isStereo) {
          if (unit.isEven) {
            resampler.pushInterpolated(audioBufferL, 0, buf, isSampleRate18900);
          } else {
            resampler.pushInterpolated(audioBufferR, 1, buf, isSampleRate18900);
          }
          // debugBuffer[unit.isEven ? 0 : 1].addAll(buf);
        } else {
          resampler.pushInterpolated(audioBufferL, 0, buf, isSampleRate18900);
          resampler.pushInterpolated(audioBufferR, 1, buf, isSampleRate18900);
        }
      }
    }

    // // write to xa.wav file : ffplay.exe -f s16le -ar 37800 -ac 2 xa.wav
    // File("trace/xa.wav").writeAsBytes(
    //   Uint16List.fromList(List.generate(debugBuffer[0].length,
    //               (i) => [debugBuffer[0][i], debugBuffer[1][i]])
    //           .expand((l) => [l[0], l[1]])
    //           .toList())
    //       .buffer
    //       .asUint8List(),
    //   mode: FileMode.append,
    // );
  }

  //
}

class XaResampler {
  static // 7 x 29
      const zigzagTables = [
    [
      0x0000, 0x0000, 0x0000, 0x0000, 0x0000, -0x0002, 0x000A, -0x0022, 0x0041,
      -0x0054, 0x0034, 0x0009, -0x010A, 0x0400, -0x0A78, //
      0x234C, 0x6794, -0x1780, 0x0BCD, -0x0623, 0x0350, -0x016D, 0x006B, 0x000A,
      -0x0010, 0x0011, -0x0008, 0x0003, -0x0001, //
    ],
    [
      0x0000, 0x0000, 0x0000, -0x0002, 0x0000, 0x0003, -0x0013, 0x003C, -0x004B,
      0x00A2, -0x00E3, 0x0132, -0x0043, -0x0267, 0x0C9D, //
      0x74BB, -0x11B4, 0x09B8, -0x05BF, 0x0372, -0x01A8, 0x00A6, -0x001B,
      0x0005,
      0x0006, -0x0008, 0x0003, -0x0001, 0x0000, //
    ],
    [
      0x0000, 0x0000, -0x0001, 0x0003, -0x0002, -0x0005, 0x001F, -0x004A,
      0x00B3,
      -0x0192, 0x02B1, -0x039E, 0x04F8, -0x05A6, 0x7939, //
      -0x05A6, 0x04F8, -0x039E, 0x02B1, -0x0192, 0x00B3, -0x004A, 0x001F,
      -0x0005,
      -0x0002, 0x0003, -0x0001, 0x0000, 0x0000, //
    ],
    [
      0x0000, -0x0001, 0x0003, -0x0008, 0x0006, 0x0005, -0x001B, 0x00A6,
      -0x01A8,
      0x0372, -0x05BF, 0x09B8, -0x11B4, 0x74BB, 0x0C9D, //
      -0x0267, -0x0043, 0x0132, -0x00E3, 0x00A2, -0x004B, 0x003C, -0x0013,
      0x0003,
      0x0000, -0x0002, 0x0000, 0x0000, 0x0000, //
    ],
    [
      0x0001, 0x0003, -0x0008, 0x0011, -0x0010, 0x000A, 0x006B, -0x016D, 0x0350,
      -0x0623, 0x0BCD, -0x1780, 0x6794, 0x234C, -0x0A78, //
      0x0400, -0x010A, 0x0009, 0x0034, -0x0054, 0x0041, -0x0022, 0x000A,
      -0x0001,
      0x0000, 0x0001, 0x0000, 0x0000, 0x0000, //
    ],
    [
      0x0002, -0x0008, 0x0010, -0x0023, 0x002B, 0x001A, -0x00EB, 0x027B,
      -0x0548,
      0x0AFA, -0x16FA, 0x53E0, 0x3C07, -0x1249, 0x080E, //
      -0x0347, 0x015B, -0x0044, -0x0017, 0x0046, -0x0023, 0x0011, -0x0005,
      0x0000,
      0x0000, 0x0000, 0x0000, 0x0000, 0x0000, //
    ],
    [
      -0x0005, 0x0011, -0x0023, 0x0046, -0x0017, -0x0044, 0x015B, -0x0347,
      0x080E,
      -0x1249, 0x3C07, 0x53E0, -0x16FA, 0x0AFA, -0x0548, //
      0x027B, -0x00EB, 0x001A, 0x002B, -0x0023, 0x0010, -0x0008, 0x0002, 0x0000,
      0x0000, 0x0000, 0x0000, 0x0000, 0x0000, //
    ],
  ];

  final _ring = [List.filled(32, 0), List.filled(32, 0)];
  final _p = [0, 0];
  final _step = [6, 6];

  void reset() {
    _ring[0].fillRange(0, 32, 0);
    _ring[1].fillRange(0, 32, 0);
    _p.setAll(0, [0, 0]);
    _step.setAll(0, [6, 6]);
  }

  int _applyZigzag(List<int> ring, int table, int p) {
    int sum = 0;
    for (int i = 1; i < 29; i++) {
      sum += ring[(p - i) & 0x1f] * zigzagTables[table][i] ~/ 0x8000;
    }
    return sum.min(0x7fff).max(-0x8000);
  }

  void pushInterpolated(
      Queue<int> buf, int ch, List<int> org, bool doubleSamples) {
    for (final val in org) {
      // use 1 sample twice  when 18900Hz
      for (int i = 0; i < 2; i++) {
        _ring[ch][_p[ch]++ & 0x1f] = val;

        if (--_step[ch] <= 0) {
          _step[ch] = 6;
          for (int i = 0; i < 7; i++) {
            buf.add(_applyZigzag(_ring[ch], i, _p[ch]));
          }
        }

        if (!doubleSamples) {
          break;
        }
      }
    }
  }
}

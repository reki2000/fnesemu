import 'dart:collection';

import 'package:fnesemu/util/debug.dart';
import 'package:fnesemu/util/int.dart';

class Mdec {
  final decoder = Decoder();
  final params = Queue<int>();
  int paramCount = 0;

  int command = commandNone; // 1: Decode 2: Set Quant 3: Set Scale
  static const commandNone = 0;
  static const commandDecode = 1;
  static const commandSetQuant = 2;
  static const commandSetScale = 3;

  int blockType = blockTypeY1;
  static const blockTypeCr = 0;
  static const blockTypeCb = 1;
  static const blockTypeY1 = 2;
  static const blockTypeY2 = 3;
  static const blockTypeY3 = 4;
  static const blockTypeY4 = 5;

  final buf = List<List<int>>.generate(
      6, (_) => List<int>.filled(64, 0)); // 0:Cr  1:Cb 2:Y1 3:Y2 4:Y3 5:Y4

  final output = Queue<int>();
  bool dataInRequest = false;
  bool dataOutRequest = false;

  bool get dataInAck => dataInRequest && params.length < 64;
  bool get dataOutAck => dataOutRequest && output.isNotEmpty;

  int depth = depth4bit; // 0:4bit 1:8bit 2:24bit 3:15bit
  static const depth4bit = 0;
  static const depth8bit = 1;
  static const depth24bit = 2;
  static const depth15bit = 3;

  bool signed = false;
  bool bit15Set = false; // 0: clear 1: set (for 15bit depth only)

  void reset() {
    params.clear();
    paramCount = 0;
    command = commandNone;
    dataInRequest = false;
    dataOutRequest = false;
    depth = depth4bit;
    signed = false;
    bit15Set = false;
    blockType = blockTypeY1;
    output.clear();

    decoder.outputIndex = -1;
  }

  void writeCommand(int value) {
    // debugLog("mdec: got ${value.hex32} state:${dump()}");

    if (paramCount > 0) {
      params.add(value.mask16);
      params.add(value >> 16);

      if (command == Mdec.commandDecode) {
        decodeStep(params.removeFirst());
        decodeStep(params.removeFirst());
      }

      paramCount -= 1;
      if (paramCount <= 0) {
        switch (command) {
          case Mdec.commandDecode:
            decodeStep(0xfe00); // EOB
            debugLog(
                "mdec: decode command completes oIdx:${decoder.outputIndex} ${dump()}");
          case Mdec.commandSetQuant:
            setQuant();
          case Mdec.commandSetScale:
            setScale();
        }
        params.clear();
        command = Mdec.commandNone;
      }

      return;
    }

    switch (value >> 29) {
      case 0x01: // Decode
        paramCount = value.mask16;
        if (paramCount == 0) {
          paramCount = 0x10000;
        }
        depth = (value >> 27) & 0x3;
        blockType = blockTypeCr;
        signed = value.bit24;
        bit15Set = value.bit23;
        command = Mdec.commandDecode;
        debugLog("mdec: decode command ${value.hex32} ${dump()}");
        break;

      case 0x02: // SetQuant
        paramCount = value.bit0 ? 32 : 16;
        command = Mdec.commandSetQuant;
        break;

      case 0x03: // SetScale
        paramCount = 32;
        command = Mdec.commandSetScale;
        break;

      default:
        debugLog("mdec: got unknown command ${value.hex32}");
    }
  }

  void writeControl(int value) {
    // debugLog("mdec: writeControl ${value.hex32} ${dump()}");
    if (value.bit31) {
      reset();
    }

    dataInRequest = value.bit30;
    dataOutRequest = value.bit29;
  }

  int readStatus() {
    // debugLog("mdec: readStatus ${dump()}");
    return 0
            .setBit(31, output.isEmpty) // Data-Out Fifo Empty
            .setBit(30, params.length >= 64) // Data-In Fifo Full
            .setBit(29, command != commandNone) // Command Busy
            .setBit(28, dataInRequest) // Data-In Request
            .setBit(27, dataOutRequest) // Data-Out Request
            .setBit(24, signed) // Data Output Signed
            .setBit(23, bit15Set) // Data Output Bit15
        |
        depth << 25 |
        blockType << 16 |
        paramCount.dec.mask16; // Number of Parameter Words remaining minus 1
  }

  int readData() => output.isEmpty ? 0 : output.removeFirst();

  void decodeStep(int input) {
    if (!decoder.extractRle(input, buf[blockType],
        blockType == blockTypeCr || blockType == blockTypeCb)) {
      return;
    }

    // debugLog("mdec: RLE extract completes a block $blockType\n"
    //     " [${buf[blockType].map((i) => i.hex16).join(" ")}]");

    decoder.fastIdct(buf[blockType]);

    // debugLog("mdec: IDCT completes a block $blockType\n"
    //     " [${buf[blockType].map((i) => i.hex16).join(" ")}]");

    if (depth == depth4bit) {
      final xor = signed ? 0 : 0x08;
      for (int i = 0; i < 64; i += 8) {
        int value = 0;
        for (int j = 7; j >= 0; j--) {
          final v = buf[blockType][i + j].rel9.clip(-128, 127) >> 4;
          value = (v.mask4 ^ xor) | (value << 4);
        }
        output.add(value);
      }
      // debugLog("mdec: output a 4bpp block\n"
      //     " [${output.map((i) => i.hex32).join(" ")}]");

      return;
    }

    if (depth == depth8bit) {
      final xor = signed ? 0 : 0x80;
      for (int i = 0; i < 64; i += 4) {
        int value = 0;
        for (int j = 3; j >= 0; j--) {
          final v = buf[blockType][i + j].rel9.clip(-128, 127);
          value = (v.mask8 ^ xor) | (value << 8);
        }
        output.add(value);
      }

      // debugLog("mdec: output a 8bpp block\n"
      //     " [${output.map((i) => i.hex32).join(" ")}]");

      return;
    }

    if (blockType == blockTypeY4) {
      final rgb = List<Color>.filled(16 * 16, Color(0, 0, 0));
      final cbBuf = buf[Mdec.blockTypeCb];
      final crBuf = buf[Mdec.blockTypeCr];
      decoder.yuvToRgb(rgb, cbBuf, crBuf, buf[Mdec.blockTypeY1], 0, 0);
      decoder.yuvToRgb(rgb, cbBuf, crBuf, buf[Mdec.blockTypeY2], 8, 0);
      decoder.yuvToRgb(rgb, cbBuf, crBuf, buf[Mdec.blockTypeY3], 0, 8);
      decoder.yuvToRgb(rgb, cbBuf, crBuf, buf[Mdec.blockTypeY4], 8, 8);

      if (depth == depth15bit) {
        final xor = signed ? 0 : 0x42104210;
        final bit15 = bit15Set ? 0x80008000 : 0;
        for (int i = 0; i < 16 * 16; i += 2) {
          output.add((rgb[i].c15 | (rgb[i + 1].c15 << 16) | bit15) ^ xor);
        }
        // debugLog("mdec: output a 15bpp block\n"
        //     " [${output.toList().sublist(0, 128).map((i) => i.hex32).join(" ")}]");
      } else {
        final xor = signed ? 0 : 0x80808080;
        for (int i = 0; i < 16 * 16 - 1; i++) {
          if (i % 4 == 3) {
            continue;
          }
          final value = switch (i % 4) {
            0 => rgb[i].c24 | rgb[i + 1].c24.mask8 << 24,
            1 => (rgb[i].c24 >> 8).mask16 | rgb[i + 1].c24.mask16 << 16,
            2 => (rgb[i].c24 >> 16).mask8 | rgb[i + 1].c24 << 8,
            _ => 0
          };
          output.add(value ^ xor);
        }
        // debugLog("mdec: output a 24bpp block\n"
        //     " [${output.map((i) => i.hex32).join(" ")}]");
      }
    }

    blockType = switch (blockType) {
      blockTypeCr => blockTypeCb,
      blockTypeCb => blockTypeY1,
      blockTypeY1 => blockTypeY2,
      blockTypeY2 => blockTypeY3,
      blockTypeY3 => blockTypeY4,
      _ => blockTypeCr,
    };
  }

  void setQuant() {
    for (var qt in [decoder.qtY, decoder.qtC]) {
      for (int i = 0; i < 32; i++) {
        int value = params.removeFirst();
        for (int j = 0; j < 2; j++) {
          qt[i * 2 + j] = value.rel8;
          value >>= 8;
        }
      }
      if (params.length < 16) {
        break;
      }
    }

    debugLog("mdec: SetQuant ${dump()}\n"
        " [${decoder.qtY.map((i) => i.hex8).join(" ")}]\n"
        " [${decoder.qtC.map((i) => i.hex8).join(" ")}]");
  }

  void setScale() {
    decoder.scale.setAll(0, params);
    debugLog("mdec: SetScale ${dump()}\n"
        " [${decoder.scale.map((i) => i.hex16).join(" ")}]");
  }

  String dump() => "command:$command paramCount:$paramCount "
      "depth:$depth signed:$signed bit15Set:$bit15Set "
      "blockType:$blockType "
      "params:${params.length} ";
}

class Decoder {
  final scale = List<int>.filled(64, 0);
  final qtY = List<int>.filled(64, 0);
  final qtC = List<int>.filled(64, 0);

  static List<double> scaleFactors = [
    1.000000000, 1.387039845, 1.306562965, 1.175875602, //
    1.000000000, 0.785694958, 0.541196100, 0.275899379 //
  ];

  static List<int> zigZag = [
    0, 1, 5, 6, 14, 15, 27, 28, //
    2, 4, 7, 13, 16, 26, 29, 42, //
    3, 8, 12, 17, 25, 30, 41, 43, //
    9, 11, 18, 24, 31, 40, 44, 53, //
    10, 19, 23, 32, 39, 45, 52, 54, //
    20, 22, 33, 38, 46, 51, 55, 60, //
    21, 34, 37, 47, 50, 56, 59, 61, //
    35, 36, 48, 49, 57, 58, 62, 63 //
  ];
  static List<int> zagZig = List<int>.filled(64, 0);
  static List<double> scaleZag = List<double>.filled(64, 0);

  Decoder() {
    for (int i = 0; i < 64; i++) {
      zagZig[zigZag[i]] = i;
      scaleZag[zigZag[i]] = scaleFactors[i % 8] * scaleFactors[i ~/ 8] / 8;
    }
  }

  // RLE decoding state
  int outputIndex = -1;
  int q = 0;

  // Extract one RLE encoded data, return true if block is completed
  bool extractRle(int input, List<int> output, bool isChrominance) {
    final qt = isChrominance ? qtC : qtY;
    // debugLog(
    //     "mdec: RLE ${input.hex16} idx:$outputIndex q:${q.hex8} ac:${ac.hex16} [${output.map((i) => i.hex16).join(",")}]");
    if (outputIndex == -1) {
      if (input == 0xfe00) {
        return false;
      }

      output.fillRange(0, 64, 0);
      q = input >> 10;
      outputIndex = 0;

      int value = input.rel10 * qt[0];
      if (q == 0) {
        value *= 2;
      }
      output[0] = (value.clip(-1024, 1023) * scaleZag[0]).round();

      return false;
    }

    final runLength = (input >> 10) & 0x3f;
    outputIndex += runLength + 1;

    if (outputIndex >= 64) {
      outputIndex = -1;
      return true;
    }

    final (value, idx) = (q == 0)
        ? (input.rel10 * 2, outputIndex)
        : ((input.rel10 * qt[outputIndex] * q + 4) ~/ 8, zagZig[outputIndex]);
    output[idx] = (value.clip(-1024, 1023) * scaleZag[outputIndex]).round();

    if (outputIndex == 63) {
      outputIndex = -1;
      return true;
    }

    return false;
  }

  // 8x8: Cr+Cb+(Y1, Y3, Y2, Y4) -->to RGB 8x8x4
  void yuvToRgb(List<Color> out, List<int> cbBuf, List<int> crBuf,
      List<int> yBuf, int xOffset, int yOffset) {
    for (int y = 0; y < 8; y++) {
      final y1 = y * 8;
      final y2 = ((yOffset + y) >> 1) * 8 + (xOffset >> 1);
      final y3 = (yOffset + y) * 16 + xOffset;

      for (int x = 0; x < 8; x++) {
        final yy = yBuf.elementAt(x + y1);
        final cr = crBuf.elementAt((x >> 1) + y2);
        final cb = cbBuf.elementAt((x >> 1) + y2);

        final r = yy + 1.402 * cr;
        final g = yy - 0.344136 * cb - 0.714136 * cr;
        final b = yy + 1.772 * cb;

        out[y3 + x] = Color(r.round().clip(-128, 127),
            g.round().clip(-128, 127), b.round().clip(-128, 127));
        // if (yBlock == Mdec.blockTypeY2) {
        //   out[y3 + x] = Color(-128, -128, -128);
        // }
      }
    }
  }

  void fastIdct(List<int> block) {
    List<int> src = block;
    List<int> dst = List<int>.filled(64, 0);
    for (int pass = 0; pass < 2; pass++) {
      for (int i = 0; i < 8; i++) {
        if (src[1 * 8 + i] == 0 &&
            src[2 * 8 + i] == 0 &&
            src[3 * 8 + i] == 0 &&
            src[4 * 8 + i] == 0 &&
            src[5 * 8 + i] == 0 &&
            src[6 * 8 + i] == 0 &&
            src[7 * 8 + i] == 0) {
          for (int j = 0; j < 8; j++) {
            dst[i * 8 + j] = src[0 * 8 + i];
          }
        } else {
          final z10 = src[0 * 8 + i] + src[4 * 8 + i];
          final z11 = src[0 * 8 + i] - src[4 * 8 + i];
          final z13 = src[2 * 8 + i] + src[6 * 8 + i];
          var z12 = src[2 * 8 + i] - src[6 * 8 + i];
          z12 = (1.414213562 * z12).round() - z13;

          final tmp0 = z10 + z13;
          final tmp3 = z10 - z13;
          final tmp1 = z11 + z12;
          final tmp2 = z11 - z12;

          final z13_2 = src[3 * 8 + i] + src[5 * 8 + i];
          final z10_2 = src[3 * 8 + i] - src[5 * 8 + i];
          final z11_2 = src[1 * 8 + i] + src[7 * 8 + i];
          final z12_2 = src[1 * 8 + i] - src[7 * 8 + i];

          final z5 = (1.847759065 * (z12_2 - z10_2)).round();
          final tmp7 = z11_2 + z13_2;
          final tmp6 =
              (2.613125930 * (z10_2)).round() + z5 - tmp7; // scalefactor[2]*2
          final tmp5 =
              (1.414213562 * (z11_2 - z13_2)).round() - tmp6; // sqrt(2)
          final tmp4 = (1.082392200 * (z12_2)).round() - z5 + tmp5;

          dst[i * 8 + 0] = tmp0 + tmp7;
          dst[i * 8 + 7] = tmp0 - tmp7;
          dst[i * 8 + 1] = tmp1 + tmp6;
          dst[i * 8 + 6] = tmp1 - tmp6;
          dst[i * 8 + 2] = tmp2 + tmp5;
          dst[i * 8 + 5] = tmp2 - tmp5;
          dst[i * 8 + 4] = tmp3 + tmp4;
          dst[i * 8 + 3] = tmp3 - tmp4;
        }
      }
      final tmp = src;
      src = dst;
      dst = tmp;
    }
  }
}

class Color {
  final int r;
  final int g;
  final int b;

  Color(this.r, this.g, this.b);

  int get c24 => b.mask8 << 16 | g.mask8 << 8 | r.mask8;
  int get c15 => (b << 7) & 0x7c00 | (g << 2) & 0x3e0 | (r >> 3) & 0x1f;
}

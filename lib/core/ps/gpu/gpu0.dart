part of 'gpu.dart';

extension Gpu0 on Gpu {
  static const xMask = 0x3ff;
  static const yMask = 0x1ff;

  void writeGp0(int value) {
    // if (bus.gpu.frame >= 1072 && bus.gpu.frame <= 1072) {
    // debugLog("GPU0: writeGp0: value:${value.hex32} ${dumpCmd()}");
    // }

    if (!cmdReady || !handleSingleWordCommand(value)) {
      if (!handleMultiwordCommand(value)) {
        debugLog("invalid GP0 command cmd0:${value.hex32} ${dumpCmd()}");
        cmdSize = 0;
      }
    }
  }

  bool handleSingleWordCommand(int value) {
    switch (value >> 24) {
      case 0x00: // nop
      case 0x01: // clear cache
        break;

      case 0x1f: // irq1
        if (!irq1) {
          bus.setIrq(Interrupt.gpu);
        }
        irq1 = true;

      case 0x02: // quick rectangler fill
        return false;

      case >= 0x00 && < 0x20:
        debugLog("GPU0: unknown misc command: ${value.hex32}");

      case 0xe1: // draw mode setting
        status = status.masked(0x7ff, value).setBit(15, value.bit11);
      // debugLog("GPU0: draw mode setting: ${status.hex32}");

      case 0xe2: // texture window setting
        textureMaskX = value & 0x1f;
        textureMaskY = (value >> 5) & 0x1f;
        textureOffsetX = (value >> 10) & 0x1f;
        textureOffsetY = (value >> 15) & 0x1f;

        textureMaskX2 = ~(textureMaskX << 3) & 0xff;
        textureMaskY2 = ~(textureMaskY << 3) & 0xff;
        textureOffsetX2 = (textureOffsetX & textureMaskX) << 3;
        textureOffsetY2 = (textureOffsetY & textureMaskY) << 3;

      // debugLog(
      //     "GPU0: texture window setting: ${value.hex32} mask:($textureMaskX, $textureMaskY) offset:($textureOffsetX, $textureOffsetY)");

      case 0xe3: // set drawing area top left
        drawingX1 = value & xMask;
        drawingY1 = (value >> 10) & yMask;

      case 0xe4: // set drawing area bottom right
        drawingX2 = value & xMask;
        drawingY2 = (value >> 10) & yMask;

      case 0xe5: // set drawing offset
        drawingOffsetX = value.rel11;
        drawingOffsetY = (value >> 11).rel11;

      case 0xe6: // mask bit setting
        status = status.setBit(11, value.bit0);
        status = status.setBit(12, value.bit1);

      case >= 0xe0 && < 0x100:
        debugLog("GPU0: unknown environment command: ${value.hex32}");

      default:
        return false;
    }

    return true;
  }

  bool handleMultiwordCommand(int value) {
    final cmd0 = cmdSize == 0 ? value : cmd[0];

    // debugLog(
    //     "gpu0: multiword value:${value.hex32} [${cmd0 >> 29}] cmd:${dumpCmd()}");

    switch (cmd0 >> 29) {
      case 0x00: // misc
        switch (cmd0 >> 24) {
          case 0x02: // quick rectangle fill
            cmdFillRectangle(value);

          default:
            return false;
        }

      case 0x01: // polygon primitive
        cmdDrawPolygon(value);

      case 0x02: // line primitive
        cmdDrawLine(value);

      case 0x03: // rectangle primitive
        cmdDrawRectangle(value);

      case 0x04: // vram to vram blit
        cmdBlitVramToVram(value);

      case 0x05: // cpu to vram blit
        cmdBlitCpuToVram(value);

      case 0x06: // vram to cpu blit
        cmdBlitVramToCpu(value);

      default:
        return false;
    }

    return true;
  }

  postRead() {
    if (cmdSize == 0) {
      vramToCpuReady = false;
      return;
    }

    vramToCpuReady = true;
    readValue = 0;
    for (int i = 0; i < 2; i++) {
      readValue |= readFrameBuffer16(bltFromX, bltFromY) << (i * 16);
      bltFromX++;
      bltSizeX--;

      if (bltSizeX == 0) {
        bltFromX = cmd[1] & xMask;
        bltSizeX = (cmd[2].dec & xMask).inc;
        bltSizeY--;
        bltFromY++;

        // debugLog(
        //     "GPU0: blit vram to cpu:  ($bltFromX, $bltFromY) $bltSizeX x $bltSizeY");

        if (bltSizeY == 0) {
          // debugLog("GPU0: blit vram to cpu completed");
          cmdSize = 0;
          break;
        }
      }
    }
  }

  cmdFillRectangle(int value) {
    cmd[cmdSize++] = value;

    if (cmdSize == 3) {
      final p0 = Point.of(cmd[1] & 0x01ff03f0, 0, 0);
      final w = ((cmd[2] & 0x3ff) + 0x0f) & 0x7f0;
      final h = cmd[2] >> 16 & 0x1ff;
      final c16 = Color.ofC24(cmd[0]).c15;
      for (int y = p0.y; y < (p0.y + h).min(512); y++) {
        for (int x = p0.x; x < (p0.x + w).min(1024); x++) {
          writeFrameBuffer16(x, y, c16);
        }
      }

      // debugLog(
      //     "GPU0: quick rectangle fill completed : ${dumpCmd()} (${p0.x},${p0.y}) ${w}x$h ${c16.hex16}");
      cmdSize = 0;
    }
  }

  cmdDrawPolygon(int value) {
    cmd[cmdSize++] = value;

    final gouraud = cmd[0].bit28;
    final rectangle = cmd[0].bit27;
    final textured = cmd[0].bit26;

    final indiceNum = rectangle ? 4 : 3;
    final size = ((gouraud ? 1 : 0) + (textured ? 1 : 0) + 1) * indiceNum +
        (gouraud ? 0 : 1);

    if (cmdSize == size) {
      final c = cmd;
      final c0 = c[0];

      if (textured) {
        if (gouraud) {
          final clut = c[2] >> 16;
          final page = c[5] >> 16;
          // 0c,1xy,2uv   3c,4xy,5uv  6c,7xy,8uv   9c,10xy,11uv
          renderTexturedGouraudPolygon(c0, clut, page, c0, c[1], c[2], c[3],
              c[4], c[5], c[6], c[7], c[8]);
          if (rectangle) {
            renderTexturedGouraudPolygon(c0, clut, page, c[3], c[4], c[5], c[6],
                c[7], c[8], c[9], c[10], c[11]);
          }
          // debugLogTexturedPolygon(cmd);
        } else {
          // 0c,1xy,2uv   3xy,4uv  5xy,6uv  7xy,8uv
          final clut = c[2] >> 16;
          final page = c[4] >> 16;
          renderTexturedGouraudPolygon(
              c0, clut, page, 0, c[1], c[2], 0, c[3], c[4], 0, c[5], c[6]);
          if (rectangle) {
            renderTexturedGouraudPolygon(
                c0, clut, page, 0, c[3], c[4], 0, c[5], c[6], 0, c[7], c[8]);
            // debugLogTexturedPolygon(cmd);
          }
        }
      } else {
        if (gouraud) {
          renderGouraudPolygon(c0, c[0], c[1], c[2], c[3], c[4], c[5]);
          if (rectangle) {
            renderGouraudPolygon(c0, c[2], c[3], c[4], c[5], c[6], c[7]);
          }
        } else {
          renderFlatPolygon(c0, c[1], c[2], c[3]);
          if (rectangle) {
            renderFlatPolygon(c0, c[2], c[3], c[4]);
            // final (x0, y0) = (c[1] & xMask, c[1] >> 16 & yMask);
            // final (x1, y1) = (c[2] & xMask, c[2] >> 16 & yMask);
            // final (x2, y2) = (c[3] & xMask, c[3] >> 16 & yMask);
            // final (x3, y3) = (c[4] & xMask, c[4] >> 16 & yMask);
            // debugLog(
            //     "GPU0: flat rectangle polygon completed ${dumpCmd()} "
            //     "($x0,$y0)-($x1,$y1)-($x2,$y2)-($x3,$y3) ${x3 - x0}x${y3 - y0}");
          }
        }
      }

      // debugLog(
      //     "GPU0: polygon completed ${dumpCmd()}");
      //     "($x0, $y0) $w x $h ($u0, $v0) "
      //     "clut:${clut.hex16} ${clut << 4 & 0x3e0},${clut >> 5 & 0x1ff} page:${page.hex16} ${page << 6 & 0x3c0},${page << 4 & 0x100} c${page >> 7 & 3} ");
      cmdSize = 0;
    }
  }

  cmdDrawLine(int value) {
    cmd[cmdSize++] = value;

    final gouraud = cmd[0].bit28;
    final polyline = cmd[0].bit27;

    if (polyline && value & 0xf000f000 == 0x50005000) {
      cmdSize = 0;
      return;
    }

    if (gouraud) {
      if (cmdSize > 3 && !cmdSize.bit0) {
        renderGouraudLine(cmd[0], cmd[cmdSize - 3], cmd[cmdSize - 1],
            cmd[cmdSize - 4], cmd[cmdSize - 2]);
        if (!polyline && cmdSize == 4) {
          cmdSize = 0;
        }
      }
    } else {
      if (cmdSize > 2) {
        renderLine(cmd[0], cmd[cmdSize - 2], cmd[cmdSize - 1]);
        if (!polyline && cmdSize == 3) {
          cmdSize = 0;
        }
      }
    }
  }

  cmdDrawRectangle(int value) {
    cmd[cmdSize++] = value;

    final textured = cmd[0].bit26;
    final size = cmd[0] >> 27 & 3;

    int beginIndex = 2;
    int sizeIndex = 2;

    if (textured) {
      beginIndex++;
      sizeIndex++;
    }

    if (size == 0) {
      beginIndex++;
    }

    if (cmdSize == beginIndex) {
      final transparent = cmd[0].bit25;
      final transparentMask = transparent ? 0xffff : 0x7fff;
      final modulated = !cmd[0].bit24;
      final modulateColor = Color.ofC24(cmd[0]);

      final (clut, v0, u0) = !textured
          ? (0, 0, 0)
          : (cmd[2] >> 16, (cmd[2] >> 8) & 0xff, cmd[2] & 0xff);

      final (w, h) = switch (size) {
        0 => (cmd[sizeIndex] & xMask, (cmd[sizeIndex] >> 16) & yMask),
        1 => (1, 1),
        2 => (8, 8),
        3 => (16, 16),
        _ => throw "unreachable",
      };

      final (x0, y0) = (cmd[1].rel11, (cmd[1] >> 16).rel11);
      final baseX = status << 6 & 0x3c0;
      final baseY = status << 4 & 0x100;
      final clutMode = status >> 7 & 3;
      final clutBase = (clut >> 6 & yMask) * 1024 + ((clut & 0x3f) << 4);

      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          if (textured) {
            final texColor = getTextureColor2(
                u0 + x, v0 + y, baseX, baseY, clutBase, clutMode);
            final c16 =
                modulated ? modulate(texColor, modulateColor) : texColor;
            if (c16 != 0) {
              pset16(x0 + x, y0 + y, c16 & transparentMask);
            }
            //   debugLog(
            //       "GPU0: textured rectangle pixel ($x, $y) color:${c16.hex16}");
          } else {
            pset24(x0 + x, y0 + y, cmd[0].mask24, transparent: transparent);
          }
        }
      }

      // debugLog("GP0 rectangle primitive completed : ${dumpCmd()} "
      //     "($x0, $y0) $w x $h ($u0, $v0) ${transparent ? "semi" : "opaq"} ${textured ? "tex" : "---"} "
      //     "clut:${clut.hex16} ${clut << 4 & 0x3f0},${clut >> 6 & 0x1ff} page:${status.hex16} "
      //     "${status << 6 & 0x3c0},${status << 4 & 0x100} c${status >> 7 & 3} "
      //     "${textured ? dumpClut(clut, status) : ""}");
      cmdSize = 0;
    }
  }

  cmdBlitVramToVram(int value) {
    cmd[cmdSize++] = value;

    if (cmdSize == 4) {
      bltFromY = (cmd[1] >> 16) & yMask;
      bltPosY = (cmd[2] >> 16) & yMask;
      bltSizeY = (cmd[3] >> 16).maskZeroMax(yMask);

      bltFromX = cmd[1] & xMask;
      bltPosX = cmd[2] & xMask;
      bltSizeX = cmd[3].maskZeroMax(xMask);
      // debugLog(
      //     "GP0 vram to vram blit: [${dumpCmd()}] $bltFromX,$bltFromY -> $bltPosX,$bltPosY w:$bltSizeX h:$bltSizeY");

      final forceMask = status.bit11 ? 0x8000 : 0;
      while (cmdSize == 4) {
        if (!status.bit12 || !readFrameBuffer16(bltPosX, bltPosY).bit15) {
          writeFrameBuffer16(bltPosX, bltPosY,
              readFrameBuffer16(bltFromX, bltFromY) | forceMask);
        }
        bltFromX++;
        bltPosX++;
        bltSizeX--;

        if (bltSizeX <= 0) {
          bltFromX = cmd[1] & xMask;
          bltPosX = cmd[2] & xMask;
          bltSizeX = cmd[3].maskZeroMax(xMask);

          bltFromY++;
          bltPosY++;
          bltSizeY--;

          if (bltSizeY <= 0) {
            cmdSize = 0;
            return;
          }
        }
      }
    }
  }

  cmdBlitCpuToVram(int value) {
    if (cmdSize == 3) {
      final forceMask = status.bit11 ? 0x8000 : 0;
      for (final v in [value.mask16, value >> 16]) {
        if (!status.bit12 || !readFrameBuffer16(bltPosX, bltPosY).bit15) {
          writeFrameBuffer16(bltPosX, bltPosY, v | forceMask);
        }
        bltPosX++;
        bltSizeX--;

        if (bltSizeX == 0) {
          bltPosX = cmd[1] & xMask;
          bltSizeX = cmd[2].maskZeroMax(xMask);

          bltPosY++;
          bltSizeY--;

          if (bltSizeY == 0) {
            // debugLog(
            //     "GPU0: blit cpu to vram: completed  pc:${bus.cpu.pc.hex32}");
            cmdSize = 0;
            break;
          }
        }
      }

      return;
    }

    cmd[cmdSize++] = value;

    if (cmdSize == 3) {
      bltPosX = cmd[1] & xMask;
      bltSizeX = cmd[2].maskZeroMax(xMask);

      bltPosY = cmd[1] >> 16 & yMask;
      bltSizeY = (cmd[2] >> 16).maskZeroMax(yMask);

      // debugLog(
      //     "GPU0: blit cpu to vram: ${dumpCmd()} ($bltPosX,$bltPosY) $bltSizeX x $bltSizeY");
    }
  }

  cmdBlitVramToCpu(int value) {
    cmd[cmdSize++] = value;

    if (cmdSize == 3) {
      bltFromX = cmd[1] & xMask;
      bltSizeX = cmd[2].maskZeroMax(xMask);

      bltFromY = cmd[1] >> 16 & yMask;
      bltSizeY = (cmd[2] >> 16).maskZeroMax(yMask);

      // debugLog(
      //     "GPU0: blit vram to cpu: ${dumpCmd()} ($bltFromX, $bltFromY) $bltSizeX x $bltSizeY");

      cmdSize++;

      postRead(); // pre-read first 2 pixels
    }
  }

  int modulate(int c16, Color m24) {
    final c24 = Color.ofC15(c16);
    final r = 255.min(c24.r * m24.r ~/ 128);
    final g = 255.min(c24.g * m24.g ~/ 128);
    final b = 255.min(c24.b * m24.b ~/ 128);
    return Color(r, g, b).c15 | (c16 & 0x8000);
  }

  String dumpClut(int clut, int page) {
    final (clutX, clutY, clutMode) =
        (clut << 4 & 0x3f0, clut >> 6 & 0x1ff, page >> 7 & 3);
    final clutBase = clutY * 2048 + clutX * 2;

    final dump = switch (clutMode) {
      0 => List.generate(16, (i) => i)
          .map((i) => frameBuffer.getUint16LE(clutBase + i * 2).hex16)
          .join(" "),
      1 => List.generate(256, (i) => i)
          .map((i) => frameBuffer.getUint16LE(clutBase + i * 2).hex16)
          .join(" "),
      2 => "16bit",
      _ => "unknown",
    };

    return "0x${clutBase.hex32} [$dump]";
  }

  debugLogTexturedPolygon(List<int> c) {
    final clut = c[2] >> 16;
    final page = c[4] >> 16;

    final (x0, y0) = (c[1] & xMask, c[1] >> 16 & yMask);
    final (u0, v0) = (c[2] & 0xff, c[2] >> 8 & 0xff);
    final (x1, y1) = (c[3] & xMask, c[3] >> 16 & yMask);
    final (u1, v1) = (c[4] & 0xff, c[4] >> 8 & 0xff);
    final (x2, y2) = (c[5] & xMask, c[5] >> 16 & yMask);
    final (u2, v2) = (c[6] & 0xff, c[6] >> 8 & 0xff);
    final (x3, y3) = (c[7] & xMask, c[7] >> 16 & yMask);
    final (u3, v3) = (c[8] & 0xff, c[8] >> 8 & 0xff);
    final (clutX, clutY, clutMode) =
        (clut << 4 & 0x3f0, clut >> 6 & 0x1ff, page >> 7 & 3);
    final (pageX, pageY) = (page << 6 & 0x3c0, page << 4 & 0x100);
    final clutDump = dumpClut(clut, page);
    // debugLog(
    //     "GPU0: textured rectangle polygon completed ${cmd.sublist(0, cmdSize).map((e) => e.hex32).join(" ")} "
    //     "($x0,$y0)-($x1,$y1)-($x2,$y2)-($x3,$y3) ${x3 - x0}x${y3 - y0} ($u0,$v0)-($u1,$v1)-($u2,$v2)-($u3,$v3) "
    //     "clut:${clut.hex16} $clutX,$clutY page:${page.hex16} $pageX,$pageY c$clutMode [$clutDump]");
    // if (x0 == 0 && y0 == 144) {
    debugLog("GPU0: textured rectangle polygon completed ${dumpCmd()} "
        "($x0,$y0)-($x3,$y3) ${x3 - x0}x${y3 - y0} ($u0,$v0)-($u3,$v3) "
        "clut:${clut.hex16} $clutX,$clutY page:${page.hex16} $pageX,$pageY c$clutMode [$clutDump]");
    // debugLog(
    //     "GPU0: texture color at (0,144): ${getTextureColor(0, 144, clut, status).hex16}");
    // renderFlatPolygon(0, c[3], c[5], c[7]);
    // }
  }
}

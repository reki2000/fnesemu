part of 'gpu.dart';

extension Gpu0 on Gpu {
  static const xMask = 0x3ff;
  static const yMask = 0x1ff;

  void writeGp0(int value) {
    // debugLog(
    //     "gpu0: value:${value.hex32} cmd:${cmd.sublist(0, cmdSize).map((e) => e.hex32).join(" ")}");

    if (!cmdReady || !handleSingleWordCommand(value)) {
      if (!handleMultiwordCommand(value)) {
        debugLog(
            "invalid GP0 command cmd0:${value.hex32} cmd:${cmd.sublist(0, cmdSize).map((e) => e.hex32).join(" ")}");
        cmdSize = 0;
      }
    }
  }

  bool handleMultiwordCommand(int value) {
    final cmd0 = cmdSize == 0 ? value : cmd[0];
    switch (cmd0 >> 29) {
      case 0x00: // misc
        switch (cmd0 >> 24) {
          case 0x02: // quick rectangle fill
            cmd[cmdSize++] = value;

            if (cmdSize == 3) {
              final p0 = Point.of(cmd[1] & 0x01ff03f0, 0, 0);
              final w = ((cmd[2] & 0x3ff) + 0x0f) & 0x7f0;
              final h = cmd[2] >> 16 & 0x1ff;
              final c16 = Color.ofC24(cmd[0]).c15;
              for (int y = p0.y; y < (p0.y + h).min(512); y++) {
                for (int x = p0.x; x < (p0.x + w).min(1024); x++) {
                  pset16(x, y, c16, ignoreWindow: true);
                }
              }

              // debugLog(
              //     "GPU0: quick rectangle fill completed : ${cmd.sublist(0, cmdSize).map((e) => e.hex32).join(" ")} (${p0.x},${p0.y}) ${w}x$h ${c16.hex16}");
              cmdSize = 0;
            }

          default:
            return false;
        }

      case 0x01: // polygon primitive
        cmd[cmdSize++] = value;

        final gouraud = cmd[0].bit28;
        final textured = cmd[0].bit26;
        final rectangle = cmd[0].bit27;

        final indiceNum = rectangle ? 4 : 3;
        final size = ((gouraud ? 1 : 0) + (textured ? 1 : 0) + 1) * indiceNum +
            (gouraud ? 0 : 1);

        if (cmdSize == size) {
          final c = cmd;
          final c0 = c[0];

          if (textured) {
            final clut = c[2] >> 16;
            final page = c[4] >> 16;
            renderTexturedPolygon(
                c0, clut, page, c[1], c[2], c[3], c[4], c[5], c[6]);
            if (rectangle) {
              renderTexturedPolygon(
                  c0, clut, page, c[3], c[4], c[5], c[6], c[7], c[8]);
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
              }
            }
          }

          // debugLog(
          //     "GPU0: polygon completed ${cmd.sublist(0, cmdSize).map((e) => e.hex32).join(" ")}");
          cmdSize = 0;
        }

      case 0x02: // line primitive
        cmd[cmdSize++] = value;

        final gouraud = cmd[0].bit28;
        final polyline = cmd[0].bit27;

        if (polyline && value & 0xf000f000 == 0x50005000) {
          cmdSize = 0;
          break;
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

      case 0x03: // rectangle primitive
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
          final (clut, v0, u0) = !textured
              ? (0, 0, 0)
              : (cmd[2] >> 16, cmd[2] >> 8 & 0xff, cmd[2] & 0xff);
          final (w, h) = switch (size) {
            0 => (cmd[sizeIndex] & xMask, cmd[sizeIndex] >> 16 & yMask),
            1 => (1, 1),
            2 => (8, 8),
            3 => (16, 16),
            _ => throw "unreachable",
          };
          final (x0, y0) = (cmd[1] & xMask, cmd[1] >> 16 & yMask);
          for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
              if (textured) {
                pset16(x0 + x, y0 + y,
                    getTextureColor(u0 + x, v0 + y, clut, status));
              } else {
                pset24(x0 + x, y0 + y, cmd[0].mask24);
              }
            }
          }

          // debugLog(
          //     "GP0 rectangle primitive completed : ${cmd.sublist(0, cmdSize).map((e) => e.hex32).join(" ")} "
          //     "($x0, $y0) $w x $h ($u0, $v0) "
          //     "clut:${clut.hex16} ${clut << 4 & 0x3e0},${clut >> 5 & 0x1ff} page:${status.hex16} ${status << 6 & 0x3c0},${status << 4 & 0x100} c${status >> 7 & 3} ");
          cmdSize = 0;
        }

      case 0x04: // vram to vram blit
        cmd[cmdSize++] = value;

        if (cmdSize == 4) {
          bltFromY = (cmd[1] >> 16) & yMask;
          bltPosY = (cmd[2] >> 16) & yMask;
          bltSizeY = (cmd[3] >> 16).maskZeroMax(yMask);

          bltFromX = cmd[1] & xMask;
          bltPosX = cmd[2] & xMask;
          bltSizeX = cmd[3].maskZeroMax(xMask);
          // debugLog(
          //     "GP0 vram to vram blit: [${cmd.sublist(0, cmdSize).map((e) => e.hex32).join(" ")}] $bltFromX,$bltFromY -> $bltPosX,$bltPosY w:$bltSizeX h:$bltSizeY");

          while (cmdSize == 4) {
            writeFrameBuffer16(
                bltPosX, bltPosY, readFrameBuffer16(bltFromX, bltFromY));
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
                return true;
              }
            }
          }
        }
        return true;

      case 0x05: // cpu to vram blit
        if (cmdSize == 3) {
          for (final v in [value.mask16, value >> 16]) {
            writeFrameBuffer16(bltPosX, bltPosY, v);
            bltPosX++;
            bltSizeX--;

            if (bltSizeX == 0) {
              bltPosX = cmd[1] & xMask;
              bltSizeX = cmd[2].maskZeroMax(xMask);

              bltPosY++;
              bltSizeY--;

              if (bltSizeY == 0) {
                // debugLog(
                //     "GPU0: blit cpu to vram: completed  pc:${bus.cpu.pc.hex32} clk:$frame:$scanline:${bus.cpu.clocks} ");
                cmdSize = 0;
                break;
              }
            }
          }

          return true;
        }

        cmd[cmdSize++] = value;

        if (cmdSize == 3) {
          bltPosX = cmd[1] & xMask;
          bltSizeX = cmd[2].maskZeroMax(xMask);

          bltPosY = cmd[1] >> 16 & yMask;
          bltSizeY = (cmd[2] >> 16).maskZeroMax(yMask);

          // debugLog(
          //     "GPU0: blit cpu to vram: ${cmd.sublist(0, cmdSize).map((e) => e.hex32).join(" ")} ($bltPosX, $bltPosY) $bltSizeX x $bltSizeY");
        }

      case 0x06: // vram to cpu blit
        cmd[cmdSize++] = value;

        if (cmdSize == 3) {
          bltFromX = cmd[1] & xMask;
          bltSizeX = cmd[2].maskZeroMax(xMask);

          bltFromY = cmd[1] >> 16 & yMask;
          bltSizeY = (cmd[2] >> 16).maskZeroMax(yMask);

          // debugLog(
          //     "GPU0: blit vram to cpu: ${cmd.sublist(0, cmdSize).map((e) => e.hex32).join(" ")} ($bltFromX, $bltFromY) $bltSizeX x $bltSizeY");

          cmdSize++;
        }

      default:
        return false;
    }

    return true;
  }

  postRead() {
    if (cmdSize == 0) {
      return;
    }

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
        textureMaskY = value >> 5 & 0x1f;
        textureOffsetX = value >> 10 & 0x1f;
        textureOffsetY = value >> 15 & 0x1f;

      case 0xe3: // set drawing area top left
        drawingX1 = value & xMask;
        drawingY1 = value >> 10 & yMask;

      case 0xe4: // set drawing area bottom right
        drawingX2 = value & xMask;
        drawingY2 = value >> 10 & yMask;

      case 0xe5: // set drawing offset
        drawingOffsetX = value & 0x7ff;
        drawingOffsetY = value >> 11 & 0x7ff;

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
}

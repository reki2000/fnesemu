part of 'gpu.dart';

extension Gpu0 on Gpu {
  void writeGp0(int value) {
    if (!cmdReady || !handleSingleCommand(value)) {
      if (!handleCommand(value)) {
        debugLog(
            "invalid GP0 command cmd0:${value.hex24} cmd:${cmd.sublist(0, cmdSize).map((e) => e.hex32).join(" ")}");
        cmdSize = 0;
      }
    }
  }

  static const xMask = 0x3ff;
  static const yMask = 0x1ff;

  bool handleCommand(int value) {
    final cmd0 = cmdSize == 0 ? value : cmd[0];
    switch (cmd0 >> 29) {
      case 0x00: // misc
        switch (cmd0 >> 24) {
          case 0x02: // quick rectangle fill
            break;

          default:
            return false;
        }
        break;

      case 0x01: // polygon primitive
        return false;

      case 0x02: // line primitive
        return false;

      case 0x03: // rectangle primitive
        cmd[cmdSize++] = value;

        final textured = cmd[0].bit26;
        final size = cmd[0] >> 27 & 3;

        int beginIndex = 2;
        int sizeIndex = 3;

        if (textured) {
          beginIndex++;
          sizeIndex++;
        }

        if (size == 0) {
          beginIndex++;
        }

        if (cmdSize == beginIndex) {
          final (clut, u0, v0) = textured
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
          int v = v0;
          for (int y = 0; y < h; y++) {
            int u = u0;
            for (int x = 0; x < w; x++) {
              final c24 = textured ? getTexureColor(u, v, clut) : cmd[0].mask24;
              pset24(x0 + x, y0 + y, c24);
              u++;
            }
            v++;
          }

          // debugLog(
          //     "GP0 rectangle primitive completed : ${cmd.sublist(0, cmdSize).map((e) => e.hex32).join(" ")}");
          cmdSize = 0;
        }

      case 0x04: // vram to vram blit
        if (cmdSize == 3) {
          cmd[cmdSize++] = value;

          bltFromY = cmd[1] >> 16 & yMask;
          bltPosY = cmd[2] >> 16 & yMask;
          bltSizeY = (value >> 16).maskZeroMax(yMask);

          bltFromX = cmd[1] & xMask;
          bltPosX = cmd[2] & xMask;
          bltSizeX = value.maskZeroMax(xMask);

          debugLog(
              "GP0 vram to vram blit : ${cmd.sublist(0, cmdSize).map((e) => e.hex32).join(" ")}");

          while (cmdSize == 4) {
            writeFrameBuffer32(
                bltPosX, bltPosY, readFrameBuffer32(bltFromX, bltFromY));
            bltPosX += 2;
            bltFromX += 2;
            bltSizeX -= 2;

            if (bltSizeX == 0) {
              bltPosX = cmd[2] & xMask;
              bltFromX = cmd[1] & xMask;
              bltSizeX = cmd[3].maskZeroMax(xMask);

              bltFromY++;
              bltPosY++;
              bltSizeY--;

              if (bltSizeY == 0) {
                cmdSize = 0;
              }
            }
          }

          cmd[cmdSize++] = value;

          return true;
        }

      case 0x05: // cpu to vram blit
        if (cmdSize == 3) {
          writeFrameBuffer32(bltPosX, bltPosY, value);
          bltPosX += 2;
          bltSizeX -= 2;

          if (bltSizeX == 0) {
            bltPosX = cmd[1] & xMask;
            bltSizeX = cmd[2].maskZeroMax(xMask);

            bltPosY++;
            bltSizeY--;

            if (bltSizeY == 0) {
              debugLog("GP0 cpu to vram blit completed");
              cmdSize = 0;
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

          debugLog(
              "GP0 cpu to vram blit : ${cmd.sublist(0, cmdSize).map((e) => e.hex32).join(" ")}");
        }

      case 0x06: // vram to cpu blit
        cmd[cmdSize++] = value;

        if (cmdSize == 3) {
          bltFromX = cmd[1] & xMask;
          bltFromY = cmd[1] >> 16 & yMask;
          bltSizeX = cmd[2].maskZeroMax(xMask);
          bltSizeY = (cmd[2] >> 16).maskZeroMax(yMask);

          debugLog(
              "GP0 vram to cpu blit : ${cmd.sublist(0, cmdSize).map((e) => e.hex32).join(" ")}");

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

    readValue = readFrameBuffer32(bltFromX, bltFromY);
    bltFromX += 2;
    bltSizeX -= 2;

    if (bltSizeX == 0) {
      bltFromX = cmd[1] & xMask;
      bltSizeX = (cmd[2].dec & xMask).inc;
      bltSizeY--;
      bltFromY++;

      if (bltSizeY == 0) {
        debugLog("GP0 vram to cpu blit completed");
        cmdSize = 0;
      }
    }
  }

  bool handleSingleCommand(int value) {
    switch (value >> 24) {
      case 0x01: // clear cache
        break;

      case 0xe1: // draw mode setting
        status = status.setMasked(0x7ff, value).setBit(15, value.bit11);

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

      default:
        return false;
    }

    return true;
  }
}

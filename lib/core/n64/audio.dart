import 'dart:typed_data';
import 'bus.dart';

/// Scalar audio command interpreter for the original and Shindou SM64 ABIs.
class N64Audio {
  final N64Bus bus;
  final memory = Uint8List(65536);
  final book = Int16List(256);
  final segments = List<int>.filled(16, 0);
  int input = 0, output = 0, count = 0, loop = 0, tasks = 0;
  int wetLeft = 0, wetRight = 0, dryRight = 0;
  int leftVol = 0, rightVol = 0, dryVol = 32767, wetVol = 0;
  int leftTarget = 0, rightTarget = 0, leftRate = 0, rightRate = 0;
  int reverb = 0, reverbRamp = 0, leftRamp = 0, rightRamp = 0;
  bool shindou = false;
  N64Audio(this.bus);
  void reset() {
    memory.fillRange(0, memory.length, 0);
    book.fillRange(0, book.length, 0);
    tasks = 0;
    input = output = count = loop = 0;
    segments.fillRange(0, segments.length, 0);
    wetLeft = wetRight = dryRight = leftVol = rightVol = wetVol = 0;
    dryVol = 32767;
    leftTarget = rightTarget =
        leftRate = rightRate = reverb = reverbRamp = leftRamp = rightRamp = 0;
  }

  int read(int a) =>
      ((memory[a & 65535] << 8) | memory[(a + 1) & 65535]).toSigned(16);
  void write(int a, int v) {
    v = v.clamp(-32768, 32767);
    memory[a & 65535] = v >> 8;
    memory[(a + 1) & 65535] = v;
  }

  int addr(int value) =>
      ((value & 0xffffff) + segments[(value >> 24) & 15]) & 0x7fffff;
  void dma(int ram, int dmem, int bytes, bool load) {
    if (ram + bytes > bus.ram.length || dmem + bytes > memory.length) {
      throw StateError('Audio DMA out of bounds');
    }
    if (load) {
      memory.setRange(dmem, dmem + bytes, bus.ram, ram);
    } else {
      bus.ram.setRange(ram, ram + bytes, memory, dmem);
    }
  }

  void task(int start, int length, {required bool newer}) {
    shindou = newer;
    tasks++;
    for (var at = start; at < start + length; at += 8) {
      final w0 = bus.ramRead(at, 4),
          w1 = bus.ramRead(at + 4, 4),
          op = w0 >> 24,
          flags = (w0 >> 16) & 255;
      final high = (w1 >> 16) & 65535, low = w1 & 65535;
      switch (op) {
        case 0:
          break;
        case 1:
          decode(w0, w1, false);
        case 2:
          final start = w0 & 65535, end = start + (w1 & 65535);
          if (end > memory.length) {
            throw StateError('Audio clear buffer out of bounds');
          }
          memory.fillRange(start, end, 0);
        case 3:
          if (shindou) throw UnsupportedError('Shindou audio opcode 3');
          for (var i = 0; i < count; i += 2) {
            final s = read(input + i),
                l = s * leftVol ~/ 32768,
                r = s * rightVol ~/ 32768;
            write(output + i, read(output + i) + l * dryVol ~/ 32768);
            write(dryRight + i, read(dryRight + i) + r * dryVol ~/ 32768);
            if ((flags & 8) != 0) {
              write(wetLeft + i, read(wetLeft + i) + l * wetVol ~/ 32768);
              write(wetRight + i, read(wetRight + i) + r * wetVol ~/ 32768);
            }
          }
          // Persist mixer state; ramp rates use Q16 fixed point.
          for (var i = 0; i < 40; i++) {
            bus.ramWrite(addr(w1) + i * 2, 0, 2);
          }
        case 4:
          if (!shindou) {
            dma(addr(w1), input, count, true);
          } else {
            mix(high, low, flags * 16, 32767);
          }
        case 5:
          resample(w0, w1, false);
        case 6:
          if (!shindou) {
            dma(addr(w1), output, count, false);
          } else {
            resample(w0, w1, true);
          }
        case 7:
          if (shindou) throw UnsupportedError('Shindou audio opcode 7');
          segments[(w1 >> 24) & 15] = w1 & 0xffffff;
        case 8:
          if ((flags & 8) == 0 || shindou) {
            input = w0 & 65535;
            output = high;
            count = low;
          } else {
            dryRight = w0 & 65535;
            wetLeft = high;
            wetRight = low;
          }
        case 9:
          if (shindou) throw UnsupportedError('Shindou audio opcode 9');
          if ((flags & 8) != 0) {
            dryVol = (w0 & 65535).toSigned(16);
            wetVol = low.toSigned(16);
          } else if ((flags & 4) != 0) {
            if ((flags & 2) != 0) {
              leftVol = (w0 & 65535).toSigned(16);
            } else {
              rightVol = (w0 & 65535).toSigned(16);
            }
          } else if ((flags & 2) != 0) {
            leftTarget = (w0 & 65535).toSigned(16);
            leftRate = w1.toSigned(32);
          } else {
            rightTarget = (w0 & 65535).toSigned(16);
            rightRate = w1.toSigned(32);
          }
        case 10:
          final source = w0 & 65535, bytes = (low + 15) & ~15;
          memory.setRange(high, high + bytes,
              Uint8List.fromList(memory.sublist(source, source + bytes)));
        case 11:
          final n = (w0 & 65535) ~/ 2;
          if (n > book.length) {
            throw StateError('ADPCM predictor table overflow');
          }
          for (var i = 0; i < n; i++) {
            book[i] = bus.ramRead(addr(w1) + i * 2, 2).toSigned(16);
          }
        case 12:
          mix(high, low, shindou ? flags * 16 : count,
              (w0 & 65535).toSigned(16));
        case 13:
          final dest = shindou ? w0 & 65535 : output,
              bytes = shindou ? flags * 16 : count;
          for (var i = 0; i < bytes; i += 2) {
            write(dest + i * 2, read(high + i));
            write(dest + i * 2 + 2, read(low + i));
          }
        case 14:
          throw UnsupportedError('Audio pole filter opcode');
        case 15:
          loop = addr(w1);
        case 16:
          final source = w0 & 65535, bytes = ((low + 31) & ~31) * flags;
          memory.setRange(high, high + bytes,
              Uint8List.fromList(memory.sublist(source, source + bytes)));
        case 17:
          for (var i = 0; i < ((w0 & 65535) + 7) & ~7; i++) {
            write(low + i * 2, read(high + i * 4));
          }
        case 18:
          reverb = flags << 8;
          reverbRamp = (w0 & 65535).toSigned(16);
          leftRamp = high.toSigned(16);
          rightRamp = low.toSigned(16);
        case 19:
          final source = flags << 4, n = (((w0 >> 8) & 255) + 15) & ~15;
          final dl = ((w1 >> 24) & 255) << 4,
              dr = ((w1 >> 16) & 255) << 4,
              wl = ((w1 >> 8) & 255) << 4,
              wr = (w1 & 255) << 4;
          for (var i = 0; i < n; i++) {
            final sample = read(source + i * 2);
            var l = (sample * leftVol) >> 16, r = (sample * rightVol) >> 16;
            if ((w0 & 2) != 0) l = -l;
            if ((w0 & 1) != 0) r = -r;
            write(dl + i * 2, read(dl + i * 2) + l);
            write(dr + i * 2, read(dr + i * 2) + r);
            if ((w0 & 4) != 0) {
              final swap = l;
              l = r;
              r = swap;
            }
            write(wl + i * 2, read(wl + i * 2) + ((l * reverb) >> 16));
            write(wr + i * 2, read(wr + i * 2) + ((r * reverb) >> 16));
            if (i % 8 == 7) {
              leftVol = (leftVol + leftRamp) & 65535;
              rightVol = (rightVol + rightRamp) & 65535;
              reverb = (reverb + reverbRamp) & 65535;
            }
          }
        case 20:
          dma(addr(w1), w0 & 65535, flags * 16, true);
        case 21:
          dma(addr(w1), w0 & 65535, flags * 16, false);
        case 22:
          leftVol = high;
          rightVol = low;
        case 23:
          decode(w0, w1, true);
        case 24:
          for (var i = 0; i < (((w0 & 65535) + 31) & ~31); i += 2) {
            write(high + i, (read(high + i) * flags) >> 4);
          }
        case 26:
          final source = w0 & 65535,
              block = Uint8List.fromList(memory.sublist(source, source + 128));
          for (var i = 0; i < flags; i++) {
            memory.setRange(high + i * 128, high + (i + 1) * 128, block);
          }
        default:
          throw UnsupportedError('Audio command opcode $op');
      }
    }
  }

  void mix(int source, int dest, int bytes, int gain) {
    for (var i = 0; i < bytes; i += 2) {
      write(dest + i, read(dest + i) + ((read(source + i) * gain) >> 15));
    }
  }

  void decode(int w0, int w1, bool signed8) {
    final flags = (w0 >> 16) & 255, state = addr(w1);
    final history = List<int>.filled(16, 0);
    if ((flags & 1) == 0) {
      for (var i = 0; i < 16; i++) {
        history[i] = bus
            .ramRead(((flags & 2) != 0 ? loop : state) + i * 2, 2)
            .toSigned(16);
      }
    }
    for (var i = 0; i < 16; i++) {
      write(output + i * 2, history[i]);
    }
    var src = input, dst = output + 32;
    for (var block = 0; block < (count + 31) ~/ 32; block++) {
      if (signed8) {
        for (var i = 0; i < 16; i++) {
          history[i] = memory[src++].toSigned(8) << 8;
          write(dst, history[i]);
          dst += 2;
        }
        continue;
      }
      final header = memory[src++],
          scale = header >> 4,
          predictor = (header & 15) * 16;
      if (predictor + 16 > book.length) {
        throw StateError('ADPCM predictor out of bounds');
      }
      final residual = List<int>.generate(16, (i) {
        final nibble =
            i.isEven ? memory[src + i ~/ 2] >> 4 : memory[src + i ~/ 2] & 15;
        return nibble.toSigned(4) << scale.clamp(0, 12);
      });
      src += 8;
      for (var group = 0; group < 2; group++) {
        final prev1 = history[15],
            prev2 = history[14],
            samples = List<int>.filled(8, 0);
        for (var i = 0; i < 8; i++) {
          var prediction =
              book[predictor + i] * prev2 + book[predictor + 8 + i] * prev1;
          for (var j = 0; j < i; j++) {
            prediction +=
                book[predictor + 8 + i - j - 1] * residual[group * 8 + j];
          }
          samples[i] = (residual[group * 8 + i] + (prediction >> 11))
              .clamp(-32768, 32767);
          write(dst, samples[i]);
          dst += 2;
        }
        history.setRange(0, 8, history, 8);
        history.setRange(8, 16, samples);
      }
    }
    for (var i = 0; i < 16; i++) {
      bus.ramWrite(state + i * 2, history[i], 2);
    }
  }

  void resample(int w0, int w1, bool nearest) {
    final flags = (w0 >> 16) & 255, pitch = (w0 & 65535) * 2, state = addr(w1);
    var fraction = nearest
        ? w1 & 65535
        : ((flags & 1) != 0 ? 0 : bus.ramRead(state + 8, 2));
    final base = input - 8;
    if (!nearest) {
      for (var i = 0; i < 4; i++) {
        write(base + i * 2,
            (flags & 1) != 0 ? 0 : bus.ramRead(state + i * 2, 2).toSigned(16));
      }
    }
    var pos = nearest ? input : base;
    for (var i = 0; i < ((count + 7) & ~7); i += 2) {
      // Linear interpolation; the hardware's four-tap filter remains approximate.
      final a = read(pos), b = read(pos + 2);
      write(output + i, nearest ? a : a + (((b - a) * fraction) >> 16));
      fraction += pitch;
      pos += (fraction >> 16) * 2;
      fraction &= 65535;
    }
    if (!nearest) {
      for (var i = 0; i < 4; i++) {
        bus.ramWrite(state + i * 2, read(pos + i * 2), 2);
      }
      bus.ramWrite(state + 8, fraction, 2);
    }
  }
}

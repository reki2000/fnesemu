import 'package:fnesemu_core/src/core/psp/memory.dart';
import 'package:fnesemu_core/src/core/psp/mpeg.dart';
import 'package:test/test.dart';

const _rbAt = 0x08900000;
const _dataAt = 0x08910000;
const _auAt = 0x08a00000;

/// Writes a pack with one PES packet of [stream] carrying [payload] into
/// packet [index], with the time stamp [pts] when it is not negative, after
/// a system header when [systemHeader].
void _pack(PspMemory mem, int index, int stream, List<int> payload,
    {int pts = -1, bool systemHeader = false}) {
  final at = _dataAt + index * PspMpeg.packetSize;
  final bytes = <int>[0, 0, 1, 0xba, ...List.filled(9, 0), 0xf8];
  if (systemHeader) bytes.addAll([0, 0, 1, 0xbb, 0, 2, 0x80, 0]);
  final header = <int>[];
  if (pts >= 0) {
    header.addAll([
      0x21 | (pts >> 29 & 0xe),
      pts >> 22 & 0xff,
      (pts >> 14 & 0xfe) | 1,
      pts >> 7 & 0xff,
      (pts << 1 & 0xfe) | 1,
    ]);
  }
  final length = 3 + header.length + payload.length;
  bytes.addAll([0, 0, 1, stream, length >> 8, length & 0xff, 0x81]);
  bytes.addAll([pts >= 0 ? 0x80 : 0, header.length, ...header, ...payload]);
  for (var i = 0; i < bytes.length; i++) {
    mem.write8(at + i, bytes[i]);
  }
}

int _pts(PspMemory mem) => mem.read32(_auAt) << 32 | mem.read32(_auAt + 4);

void main() {
  late PspMemory mem;
  late PspMpeg mpeg;

  setUp(() {
    mem = PspMemory();
    mpeg = PspMpeg(mem)
      ..construct(_rbAt, 8, _dataAt, 0x08800000, 0)
      ..ringbuffer = _rbAt
      ..videoOn = true
      ..audioOn = true
      ..flush();
  });

  test('video units run from one access unit delimiter to the next', () {
    const aud = [0, 0, 0, 1, 9, 0xf0];
    // A system header before the video in the first pack, two units there,
    // the third delimiter split across the packets that follow.
    _pack(mem, 0, 0xe0, [...aud, 0x11, ...aud, 0x22, 0, 0], pts: 90000,
        systemHeader: true);
    _pack(mem, 1, 0xbd, [1, 2, 3], pts: 90000);
    _pack(mem, 2, 0xe0, [0, 1]);
    _pack(mem, 3, 0xe0, [9, 0xf0, 0x33]);
    mpeg.put(4);
    expect(mpeg.videoUnit(_auAt), 0);
    expect(_pts(mem), 90000);
    expect(mpeg.lastVideoUnit, [0, 0, 0, 1, 9, 0xf0, 0x11]);
    expect(mpeg.videoUnit(_auAt), 0);
    expect(_pts(mem), 90000 + PspMpeg.videoFrameTicks);
    expect(mpeg.lastVideoUnit, [0, 0, 0, 1, 9, 0xf0, 0x22]);
    // the third unit has no delimiter after it yet
    expect(mpeg.videoUnit(_auAt), PspMpeg.errorNoData);
    _pack(mem, 4, 0xe0, [...aud]);
    mpeg.put(1);
    expect(mpeg.videoUnit(_auAt), 0);
    expect(_pts(mem), 90000 + 2 * PspMpeg.videoFrameTicks);
    expect(mpeg.lastVideoUnit, [0, 0, 0, 1, 9, 0xf0, 0x33]);
  });

  test('audio units follow the audio clock and free the ring buffer', () {
    _pack(mem, 0, 0xbd, [0], pts: 1000);
    _pack(mem, 1, 0xbd, [0], pts: 1000 + PspMpeg.audioFrameTicks * 2);
    mpeg.put(2);
    mpeg.videoOn = false;
    expect(mpeg.free, 6);
    expect(mpeg.audioUnit(_auAt), 0);
    expect(_pts(mem), 1000);
    expect(mpeg.audioUnit(_auAt), 0);
    expect(_pts(mem), 1000 + PspMpeg.audioFrameTicks);
    // The clock reaches the second packet, whose successor is not there.
    expect(mpeg.audioUnit(_auAt), PspMpeg.errorNoData);
    expect(mpeg.free, 7);
    expect(mem.read32(_rbAt + 12), 7);
  });

  test('a put fills up to the end of the buffer', () {
    mpeg.put(6);
    mpeg.videoOn = false;
    mpeg.audioOn = false;
    expect(mpeg.chunk(8), 2);
    expect(mpeg.putAt, _dataAt + 6 * PspMpeg.packetSize);
  });
}

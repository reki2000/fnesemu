import 'dart:typed_data';

import 'package:fnesemu_core/src/core/psp/atrac.dart';
import 'package:fnesemu_core/src/core/psp/memory.dart';
import 'package:fnesemu_core/src/media_decoder.dart';
import 'package:fnesemu_core/src/util/state.dart';
import 'package:test/test.dart';

const _fileAt = 0x08900000;
const _outAt = 0x08a00000;
const _countAt = 0x08a10000, _endAt = 0x08a10004, _remainAt = 0x08a10008;

/// A decoder whose samples are the first byte of the frame on the left and
/// its negation on the right; it records the flushes.
class _FakeDecoder implements MediaDecoder {
  var flushes = 0;
  @override
  String get name => 'fake';
  @override
  bool supports(MediaCodec codec) => codec == MediaCodec.atrac3plus;
  @override
  bool open(int id, MediaCodec codec,
          {int sampleRate = 44100,
          int channels = 2,
          int blockAlign = 0,
          Uint8List? codecData}) {
    opened = (codec, codecData);
    return true;
  }

  (MediaCodec, Uint8List?)? opened;
  @override
  MediaPicture? decodeVideo(int id, Uint8List unit) => null;
  @override
  Int16List? decodeAudio(int id, Uint8List frame) => Int16List(4096)
    ..setAll(0, [
      for (var i = 0; i < 2048; i++) ...[frame[0], -frame[0]]
    ]);
  @override
  void flush(int id) => flushes++;
  @override
  void close(int id) {}
}

/// Writes a WAVE file of three 16-byte ATRAC3plus frames whose first bytes
/// are 1, 2 and 3: 5000 samples after a delay of 100, with a loop from
/// 1000 to 2499 when [loop].
int _writeFile(PspMemory mem, {bool loop = true}) {
  final bytes = BytesBuilder();
  void word(int v) => bytes
      .add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
  void half(int v) => bytes
      .add((ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List());
  void tag(String t) => bytes.add(t.codeUnits);
  tag('RIFF');
  word(0);
  tag('WAVE');
  tag('fmt ');
  word(16);
  half(0xfffe);
  half(2);
  word(44100);
  word(0);
  half(16);
  half(0);
  tag('fact');
  word(8);
  word(5000);
  word(100);
  if (loop) {
    tag('smpl');
    word(60);
    for (var i = 0; i < 7; i++) {
      word(0);
    }
    word(1); // loops
    word(0);
    word(0); // id
    word(0); // type
    word(1000);
    word(2499);
    word(0);
    word(0);
  }
  tag('data');
  word(48);
  for (var f = 1; f <= 3; f++) {
    bytes.add([f, ...List.filled(15, 0)]);
  }
  final file = bytes.takeBytes();
  for (var i = 0; i < file.length; i++) {
    mem.write8(_fileAt + i, file[i]);
  }
  return file.length;
}

void main() {
  late PspMemory mem;
  late PspAtrac atrac;
  late _FakeDecoder decoder;

  setUp(() {
    mem = PspMemory();
    decoder = _FakeDecoder();
    atrac = PspAtrac(mem)..decoder = decoder;
  });

  int decode(int id) => atrac.decode(id, _outAt, _countAt, _endAt, _remainAt);

  test('reads the samples and the loop of a WAVE file', () {
    final id = atrac.setDataAndGetId(_fileAt, _writeFile(mem));
    expect(id, 0);
    expect(atrac.soundSample(id, _countAt, _endAt, _remainAt), 0);
    expect(mem.read32(_countAt), 4999);
    expect(mem.read32(_endAt), 1000);
    expect(mem.read32(_remainAt), 2499);
  });

  test('decodes after the delay and loops back to the loop start', () {
    final id = atrac.setDataAndGetId(_fileAt, _writeFile(mem));
    atrac.setLoopNum(id, -1);
    expect(decode(id), 0);
    // the first frame less the delay
    expect(mem.read32(_countAt), 2048 - 100);
    expect(mem.read32(_outAt), 0xffff0001);
    expect(mem.read32(_remainAt), 0xffffffff);
    // the second frame up to the loop end
    expect(decode(id), 0);
    expect(mem.read32(_countAt), 2500 - 1948);
    expect(mem.read32(_outAt), 0xfffe0002);
    expect(mem.read32(_endAt), 0);
    // back at the loop start, in the first frame again
    expect(decode(id), 0);
    expect(mem.read32(_countAt), 2048 - 1100);
    expect(mem.read32(_outAt), 0xffff0001);
    expect(decoder.flushes, 1);
  });

  test('ends at the last sample without a loop', () {
    final id = atrac.setDataAndGetId(_fileAt, _writeFile(mem, loop: false));
    var total = 0;
    while (decode(id) == 0) {
      total += mem.read32(_countAt);
    }
    expect(total, 5000);
    expect(mem.read32(_endAt), 1);
    expect(decode(id), PspAtrac.errorAllDataDecoded);
  });

  test('a file without a loop refuses a loop count', () {
    final id = atrac.setDataAndGetId(_fileAt, _writeFile(mem, loop: false));
    expect(atrac.setLoopNum(id, -1), PspAtrac.errorNoLoop);
    expect(atrac.loopStatus(id, _countAt, _endAt), 0);
    expect(mem.read32(_countAt), 0);
    expect(mem.read32(_endAt), 0);
  });

  test('streams a file through a buffer smaller than the file', () {
    final length = _writeFile(mem, loop: false);
    mem.write32(_fileAt + 4, length - 8); // the RIFF size
    final file = [for (var i = 0; i < length; i++) mem.read8(_fileAt + i)];
    // The buffer holds the header and the first frame.
    final size = length - 32;
    final id = atrac.setHalfwayBufferAndGetId(_fileAt, size, size);
    expect(id, 0);
    expect(atrac.remainFrame(id, _remainAt), 0);
    expect(mem.read32(_remainAt), 1);
    // The rest goes to the start of the buffer, from the file offset
    // after the received part.
    const writeAt = 0x08a20000, availableAt = 0x08a20004;
    const offsetAt = 0x08a20008;
    expect(atrac.streamDataInfo(id, writeAt, availableAt, offsetAt), 0);
    expect(mem.read32(writeAt), _fileAt);
    expect(mem.read32(availableAt), 32);
    expect(mem.read32(offsetAt), size);
    expect(decode(id), 0);
    expect(mem.read32(_outAt), 0xffff0001);
    for (var i = 0; i < 32; i++) {
      mem.write8(_fileAt + i, file[size + i]);
    }
    expect(atrac.addStreamData(id, 32), 0);
    expect(atrac.remainFrame(id, _remainAt), 0);
    expect(mem.read32(_remainAt), 0xffffffff);
    // A restored player reads the header from the saved part, as the
    // buffer holds other bytes now.
    final writer = StateWriter('psp', 9, 0);
    atrac.saveState(writer);
    final restored = PspAtrac(mem)..decoder = decoder;
    restored.loadState(StateReader(writer.take(), 'psp', 9, 0));
    expect(restored.decode(id, _outAt, _countAt, _endAt, _remainAt), 0);
    expect(mem.read32(_outAt), 0xfffe0002);
    expect(restored.decode(id, _outAt, _countAt, _endAt, _remainAt), 0);
    expect(mem.read32(_outAt), 0xfffd0003);
  });
}

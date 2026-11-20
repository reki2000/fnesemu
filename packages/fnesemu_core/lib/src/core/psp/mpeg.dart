import '../../util/state.dart';
import 'memory.dart';

/// The movie player library (sceMpeg) without a picture or sound decoder.
///
/// The guest streams a PSMF movie into a ring buffer of 2048-byte packets.
/// Each packet is an MPEG program stream pack with one PES packet: video
/// (stream 0xe0) or ATRAC audio (private stream 0xbd). This class follows
/// the time stamps of the stream so the movie plays for its own length
/// and ends when the data ends. A video access unit starts at an access
/// unit delimiter (H.264 NAL unit type 9) of the video elementary stream;
/// it takes the time stamp of its PES packet when it is the first unit
/// there, and otherwise the previous one plus a frame at 29.97 Hz. An
/// audio access unit advances an audio clock by one ATRAC frame (2048
/// samples at 44100 Hz). Decoding writes a black picture and silence.
///
/// The ring buffer lives in guest memory with the SDK layout: the packet
/// count, the read and write packet indexes, the free packet count, the
/// packet size, the data address, the read callback and its argument.
class PspMpeg {
  final PspMemory mem;
  PspMpeg(this.mem);

  static const packetSize = 0x800;
  static const errorNoData = 0x80618001;

  /// The video frame length in 90 kHz time stamp units.
  static const videoFrameTicks = 3003;

  /// The ATRAC frame length in 90 kHz time stamp units.
  static const audioFrameTicks = 2048 * 90000 ~/ 44100;

  /// The stream types of RegistStream.
  static const streamVideo = 0, streamAudio = 1;

  /// The guest address of the ring buffer.
  int ringbuffer = 0;

  /// The packets put into the ring buffer since the last flush.
  int written = 0;

  /// The packets each stream has consumed since the last flush.
  int videoAt = 0, audioAt = 0;

  bool videoOn = false, audioOn = false;

  /// The time stamp of the next audio access unit, or -1 before the first.
  int audioPts = -1;

  // The video scan: the payload byte reached in packet [videoAt], the
  // zero bytes just before it, whether a start code waits for its NAL
  // header, the last unit's time stamp and the packet whose time stamp
  // a unit took.
  int videoOffset = 0;
  int videoZeros = 0;
  bool videoStart = false;
  int videoPts = -1;
  int videoPtsPacket = -1;

  /// The pixel format of decoded pictures (3: 32-bit).
  int pixelMode = 3;

  int get packets => mem.read32(ringbuffer);
  int get dataAt => mem.read32(ringbuffer + 20);
  int get callback => mem.read32(ringbuffer + 24);
  int get callbackArg => mem.read32(ringbuffer + 28);

  /// The packets no registered stream needs any more.
  int get consumed {
    var at = written;
    if (videoOn && videoAt < at) at = videoAt;
    if (audioOn && audioAt < at) at = audioAt;
    return at;
  }

  int get free => packets - (written - consumed);

  /// Writes the ring buffer of [packetCount] packets at [data] to [at].
  void construct(int at, int packetCount, int data, int func, int arg) {
    mem.write32(at, packetCount);
    mem.write32(at + 4, 0);
    mem.write32(at + 8, 0);
    mem.write32(at + 12, packetCount);
    mem.write32(at + 16, packetSize);
    mem.write32(at + 20, data);
    mem.write32(at + 24, func);
    mem.write32(at + 28, arg);
    mem.write32(at + 32, data + packetCount * packetSize);
    mem.write32(at + 36, 0);
    mem.write32(at + 40, 0);
  }

  /// Restarts the stream: the ring buffer empties.
  void flush() {
    written = 0;
    videoAt = 0;
    videoOffset = 0;
    videoZeros = 0;
    videoStart = false;
    videoPts = -1;
    videoPtsPacket = -1;
    audioAt = 0;
    audioPts = -1;
    _sync();
  }

  /// The packets one read callback may fill at once: no more than
  /// [want], the free space and the space up to the end of the buffer.
  int chunk(int want) {
    final count = packets;
    if (count == 0) return 0;
    var n = want < free ? want : free;
    final room = count - written % count;
    if (n > room) n = room;
    return n < 0 ? 0 : n;
  }

  /// The guest address the next put writes to.
  int get putAt => dataAt + (packets == 0 ? 0 : written % packets) * packetSize;

  /// Records [n] packets written by the read callback.
  void put(int n) {
    written += n;
    _sync();
  }

  void _sync() {
    if (ringbuffer == 0) return;
    final count = packets;
    if (count == 0) return;
    mem.write32(ringbuffer + 4, consumed % count);
    mem.write32(ringbuffer + 8, written % count);
    mem.write32(ringbuffer + 12, free);
  }

  /// The PES stream id of packet [index], its time stamps and the guest
  /// addresses of its payload, or null for a packet that is not a pack
  /// with a PES packet.
  ({int stream, int pts, int dts, int start, int end})? _packet(int index) {
    final at = dataAt + (index % packets) * packetSize;
    if (mem.read32(at) != 0xba010000) return null;
    final pes = at + 14 + (mem.read8(at + 13) & 7);
    if (mem.read8(pes) != 0 || mem.read8(pes + 1) != 0) return null;
    if (mem.read8(pes + 2) != 1) return null;
    final stream = mem.read8(pes + 3);
    final length = mem.read8(pes + 4) << 8 | mem.read8(pes + 5);
    final flags = mem.read8(pes + 7);
    var pts = -1, dts = -1;
    if (flags & 0x80 != 0) {
      pts = _timeStamp(pes + 9);
      dts = flags & 0x40 != 0 ? _timeStamp(pes + 14) : pts;
    }
    var end = pes + 6 + length;
    if (end > at + packetSize) end = at + packetSize;
    return (
      stream: stream,
      pts: pts,
      dts: dts,
      start: pes + 9 + mem.read8(pes + 8),
      end: end,
    );
  }

  /// The 33-bit time stamp coded in five bytes at [at].
  int _timeStamp(int at) =>
      (mem.read8(at) >> 1 & 7) << 30 |
      mem.read8(at + 1) << 22 |
      (mem.read8(at + 2) >> 1) << 15 |
      mem.read8(at + 3) << 7 |
      mem.read8(at + 4) >> 1;

  /// Takes the next video access unit into the unit at [au]. Returns
  /// [errorNoData] when the ring buffer holds no further one.
  int videoUnit(int au) {
    while (videoAt < written) {
      final p = _packet(videoAt);
      if (p == null || p.stream != 0xe0) {
        videoAt++;
        videoOffset = 0;
        continue;
      }
      for (var a = p.start + videoOffset; a < p.end; a++) {
        final byte = mem.read8(a);
        if (videoStart) {
          videoStart = false;
          if (byte & 0x1f == 9) {
            videoOffset = a + 1 - p.start;
            final first = p.pts >= 0 && videoPtsPacket != videoAt;
            if (first) {
              videoPts = p.pts;
              videoPtsPacket = videoAt;
            } else {
              videoPts = videoPts < 0 ? 0 : videoPts + videoFrameTicks;
            }
            _sync();
            final dts = first ? p.dts : videoPts;
            _writeUnit(au, videoPts, dts);
            return 0;
          }
        }
        if (byte == 0) {
          videoZeros++;
        } else {
          if (byte == 1 && videoZeros >= 2) videoStart = true;
          videoZeros = 0;
        }
      }
      videoAt++;
      videoOffset = 0;
    }
    _sync();
    return errorNoData;
  }

  /// Takes the next audio access unit into the unit at [au]. The audio
  /// clock starts at the first audio time stamp; the packets whose time
  /// stamps it has passed are consumed. Returns [errorNoData] when the
  /// ring buffer holds no audio beyond the clock.
  int audioUnit(int au) {
    var next = -1;
    for (var i = audioAt; i < written; i++) {
      final p = _packet(i);
      if (p == null || p.stream != 0xbd) {
        if (i == audioAt) audioAt++;
        continue;
      }
      if (p.pts < 0) continue;
      if (audioPts < 0) audioPts = p.pts;
      if (p.pts > audioPts) {
        next = p.pts;
        break;
      }
      audioAt = i;
    }
    if (next < 0) {
      _sync();
      return errorNoData;
    }
    _writeUnit(au, audioPts, audioPts);
    audioPts += audioFrameTicks;
    _sync();
    return 0;
  }

  /// Fills an access unit: the time stamps as high and low words, then
  /// the elementary stream buffer and the size, which stay.
  void _writeUnit(int au, int pts, int dts) {
    mem.write32(au, pts >>> 32);
    mem.write32(au + 4, pts & 0xffffffff);
    mem.write32(au + 8, dts >>> 32);
    mem.write32(au + 12, dts & 0xffffffff);
  }

  /// Resets an access unit to no time stamp with its stream buffer.
  void initUnit(int au, int esBuffer) {
    for (var i = 0; i < 16; i += 4) {
      mem.write32(au + i, 0xffffffff);
    }
    mem.write32(au + 16, esBuffer);
    mem.write32(au + 20, 0);
  }

  /// Writes a black picture of 272 lines [width] pixels apart at [at].
  void blackPicture(int at, int width) {
    final bytes = pixelMode == 3 ? 4 : 2;
    final black = pixelMode == 3 ? 0xff000000 : 0;
    final end = at + width * 272 * bytes;
    if (bytes == 4) {
      for (var a = at; a < end; a += 4) {
        mem.write32(a, black);
      }
    } else {
      for (var a = at; a < end; a += 4) {
        mem.write32(a, 0);
      }
    }
  }

  /// Writes the silence of one ATRAC frame (2048 stereo 16-bit samples).
  void silence(int at) {
    for (var a = at; a < at + 2048 * 4; a += 4) {
      mem.write32(a, 0);
    }
  }

  void saveState(StateWriter writer) {
    writer.ints([
      ringbuffer, written, videoAt, audioAt, videoOn ? 1 : 0, //
      audioOn ? 1 : 0, audioPts, pixelMode, videoOffset, videoZeros,
      videoStart ? 1 : 0, videoPts, videoPtsPacket,
    ]);
  }

  void loadState(StateReader reader) {
    final x = reader.ints();
    ringbuffer = x[0];
    written = x[1];
    videoAt = x[2];
    audioAt = x[3];
    videoOn = x[4] != 0;
    audioOn = x[5] != 0;
    audioPts = x[6];
    pixelMode = x[7];
    videoOffset = x[8];
    videoZeros = x[9];
    videoStart = x[10] != 0;
    videoPts = x[11];
    videoPtsPacket = x[12];
  }
}

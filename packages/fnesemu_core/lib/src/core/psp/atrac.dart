import 'dart:typed_data';

import '../../media_decoder.dart';
import '../../util/state.dart';
import 'memory.dart';

/// The ATRAC player of the system software (sceAtrac3plus) for a guest
/// that hands it a whole RIFF WAVE file in memory.
///
/// The file has a format chunk (the codec, the channels, the sample rate
/// and the frame size as the block alignment), a fact chunk (the number of
/// samples, then the samples the decoded stream has before the first
/// one), an optional sample chunk with a loop, and the data chunk of
/// frames. ATRAC3plus frames hold 2048 samples per channel and ATRAC3
/// frames 1024. A decode call returns the samples of one frame from the
/// play position as 16-bit stereo, cut at the loop end or the end of the
/// file; a mono file is played on both channels. Looping goes back to the
/// loop start while the loop count is not zero (-1 loops forever).
///
/// Frames decode through the [decoder], ATRAC3 with the extension of the
/// format chunk as its codec data; without a decoder for the codec the
/// samples are silence.
///
/// A streaming setup (the halfway buffer calls) gives only the start of
/// the file, in a buffer the guest then refills with the rest. The player
/// copies each part it receives into a whole copy of the file, so the
/// buffer is free again at once: the stream info asks for the next bytes
/// of the file at the write position, which moves through the buffer and
/// wraps at its end. Frames that have not arrived yet play as silence.
///
/// The error codes follow the public SDK lists; they are not verified on
/// hardware.
class PspAtrac {
  PspAtrac(this.mem);

  final PspMemory mem;

  /// The decoder of the frames, from the core; null plays silence.
  MediaDecoder? decoder;

  static const slotCount = 6;

  static const errorNoId = 0x80630003;
  static const errorBadId = 0x80630005;
  static const errorUnknownFormat = 0x80630006;
  static const errorNoData = 0x80630010;
  static const errorNoLoop = 0x80630021;
  static const errorSecondBufferNotNeeded = 0x80630022;
  static const errorAllDataDecoded = 0x80630024;

  /// The media ids of the slots at [decoder] start here.
  static const mediaIdBase = 0x100;

  final _slots = List<_AtracSlot?>.filled(slotCount, null);

  _AtracSlot? _slot(int id) => id >= 0 && id < slotCount ? _slots[id] : null;

  /// Takes a free slot for [codec] (0x1000 ATRAC3plus, 0x1001 ATRAC3)
  /// without data; returns its id or [errorNoId].
  int allocate(int codec) {
    final id = _slots.indexOf(null);
    if (id < 0) return errorNoId;
    _slots[id] = _AtracSlot()..codec = codec;
    return id;
  }

  /// Takes a free slot and sets the file of [size] bytes at [at] into it.
  int setDataAndGetId(int at, int size) {
    final id = _slots.indexOf(null);
    if (id < 0) return errorNoId;
    final slot = _AtracSlot();
    final result = _parse(slot, at, size);
    if (result != 0) return result;
    _slots[id] = slot;
    return id;
  }

  /// Sets the file of [size] bytes at [at] into the slot [id].
  int setData(int id, int at, int size) {
    final slot = _slot(id);
    if (slot == null) return errorBadId;
    _close(id);
    return _parse(slot, at, size);
  }

  /// Takes a free slot and sets the start of a file into it: [readSize]
  /// bytes in a buffer of [bufferSize] bytes at [at].
  int setHalfwayBufferAndGetId(int at, int readSize, int bufferSize) {
    final id = _slots.indexOf(null);
    if (id < 0) return errorNoId;
    final slot = _AtracSlot();
    final result = _parseHalfway(slot, at, readSize, bufferSize);
    if (result != 0) return result;
    _slots[id] = slot;
    return id;
  }

  /// Sets the start of a file into the slot [id], as
  /// [setHalfwayBufferAndGetId] does.
  int setHalfwayBuffer(int id, int at, int readSize, int bufferSize) {
    final slot = _slot(id);
    if (slot == null) return errorBadId;
    _close(id);
    return _parseHalfway(slot, at, readSize, bufferSize);
  }

  int _parseHalfway(_AtracSlot slot, int at, int readSize, int bufferSize) {
    if (readSize < 12 || readSize > bufferSize) return errorUnknownFormat;
    // The RIFF size gives the length of the whole file.
    final fileSize = mem.read32(at + 4) + 8;
    final result = _parse(slot, at, fileSize < readSize ? readSize : fileSize);
    if (result != 0) return result;
    slot
      ..stream = Uint8List(slot.size)
      ..bufferSize = bufferSize
      ..received = 0
      ..writeAt = 0;
    _receive(slot, at, readSize < slot.size ? readSize : slot.size);
    return 0;
  }

  /// Copies [count] bytes at [at] to the end of the received part of the
  /// file and moves the write position on.
  void _receive(_AtracSlot slot, int at, int count) {
    final stream = slot.stream!;
    if (count > stream.length - slot.received) {
      count = stream.length - slot.received;
    }
    for (var i = 0; i < count; i++) {
      stream[slot.received + i] = mem.read8(at + i);
    }
    slot.received += count;
    slot.writeAt += count;
    if (slot.writeAt >= slot.bufferSize) slot.writeAt = 0;
  }

  /// The guest wrote [count] more bytes at the write position.
  int addStreamData(int id, int count) {
    final slot = _slot(id);
    if (slot == null) return errorBadId;
    if (slot.stream != null && count > 0) {
      _receive(slot, slot.buffer + slot.writeAt, count);
    }
    return 0;
  }

  int release(int id) {
    if (_slot(id) == null) return errorBadId;
    _close(id);
    _slots[id] = null;
    return 0;
  }

  /// The bytes a parse reads in place of memory from the address
  /// [_headerAt] on: the received part of a restored stream, whose
  /// buffer holds other parts of the file by now.
  Uint8List? _header;
  int _headerAt = 0;

  int _read16(int at) {
    final header = _header;
    final i = at - _headerAt;
    if (header == null || i < 0 || i + 2 > header.length) return mem.read16(at);
    return header[i] | header[i + 1] << 8;
  }

  int _read32(int at) => _read16(at) | _read16(at + 2) << 16;

  int _read8(int at) => _read16(at & ~1) >> (at & 1) * 8 & 0xff;

  int _parse(_AtracSlot slot, int at, int size) {
    if (size < 12 ||
        _read32(at) != 0x46464952 || // RIFF
        _read32(at + 8) != 0x45564157) {
      // WAVE
      return errorUnknownFormat;
    }
    var chunk = at + 12;
    var hasFormat = false, hasData = false;
    slot
      ..buffer = at
      ..size = size
      ..loopStart = -1
      ..loopEnd = -1
      ..delay = 0
      ..samples = 0
      ..position = 0
      ..loopNum = 0
      ..lastFrame = -1;
    while (chunk + 8 <= at + size && !hasData) {
      final id = _read32(chunk);
      final length = _read32(chunk + 4);
      final body = chunk + 8;
      switch (id) {
        case 0x20746d66: // fmt
          final tag = _read16(body);
          slot
            ..codec = tag == 0x0270 ? 0x1001 : 0x1000
            ..channels = _read16(body + 2)
            ..sampleRate = _read32(body + 4)
            ..blockAlign = _read16(body + 12);
          // The bytes after the extension size, which the ATRAC3 decoder
          // reads.
          var extra = length >= 18 ? _read16(body + 16) : 0;
          if (extra > length - 18) extra = length - 18;
          slot.codecData = Uint8List.fromList([
            for (var i = 0; i < extra; i++) _read8(body + 18 + i),
          ]);
          hasFormat = true;
        case 0x74636166: // fact
          slot.samples = _read32(body);
          if (length >= 8) slot.delay = _read32(body + 4);
        case 0x6c706d73: // smpl
          if (length >= 36 + 24 && _read32(body + 28) > 0) {
            slot
              ..loopStart = _read32(body + 36 + 8)
              ..loopEnd = _read32(body + 36 + 12);
          }
        case 0x61746164: // data
          slot
            ..dataAt = body
            ..dataSize = length;
          hasData = true;
      }
      chunk = body + length + (length & 1);
    }
    if (!hasFormat || !hasData || slot.blockAlign == 0) {
      return errorUnknownFormat;
    }
    if (slot.dataAt + slot.dataSize > at + size) {
      slot.dataSize = at + size - slot.dataAt;
    }
    if (slot.samples == 0) {
      slot.samples =
          slot.dataSize ~/ slot.blockAlign * slot.frameSamples - slot.delay;
    }
    return 0;
  }

  /// Decodes the next samples of slot [id] as stereo into [out] and writes
  /// their count, the end flag and the remaining frames (-1: the whole
  /// file is in memory) to [countAt], [endAt] and [remainAt].
  int decode(int id, int out, int countAt, int endAt, int remainAt) {
    final slot = _slot(id);
    if (slot == null) return errorBadId;
    if (slot.blockAlign == 0) return errorNoData;
    if (slot.position >= slot.limit) {
      _write(countAt, 0);
      _write(endAt, 1);
      _write(remainAt, _remain(slot));
      return errorAllDataDecoded;
    }
    final spf = slot.frameSamples;
    final stream = slot.position + slot.delay;
    final frame = stream ~/ spf;
    final skip = stream % spf;
    var count = spf - skip;
    if (count > slot.limit - slot.position) {
      count = slot.limit - slot.position;
    }
    final samples = _decodeFrame(id, slot, frame);
    final channels = slot.channels == 1 ? 1 : 2;
    for (var i = 0; i < count; i++) {
      var left = 0, right = 0;
      final at = (skip + i) * channels;
      if (samples != null && at + channels <= samples.length) {
        left = samples[at];
        right = samples[at + channels - 1];
      }
      mem.write32(out + i * 4, (left & 0xffff) | (right & 0xffff) << 16);
    }
    slot.position += count;
    if (slot.position >= slot.limit && slot.looping) {
      slot.position = slot.loopStart;
      if (slot.loopNum > 0) slot.loopNum--;
    }
    _write(countAt, count);
    _write(endAt, slot.position >= slot.limit ? 1 : 0);
    _write(remainAt, _remain(slot));
    return 0;
  }

  /// Decodes [frame] of the data; a frame that does not follow the last
  /// one restarts the decoder from the frame before it, which the overlap
  /// of the transform needs.
  Int16List? _decodeFrame(int id, _AtracSlot slot, int frame) {
    final decoder = this.decoder;
    final codec =
        slot.codec == 0x1001 ? MediaCodec.atrac3 : MediaCodec.atrac3plus;
    if (decoder == null || !decoder.supports(codec)) return null;
    final mediaId = mediaIdBase + id;
    if (!slot.open) {
      slot.open = decoder.open(mediaId, codec,
          sampleRate: slot.sampleRate,
          channels: slot.channels,
          blockAlign: slot.blockAlign,
          codecData: slot.codecData);
      if (!slot.open) return null;
      slot.lastFrame = -1;
    }
    if (frame != slot.lastFrame + 1) {
      decoder.flush(mediaId);
      if (frame > 0) decoder.decodeAudio(mediaId, _frameBytes(slot, frame - 1));
    }
    slot.lastFrame = frame;
    if ((frame + 1) * slot.blockAlign > slot.dataSize) return null;
    if (slot.stream != null &&
        slot.dataAt - slot.buffer + (frame + 1) * slot.blockAlign >
            slot.received) {
      return null;
    }
    return decoder.decodeAudio(mediaId, _frameBytes(slot, frame));
  }

  Uint8List _frameBytes(_AtracSlot slot, int frame) {
    final stream = slot.stream;
    if (stream != null) {
      final at = slot.dataAt - slot.buffer + frame * slot.blockAlign;
      return Uint8List.sublistView(stream, at, at + slot.blockAlign);
    }
    final bytes = Uint8List(slot.blockAlign);
    final at = slot.dataAt + frame * slot.blockAlign;
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = mem.read8(at + i);
    }
    return bytes;
  }

  void _close(int id) {
    final slot = _slots[id];
    if (slot != null && slot.open) decoder?.close(mediaIdBase + id);
    slot?.open = false;
  }

  /// Closes the streams at the decoder, before it changes.
  void closeAll() {
    for (var id = 0; id < slotCount; id++) {
      _close(id);
    }
  }

  void _write(int at, int value) {
    if (at != 0) mem.write32(at, value);
  }

  /// Writes the last sample, the loop start and the loop end (-1 without
  /// a loop).
  int soundSample(int id, int endAt, int loopStartAt, int loopEndAt) {
    final slot = _slot(id);
    if (slot == null) return errorBadId;
    _write(endAt, slot.samples - 1);
    _write(loopStartAt, slot.loopStart);
    _write(loopEndAt, slot.loopEnd);
    return 0;
  }

  /// Sets the number of loops. A file without a loop keeps playing once
  /// and the call fails, so the loop count the guest reads back stays 0.
  int setLoopNum(int id, int count) {
    final slot = _slot(id);
    if (slot == null) return errorBadId;
    if (slot.loopStart < 0) return errorNoLoop;
    slot.loopNum = count;
    return 0;
  }

  /// Moves the play position to [sample]. A stream receives the
  /// [written] bytes the guest put where [bufferInfoForResetting] asked.
  int resetPlayPosition(int id, int sample, int written) {
    final slot = _slot(id);
    if (slot == null) return errorBadId;
    slot.position = sample;
    slot.lastFrame = -1;
    if (slot.stream != null && written > 0) {
      slot.writeAt = 0;
      _receive(slot, slot.buffer, written);
    }
    return 0;
  }

  int remainFrame(int id, int at) {
    final slot = _slot(id);
    if (slot == null) return errorBadId;
    _write(at, _remain(slot));
    return 0;
  }

  /// The received frames after the play position, or -1 when the whole
  /// file is in memory.
  int _remain(_AtracSlot slot) {
    if (slot.stream == null || slot.received >= slot.size) return -1;
    final frames =
        (slot.received - (slot.dataAt - slot.buffer)) ~/ slot.blockAlign;
    final at = (slot.position + slot.delay) ~/ slot.frameSamples;
    return frames > at ? frames - at : 0;
  }

  /// GetInternalErrorInfo: no decoder error is kept.
  int internalError(int id, int at) {
    if (_slot(id) == null) return errorBadId;
    _write(at, 0);
    return 0;
  }

  int nextSample(int id, int at) {
    final slot = _slot(id);
    if (slot == null) return errorBadId;
    final skip = (slot.position + slot.delay) % slot.frameSamples;
    var count = slot.frameSamples - skip;
    if (count > slot.limit - slot.position) count = slot.limit - slot.position;
    _write(at, count < 0 ? 0 : count);
    return 0;
  }

  int maxSample(int id, int at) {
    final slot = _slot(id);
    if (slot == null) return errorBadId;
    _write(at, slot.frameSamples);
    return 0;
  }

  int nextDecodePosition(int id, int at) {
    final slot = _slot(id);
    if (slot == null) return errorBadId;
    if (slot.position >= slot.limit) return errorAllDataDecoded;
    _write(at, slot.position);
    return 0;
  }

  int channel(int id, int at) {
    final slot = _slot(id);
    if (slot == null) return errorBadId;
    _write(at, slot.channels);
    return 0;
  }

  /// The bit rate in kilobits per second.
  int bitrate(int id, int at) {
    final slot = _slot(id);
    if (slot == null) return errorBadId;
    _write(at,
        slot.blockAlign * 8 * slot.sampleRate ~/ (slot.frameSamples * 1000));
    return 0;
  }

  int loopStatus(int id, int countAt, int statusAt) {
    final slot = _slot(id);
    if (slot == null) return errorBadId;
    _write(countAt, slot.loopNum);
    _write(statusAt, slot.loopStart >= 0 ? 1 : 0);
    return 0;
  }

  /// Where the guest writes the next part of the file, how many bytes
  /// fit there, and the file offset of those bytes. When the whole file
  /// is in memory there is nowhere to write.
  int streamDataInfo(int id, int writeAt, int availableAt, int offsetAt) {
    final slot = _slot(id);
    if (slot == null) return errorBadId;
    if (slot.stream == null) {
      _write(writeAt, slot.buffer + slot.size);
      _write(availableAt, 0);
      _write(offsetAt, slot.size);
      return 0;
    }
    var available = slot.bufferSize - slot.writeAt;
    if (available > slot.size - slot.received) {
      available = slot.size - slot.received;
    }
    _write(writeAt, slot.buffer + slot.writeAt);
    _write(availableAt, available);
    _write(offsetAt, slot.received);
    return 0;
  }

  int bufferInfoForResetting(int id, int at) {
    final slot = _slot(id);
    if (slot == null) return errorBadId;
    if (slot.stream != null) {
      // The received part stays in the copy: the guest refills the
      // buffer from its start with the bytes after it.
      var needed = slot.size - slot.received;
      if (needed > slot.bufferSize) needed = slot.bufferSize;
      for (var i = 0; i < 8; i++) {
        _write(at + i * 4, 0);
      }
      _write(at, slot.buffer);
      _write(at + 4, slot.bufferSize);
      _write(at + 8, needed);
      _write(at + 12, slot.received);
      return 0;
    }
    // the first buffer: write position, writable and needed bytes, file
    // position; then the same for the second buffer
    for (var i = 0; i < 8; i++) {
      _write(at + i * 4, i == 0 || i == 4 ? slot.buffer + slot.size : 0);
    }
    _write(at + 12, slot.size);
    return 0;
  }

  void saveState(StateWriter writer) {
    final out = <int>[];
    for (var id = 0; id < slotCount; id++) {
      final slot = _slots[id];
      if (slot == null) continue;
      out.addAll([
        id, slot.codec, slot.buffer, slot.size, slot.position, //
        slot.loopNum,
      ]);
    }
    writer.ints(out);
    // The streams: the slot, the buffer size, the write position and the
    // received part of the file.
    for (var id = 0; id < slotCount; id++) {
      final slot = _slots[id];
      final stream = slot?.stream;
      if (slot == null || stream == null) continue;
      writer.ints([id, slot.bufferSize, slot.writeAt]);
      writer.bytes(Uint8List.sublistView(stream, 0, slot.received));
    }
    writer.ints([-1]);
  }

  void loadState(StateReader reader) {
    closeAll();
    _slots.fillRange(0, slotCount, null);
    final x = reader.ints();
    final streams = <int, (List<int>, Uint8List)>{};
    if (reader.version >= 9) {
      for (var s = reader.ints(); s[0] >= 0; s = reader.ints()) {
        streams[s[0]] = (s, reader.bytes());
      }
    }
    for (var i = 0; i + 5 < x.length; i += 6) {
      final slot = _AtracSlot()..codec = x[i + 1];
      final stream = streams[x[i]];
      if (stream != null) {
        _header = stream.$2;
        _headerAt = x[i + 2];
      }
      if (x[i + 3] > 0) _parse(slot, x[i + 2], x[i + 3]);
      _header = null;
      slot
        ..position = x[i + 4]
        ..loopNum = x[i + 5];
      if (stream != null) {
        final (s, received) = stream;
        slot
          ..stream = (Uint8List(slot.size)..setAll(0, received))
          ..bufferSize = s[1]
          ..writeAt = s[2]
          ..received = received.length;
      }
      _slots[x[i]] = slot;
    }
  }
}

class _AtracSlot {
  int codec = 0x1000;

  /// The extension of the format chunk, the codec data of ATRAC3.
  Uint8List codecData = Uint8List(0);
  int buffer = 0, size = 0;
  int channels = 2, sampleRate = 44100, blockAlign = 0;
  int dataAt = 0, dataSize = 0;

  /// The samples of the file and the decoded samples before the first.
  int samples = 0, delay = 0;
  int loopStart = -1, loopEnd = -1;
  int loopNum = 0;

  /// The next sample to play.
  int position = 0;

  /// The frame the decoder took last, and whether it is open.
  int lastFrame = -1;
  bool open = false;

  /// A stream: the copy of the file, of [size] bytes, with the received
  /// part first; the size of the guest's buffer at [buffer] and the
  /// offset in it where the next part goes. Null when the whole file is
  /// in memory.
  Uint8List? stream;
  int bufferSize = 0, received = 0, writeAt = 0;

  int get frameSamples => codec == 0x1001 ? 1024 : 2048;

  bool get looping => loopNum != 0 && loopStart >= 0 && loopEnd >= loopStart;

  /// The play position where decoding stops: after the loop end while it
  /// loops, at the end of the file otherwise.
  int get limit => looping ? loopEnd + 1 : samples;
}

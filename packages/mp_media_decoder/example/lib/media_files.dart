import 'dart:typed_data';

/// Splits an H.264 Annex B byte stream into access units. A unit ends where
/// an access unit delimiter, a parameter set, an SEI or a slice starting a
/// new picture follows a slice.
List<Uint8List> h264AccessUnits(Uint8List stream) {
  final starts = <(int, int)>[]; // the start of each NAL unit and its type
  for (var i = 0; i + 3 < stream.length; i++) {
    if (stream[i] == 0 && stream[i + 1] == 0 && stream[i + 2] == 1) {
      final start = i > 0 && stream[i - 1] == 0 ? i - 1 : i;
      starts.add((start, stream[i + 3] & 0x1f));
      i += 2;
    }
  }
  final units = <Uint8List>[];
  var unitStart = 0;
  var sawSlice = false;
  for (var n = 0; n < starts.length; n++) {
    final (start, type) = starts[n];
    final isSlice = type == 1 || type == 5;
    // first_mb_in_slice of 0 (a leading 1 bit in its Exp-Golomb code)
    // starts a new picture
    final newPicture = isSlice && stream[_headerEnd(stream, start)] & 0x80 != 0;
    final startsUnit = type == 9 || type == 7 || type == 8 || type == 6;
    if (sawSlice && start > unitStart && (startsUnit || newPicture)) {
      units.add(Uint8List.sublistView(stream, unitStart, start));
      unitStart = start;
      sawSlice = false;
    }
    if (isSlice) sawSlice = true;
  }
  if (unitStart < stream.length) {
    units.add(Uint8List.sublistView(stream, unitStart));
  }
  return units;
}

/// The byte after the start code and the NAL header of the NAL unit at
/// [start].
int _headerEnd(Uint8List stream, int start) =>
    stream[start + 2] == 1 ? start + 4 : start + 5;

/// The video elementary stream (stream 0xe0) of a PSMF movie of a PSP disc:
/// a header whose big-endian word at byte 8 is the offset of an MPEG
/// program stream of 2048-byte packs. Null when [file] is not one.
Uint8List? psmfVideo(Uint8List file) {
  if (file.length < 16 ||
      String.fromCharCodes(file.sublist(0, 4)) != 'PSMF') {
    return null;
  }
  final data = ByteData.sublistView(file);
  final out = BytesBuilder(copy: false);
  var at = data.getUint32(8);
  while (at + 14 <= file.length) {
    if (data.getUint32(at) != 0x000001ba) {
      at++;
      continue;
    }
    // a pack may hold several PES packets: a system header, a private
    // stream, the video and padding
    var pes = at + 14 + (file[at + 13] & 7);
    while (pes + 6 <= file.length && data.getUint32(pes) >> 8 == 1) {
      final stream = file[pes + 3];
      if (stream == 0xba) break;
      final end = pes + 6 + data.getUint16(pes + 4);
      if (stream == 0xe0 && end <= file.length) {
        out.add(Uint8List.sublistView(file, pes + 9 + file[pes + 8], end));
      }
      pes = end;
    }
    at = pes > at ? pes : at + 1;
  }
  return out.takeBytes();
}

/// The ATRAC3plus frames of a RIFF WAVE file (`.at3`), with the settings of
/// its format chunk.
class Atrac3plusFile {
  Atrac3plusFile(this.sampleRate, this.channels, this.blockAlign, this.data);

  final int sampleRate;
  final int channels;
  final int blockAlign;
  final Uint8List data;

  int get frameCount => blockAlign == 0 ? 0 : data.length ~/ blockAlign;

  Uint8List frame(int index) =>
      Uint8List.sublistView(data, index * blockAlign, (index + 1) * blockAlign);

  /// Reads the format and data chunks; null when [file] is not a WAVE file
  /// with them.
  static Atrac3plusFile? parse(Uint8List file) {
    if (file.length < 12 ||
        String.fromCharCodes(file.sublist(0, 4)) != 'RIFF' ||
        String.fromCharCodes(file.sublist(8, 12)) != 'WAVE') {
      return null;
    }
    final data = ByteData.sublistView(file);
    int? sampleRate, channels, blockAlign;
    Uint8List? samples;
    var at = 12;
    while (at + 8 <= file.length) {
      final id = String.fromCharCodes(file.sublist(at, at + 4));
      final size = data.getUint32(at + 4, Endian.little);
      final body = at + 8;
      final end = body + size > file.length ? file.length : body + size;
      if (id == 'fmt ' && size >= 16) {
        channels = data.getUint16(body + 2, Endian.little);
        sampleRate = data.getUint32(body + 4, Endian.little);
        blockAlign = data.getUint16(body + 12, Endian.little);
      } else if (id == 'data') {
        samples = Uint8List.sublistView(file, body, end);
      }
      at = body + size + (size & 1);
    }
    if (sampleRate == null || samples == null) return null;
    return Atrac3plusFile(sampleRate, channels!, blockAlign!, samples);
  }
}

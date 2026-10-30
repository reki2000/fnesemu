import 'dart:typed_data';

import '../../cdrom.dart';

// signature bytes, as character codes
const dcDiscSignature = '\x53\x45\x47\x41\x20\x53\x45\x47\x41\x4b\x41\x54\x41'
    '\x4e\x41\x20\x53\x45\x47\x41\x20\x45\x4e\x54\x45\x52\x50\x52\x49\x53\x45'
    '\x53';

/// Identifies the platform; metadata alone does not establish BIOS bootability.
Future<bool> isDcDisc(CdromDrive drive) => _DiscIdentity(drive).matches();

class _DiscIdentity {
  _DiscIdentity(this.drive) : initial = drive.status;

  final CdromDrive drive;
  final CdromDriveStatus initial;
  static const _blockSize = 2048;
  static const _maxDirectoryBlocks = 128;

  bool get _current =>
      drive.status.isReady && drive.status.discId == initial.discId;

  Future<bool> matches() async {
    if (!initial.isReady) return false;
    final tracks = initial.toc.tracks
        .where((track) =>
            !track.isAudio &&
            track.startLba >= 0 &&
            track.sectors > 0 &&
            track.startLba + track.sectors <= initial.toc.totalSectors)
        .toList();
    if (tracks.isEmpty) return false;
    // IP.BIN is in the last data track's system area.
    // Retail metadata also appears at the beginning of the first data track (Comstedt, 2000).
    final candidates = {tracks.last, tracks.first};
    for (final track in candidates) {
      if (_header(await _read(track, track.startLba))) return _current;
    }
    for (final track in candidates) {
      if (await _isoHeader(track)) return _current;
    }
    return false;
  }

  static bool _header(Uint8List? data) {
    if (data == null || data.length < 256) return false;
    for (var i = 0; i < dcDiscSignature.length; i++) {
      if (data[i] != dcDiscSignature.codeUnitAt(i)) return false;
    }
    return true;
  }

  Future<Uint8List?> _read(CdromTrack track, int lba) async {
    if (lba < track.startLba || lba >= track.startLba + track.sectors) {
      return null;
    }
    for (var attempt = 0; attempt < 5000 && _current; attempt++) {
      final raw = drive.read(lba);
      if (!_current) return null;
      if (raw != null) return _payload(raw);
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    return null;
  }

  static Uint8List? _payload(Uint8List raw) {
    if (raw.length != cdSectorSize) return null;
    for (var i = 0; i < cdSync.length; i++) {
      if (raw[i] != cdSync[i]) return null;
    }
    if (raw[15] == 1) return Uint8List.sublistView(raw, 16, 2064);
    if (raw[15] != 2 || raw[18] & 0x20 != 0) return null;
    for (var i = 16; i < 20; i++) {
      if (raw[i] != raw[i + 4]) return null;
    }
    return Uint8List.sublistView(raw, 24, 2072);
  }

  // ECMA-119 sections 7.2.3 and 7.3.3 store each value in both byte orders.
  static int? _both(Uint8List data, int offset, int width) {
    var little = 0, big = 0;
    for (var i = 0; i < width; i++) {
      little += data[offset + i] * (1 << (8 * i));
      big = big * 256 + data[offset + width + i];
    }
    return little == big ? little : null;
  }

  static (int, int)? _extent(Uint8List record, int volumeBlocks) {
    final block = _both(record, 2, 4), size = _both(record, 10, 4);
    if (block == null ||
        size == null ||
        record[1] != 0 ||
        record[26] != 0 ||
        record[27] != 0 ||
        _both(record, 28, 2) != 1 ||
        size == 0 ||
        block + (size + _blockSize - 1) ~/ _blockSize > volumeBlocks) {
      return null;
    }
    return (block, size);
  }

  Future<bool> _isoHeader(CdromTrack track) async {
    // Root-only metadata lookup, not an executable loader or ISO mount.
    // Bounds are identification policy, not limits imposed by ECMA-119.
    Uint8List? primary;
    for (var block = 16; block < 48; block++) {
      final data = await _read(track, track.startLba + block);
      if (data == null ||
          String.fromCharCodes(data.sublist(1, 6)) != 'CD001' ||
          data[6] != 1 ||
          data[0] == 255) {
        return false;
      }
      if (data[0] == 1) {
        primary = data;
        break;
      }
    }
    if (primary == null ||
        primary[881] != 1 ||
        _both(primary, 128, 2) != _blockSize ||
        _both(primary, 120, 2) != 1 ||
        _both(primary, 124, 2) != 1) {
      return false;
    }
    final volumeBlocks = _both(primary, 80, 4);
    if (volumeBlocks == null ||
        volumeBlocks > track.sectors ||
        volumeBlocks < 17) {
      return false;
    }
    final root = Uint8List.sublistView(primary, 156, 190);
    if (root[0] != 34 ||
        root[25] & 0x86 != 2 ||
        root[32] != 1 ||
        root[33] != 0) {
      return false;
    }
    final location = _extent(root, volumeBlocks);
    if (location == null) return false;
    final (rootBlock, rootSize) = location;
    if (rootSize > _maxDirectoryBlocks * _blockSize) return false;
    for (var offset = 0; offset < rootSize; offset += _blockSize) {
      final data =
          await _read(track, track.startLba + rootBlock + offset ~/ _blockSize);
      if (data == null) return false;
      final available =
          rootSize - offset < _blockSize ? rootSize - offset : _blockSize;
      for (var index = 0; index < available;) {
        final length = data[index];
        if (length == 0) break; // Padding through the end of this block.
        if (length < 34 || length.isOdd || index + length > available) {
          return false;
        }
        final record = Uint8List.sublistView(data, index, index + length);
        final nameSize = record[32];
        if (nameSize == 0 ||
            33 + nameSize + (nameSize.isEven ? 1 : 0) > length ||
            (nameSize.isEven && record[33 + nameSize] != 0)) {
          return false;
        }
        final name = String.fromCharCodes(record.sublist(33, 33 + nameSize));
        if (name == 'IP.BIN;1' || name == 'IP0000.BIN;1') {
          final file = _extent(record, volumeBlocks);
          if (file != null &&
              file.$2 >= 256 &&
              record[25] & 0x86 == 0 &&
              _header(await _read(track, track.startLba + file.$1))) {
            return true;
          }
        }
        index += length;
      }
    }
    return false;
  }
}

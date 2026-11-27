import 'dart:typed_data';

import 'cdrom_drive.dart';

/// A sparse CD/GD/DVD disc image for self-contained benchmarks: stores the TOC
/// and only the sectors and subcodes actually accessed during a benchmark run.
class BenchDisc {
  static const _magic = [0x42, 0x44, 0x49, 0x53, 0x43, 0x30, 0x31, 0x00];
  static const _flagHasSessions = 1 << 0;
  static const _flagHasIsXa = 1 << 1;
  static const _flagIsXa = 1 << 2;
  static const _flagHasSubcodes = 1 << 3;

  final CdromToc toc;
  final Map<int, Uint8List> sectors;
  final Map<int, CdromSubcode> subcodes;
  final bool hasSubcodes;

  const BenchDisc(
    this.toc,
    this.sectors, {
    this.subcodes = const {},
    this.hasSubcodes = false,
  });

  /// Opens a synchronous in-memory [BenchDiscDrive] backed by this disc.
  BenchDiscDrive openDrive() => BenchDiscDrive(this);

  /// Encodes this disc into a compact binary image.
  Uint8List encode() {
    final sessions = toc.sessions;
    final sectorKeys = sectors.keys.toList()..sort();
    final subcodeKeys = subcodes.keys.toList()..sort();

    var totalBytes = 8 + 12 + toc.tracks.length * 12;
    if (sessions != null) totalBytes += sessions.length * 8;
    totalBytes += 4;
    for (final lba in sectorKeys) {
      totalBytes += 6 + sectors[lba]!.length;
    }
    totalBytes += 4;
    for (final lba in subcodeKeys) {
      final sub = subcodes[lba]!;
      totalBytes += 5 + (sub.readable && sub.raw != null ? 96 : 0);
    }

    final out = Uint8List(totalBytes);
    final bd = ByteData.sublistView(out);
    for (var i = 0; i < 8; i++) {
      out[i] = _magic[i];
    }
    var off = 8;
    bd.setUint32(off, toc.totalSectors, Endian.little);
    off += 4;
    out[off++] = toc.medium.index;
    var flags = 0;
    if (sessions != null) flags |= _flagHasSessions;
    if (toc.isXa != null) {
      flags |= _flagHasIsXa;
      if (toc.isXa!) flags |= _flagIsXa;
    }
    if (hasSubcodes) flags |= _flagHasSubcodes;
    out[off++] = flags;
    bd.setUint16(off, toc.tracks.length, Endian.little);
    off += 2;
    bd.setUint16(off, sessions?.length ?? 0, Endian.little);
    off += 2;
    bd.setUint16(off, 0, Endian.little);
    off += 2;

    for (final t in toc.tracks) {
      bd.setUint16(off, t.number, Endian.little);
      out[off + 2] = t.isAudio ? 1 : 0;
      out[off + 3] = 0;
      bd.setInt32(off + 4, t.startLba, Endian.little);
      bd.setUint32(off + 8, t.sectors, Endian.little);
      off += 12;
    }
    if (sessions != null) {
      for (final s in sessions) {
        bd.setUint16(off, s.number, Endian.little);
        bd.setUint16(off + 2, s.firstTrack, Endian.little);
        bd.setInt32(off + 4, s.startLba, Endian.little);
        off += 8;
      }
    }

    bd.setUint32(off, sectorKeys.length, Endian.little);
    off += 4;
    for (final lba in sectorKeys) {
      final data = sectors[lba]!;
      bd.setInt32(off, lba, Endian.little);
      bd.setUint16(off + 4, data.length, Endian.little);
      off += 6;
      out.setRange(off, off + data.length, data);
      off += data.length;
    }

    bd.setUint32(off, subcodeKeys.length, Endian.little);
    off += 4;
    for (final lba in subcodeKeys) {
      final sub = subcodes[lba]!;
      bd.setInt32(off, lba, Endian.little);
      off += 4;
      if (!sub.readable) {
        out[off++] = 1;
      } else if (sub.raw case final raw?) {
        out[off++] = 2;
        out.setRange(off, off + 96, raw);
        off += 96;
      } else {
        out[off++] = 0;
      }
    }
    return out;
  }

  /// Decodes a binary image produced by [encode].
  factory BenchDisc.decode(Uint8List bytes) {
    if (bytes.length < 20) {
      throw const FormatException('bench disc image is too short');
    }
    for (var i = 0; i < 8; i++) {
      if (bytes[i] != _magic[i]) {
        throw const FormatException('invalid bench disc header');
      }
    }
    final bd = ByteData.sublistView(bytes);
    var off = 8;
    final totalSectors = bd.getUint32(off, Endian.little);
    off += 4;
    final mediumIndex = bytes[off++];
    if (mediumIndex >= CdromMedium.values.length) {
      throw FormatException('invalid bench disc medium: $mediumIndex');
    }
    final medium = CdromMedium.values[mediumIndex];
    final flags = bytes[off++];
    final trackCount = bd.getUint16(off, Endian.little);
    off += 2;
    final sessionCount = bd.getUint16(off, Endian.little);
    off += 2;
    off += 2; // reserved

    final tracks = <CdromTrack>[];
    for (var i = 0; i < trackCount; i++) {
      final number = bd.getUint16(off, Endian.little);
      final isAudio = bytes[off + 2] != 0;
      final startLba = bd.getInt32(off + 4, Endian.little);
      final sectors = bd.getUint32(off + 8, Endian.little);
      tracks.add(CdromTrack(number, isAudio, startLba, sectors));
      off += 12;
    }

    List<CdromSession>? sessions;
    if (flags & _flagHasSessions != 0) {
      sessions = <CdromSession>[];
      for (var i = 0; i < sessionCount; i++) {
        final number = bd.getUint16(off, Endian.little);
        final firstTrack = bd.getUint16(off + 2, Endian.little);
        final startLba = bd.getInt32(off + 4, Endian.little);
        sessions.add(CdromSession(number, firstTrack, startLba));
        off += 8;
      }
    }
    final bool? isXa =
        flags & _flagHasIsXa != 0 ? (flags & _flagIsXa != 0) : null;
    final hasSubcodes = flags & _flagHasSubcodes != 0;

    final sectorCount = bd.getUint32(off, Endian.little);
    off += 4;
    final sectors = <int, Uint8List>{};
    for (var i = 0; i < sectorCount; i++) {
      final lba = bd.getInt32(off, Endian.little);
      final len = bd.getUint16(off + 4, Endian.little);
      off += 6;
      sectors[lba] = Uint8List.sublistView(bytes, off, off + len);
      off += len;
    }

    final subcodeCount = bd.getUint32(off, Endian.little);
    off += 4;
    final subcodes = <int, CdromSubcode>{};
    for (var i = 0; i < subcodeCount; i++) {
      final lba = bd.getInt32(off, Endian.little);
      final kind = bytes[off + 4];
      off += 5;
      switch (kind) {
        case 0:
          subcodes[lba] = const CdromSubcode();
        case 1:
          subcodes[lba] = const CdromSubcode(readable: false);
        case 2:
          subcodes[lba] =
              CdromSubcode.fromRaw(Uint8List.sublistView(bytes, off, off + 96));
          off += 96;
        default:
          throw FormatException('invalid bench disc subcode kind: $kind');
      }
    }

    return BenchDisc(
      CdromToc(
        tracks,
        totalSectors,
        sessions: sessions,
        isXa: isXa,
        medium: medium,
      ),
      sectors,
      subcodes: subcodes,
      hasSubcodes: hasSubcodes,
    );
  }
}

/// A synchronous in-memory [CdromDrive] backed by a [BenchDisc].
class BenchDiscDrive implements CdromDrive, CdromSubcodeDrive {
  static final _zeroSector = Uint8List(2352);

  final BenchDisc disc;
  final _events = CdromDriveEvents();
  late CdromDriveStatus _status;

  BenchDiscDrive(this.disc) {
    _status = CdromDriveStatus(CdromDriveState.ready, 1, disc.toc);
  }

  bool _isReadable(int lba) => lba >= 0 && lba < disc.toc.totalSectors;

  @override
  CdromDriveStatus get status => _status;

  @override
  CdromDriveEvent? takeEvent() => _events.take();

  @override
  void clearEvents() => _events.clear();

  @override
  void seek(int lba) {
    final readable = _isReadable(lba);
    final data = disc.sectors[lba];
    _status = CdromDriveStatus(
      CdromDriveState.ready,
      1,
      disc.toc,
      seekLba: lba,
      isSeeking: false,
      seekError: !readable || (data != null && data.isEmpty),
    );
  }

  @override
  Uint8List? read(int lba) {
    if (!_isReadable(lba)) return Uint8List(0);
    return disc.sectors[lba] ?? _zeroSector;
  }

  @override
  CdromSubcode? readSubcode(int lba) {
    if (!_isReadable(lba)) return const CdromSubcode(readable: false);
    if (!disc.hasSubcodes) return const CdromSubcode();
    return disc.subcodes[lba] ?? const CdromSubcode();
  }
}

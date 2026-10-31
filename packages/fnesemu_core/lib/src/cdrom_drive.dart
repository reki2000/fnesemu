import 'dart:collection';
import 'dart:typed_data';

enum CdromDriveState {
  /// no disc in the drive
  empty,

  /// tray is open (during eject)
  trayOpen,

  /// a disc is inserted and the TOC is being read
  loading,

  /// TOC is read and sectors are readable
  ready,

  /// failed to read the TOC
  error,
}

/// Physical tray events and the separate result of reading the inserted disc.
enum CdromDriveEventType { trayOpened, trayClosed, discReady, discError }

class CdromDriveEvent {
  final CdromDriveEventType type;
  final int discId;

  const CdromDriveEvent(this.type, this.discId);
}

/// FIFO for a drive's single core consumer. State transitions are recorded
/// even while emulation is paused; sector reads do not generate events.
class CdromDriveEvents {
  final _queue = Queue<CdromDriveEvent>();

  void add(CdromDriveState state, int discId) {
    final type = switch (state) {
      CdromDriveState.trayOpen => CdromDriveEventType.trayOpened,
      CdromDriveState.empty ||
      CdromDriveState.loading =>
        CdromDriveEventType.trayClosed,
      CdromDriveState.ready => CdromDriveEventType.discReady,
      CdromDriveState.error => CdromDriveEventType.discError,
    };
    _queue.add(CdromDriveEvent(type, discId));
  }

  CdromDriveEvent? take() => _queue.isEmpty ? null : _queue.removeFirst();

  void clear() => _queue.clear();
}

class CdromTrack {
  final int number; // 1..
  final bool isAudio;
  final int startLba; // LBA of INDEX 01, without 2 seconds of lead-in
  final int sectors;

  const CdromTrack(this.number, this.isAudio, this.startLba, this.sectors);

  @override
  String toString() =>
      "track $number ${isAudio ? "audio" : "data"} lba:$startLba sectors:$sectors";
}

/// An explicitly known session boundary, without the two-second lead-in.
class CdromSession {
  final int number; // 1..99, in ascending contiguous order.
  final int firstTrack; // Track number at the session start.
  final int startLba;

  const CdromSession(this.number, this.firstTrack, this.startLba);
}

class CdromToc {
  final List<CdromTrack> tracks;

  /// number of sectors of the disc, from LBA 0 (without lead-in)
  final int totalSectors;

  /// Null means the drive does not expose session metadata; do not infer one.
  final List<CdromSession>? sessions;

  /// Explicit lead-in disc identity; null means XA identity is unavailable.
  final bool? isXa;

  const CdromToc(this.tracks, this.totalSectors, {this.sessions, this.isXa});

  static const empty = CdromToc([], 0);

  bool get isEmpty => tracks.isEmpty;
  int get trackCount => tracks.length;

  int startLba(int trackNo) {
    if (trackNo < 1 || trackNo > tracks.length) {
      throw RangeError("cdrom: invalid track number $trackNo");
    }
    return tracks[trackNo - 1].startLba;
  }

  bool isAudio(int trackNo) => tracks[trackNo - 1].isAudio;

  /// returns true if [lba] (without lead-in) is in an audio track
  bool isAudioLba(int lba) {
    for (int i = tracks.length - 1; i >= 0; i--) {
      if (lba >= tracks[i].startLba) {
        return tracks[i].isAudio;
      }
    }
    return false;
  }
}

/// synchronous snapshot of the drive
class CdromDriveStatus {
  final CdromDriveState state;

  /// incremented on each disc change (eject, insert, TOC read)
  final int discId;

  final CdromToc toc;

  /// LBA of the last [CdromDrive.seek]
  final int seekLba;

  /// true while the sector at [seekLba] is being read
  final bool isSeeking;

  /// true if [seekLba] is not readable
  final bool seekError;

  const CdromDriveStatus(this.state, this.discId, this.toc,
      {this.seekLba = 0, this.isSeeking = false, this.seekError = false});

  static const empty =
      CdromDriveStatus(CdromDriveState.empty, 0, CdromToc.empty);

  bool get isReady => state == CdromDriveState.ready;
  bool get isTrayOpen => state == CdromDriveState.trayOpen;
}

/// A CD-ROM drive seen from the emulator core.
///
/// All accesses are synchronous: the drive reads the image files in the
/// background, and the core polls [status] and [read] until the result is
/// available. All LBAs are without 2 seconds of lead-in.
abstract class CdromDrive {
  /// returns the current status. cheap enough to be polled on each exec.
  CdromDriveStatus get status;

  /// Takes the oldest event, or null. A single core consumes the queue on
  /// its execution thread. Ready/error events belong to [CdromDriveEvent.discId]; ignore
  /// them if a newer medium has replaced that generation.
  CdromDriveEvent? takeEvent();

  /// Discards past events when attaching or resetting to the current status.
  void clearEvents();

  /// moves the head to [lba]. the core polls [CdromDriveStatus.isSeeking]
  /// and [CdromDriveStatus.seekError] for the result.
  void seek(int lba);

  /// returns the raw sector (2352 bytes) at [lba], or null if it has not been
  /// read yet (the drive starts reading it). returns empty data if [lba] is
  /// not readable.
  Uint8List? read(int lba);
}

/// Position decoded from a CRC-validated ADR=1 Q subchannel record.
/// Track/index numbers are binary; elapsed frames exclude any disc lead-in.
class CdromSubcodePosition {
  const CdromSubcodePosition(
      {required this.control,
      required this.track,
      required this.index,
      required this.trackFrames,
      this.discFrames});
  final int control, track, index, trackFrames;

  /// Absolute MSF frame count from the actual Q record, including the lead-in.
  /// Null retains compatibility with providers that supply only track position.
  final int? discFrames;
}

/// Identifier decoded from CRC-validated Q records (ADR=2 catalog or ADR=3 ISRC).
/// An empty value explicitly means not detected; null metadata means unknown.
class CdromSubcodeIdentifier {
  const CdromSubcodeIdentifier(this.value, {required this.frame});
  final String value;

  /// Binary absolute frame within a second (0..74) from the identifier record.
  final int frame;
}

/// Explicitly supplied subchannels for a single requested sector.
/// Null fields mean unavailable metadata, not an invented silent subchannel.
class CdromSubcode {
  const CdromSubcode(
      {this.raw,
      this.position,
      this.catalog,
      this.recording,
      this.readable = true});

  /// Decodes packed P-W symbols using ECMA-130 section 22 and IEC 60908 17.5.3.
  /// Raw symbols are retained even if Q CRC, BCD or a supported layout is invalid.
  /// Lead-in TOC and CD-R recorder/reserved identifiers are not decoded.
  factory CdromSubcode.fromRaw(Uint8List symbols) {
    if (symbols.length != 96) {
      throw ArgumentError.value(
          symbols.length, 'symbols.length', 'Expected 96');
    }
    final raw = Uint8List.fromList(symbols), q = Uint8List(12);
    for (var bit = 0; bit < 96; bit++) {
      q[bit >> 3] |= ((raw[bit] >> 6) & 1) << (7 - (bit & 7));
    }
    var crc = 0;
    for (var byte = 0; byte < 10; byte++) {
      crc ^= q[byte] << 8;
      for (var bit = 0; bit < 8; bit++) {
        crc = ((crc << 1) ^ (crc & 0x8000 != 0 ? 0x1021 : 0)) & 0xffff;
      }
    }
    if (((~crc) & 0xffff) != (q[10] << 8 | q[11])) {
      return CdromSubcode(raw: raw);
    }
    int? bcd(int value) => value >> 4 > 9 || (value & 15) > 9
        ? null
        : (value >> 4) * 10 + (value & 15);
    int? frames(int offset) {
      final minute = bcd(q[offset]),
          second = bcd(q[offset + 1]),
          frame = bcd(q[offset + 2]);
      if (minute == null ||
          second == null ||
          frame == null ||
          second >= 60 ||
          frame >= 75) {
        return null;
      }
      return (minute * 60 + second) * 75 + frame;
    }

    switch (q[0] & 15) {
      case 1:
        final track = q[1] == 0xaa ? 0xaa : bcd(q[1]), index = bcd(q[2]);
        final relative = frames(3), absolute = frames(7);
        if (track == null ||
            track == 0 ||
            index == null ||
            q[6] != 0 ||
            relative == null ||
            absolute == null) {
          return CdromSubcode(raw: raw);
        }
        return CdromSubcode(
            raw: raw,
            position: CdromSubcodePosition(
                control: q[0] >> 4,
                track: track,
                index: index,
                trackFrames: relative,
                discFrames: absolute));
      case 2:
        final digits = StringBuffer();
        for (var digit = 0; digit < 13; digit++) {
          final value = (q[1 + digit ~/ 2] >> (digit.isEven ? 4 : 0)) & 15;
          if (value > 9) return CdromSubcode(raw: raw);
          digits.write(value);
        }
        final frame = bcd(q[9]);
        if (q[7] & 15 != 0 || q[8] != 0 || frame == null || frame >= 75) {
          return CdromSubcode(raw: raw);
        }
        return CdromSubcode(
            raw: raw,
            catalog: CdromSubcodeIdentifier(digits.toString(), frame: frame));
      case 3:
        // ECMA-394 5.6.3.2: selector 00 is ISRC; RID/TBD records are separate.
        final frame = bcd(q[9]);
        if (q[4] & 3 != 0 || q[8] & 15 != 0 || frame == null || frame >= 75) {
          return CdromSubcode(raw: raw);
        }
        if (q.sublist(1, 9).every((value) => value == 0)) {
          return CdromSubcode(
              raw: raw, recording: CdromSubcodeIdentifier('', frame: frame));
        }
        int bits(int offset, int count) {
          var result = 0;
          for (var bit = offset; bit < offset + count; bit++) {
            result = (result << 1) | ((q[1 + bit ~/ 8] >> (7 - bit % 8)) & 1);
          }
          return result;
        }
        final code = StringBuffer();
        for (var character = 0; character < 5; character++) {
          final value = bits(character * 6, 6);
          final letter = value >= 0x11 && value <= 0x2a;
          if (!letter && (character < 2 || value > 9)) {
            return CdromSubcode(raw: raw);
          }
          code.writeCharCode(value + 0x30);
        }
        for (var digit = 0; digit < 7; digit++) {
          final value = bits(32 + digit * 4, 4);
          if (value > 9) return CdromSubcode(raw: raw);
          code.write(value);
        }
        return CdromSubcode(
            raw: raw,
            recording: CdromSubcodeIdentifier(code.toString(), frame: frame));
      default:
        return CdromSubcode(raw: raw);
    }
  }

  /// 96 packed P-W bytes in disc order, without the two synchronization symbols.
  final Uint8List? raw;
  final CdromSubcodePosition? position;

  /// Thirteen ASCII digits, or an empty value when no catalog was detected.
  final CdromSubcodeIdentifier? catalog;

  /// Twelve ASCII ISRC characters without separators, or an empty value.
  final CdromSubcodeIdentifier? recording;
  final bool readable;
}

/// Optional drive capability; ordinary 2352-byte adapters remain valid.
abstract interface class CdromSubcodeDrive {
  /// Returns null while fetching, or readable=false for an unreadable sector.
  /// LBAs and media-generation ownership follow [CdromDrive.read].
  CdromSubcode? readSubcode(int lba);
}

/// a drive without a disc
class EmptyCdromDrive implements CdromDrive {
  @override
  CdromDriveStatus get status => CdromDriveStatus.empty;

  @override
  CdromDriveEvent? takeEvent() => null;

  @override
  void clearEvents() {}

  @override
  void seek(int lba) {}

  @override
  Uint8List? read(int lba) => Uint8List(0);
}

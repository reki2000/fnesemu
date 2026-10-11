import '../util/int.dart';

/// CD time expressed as a nonnegative number of 1/75-second frames.
/// A track-relative duration uses [Msf.ofFrames]; disc time uses [Msf.ofLba].
class Msf {
  static const framesPerSecond = 75;
  static const lbaOffset = 2 * framesPerSecond;

  final int _frames;

  Msf.ofFrames(int frames)
      : _frames = RangeError.checkNotNegative(frames, 'frames');

  /// LBA zero corresponds to 00:02:00; the first pregap can use negative LBAs.
  Msf.ofLba(int lba) : this.ofFrames(lba + lbaOffset);

  /// Numeric time fields. Command validation remains the caller's job.
  Msf.ofParts(int minute, int second, int frame)
      : this.ofFrames((minute * 60 + second) * framesPerSecond + frame);

  Msf.ofBcd(int minute, int second, int frame)
      : this.ofParts(_decodeBcd(minute), _decodeBcd(second), _decodeBcd(frame));

  int frames() => _frames;

  (int, int, int) parts() => (
        _frames ~/ (60 * framesPerSecond),
        _frames ~/ framesPerSecond % 60,
        _frames % framesPerSecond,
      );

  String format() {
    final (minute, second, frame) = parts();
    return '${minute.d2z}:${second.d2z}:${frame.d2z}';
  }

  (int, int, int) bcd() {
    final (minute, second, frame) = parts();
    return (_encodeBcd(minute), _encodeBcd(second), _encodeBcd(frame));
  }

  static int _encodeBcd(int value) => (value ~/ 10).shl4 | value % 10;
  static int _decodeBcd(int value) => value.shr4 * 10 + value.mask4;
}

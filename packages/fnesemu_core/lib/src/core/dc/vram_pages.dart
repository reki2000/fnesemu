import 'dart:typed_data';

/// Write stamps for 4 KiB pages of one VRAM storage buffer. Every writer of the
/// buffer marks the pages it changes; texture caches compare the stamps with
/// the time they last validated their contents.
class DcVramPages {
  DcVramPages._(int length) : _pages = Int64List((length + 4095) >> 12);
  static final _all = Expando<DcVramPages>();

  /// The shared stamps of [memory].
  static DcVramPages of(Uint8List memory) =>
      _all[memory] ??= DcVramPages._(memory.length);

  final Int64List _pages;
  int _clock = 1;
  int get clock => _clock;

  void mark(int offset) => _pages[offset >> 12] = ++_clock;

  void markRange(int offset, int length) {
    if (length <= 0) return;
    final stamp = ++_clock;
    final last = (offset + length - 1) >> 12;
    for (var page = offset >> 12; page <= last; page++) {
      _pages[page] = stamp;
    }
  }

  void markAll() => _pages.fillRange(0, _pages.length, ++_clock);

  /// The newest stamp of the storage bytes [start, end).
  int newest(int start, int end) {
    if (start < 0) start = 0;
    final limit = _pages.length << 12;
    if (end > limit) end = limit;
    var result = 0;
    for (var page = start >> 12; page < (end + 4095) >> 12; page++) {
      if (_pages[page] > result) result = _pages[page];
    }
    return result;
  }
}

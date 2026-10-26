import 'dart:typed_data';

import 'runtime.dart';

/// Write protection for guest pages that hold translated code.
///
/// The host declares its guest mappings through [map]. Protecting a page
/// removes the write mapping of every writable guest alias of the same host
/// bytes, so a compiled store to code leaves its block through the
/// unmapped-page path before it can change upcoming instructions. Writes
/// made outside compiled code, such as by the CPU interpreter, DMA or
/// another CPU, are detected by the block guards instead.
///
/// A page that compiled code keeps writing, such as data next to code, can
/// be [release]d: its blocks are dropped and it is never protected again
/// until [reset].
final class JitCodeMemory {
  final JitRuntime rt;
  final _mappings = <(int, int, Uint8List, int, bool)>[];

  /// protected host pages by buffer and page offset, with their blocks
  final _protected = Map<Uint8List, Map<int, Set<(int, int)>>>.identity();
  final _released = Map<Uint8List, Set<int>>.identity();

  /// native exits at stores into each protected host page
  final _storeExits = Map<Uint8List, Map<int, int>>.identity();

  /// store exits into one protected page before [noteStoreExit] releases it
  static const storeExitLimit = 16;

  JitCodeMemory(this.rt);

  /// Maps [size] bytes of guest memory at [guestAddr] to [host] from
  /// [offset], as [JitRuntime.mapPages] does, and records the mapping as an
  /// alias for protection.
  void map(int guestAddr, int size, Uint8List host,
      {int offset = 0, bool writable = true}) {
    rt.mapPages(guestAddr, size, host, offset: offset, write: writable);
    _mappings.add((guestAddr, size, host, offset, writable));
  }

  (Uint8List, int)? _hostPage(int guestAddr) =>
      rt.readPages[(guestAddr & rt.addrMask) >>> rt.pageShift];

  /// Protects the page holding [guestAddr] and records [block] as translated
  /// from it. Returns false for unmapped or released pages.
  bool protect(int guestAddr, {(int, int)? block}) {
    final page = _hostPage(guestAddr);
    if (page == null) return false;
    final (host, offset) = page;
    if (_released[host]?.contains(offset) ?? false) return false;
    final pages = _protected[host] ??= {};
    var blocks = pages[offset];
    if (blocks == null) {
      pages[offset] = blocks = {};
      _setWrites(host, offset, false);
    }
    if (block != null) blocks.add(block);
    return true;
  }

  /// Whether the page holding [guestAddr] is protected.
  bool isProtected(int guestAddr) {
    final page = _hostPage(guestAddr);
    return page != null &&
        (_protected[page.$1]?.containsKey(page.$2) ?? false);
  }

  /// Whether the page holding [guestAddr] was released.
  bool isReleased(int guestAddr) {
    final page = _hostPage(guestAddr);
    return page != null && (_released[page.$1]?.contains(page.$2) ?? false);
  }

  /// Stops protecting the page holding [guestAddr]: invalidates the blocks
  /// translated from it and restores the write mappings of its aliases.
  void release(int guestAddr) {
    final page = _hostPage(guestAddr);
    if (page == null) return;
    final (host, offset) = page;
    final blocks = _protected[host]?.remove(offset);
    if (blocks != null) {
      for (final (pc, tag) in blocks) {
        rt.invalidate(pc, tag);
      }
      _setWrites(host, offset, true);
    }
    (_released[host] ??= {}).add(offset);
  }

  /// Counts a native exit at a store into the protected page holding
  /// [guestAddr], and releases the page at the [limit]th one: data stored next
  /// to code no longer leaves native code. The caller ends the blocks that
  /// store into a released page ([isReleased]) so that the next block guards
  /// its code words. Returns whether the page was released by this call.
  bool noteStoreExit(int guestAddr, {int limit = storeExitLimit}) {
    final page = _hostPage(guestAddr);
    if (page == null) return false;
    final (host, offset) = page;
    if (!(_protected[host]?.containsKey(offset) ?? false)) return false;
    final counts = _storeExits[host] ??= {};
    final count = (counts[offset] ?? 0) + 1;
    if (count < limit) {
      counts[offset] = count;
      return false;
    }
    counts.remove(offset);
    release(guestAddr);
    return true;
  }

  /// Restores every write mapping and forgets protection and releases, for
  /// a runtime whose blocks were cleared.
  void reset() {
    for (final MapEntry(key: host, value: pages) in _protected.entries) {
      for (final offset in pages.keys) {
        _setWrites(host, offset, true);
      }
    }
    _protected.clear();
    _released.clear();
    _storeExits.clear();
  }

  void _setWrites(Uint8List host, int offset, bool writable) {
    for (final (at, size, buffer, start, canWrite) in _mappings) {
      final delta = offset - start;
      if (!canWrite || !identical(buffer, host) || delta < 0 || delta >= size) {
        continue;
      }
      if (writable) {
        rt.mapPages(at + delta, rt.pageBytes, host, offset: offset, read: false);
      } else {
        rt.unmapPages(at + delta, rt.pageBytes, read: false);
      }
    }
  }
}

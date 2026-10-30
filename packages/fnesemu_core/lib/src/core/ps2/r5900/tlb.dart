import 'dart:typed_data';

import '../state.dart';

/// An address exception raised while translating or accessing an address.
/// The CPU turns it into the matching COP0 exception.
class Ps2Fault implements Exception {
  static const tlbModified = 1, tlbLoad = 2, tlbStore = 3;
  static const addressLoad = 4, addressStore = 5;

  /// the exception code of Cause.ExcCode
  final int code;
  final int address;

  /// true for a TLB miss, which uses the refill vector
  final bool refill;

  const Ps2Fault(this.code, this.address, {this.refill = false});

  @override
  String toString() => 'Ps2Fault($code, 0x${address.toRadixString(16)})';
}

class TlbEntry {
  int mask = 0; // PageMask
  int vpn2 = 0; // EntryHi without the ASID and the mask bits
  int asid = 0;
  bool global = false;
  int lo0 = 0, lo1 = 0;
}

/// The 48-entry joint TLB of the R5900.
///
/// The TLB stays inactive until the guest writes an entry: until then user
/// and kernel-mapped addresses translate to themselves, which lets a program
/// start without the BIOS having set up the memory map.
class Tlb {
  static const entryCount = 48;
  static const _cacheSize = 4096;

  final entries = List.generate(entryCount, (_) => TlbEntry());
  bool active = false;
  int asid = 0;

  // direct-mapped cache of 4 KiB translations: tag, physical page, writable
  final _tag = Int64List(_cacheSize);
  final _phys = Int64List(_cacheSize);
  final _writable = Uint8List(_cacheSize);

  Tlb() {
    _tag.fillRange(0, _cacheSize, -1);
  }

  /// called when earlier translations may no longer hold
  void Function()? onChange;

  void _flush() {
    _tag.fillRange(0, _cacheSize, -1);
    onChange?.call();
  }

  void saveState(StateWriter w) {
    for (final e in entries) {
      w.ints([e.mask, e.vpn2, e.asid, e.lo0, e.lo1]);
      w.boolean(e.global);
    }
    w.boolean(active);
    w.int64(asid);
  }

  void loadState(StateReader s) {
    for (final e in entries) {
      final v = s.fields(5, 'tlb entry');
      e.mask = v[0];
      e.vpn2 = v[1];
      e.asid = v[2];
      e.lo0 = v[3];
      e.lo1 = v[4];
      e.global = s.boolean();
    }
    active = s.boolean();
    asid = s.int64();
    _updateIdentity();
    _flush();
  }

  void setAsid(int value) {
    if (value & 0xff == asid) return;
    asid = value & 0xff;
    onChange?.call();
  }

  /// empties the TLB and switches translation off
  void clear() {
    for (final e in entries) {
      e.mask = e.vpn2 = e.asid = e.lo0 = e.lo1 = 0;
      e.global = false;
    }
    active = false;
    asid = 0;
    userIdentity = true;
    _flush();
  }

  void write(int index, int mask, int entryHi, int lo0, int lo1) {
    final e = entries[index];
    e.mask = mask & 0x1ffe000;
    e.vpn2 = entryHi & ~(e.mask | 0x1fff) & 0xffffffff;
    e.asid = entryHi & 0xff;
    e.global = lo0 & 1 != 0 && lo1 & 1 != 0;
    e.lo0 = lo0;
    e.lo1 = lo1;
    active = true;
    _updateIdentity();
    _flush();
  }

  /// Whether every entry for user addresses below 0x30000000 maps them to
  /// the physical address that compiled code uses: the address without its
  /// top three bits. Compiled code accesses those addresses without the
  /// TLB while this holds.
  bool userIdentity = true;

  void _updateIdentity() {
    userIdentity = entries.every((e) {
      if (e.vpn2 >= 0x30000000) return true;
      final pageSize = (e.mask >> 1) + 0x1000;
      for (final (lo, offset) in [(e.lo0, 0), (e.lo1, pageSize)]) {
        if (lo & 2 == 0) continue;
        final phys = ((lo >> 6) << 12) & 0xffffffff;
        if (phys != (e.vpn2 + offset) & 0x1fffffff) return false;
      }
      return true;
    });
  }

  /// the index of the entry that matches [entryHi], or -1
  int probe(int entryHi) {
    final vaddr = entryHi & 0xffffe000;
    final a = entryHi & 0xff;
    for (var i = 0; i < entryCount; i++) {
      final e = entries[i];
      if ((vaddr & ~(e.mask | 0x1fff)) == e.vpn2 && (e.global || e.asid == a)) {
        return i;
      }
    }
    return -1;
  }

  /// Translates [vaddr]. Throws a [Ps2Fault] on a miss, an invalid page or a
  /// store to a page that is not dirty.
  int translate(int vaddr, bool write) {
    final vpn = vaddr >> 12;
    final slot = vpn & (_cacheSize - 1);
    final tag = (vpn << 8) | asid;
    if (_tag[slot] == tag) {
      if (write && _writable[slot] == 0) {
        throw Ps2Fault(Ps2Fault.tlbModified, vaddr);
      }
      return _phys[slot] | (vaddr & 0xfff);
    }
    for (var i = 0; i < entryCount; i++) {
      final e = entries[i];
      if ((vaddr & ~(e.mask | 0x1fff)) != e.vpn2) continue;
      if (!e.global && e.asid != asid) continue;
      final pageSize = (e.mask >> 1) + 0x1000;
      final odd = vaddr & pageSize != 0;
      final lo = odd ? e.lo1 : e.lo0;
      if (lo & 2 == 0) {
        throw Ps2Fault(write ? Ps2Fault.tlbStore : Ps2Fault.tlbLoad, vaddr);
      }
      final offsetMask = pageSize - 1;
      final base = ((lo >> 6) << 12) & ~offsetMask & 0xffffffff;
      final phys = base | (vaddr & offsetMask);
      final writable = lo & 4 != 0;
      if (write && !writable) throw Ps2Fault(Ps2Fault.tlbModified, vaddr);
      _tag[slot] = tag;
      _phys[slot] = phys & ~0xfff;
      _writable[slot] = writable ? 1 : 0;
      return phys;
    }
    throw Ps2Fault(write ? Ps2Fault.tlbStore : Ps2Fault.tlbLoad, vaddr,
        refill: true);
  }
}

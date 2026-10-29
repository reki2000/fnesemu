import 'dart:typed_data';

import 'bus.dart';

/// A device on the other end of a DMA channel.
class DmaEndpoint {
  /// false while a source has nothing to give yet (the transfer waits)
  bool get hasData => true;

  /// false while a destination cannot take more (the transfer waits)
  bool get canPut => true;

  /// receives one quadword from memory
  void put(int low, int high) {}

  /// receives the tag quadword when the tag transfer enable bit is set
  void putTag(int low, int high) => put(low, high);

  /// supplies one quadword for memory
  void get(Int64List out) {
    out[0] = 0;
    out[1] = 0;
  }
}

class DmaChannel {
  int chcr = 0, madr = 0, qwc = 0, tadr = 0, asr0 = 0, asr1 = 0, sadr = 0;

  // a chain transfer that waits in the middle of a packet resumes with
  // these: the next tag address and whether the packet ends the chain
  bool inPacket = false, packetEnds = false;
  int nextTag = 0;
}

/// The EE DMA controller.
///
/// A transfer runs to completion when its channel is started, without bus
/// timing. Supported: normal mode, interleave mode for the scratchpad
/// channels, and source chain mode (tag IDs 0..7)
/// with the tag transfer enable bit. Memory FIFO and stall control are not
/// implemented. SIF0 also supports destination chain mode, and waits for
/// its source to supply data (see [service]). The IPU channels wait for the
/// IPU FIFOs, and a source chain to the IPU resumes in its packet.
///
/// The GIF channel moves its data at once but finishes one bus clock per
/// quadword later, so that PATH3 stays busy while the GS would still take
/// the data (see [path3Busy]).
class Dmac {
  static const channelCount = 10;
  static const vif0 = 0, vif1 = 1, gif = 2, fromIpu = 3, toIpu = 4;
  static const sif0 = 5, sif1 = 6, sif2 = 7, fromSpr = 8, toSpr = 9;

  static const _channelBases = [
    0x8000, 0x9000, 0xa000, 0xb000, 0xb400, //
    0xc000, 0xc400, 0xc800, 0xd000, 0xd400
  ];
  static const _str = 1 << 8, _tie = 1 << 7, _tte = 1 << 6;
  static const _dmaEnable = 1;

  final Ps2Bus bus;
  final channels = List.generate(channelCount, (_) => DmaChannel());
  final endpoints = List<DmaEndpoint?>.filled(channelCount, null);

  int ctrl = 0, stat = 0, pcr = 0, sqwc = 0, rbsr = 0, rbor = 0, stadr = 0;
  int enabler = 0x1201;

  /// true when a register or a transfer changed the interrupt output
  bool dirty = false;

  final _quad = Int64List(2);

  /// the SIF0 end tag was received and the channel finishes after its data
  bool _sif0End = false;
  bool _sif0Irq = false;

  /// quadwords moved by the GIF transfer that runs now
  int _moved = 0;

  /// bus clocks until the GIF channel finishes its moved data
  int _gifLeft = 0;
  bool _gifFinishing = false;

  /// called when the GIF channel finishes; VIF1 waits for this at FLUSHA
  void Function()? onPath3Idle;

  Dmac(this.bus);

  static bool handles(int address) =>
      address >= 0x10008000 && address < 0x1000f000 ||
      address == 0x1000f520 ||
      address == 0x1000f590;

  /// INT1 of the CPU
  bool get asserted => (stat & (stat >>> 16) & 0x3ff) != 0;

  int _channelOf(int address) {
    final base = address & 0xfc00;
    return _channelBases.indexOf(base);
  }

  int read(int address) {
    if (address == 0x1000f520) return enabler;
    if (address >= 0x1000e000) {
      switch (address & 0xff) {
        case 0x00:
          return ctrl;
        case 0x10:
          return stat;
        case 0x20:
          return pcr;
        case 0x30:
          return sqwc;
        case 0x40:
          return rbsr;
        case 0x50:
          return rbor;
        case 0x60:
          return stadr;
      }
      return 0;
    }
    final ch = _channelOf(address);
    if (ch < 0) return 0;
    final c = channels[ch];
    return switch (address & 0xf0) {
      0x00 => c.chcr,
      0x10 => c.madr,
      0x20 => c.qwc,
      0x30 => c.tadr,
      0x40 => c.asr0,
      0x50 => c.asr1,
      0x80 => c.sadr,
      _ => 0,
    };
  }

  void write(int address, int value) {
    value &= 0xffffffff;
    if (address == 0x1000f590) {
      enabler = value;
      return;
    }
    if (address >= 0x1000e000) {
      switch (address & 0xff) {
        case 0x00:
          ctrl = value;
        case 0x10:
          // low half: write 1 to clear; high half: write 1 to toggle
          final status = stat & 0xffff & ~value;
          final mask = ((stat >>> 16) ^ (value >>> 16)) & 0xffff;
          stat = status | (mask << 16);
          dirty = true;
        case 0x20:
          pcr = value;
        case 0x30:
          sqwc = value;
        case 0x40:
          rbsr = value;
        case 0x50:
          rbor = value;
        case 0x60:
          stadr = value;
      }
      return;
    }
    final ch = _channelOf(address);
    if (ch < 0) return;
    final c = channels[ch];
    switch (address & 0xf0) {
      case 0x00:
        c.chcr = value;
        if (ch == sif0) _sif0End = _sif0Irq = false;
        if (value & _str != 0) c.inPacket = false;
        if (value & _str != 0 && ctrl & _dmaEnable != 0) _run(ch);
      case 0x10:
        c.madr = value;
      case 0x20:
        c.qwc = value & 0xffff;
      case 0x30:
        c.tadr = value;
      case 0x40:
        c.asr0 = value;
      case 0x50:
        c.asr1 = value;
      case 0x80:
        c.sadr = value;
    }
  }

  /// reads a quadword; bit 31 of [address] selects the scratchpad
  void _read(int address) {
    final a = address & 0x80000000 != 0
        ? Ps2Bus.scratchBase + (address & 0x3ff0)
        : address & 0x7ffffff0;
    _quad[0] = bus.readPhysical64(a);
    _quad[1] = bus.readPhysical64(a + 8);
  }

  void _write(int address, int low, int high) {
    final a = address & 0x80000000 != 0
        ? Ps2Bus.scratchBase + (address & 0x3ff0)
        : address & 0x7ffffff0;
    bus.writePhysical64(a, low);
    bus.writePhysical64(a + 8, high);
  }

  /// resumes a channel that is waiting for data from the IOP
  void service() {
    final c = channels[sif0];
    if (c.chcr & _str != 0 && ctrl & _dmaEnable != 0) _run(sif0);
    serviceIpu();
  }

  /// resumes the IPU channels that wait for the IPU FIFOs
  void serviceIpu() {
    if (ctrl & _dmaEnable == 0) return;
    if (channels[toIpu].chcr & _str != 0) _run(toIpu);
    if (channels[fromIpu].chcr & _str != 0) _run(fromIpu);
  }

  /// true while the GIF channel transfers
  bool get path3Busy => _gifFinishing;

  /// advances the GIF channel by [busClocks]
  void advance(int busClocks) {
    if (!_gifFinishing) return;
    _gifLeft -= busClocks;
    if (_gifLeft > 0) return;
    _gifFinishing = false;
    _finish(gif);
    onPath3Idle?.call();
  }

  /// resumes VIF1 when it waits for its destination
  void serviceVif1() {
    if (ctrl & _dmaEnable == 0) return;
    if (channels[vif1].chcr & _str != 0) _run(vif1);
  }

  void _run(int ch) {
    final c = channels[ch];
    if (ch == gif) _moved = 0;
    switch ((c.chcr >> 2) & 3) {
      case 0:
        if (!_normal(ch, c)) return;
      case 1:
        if (ch == sif0) {
          if (!_destChain(ch, c)) return;
        } else if (!_chain(ch, c)) {
          return;
        }
      case 2:
        _interleave(ch, c);
    }
    if (ch == gif && _moved > 0) {
      _gifLeft = _moved;
      _gifFinishing = true;
      return;
    }
    _finish(ch);
  }

  void _finish(int ch) {
    channels[ch].chcr &= ~_str;
    stat |= 1 << ch;
    dirty = true;
  }

  /// true when the channel reads memory (VIF1 can also read from the GS)
  bool _fromMemory(int ch) {
    if (ch == vif1) return channels[ch].chcr & 1 != 0;
    return ch == vif0 || ch == gif || ch == toIpu || ch == sif1;
  }

  /// transfers one quadword in the direction of the channel; [spr] is the
  /// scratchpad address of the channel for the SPR channels
  void _move(int ch, DmaChannel c, int address) {
    if (ch == toSpr) {
      _read(address);
      _write(0x80000000 | c.sadr, _quad[0], _quad[1]);
      c.sadr = (c.sadr + 16) & 0x3ff0;
    } else if (ch == fromSpr) {
      _read(0x80000000 | c.sadr);
      _write(address, _quad[0], _quad[1]);
      c.sadr = (c.sadr + 16) & 0x3ff0;
    } else if (_fromMemory(ch)) {
      _read(address);
      endpoints[ch]?.put(_quad[0], _quad[1]);
    } else {
      final e = endpoints[ch];
      if (e == null) {
        _quad[0] = _quad[1] = 0;
      } else {
        e.get(_quad);
      }
      _write(address, _quad[0], _quad[1]);
    }
  }

  /// returns false when the transfer waits for its source
  bool _normal(int ch, DmaChannel c) {
    // a zero count transfers 0x10000 quadwords on hardware; treat it as none
    while (c.qwc > 0) {
      if ((ch == sif0 || ch == fromIpu) && endpoints[ch]?.hasData == false) {
        return false;
      }
      if (endpoints[ch]?.canPut == false) return false;
      _move(ch, c, c.madr);
      if (ch == gif) _moved++;
      c.madr += 16;
      c.qwc--;
    }
    return true;
  }

  /// SIF0 destination chain: every packet starts with a tag from the source
  bool _destChain(int ch, DmaChannel c) {
    final e = endpoints[ch];
    if (e == null) return true;
    while (true) {
      if (c.qwc == 0 && !_sif0End) {
        if (!e.hasData) return false;
        e.get(_quad);
        final tag = _quad[0];
        c.chcr = (c.chcr & 0xffff) | (tag & 0xffff0000);
        c.qwc = tag & 0xffff;
        c.madr = (tag >>> 32) & 0x7ffffff0;
        final id = (tag >>> 28) & 7;
        _sif0End = id == 7;
        _sif0Irq = (tag >>> 31) & 1 != 0;
      }
      if (!_normal(ch, c)) return false;
      if (_sif0End || (_sif0Irq && c.chcr & _tie != 0)) {
        _sif0End = _sif0Irq = false;
        return true;
      }
      _sif0Irq = false;
    }
  }

  void _interleave(int ch, DmaChannel c) {
    final skip = sqwc & 0xff, size = (sqwc >>> 16) & 0xff;
    if (size == 0) return;
    while (c.qwc > 0) {
      final n = c.qwc < size ? c.qwc : size;
      for (var i = 0; i < n; i++) {
        _move(ch, c, c.madr);
        c.madr += 16;
      }
      c.qwc -= n;
      c.madr += skip * 16;
    }
  }

  /// returns false when the transfer waits for its destination
  bool _chain(int ch, DmaChannel c) {
    if (!_fromMemory(ch) && ch != fromSpr && ch != toSpr) return true;
    for (var packets = 0; packets < 0x100000; packets++) {
      if (c.inPacket) {
        if (!_normal(ch, c)) return false;
        c.inPacket = false;
        c.tadr = c.nextTag;
        if (c.packetEnds) return true;
        continue;
      }
      _read(c.tadr);
      final tag = _quad[0];
      if (c.chcr & _tte != 0 && ch == toSpr) {
        // the scratchpad takes the whole tag quadword
        _write(0x80000000 | c.sadr, _quad[0], _quad[1]);
        c.sadr = (c.sadr + 16) & 0x3ff0;
      } else if (c.chcr & _tte != 0 && ch != fromSpr) {
        endpoints[ch]?.putTag(_quad[0], _quad[1]);
      }
      final qwc = tag & 0xffff;
      final id = (tag >>> 28) & 7;
      final irq = (tag >>> 31) & 1 != 0;
      final target = ((tag >>> 32) & 0x7fffffff) | ((tag >>> 63) << 31);
      c.chcr = (c.chcr & 0xffff) | ((tag & 0xffff0000));
      c.qwc = qwc;
      var next = c.tadr + 16;
      var end = false;
      switch (id) {
        case 0: // refe
          c.madr = target;
          end = true;
        case 1: // cnt
          c.madr = c.tadr + 16;
          next = c.madr + qwc * 16;
        case 2: // next
          c.madr = c.tadr + 16;
          next = target;
        case 3 || 4: // ref, refs
          c.madr = target;
        case 5: // call
          c.madr = c.tadr + 16;
          final asp = (c.chcr >> 4) & 3;
          if (asp >= 2) return true;
          final back = c.madr + qwc * 16;
          if (asp == 0) {
            c.asr0 = back;
          } else {
            c.asr1 = back;
          }
          c.chcr = (c.chcr & ~0x30) | ((asp + 1) << 4);
          next = target;
        case 6: // ret
          c.madr = c.tadr + 16;
          final asp = (c.chcr >> 4) & 3;
          if (asp == 0) {
            end = true;
          } else {
            next = asp == 1 ? c.asr0 : c.asr1;
            c.chcr = (c.chcr & ~0x30) | ((asp - 1) << 4);
          }
        default: // end
          c.madr = c.tadr + 16;
          end = true;
      }
      if (!_normal(ch, c)) {
        c
          ..inPacket = true
          ..nextTag = next
          ..packetEnds = end || (irq && c.chcr & _tie != 0);
        return false;
      }
      c.tadr = next;
      if (end || (irq && c.chcr & _tie != 0)) return true;
    }
    return true;
  }
}

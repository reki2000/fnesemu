import '../../state.dart';

import 'bsc.dart';
import 'cpg.dart';
import 'dmac.dart';
import 'fault.dart';
import 'gpio.dart';
import 'sci.dart';
import 'scif.dart';
import 'tmu.dart';

/// SH7750 interrupt priorities and external input detection.
class DcIntc {
  int _icr = 0, _ipra = 0, _iprb = 0, _iprc = 0;
  bool _nmiHigh = true, _nmiPending = false;
  void Function()? onNmi;

  bool get nmiHigh => _nmiHigh;
  set nmiHigh(bool value) {
    if (value != _nmiHigh && value == (_icr & 0x100 != 0)) {
      _nmiPending = true;
      onNmi?.call();
    }
    _nmiHigh = value;
  }

  bool get nmiIgnoresBlock => _icr & 0x200 != 0;

  void acknowledgeNmi() {
    _nmiPending = false;
    _icr &= ~0x200;
  }

  void reset() {
    _icr = _ipra = _iprb = _iprc = 0;
    _nmiPending = false;
  }

  void saveState(StateWriter writer) {
    writer.section('dc.sh4.intc');
    writer.ints([_icr, _ipra, _iprb, _iprc]);
    writer.boolean(_nmiHigh);
    writer.boolean(_nmiPending);
  }

  /// Assign the sampled NMI level directly, without synthesizing an edge.
  void loadState(StateReader reader) {
    reader.section('dc.sh4.intc');
    final values = reader.ints();
    final high = reader.boolean(), pending = reader.boolean();
    const masks = [0x4380, 0xffff, 0xfff0, 0xffff];
    if (values.length != 4) throw const StateMismatch('SH4 interrupt layout');
    for (var i = 0; i < 4; i++) {
      if (values[i] < 0 || values[i] & ~masks[i] != 0) {
        throw const StateMismatch('SH4 interrupt state');
      }
    }
    _icr = values[0];
    _ipra = values[1];
    _iprb = values[2];
    _iprc = values[3];
    _nmiHigh = high;
    _nmiPending = pending;
  }

  int read(int offset) => switch (offset) {
        0 => _icr | (_nmiHigh ? 0x8000 : 0),
        4 => _ipra,
        8 => _iprb,
        12 => _iprc,
        2 || 6 || 10 || 14 => 0,
        _ => throw DcUnsupported('unsupported INTC register: $offset'),
      };

  void write(int offset, int value) {
    switch (offset) {
      case 0:
        _icr = value & 0x4380;
      case 4:
        _ipra = value & 0xffff;
      case 8:
        _iprb = value & 0xfff0;
      case 12:
        _iprc = value & 0xffff;
      case 2:
      case 6:
      case 10:
      case 14:
        // ROM BIOS clears the unused halfwords during application handoff.
        if (value != 0) {
          throw DcUnsupported(
              'nonzero write to reserved INTC halfword: $offset');
        }
      default:
        throw DcUnsupported('unsupported INTC register: $offset');
    }
  }

  /// Returns priority and INTEVT, retaining default order on equal priorities.
  (int, int) pending(int irlPins, DcTmu tmu,
      {DcDmac? dma,
      DcScif? scif,
      DcCpg? cpg,
      DcSci? sci,
      DcBsc? bsc,
      DcGpio? gpio}) {
    if (_nmiPending) return (16, 0x1c0);
    if (!_nmiHigh && _icr & 0x4000 != 0) return (0, 0);
    var priority = 0, event = 0;
    if (_icr & 0x80 == 0) {
      priority = 15 - irlPins;
      event = priority == 0 ? 0 : 0x200 + irlPins * 0x20;
    } else {
      const levels = [13, 10, 7, 4];
      const events = [0x240, 0x2a0, 0x300, 0x360];
      for (var pin = 0; pin < 4; pin++) {
        if (irlPins & (1 << pin) == 0 && levels[pin] > priority) {
          priority = levels[pin];
          event = events[pin];
        }
      }
    }
    final gpioPriority = (_iprc >> 12) & 15;
    if (gpio != null && gpioPriority > priority && gpio.interruptPending) {
      priority = gpioPriority;
      event = 0x620;
    }
    final dmaPriority = (_iprc >> 8) & 15;
    if (dma != null && dmaPriority > priority) {
      for (var channel = 0; channel < 4; channel++) {
        if (dma.interruptPending(channel)) {
          priority = dmaPriority;
          event = 0x640 + channel * 0x20;
          break;
        }
      }
      if (dma.addressError && dmaPriority > priority) {
        priority = dmaPriority;
        event = 0x6c0;
      }
    }
    for (var channel = 0; channel < 3; channel++) {
      final level = (_ipra >> (12 - channel * 4)) & 15;
      if (level > priority && tmu.interruptPending(channel)) {
        priority = level;
        event = 0x400 + channel * 0x20;
      }
    }
    final sciPriority = (_iprb >> 4) & 15;
    if (sci != null && sciPriority > priority && sci.interruptEvent != 0) {
      priority = sciPriority;
      event = sci.interruptEvent;
    }
    final serialPriority = (_iprc >> 4) & 15;
    if (scif != null && serialPriority > priority && scif.interruptEvent != 0) {
      priority = serialPriority;
      event = scif.interruptEvent;
    }
    final watchdogPriority = (_iprb >> 12) & 15;
    if (cpg != null && watchdogPriority > priority && cpg.interruptPending) {
      priority = watchdogPriority;
      event = 0x560;
    }
    final refreshPriority = (_iprb >> 8) & 15;
    if (bsc != null && refreshPriority > priority && bsc.interruptEvent != 0) {
      priority = refreshPriority;
      event = bsc.interruptEvent;
    }
    return (priority, event);
  }
}

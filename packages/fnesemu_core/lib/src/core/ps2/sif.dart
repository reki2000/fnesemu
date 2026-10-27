import 'dart:collection';
import 'dart:typed_data';

import 'dmac.dart';

/// The EE <-> IOP interface: the mailbox registers and the two DMA paths.
///
/// SIF0 carries data from the IOP to the EE and SIF1 the other way. Both are
/// word FIFOs filled and drained by the DMA channels of the two processors.
class Sif {
  /// registers, written by both sides (see [eeWrite] and [iopWrite])
  int mscom = 0, smcom = 0, msflg = 0, smflg = 0, control = 0;

  final sif0Fifo = ListQueue<int>();
  final sif1Fifo = ListQueue<int>();

  late final DmaEndpoint sif0 = _Sif0(this);
  late final DmaEndpoint sif1 = _Sif1(this);

  void reset() {
    mscom = smcom = msflg = smflg = control = 0;
    sif0Fifo.clear();
    sif1Fifo.clear();
  }

  /// EE side register offsets 0x1000f200..0x1000f260
  int eeRead(int offset) => switch (offset) {
        0x00 => mscom,
        0x10 => smcom,
        0x20 => msflg,
        0x30 => smflg,
        0x40 => control,
        _ => 0,
      };

  void eeWrite(int offset, int value) {
    value &= 0xffffffff;
    switch (offset) {
      case 0x00:
        mscom = value;
      case 0x10:
        smcom = value;
      case 0x20:
        msflg |= value; // the EE sets MSFLG bits
      case 0x30:
        smflg &= ~value; // and clears SMFLG bits
      case 0x40:
        control = value;
    }
  }

  /// IOP side register offsets 0x1d000000..0x1d000040
  int iopRead(int offset) => eeRead(offset);

  void iopWrite(int offset, int value) {
    value &= 0xffffffff;
    switch (offset) {
      case 0x00:
        mscom = value;
      case 0x10:
        smcom = value;
      case 0x20:
        msflg &= ~value; // the IOP clears MSFLG bits
      case 0x30:
        smflg |= value; // and sets SMFLG bits
      case 0x40:
        control = value;
    }
  }
}

class _Sif0 extends DmaEndpoint {
  final Sif sif;
  _Sif0(this.sif);

  @override
  bool get hasData => sif.sif0Fifo.length >= 4;

  @override
  void get(Int64List out) {
    final f = sif.sif0Fifo;
    if (f.length < 4) {
      out[0] = out[1] = 0;
      return;
    }
    final a = f.removeFirst(), b = f.removeFirst();
    final c = f.removeFirst(), d = f.removeFirst();
    out[0] = a | (b << 32);
    out[1] = c | (d << 32);
  }
}

class _Sif1 extends DmaEndpoint {
  final Sif sif;
  _Sif1(this.sif);

  @override
  void put(int low, int high) {
    sif.sif1Fifo
      ..add(low & 0xffffffff)
      ..add(low >>> 32)
      ..add(high & 0xffffffff)
      ..add(high >>> 32);
  }
}

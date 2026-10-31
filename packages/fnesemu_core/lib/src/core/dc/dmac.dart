import 'dart:typed_data';

import '../../state.dart';
import '../../util/int.dart';
import 'fault.dart';

typedef DcDmaTransfer = bool Function(
    int source, int destination, int size, int resource);

/// A destination-owned external DDT endpoint, resolved by a stable device ID.
typedef DcDdtStateBinding = ({
  Object owner,
  bool Function(int address, bool write) transfer
});
typedef DcDdtStateResolver = DcDdtStateBinding? Function(
    String ownerId, int address, bool write);

/// SH7750 normal transfers and channel-0 DDT 32-byte requests.
/// Transfer-unit scheduling is functional rather than bus-cycle accurate.
class DcDmac {
  DcDmac(this.transfer, {this.peripheralRequest, this.externalRequest});
  final DcDmaTransfer transfer;
  final bool Function(int resource)? peripheralRequest;
  final bool Function(int channel, int resource)? externalRequest;
  final _source = Uint32List(4), _destination = Uint32List(4);
  final _count = Uint32List(4), _control = Uint32List(4);
  Object? _ddtOwner;
  bool Function(int address, bool write)? _ddtTransfer;
  bool _ddtWrite = false;
  int _operation = 0, _observedErrors = 0, _observedEnd = 0, _next = 0;

  void reset() {
    _source.fillRange(0, 4, 0);
    _destination.fillRange(0, 4, 0);
    _count.fillRange(0, 4, 0);
    _control.fillRange(0, 4, 0);
    _ddtOwner = _ddtTransfer = null;
    _operation = _observedErrors = _observedEnd = _next = 0;
  }

  void saveState(StateWriter writer,
      {String? Function(Object owner)? identifyDdtOwner}) {
    if ((_ddtOwner == null) != (_ddtTransfer == null)) {
      throw const StateMismatch('SH4 DMA inconsistent DDT endpoint');
    }
    final ownerId =
        _ddtOwner == null ? null : identifyDdtOwner?.call(_ddtOwner!);
    if (_ddtOwner != null && (ownerId == null || ownerId.isEmpty)) {
      throw const StateMismatch('SH4 DMA DDT owner is not registered');
    }
    writer.section('dc.sh4.dmac');
    for (final buffer in [_source, _destination, _count, _control]) {
      writer.ints(buffer);
    }
    writer.ints([_operation, _observedErrors, _observedEnd, _next]);
    writer.boolean(_ddtWrite);
    writer.boolean(ownerId != null);
    if (ownerId != null) writer.string(ownerId);
  }

  /// A resolver supplies destination-owned callbacks without making a request.
  /// Its address is the raw saved channel-0 register, before physical masking.
  void loadState(StateReader reader, {DcDdtStateResolver? resolveDdtOwner}) {
    reader.section('dc.sh4.dmac');
    final buffers = [_source, _destination, _count, _control];
    final values = [for (final _ in buffers) reader.ints()];
    final status = reader.ints();
    final write = reader.boolean();
    final ownerId = reader.boolean() ? reader.string() : null;
    for (var group = 0; group < 4; group++) {
      if (values[group].length != 4) {
        throw const StateMismatch('SH4 DMA layout');
      }
      for (var channel = 0; channel < 4; channel++) {
        final mask = group == 2
            ? 0xffffff
            : group == 3
                ? (channel < 2 ? 0xff0ffff7 : 0xff0afff7)
                : 0xffffffff;
        if (values[group][channel] < 0 || values[group][channel] & ~mask != 0) {
          throw const StateMismatch('SH4 DMA channel state');
        }
      }
    }
    if (status.length != 4 ||
        status.any((value) => value < 0) ||
        status[0] & ~0x8307 != 0 ||
        status[1] & ~6 != 0 ||
        status[2] & ~15 != 0 ||
        status[3] > 3) {
      throw const StateMismatch('SH4 DMA control state');
    }
    DcDdtStateBinding? binding;
    if (ownerId != null) {
      final expected = 0x000850c1 | (write ? 0x300 : 0x200);
      if (ownerId.isEmpty ||
          status[0] & 0x8000 == 0 ||
          values[2][0] != 1 ||
          values[3][0] != expected) {
        throw const StateMismatch('SH4 DMA DDT request state');
      }
      binding = resolveDdtOwner?.call(ownerId, values[write ? 1 : 0][0], write);
      if (binding == null) {
        throw const StateMismatch('SH4 DMA DDT owner cannot be resolved');
      }
    }
    for (var group = 0; group < buffers.length; group++) {
      buffers[group].setAll(0, values[group]);
    }
    _operation = status[0];
    _observedErrors = status[1];
    _observedEnd = status[2];
    _next = status[3];
    _ddtWrite = write;
    _ddtOwner = binding?.owner;
    _ddtTransfer = binding?.transfer;
  }

  bool get ddtEnabled => _operation & 0x8007 == 0x8001;
  bool get hasDdtTransfers => ddtEnabled && _ddtTransfer != null;
  bool ownsDdtRequest(Object owner) => identical(_ddtOwner, owner);

  /// DTR ID=00, SZ=100, MD=01, COUNT=1. The callback owns the external endpoint.
  /// SH7750 Hardware Manual §14.5; HOLLY uses only 32-byte block transfers.
  bool requestDdt32(Object owner, int address,
      {required bool write,
      required bool Function(int address, bool write) transfer}) {
    if (!ddtEnabled || _ddtTransfer != null) return false;
    _ddtOwner = owner;
    _ddtTransfer = transfer;
    _ddtWrite = write;
    if (write) {
      _destination[0] = address.mask32;
    } else {
      _source[0] = address.mask32;
    }
    _count[0] = 1;
    // DS=edge, increment addresses, single-address R/W, burst, 32-byte, DE; IE=0.
    _control[0] = 0x000850c1 | (write ? 0x300 : 0x200);
    _observedEnd &= ~1;
    return true;
  }

  /// Withdraws an external request without reporting normal transfer completion.
  /// DE/register contents are retained, as with a DTR transfer-end cancellation.
  void cancelDdt(Object owner) {
    if (!ownsDdtRequest(owner)) return;
    _ddtOwner = _ddtTransfer = null;
  }

  void _transferDdt() {
    final address = _ddtWrite ? _destination[0] : _source[0];
    final owner = _ddtOwner, callback = _ddtTransfer!;
    if (address & 31 != 0) {
      _operation |= 4;
      _observedErrors &= ~4;
      return;
    }
    if (!callback(address & 0x1fffffff, _ddtWrite)) {
      if (identical(_ddtOwner, owner) && identical(_ddtTransfer, callback)) {
        _operation |= 4;
        _observedErrors &= ~4;
      }
      return;
    }
    if (_ddtWrite) {
      _destination[0] = (address + 32).mask32;
    } else {
      _source[0] = (address + 32).mask32;
    }
    _count[0] = 0;
    _control[0] |= 2;
    _observedEnd &= ~1;
    _ddtOwner = _ddtTransfer = null;
  }

  bool get addressError => _operation & 4 != 0;

  /// Enabled unfinished channels must be terminated before deep sleep entry.
  bool get hasEnabledTransfers {
    if (_operation & 1 == 0) return false;
    for (var channel = 0; channel < 4; channel++) {
      if (_control[channel] & 3 == 1) return true;
    }
    return false;
  }

  bool interruptPending(int channel) => _control[channel] & 6 == 6;

  bool get hasAutoMemoryTransfers {
    if (_operation & 7 != 1) return false;
    for (var channel = 0; channel < 4; channel++) {
      final control = _control[channel];
      if (control & 3 == 1 && (control >> 8) & 15 == 4) return true;
    }
    return false;
  }

  /// Device-visible writes need individual bus edges even when unrelated devices are idle.
  bool hasAutoMemoryTransferTo(bool Function(int) matches) {
    if (_operation & 7 != 1) return false;
    for (var channel = 0; channel < 4; channel++) {
      if (channel == 0 && _operation & 0x8000 != 0) continue;
      final control = _control[channel];
      if (control & 3 == 1 &&
          (control >> 8) & 15 == 4 &&
          matches(_destination[channel] & 0x1fffffff)) {
        return true;
      }
    }
    return false;
  }

  /// Resource selections 5, 6, 8-11, 13 and 14 are peripheral requests.
  bool get hasPeripheralTransfers {
    if (_operation & 7 != 1) return false;
    for (var channel = 0; channel < 4; channel++) {
      final control = _control[channel];
      if (control & 3 == 1 && (0x6f60 >> ((control >> 8) & 15)) & 1 != 0) {
        return true;
      }
    }
    return false;
  }

  void nmi() {
    _operation |= 2;
    _observedErrors &= ~2;
  }

  int read(int offset, {bool sideEffects = true}) {
    if (offset == 0x40) {
      if (sideEffects) _observedErrors |= _operation & 6;
      return _operation;
    }
    if (offset < 0 || offset >= 0x40 || offset & 3 != 0) {
      throw DcUnsupported('unsupported DMAC register: $offset');
    }
    final channel = offset >> 4;
    switch (offset & 15) {
      case 0:
        return _source[channel];
      case 4:
        return _destination[channel];
      case 8:
        return _count[channel];
      default:
        if (sideEffects && _control[channel] & 2 != 0) {
          _observedEnd |= 1 << channel;
        }
        return _control[channel];
    }
  }

  void write(int offset, int value) {
    if (offset == 0x40) {
      final preserved = (_operation & 6) & ~(_observedErrors & ~value);
      _operation = (value & 0x8301) | preserved;
      if (_operation & 0x8000 == 0) _ddtOwner = _ddtTransfer = null;
      _observedErrors &= preserved;
      return;
    }
    if (offset < 0 || offset >= 0x40 || offset & 3 != 0) {
      throw DcUnsupported('unsupported DMAC register: $offset');
    }
    final channel = offset >> 4;
    if (channel == 0 && _operation & 0x8000 != 0) {
      throw const DcUnsupported('CPU write to channel 0 in SH7750 DDT mode');
    }
    switch (offset & 15) {
      case 0:
        _source[channel] = value;
      case 4:
        _destination[channel] = value;
      case 8:
        _count[channel] = value & 0xffffff;
      default:
        var end = _control[channel] & 2;
        if (value & 2 == 0 && _observedEnd & (1 << channel) != 0) {
          end = 0;
          _observedEnd &= ~(1 << channel);
        }
        final mask = channel < 2 ? 0xff0ffff5 : 0xff0afff5;
        _control[channel] = (value & mask) | end;
    }
  }

  bool _requested(int channel) {
    if (channel == 0 && _operation & 0x8000 != 0) return _ddtTransfer != null;
    if (_control[channel] & 3 != 1) return false;
    final resource = (_control[channel] >> 8) & 15;
    if (resource >= 4 && resource <= 6) return true;
    if (resource == 1 || resource == 7 || resource == 15) {
      throw DcUnsupported('prohibited DMAC request source');
    }
    if (resource >= 8) return peripheralRequest?.call(resource) ?? false;
    return externalRequest?.call(channel, resource) ?? false;
  }

  void tickTransferUnits(int units) {
    if (units < 0) throw ArgumentError.value(units, 'units');
    const priorities = [
      [0, 1, 2, 3],
      [0, 2, 3, 1],
      [2, 0, 1, 3]
    ];
    for (var unit = 0; unit < units; unit++) {
      if (_operation & 7 != 1) return;
      final mode = (_operation >> 8) & 3;
      var selected = -1;
      for (var slot = 0; slot < 4; slot++) {
        final channel = mode == 3 ? (_next + slot) & 3 : priorities[mode][slot];
        if (_requested(channel)) {
          selected = channel;
          break;
        }
      }
      if (selected < 0) return;
      if (selected == 0 && _operation & 0x8000 != 0) {
        _transferDdt();
        _next = 1;
        continue;
      }
      final control = _control[selected];
      final sizeCode = (control >> 4) & 7;
      if (sizeCode > 4 ||
          ((control >> 12) & 3) == 3 ||
          ((control >> 14) & 3) == 3) {
        throw DcUnsupported('prohibited DMAC size or address mode');
      }
      final size = [8, 1, 2, 4, 32][sizeCode];
      final source = _source[selected], destination = _destination[selected];
      final resource = (control >> 8) & 15;
      final peripheralSource = [6, 9, 11, 14].contains(resource);
      final peripheralDestination = [5, 8, 10, 13].contains(resource);
      if ((source | destination) & (size - 1) != 0 ||
          ((source & 0x1fffffff) >= 0x1c000000) != peripheralSource ||
          ((destination & 0x1fffffff) >= 0x1c000000) != peripheralDestination) {
        _operation |= 4;
        _observedErrors &= ~4;
        return;
      }
      if (!transfer(
          source & 0x1fffffff, destination & 0x1fffffff, size, resource)) {
        _operation |= 4;
        _observedErrors &= ~4;
        return;
      }
      const direction = [0, 1, -1];
      _source[selected] =
          (source + size * direction[(control >> 12) & 3]).mask32;
      _destination[selected] =
          (destination + size * direction[(control >> 14) & 3]).mask32;
      _count[selected] = (_count[selected] - 1) & 0xffffff;
      if (_count[selected] == 0) {
        _control[selected] |= 2;
        _observedEnd &= ~(1 << selected);
      }
      _next = (selected + 1) & 3;
    }
  }
}

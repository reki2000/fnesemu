import 'dart:typed_data';

import '../../sram.dart';

/// Selects independent persistent keys through the existing single-region API.
/// The app flushes its active region when init selects a different key.
class DcStorageRegion extends Sram {
  DcStorageRegion(this.parent);
  final Sram parent;

  void _activate() {
    if (parent.id != id) parent.init(id, Uint8List.fromList(data));
    data = parent.data;
  }

  @override
  void init(String id, Uint8List initialData) {
    super.init(id, initialData);
    _activate();
  }

  @override
  int read8(int addr) {
    _activate();
    return parent.read8(addr);
  }

  @override
  void write8(int addr, int value) {
    _activate();
    parent.write8(addr, value);
  }
}

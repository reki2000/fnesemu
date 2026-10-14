import '../bus_m68.dart';
import 'md_32x.dart';

/// Adapter mapping is installed only for cartridges using md 32x.
class Md32xBus extends BusM68 {
  final Md32x adapter;
  Md32xBus(this.adapter, BusM68 previous)
      : super(ram: previous.ram, pad: previous.pad, rom: previous.rom);

  @override
  int read8(int addr) =>
      adapter.mapsMain(addr) ? adapter.readMain8(addr) : super.read8(addr);
  @override
  int read16(int addr) =>
      adapter.mapsMain(addr) ? adapter.readMain16(addr) : super.read16(addr);
  @override
  void write8(int addr, int data) {
    if (adapter.mapsMain(addr)) {
      adapter.writeMain8(addr, data);
    } else {
      super.write8(addr, data);
    }
  }

  @override
  void write16(int addr, int data) {
    if (adapter.mapsMain(addr)) {
      adapter.writeMain16(addr, data);
    } else {
      super.write16(addr, data);
    }
  }
}

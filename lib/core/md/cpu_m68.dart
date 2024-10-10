import 'bus_m68.dart';

class Regs {
  List<int> d = List.filled(8, 0);
  List<int> a = List.filled(8, 0);
  int pc = 0;
  int sr = 0;

  int get sp => a[7];
  set sp(int val) => a[7] = val;
}

class M68 {
  final BusM68 bus;

  int clocks = 0;

  final regs = Regs();

  M68(this.bus);

  bool exec() => false;
}

import '../../../util/int.dart';
import '../../../util/state.dart';

/// mirroring setting for PPU name table
class Mirror {
  //                0x2000-0x2400/0x2800-0x2c00
  // Vertical       0x2000 0x2400 0x2000 0x2400  A-B/A-B
  // Horizontal     0x2000 0x2000 0x2400 0x2400  A-A/B-B
  // OneScreenLow   0x2000 0x2000 0x2000 0x2000  A-A/A-A
  // OneScreenHigh  0x2400 0x2400 0x2400 0x2400  B-B/B-B
  final int Function(int) mask;
  final String name;
  final bool isExternal;

  Mirror(
    this.mask, {
    required this.name,
    this.isExternal = false,
  });

  static final vertical = Mirror((v) => v & ~0x800, name: "v ");
  static final horizontal =
      Mirror((v) => v & ~0xc00 | (v & 0x800).shr1, name: "h ");
  static final oneScreenLow = Mirror((v) => v & ~0xc00, name: "1l");
  static final oneScreenHigh = Mirror((v) => v & ~0xc00 | 0x400, name: "1h");

  static final external = Mirror((v) => v, name: "ex", isExternal: true);

  /// Every mirroring mode in state order, for saving the active mode as an index.
  static final all = [vertical, horizontal, oneScreenLow, oneScreenHigh, external];

  /// The index of this mode in [all], or -1 when it is not a known mode.
  int get stateId => all.indexWhere((m) => identical(m, this));

  /// The mode at [stateId], throwing a StateMismatch for an unknown index.
  static Mirror fromStateId(int stateId) {
    if (stateId < 0 || stateId >= all.length) {
      throw StateMismatch('mirror mode $stateId');
    }
    return all[stateId];
  }
}

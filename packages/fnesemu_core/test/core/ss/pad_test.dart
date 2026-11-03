import 'package:fnesemu_core/src/core/ss/pad.dart';
import 'package:fnesemu_core/src/pad_button.dart';
import 'package:fnesemu_core/src/pad_source.dart';
import 'package:test/test.dart';

void main() {
  test('key slots are in the unified key order', () {
    final names = Pad().buttons.map((b) => b.name).toList();
    expect(names.sublist(4), [
      'Y', 'A', 'B', 'C', // S Z X C
      'X', 'Z', '', // A D W
      'L', 'R', // Q E
      '', '', '', '', // 1 2 3 4
      '', // R
      'Start', '', // Enter Shift
    ]);
  });

}

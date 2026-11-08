// Reads the input sequences of the harnesses.
@TestOn('vm')
library;

import 'package:fnesemu_core/core_factory.dart';
import 'package:test/test.dart';

import '../../tool/input_sequence.dart';

List<(int, String, int)> presses(String text, {int origin = 0}) => [
      for (final p in parseInput(text, origin: origin))
        (p.frame, p.button, p.frames)
    ];

void main() {

  test('every button of every core can be written', () {
    for (final system in CoreFactory.systems) {
      final core = CoreFactory.of(system.id);
      addTearDown(core.dispose);
      final names = core.buttons.map((b) => b.name);
      for (final name in names.where((n) => n.isNotEmpty)) {
        expect(presses(quoteButton(name)), [(0, name, 10)],
            reason: '${system.id}: $name');
      }
    }
  });
}

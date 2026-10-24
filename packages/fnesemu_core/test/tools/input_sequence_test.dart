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
  test('a press holds the default length and moves the cursor by it', () {
    expect(presses('A B:4 C'), [(0, 'A', 10), (10, 'B', 4), (14, 'C', 10)]);
  });

  test('@F moves the cursor to a frame and _N waits', () {
    expect(presses('@100 A _5 B'), [(100, 'A', 10), (115, 'B', 10)]);
  });

  test('@F before the cursor is an error', () {
    expect(() => parseInput('@100 A @105 B'), throwsA(isA<InputError>()));
    expect(() => parseInput('@5 A', origin: 10), throwsA(isA<InputError>()));
  });

  test('the cursor starts at the origin', () {
    expect(presses('A @30 B', origin: 20), [(20, 'A', 10), (30, 'B', 10)]);
  });

  test('readInput returns the cursor at the end', () {
    expect(readInput('A _5 (B:3 | C:20)', origin: 4).end, 39);
  });

  test('B+C holds several buttons together', () {
    expect(presses('A+B:3 C'), [(0, 'A', 3), (0, 'B', 3), (3, 'C', 10)]);
  });

  test(':N sets the default length until the end of the group', () {
    expect(presses(':4 A [:2 B]*2 C'),
        [(0, 'A', 4), (4, 'B', 2), (6, 'B', 2), (8, 'C', 4)]);
  });

  test('[ ]*N repeats a part', () {
    expect(presses('[A:2 _3]*3'), [(0, 'A', 2), (5, 'A', 2), (10, 'A', 2)]);
  });

  test('@F inside [ ] is an error', () {
    expect(() => parseInput('[@10 A]*2'), throwsA(isA<InputError>()));
  });

  test('( | ) runs the branches from the cursor and moves to the latest end',
      () {
    expect(presses('@10 (A:30 | _5 B:2 | :3 C) D'), [
      (10, 'A', 30),
      (10, 'C', 3),
      (15, 'B', 2),
      (40, 'D', 10),
    ]);
  });

  test('a quoted name may have reserved characters', () {
    expect(presses('"Flip Disk" "a+b":3'),
        [(0, 'Flip Disk', 10), (10, 'a+b', 3)]);
  });

  test('broken sequences are errors', () {
    for (final text in [
      '[A',
      '[A]',
      '[A]*0',
      '(A | B',
      'A)',
      '@',
      '_x',
      'A:',
      '"A',
      'A::2',
    ]) {
      expect(() => parseInput(text), throwsA(isA<InputError>()),
          reason: text);
    }
  });

  test('buttonIndex takes the exact name, then the only one in another case',
      () {
    expect(buttonIndex(['x', 'X', 'Start'], 'X'), 1);
    expect(buttonIndex(['x', 'Start'], 'start'), 1);
    expect(() => buttonIndex(['x', 'X'], 'y'), throwsA(isA<InputError>()));
  });

  test('every button of every core can be written', () {
    for (final system in CoreFactory.systems) {
      final names = CoreFactory.of(system.id).buttons.map((b) => b.name);
      for (final name in names.where((n) => n.isNotEmpty)) {
        expect(presses(quoteButton(name)), [(0, name, 10)],
            reason: '${system.id}: $name');
      }
    }
  });
}

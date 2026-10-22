// the input sequence of the headless runner: button presses written as a line of text
//
//   @F          moves the cursor to frame F (not before the cursor)
//   _N          moves the cursor N frames on
//   B           holds button B for the default length and moves the cursor by it
//   B:N         holds button B for N frames and moves the cursor by N
//   B+C:N       holds several buttons together
//   :N          sets the default length to N frames (initially 10)
//   [ ... ]*N   repeats the part N times (no @F inside)
//   ( a | b )   runs the parts in parallel from the cursor; the cursor moves to the latest end
//   "..."       a button name with a reserved character: @ _ : + [ ] * ( ) | " or a space
//
// a default length set inside [ ] or ( ) ends with it.
// e.g. "@150 Start @250 ( right:710 | _12 [A:6 _30]*20 )" presses Start, then holds right while tapping A.

import 'dart:convert';

/// a button held from [frame] for [frames] frames
typedef Press = ({int frame, String button, int frames});

/// the default number of frames a press is held
const defaultHold = 10;

class InputError implements Exception {
  final String message;
  InputError(this.message);

  @override
  String toString() => message;
}

/// reads [text] with the cursor at [origin]; the presses are sorted by frame
List<Press> parseInput(String text, {int origin = 0}) =>
    readInput(text, origin: origin).presses;

/// reads [text] with the cursor at [origin]; returns the presses sorted by
/// frame and the cursor at the end
({List<Press> presses, int end}) readInput(String text, {int origin = 0}) {
  final nodes = _Parser(text).parse();
  final presses = <Press>[];
  final end = _eval(nodes, origin, defaultHold, false, presses);
  presses.sort((a, b) => a.frame.compareTo(b.frame));
  return (presses: presses, end: end);
}

/// the index of [name] in [buttons]: the exact name, or else the only name
/// that differs in case
int buttonIndex(List<String> buttons, String name) {
  final exact = buttons.indexOf(name);
  if (exact >= 0) return exact;
  final lower = name.toLowerCase();
  final folded = [
    for (var i = 0; i < buttons.length; i++)
      if (buttons[i].toLowerCase() == lower) i
  ];
  if (folded.length == 1) return folded.first;
  throw InputError(
      "unknown button: $name (${buttons.map(quoteButton).join(" ")})");
}

/// the presses of [input] as (frame, button index, frames)
List<(int, int, int)> resolveInput(String input, List<String> buttons,
        {int origin = 0}) =>
    [
      for (final p in parseInput(input, origin: origin))
        (p.frame, buttonIndex(buttons, p.button), p.frames)
    ];

/// the presses as JSON: [[frame, button, frames], ...]
String pressesJson(List<(int, int, int)> presses, List<String> buttons) =>
    jsonEncode([
      for (final (f, b, n) in presses) [f, buttons[b], n]
    ]);

/// holds each button while any of its presses lasts
class PadPlayer {
  /// (frame, button index, frames); more may be added while playing
  final List<(int, int, int)> presses;
  final List<bool> _held;

  PadPlayer(this.presses, int buttons) : _held = List.filled(buttons, false);

  /// calls [change] for each button that goes down or up at [frame]
  void step(int frame, void Function(int button, bool down) change) {
    final down = List<bool>.filled(_held.length, false);
    for (final (f, b, n) in presses) {
      if (frame >= f && frame < f + n) down[b] = true;
    }
    for (var b = 0; b < _held.length; b++) {
      if (down[b] == _held[b]) continue;
      _held[b] = down[b];
      change(b, down[b]);
    }
  }
}

/// [name] as written in a sequence
String quoteButton(String name) =>
    name.isEmpty || name.split("").any(_reserved.contains) ? '"$name"' : name;

const _reserved = {
  "@", "_", ":", "+", "[", "]", "*", "(", ")", "|", '"', //
  " ", "\t", "\n", "\r",
};

sealed class _Node {}

class _At extends _Node {
  final int frame;
  _At(this.frame);
}

class _Wait extends _Node {
  final int frames;
  _Wait(this.frames);
}

class _Hold extends _Node {
  final int frames;
  _Hold(this.frames);
}

class _Buttons extends _Node {
  final List<String> names;
  final int? frames;
  _Buttons(this.names, this.frames);
}

class _Repeat extends _Node {
  final List<_Node> body;
  final int count;
  _Repeat(this.body, this.count);
}

class _Parallel extends _Node {
  final List<List<_Node>> branches;
  _Parallel(this.branches);
}

/// returns the cursor after [nodes]
int _eval(List<_Node> nodes, int cursor, int hold, bool inRepeat,
    List<Press> presses) {
  for (final node in nodes) {
    switch (node) {
      case _At(:final frame):
        if (inRepeat) throw InputError("@$frame inside [ ]");
        if (frame < cursor) {
          throw InputError("@$frame is before the cursor at $cursor");
        }
        cursor = frame;
      case _Wait(:final frames):
        cursor += frames;
      case _Hold(:final frames):
        hold = frames;
      case _Buttons(:final names, :final frames):
        final n = frames ?? hold;
        for (final b in names) {
          presses.add((frame: cursor, button: b, frames: n));
        }
        cursor += n;
      case _Repeat(:final body, :final count):
        for (var i = 0; i < count; i++) {
          cursor = _eval(body, cursor, hold, true, presses);
        }
      case _Parallel(:final branches):
        var end = cursor;
        for (final b in branches) {
          final e = _eval(b, cursor, hold, inRepeat, presses);
          if (e > end) end = e;
        }
        cursor = end;
    }
  }
  return cursor;
}

class _Parser {
  final String text;
  int pos = 0;

  _Parser(this.text);

  List<_Node> parse() {
    final nodes = _sequence();
    if (pos < text.length) _fail("unexpected ${text[pos]}");
    return nodes;
  }

  Never _fail(String message) =>
      throw InputError("$message at column ${pos + 1} in input: $text");

  bool get _end => pos >= text.length;

  String get _c => text[pos];

  void _skipSpaces() {
    while (!_end && " \t\n\r".contains(_c)) {
      pos++;
    }
  }

  int _number() {
    final start = pos;
    while (!_end && "0123456789".contains(_c)) {
      pos++;
    }
    if (start == pos) _fail("a number expected");
    return int.parse(text.substring(start, pos));
  }

  /// reads items until the end, "]", "|" or ")"
  List<_Node> _sequence() {
    final nodes = <_Node>[];
    while (true) {
      _skipSpaces();
      if (_end || "])|".contains(_c)) return nodes;
      switch (_c) {
        case "@":
          pos++;
          nodes.add(_At(_number()));
        case "_":
          pos++;
          nodes.add(_Wait(_number()));
        case ":":
          pos++;
          nodes.add(_Hold(_positive()));
        case "[":
          pos++;
          final body = _sequence();
          if (_end || _c != "]") _fail("a [ without its ]*N");
          pos++;
          if (_end || _c != "*") _fail("a ] without *N");
          pos++;
          nodes.add(_Repeat(body, _positive()));
        case "(":
          pos++;
          final branches = [_sequence()];
          while (!_end && _c == "|") {
            pos++;
            branches.add(_sequence());
          }
          if (_end || _c != ")") _fail("a ( without its )");
          pos++;
          nodes.add(_Parallel(branches));
        default:
          nodes.add(_buttons());
      }
    }
  }

  int _positive() {
    final n = _number();
    if (n == 0) _fail("0 is not allowed here");
    return n;
  }

  _Buttons _buttons() {
    final names = [_name()];
    while (!_end && _c == "+") {
      pos++;
      names.add(_name());
    }
    int? frames;
    if (!_end && _c == ":") {
      pos++;
      frames = _positive();
    }
    if (!_end && !" \t\n\r])|([".contains(_c)) _fail("unexpected $_c");
    return _Buttons(names, frames);
  }

  String _name() {
    if (_end) _fail("a button name expected");
    if (_c == '"') {
      final close = text.indexOf('"', pos + 1);
      if (close < 0) _fail("a \" without its closing \"");
      final name = text.substring(pos + 1, close);
      pos = close + 1;
      return name;
    }
    final start = pos;
    while (!_end && !_reserved.contains(_c)) {
      pos++;
    }
    if (start == pos) _fail("unexpected $_c");
    return text.substring(start, pos);
  }
}

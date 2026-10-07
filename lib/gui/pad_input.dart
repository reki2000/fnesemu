import 'package:flutter/foundation.dart';

import '../core/pad_button.dart';

/// Combines independent input sources before sending changes to the core.
class PadInput extends ChangeNotifier {
  final void Function(PadButton) onDown;
  final void Function(PadButton) onUp;
  final _sources = <Object, Set<PadButton>>{};
  Set<PadButton> _pressed = {};
  bool enabled = true;
  int generation = 0;

  PadInput({required this.onDown, required this.onUp});

  Set<PadButton> get pressed => Set.unmodifiable(_pressed);

  void setSource(Object source, Set<PadButton> buttons) {
    if (!enabled && buttons.isNotEmpty) return;
    if (buttons.isEmpty) {
      _sources.remove(source);
    } else {
      _sources[source] = Set.of(buttons);
    }
    final next = _sources.values.expand((buttons) => buttons).toSet();
    if (setEquals(next, _pressed)) return;
    for (final button in _pressed.difference(next)) {
      onUp(button);
    }
    for (final button in next.difference(_pressed)) {
      onDown(button);
    }
    _pressed = next;
    notifyListeners();
  }

  void clear() {
    generation++;
    _sources.clear();
    for (final button in _pressed) {
      onUp(button);
    }
    _pressed = {};
    notifyListeners();
  }
}

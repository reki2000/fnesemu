import 'package:flutter/foundation.dart';

import 'package:fnesemu_core/app_api.dart';

/// Combines independent input sources into the state that the core reads.
/// The core pulls the buttons and axes through [PadSource]; nothing is pushed.
class PadInput extends ChangeNotifier implements PadSource {
  final _sources = <Object, Set<PadButton>>{};
  final _axisSources = <Object, Map<PadAxis, double>>{};
  Set<PadButton> _pressed = {};
  Map<PadAxis, double> _axes = {};
  bool enabled = true;
  int generation = 0;

  Set<PadButton> get pressed => Set.unmodifiable(_pressed);

  /// Current axis values, -1.0..1.0. An axis that no source holds is absent.
  Map<PadAxis, double> get axes => Map.unmodifiable(_axes);

  // The GUI has one controller.
  @override
  bool isPressed(int controllerId, PadButton button) =>
      controllerId == 0 && _pressed.contains(button);

  @override
  double axis(int controllerId, PadAxis axis) =>
      controllerId == 0 ? _axes[axis] ?? 0 : 0;

  void setSource(Object source, Set<PadButton> buttons) {
    if (!enabled && buttons.isNotEmpty) return;
    if (buttons.isEmpty) {
      _sources.remove(source);
    } else {
      _sources[source] = Set.of(buttons);
    }
    final next = _sources.values.expand((buttons) => buttons).toSet();
    if (setEquals(next, _pressed)) return;
    _pressed = next;
    notifyListeners();
  }

  /// Sets the axes held by [source]; empty values release the source. For an
  /// axis held by several sources, the value farthest from neutral wins.
  void setAxisSource(Object source, Map<PadAxis, double> values) {
    if (!enabled && values.isNotEmpty) return;
    if (values.isEmpty) {
      _axisSources.remove(source);
    } else {
      _axisSources[source] = Map.of(values);
    }
    _updateAxes();
  }

  void _updateAxes() {
    final next = <PadAxis, double>{};
    for (final values in _axisSources.values) {
      for (final e in values.entries) {
        final current = next[e.key];
        if (current == null || e.value.abs() > current.abs()) {
          next[e.key] = e.value;
        }
      }
    }
    if (mapEquals(next, _axes)) return;
    _axes = next;
    notifyListeners();
  }

  void clear() {
    generation++;
    _sources.clear();
    _axisSources.clear();
    _pressed = {};
    _axes = {};
    notifyListeners();
  }
}

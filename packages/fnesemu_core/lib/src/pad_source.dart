import 'pad_button.dart';

/// The state of the controllers, owned by the GUI. A core reads it where the
/// hardware samples its controllers, and never writes it.
abstract interface class PadSource {
  /// Whether [button] of the controller [controllerId] is held down.
  bool isPressed(int controllerId, PadButton button);

  /// The position of [axis], -1.0..1.0 in screen orientation: -1.0 is left /
  /// up and 1.0 is right / down. An axis that is not held reads 0.
  double axis(int controllerId, PadAxis axis);
}

/// A source without any input.
class NoPadSource implements PadSource {
  const NoPadSource();

  @override
  bool isPressed(int controllerId, PadButton button) => false;

  @override
  double axis(int controllerId, PadAxis axis) => 0;
}

/// The input connection of a core: the core reads through it, and the owner
/// of the core replaces [source] at any time.
class PadPort implements PadSource {
  PadSource source = const NoPadSource();

  @override
  bool isPressed(int controllerId, PadButton button) =>
      source.isPressed(controllerId, button);

  @override
  double axis(int controllerId, PadAxis axis) =>
      source.axis(controllerId, axis);
}

/// A [PadSource] that is set by calls, for tests and tools without a GUI.
class PadState implements PadSource {
  final _pressed = <int, Set<String>>{};
  final _axes = <int, Map<String, double>>{};

  void press(int controllerId, PadButton button) =>
      (_pressed[controllerId] ??= {}).add(button.name);

  void release(int controllerId, PadButton button) =>
      _pressed[controllerId]?.remove(button.name);

  void setAxis(int controllerId, PadAxis axis, double value) =>
      (_axes[controllerId] ??= {})[axis.name] = value;

  void clear() {
    _pressed.clear();
    _axes.clear();
  }

  @override
  bool isPressed(int controllerId, PadButton button) =>
      _pressed[controllerId]?.contains(button.name) ?? false;

  @override
  double axis(int controllerId, PadAxis axis) =>
      _axes[controllerId]?[axis.name] ?? 0;
}

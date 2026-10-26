class PadButton {
  static const up = PadButton("up");
  static const down = PadButton("down");
  static const left = PadButton("left");
  static const right = PadButton("right");

  /// a key position which has no button of the core
  static const none = PadButton("");

  final String name;

  const PadButton(this.name);
}

/// An analog axis of a controller. A value is in -1.0..1.0 and 0 is neutral.
/// Screen orientation applies: -1.0 is left / up and 1.0 is right / down.
class PadAxis {
  static const leftX = PadAxis("lx");
  static const leftY = PadAxis("ly");
  static const rightX = PadAxis("rx");
  static const rightY = PadAxis("ry");

  final String name;

  const PadAxis(this.name);
}

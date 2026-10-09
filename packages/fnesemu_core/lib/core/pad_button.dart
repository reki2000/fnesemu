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

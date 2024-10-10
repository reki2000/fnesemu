import '../pad_button.dart';

class Pad {
  Pad();

  void keyDown(int controllerId, PadButton k) {}

  void keyUp(int controllerId, PadButton k) {}

  List<PadButton> get buttons => [
        PadButton.up,
        PadButton.down,
        PadButton.left,
        PadButton.right,
        const PadButton("RUN"),
        const PadButton("A"),
        const PadButton("B"),
        const PadButton("C"),
        const PadButton("X"),
        const PadButton("Y"),
        const PadButton("Z"),
      ];
}

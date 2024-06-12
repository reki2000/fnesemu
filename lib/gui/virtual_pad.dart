// Flutter imports:
import 'package:flutter/material.dart';

// Project imports:
import 'nes_controller.dart';

/// provides virtual pad buttons such as left, up, down, right, select, start, b and a.
/// those buttons handle `tapDown` and tapUp` events
class VirtualPadWidget extends StatelessWidget {
  final NesController controller;

  const VirtualPadWidget({
    super.key,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    // build a tap-effected button
    Widget button(IconData icon, NesPadButton button, {String name = ""}) {
      return InkResponse(
          canRequestFocus: false,
          containedInkWell: false,
          onTapDown: (_) => controller.padDown(button),
          onTapUp: (_) => controller.padUp(button),
          child: Stack(
            alignment: Alignment.center,
            children: [
              // icon for this button
              Icon(icon, color: Theme.of(context).primaryColor),
              // text shown on this button
              if (name != "")
                Center(
                    child: Text(
                  name,
                  style: const TextStyle(color: Colors.white),
                )),
            ],
          ));
    }

    return Container(
        width: 512,
        margin: const EdgeInsets.all(10.0),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          button(Icons.arrow_back, NesPadButton.left),
          button(Icons.arrow_upward, NesPadButton.up),
          button(Icons.arrow_downward, NesPadButton.down),
          button(Icons.arrow_forward, NesPadButton.right),
          button(Icons.circle, NesPadButton.select, name: "sel"),
          button(Icons.circle, NesPadButton.start, name: "sta"),
          button(Icons.circle, NesPadButton.b, name: "B"),
          button(Icons.circle, NesPadButton.a, name: "A"),
        ]));
  }
}

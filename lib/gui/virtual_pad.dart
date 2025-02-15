// Flutter imports:
import 'package:flutter/material.dart';

// Project imports:
import '../core/core_controller.dart';
import '../core/pad_button.dart';

/// provides virtual pad buttons such as left, up, down, right, select, start, b and a.
/// those buttons handle `tapDown` and tapUp` events
class VirtualPadWidget extends StatelessWidget {
  final CoreController controller;

  const VirtualPadWidget({
    super.key,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    // build a tap-effected button
    Widget button(IconData icon, PadButton button, {String name = ""}) {
      return InkResponse(
          canRequestFocus: false,
          containedInkWell: false,
          onTapDown: (_) => controller.padDown(0, button),
          onTapUp: (_) => controller.padUp(0, button),
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
          button(Icons.arrow_back, PadButton.left),
          button(Icons.arrow_upward, PadButton.up),
          button(Icons.arrow_downward, PadButton.down),
          button(Icons.arrow_forward, PadButton.right),
          if (controller.buttons.length > 4)
            ...controller.buttons
                .sublist(4)
                .map((b) => button(Icons.circle, b, name: b.name))
        ]));
  }
}

// Flutter imports:
import 'package:flutter/material.dart';

// Project imports:
import '../core/core_controller.dart';
import '../core/pad_button.dart';
import 'pad_input.dart';

/// Action buttons; directional input is provided by DirectionPad.
class VirtualPadWidget extends StatelessWidget {
  final CoreController controller;
  final PadInput input;

  /// the buttons are shrunk to be placed in a line within this width
  final double width;

  const VirtualPadWidget({
    super.key,
    required this.controller,
    required this.input,
    required this.width,
  });

  static const keys = "ASZXCQWERD";

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).primaryColor;

    // build a tap-effected button
    Widget button(PadButton button,
        {String name = "", IconData? icon, String key = ""}) {
      return InkResponse(
          canRequestFocus: false,
          containedInkWell: false,
          onTapDown: (_) => input.setSource(button, {button}),
          onTapUp: (_) => input.setSource(button, {}),
          onTapCancel: () => input.setSource(button, {}),
          // leaves room for the key label at the top right
          child: Padding(
            padding: const EdgeInsets.only(top: 8, right: 6),
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                // icon for this button
                if (icon != null) Icon(icon, color: color),
                // text shown on this button
                if (name != "")
                  Container(
                    color: color,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    child: Text(
                      name,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                // assigned key
                if (key != "")
                  Positioned(
                    top: -10,
                    right: -8,
                    child: Text(
                      key,
                      style: const TextStyle(color: Colors.grey, fontSize: 11),
                    ),
                  ),
              ],
            ),
          ));
    }

    return Container(
        width: width,
        margin: const EdgeInsets.all(5.0),
        child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(spacing: 8, children: [
              if (controller.buttons.length > 4)
                ...controller.buttons.sublist(4).asMap().entries.map((e) =>
                    button(e.value,
                        name: e.value.name,
                        key: e.key < VirtualPadWidget.keys.length
                            ? VirtualPadWidget.keys[e.key]
                            : ""))
            ])));
  }
}

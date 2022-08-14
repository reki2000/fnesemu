// Dart imports:
import 'dart:async';

// Flutter imports:
import 'package:flutter/material.dart';

// Project imports:
import 'nes_controller.dart';

// provides a `Stream<double>` which emits 1.0 to 0.0 in every tick(40 ms) during its lifetime(300 ms)
class _FlashStream {
  final _stream = StreamController<double>();
  Timer? _timer;

  static const _tick = Duration(milliseconds: 30);
  static const _loop = 10;

  void flash() {
    _timer?.cancel();
    var _counter = _loop;
    _timer = Timer.periodic(_tick, (_) {
      if (_counter == 0) {
        _timer?.cancel();
      }
      _stream.add(_counter-- / _loop);
    });
  }

  get stream => _stream.stream;
}

/// provides virtual pad buttons such as left, up, down, right, select, start, b and a.
/// those buttons handle `tapDown` and tapUp` events
class VirtualPadWidget extends StatelessWidget {
  final NesController controller;

  const VirtualPadWidget({
    Key? key,
    required this.controller,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // build a tap-effected button
    Widget _button(IconData icon, NesPadButton button, {String name = ""}) {
      final animator = _FlashStream();

      // do the flush animation when PadDown event for this button is fired.
      controller.padDownStream.listen((event) {
        if (event == button) {
          animator.flash();
        }
      });

      return GestureDetector(
        onTapDown: (_) => controller.padDown(button),
        onTapUp: (_) => controller.padUp(button),
        child: Stack(alignment: Alignment.center, children: [
          // icon for this button
          Icon(icon, color: Theme.of(context).primaryColor),
          // text shown on this button
          if (name != "")
            Center(
                child: Text(
              name,
              style: const TextStyle(color: Colors.white),
            )),
          // animating circle when tapped
          Transform(
              transform: (Matrix4.identity() * 2.0)
                ..setTranslationRaw(-12.5, -12.5, 0.0),
              child: StreamBuilder<double>(
                  stream: animator.stream,
                  builder: (_, snapshot) => Opacity(
                      child: Icon(Icons.circle,
                          color: Theme.of(context).primaryColor),
                      opacity: snapshot.data ?? 0.0))),
        ]),
      );
    }

    return Container(
        width: 512,
        margin: const EdgeInsets.all(10.0),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          _button(Icons.arrow_back, NesPadButton.left),
          _button(Icons.arrow_upward, NesPadButton.up),
          _button(Icons.arrow_downward, NesPadButton.down),
          _button(Icons.arrow_forward, NesPadButton.right),
          _button(Icons.circle, NesPadButton.select, name: "sel"),
          _button(Icons.circle, NesPadButton.start, name: "sta"),
          _button(Icons.circle, NesPadButton.b, name: "B"),
          _button(Icons.circle, NesPadButton.a, name: "A"),
        ]));
  }
}

// Dart imports:
import 'dart:typed_data';
import 'dart:ui' as ui;

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:google_fonts/google_fonts.dart';

// Project imports:
import '../cpu/nes.dart';

class NesWidget extends StatefulWidget {
  const NesWidget({Key? key}) : super(key: key);

  @override
  State<NesWidget> createState() => _NesWidgetState();
}

class _NesWidgetState extends State<NesWidget> {
  ui.Image? screenImage;

  @override
  void initState() {
    super.initState();
    nes.renderVideo = (Uint8List buf) async => renderVideo(buf);
  }

  void renderVideo(Uint8List buf) async {
    ui.decodeImageFromPixels(buf, 256, 240, ui.PixelFormat.rgba8888, (image) {
      setState(() {
        screenImage?.dispose();
        screenImage = image;
      });
    });
  }

  @override
  Widget build(BuildContext ctx) {
    return Column(
      children: [
        Container(
            width: 512,
            height: 480,
            color: Colors.black,
            child: RawImage(image: screenImage, scale: 0.5)),
        Text(nes.dump(showZeroPage: true, showStack: true), style: debugStyle),
      ],
    );
  }
}

final nes = Nes();

final debugStyle = GoogleFonts.robotoMono(fontSize: 12);

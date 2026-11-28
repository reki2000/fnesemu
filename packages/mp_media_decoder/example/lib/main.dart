// Tries mp_media_decoder: plays an H.264 stream (an Annex B `.h264` file or
// the video of a PSP `.pmf` movie) or an ATRAC3plus `.at3` file given by its
// path.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:mp_audio_stream/mp_audio_stream.dart';
import 'package:mp_media_decoder/mp_media_decoder.dart';

import 'media_files.dart';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'mp_media_decoder example',
        theme: ThemeData(colorSchemeSeed: Colors.indigo),
        home: const PlayerPage(),
      );
}

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  final _decoders = MediaDecoders.open();
  final _path = TextEditingController();
  final _log = <String>[];
  ui.Image? _picture;
  Timer? _timer;
  AudioStream? _audio;

  @override
  void dispose() {
    _stop();
    _path.dispose();
    super.dispose();
  }

  void _say(String line) => setState(() => _log.insert(0, line));

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _audio?.uninit();
    _audio = null;
  }

  Future<void> _play() async {
    _stop();
    final path = _path.text.trim();
    final Uint8List file;
    try {
      file = await File(path).readAsBytes();
    } on IOException catch (e) {
      _say('cannot read $path: $e');
      return;
    }
    final atrac = Atrac3plusFile.parse(file);
    if (atrac != null) return _playAtrac3plus(atrac);
    final lower = path.toLowerCase();
    final stream = lower.endsWith('.pmf') ? psmfVideo(file) : file;
    if (stream == null) {
      _say('not a PSMF movie: $path');
      return;
    }
    _playH264(stream);
  }

  /// Shows the pictures of an H.264 stream at 30 per second.
  void _playH264(Uint8List stream) {
    final decoder = _decoders.openH264();
    if (decoder == null) {
      _say('no H.264 decoder on this platform');
      return;
    }
    final units = h264AccessUnits(stream);
    _say('H.264: ${units.length} access units');
    var next = 0;
    final watch = Stopwatch()..start();
    _timer = Timer.periodic(const Duration(milliseconds: 33), (timer) {
      if (next >= units.length) {
        timer.cancel();
        decoder.close();
        _say('H.264: done, ${(watch.elapsedMilliseconds / units.length).toStringAsFixed(1)} ms per unit');
        return;
      }
      final picture = decoder.decode(units[next++]);
      if (picture != null) _show(picture);
    });
  }

  void _show(DecodedPicture picture) {
    ui.decodeImageFromPixels(picture.pixels.buffer.asUint8List(),
        picture.width, picture.height, ui.PixelFormat.rgba8888, (image) {
      if (!mounted) return;
      setState(() {
        _picture?.dispose();
        _picture = image;
      });
    });
  }

  /// Decodes an ATRAC3plus file and plays it.
  void _playAtrac3plus(Atrac3plusFile file) {
    final decoder = _decoders.openAtrac3plus(
        sampleRate: file.sampleRate,
        channels: file.channels,
        blockAlign: file.blockAlign);
    if (decoder == null) {
      _say('no ATRAC3plus decoder on this platform');
      return;
    }
    _say('ATRAC3plus: ${file.sampleRate} Hz, ${file.channels} channels, '
        '${file.frameCount} frames of ${file.blockAlign} bytes');
    final audio = _audio = getAudioStream()
      ..init(
          bufferMilliSec: 1000,
          waitingBufferMilliSec: 100,
          channels: file.channels,
          sampleRate: file.sampleRate)
      ..resume();
    var next = 0;
    // each frame holds 2048 samples per channel: about 46 ms at 44100 Hz
    _timer = Timer.periodic(const Duration(milliseconds: 20), (timer) {
      if (audio.stat().full > 0 && next > 0) return;
      for (var i = 0; i < 2 && next < file.frameCount; i++) {
        final samples = decoder.decode(file.frame(next++));
        if (samples != null) {
          audio.push(Float32List.fromList(
              [for (final s in samples) s / 32768]));
        }
      }
      if (next >= file.frameCount) {
        timer.cancel();
        decoder.close();
        _say('ATRAC3plus: done');
      }
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('Decoders: ${_decoders.name}')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _path,
                    decoration: const InputDecoration(
                        labelText: 'path of a .h264, .pmf or .at3 file'),
                    onSubmitted: (_) => _play(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _play, child: const Text('Play')),
                const SizedBox(width: 8),
                OutlinedButton(onPressed: _stop, child: const Text('Stop')),
              ]),
              const SizedBox(height: 16),
              Expanded(
                child: Container(
                  color: Colors.black,
                  child: _picture == null
                      ? null
                      : RawImage(image: _picture, fit: BoxFit.contain),
                ),
              ),
              SizedBox(
                height: 120,
                child: ListView(children: [for (final l in _log) Text(l)]),
              ),
            ],
          ),
        ),
      );
}

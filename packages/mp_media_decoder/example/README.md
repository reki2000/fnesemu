# mp_media_decoder example

Plays a file given by its path with the decoders of `mp_media_decoder`:

- an H.264 Annex B stream (`.h264`) or the video of a PSP movie (`.pmf`), shown at 30 pictures per second;
- an ATRAC3plus RIFF WAVE file (`.at3`), played through `mp_audio_stream`.

The title bar shows the decoders that the platform has. Run it with `flutter run -d linux` (or another desktop or mobile device).

# Controller pacing benchmark

The controller uses a fixed event-loop yield of 2ms by default and limits output to 60 FPS. `FRAME_YIELD_US=1000` selects a 1ms yield at build time. Each frame advances a deadline by 16,667 microseconds. If execution overruns the deadline, the next deadline becomes the completion time plus the fixed yield. Timer waits round up to milliseconds, and deadline accumulation prevents that rounding from adding an extra delay every frame. Existing emulated-clock pacing still limits slower systems.

## Running

Build with `dart build cli -t tool/controller_bench.dart -o /tmp/controller-bench` and run `/tmp/controller-bench/bundle/bin/controller_bench`, then pass `ps <BIOS> <disc>` or `n64 <ROM|zip>`, `-w 2400`, `-m 600`, and optional `-p frame:button` inputs. It fast-forwards without pacing, synchronizes controller clocks with one debug frame, disables debug rendering, then runs the actual continuous controller loop. Output includes completed-frame FPS, process CPU time and the interval of a 16ms event-loop timer at the 95th percentile and maximum. CPU time uses Linux `/proc/self/stat` with 10ms ticks.

For onscreen measurement, build the application root with `flutter build linux --release --target tool/controller_gui_bench.dart --dart-define=FRAME_YIELD_US=2000`. Run the bundle executable with the same arguments. This diagnostic uses the production `CoreView`, `ImageContainer` and `SoundPlayer`, including image conversion, painting, virtual controls and audio output. It does not include the full application menus or storage. The FPS value counts completed emulated frames, not presentation acknowledgements from the compositor.

The periodic timer is a probe of event-loop scheduling, not a measurement of input latency. Check menus, window resizing, input, pause/resume and audio manually in the normal application.

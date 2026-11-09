# mp_gpu probe

Checks how long the platform takes before the pixels of a pass can be read back, so that `GpuDevice.settle` can wait no longer than needed. `lib/main.dart` describes the cases and the output.

## Running

`tool/prepare.sh` generates the platform runners with Flutter GPU enabled and compiles the shaders. The runners and the shader bundle are not checked in.

```
sh tool/prepare.sh linux
flutter build linux --release
MP_GPU_PROBE_OUT=$PWD/probe.out build/linux/x64/release/bundle/mp_gpu_probe
```

- Web: build with `flutter build web --wasm`, serve `build/web` over HTTP and run `node tool/run_web.mjs URL --enable-unsafe-webgpu`.
- Android: build with `flutter build apk --release` and run `tool/run_android.sh` with a device connected over adb. Keep the screen on: the engine makes no frames while it is off.

## CI

`.github/workflows/mp-gpu-probe.yaml` builds and runs the probe on Linux, Windows, macOS and Chrome when a branch `probe/...` is pushed or the workflow is started by hand. Each job writes the probe lines to its summary, and the `MP_GPU_PROBE_BEST` line ranks the waits. The runners have no real GPU, so the results show the behavior of the APIs on software renderers, not of real drivers. Emulators and simulators tell even less, so they are not run.

The `MP_GPU_PROBE_DEVICE` line shows the wait that `GpuDevice.create` chose by its check; the `settle` cases use it.

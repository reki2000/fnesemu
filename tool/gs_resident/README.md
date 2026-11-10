# GS frame capture and GPU replay

The Linux validation executable records one emulated frame after restoring a checkpoint. Each primitive is recorded in issue order. The register and transfer stream also includes vertical blank events.

Build the validation entry point from the repository root.

```sh
flutter build linux --release --target tool/gs_frame_check.dart
```

The configuration is a local JSON file with the BIOS and disc paths in `files`, a headless checkpoint path in `state`, the absolute frame number in `frame`, and the optional input sequence in `input`.

```sh
build/linux/x64/release/bundle/fnesemu record trace-config.json frame-trace
build/linux/x64/release/bundle/fnesemu replay frame-trace
```

Replay takes an optional numeric packet limit. Replay reads only the trace directory. It reconstructs the final GS state from the raw command stream and then sends each supported packet to the host GPU with the texture, destination, and depth inputs captured immediately before the draw. It compares the returned color and depth writes with the software reference for that command. The GPU packet checks run independently. A command outside the GPU path is listed in the trace and counted separately. The tool returns 2 if a GPU check fails or no packets are tested.

- `gs-start.bin` and `gs-end.bin` contain the GS checkpoints.
- `gs-stream.bin` contains 16-byte little-endian records with the operation, register, and value.
- `draws.jsonl` contains primitive vertices, register state, and packet offsets or the reason a command was excluded.
- `packets.bin` contains the GPU inputs and software output for each eligible draw.
- `reference.png` contains the software scanout.
- `replay.jsonl` and `replay-summary.json` contain the GPU comparison results.
- `mismatches.bin` contains GPU readbacks for mismatching draws, indexed by byte offset and length in `replay.jsonl`.

The Linux OpenGL ES replay covers textured and untextured sprites and triangles, nearest and linear filtering, mipmaps, fog, and 16-, 24-, and 32-bit framebuffer writes where the packet can preserve the original VRAM dependencies. A third output plane carries per-pixel depth for supported depth-writing triangles. The check compares the actual stored color and alpha bits as well as depth. Each packet starts from the recorded software state so that one mismatch cannot change the input to a later draw.

The packet count measures replay coverage for the captured frame. It does not measure coverage or throughput of the live emulator. The replay waits for GPU readback and does not substitute software output for missing or invalid GPU results. Commands that cannot be represented by a packet stay visible in `draws.jsonl`. Keep the trace and its images local.

The report counts offscreen and degenerate geometry separately as `noRasterEffect`. The raw software replay checks their effect on the final GS state along with the rest of the command stream.

For a fixed-UV triangle that reads from the same 32-bit buffer it writes, the recorder checks texture dependencies in scan order. The packet stores row boundaries when a later row needs an earlier pass. Replay takes the color writes from the GPU readback, applies the framebuffer mask, and updates the texture input for the next pass. It compares the combined GPU result against the software output for the entire draw. The replay log reports the number of GPU passes for such commands.

Use `build/linux/x64/release/bundle/fnesemu full frame-trace` for a complete scanout. This mode starts at the same GS checkpoint and replays registers, transfers, and draw kicks in order. It builds each GPU draw from the current replay VRAM and applies the returned writes before advancing to the next GS event. It saves `full-gpu.png` and aborts if a required GPU draw fails. The full replay and the independent packet checks serve different purposes. Only the full replay carries GPU differences forward into later draws.

Pass an optional numeric DISPFB2 value to `full` when the recorded draw target is displayed after the trace ends. Both the software and GPU replay then read the same target through the GS display circuit and capture both field parities from that buffer. The `full-omit` command uses the same scanout with all draw kicks omitted as a control.

The Linux `replay-atlas` mode packs independent validation outputs into shared GPU targets and reads each target once. It checks a marker for every packed draw, retries missing results, and reports the number of target submissions. Two-pass CT32 feedback draws use a GPU render target as the next pass's texture input and read back only the combined output. The `full` mode also uses GPU feedback for those draws. The full mode still applies the final result of each draw to the CPU-side GS memory so the next command can build its packet.

The Linux Vulkan experiment in `tool/gs_resident/` processes a recorded GS stream from its checkpoint. The encoder reads the raw events, resolves draw state and palette addresses, and forwards packed host transfer words. It never uses the software draw snapshots or the software reference image as input. Vulkan stores local memory and the CLUT on the GPU, preserves the order of updates that touch the same data, and reads only the final scanout.

Build and run from the source directory.

```sh
dart compile exe --packages=.dart_tool/package_config.json tool/gs_resident_export.dart -o tool/gs_resident/export
glslangValidator -V tool/gs_resident/replay.comp -o tool/gs_resident/replay.spv
cc -O2 tool/gs_resident/replay.c -lvulkan -o tool/gs_resident/replay
tool/gs_resident/export "$trace" 0x9400
FNES_GS_GPU=Intel tool/gs_resident/replay tool/gs_resident/replay.spv \
  "$trace/resident-start.bin" "$trace/resident-commands.bin" \
  "$trace/resident-aux.bin" "$trace/resident-scanout.rgba"
```

The output file is tightly packed RGBA, from the top scanline. The encoder prints its dimensions. The replay reports CPU preparation, pipeline creation, command recording, and GPU submission timings separately. It resets VRAM from the checkpoint before each timing sample and reads only the final sample. It selects a hardware compute device and rejects software Vulkan devices. The experiment supports the transfers and display mode of the recorded frame. It currently rejects guest readback, local-to-local transfers, partial host transfers, and aliased upload destinations.

Compatible ordered draw groups use an 8 by 8 tile mask. A workgroup visits only commands that can cover its tile and retains their issue order. The recorder groups draws only when their color and depth layouts agree and their texture reads are separate from the group's writes. The compute shader uses ordinary memory access for proven exclusive words and retains atomic updates for packed or potentially shared words. For feedback, the snapshot covers the words the draw can change.

The headless `gs_resident_live.dart` driver can also attach the encoder directly to the emulated GS after a local checkpoint. The worker receives each ordered batch over a pipe, keeps VRAM and the Vulkan pipeline across batches, and publishes completed images through the core image API. The main isolate runs the next emulation step while a separate isolate feeds the Vulkan process. This test uses the known alternating output buffers of the local scene. The application does not select this experimental backend by default.

Build the live driver with `dart compile exe --packages=.dart_tool/package_config.json tool/gs_resident_live.dart -o tool/gs_resident/live`. Make the local JIT memory library visible to the executable, for example with `LD_PRELOAD` on Linux. Run `tool/gs_resident/live CONFIG OUTPUT 4 gpu` and `tool/gs_resident/live CONFIG OUTPUT 4 software` with the same checkpoint. The timed interval starts after the worker is ready and ends when the last image is collected. Both modes save each tested frame as RGBA.

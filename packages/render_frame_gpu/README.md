# render_frame_gpu

An experimental renderer that draws a core's `RenderFrame` with Flutter GPU into an offscreen texture.

## Shaders

Run `tool/build_shaders.sh` to compile `shaders/frame.vert` and `shaders/frame.frag` into `shaders/frame.shaderbundle` with the `impellerc` of the Flutter SDK.

## Capturing a frame

`core_headless run` writes the renders of the second to last frame with `--render-frames PREFIX`. Each render goes to `PREFIX_N.rframe` together with the colors of the core's own renderer.

## Replay app

`example/` draws one `.rframe` file, times it and compares the result with the colors of the core's renderer.

```
cd example
flutter build linux --profile
FLUTTER_ENGINE_SWITCHES=2 FLUTTER_ENGINE_SWITCH_1=enable-impeller FLUTTER_ENGINE_SWITCH_2=enable-flutter-gpu \
  build/linux/x64/profile/bundle/render_frame_gpu_example <file.rframe> [draws] [out dir] [--exit]
```

## Known limits

- Modifier volumes, the secondary accumulation buffer, bump maps and mipmaps are not drawn.
- The background plane becomes a flat clear color.
- Automatic sorting of translucent triangles is approximated by the mean depth of each triangle.
- The result is not written back to the core's video memory.
- On the Linux GLES backend, uploaded textures lost their contents after some tens of frames, so textures are written again on every draw.

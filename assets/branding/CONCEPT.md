# fnesemu icon concept and design notes

## Concept

Four central cores and six surrounding platform pieces represent multiple emulation cores running across Flutter's Android, iOS, Web, Windows, macOS, and Linux targets. The individual pieces are abstract and do not depict specific operating system logos.

The blue palette, diagonal ribbons, and folded shapes recall Flutter. Six distinct outer pieces and independent central cores avoid the three-arrow cycle associated with recycling symbols.

## Approved source

`app_icon.svg` is the approved vector master, without embedded raster data. Its canvas is 1254 × 1254, centered at (627, 627), with a white background. All platform icons are exported from this SVG. Only the master SVG and these notes are retained as design sources; proposal images, comparison pages, and generation scripts are excluded.

## Geometry and placement

All straight edges are horizontal, vertical, or at ±45 degrees. Curves appear only at the central cores' outer corners. Shared outer vertices were adjusted to these directions while remaining close to the approved concept 10. The overall layout is asymmetric, so the gaps are not all identical.

The original four core centers were moved 45 degrees counterclockwise around the image center, independently of each core's own orientation. The cores were enlarged, then enlarged another 5% in linear dimensions, giving a final square side of 168 pixels.

Each core consists of two touching 168 × 84 rectangles with a 2:1 aspect ratio. Only the original square's four outer corners are rounded, with a radius of 33.6 pixels. Corners on the shared boundary remain square, and there is no gap between the rectangles.

| Position | Center | Rotation added to the original 45 degrees |
|---|---|---|
| Top | (631.24264069, 462.95122676) | 0 degrees |
| Right | (787.15968594, 628.76776695) | 90 degrees |
| Bottom | (630.18198052, 784.33125881) | 180 degrees |
| Left | (475.67914883, 616.39339828) | 270 degrees |

The rightmost cyan face is a trapezoid with a horizontal top edge, parallel 45-degree sides, and an acute point facing right.

The blue face of the upper-right piece extends downward by approximately 33.27 pixels. Its minimum distance from the piece below decreases from 90.01 to 56.74 pixels. This matches the median of three other narrow outer gaps: 38.70, 56.74, and 59.56 pixels.

## Colors

| Color | Purpose |
|---|---|
| `#28bcf5` | Light cyan outer ribbons and central rectangle faces |
| `#05aaf0` | Blue outer ribbons and the other central rectangle faces |
| `#045293` | Dark blue folds in the outer pieces |
| `#ffffff` | Background |

The two central colors alternate clockwise from top to right, bottom, and left. Quarter-turn rotations vary the split direction. A matching underlay prevents antialiasing from exposing a white hairline along the shared boundary.

## Platform exports

The SVG is rendered at 2048 pixels and resized with Lanczos filtering. Exports preserve the relative shapes and placement. PNG backgrounds are white, except for the transparent Android adaptive foreground layers.

- Web: SVG and 32-pixel PNG favicons, plus 192- and 512-pixel PWA icons.
- Web maskable: artwork scaled to 80% and centered on white.
- Android: 48/72/96/144/192-pixel legacy icons for mdpi through xxxhdpi, plus 108/162/216/324/432-pixel adaptive foregrounds scaled to 60%, with a separate white background.
- iOS and macOS: all sizes declared by the existing AppIcon asset catalogs; iOS exports are opaque.
- Windows: an ICO containing 16/24/32/48/64/128/256-pixel images.
- Linux: a 256-pixel PNG installed into the bundle's data directory and loaded as the GTK window icon.

Maskable and adaptive exports include padding to keep every outer piece within the [Web manifest safe zone](https://www.w3.org/TR/appmanifest/#icon-masks) and the [Android adaptive icon safe zone](https://developer.android.com/develop/ui/compose/system/icon_design_adaptive).

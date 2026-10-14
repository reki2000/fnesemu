# fnesemu icon concept and design notes

## Concept

Four central cores and six surrounding platform pieces represent multiple emulation cores running across Flutter's Android, iOS, Web, Windows, macOS, and Linux targets. The individual pieces are abstract and do not depict specific operating system logos.

The blue palette, diagonal ribbons, and folded shapes recall Flutter. Six distinct outer pieces and independent central cores avoid the three-arrow cycle associated with recycling symbols.

## Approved source

`app_icon.svg` is the approved vector master, without embedded raster data. Its canvas is 1254 × 1254, centered at (627, 627), with a white background. All platform icons are exported from this SVG. The master SVG, the R2 alternative SVG, and these notes are retained as design sources; comparison pages, raster proposals, and generation scripts are excluded.

## Retained alternative

`app_icon_r2.svg` retains the R2 alternative for future design comparison and is not used for platform exports. It joins the original four central cores while preserving their size, face colors, and rotations. All shared corners are square; only the four corners of the combined outer silhouette remain rounded. The six outer pieces retain their original positions rather than the R1 spacing adjustments.

## Geometry and placement

All straight edges are horizontal, vertical, or at ±45 degrees. Curves appear only at the central cores' outer corners. The R1 revision retains the four central cores, six outer pieces, face colors, and individual piece geometry while balancing their spacing.

Each core consists of two touching 168 × 84 rectangles with a 2:1 aspect ratio. Only the original square's four outer corners are rounded, with a radius of 33.6 pixels. Corners on the shared boundary remain square, and there is no gap between the rectangles.

The core centers are symmetric around (627, 627), at a radius of approximately 152.735065 pixels. Adjacent cores have a 48-pixel gap between their parallel straight edges.

| Position | Center | Rotation |
|---|---|---|
| Top | (627, 474.264935) | 45 degrees |
| Right | (779.735065, 627) | 135 degrees |
| Bottom | (627, 779.735065) | 225 degrees |
| Left | (474.264935, 627) | 315 degrees |

The six outer pieces are translated without rotating, scaling, or changing their paths. The minimum gap between each pair of neighboring outer pieces and between each outer piece and its nearest central core is approximately 48 pixels on the 1254-pixel canvas. Rounded-core outlines were sampled at 7.5-degree intervals when checking distances; measured gaps range from 47.996 to 48.008 pixels. Wedge-shaped openings still widen away from their closest points.

| Outer piece | Translation (x, y) |
|---|---|
| Upper left | (39.413908, 8.933621) |
| Upper right | (-50.775199, 4.986688) |
| Left | (48.159898, -7.007017) |
| Right | (-7.739014, -3.757110) |
| Lower right | (3.815559, -16.110587) |
| Lower left | (40.370566, 2.300800) |

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

// The bits of the I/O ports which hold written values, from the register
// definitions: the defined fields can be read back and the other bits read
// as 0. Ports which are not plain registers are not masked.

/// returns the bits of the [port] which can be written and read back, or
/// null when the port is not a plain register of the SoC. [colorMode] enables the
/// registers and the wider fields of the color mode
int? ioMask(int port, {required bool colorMode}) => switch (port) {
      0x00 => 0x3f, // screen 1/2, sprites, sprite window, screen 2 window
      0x01 => colorMode ? 0xff : 0x07, // back color: palette and index
      0x03 => 0xff, // line compare
      0x04 => colorMode ? 0x3f : 0x1f, // sprite table base
      0x05 => 0x7f, // first sprite
      0x06 => 0xff, // sprite count
      0x07 => colorMode ? 0xff : 0x77, // screen 1/2 map bases
      >= 0x08 && <= 0x13 => 0xff, // windows and scroll positions
      0x14 => colorMode ? 0x03 : 0x01, // LCD sleep and contrast
      0x15 => 0x3f, // LCD segments
      0x16 || 0x17 => 0xff, // line total, vertical sync
      >= 0x1c && <= 0x1f => 0xff, // shade pool
      >= 0x20 && <= 0x3f => 0x77, // mono palettes: two 3-bit colors
      0x40 || 0x44 || 0x46 => colorMode ? 0xfe : 0, // word aligned DMA
      0x41 || 0x45 || 0x47 => colorMode ? 0xff : 0,
      0x42 => colorMode ? 0x0f : 0, // DMA source bank
      0x48 => colorMode ? 0xc0 : 0, // DMA start and direction
      0x4a || 0x4b || 0x4e || 0x4f => colorMode ? 0xff : 0, // sound DMA
      0x4c || 0x50 => colorMode ? 0x0f : 0,
      0x52 => colorMode ? 0xdf : 0, // sound DMA control
      0x60 => 0xea, // color, 4bpp, packed, waits
      >= 0x80 && <= 0x87 => port.isEven ? 0xff : 0x07, // 11-bit frequencies
      >= 0x88 && <= 0x8d => 0xff, // volumes and sweep
      0x8e => 0x17, // noise tap and enable; the reset bit is not kept
      0x8f => 0xff, // wave table base
      0x90 => 0xef, // channel enables and modes
      0x94 => 0x0f, // voice volume
      0xa2 => 0x0f, // timer control
      >= 0xa4 && <= 0xa7 => 0xff, // timer reload values
      0xb0 => 0xf8, // interrupt vector base
      0xb2 => 0xff, // interrupt enable
      0xb5 => 0x70, // key group select
      0xb7 => 0x10, // NMI on low battery
      _ => null,
    };

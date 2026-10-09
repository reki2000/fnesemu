/// PCE timing constants shared by the core and its components.
const systemClockHz = 21477270; // 21.47727 MHz
const scanlinesInFrame = 263;
const clocksInScanline = systemClockHz ~/ 59.97 ~/ scanlinesInFrame;

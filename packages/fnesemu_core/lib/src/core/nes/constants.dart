/// NES timing and video constants shared by the core and its components.
const cpuClock = 1789773;
const apuClock = cpuClock ~/ 2;
const scanlinesInFrame = 262;
const cpuCyclesInScanline = cpuClock / 59.97 ~/ scanlinesInFrame;
const imageWidth = 256;
const imageHeight = 240;

import 'dart:collection';
import 'dart:io';

import 'package:fnesemu/util/int.dart';

import 'r3000.dart';

class Case {
  final String name;
  final int opcode;
  final List<int> data;
  final List<int> result;

  Case(this.name, this.opcode, this.data, this.result);
}

List<int> parseData(Queue<String> lines) {
  List<int> input = List.filled(64, 0);

  int idx = 0;
  while (true) {
    final line = lines.removeFirst().trim();
    if (line.startsWith("}")) break;

    if (line.isEmpty || !line.contains("0x")) continue;

    for (final numStr in line.split(",")) {
      if (numStr.trim().isEmpty || !numStr.startsWith("0x")) continue;
      if (idx < 64) {
        input[idx++] = int.parse(numStr.substring(2).trim(), radix: 16);
      }
    }
  }

  return input;
}

List<Case> loadTests(String path) {
  final Queue<String> lines = Queue.from(File(path).readAsLinesSync());
  final tests = <Case>[];

  while (!lines
      .removeFirst()
      .trim()
      .startsWith("const struct test_t tests[] =")) {}

  while (true) {
    final line = lines.removeFirst().trim();
    if (line.startsWith("};")) break; // End of test array

    if (!line.startsWith("{")) continue;

    String name = "";
    int opcode = 0;
    List<int> input = [];
    List<int> output = [];

    // Parse test case fields
    while (true) {
      final line = lines.removeFirst().trim();
      if (line.startsWith("}")) break; // End of current test case

      if (line.startsWith(".name")) {
        name = line.split("\"")[1]; // Extract between quotes
      } else if (line.startsWith(".opcode")) {
        opcode = int.parse(
            line.split("=")[1].trim().split(",")[0].trim().substring(2),
            radix: 16);
      } else if (line.startsWith(".input")) {
        input = parseData(lines);
      } else if (line.startsWith(".output")) {
        output = parseData(lines);
      }
    }

    tests.add(Case(name, opcode, input, output));
  }

  return tests;
}

class _DummyBus implements BusR3000 {
  @override
  int read32(int addr) => 0;

  @override
  void write32(int addr, int value) {}

  @override
  int read16(int addr) => 0;

  @override
  int read8(int addr) => 0;

  @override
  void write16(int addr, int value) {}

  @override
  void write8(int addr, int value) {}
}

final Map<int, String> flagBits = {
  31: 'Logical sum of bits 30 - 23 and bits 18 - 13',
  30: 'Calculation test result #1 overflow generated (2^43 or more)',
  29: 'Calculation test result #2 overflow generated (2^43 or more)',
  28: 'Calculation test result #3 overflow generated (2^43 or more)',
  27: 'Calculation test result #1 underflow generated (less than -2^43)',
  26: 'Calculation test result #2 underflow generated (less than -2^43)',
  25: 'Calculation test result #3 underflow generated (less than -2^43)',
  24: 'Limiter A1 out of range detected (less than 0 or less than -2^15, or 2^15 or more)',
  23: 'Limiter A2 out of range detected (less than 0 or less than -2^15, or 2^15 or more)',
  22: 'Limiter A3 out of range detected (less than -0 or less than -2^15, or 2^15 or more)',
  21: 'Limiter B1 out of range detected (less than 0, or 2^8 or more)',
  20: 'Limiter B2 out of range detected (less than 0, or 2^8 or more)',
  19: 'Limiter B3 out of range detected (less than 0, or 2^8 or more)',
  18: 'Limiter C out of range detected (less than 0, or 2^16 or more)',
  17: 'Divide overflow generated (quotient of 2.0 or more)',
  16: 'Calculation test result #4 overflow generated (2^31 or more)',
  15: 'Calculation test result #4 underflow generated (less than -2^31)',
  14: 'Limiter D1 out of range detected (less than -2^10, or 2^10 or more)',
  13: 'Limiter D2 out of range detected (less than -2^10, or 2^10 or more)',
  12: 'Limiter E out of range detected (less than 0, or 2^12 or more)',
};

final Map<int, String> regNames = {
  // Data Registers (0-31)
  0: 'VXY0', // Vector #0 (X/Y)
  1: 'VZ0', // Vector #0 (Z)
  2: 'VXY1', // Vector #1 (X/Y)
  3: 'VZ1', // Vector #1 (Z)
  4: 'VXY2', // Vector #2 (X/Y)
  5: 'VZ2', // Vector #2 (Z)
  6: 'RGB', // Color data + GTE instruction
  7: 'OTZ', // Z-component average value
  8: 'IR0', // Intermediate value #0
  9: 'IR1', // Intermediate value #1
  10: 'IR2', // Intermediate value #2
  11: 'IR3', // Intermediate value #3
  12: 'SXY0', // Calculation result record (XY)
  13: 'SXY1', // Calculation result record (XY)
  14: 'SXY2', // Calculation result record (XY)
  15: 'SXYP', // Calculation result setting register
  16: 'SZ0', // Calculation result record (Z)
  17: 'SZ1', // Calculation result record (Z)
  18: 'SZ2', // Calculation result record (Z)
  19: 'SZ3', // Calculation result record (Z)
  20: 'RGB0', // Calculation result record (color data)
  21: 'RGB1', // Calculation result record (color data)
  22: 'RGB2', // Calculation result record (color data)
  23: 'RES1', // Reserved by system (access prohibited)
  24: 'MAC0', // Sum of products #0
  25: 'MAC1', // Sum of products #1
  26: 'MAC2', // Sum of products #2
  27: 'MAC3', // Sum of products #3
  28: 'IRGB', // Color data input register
  29: 'ORGB', // Color data output register
  30: 'LZCS', // Leading zero/one count source data
  31: 'LZCR', // Leading zero/one count processing result

  // Control Registers (32-63)
  32: 'R11R12', // Rotation matrix
  33: 'R13R21', // Rotation matrix
  34: 'R22R23', // Rotation matrix
  35: 'R31R32', // Rotation matrix
  36: 'R33', // Rotation matrix
  37: 'TRX', // Translation vector (X)
  38: 'TRY', // Translation vector (Y)
  39: 'TRZ', // Translation vector (Z)
  40: 'L11L12', // Light source direction vector X 3
  41: 'L13L21', // Light source direction vector X 3
  42: 'L22L23', // Light source direction vector X 3
  43: 'L31L32', // Light source direction vector X 3
  44: 'L33', // Light source direction vector X 3
  45: 'RBK', // Peripheral color (background color) (R)
  46: 'GBK', // Peripheral color (background color) (G)
  47: 'BBK', // Peripheral color (background color) (B)
  48: 'LR1LR2', // Light source color X 3
  49: 'LR3LG1', // Light source color X 3
  50: 'LG2LG3', // Light source color X 3
  51: 'LB1LB2', // Light source color X 3
  52: 'LB3', // Light source color X 3
  53: 'RFC', // Far color (R)
  54: 'GFC', // Far color (G)
  55: 'BFC', // Far color (B)
  56: 'OFX', // Screen offset (X)
  57: 'OFY', // Screen offset (Y)
  58: 'H', // Screen position
  59: 'DQA', // Depth parameter A (coefficient)
  60: 'DQB', // Depth parameter B (offset)
  61: 'ZSF3', // Z-averaging scale factor
  62: 'ZSF4', // Z-averaging scale factor
  63: 'FLAG', // Flag
};

main(List<String> args) {
  final bus = _DummyBus();
  final cpu = R3000(bus);
  Cop2 cop2 = Cop2(cpu);

  final tests = loadTests(args[0]);

  print("Loaded ${tests.length} tests");

  for (var test in tests) {
    print("Test 0x${test.opcode} ${test.name}");

    for (int i = 0; i < 64; i++) {
      i > 31
          ? cop2.writeCtrl(i - 32, test.data[i])
          : cop2.writeReg(i, test.data[i]);
    }

    if (test.opcode != 0xffffffff) {
      cop2.execCmd(test.opcode);
    }

    bool pass = true;
    for (int i = 0; i < 64; i++) {
      final result = i > 31 ? cop2.readCtrl(i - 32) : cop2.readReg(i);
      if (result == test.result[i]) {
        continue;
      }

      pass = false;
      print(
          "Reg $i ${regNames[i]} Expected: ${test.result[i].hex32} Got: ${result.hex32}");

      if (i != 63) {
        continue;
      }

      for (var bit = 0; bit < 32; bit++) {
        if (result.bit(bit) != test.result[i].bit(bit)) {
          print(
              "Bit $bit: ${test.result[i].bit(bit) ? "must" : "must not"} be set - ${flagBits[bit]}");
        }
      }
    }

    if (!pass) {
      print("Test failed!");
      return;
    }
  }

  print("All tests completed.");
}

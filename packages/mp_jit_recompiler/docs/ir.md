# IR semantics

This document defines the value model that every executor implements: the reference executor, x86-64, ARM64 and Wasm. A frontend emits one lowering that relies on these rules.

## Value widths and byte order

The reference executor uses `BigInt` for exact i64 semantics on every Dart compiler. x86-64, ARM64 and Wasm use native 64-bit integer operations. Wasm i64 values stay inside generated code and linear memory, so no 64-bit value crosses the JavaScript boundary.

- Arithmetic wraps at its declared width. Comparisons return i32. Shift counts, conditions, guest addresses, block PCs and tags remain i32 independently of register width.
- Integer `divS`, `divU`, `remS` and `remU` use truncating quotient and dividend-signed remainder at i32/i64 width. The divisor-zero result is zero for both quotient and remainder; signed MIN / -1 wraps to MIN with remainder zero. Frontends needing different guest-specific zero-divisor behavior select their own special result (for example PS1 HI/LO). Native x64 and Wasm lowerings guard all hardware-trapping cases.
- `sext32`, `zext32` and `trunc32` make word-to-register conversions explicit. For example, an N64 word result can use `b.sext32(b.add(b.trunc32(register), b.c32(1)))` before storing to an i64 register.
- Context indices count 32-bit words. An i64 load or store occupies two consecutive words, low word first, independently of guest memory byte order. Runtime installation checks the whole access against the context size.
- `c64(BigInt)` and `c64Parts(low, high)` preserve exact constants without converting a 64-bit value through a JavaScript number.
- Memory accesses specify `IrEndian.little` or `IrEndian.big` and may transfer up to the value width, including 8 bytes for i64. The default is i32 little-endian. A sign-extended big-endian word load is `b.load(4, address, type: IrType.i64, signed: true, endian: IrEndian.big)`. Frontends handle guest alignment faults and split accesses that cross page mappings.
- Instruction guards take an explicit byte order through `b.guard(address, instruction, endian: IrEndian.big)`, so translators can compare decoded 32-bit instructions with big-endian code bytes.
- Helpers use a three-i32-argument, i32-result ABI. The verifier rejects i64 helper arguments.

## Floating-point bit patterns

`floatAdd`, `floatSub` and `floatMul` interpret i32 values as binary32 and i64 values as binary64, evaluate in binary64, then round to the result width. `floatConvert` widens binary32 to binary64 exactly or narrows to nearest even. `floatToInt` converts either width to a signed word to nearest even or toward zero.

- Nonfinite and out-of-range conversions and NaN payloads are unspecified by this contract, so frontends exit before them. The N64 frontend exits before nonfinite operands to preserve CPU behavior.
- Native backends rely on the host default rounding mode (x64 MXCSR, ARM64 FPCR). The operations preserve the N64 interpreter arithmetic model and do not implement guest exception flags or other rounding modes.
- Values remain ordinary SSA bit patterns. Guest FPRs are not allocated to host floating-point registers across blocks.

## Optimizer

Compiled backends run `optimizeIrBlock` before emission. It folds i32 constants (including safe division), algebraic identities and discards unused pure values. Loads, calls, guards, side-exit snapshots and guest clock costs remain intact. Mixed-width blocks keep their i64 operations while the safe i32 simplifications and dead-value removal still apply. The native and Wasm backends fuse a comparison into a branch or conditional exit when the comparison has exactly one consumer, preserving operands through intervening operations.

A block has at most 4,096 values on the x86-64 and ARM64 backends; a longer block is rejected.

## Not yet in the IR

A typed 64-bit helper ABI, additional floating-point operations and TLB-aware fast paths are future work; see the [roadmap](roadmap.md).

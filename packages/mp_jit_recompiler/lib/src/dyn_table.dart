/// The direct-mapped dynamic jump table shared by every backend: a block's entry sits at the index [index] computes, and the generated code of the x64, ARM64 and Wasm backends all reproduces that index from these same constants.
abstract final class DynTable {
  static const entries = 4096;

  /// Guest pcs are word aligned, so the index drops their low [pcShift] bits.
  static const pcShift = 2;

  /// The size of a native table entry in bits: 16 bytes holding the packed pc and tag in one word and the entry in the next; the Wasm table's entries are 12 bytes, so its generated code scales the index by 12 instead.
  static const entryBits = 4;

  /// the dynamic table index of (pc, tag), as computed by the generated code
  static int index(int pc, int tag) => ((pc >>> pcShift) ^ tag) & (entries - 1);
}

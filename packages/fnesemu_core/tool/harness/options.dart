/// an error in the command line; the harness prints it with the usage
class UsageError implements Exception {
  final String message;
  UsageError(this.message);

  @override
  String toString() => message;
}

/// the command line of a subcommand: positional arguments, options with a
/// value and flags
class Options {
  final positional = <String>[];
  final _values = <String, String>{};
  final _flags = <String>{};

  /// [valued] and [flags] are long names; [aliases] maps short names to them
  Options.parse(List<String> args,
      {Set<String> valued = const {},
      Set<String> flags = const {},
      Map<String, String> aliases = const {}}) {
    for (var i = 0; i < args.length; i++) {
      final a = aliases[args[i]] ?? args[i];
      if (valued.contains(a)) {
        if (i + 1 >= args.length) throw UsageError("$a needs a value");
        if (_values.containsKey(a)) throw UsageError("$a is given twice");
        _values[a] = args[++i];
      } else if (flags.contains(a)) {
        _flags.add(a);
      } else if (a.startsWith("-") && a.length > 1) {
        throw UsageError("unknown option: ${args[i]}");
      } else {
        positional.add(a);
      }
    }
  }

  String? operator [](String name) => _values[name];

  bool flag(String name) => _flags.contains(name);

  int integer(String name, int fallback) {
    final v = _values[name];
    if (v == null) return fallback;
    return int.tryParse(v) ?? (throw UsageError("$name takes a number: $v"));
  }
}

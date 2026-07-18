import 'dart:math';

/// Generates collision-resistant local identifiers without a dependency.
class IdGenerator {
  IdGenerator._();

  static final Random _random = Random.secure();

  /// Creates a time-prefixed hexadecimal identifier.
  static String create(String prefix) {
    final time = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final random = List<int>.generate(12, (_) => _random.nextInt(256))
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${prefix}_$time$random';
  }
}

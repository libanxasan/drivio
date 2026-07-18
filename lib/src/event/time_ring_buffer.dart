import 'dart:collection';

/// Time-bounded ring buffer.
class TimeRingBuffer<T> {
  /// Creates a ring buffer.
  TimeRingBuffer({
    required this.capacity,
    required this.timestampMillis,
  });

  /// Maximum represented duration.
  final Duration capacity;

  /// Timestamp extractor.
  final int Function(T value) timestampMillis;

  final Queue<T> _values = Queue<T>();

  /// Number of retained values.
  int get length => _values.length;

  /// Adds a value and evicts expired entries.
  void add(T value) {
    _values.addLast(value);
    final cutoff = timestampMillis(value) - capacity.inMilliseconds;
    while (_values.isNotEmpty && timestampMillis(_values.first) < cutoff) {
      _values.removeFirst();
    }
  }

  /// Returns values at or after the supplied timestamp.
  List<T> since(int minimumTimestampMillis) {
    return _values
        .where((value) => timestampMillis(value) >= minimumTimestampMillis)
        .toList(growable: false);
  }

  /// Clears all values.
  void clear() => _values.clear();
}

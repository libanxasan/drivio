import 'dart:math' as math;

import '../model/axis_statistics.dart';

/// Numerically stable online statistics accumulator.
class OnlineStatistics {
  int _count = 0;
  double _minimum = double.infinity;
  double _maximum = double.negativeInfinity;
  double _mean = 0;
  double _m2 = 0;
  double _sumSquares = 0;

  /// Number of values added.
  int get count => _count;

  /// Adds one value.
  void add(double value) {
    _count++;
    _minimum = math.min(_minimum, value);
    _maximum = math.max(_maximum, value);

    final delta = value - _mean;
    _mean += delta / _count;
    final delta2 = value - _mean;
    _m2 += delta * delta2;
    _sumSquares += value * value;
  }

  /// Merges already-condensed population statistics exactly.
  void addStatistics(AxisStatistics statistics) {
    final incomingCount = statistics.sampleCount;
    if (incomingCount <= 0) return;

    if (_count == 0) {
      _count = incomingCount;
      _minimum = statistics.minimum;
      _maximum = statistics.maximum;
      _mean = statistics.mean;
      _m2 = statistics.standardDeviation *
          statistics.standardDeviation *
          incomingCount;
      _sumSquares = statistics.rms * statistics.rms * incomingCount;
      return;
    }

    final previousCount = _count;
    final combinedCount = previousCount + incomingCount;
    final delta = statistics.mean - _mean;

    _minimum = math.min(_minimum, statistics.minimum);
    _maximum = math.max(_maximum, statistics.maximum);
    _mean += delta * incomingCount / combinedCount;
    _m2 += statistics.standardDeviation *
            statistics.standardDeviation *
            incomingCount +
        delta * delta * previousCount * incomingCount / combinedCount;
    _sumSquares += statistics.rms * statistics.rms * incomingCount;
    _count = combinedCount;
  }

  /// Produces immutable statistics.
  AxisStatistics snapshot() {
    if (_count == 0) return AxisStatistics.empty;
    final variance = _m2 / _count;
    return AxisStatistics(
      minimum: _minimum,
      maximum: _maximum,
      mean: _mean,
      standardDeviation: math.sqrt(math.max(0, variance)),
      rms: math.sqrt(_sumSquares / _count),
      sampleCount: _count,
    );
  }

  /// Clears the accumulator.
  void reset() {
    _count = 0;
    _minimum = double.infinity;
    _maximum = double.negativeInfinity;
    _mean = 0;
    _m2 = 0;
    _sumSquares = 0;
  }
}

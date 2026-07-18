/// Statistical condensation of one sensor axis over a time window.
class AxisStatistics {
  /// Creates axis statistics.
  const AxisStatistics({
    required this.minimum,
    required this.maximum,
    required this.mean,
    required this.standardDeviation,
    required this.rms,
    required this.sampleCount,
  });

  /// Minimum signed value.
  final double minimum;

  /// Maximum signed value.
  final double maximum;

  /// Arithmetic mean.
  final double mean;

  /// Population standard deviation.
  final double standardDeviation;

  /// Root mean square.
  final double rms;

  /// Number of source samples.
  final int sampleCount;

  /// Empty statistics.
  static const empty = AxisStatistics(
    minimum: 0,
    maximum: 0,
    mean: 0,
    standardDeviation: 0,
    rms: 0,
    sampleCount: 0,
  );

  /// JSON representation.
  Map<String, Object> toJson() => <String, Object>{
        'minimum': minimum,
        'maximum': maximum,
        'mean': mean,
        'standardDeviation': standardDeviation,
        'rms': rms,
        'sampleCount': sampleCount,
      };
}

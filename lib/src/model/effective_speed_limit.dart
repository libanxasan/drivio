/// Source used to determine an effective legal speed limit.
enum SpeedLimitSource {
  backendOverride,
  openStreetMap,
  statutoryDefault,
  roadClassDefault,
  unavailable,
}

/// Direction relative to an OpenStreetMap way.
enum TravelDirection { forward, backward, unknown }

/// Resolved speed limit and provenance.
class EffectiveSpeedLimit {
  /// Creates a speed limit result.
  const EffectiveSpeedLimit({
    required this.speedKph,
    required this.source,
    required this.confidence,
    this.osmWayId,
    this.backendRuleId,
    this.isConditional = false,
  });

  /// Legal limit in kilometers per hour, or null when unknown.
  final double? speedKph;

  /// Limit source.
  final SpeedLimitSource source;

  /// Source confidence from 0 to 1.
  final double confidence;

  /// OpenStreetMap way identifier.
  final int? osmWayId;

  /// Backend override rule identifier.
  final String? backendRuleId;

  /// Whether a conditional OSM rule was applied.
  final bool isConditional;

  /// Whether a numeric limit is available.
  bool get isAvailable => speedKph != null;

  /// Unknown limit.
  static const unavailable = EffectiveSpeedLimit(
    speedKph: null,
    source: SpeedLimitSource.unavailable,
    confidence: 0,
  );
}

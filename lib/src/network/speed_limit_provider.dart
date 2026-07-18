import '../model/effective_speed_limit.dart';

/// Road tags and identifiers used to resolve an effective speed limit.
class SpeedLimitRequest {
  /// Creates a request.
  const SpeedLimitRequest({
    required this.timestamp,
    required this.direction,
    required this.osmTags,
    this.osmWayId,
    this.latitude,
    this.longitude,
  });

  /// Time at which the limit is needed.
  final DateTime timestamp;

  /// Direction relative to the OSM way.
  final TravelDirection direction;

  /// OpenStreetMap tags for the matched way.
  final Map<String, String> osmTags;

  /// OpenStreetMap way identifier.
  final int? osmWayId;

  /// Optional latitude.
  final double? latitude;

  /// Optional longitude.
  final double? longitude;
}

/// Resolves a numeric legal speed limit.
abstract interface class SpeedLimitProvider {
  /// Returns a limit or null when the provider has no applicable value.
  Future<EffectiveSpeedLimit?> findSpeedLimit(SpeedLimitRequest request);
}

/// Parses OpenStreetMap maxspeed tags.
class OpenStreetMapSpeedLimitProvider implements SpeedLimitProvider {
  /// Creates a parser-backed provider.
  const OpenStreetMapSpeedLimitProvider();

  @override
  Future<EffectiveSpeedLimit?> findSpeedLimit(
    SpeedLimitRequest request,
  ) async {
    final tags = request.osmTags;
    final directional = switch (request.direction) {
      TravelDirection.forward => tags['maxspeed:forward'],
      TravelDirection.backward => tags['maxspeed:backward'],
      TravelDirection.unknown => null,
    };
    final raw = directional ?? tags['maxspeed'];
    final parsed = parseSpeedKph(raw);
    if (parsed == null) return null;
    return EffectiveSpeedLimit(
      speedKph: parsed,
      source: SpeedLimitSource.openStreetMap,
      confidence: directional != null ? 0.9 : 0.85,
      osmWayId: request.osmWayId,
    );
  }

  /// Converts a common OSM maxspeed value to kilometers per hour.
  double? parseSpeedKph(String? raw) {
    if (raw == null) return null;
    final normalized = raw.trim().toLowerCase();
    final direct = double.tryParse(normalized);
    if (direct != null && direct > 0) return direct;

    final match = RegExp(r'^([0-9]+(?:\.[0-9]+)?)\s*(km/h|kmh|kph|mph)$')
        .firstMatch(normalized);
    if (match == null) return null;
    final value = double.parse(match.group(1)!);
    return match.group(2) == 'mph' ? value * 1.609344 : value;
  }
}

/// Applies backend precedence before OpenStreetMap fallback.
class CompositeSpeedLimitProvider implements SpeedLimitProvider {
  /// Creates a composite provider.
  const CompositeSpeedLimitProvider({
    required this.backend,
    this.openStreetMap = const OpenStreetMapSpeedLimitProvider(),
    this.fallback,
  });

  /// Authoritative backend provider.
  final SpeedLimitProvider backend;

  /// OpenStreetMap fallback provider.
  final SpeedLimitProvider openStreetMap;

  /// Optional statutory or road-class fallback.
  final SpeedLimitProvider? fallback;

  @override
  Future<EffectiveSpeedLimit?> findSpeedLimit(
    SpeedLimitRequest request,
  ) async {
    return await backend.findSpeedLimit(request) ??
        await openStreetMap.findSpeedLimit(request) ??
        await fallback?.findSpeedLimit(request);
  }
}

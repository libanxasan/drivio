import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/osrm_configuration.dart';
import '../model/location_sample.dart';
import '../model/osrm_match_result.dart';

/// OSRM Match API client.
class OsrmClient {
  /// Creates an OSRM client.
  OsrmClient({
    this.configuration = const OsrmConfiguration(),
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// OSRM settings.
  final OsrmConfiguration configuration;

  final http.Client _client;

  /// Matches a complete trace, splitting it into overlapping requests when needed.
  Future<OsrmMatchResult> matchTrace(List<LocationSample> samples) async {
    if (samples.length < 2) {
      throw ArgumentError('At least two location samples are required.');
    }

    final valid = samples.where((sample) {
      return !sample.isMocked &&
          sample.accuracyMeters.isFinite &&
          sample.latitude.isFinite &&
          sample.longitude.isFinite;
    }).toList(growable: false);

    if (valid.length < 2) {
      throw ArgumentError('At least two valid location samples are required.');
    }

    final batches = <List<LocationSample>>[];
    final maximum = configuration.maximumPointsPerRequest;
    var start = 0;
    while (start < valid.length - 1) {
      final end = (start + maximum).clamp(0, valid.length).toInt();
      batches.add(valid.sublist(start, end));
      if (end == valid.length) break;
      start = end - 1;
    }

    final subMatches = <OsrmSubMatch>[];
    var matchedTracepoints = 0;
    for (final batch in batches) {
      final result = await _matchBatch(batch);
      subMatches.addAll(result.subMatches);
      matchedTracepoints += result.matchedTracepointCount;
    }

    return OsrmMatchResult(
      subMatches: subMatches,
      tracepointCount: valid.length,
      matchedTracepointCount: matchedTracepoints.clamp(0, valid.length).toInt(),
    );
  }

  Future<OsrmMatchResult> _matchBatch(List<LocationSample> samples) async {
    final coordinates = samples
        .map((sample) => '${sample.longitude},${sample.latitude}')
        .join(';');
    final timestamps = samples
        .map((sample) => '${sample.timestampMillis ~/ 1000}')
        .join(';');
    final radiuses = samples
        .map((sample) => '${sample.accuracyMeters.clamp(5, 100).round()}')
        .join(';');

    final uri = Uri.parse(
      '${configuration.baseUrl}/match/v1/'
      '${configuration.profile}/$coordinates',
    ).replace(
      queryParameters: <String, String>{
        'geometries': 'geojson',
        'overview': 'full',
        'steps': 'true',
        'annotations': 'false',
        'timestamps': timestamps,
        'radiuses': radiuses,
      },
    );

    final response = await _client.get(uri).timeout(configuration.requestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw OsrmException(
        'OSRM Match failed with HTTP ${response.statusCode}: ${response.body}',
      );
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    if (json['code'] != 'Ok') {
      throw OsrmException('OSRM Match failed: ${json['code']}');
    }

    final matchings = (json['matchings'] as List<dynamic>? ?? const <dynamic>[])
        .cast<Map<String, dynamic>>();
    final subMatches = matchings.map(_parseMatching).toList(growable: false);
    final tracepoints = json['tracepoints'] as List<dynamic>? ?? const <dynamic>[];
    final matchedCount = tracepoints.where((value) => value != null).length;

    return OsrmMatchResult(
      subMatches: subMatches,
      tracepointCount: samples.length,
      matchedTracepointCount: matchedCount,
    );
  }

  OsrmSubMatch _parseMatching(Map<String, dynamic> json) {
    final geometry = json['geometry'] as Map<String, dynamic>?;
    final coordinates = (geometry?['coordinates'] as List<dynamic>? ??
            const <dynamic>[])
        .cast<List<dynamic>>()
        .map(
          (coordinate) => RouteCoordinate(
            (coordinate[0] as num).toDouble(),
            (coordinate[1] as num).toDouble(),
          ),
        )
        .toList(growable: false);

    final roadNames = <String>{};
    final legs = (json['legs'] as List<dynamic>? ?? const <dynamic>[])
        .cast<Map<String, dynamic>>();
    for (final leg in legs) {
      final steps = (leg['steps'] as List<dynamic>? ?? const <dynamic>[])
          .cast<Map<String, dynamic>>();
      for (final step in steps) {
        final name = step['name']?.toString().trim();
        if (name != null && name.isNotEmpty) roadNames.add(name);
      }
    }

    return OsrmSubMatch(
      distanceMeters: (json['distance'] as num?)?.toDouble() ?? 0,
      durationSeconds: (json['duration'] as num?)?.toDouble() ?? 0,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
      geometry: coordinates,
      roadNames: roadNames.toList(growable: false),
    );
  }

  /// Closes the HTTP client.
  void close() => _client.close();
}

/// OSRM request or response error.
class OsrmException implements Exception {
  /// Creates an exception.
  const OsrmException(this.message);

  /// Error description.
  final String message;

  @override
  String toString() => 'OsrmException: $message';
}

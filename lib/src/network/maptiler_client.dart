import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/maptiler_configuration.dart';
import '../model/street_context.dart';

/// Minimal MapTiler map and reverse-geocoding client.
class MapTilerClient {
  /// Creates a client.
  MapTilerClient({
    required this.configuration,
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client();

  /// MapTiler settings.
  final MapTilerConfiguration configuration;

  /// HTTP timeout.
  final Duration timeout;

  final http.Client _client;

  /// MapLibre-compatible style URL.
  String get styleUrl => configuration.styleUrl;

  /// Resolves a human-readable street or place near one coordinate.
  Future<StreetContext?> reverseGeocode({
    required double longitude,
    required double latitude,
  }) async {
    final response = await _client
        .get(configuration.reverseGeocodingUri(longitude, latitude))
        .timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw MapTilerException(
        'MapTiler reverse geocoding failed with HTTP '
        '${response.statusCode}: ${response.body}',
      );
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final features = (json['features'] as List<dynamic>? ?? const <dynamic>[])
        .cast<Map<String, dynamic>>();
    if (features.isEmpty) return null;
    final feature = features.first;
    final properties = (feature['properties'] as Map<String, dynamic>? ??
            const <String, dynamic>{})
        .cast<String, Object?>();
    return StreetContext(
      featureId: feature['id']?.toString(),
      name: feature['text']?.toString() ??
          feature['name']?.toString() ??
          properties['name']?.toString(),
      placeName: feature['place_name']?.toString() ??
          feature['full_address']?.toString() ??
          properties['place_name']?.toString(),
      roadClass: properties['class']?.toString() ??
          properties['road_class']?.toString(),
      properties: properties,
    );
  }

  /// Closes the HTTP client.
  void close() => _client.close();
}

/// MapTiler request or response error.
class MapTilerException implements Exception {
  /// Creates an exception.
  const MapTilerException(this.message);

  /// Error description.
  final String message;

  @override
  String toString() => 'MapTilerException: $message';
}

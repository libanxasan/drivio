/// MapTiler map and geocoding configuration.
class MapTilerConfiguration {
  /// Creates MapTiler settings.
  const MapTilerConfiguration({
    required this.apiKey,
    this.styleId = 'streets-v2',
    this.language,
  });

  /// MapTiler API key supplied by the host application.
  final String apiKey;

  /// Map style identifier.
  final String styleId;

  /// Optional language code.
  final String? language;

  /// Style URL for MapLibre-compatible map widgets.
  String get styleUrl =>
      'https://api.maptiler.com/maps/$styleId/style.json?key=$apiKey';

  /// Reverse-geocoding URL for one coordinate.
  Uri reverseGeocodingUri(double longitude, double latitude) {
    return Uri.parse(
      'https://api.maptiler.com/geocoding/'
      '$longitude,$latitude.json',
    ).replace(
      queryParameters: <String, String>{
        'key': apiKey,
        if (language != null) 'language': language!,
      },
    );
  }
}

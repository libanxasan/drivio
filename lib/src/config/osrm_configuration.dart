/// OSRM Match API configuration.
class OsrmConfiguration {
  /// Creates OSRM settings.
  const OsrmConfiguration({
    this.baseUrl = 'https://router.project-osrm.org',
    this.profile = 'driving',
    this.maximumPointsPerRequest = 80,
    this.requestTimeout = const Duration(seconds: 30),
  })  : assert(maximumPointsPerRequest >= 2),
        assert(requestTimeout > Duration.zero);

  /// OSRM server base URL.
  final String baseUrl;

  /// OSRM routing profile.
  final String profile;

  /// Maximum points in one Match request.
  final int maximumPointsPerRequest;

  /// HTTP request timeout.
  final Duration requestTimeout;
}

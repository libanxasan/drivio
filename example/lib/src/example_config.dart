import 'package:driving_telemetry/driving_telemetry.dart';

import 'convex_session.dart';

/// Build-time settings, passed with `--dart-define`.
///
/// ```sh
/// flutter run \
///   --dart-define=DRIVIO_CONVEX_URL=https://<deployment>.convex.cloud
/// ```
///
/// With a Convex URL, the app signs in anonymously, streams the current trip
/// live (GPS samples, motion frames, events) and uploads the recorded archive
/// to the same deployment. Without one, it records locally only.
class ExampleConfig {
  /// Creates a configuration.
  const ExampleConfig({
    this.convexUrl = '',
    this.convexSiteUrl = '',
    this.matchRoutes = true,
    this.automatic = true,
  });

  /// Reads the `--dart-define` values.
  const ExampleConfig.fromEnvironment()
      : convexUrl = const String.fromEnvironment('DRIVIO_CONVEX_URL'),
        convexSiteUrl = const String.fromEnvironment('DRIVIO_CONVEX_SITE_URL'),
        matchRoutes = const bool.fromEnvironment(
          'DRIVIO_MATCH_ROUTES',
          defaultValue: true,
        ),
        automatic = const bool.fromEnvironment(
          'DRIVIO_AUTOMATIC',
          defaultValue: true,
        );

  /// Convex deployment URL (`https://<deployment>.convex.cloud`). Empty: local only.
  final String convexUrl;

  /// HTTP actions URL; derived from [convexUrl] when empty.
  final String convexSiteUrl;

  /// Whether finished trips are matched against the public OSRM server.
  final bool matchRoutes;

  /// Whether drives are recorded automatically from GPS and accelerometer.
  final bool automatic;

  /// Whether a deployment is configured.
  bool get uploadsEnabled => convexUrl.isNotEmpty;

  /// The HTTP actions origin (`https://<deployment>.convex.site`).
  String get siteUrl => convexSiteUrl.isNotEmpty
      ? convexSiteUrl
      : convexUrl.replaceFirst('.convex.cloud', '.convex.site');

  /// The anonymous session, or null when local only.
  ConvexSession? createSession() =>
      uploadsEnabled ? ConvexSession(convexUrl) : null;

  /// The archive upload client for [session].
  TelemetryBackendClient createBackend(ConvexSession session) =>
      HttpTelemetryBackendClient(
        endpoint: Uri.parse('$siteUrl/v1/telemetry/chunks'),
        authorizationTokenProvider: session.token,
      );
}

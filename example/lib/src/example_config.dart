import 'package:driving_telemetry/driving_telemetry.dart';

/// Build-time settings, passed with `--dart-define`.
///
/// ```sh
/// flutter run \
///   --dart-define=DRIVIO_UPLOAD_URL=https://example.convex.site/v1/telemetry/chunks \
///   --dart-define=DRIVIO_USER_ID=user-123 \
///   --dart-define=DRIVIO_AUTH_TOKEN=...
/// ```
///
/// The values are compile-time constants, so the background sync isolate
/// sees the same configuration as the UI. A real app should load the token
/// from its auth session instead of baking it into the build.
class ExampleConfig {
  /// Creates a configuration.
  const ExampleConfig({
    this.uploadUrl = '',
    this.userId = 'example-user',
    this.authToken = '',
    this.matchRoutes = true,
  });

  /// Reads the `--dart-define` values.
  const ExampleConfig.fromEnvironment()
      : uploadUrl = const String.fromEnvironment('DRIVIO_UPLOAD_URL'),
        userId = const String.fromEnvironment(
          'DRIVIO_USER_ID',
          defaultValue: 'example-user',
        ),
        authToken = const String.fromEnvironment('DRIVIO_AUTH_TOKEN'),
        matchRoutes = const bool.fromEnvironment(
          'DRIVIO_MATCH_ROUTES',
          defaultValue: true,
        );

  /// Chunk upload endpoint. Uploads are off when empty.
  final String uploadUrl;

  /// User identifier recorded with each trip.
  final String userId;

  /// Bearer token for the upload endpoint.
  final String authToken;

  /// Whether finished trips are matched against the public OSRM server.
  final bool matchRoutes;

  /// Whether an upload endpoint is configured.
  bool get uploadsEnabled => uploadUrl.isNotEmpty;

  /// Creates the upload client, or null when uploads are off.
  TelemetryBackendClient? createBackend() {
    if (!uploadsEnabled) return null;
    return HttpTelemetryBackendClient(
      endpoint: Uri.parse(uploadUrl),
      authorizationTokenProvider:
          authToken.isEmpty ? null : () async => authToken,
    );
  }
}

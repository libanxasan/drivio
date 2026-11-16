import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../model/location_sample.dart';
import 'location_source.dart';

/// Keeps location updates running while the app is in the background.
///
/// On Android this starts a location foreground service with a persistent
/// notification. The app manifest must declare `ACCESS_BACKGROUND_LOCATION`,
/// `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_LOCATION`. On iOS the app
/// must list `location` under `UIBackgroundModes` in `Info.plist`.
class BackgroundLocationOptions {
  /// Creates background options.
  const BackgroundLocationOptions({
    this.notificationTitle = 'Recording trip',
    this.notificationText = 'Driving telemetry is being recorded.',
    this.notificationChannelName = 'Trip recording',
    this.notificationIcon =
        const AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
    this.requireAlwaysPermission = false,
    this.showBackgroundIndicator = true,
  });

  /// Android foreground service notification title.
  final String notificationTitle;

  /// Android foreground service notification text.
  final String notificationText;

  /// Android notification channel name.
  final String notificationChannelName;

  /// Android notification icon resource.
  final AndroidResource notificationIcon;

  /// Fails [GeolocatorLocationSource.start] unless "Always" permission is
  /// granted. A trip started in the foreground keeps running in the
  /// background with "While in use" permission on both platforms, so this is
  /// only needed for trips that start in the background.
  final bool requireAlwaysPermission;

  /// Shows the iOS background location indicator while recording.
  final bool showBackgroundIndicator;
}

/// Location source backed by geolocator.
class GeolocatorLocationSource implements LocationSource {
  /// Creates a source.
  ///
  /// [locationSettings] overrides the platform settings built from
  /// [background]. Pass [background] to keep recording when the app is not
  /// visible.
  GeolocatorLocationSource({
    LocationSettings? locationSettings,
    this.requestPermission = true,
    this.background,
    TargetPlatform? platform,
  }) : locationSettings = locationSettings ??
            platformLocationSettings(
              background: background,
              platform: platform ?? defaultTargetPlatform,
            );

  /// Creates settings tuned for vehicle trips on [platform].
  ///
  /// Android receives a 1 s fused-location interval and, with [background],
  /// a foreground service with a wake lock. iOS receives the automotive
  /// activity type, never pauses updates automatically, and allows updates
  /// in the background when [background] is set.
  static LocationSettings platformLocationSettings({
    BackgroundLocationOptions? background,
    TargetPlatform platform = TargetPlatform.android,
  }) {
    const accuracy = LocationAccuracy.bestForNavigation;
    switch (platform) {
      case TargetPlatform.android:
        return AndroidSettings(
          accuracy: accuracy,
          distanceFilter: 0,
          intervalDuration: const Duration(seconds: 1),
          foregroundNotificationConfig: background == null
              ? null
              : ForegroundNotificationConfig(
                  notificationTitle: background.notificationTitle,
                  notificationText: background.notificationText,
                  notificationChannelName: background.notificationChannelName,
                  notificationIcon: background.notificationIcon,
                  enableWakeLock: true,
                  setOngoing: true,
                ),
        );
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return AppleSettings(
          accuracy: accuracy,
          distanceFilter: 0,
          activityType: ActivityType.automotiveNavigation,
          pauseLocationUpdatesAutomatically: false,
          allowBackgroundLocationUpdates: background != null,
          showBackgroundLocationIndicator:
              background?.showBackgroundIndicator ?? false,
        );
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.windows:
        return const LocationSettings(accuracy: accuracy, distanceFilter: 0);
    }
  }

  /// Settings passed directly to geolocator.
  final LocationSettings locationSettings;

  /// Whether the source requests permission during start.
  final bool requestPermission;

  /// Background recording options, or null for foreground-only recording.
  final BackgroundLocationOptions? background;

  final StreamController<LocationSample> _controller =
      StreamController<LocationSample>.broadcast();
  StreamSubscription<Position>? _subscription;
  bool _started = false;

  @override
  Stream<LocationSample> get samples => _controller.stream;

  @override
  Future<void> start() async {
    if (_started) return;
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw const LocationSourceException('Location services are disabled.');
    }

    var permission = await Geolocator.checkPermission();
    if (requestPermission && permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw LocationSourceException(
        'Location permission is not available: ${permission.name}.',
      );
    }
    if (background?.requireAlwaysPermission == true &&
        permission != LocationPermission.always) {
      if (requestPermission) permission = await Geolocator.requestPermission();
      if (permission != LocationPermission.always) {
        throw const LocationSourceException(
          'Background recording needs "Always" location permission.',
        );
      }
    }

    _subscription = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(
      (position) {
        if (_controller.isClosed) return;
        final timestamp = position.timestamp.toUtc().millisecondsSinceEpoch;
        _controller.add(
          LocationSample(
            timestampMillis: timestamp,
            latitude: position.latitude,
            longitude: position.longitude,
            speedMps: position.speed < 0 ? 0 : position.speed,
            headingDegrees: position.heading < 0 ? 0 : position.heading,
            accuracyMeters: position.accuracy,
            altitudeMeters: position.altitude,
            speedAccuracyMps: position.speedAccuracy,
            headingAccuracyDegrees: position.headingAccuracy,
            isMocked: position.isMocked,
          ),
        );
      },
      onError: (Object error, StackTrace stackTrace) {
        if (_controller.isClosed) return;
        _controller.addError(error, stackTrace);
      },
    );
    _started = true;
  }

  @override
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    await _subscription?.cancel();
    _subscription = null;
  }

  /// Releases the stream controller.
  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }
}

/// Location collection failure.
class LocationSourceException implements Exception {
  /// Creates an exception.
  const LocationSourceException(this.message);

  /// Error description.
  final String message;

  @override
  String toString() => 'LocationSourceException: $message';
}

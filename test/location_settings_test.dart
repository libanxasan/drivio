import 'package:driving_telemetry/driving_telemetry.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

void main() {
  test('Android background recording uses a foreground service', () {
    final settings = GeolocatorLocationSource.platformLocationSettings(
      background: const BackgroundLocationOptions(notificationTitle: 'Trip'),
      platform: TargetPlatform.android,
    ) as AndroidSettings;

    expect(settings.intervalDuration, const Duration(seconds: 1));
    final service = settings.foregroundNotificationConfig!;
    expect(service.notificationTitle, 'Trip');
    expect(service.enableWakeLock, isTrue);
    expect(service.setOngoing, isTrue);
  });

  test('Android foreground-only recording starts no service', () {
    final settings = GeolocatorLocationSource.platformLocationSettings(
      platform: TargetPlatform.android,
    ) as AndroidSettings;
    expect(settings.foregroundNotificationConfig, isNull);
  });

  test('iOS background recording never pauses automatically', () {
    final settings = GeolocatorLocationSource.platformLocationSettings(
      background: const BackgroundLocationOptions(),
      platform: TargetPlatform.iOS,
    ) as AppleSettings;

    expect(settings.allowBackgroundLocationUpdates, isTrue);
    expect(settings.pauseLocationUpdatesAutomatically, isFalse);
    expect(settings.showBackgroundLocationIndicator, isTrue);
    expect(settings.activityType, ActivityType.automotiveNavigation);
  });

  test('iOS foreground-only recording disallows background updates', () {
    final settings = GeolocatorLocationSource.platformLocationSettings(
      platform: TargetPlatform.iOS,
    ) as AppleSettings;
    expect(settings.allowBackgroundLocationUpdates, isFalse);
  });
}

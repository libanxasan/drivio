import 'package:driving_telemetry/driving_telemetry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const provider = OpenStreetMapSpeedLimitProvider();

  test('parses metric speed', () {
    expect(provider.parseSpeedKph('60'), 60);
    expect(provider.parseSpeedKph('80 km/h'), 80);
  });

  test('converts mph', () {
    expect(provider.parseSpeedKph('50 mph'), closeTo(80.4672, 0.0001));
  });

  test('directional value supersedes general value', () async {
    final result = await provider.findSpeedLimit(
      SpeedLimitRequest(
        timestamp: DateTime.utc(2026, 7, 16),
        direction: TravelDirection.forward,
        osmTags: const <String, String>{
          'maxspeed': '50',
          'maxspeed:forward': '70',
        },
        osmWayId: 123,
      ),
    );

    expect(result?.speedKph, 70);
    expect(result?.source, SpeedLimitSource.openStreetMap);
  });
}

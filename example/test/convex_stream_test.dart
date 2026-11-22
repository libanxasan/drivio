import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:driving_telemetry/driving_telemetry.dart';
import 'package:driving_telemetry_example/src/convex_session.dart';
import 'package:driving_telemetry_example/src/live_stream.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

String jwt(String userId) {
  String part(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final exp =
      DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
          1000;
  return '${part({'alg': 'RS256'})}.${part({
        'sub': '$userId|session-1',
        'iat': exp - 3600,
        'exp': exp
      })}.sig';
}

http.Response ok(Object? value) =>
    http.Response(jsonEncode({'status': 'success', 'value': value}), 200);

class _Location implements LocationSource {
  final controller = StreamController<LocationSample>.broadcast();
  @override
  Stream<LocationSample> get samples => controller.stream;
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
}

class _Motion implements MotionSource {
  final controller = StreamController<RawMotionSample>.broadcast();
  @override
  Stream<RawMotionSample> get samples => controller.stream;
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
}

void main() {
  late Directory temporary;
  setUp(() async =>
      temporary = await Directory.systemTemp.createTemp('convex_example_'));
  tearDown(() => temporary.delete(recursive: true));

  test('signs in anonymously once and keeps the session', () async {
    final calls = <Map<String, dynamic>>[];
    final client = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      calls.add(body);
      expect(request.url.toString(), 'https://deployment.test/api/action');
      return ok({
        'tokens': {'token': jwt('user-a'), 'refreshToken': 'refresh-1'}
      });
    });
    final file = File('${temporary.path}/session.json');
    final session = ConvexSession('https://deployment.test',
        client: client, file: () async => file);
    expect(await session.ensureSignedIn(), 'user-a');
    expect(calls.single['args'], {'provider': 'anonymous'});
    expect(await session.token(), jwt('user-a'));

    final again = ConvexSession('https://deployment.test',
        client: client, file: () async => file);
    expect(await again.ensureSignedIn(), 'user-a');
    expect(calls, hasLength(1), reason: 'the stored session is reused');
  });

  test('streams the current trip in batches and closes the stream at the end',
      () async {
    final published = <Map<String, dynamic>>[];
    final client = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (body['path'] == 'auth:signIn') {
        return ok({
          'tokens': {'token': jwt('user-a'), 'refreshToken': 'refresh-1'}
        });
      }
      published.add(body);
      return ok(body['path'] == 'streams:publish' ? {'inserted': 1} : null);
    });
    final session = ConvexSession('https://deployment.test',
        client: client,
        file: () async => File('${temporary.path}/session.json'));
    await session.ensureSignedIn();
    final location = _Location();
    final recorder = DrivingTelemetryRecorder(
      store: FileTelemetryStore(rootDirectory: temporary),
      locationSource: location,
      motionSource: _Motion(),
    );
    final stream = LiveStreamPublisher(
        recorder: recorder,
        session: session,
        flushInterval: const Duration(hours: 1));
    stream.start();
    final tripId = await recorder.startTrip(userId: 'user-a');
    await pumpEventQueue();
    for (var i = 0; i < 3; i++) {
      location.controller.add(LocationSample(
        timestampMillis: DateTime.now().millisecondsSinceEpoch + i * 1000,
        latitude: 11.57,
        longitude: 43.14,
        speedMps: 10,
        headingDegrees: 90,
        accuracyMeters: 5,
      ));
    }
    await pumpEventQueue();
    await stream.flush();
    final publish =
        published.singleWhere((call) => call['path'] == 'streams:publish');
    expect(publish['args']['streamId'], tripId);
    expect(publish['args']['kinds'], ['points', 'frames', 'events']);
    expect((publish['args']['points'] as List), hasLength(3));
    expect(stream.sent, 3);

    await recorder.stopTrip();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(published.last['path'], 'streams:close');
    expect(published.last['args'], {'streamId': tripId});
    await stream.stop();
    await recorder.dispose();
  });

  test('keeps a bounded backlog while offline', () async {
    var online = false;
    final client = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (body['path'] == 'auth:signIn') {
        return ok({
          'tokens': {'token': jwt('user-a'), 'refreshToken': 'refresh-1'}
        });
      }
      if (!online) throw const SocketException('offline');
      return ok({'inserted': (body['args']['points'] as List).length});
    });
    final session = ConvexSession('https://deployment.test',
        client: client,
        file: () async => File('${temporary.path}/session.json'));
    await session.ensureSignedIn();
    final location = _Location();
    final recorder = DrivingTelemetryRecorder(
      store: FileTelemetryStore(rootDirectory: temporary),
      locationSource: location,
      motionSource: _Motion(),
    );
    final stream = LiveStreamPublisher(
        recorder: recorder,
        session: session,
        flushInterval: const Duration(hours: 1),
        maximumPending: 5);
    stream.start();
    await recorder.startTrip(userId: 'user-a');
    await pumpEventQueue();
    for (var i = 0; i < 8; i++) {
      location.controller.add(LocationSample(
        timestampMillis: DateTime.now().millisecondsSinceEpoch + i * 1000,
        latitude: 11.57,
        longitude: 43.14,
        speedMps: 10,
        headingDegrees: 90,
        accuracyMeters: 5,
      ));
    }
    await pumpEventQueue();
    await stream.flush();
    expect(stream.lastError, isNotNull);
    online = true;
    await stream.flush();
    expect(stream.sent, 5,
        reason: 'the 3 oldest were dropped; the archive backfills them');
    expect(stream.lastError, isNull);
    await stream.stop();
    await recorder.stopTrip();
    await recorder.dispose();
  });
}

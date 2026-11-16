import 'package:driving_telemetry/driving_telemetry.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_sources.dart';
import 'support/stores.dart';

Future<void> _writeContinuous(
  TelemetryStore store,
  String tripId,
  int index,
  int start,
  int end,
) async {
  final chunk = TelemetryChunk(
    schemaVersion: TelemetryBinaryCodec.schemaVersion,
    tripId: tripId,
    chunkId: 'chunk-$index',
    chunkIndex: index,
    type: TelemetryChunkType.continuous,
    startedAtMillis: start,
    endedAtMillis: end,
  );
  await store.writeChunk(chunk, TelemetryBinaryCodec().encode(chunk));
}

void main() {
  for (final entry in storeFactories.entries) {
    group('${entry.key} store', () {
      test('closes an open trip from its last persisted chunk', () async {
        final store = entry.value(await temporaryDirectory(addTearDown));
        await store.initialize();
        await store.createTrip(
          tripId: 'killed',
          userId: 'user-1',
          startedAtMillis: 1000,
          schemaVersion: TelemetryBinaryCodec.schemaVersion,
        );
        await _writeContinuous(store, 'killed', 0, 1000, 31000);
        await _writeContinuous(store, 'killed', 1, 31000, 61000);
        await store.createTrip(
          tripId: 'finished',
          userId: 'user-1',
          startedAtMillis: 500,
          schemaVersion: TelemetryBinaryCodec.schemaVersion,
        );
        await store.closeTrip(tripId: 'finished', endedAtMillis: 900);

        final recovered = await TelemetryTripRecovery(store).recover();

        expect(recovered.map((trip) => trip.tripId), <String>['killed']);
        expect(recovered.single.endedAtMillis, 61000);
        expect(recovered.single.chunkCount, 3);
        final manifest = await store.readManifest('killed');
        expect(manifest.status, 'closed');
        expect(manifest.endedAtMillis, 61000);
        expect(manifest.metadata['recovered'], isTrue);
        final last = manifest.chunks.last;
        expect(last.type, TelemetryChunkType.tripManifest);
        expect(last.chunkIndex, 2);
        expect(last.chunkId, TelemetryTripRecovery.manifestChunkId('killed'));

        expect(await TelemetryTripRecovery(store).recover(), isEmpty);
      });

      test('a retried recovery reuses the manifest chunk', () async {
        final store = entry.value(await temporaryDirectory(addTearDown));
        await store.initialize();
        await store.createTrip(
          tripId: 'half-recovered',
          userId: 'user-1',
          startedAtMillis: 1000,
          schemaVersion: TelemetryBinaryCodec.schemaVersion,
        );
        await store.writeJsonArtifact(
          tripId: 'half-recovered',
          chunkId: TelemetryTripRecovery.manifestChunkId('half-recovered'),
          chunkIndex: 0,
          type: TelemetryChunkType.tripManifest,
          startedAtMillis: 1000,
          endedAtMillis: 1000,
          schemaVersion: TelemetryBinaryCodec.schemaVersion,
          value: const <String, Object?>{'status': 'closed'},
        );

        await TelemetryTripRecovery(store).recover();

        final manifest = await store.readManifest('half-recovered');
        expect(manifest.status, 'closed');
        expect(manifest.chunks, hasLength(1));
      });

      test('a recorder never recovers its own active trip', () async {
        final store = entry.value(await temporaryDirectory(addTearDown));
        final motion = FakeMotionSource();
        final location = FakeLocationSource();
        final recorder = DrivingTelemetryRecorder(
          store: store,
          motionSource: motion,
          locationSource: location,
        );
        final tripId = await recorder.startTrip(userId: 'user-1');

        expect(await recorder.recoverInterruptedTrips(), isEmpty);
        expect((await store.readManifest(tripId)).status, 'recording');

        await recorder.dispose();
      });
    });
  }

  test('checkpoint persists buffered samples while recording', () async {
    final store = FileTelemetryStore(
      rootDirectory: await temporaryDirectory(addTearDown),
    );
    final motion = FakeMotionSource();
    final location = FakeLocationSource();
    final recorder = DrivingTelemetryRecorder(
      store: store,
      motionSource: motion,
      locationSource: location,
    );
    final tripId = await recorder.startTrip(userId: 'user-1');
    final now = DateTime.now().millisecondsSinceEpoch;
    location.emit(now);
    location.emit(now + 1000);
    await pump();

    await recorder.checkpoint();

    final manifest = await store.readManifest(tripId);
    expect(manifest.chunks, hasLength(1));
    expect(manifest.chunks.single.type, TelemetryChunkType.continuous);
    expect(recorder.isRecording, isTrue);
    await recorder.dispose();
  });

  test('the checkpoint timer flushes without new samples', () async {
    final store = FileTelemetryStore(
      rootDirectory: await temporaryDirectory(addTearDown),
    );
    final location = FakeLocationSource();
    final recorder = DrivingTelemetryRecorder(
      store: store,
      motionSource: FakeMotionSource(),
      locationSource: location,
      configuration: const TelemetryConfiguration(
        checkpointInterval: Duration(milliseconds: 50),
      ),
    );
    final tripId = await recorder.startTrip(userId: 'user-1');
    location.emit(DateTime.now().millisecondsSinceEpoch);
    await pump();

    await Future<void>.delayed(const Duration(milliseconds: 200));
    await recorder.checkpoint();

    expect((await store.readManifest(tripId)).chunks, hasLength(1));
    await recorder.dispose();
  });
}

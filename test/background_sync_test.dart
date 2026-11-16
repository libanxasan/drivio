import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:driving_telemetry/driving_telemetry.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/stores.dart';

class _Backend implements TelemetryBackendClient {
  Object? error;
  final List<String> uploaded = <String>[];
  Duration delay = Duration.zero;

  @override
  Future<TelemetryUploadReceipt> uploadChunk({
    required PendingTelemetryChunk pending,
    required Uint8List compressedBytes,
  }) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    final failure = error;
    if (failure != null) throw failure;
    uploaded.add(pending.chunk.chunkId);
    return const TelemetryUploadReceipt(accepted: true, alreadyExisted: false);
  }
}

Future<TelemetryStore> _seed(int count) async {
  final store =
      SqliteTelemetryStore(rootDirectory: await temporaryDirectory(addTearDown));
  addTearDown(store.close);
  await store.initialize();
  await store.createTrip(
    tripId: 'trip-1',
    userId: 'user-1',
    startedAtMillis: 0,
    schemaVersion: TelemetryBinaryCodec.schemaVersion,
  );
  for (var index = 0; index < count; index++) {
    final chunk = TelemetryChunk(
      schemaVersion: TelemetryBinaryCodec.schemaVersion,
      tripId: 'trip-1',
      chunkId: 'chunk-$index',
      chunkIndex: index,
      type: TelemetryChunkType.continuous,
      startedAtMillis: index * 1000,
      endedAtMillis: index * 1000 + 1000,
    );
    await store.writeChunk(chunk, TelemetryBinaryCodec().encode(chunk));
  }
  return store;
}

void main() {
  group('UploadRetryPolicy', () {
    const policy = UploadRetryPolicy(
      baseDelay: Duration(seconds: 10),
      maximumDelay: Duration(minutes: 1),
      jitter: 0,
    );

    test('doubles the delay and caps it', () {
      expect(policy.delayAfter(0), Duration.zero);
      expect(policy.delayAfter(1), const Duration(seconds: 10));
      expect(policy.delayAfter(3), const Duration(seconds: 40));
      expect(policy.delayAfter(10), const Duration(minutes: 1));
    });

    test('jitter stays within bounds', () {
      const jittered = UploadRetryPolicy(
        baseDelay: Duration(seconds: 10),
        jitter: 0.2,
      );
      expect(
        jittered.delayAfter(1, spread: 1),
        const Duration(seconds: 12),
      );
      expect(
        jittered.delayAfter(1, spread: -1),
        const Duration(seconds: 8),
      );
    });
  });

  test('failed chunks wait for their backoff before retrying', () async {
    final store = await _seed(2);
    final backend = _Backend()
      ..error = const TelemetryUploadException(statusCode: 500, message: 'x');
    var now = 1000000;
    final synchronizer = TelemetrySynchronizer(
      store: store,
      backend: backend,
      retryPolicy: const UploadRetryPolicy(
        baseDelay: Duration(seconds: 30),
        jitter: 0,
      ),
      clock: () => now,
    );

    final first = await synchronizer.synchronize();
    expect(first.failed, 2);

    backend.error = null;
    final deferred = await synchronizer.synchronize();
    expect(deferred.attempted, 0);
    expect(deferred.deferred, 2);

    now = DateTime.now().millisecondsSinceEpoch + 31000;
    final retried = await synchronizer.synchronize();
    expect(retried.uploaded, 2);
    expect(retried.isComplete, isTrue);
  });

  for (final error in <Object>[
    const SocketException('offline'),
    TimeoutException('slow'),
    const TelemetryUploadException(statusCode: 503, message: 'busy'),
  ]) {
    test('stops the pass after ${error.runtimeType}', () async {
      final store = await _seed(3);
      final backend = _Backend()..error = error;
      final result = await TelemetrySynchronizer(
        store: store,
        backend: backend,
      ).synchronize();

      expect(result.attempted, 1);
      expect(result.failed, 1);
      expect(result.remaining, 2);
      expect(result.interrupted, isTrue);
      expect(result.isComplete, isFalse);
    });
  }

  test('a time budget stops starting new uploads', () async {
    final store = await _seed(5);
    final backend = _Backend()..delay = const Duration(milliseconds: 40);
    final synchronizer = TelemetrySynchronizer(store: store, backend: backend);

    final result = await synchronizer.synchronize(
      timeBudget: const Duration(milliseconds: 60),
    );

    expect(result.uploaded, inInclusiveRange(1, 3));
    expect(result.remaining, 5 - result.uploaded);
    expect(
      await runBackgroundTelemetrySync(synchronizer),
      isTrue,
    );
    expect(backend.uploaded, hasLength(5));
  });

  test('background sync reports failure so the OS retries', () async {
    final store = await _seed(1);
    final backend = _Backend()..error = const SocketException('offline');
    expect(
      await runBackgroundTelemetrySync(
        TelemetrySynchronizer(store: store, backend: backend),
      ),
      isFalse,
    );
  });

  group('TelemetrySyncScheduler', () {
    test('backs off after failures and resets after success', () async {
      final store = await _seed(1);
      final backend = _Backend()..error = const SocketException('offline');
      final scheduler = TelemetrySyncScheduler(
        synchronizer: TelemetrySynchronizer(
          store: store,
          backend: backend,
          retryPolicy: UploadRetryPolicy.immediate,
        ),
        interval: const Duration(hours: 1),
        minimumRetryDelay: const Duration(milliseconds: 20),
        random: math.Random(1),
      );
      addTearDown(scheduler.dispose);
      final results = <TelemetrySyncResult>[];
      scheduler.results.listen(results.add);

      scheduler.start();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(results, hasLength(1));
      expect(scheduler.consecutiveFailures, 1);
      expect(
        scheduler.nextRunAt!.difference(DateTime.now()),
        lessThan(const Duration(milliseconds: 30)),
      );

      backend.error = null;
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(results.last.uploaded, 1);
      expect(scheduler.consecutiveFailures, 0);
      expect(
        scheduler.nextRunAt!.difference(DateTime.now()),
        greaterThan(const Duration(minutes: 59)),
      );
    });

    test('pauses offline and syncs when connectivity returns', () async {
      final store = await _seed(1);
      final backend = _Backend();
      final connectivity = StreamController<bool>();
      final scheduler = TelemetrySyncScheduler(
        synchronizer: TelemetrySynchronizer(store: store, backend: backend),
        interval: const Duration(hours: 1),
        connectivity: connectivity.stream,
      );
      addTearDown(scheduler.dispose);
      final results = <TelemetrySyncResult>[];
      scheduler.results.listen(results.add);

      connectivity.add(false);
      scheduler.start();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(results, hasLength(1));
      connectivity.add(false);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(scheduler.nextRunAt, isNull);

      connectivity.add(true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(results, hasLength(2));
      expect(scheduler.nextRunAt, isNotNull);
      await connectivity.close();
    });

    test('syncNow joins a pass already running', () async {
      final store = await _seed(1);
      final backend = _Backend()..delay = const Duration(milliseconds: 20);
      final scheduler = TelemetrySyncScheduler(
        synchronizer: TelemetrySynchronizer(store: store, backend: backend),
      );
      addTearDown(scheduler.dispose);
      final first = scheduler.syncNow();
      final second = scheduler.syncNow();
      expect(identical(first, second), isTrue);
      expect((await first).uploaded, 1);
    });
  });
}

import 'dart:async';

import '../model/location_sample.dart';
import '../model/raw_motion_sample.dart';
import 'location_source.dart';
import 'motion_source.dart';

/// Shares one underlying source between several consumers, such as automatic
/// trip detection and the recorder. The source runs while at least one lease
/// is started, and starts and stops once.
class SourceLeases<T> {
  /// Wraps [start], [stop] and [samples] of the underlying source.
  SourceLeases({
    required Future<void> Function() start,
    required Future<void> Function() stop,
    required Stream<T> samples,
  }) : _start = start,
       _stop = stop,
       _samples = samples;

  final Future<void> Function() _start;
  final Future<void> Function() _stop;
  final Stream<T> _samples;
  final Set<Object> _owners = {};
  Future<void> _tail = Future.value();

  /// The shared sample stream.
  Stream<T> get samples => _samples;

  /// Whether any lease is started.
  bool get isRunning => _owners.isNotEmpty;

  Future<void> _serial(Future<void> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// Starts the source for [owner] (idempotent).
  Future<void> acquire(Object owner) => _serial(() async {
    if (_owners.contains(owner)) return;
    if (_owners.isEmpty) {
      try {
        await _start();
      } catch (_) {
        await _stop();
        rethrow;
      }
    }
    _owners.add(owner);
  });

  /// Releases [owner]; the source stops with the last owner (idempotent).
  Future<void> release(Object owner) => _serial(() async {
    if (!_owners.contains(owner)) return;
    if (_owners.length == 1) await _stop();
    _owners.remove(owner);
  });
}

/// A [LocationSource] that holds a lease on a shared location source.
class LeasedLocationSource implements LocationSource {
  /// Creates a lease on [leases].
  LeasedLocationSource(this.leases);

  /// The shared source.
  final SourceLeases<LocationSample> leases;

  /// Shares [source] between several [LeasedLocationSource]s.
  static SourceLeases<LocationSample> share(LocationSource source) =>
      SourceLeases(
        start: source.start,
        stop: source.stop,
        samples: source.samples,
      );

  @override
  Stream<LocationSample> get samples => leases.samples;

  @override
  Future<void> start() => leases.acquire(this);

  @override
  Future<void> stop() => leases.release(this);
}

/// A [MotionSource] that holds a lease on a shared motion source.
class LeasedMotionSource implements MotionSource {
  /// Creates a lease on [leases].
  LeasedMotionSource(this.leases);

  /// The shared source.
  final SourceLeases<RawMotionSample> leases;

  /// Shares [source] between several [LeasedMotionSource]s.
  static SourceLeases<RawMotionSample> share(MotionSource source) =>
      SourceLeases(
        start: source.start,
        stop: source.stop,
        samples: source.samples,
      );

  @override
  Stream<RawMotionSample> get samples => leases.samples;

  @override
  Future<void> start() => leases.acquire(this);

  @override
  Future<void> stop() => leases.release(this);
}

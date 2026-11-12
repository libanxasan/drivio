import 'dart:async';

import 'package:driving_telemetry/driving_telemetry.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const TelemetryExampleApp());
}

class TelemetryExampleApp extends StatefulWidget {
  const TelemetryExampleApp({super.key, this.createRecorder});

  /// Creates the recorder owned by this screen.
  final DrivingTelemetryRecorder Function()? createRecorder;

  @override
  State<TelemetryExampleApp> createState() => _TelemetryExampleAppState();
}

class _TelemetryExampleAppState extends State<TelemetryExampleApp> {
  late final DrivingTelemetryRecorder _recorder;
  late final StreamSubscription<TelemetryRecorderState> _stateSubscription;
  TelemetryTripResult? _lastTrip;
  String? _actionError;

  @override
  void initState() {
    super.initState();
    _recorder = (widget.createRecorder ?? _createRecorder)();
    _stateSubscription = _recorder.states.listen((_) {
      if (mounted) setState(() {});
    });
  }

  DrivingTelemetryRecorder _createRecorder() {
    final configuration = const TelemetryConfiguration();
    return DrivingTelemetryRecorder(
      store: FileTelemetryStore(),
      motionSource: SensorMotionSource(
        samplingPeriod: configuration.motionSamplingPeriod,
      ),
      locationSource: GeolocatorLocationSource(),
      configuration: configuration,
      osrmClient: OsrmClient(),
    );
  }

  @override
  void dispose() {
    unawaited(_stateSubscription.cancel());
    unawaited(_recorder.dispose());
    super.dispose();
  }

  Future<void> _toggleRecording() async {
    final state = _recorder.state;
    if (state != TelemetryRecorderState.idle &&
        state != TelemetryRecorderState.recording) {
      return;
    }
    final saving = _recorder.isRecording || _recorder.canRetryTripSave;
    _actionError = null;
    try {
      if (saving) {
        final result = await _recorder.stopTrip();
        if (!mounted) return;
        setState(() => _lastTrip = result);
      } else {
        await _recorder.startTrip(
          userId: 'example-user',
          metadata: const <String, Object?>{'vehicleId': 'example-vehicle'},
        );
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _actionError = switch (error) {
          LocationSourceException(:final message) => message,
          _ when saving => 'Trip save incomplete. Retry to finish saving.',
          _ => 'Could not start the trip. Try again.',
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _recorder.state;
    final (label, status) = switch (state) {
      TelemetryRecorderState.idle when _recorder.canRetryTripSave => (
          'Retry save',
          _actionError ?? 'Trip save incomplete.',
        ),
      TelemetryRecorderState.idle => (
          'Start trip',
          _actionError ?? (_lastTrip == null ? 'Ready' : 'Trip saved locally'),
        ),
      TelemetryRecorderState.starting => ('Start trip', 'Starting trip'),
      TelemetryRecorderState.recording => (
          'Stop trip',
          'Recording trip ${_recorder.activeTripId}',
        ),
      TelemetryRecorderState.stopping => (
          'Stop trip',
          'Saving trip telemetry',
        ),
      TelemetryRecorderState.disposed => ('Start trip', 'Recorder closed'),
    };
    final canAct = state == TelemetryRecorderState.idle ||
        state == TelemetryRecorderState.recording;
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Driving Telemetry')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(status),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: canAct ? _toggleRecording : null,
                child: Text(label),
              ),
              if (_lastTrip != null) ...<Widget>[
                const SizedBox(height: 24),
                Text('Trip: ${_lastTrip!.tripId}'),
                Text('Chunks: ${_lastTrip!.chunkCount}'),
                Text('Events: ${_lastTrip!.eventCount}'),
                Text(
                  'Raw distance: '
                  '${_lastTrip!.rawGpsDistanceMeters.toStringAsFixed(0)} m',
                ),
                Text(
                  'Matched distance: '
                  '${_lastTrip!.osrmMatch?.totalDistanceMeters.toStringAsFixed(0) ?? "Unavailable"} m',
                ),
                Text('Pending uploads: ${_lastTrip!.pendingUploadCount}'),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

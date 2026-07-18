import 'package:driving_telemetry/driving_telemetry.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const TelemetryExampleApp());
}

class TelemetryExampleApp extends StatefulWidget {
  const TelemetryExampleApp({super.key});

  @override
  State<TelemetryExampleApp> createState() => _TelemetryExampleAppState();
}

class _TelemetryExampleAppState extends State<TelemetryExampleApp> {
  late final DrivingTelemetryRecorder _recorder;
  String _status = 'Ready';
  TelemetryTripResult? _lastTrip;

  @override
  void initState() {
    super.initState();
    final configuration = const TelemetryConfiguration();
    final store = FileTelemetryStore();
    _recorder = DrivingTelemetryRecorder(
      store: store,
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
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _toggleRecording() async {
    try {
      if (_recorder.isRecording) {
        setState(() => _status = 'Finalizing telemetry');
        final result = await _recorder.stopTrip();
        if (!mounted) return;
        setState(() {
          _lastTrip = result;
          _status = 'Trip saved locally';
        });
      } else {
        final tripId = await _recorder.startTrip(
          userId: 'example-user',
          metadata: const <String, Object?>{
            'vehicleId': 'example-vehicle',
          },
        );
        if (!mounted) return;
        setState(() => _status = 'Recording trip $tripId');
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Driving Telemetry')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(_status),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _toggleRecording,
                child: Text(
                  _recorder.isRecording ? 'Stop trip' : 'Start trip',
                ),
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

import 'package:driving_telemetry/driving_telemetry.dart';
import 'package:flutter/material.dart';

import 'trip_controller.dart';

/// Root widget of the example app.
class DrivioExampleApp extends StatelessWidget {
  /// Creates the app around an initialized [controller].
  const DrivioExampleApp({super.key, required this.controller});

  /// Screen state.
  final TripController controller;

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF00696B);
    return MaterialApp(
      title: 'Drivio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: seed,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: TripScreen(controller: controller),
    );
  }
}

/// Records trips and shows live telemetry, uploads and history.
class TripScreen extends StatelessWidget {
  /// Creates the screen.
  const TripScreen({super.key, required this.controller});

  /// Screen state.
  final TripController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(title: const Text('Drivio')),
          body: RefreshIndicator(
            onRefresh: controller.refreshTrips,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: <Widget>[
                if (controller.recovered.isNotEmpty)
                  _RecoveredNotice(controller: controller),
                _RecordingCard(controller: controller),
                if (controller.lastTrip != null && !controller.isRecording)
                  _LastTripCard(trip: controller.lastTrip!),
                if (controller.automatic != null)
                  SwitchListTile(
                    title: const Text('Record drives automatically'),
                    subtitle: const Text(
                        'Starts and stops from GPS speed and motion'),
                    value: controller.automaticEnabled,
                    onChanged: controller.setAutomatic,
                  ),
                _UploadsCard(controller: controller),
                if (controller.liveStream != null)
                  _LiveStreamCard(controller: controller),
                const SizedBox(height: 8),
                _SectionTitle('Trips'),
                if (controller.trips.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      'No trips yet.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                for (final trip in controller.trips) _TripTile(trip: trip),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _RecoveredNotice extends StatelessWidget {
  const _RecoveredNotice({required this.controller});

  final TripController controller;

  @override
  Widget build(BuildContext context) {
    final count = controller.recovered.length;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.tertiaryContainer,
      child: ListTile(
        leading: Icon(Icons.restore, color: scheme.onTertiaryContainer),
        title: Text(
          count == 1
              ? '1 interrupted trip was recovered'
              : '$count interrupted trips were recovered',
          style: TextStyle(color: scheme.onTertiaryContainer),
        ),
        subtitle: Text(
          'The app was closed while recording. Data up to the last '
          'checkpoint was saved.',
          style: TextStyle(color: scheme.onTertiaryContainer),
        ),
        trailing: IconButton(
          tooltip: 'Dismiss',
          icon: const Icon(Icons.close),
          color: scheme.onTertiaryContainer,
          onPressed: controller.dismissRecovered,
        ),
      ),
    );
  }
}

class _RecordingCard extends StatelessWidget {
  const _RecordingCard({required this.controller});

  final TripController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = controller.recorderState;
    final (label, icon) = switch (state) {
      _ when controller.canRetrySave => ('Retry save', Icons.refresh),
      TelemetryRecorderState.recording => ('Stop trip', Icons.stop),
      TelemetryRecorderState.stopping => ('Saving…', Icons.hourglass_top),
      TelemetryRecorderState.starting => ('Starting…', Icons.hourglass_top),
      _ => ('Start trip', Icons.play_arrow),
    };
    final status = switch (state) {
      _ when controller.canRetrySave => 'Trip save incomplete',
      TelemetryRecorderState.recording => 'Recording',
      TelemetryRecorderState.stopping => 'Saving trip',
      TelemetryRecorderState.starting => 'Starting trip',
      TelemetryRecorderState.disposed => 'Recorder closed',
      TelemetryRecorderState.idle => 'Ready',
    };
    final location = controller.lastLocation;
    final canAct =
        !controller.isBusy && state != TelemetryRecorderState.disposed;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                _StatusDot(active: controller.isRecording),
                const SizedBox(width: 8),
                Text(status, style: theme.textTheme.titleMedium),
                const Spacer(),
                if (controller.isRecording && controller.isMotionPaused)
                  const Chip(
                    avatar: Icon(Icons.local_parking, size: 18),
                    label: Text('Sensors paused'),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              _formatDuration(controller.elapsed),
              textAlign: TextAlign.center,
              style: theme.textTheme.displayMedium?.copyWith(
                fontFeatures: const <FontFeature>[
                  FontFeature.tabularFigures(),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.spaceAround,
              spacing: 16,
              runSpacing: 12,
              children: <Widget>[
                _Metric(
                  label: 'Speed',
                  value: location == null
                      ? '–'
                      : '${location.speedKph.toStringAsFixed(0)} km/h',
                ),
                _Metric(
                  label: 'GPS accuracy',
                  value: location == null
                      ? '–'
                      : '${location.accuracyMeters.toStringAsFixed(0)} m',
                ),
                _Metric(label: 'Fixes', value: '${controller.fixCount}'),
                _Metric(label: 'Events', value: '${controller.eventCount}'),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('trip-action'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                backgroundColor:
                    controller.isRecording ? theme.colorScheme.error : null,
                foregroundColor:
                    controller.isRecording ? theme.colorScheme.onError : null,
              ),
              onPressed: canAct ? controller.toggleTrip : null,
              icon: Icon(icon),
              label: Text(label),
            ),
            if (controller.error != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                controller.error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
            if (controller.isRecording) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                'Recording continues with the screen off or in another app.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LastTripCard extends StatelessWidget {
  const _LastTripCard({required this.trip});

  final TelemetryTripResult trip;

  @override
  Widget build(BuildContext context) {
    final matched = trip.osrmMatch?.totalDistanceMeters;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Trip saved',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            _Row(
                'Duration',
                _formatDuration(
                  Duration(
                      milliseconds: trip.endedAtMillis - trip.startedAtMillis),
                )),
            _Row('GPS distance', _formatDistance(trip.rawGpsDistanceMeters)),
            _Row(
              'Matched distance',
              matched == null ? 'Unavailable' : _formatDistance(matched),
            ),
            _Row('Events', '${trip.eventCount}'),
            _Row('Chunks', '${trip.chunkCount}'),
            _Row('Pending uploads', '${trip.pendingUploadCount}'),
          ],
        ),
      ),
    );
  }
}

class _LiveStreamCard extends StatelessWidget {
  const _LiveStreamCard({required this.controller});

  final TripController controller;

  @override
  Widget build(BuildContext context) {
    final stream = controller.liveStream!;
    final last = stream.lastSentAt;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(stream.lastError == null
                    ? Icons.sensors
                    : Icons.sensors_off),
                const SizedBox(width: 8),
                Text('Live stream',
                    style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 8),
            _Row('Items sent', '${stream.sent}'),
            _Row(
                'Last sent',
                last == null
                    ? 'Not yet'
                    : TimeOfDay.fromDateTime(last).format(context)),
            if (stream.lastError != null)
              const Text(
                  'Offline. The gap is filled from the archive once it uploads.'),
          ],
        ),
      ),
    );
  }
}

class _UploadsCard extends StatelessWidget {
  const _UploadsCard({required this.controller});

  final TripController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sync = controller.lastSync;
    final next = controller.scheduler?.nextRunAt;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  controller.pendingUploads == 0
                      ? Icons.cloud_done_outlined
                      : Icons.cloud_upload_outlined,
                ),
                const SizedBox(width: 8),
                Text('Uploads', style: theme.textTheme.titleMedium),
                const Spacer(),
                Text(
                  controller.pendingUploads == 0
                      ? 'All uploaded'
                      : '${controller.pendingUploads} pending',
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (!controller.uploadsEnabled)
              Text(
                'Uploads are off. Run with '
                '--dart-define=DRIVIO_CONVEX_URL=<deployment URL> to enable them.',
                style: theme.textTheme.bodySmall,
              )
            else ...<Widget>[
              if (sync != null)
                Text(
                  _describeSync(sync, controller.lastSyncAt!),
                  style: theme.textTheme.bodySmall,
                ),
              if (next != null)
                Text(
                  'Next upload ${_formatTime(next)}',
                  style: theme.textTheme.bodySmall,
                ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: controller.isSyncing ? null : controller.syncNow,
                icon: const Icon(Icons.sync),
                label: Text(controller.isSyncing ? 'Uploading…' : 'Upload now'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _describeSync(TelemetrySyncResult result, DateTime at) {
    final when = _formatTime(at);
    if (result.interrupted) return 'Offline or server busy at $when';
    if (result.failed > 0) {
      return '${result.uploaded} uploaded, ${result.failed} failed at $when';
    }
    if (result.attempted == 0) return 'Nothing to upload at $when';
    return '${result.uploaded} uploaded at $when';
  }
}

class _TripTile extends StatelessWidget {
  const _TripTile({required this.trip});

  final TripManifest trip;

  @override
  Widget build(BuildContext context) {
    final started =
        DateTime.fromMillisecondsSinceEpoch(trip.startedAtMillis).toLocal();
    final ended = trip.endedAtMillis;
    final distance = trip.metadata['rawGpsDistanceMeters'];
    final pending = trip.chunks
        .where((chunk) => chunk.uploadStatus != ChunkUploadStatus.uploaded)
        .length;
    final recovered = trip.metadata['recovered'] == true;
    final details = <String>[
      if (ended != null)
        _formatDuration(Duration(milliseconds: ended - trip.startedAtMillis)),
      if (distance is num) _formatDistance(distance.toDouble()),
      if (pending > 0) '$pending to upload',
    ];
    final (label, icon) = switch (trip.status) {
      'recording' => ('Recording', Icons.fiber_manual_record),
      _ when recovered => ('Recovered', Icons.restore),
      _ => ('Saved', Icons.check_circle_outline),
    };
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: Icon(icon),
        title: Text('${_formatDate(started)} · ${_formatTime(started)}'),
        subtitle: Text(details.isEmpty ? label : details.join(' · ')),
        trailing: Text(label),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
      child: Text(text, style: Theme.of(context).textTheme.titleSmall),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 120,
      child: Column(
        children: <Widget>[
          Text(value, style: theme.textTheme.titleLarge),
          Text(label, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label)),
          Text(value),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: active ? scheme.error : scheme.outline,
      ),
    );
  }
}

String _formatDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$hours:$minutes:$seconds';
}

String _formatDistance(double meters) => meters >= 1000
    ? '${(meters / 1000).toStringAsFixed(1)} km'
    : '${meters.toStringAsFixed(0)} m';

String _formatTime(DateTime value) {
  final local = value.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

String _formatDate(DateTime value) {
  final local = value.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
}

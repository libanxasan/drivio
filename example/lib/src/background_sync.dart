import 'package:driving_telemetry/driving_telemetry.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import 'example_config.dart';

/// Task identifier. On iOS it must also be listed under
/// `BGTaskSchedulerPermittedIdentifiers` in `Info.plist` and registered in
/// `AppDelegate.swift`.
const String backgroundSyncTask = 'dev.drivio.example.telemetrySync';

/// Entry point the OS calls in a fresh background isolate.
@pragma('vm:entry-point')
void backgroundSyncDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    final backend = const ExampleConfig.fromEnvironment().createBackend();
    if (backend == null) return true;

    // SQLite is safe to open from this isolate while the UI isolate also
    // has the database open.
    final store = SqliteTelemetryStore();
    try {
      return await runBackgroundTelemetrySync(
        TelemetrySynchronizer(store: store, backend: backend),
      );
    } finally {
      await store.close();
    }
  });
}

/// Schedules periodic uploads while the app is suspended or closed.
///
/// Android runs the task about every 15 minutes when a network is
/// available. iOS decides when to run background refresh tasks based on how
/// the app is used, so uploads there are opportunistic.
Future<void> registerBackgroundSync() async {
  if (kIsWeb ||
      (defaultTargetPlatform != TargetPlatform.android &&
          defaultTargetPlatform != TargetPlatform.iOS)) {
    return;
  }
  await Workmanager().initialize(backgroundSyncDispatcher);
  await Workmanager().registerPeriodicTask(
    backgroundSyncTask,
    backgroundSyncTask,
    frequency: const Duration(minutes: 15),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
  );
}

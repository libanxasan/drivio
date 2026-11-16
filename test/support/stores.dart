import 'dart:io';

import 'package:driving_telemetry/driving_telemetry.dart';

/// Creates a store rooted in [directory].
typedef StoreFactory = TelemetryStore Function(Directory directory);

/// Every store implementation, so behavior tests run against each one.
final Map<String, StoreFactory> storeFactories = <String, StoreFactory>{
  'file': (directory) => FileTelemetryStore(rootDirectory: directory),
  'sqlite': (directory) => SqliteTelemetryStore(rootDirectory: directory),
};

/// Creates a temporary directory removed after the test.
Future<Directory> temporaryDirectory(
  void Function(dynamic Function()) addTearDown,
) async {
  final directory = await Directory.systemTemp.createTemp('telemetry_test_');
  addTearDown(() => directory.delete(recursive: true));
  return directory;
}

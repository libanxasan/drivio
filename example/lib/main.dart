import 'dart:async';

import 'package:flutter/material.dart';

import 'src/background_sync.dart';
import 'src/example_config.dart';
import 'src/example_services.dart';
import 'src/trip_controller.dart';
import 'src/trip_screen.dart';

export 'src/trip_controller.dart';
export 'src/trip_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const config = ExampleConfig.fromEnvironment();
  final controller = await ExampleServices.create(config);
  await controller.initialize();
  if (config.uploadsEnabled) unawaited(registerBackgroundSync());
  runApp(_ControllerOwner(controller: controller));
}

/// Disposes the controller when the app is torn down.
class _ControllerOwner extends StatefulWidget {
  const _ControllerOwner({required this.controller});

  final TripController controller;

  @override
  State<_ControllerOwner> createState() => _ControllerOwnerState();
}

class _ControllerOwnerState extends State<_ControllerOwner> {
  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      DrivioExampleApp(controller: widget.controller);
}

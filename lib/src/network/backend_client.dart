import 'dart:typed_data';

import '../storage/telemetry_store.dart';

/// Backend acknowledgement for one chunk upload.
class TelemetryUploadReceipt {
  /// Creates an upload receipt.
  const TelemetryUploadReceipt({
    required this.accepted,
    required this.alreadyExisted,
    this.backendChunkId,
    this.message,
  });

  /// Whether the backend accepted the payload.
  final bool accepted;

  /// Whether the same idempotency key had already been processed.
  final bool alreadyExisted;

  /// Optional backend identifier.
  final String? backendChunkId;

  /// Optional backend message.
  final String? message;
}

/// Uploads compact telemetry chunks to an application backend.
abstract interface class TelemetryBackendClient {
  /// Uploads one already-compressed chunk.
  Future<TelemetryUploadReceipt> uploadChunk({
    required PendingTelemetryChunk pending,
    required Uint8List compressedBytes,
  });
}

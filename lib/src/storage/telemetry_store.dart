import 'dart:typed_data';

import '../model/telemetry_chunk.dart';
import '../model/trip_manifest.dart';

/// A pending persisted chunk and its trip context.
class PendingTelemetryChunk {
  /// Creates a pending chunk.
  const PendingTelemetryChunk({
    required this.tripId,
    required this.userId,
    required this.metadata,
    required this.chunk,
  });

  /// Trip identifier.
  final String tripId;

  /// User identifier.
  final String userId;

  /// Trip metadata.
  final Map<String, Object?> metadata;

  /// Stored chunk metadata.
  final StoredTelemetryChunk chunk;
}

/// Durable telemetry storage abstraction.
abstract interface class TelemetryStore {
  /// Initializes backing storage. Repeated calls reuse initialized storage.
  Future<void> initialize();

  /// Creates a trip manifest.
  Future<TripManifest> createTrip({
    required String tripId,
    required String userId,
    required int startedAtMillis,
    required int schemaVersion,
    Map<String, Object?> metadata = const <String, Object?>{},
  });

  /// Writes a compact binary chunk.
  Future<StoredTelemetryChunk> writeChunk(
    TelemetryChunk chunk,
    Uint8List uncompressedBytes,
  );

  /// Writes a JSON artifact as a compressed uploadable chunk.
  Future<StoredTelemetryChunk> writeJsonArtifact({
    required String tripId,
    required String chunkId,
    required int chunkIndex,
    required TelemetryChunkType type,
    required int startedAtMillis,
    required int endedAtMillis,
    required int schemaVersion,
    required Map<String, Object?> value,
  });

  /// Closes a trip manifest.
  Future<void> closeTrip({
    required String tripId,
    required int endedAtMillis,
    Map<String, Object?> metadataUpdates = const <String, Object?>{},
  });

  /// Reads a manifest.
  Future<TripManifest> readManifest(String tripId);

  /// Lists chunks eligible to upload, including interrupted attempts.
  Future<List<PendingTelemetryChunk>> listPendingChunks();

  /// Reads compressed chunk bytes.
  Future<Uint8List> readStoredChunk(StoredTelemetryChunk chunk);

  /// Marks a chunk as uploading.
  Future<void> markUploading(String tripId, String chunkId);

  /// Marks a chunk as uploaded.
  Future<void> markUploaded(String tripId, String chunkId);

  /// Marks an upload failure.
  Future<void> markFailed(String tripId, String chunkId, String error);

  /// Deletes a local chunk file while retaining manifest history.
  Future<void> deleteChunkFile(String tripId, String chunkId);

  /// Returns the number of pending chunks for a trip.
  Future<int> pendingChunkCount(String tripId);
}

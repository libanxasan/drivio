import 'telemetry_chunk.dart';

/// Local upload status.
enum ChunkUploadStatus {
  /// Not yet uploaded.
  pending,

  /// An upload attempt is in progress.
  uploading,

  /// Acknowledged by the backend.
  uploaded,

  /// The most recent upload attempt failed.
  failed,
}

/// Persisted chunk metadata.
class StoredTelemetryChunk {
  /// Creates stored chunk metadata.
  const StoredTelemetryChunk({
    required this.chunkId,
    required this.chunkIndex,
    required this.type,
    required this.startedAtMillis,
    required this.endedAtMillis,
    required this.schemaVersion,
    required this.payloadFormat,
    required this.byteSize,
    required this.checksumSha256,
    required this.relativePath,
    required this.uploadStatus,
    this.retryCount = 0,
    this.lastError,
  });

  /// Stable chunk identifier.
  final String chunkId;

  /// Monotonic trip-local index.
  final int chunkIndex;

  /// Chunk type.
  final TelemetryChunkType type;

  /// Start timestamp.
  final int startedAtMillis;

  /// End timestamp.
  final int endedAtMillis;

  /// Schema version.
  final int schemaVersion;

  /// Payload format before compression.
  final String payloadFormat;

  /// Compressed byte size.
  final int byteSize;

  /// SHA-256 checksum of the compressed file.
  final String checksumSha256;

  /// Path relative to the telemetry root directory.
  final String relativePath;

  /// Upload state.
  final ChunkUploadStatus uploadStatus;

  /// Number of failed upload attempts.
  final int retryCount;

  /// Most recent upload error.
  final String? lastError;

  /// Copy with changed upload state.
  StoredTelemetryChunk copyWith({
    ChunkUploadStatus? uploadStatus,
    int? retryCount,
    String? lastError,
    bool clearLastError = false,
  }) {
    return StoredTelemetryChunk(
      chunkId: chunkId,
      chunkIndex: chunkIndex,
      type: type,
      startedAtMillis: startedAtMillis,
      endedAtMillis: endedAtMillis,
      schemaVersion: schemaVersion,
      payloadFormat: payloadFormat,
      byteSize: byteSize,
      checksumSha256: checksumSha256,
      relativePath: relativePath,
      uploadStatus: uploadStatus ?? this.uploadStatus,
      retryCount: retryCount ?? this.retryCount,
      lastError: clearLastError ? null : lastError ?? this.lastError,
    );
  }

  /// JSON representation.
  Map<String, Object?> toJson() => <String, Object?>{
        'chunkId': chunkId,
        'chunkIndex': chunkIndex,
        'type': type.name,
        'startedAtMillis': startedAtMillis,
        'endedAtMillis': endedAtMillis,
        'schemaVersion': schemaVersion,
        'payloadFormat': payloadFormat,
        'byteSize': byteSize,
        'checksumSha256': checksumSha256,
        'relativePath': relativePath,
        'uploadStatus': uploadStatus.name,
        'retryCount': retryCount,
        'lastError': lastError,
      };

  /// Creates metadata from JSON.
  factory StoredTelemetryChunk.fromJson(Map<String, Object?> json) {
    return StoredTelemetryChunk(
      chunkId: json['chunkId']! as String,
      chunkIndex: json['chunkIndex']! as int,
      type: TelemetryChunkType.values.byName(json['type']! as String),
      startedAtMillis: json['startedAtMillis']! as int,
      endedAtMillis: json['endedAtMillis']! as int,
      schemaVersion: json['schemaVersion']! as int,
      payloadFormat: (json['payloadFormat'] as String?) ?? 'compact-binary',
      byteSize: json['byteSize']! as int,
      checksumSha256: json['checksumSha256']! as String,
      relativePath: json['relativePath']! as String,
      uploadStatus:
          ChunkUploadStatus.values.byName(json['uploadStatus']! as String),
      retryCount: (json['retryCount'] as int?) ?? 0,
      lastError: json['lastError'] as String?,
    );
  }
}

/// Persisted trip manifest.
class TripManifest {
  /// Creates a manifest.
  const TripManifest({
    required this.tripId,
    required this.userId,
    required this.startedAtMillis,
    required this.schemaVersion,
    required this.status,
    required this.chunks,
    this.endedAtMillis,
    this.metadata = const <String, Object?>{},
  });

  /// Trip identifier.
  final String tripId;

  /// Host application user identifier.
  final String userId;

  /// Trip start time.
  final int startedAtMillis;

  /// Trip end time.
  final int? endedAtMillis;

  /// Current binary schema version.
  final int schemaVersion;

  /// Trip status.
  final String status;

  /// Persisted chunks.
  final List<StoredTelemetryChunk> chunks;

  /// Host-defined trip metadata.
  final Map<String, Object?> metadata;

  /// Copy with changed fields.
  TripManifest copyWith({
    int? endedAtMillis,
    String? status,
    List<StoredTelemetryChunk>? chunks,
    Map<String, Object?>? metadata,
  }) {
    return TripManifest(
      tripId: tripId,
      userId: userId,
      startedAtMillis: startedAtMillis,
      endedAtMillis: endedAtMillis ?? this.endedAtMillis,
      schemaVersion: schemaVersion,
      status: status ?? this.status,
      chunks: chunks ?? this.chunks,
      metadata: metadata ?? this.metadata,
    );
  }

  /// JSON representation.
  Map<String, Object?> toJson() => <String, Object?>{
        'tripId': tripId,
        'userId': userId,
        'startedAtMillis': startedAtMillis,
        'endedAtMillis': endedAtMillis,
        'schemaVersion': schemaVersion,
        'status': status,
        'chunks': chunks.map((value) => value.toJson()).toList(),
        'metadata': metadata,
      };

  /// Creates a manifest from JSON.
  factory TripManifest.fromJson(Map<String, Object?> json) {
    final chunksJson = (json['chunks'] as List<Object?>?) ?? const <Object?>[];
    return TripManifest(
      tripId: json['tripId']! as String,
      userId: json['userId']! as String,
      startedAtMillis: json['startedAtMillis']! as int,
      endedAtMillis: json['endedAtMillis'] as int?,
      schemaVersion: json['schemaVersion']! as int,
      status: json['status']! as String,
      chunks: chunksJson
          .cast<Map<String, Object?>>()
          .map(StoredTelemetryChunk.fromJson)
          .toList(growable: false),
      metadata: (json['metadata'] as Map<String, Object?>?) ??
          const <String, Object?>{},
    );
  }
}

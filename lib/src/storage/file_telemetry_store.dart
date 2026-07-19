import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../model/telemetry_chunk.dart';
import '../model/trip_manifest.dart';
import '../utils/async_mutex.dart';
import 'telemetry_store.dart';

/// File-based local telemetry store with atomic manifests.
class FileTelemetryStore implements TelemetryStore {
  /// Creates a store. A root override is useful in tests and desktop tools.
  FileTelemetryStore({Directory? rootDirectory})
      : _rootDirectoryOverride = rootDirectory;

  final Directory? _rootDirectoryOverride;
  final AsyncMutex _mutex = AsyncMutex();
  Directory? _root;

  Directory get _requiredRoot {
    final root = _root;
    if (root == null) {
      throw StateError('FileTelemetryStore.initialize must be called first.');
    }
    return root;
  }

  @override
  Future<void> initialize() {
    return _mutex.protect(() async {
      if (_root != null) return;
      final base =
          _rootDirectoryOverride ?? await getApplicationSupportDirectory();
      final root = Directory('${base.path}/driving_telemetry');
      await root.create(recursive: true);
      await Directory('${root.path}/trips').create(recursive: true);
      _root = root;
    });
  }

  @override
  Future<TripManifest> createTrip({
    required String tripId,
    required String userId,
    required int startedAtMillis,
    required int schemaVersion,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    return _mutex.protect(() async {
      final directory = _tripDirectory(tripId);
      await directory.create(recursive: true);
      await Directory('${directory.path}/chunks').create(recursive: true);
      final manifest = TripManifest(
        tripId: tripId,
        userId: userId,
        startedAtMillis: startedAtMillis,
        schemaVersion: schemaVersion,
        status: 'recording',
        chunks: const <StoredTelemetryChunk>[],
        metadata: metadata,
      );
      await _writeManifest(manifest);
      return manifest;
    });
  }

  @override
  Future<StoredTelemetryChunk> writeChunk(
    TelemetryChunk chunk,
    Uint8List uncompressedBytes,
  ) {
    return _writeCompressedChunk(
      tripId: chunk.tripId,
      chunkId: chunk.chunkId,
      chunkIndex: chunk.chunkIndex,
      type: chunk.type,
      startedAtMillis: chunk.startedAtMillis,
      endedAtMillis: chunk.endedAtMillis,
      schemaVersion: chunk.schemaVersion,
      uncompressedBytes: uncompressedBytes,
      extension: 'dtl.gz',
      payloadFormat: 'compact-binary',
    );
  }

  @override
  Future<StoredTelemetryChunk> writeJsonArtifact({
    required String tripId,
    required String chunkId,
    required int chunkIndex,
    required TelemetryChunkType type,
    required int startedAtMillis,
    required int endedAtMillis,
    required int schemaVersion,
    required Map<String, Object?> value,
  }) {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(value)));
    return _writeCompressedChunk(
      tripId: tripId,
      chunkId: chunkId,
      chunkIndex: chunkIndex,
      type: type,
      startedAtMillis: startedAtMillis,
      endedAtMillis: endedAtMillis,
      schemaVersion: schemaVersion,
      uncompressedBytes: bytes,
      extension: 'json.gz',
      payloadFormat: 'json',
    );
  }

  Future<StoredTelemetryChunk> _writeCompressedChunk({
    required String tripId,
    required String chunkId,
    required int chunkIndex,
    required TelemetryChunkType type,
    required int startedAtMillis,
    required int endedAtMillis,
    required int schemaVersion,
    required Uint8List uncompressedBytes,
    required String extension,
    required String payloadFormat,
  }) {
    return _mutex.protect(() async {
      final compressed = Uint8List.fromList(gzip.encode(uncompressedBytes));
      final checksum = sha256.convert(compressed).toString();
      final relativePath = 'trips/$tripId/chunks/$chunkId.$extension';
      final output = File('${_requiredRoot.path}/$relativePath');
      await output.parent.create(recursive: true);
      await _atomicWriteBytes(output, compressed);

      final stored = StoredTelemetryChunk(
        chunkId: chunkId,
        chunkIndex: chunkIndex,
        type: type,
        startedAtMillis: startedAtMillis,
        endedAtMillis: endedAtMillis,
        schemaVersion: schemaVersion,
        payloadFormat: payloadFormat,
        byteSize: compressed.length,
        checksumSha256: checksum,
        relativePath: relativePath,
        uploadStatus: ChunkUploadStatus.pending,
      );

      final manifest = await _readManifestUnlocked(tripId);
      final chunks = <StoredTelemetryChunk>[
        ...manifest.chunks.where((value) => value.chunkId != chunkId),
        stored,
      ]..sort((a, b) => a.chunkIndex.compareTo(b.chunkIndex));
      await _writeManifest(manifest.copyWith(chunks: chunks));
      return stored;
    });
  }

  @override
  Future<void> closeTrip({
    required String tripId,
    required int endedAtMillis,
    Map<String, Object?> metadataUpdates = const <String, Object?>{},
  }) {
    return _mutex.protect(() async {
      final manifest = await _readManifestUnlocked(tripId);
      await _writeManifest(
        manifest.copyWith(
          endedAtMillis: endedAtMillis,
          status: 'closed',
          metadata: <String, Object?>{
            ...manifest.metadata,
            ...metadataUpdates,
          },
        ),
      );
    });
  }

  @override
  Future<TripManifest> readManifest(String tripId) {
    return _mutex.protect(() => _readManifestUnlocked(tripId));
  }

  @override
  Future<List<PendingTelemetryChunk>> listPendingChunks() {
    return _mutex.protect(() async {
      final trips = Directory('${_requiredRoot.path}/trips');
      if (!await trips.exists()) return const <PendingTelemetryChunk>[];
      final pending = <PendingTelemetryChunk>[];
      await for (final entity in trips.list()) {
        if (entity is! Directory) continue;
        final manifestFile = File('${entity.path}/manifest.json');
        if (!await manifestFile.exists()) continue;
        final manifest = await _readManifestFile(manifestFile);
        for (final chunk in manifest.chunks) {
          if (chunk.uploadStatus == ChunkUploadStatus.pending ||
              chunk.uploadStatus == ChunkUploadStatus.failed ||
              chunk.uploadStatus == ChunkUploadStatus.uploading) {
            final file = File('${_requiredRoot.path}/${chunk.relativePath}');
            if (!await file.exists()) continue;
            pending.add(
              PendingTelemetryChunk(
                tripId: manifest.tripId,
                userId: manifest.userId,
                metadata: manifest.metadata,
                chunk: chunk,
              ),
            );
          }
        }
      }
      pending.sort((a, b) {
        final tripOrder = a.tripId.compareTo(b.tripId);
        if (tripOrder != 0) return tripOrder;
        return a.chunk.chunkIndex.compareTo(b.chunk.chunkIndex);
      });
      return pending;
    });
  }

  @override
  Future<Uint8List> readStoredChunk(StoredTelemetryChunk chunk) async {
    final file = File('${_requiredRoot.path}/${chunk.relativePath}');
    return file.readAsBytes();
  }

  @override
  Future<void> markUploading(String tripId, String chunkId) {
    return _updateChunk(
      tripId,
      chunkId,
      (value) => value.copyWith(
        uploadStatus: ChunkUploadStatus.uploading,
        clearLastError: true,
      ),
    );
  }

  @override
  Future<void> markUploaded(String tripId, String chunkId) {
    return _updateChunk(
      tripId,
      chunkId,
      (value) => value.copyWith(
        uploadStatus: ChunkUploadStatus.uploaded,
        clearLastError: true,
      ),
    );
  }

  @override
  Future<void> markFailed(String tripId, String chunkId, String error) {
    return _updateChunk(
      tripId,
      chunkId,
      (value) => value.copyWith(
        uploadStatus: ChunkUploadStatus.failed,
        retryCount: value.retryCount + 1,
        lastError: error,
      ),
    );
  }

  Future<void> _updateChunk(
    String tripId,
    String chunkId,
    StoredTelemetryChunk Function(StoredTelemetryChunk value) update,
  ) {
    return _mutex.protect(() async {
      final manifest = await _readManifestUnlocked(tripId);
      final chunks = manifest.chunks.map((value) {
        return value.chunkId == chunkId ? update(value) : value;
      }).toList(growable: false);
      await _writeManifest(manifest.copyWith(chunks: chunks));
    });
  }

  @override
  Future<void> deleteChunkFile(String tripId, String chunkId) {
    return _mutex.protect(() async {
      final manifest = await _readManifestUnlocked(tripId);
      final matching =
          manifest.chunks.where((value) => value.chunkId == chunkId);
      if (matching.isEmpty) return;
      final file = File('${_requiredRoot.path}/${matching.first.relativePath}');
      if (await file.exists()) await file.delete();
    });
  }

  @override
  Future<int> pendingChunkCount(String tripId) async {
    final manifest = await readManifest(tripId);
    return manifest.chunks.where((value) {
      return value.uploadStatus != ChunkUploadStatus.uploaded;
    }).length;
  }

  Directory _tripDirectory(String tripId) =>
      Directory('${_requiredRoot.path}/trips/$tripId');

  File _manifestFile(String tripId) =>
      File('${_tripDirectory(tripId).path}/manifest.json');

  Future<TripManifest> _readManifestUnlocked(String tripId) =>
      _readManifestFile(_manifestFile(tripId));

  Future<TripManifest> _readManifestFile(File file) async {
    final decoded = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return TripManifest.fromJson(decoded.cast<String, Object?>());
  }

  Future<void> _writeManifest(TripManifest manifest) async {
    final file = _manifestFile(manifest.tripId);
    await file.parent.create(recursive: true);
    final encoded = const JsonEncoder.withIndent('  ').convert(manifest.toJson());
    await _atomicWriteString(file, encoded);
  }

  Future<void> _atomicWriteString(File file, String value) async {
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(value, flush: true);
    await _replace(temporary, file);
  }

  Future<void> _atomicWriteBytes(File file, List<int> value) async {
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes(value, flush: true);
    await _replace(temporary, file);
  }

  /// Renames over the destination so a crash never leaves it missing.
  ///
  /// POSIX rename replaces the destination atomically. On file systems where
  /// that fails, fall back to delete-then-rename.
  Future<void> _replace(File temporary, File file) async {
    try {
      await temporary.rename(file.path);
    } on FileSystemException {
      if (await file.exists()) await file.delete();
      await temporary.rename(file.path);
    }
  }
}

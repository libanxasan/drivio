import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../codec/payload_compression.dart';
import '../model/telemetry_chunk.dart';
import '../model/trip_manifest.dart';
import 'file_telemetry_store.dart';
import 'telemetry_store.dart';

/// SQLite-backed telemetry store.
///
/// Trips, chunk state and compressed payloads live in one database in WAL
/// mode, so every write is a single atomic transaction and pending uploads
/// come from an index instead of a scan of every trip. Several isolates (for
/// example the UI and a background sync task) can open the same file safely.
///
/// SQLite calls are synchronous but short: each operation touches a handful
/// of rows. Compression, the expensive part of a write, runs before the
/// database call and off the calling isolate for large payloads.
class SqliteTelemetryStore implements TelemetryStore {
  /// Creates a store. With no [rootDirectory], the database is created in
  /// the application support directory next to [FileTelemetryStore] data.
  SqliteTelemetryStore({
    Directory? rootDirectory,
    this.fileName = 'telemetry.db',
    this.compressor = const PayloadCompressor(),
  }) : _rootDirectoryOverride = rootDirectory;

  /// Database file name inside the `driving_telemetry` directory.
  final String fileName;

  /// Compresses payloads before they are written.
  final PayloadCompressor compressor;

  final Directory? _rootDirectoryOverride;
  Database? _database;
  Future<void>? _initializing;

  static const int _schemaVersion = 1;

  Database get _db {
    final database = _database;
    if (database == null) {
      throw StateError('SqliteTelemetryStore.initialize must be called first.');
    }
    return database;
  }

  /// Database path, available after [initialize].
  String get path => _db.select('PRAGMA database_list').first['file'] as String;

  @override
  Future<void> initialize() => _initializing ??= _open();

  Future<void> _open() async {
    try {
      final base =
          _rootDirectoryOverride ?? await getApplicationSupportDirectory();
      final root = Directory('${base.path}/driving_telemetry');
      await root.create(recursive: true);
      final database = sqlite3.open('${root.path}/$fileName');
      database.execute('PRAGMA journal_mode = WAL');
      database.execute('PRAGMA synchronous = NORMAL');
      database.execute('PRAGMA busy_timeout = 5000');
      database.execute('PRAGMA foreign_keys = ON');
      _migrate(database);
      _database = database;
    } catch (_) {
      _initializing = null;
      rethrow;
    }
  }

  void _migrate(Database database) {
    final version = database.userVersion;
    if (version > _schemaVersion) {
      throw StateError(
        'Telemetry database version $version is newer than this library.',
      );
    }
    if (version == _schemaVersion) return;
    _transaction(database, () {
      database.execute('''
        CREATE TABLE IF NOT EXISTS trips (
          trip_id TEXT PRIMARY KEY NOT NULL,
          user_id TEXT NOT NULL,
          started_at INTEGER NOT NULL,
          ended_at INTEGER,
          schema_version INTEGER NOT NULL,
          status TEXT NOT NULL,
          metadata TEXT NOT NULL
        )''');
      database.execute('''
        CREATE TABLE IF NOT EXISTS chunks (
          trip_id TEXT NOT NULL REFERENCES trips(trip_id) ON DELETE CASCADE,
          chunk_id TEXT NOT NULL,
          chunk_index INTEGER NOT NULL,
          type TEXT NOT NULL,
          started_at INTEGER NOT NULL,
          ended_at INTEGER NOT NULL,
          schema_version INTEGER NOT NULL,
          payload_format TEXT NOT NULL,
          byte_size INTEGER NOT NULL,
          checksum TEXT NOT NULL,
          upload_status TEXT NOT NULL,
          retry_count INTEGER NOT NULL DEFAULT 0,
          last_error TEXT,
          last_attempt_at INTEGER,
          payload BLOB,
          PRIMARY KEY (trip_id, chunk_id)
        )''');
      database.execute('''
        CREATE INDEX IF NOT EXISTS chunks_by_trip_index
          ON chunks (trip_id, chunk_index)''');
      database.execute('''
        CREATE INDEX IF NOT EXISTS chunks_pending
          ON chunks (trip_id, chunk_index)
          WHERE upload_status != 'uploaded' AND payload IS NOT NULL''');
      database.execute('''
        CREATE INDEX IF NOT EXISTS chunks_by_id ON chunks (chunk_id)''');
      database.execute('''
        CREATE INDEX IF NOT EXISTS trips_by_start ON trips (started_at)''');
      database.userVersion = _schemaVersion;
    });
  }

  static T _transaction<T>(Database database, T Function() action) {
    database.execute('BEGIN IMMEDIATE');
    try {
      final result = action();
      database.execute('COMMIT');
      return result;
    } catch (_) {
      database.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Closes the database. The store can be initialized again afterwards.
  Future<void> close() async {
    final pending = _initializing;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {
        // Nothing was opened.
      }
    }
    _database?.close();
    _database = null;
    _initializing = null;
  }

  @override
  Future<TripManifest> createTrip({
    required String tripId,
    required String userId,
    required int startedAtMillis,
    required int schemaVersion,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) async {
    _db.execute(
      '''INSERT INTO trips
         (trip_id, user_id, started_at, schema_version, status, metadata)
         VALUES (?, ?, ?, ?, 'recording', ?)''',
      <Object?>[tripId, userId, startedAtMillis, schemaVersion, jsonEncode(metadata)],
    );
    return TripManifest(
      tripId: tripId,
      userId: userId,
      startedAtMillis: startedAtMillis,
      schemaVersion: schemaVersion,
      status: 'recording',
      chunks: const <StoredTelemetryChunk>[],
      metadata: metadata,
    );
  }

  @override
  Future<StoredTelemetryChunk> writeChunk(
    TelemetryChunk chunk,
    Uint8List uncompressedBytes,
  ) async {
    return _insertChunk(
      tripId: chunk.tripId,
      chunkId: chunk.chunkId,
      chunkIndex: chunk.chunkIndex,
      type: chunk.type,
      startedAtMillis: chunk.startedAtMillis,
      endedAtMillis: chunk.endedAtMillis,
      schemaVersion: chunk.schemaVersion,
      payloadFormat: 'compact-binary',
      payload: await compressor.compress(uncompressedBytes),
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
  }) async {
    return _insertChunk(
      tripId: tripId,
      chunkId: chunkId,
      chunkIndex: chunkIndex,
      type: type,
      startedAtMillis: startedAtMillis,
      endedAtMillis: endedAtMillis,
      schemaVersion: schemaVersion,
      payloadFormat: 'json',
      payload: await compressor.compressJson(value),
    );
  }

  StoredTelemetryChunk _insertChunk({
    required String tripId,
    required String chunkId,
    required int chunkIndex,
    required TelemetryChunkType type,
    required int startedAtMillis,
    required int endedAtMillis,
    required int schemaVersion,
    required String payloadFormat,
    required CompressedPayload payload,
  }) {
    final stored = StoredTelemetryChunk(
      chunkId: chunkId,
      chunkIndex: chunkIndex,
      type: type,
      startedAtMillis: startedAtMillis,
      endedAtMillis: endedAtMillis,
      schemaVersion: schemaVersion,
      payloadFormat: payloadFormat,
      byteSize: payload.bytes.length,
      checksumSha256: payload.checksumSha256,
      relativePath: _relativePath(tripId, chunkId),
      uploadStatus: ChunkUploadStatus.pending,
    );
    _upsertChunk(tripId, stored, payload.bytes);
    return stored;
  }

  void _upsertChunk(
    String tripId,
    StoredTelemetryChunk chunk,
    Uint8List? payload,
  ) {
    _db.execute(
      '''INSERT OR REPLACE INTO chunks
         (trip_id, chunk_id, chunk_index, type, started_at, ended_at,
          schema_version, payload_format, byte_size, checksum, upload_status,
          retry_count, last_error, last_attempt_at, payload)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      <Object?>[
        tripId,
        chunk.chunkId,
        chunk.chunkIndex,
        chunk.type.name,
        chunk.startedAtMillis,
        chunk.endedAtMillis,
        chunk.schemaVersion,
        chunk.payloadFormat,
        chunk.byteSize,
        chunk.checksumSha256,
        chunk.uploadStatus.name,
        chunk.retryCount,
        chunk.lastError,
        chunk.lastAttemptAtMillis,
        payload,
      ],
    );
  }

  static String _relativePath(String tripId, String chunkId) =>
      'sqlite/$tripId/$chunkId';

  @override
  Future<void> closeTrip({
    required String tripId,
    required int endedAtMillis,
    Map<String, Object?> metadataUpdates = const <String, Object?>{},
  }) async {
    final database = _db;
    _transaction(database, () {
      final row = _tripRow(tripId);
      final metadata = <String, Object?>{
        ..._decodeMetadata(row['metadata'] as String),
        ...metadataUpdates,
      };
      database.execute(
        '''UPDATE trips SET ended_at = ?, status = 'closed', metadata = ?
           WHERE trip_id = ?''',
        <Object?>[endedAtMillis, jsonEncode(metadata), tripId],
      );
    });
  }

  Row _tripRow(String tripId) {
    final rows = _db.select(
      'SELECT * FROM trips WHERE trip_id = ?',
      <Object?>[tripId],
    );
    if (rows.isEmpty) {
      throw StateError('Unknown telemetry trip: $tripId.');
    }
    return rows.first;
  }

  @override
  Future<TripManifest> readManifest(String tripId) async {
    final row = _tripRow(tripId);
    final chunks = _db
        .select(
          '''SELECT * FROM chunks WHERE trip_id = ?
             ORDER BY chunk_index''',
          <Object?>[tripId],
        )
        .map(_chunkFromRow)
        .toList(growable: false);
    return _manifestFromRow(row, chunks);
  }

  @override
  Future<List<TripManifest>> listTrips() async {
    final chunksByTrip = <String, List<StoredTelemetryChunk>>{};
    for (final row in _db.select(
      'SELECT * FROM chunks ORDER BY trip_id, chunk_index',
    )) {
      (chunksByTrip[row['trip_id'] as String] ??= <StoredTelemetryChunk>[])
          .add(_chunkFromRow(row));
    }
    return _db
        .select('SELECT * FROM trips ORDER BY started_at DESC')
        .map((row) {
      return _manifestFromRow(
        row,
        chunksByTrip[row['trip_id'] as String] ??
            const <StoredTelemetryChunk>[],
      );
    }).toList(growable: false);
  }

  @override
  Future<List<PendingTelemetryChunk>> listPendingChunks() async {
    final metadataByTrip = <String, Map<String, Object?>>{};
    final rows = _db.select('''
      SELECT c.trip_id, c.chunk_id, c.chunk_index, c.type, c.started_at,
             c.ended_at, c.schema_version, c.payload_format, c.byte_size,
             c.checksum, c.upload_status, c.retry_count, c.last_error,
             c.last_attempt_at, t.user_id, t.metadata
      FROM chunks c
      JOIN trips t ON t.trip_id = c.trip_id
      WHERE c.upload_status != 'uploaded' AND c.payload IS NOT NULL
      ORDER BY c.trip_id, c.chunk_index''');
    return rows.map((row) {
      final tripId = row['trip_id'] as String;
      return PendingTelemetryChunk(
        tripId: tripId,
        userId: row['user_id'] as String,
        metadata: metadataByTrip[tripId] ??=
            _decodeMetadata(row['metadata'] as String),
        chunk: _chunkFromRow(row),
      );
    }).toList(growable: false);
  }

  @override
  Future<Uint8List> readStoredChunk(StoredTelemetryChunk chunk) async {
    final rows = _db.select(
      '''SELECT payload FROM chunks
         WHERE chunk_id = ? AND checksum = ? AND payload IS NOT NULL
         LIMIT 1''',
      <Object?>[chunk.chunkId, chunk.checksumSha256],
    );
    if (rows.isEmpty) {
      throw FileSystemException(
        'Telemetry payload is not stored.',
        chunk.relativePath,
      );
    }
    return rows.first['payload'] as Uint8List;
  }

  @override
  Future<void> markUploading(String tripId, String chunkId) async {
    _updateStatus(
      tripId,
      chunkId,
      '''upload_status = 'uploading', last_error = NULL,
         last_attempt_at = ?''',
      <Object?>[DateTime.now().millisecondsSinceEpoch],
    );
  }

  @override
  Future<void> markUploaded(String tripId, String chunkId) async {
    _updateStatus(
      tripId,
      chunkId,
      "upload_status = 'uploaded', last_error = NULL",
      const <Object?>[],
    );
  }

  @override
  Future<void> markFailed(String tripId, String chunkId, String error) async {
    _updateStatus(
      tripId,
      chunkId,
      '''upload_status = 'failed', retry_count = retry_count + 1,
         last_error = ?, last_attempt_at = ?''',
      <Object?>[error, DateTime.now().millisecondsSinceEpoch],
    );
  }

  /// Uploaded chunks keep their state, matching [FileTelemetryStore].
  void _updateStatus(
    String tripId,
    String chunkId,
    String assignments,
    List<Object?> parameters,
  ) {
    _db.execute(
      '''UPDATE chunks SET $assignments
         WHERE trip_id = ? AND chunk_id = ? AND upload_status != 'uploaded' ''',
      <Object?>[...parameters, tripId, chunkId],
    );
  }

  @override
  Future<void> deleteChunkFile(String tripId, String chunkId) async {
    _db.execute(
      'UPDATE chunks SET payload = NULL WHERE trip_id = ? AND chunk_id = ?',
      <Object?>[tripId, chunkId],
    );
  }

  @override
  Future<int> pendingChunkCount(String tripId) async {
    final rows = _db.select(
      '''SELECT COUNT(*) AS count FROM chunks
         WHERE trip_id = ? AND upload_status != 'uploaded' ''',
      <Object?>[tripId],
    );
    return rows.first['count'] as int;
  }

  /// Copies trips and chunks from a [FileTelemetryStore] rooted at
  /// [rootDirectory] (the application support directory by default).
  ///
  /// Trips already in the database are skipped, so the import can be run on
  /// every start until [deleteImported] removes the old files. Upload state
  /// is preserved. Returns the number of trips imported.
  Future<int> importFileStore({
    Directory? rootDirectory,
    bool deleteImported = false,
  }) async {
    final base = rootDirectory ??
        _rootDirectoryOverride ??
        await getApplicationSupportDirectory();
    final tripsDirectory = Directory('${base.path}/driving_telemetry/trips');
    if (!await tripsDirectory.exists()) return 0;
    final source = FileTelemetryStore(rootDirectory: base);
    await source.initialize();

    var imported = 0;
    for (final manifest in await source.listTrips()) {
      final exists = _db.select(
        'SELECT 1 FROM trips WHERE trip_id = ?',
        <Object?>[manifest.tripId],
      ).isNotEmpty;
      if (!exists) {
        final payloads = <String, Uint8List?>{};
        for (final chunk in manifest.chunks) {
          try {
            payloads[chunk.chunkId] = await source.readStoredChunk(chunk);
          } on FileSystemException {
            payloads[chunk.chunkId] = null;
          }
        }
        _transaction(_db, () {
          _db.execute(
            '''INSERT INTO trips (trip_id, user_id, started_at, ended_at,
               schema_version, status, metadata) VALUES (?, ?, ?, ?, ?, ?, ?)''',
            <Object?>[
              manifest.tripId,
              manifest.userId,
              manifest.startedAtMillis,
              manifest.endedAtMillis,
              manifest.schemaVersion,
              manifest.status,
              jsonEncode(manifest.metadata),
            ],
          );
          for (final chunk in manifest.chunks) {
            _upsertChunk(manifest.tripId, chunk, payloads[chunk.chunkId]);
          }
        });
        imported++;
      }
      if (deleteImported) {
        await Directory('${tripsDirectory.path}/${manifest.tripId}')
            .delete(recursive: true);
      }
    }
    return imported;
  }

  static Map<String, Object?> _decodeMetadata(String value) =>
      (jsonDecode(value) as Map<String, dynamic>).cast<String, Object?>();

  static TripManifest _manifestFromRow(
    Row row,
    List<StoredTelemetryChunk> chunks,
  ) {
    return TripManifest(
      tripId: row['trip_id'] as String,
      userId: row['user_id'] as String,
      startedAtMillis: row['started_at'] as int,
      endedAtMillis: row['ended_at'] as int?,
      schemaVersion: row['schema_version'] as int,
      status: row['status'] as String,
      chunks: chunks,
      metadata: _decodeMetadata(row['metadata'] as String),
    );
  }

  static StoredTelemetryChunk _chunkFromRow(Row row) {
    return StoredTelemetryChunk(
      chunkId: row['chunk_id'] as String,
      chunkIndex: row['chunk_index'] as int,
      type: TelemetryChunkType.values.byName(row['type'] as String),
      startedAtMillis: row['started_at'] as int,
      endedAtMillis: row['ended_at'] as int,
      schemaVersion: row['schema_version'] as int,
      payloadFormat: row['payload_format'] as String,
      byteSize: row['byte_size'] as int,
      checksumSha256: row['checksum'] as String,
      relativePath: _relativePath(
        row['trip_id'] as String,
        row['chunk_id'] as String,
      ),
      uploadStatus:
          ChunkUploadStatus.values.byName(row['upload_status'] as String),
      retryCount: row['retry_count'] as int,
      lastError: row['last_error'] as String?,
      lastAttemptAtMillis: row['last_attempt_at'] as int?,
    );
  }
}

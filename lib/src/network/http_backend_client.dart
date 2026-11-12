import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../storage/telemetry_store.dart';
import 'backend_client.dart';

/// HTTP backend client using an idempotent binary upload endpoint.
class HttpTelemetryBackendClient implements TelemetryBackendClient {
  /// Creates an HTTP client.
  HttpTelemetryBackendClient({
    required this.endpoint,
    this.authorizationTokenProvider,
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
    this.additionalHeaders = const <String, String>{},
  }) : _client = client ?? http.Client();

  /// Binary chunk upload endpoint.
  final Uri endpoint;

  /// Optional bearer-token callback.
  final Future<String?> Function()? authorizationTokenProvider;

  /// Request timeout.
  final Duration timeout;

  /// Additional request headers.
  final Map<String, String> additionalHeaders;

  final http.Client _client;

  @override
  Future<TelemetryUploadReceipt> uploadChunk({
    required PendingTelemetryChunk pending,
    required Uint8List compressedBytes,
  }) async {
    final token = await authorizationTokenProvider?.call();
    final chunk = pending.chunk;
    final response = await _client
        .post(
          endpoint,
          headers: <String, String>{
            'content-type': 'application/octet-stream',
            'content-encoding': 'gzip',
            'idempotency-key': '${pending.tripId}:${chunk.chunkId}',
            'x-trip-id': pending.tripId,
            'x-user-id': pending.userId,
            'x-chunk-id': chunk.chunkId,
            'x-chunk-index': '${chunk.chunkIndex}',
            'x-chunk-type': chunk.type.name,
            'x-schema-version': '${chunk.schemaVersion}',
            'x-payload-format': chunk.payloadFormat,
            'x-checksum-sha256': chunk.checksumSha256,
            'x-started-at-ms': '${chunk.startedAtMillis}',
            'x-ended-at-ms': '${chunk.endedAtMillis}',
            if (token != null && token.isNotEmpty)
              'authorization': 'Bearer $token',
            ...additionalHeaders,
          },
          body: compressedBytes,
        )
        .timeout(timeout);

    final rawBody = response.body;
    Map<String, dynamic>? body;
    if (rawBody.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawBody);
        if (decoded is Map<String, dynamic>) body = decoded;
      } on FormatException {
        body = null;
      }
    }

    // Keep the empty 409 acknowledgement used by older integrations. A 409
    // with a body needs a duplicate receipt, since it can be a checksum error.
    if (response.statusCode == 409 &&
        (rawBody.trim().isEmpty ||
            (body?['alreadyExisted'] == true &&
                (body?['accepted'] ?? true) == true))) {
      return TelemetryUploadReceipt(
        accepted: true,
        alreadyExisted: true,
        backendChunkId: body?['chunkId']?.toString(),
        message: body?['message']?.toString(),
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw TelemetryUploadException(
        statusCode: response.statusCode,
        message: body?['message']?.toString() ?? rawBody,
      );
    }

    return TelemetryUploadReceipt(
      accepted: body?['accepted'] as bool? ?? true,
      alreadyExisted: body?['alreadyExisted'] as bool? ?? false,
      backendChunkId: body?['chunkId']?.toString(),
      message: body?['message']?.toString(),
    );
  }

  /// Closes the underlying HTTP client.
  void close() => _client.close();
}

/// HTTP upload failure.
class TelemetryUploadException implements Exception {
  /// Creates an upload exception.
  const TelemetryUploadException({
    required this.statusCode,
    required this.message,
  });

  /// HTTP status code.
  final int statusCode;

  /// Backend response or error message.
  final String message;

  @override
  String toString() => 'TelemetryUploadException($statusCode): $message';
}

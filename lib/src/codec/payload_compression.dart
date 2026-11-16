import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// A gzip payload and the SHA-256 checksum of its compressed bytes.
class CompressedPayload {
  /// Creates a compressed payload.
  const CompressedPayload({
    required this.bytes,
    required this.checksumSha256,
  });

  /// Gzip bytes.
  final Uint8List bytes;

  /// Lowercase hex SHA-256 of [bytes].
  final String checksumSha256;
}

/// Compresses chunk payloads off the calling isolate.
///
/// gzip and SHA-256 over a full chunk take long enough to drop UI frames on
/// slower phones, so payloads at or above [isolateThresholdBytes] are
/// processed with [Isolate.run]. Smaller payloads are handled inline because
/// spawning an isolate costs more than compressing them.
class PayloadCompressor {
  /// Creates a compressor.
  const PayloadCompressor({this.isolateThresholdBytes = 16 * 1024});

  /// Payload size from which work moves to a background isolate.
  /// Set to 0 to always use an isolate.
  final int isolateThresholdBytes;

  /// Compresses already encoded bytes.
  Future<CompressedPayload> compress(Uint8List uncompressed) {
    if (uncompressed.length < isolateThresholdBytes) {
      return Future<CompressedPayload>.value(_compress(uncompressed));
    }
    return Isolate.run(() => _compress(uncompressed));
  }

  /// JSON-encodes [value] and compresses it.
  Future<CompressedPayload> compressJson(Map<String, Object?> value) =>
      compress(Uint8List.fromList(utf8.encode(jsonEncode(value))));

  static CompressedPayload _compress(Uint8List uncompressed) {
    final bytes = Uint8List.fromList(gzip.encode(uncompressed));
    return CompressedPayload(
      bytes: bytes,
      checksumSha256: sha256.convert(bytes).toString(),
    );
  }
}

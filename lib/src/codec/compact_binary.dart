import 'dart:convert';
import 'dart:typed_data';

/// Compact binary writer using unsigned and ZigZag varints.
class CompactBinaryWriter {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  /// Writes raw bytes.
  void writeBytes(List<int> value) => _builder.add(value);

  /// Writes one byte.
  void writeByte(int value) => _builder.addByte(value & 0xff);

  /// Writes an unsigned variable-length integer.
  void writeVarUint(int value) {
    if (value < 0) throw ArgumentError.value(value, 'value');
    var remaining = value;
    while (remaining >= 0x80) {
      writeByte((remaining & 0x7f) | 0x80);
      remaining >>= 7;
    }
    writeByte(remaining);
  }

  /// Writes a signed integer using ZigZag encoding.
  void writeVarInt(int value) {
    final zigzag = value >= 0 ? value * 2 : (-value * 2) - 1;
    writeVarUint(zigzag);
  }

  /// Writes a UTF-8 string prefixed by its byte length.
  void writeString(String value) {
    final bytes = utf8.encode(value);
    writeVarUint(bytes.length);
    writeBytes(bytes);
  }

  /// Returns the accumulated bytes.
  Uint8List takeBytes() => _builder.takeBytes();
}

/// Compact binary reader matching [CompactBinaryWriter].
class CompactBinaryReader {
  /// Creates a reader.
  CompactBinaryReader(this.bytes);

  /// Encoded bytes.
  final Uint8List bytes;

  int _offset = 0;

  /// Current read offset.
  int get offset => _offset;

  /// Whether all bytes have been consumed.
  bool get isAtEnd => _offset >= bytes.length;

  /// Reads one byte.
  int readByte() {
    if (_offset >= bytes.length) {
      throw const FormatException('Unexpected end of compact binary payload.');
    }
    return bytes[_offset++];
  }

  /// Reads raw bytes.
  Uint8List readBytes(int length) {
    if (length < 0 || _offset + length > bytes.length) {
      throw const FormatException('Invalid compact binary byte length.');
    }
    final value = Uint8List.sublistView(bytes, _offset, _offset + length);
    _offset += length;
    return value;
  }

  /// Reads an unsigned variable-length integer.
  int readVarUint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (shift > 63) {
        throw const FormatException('Varint is too long.');
      }
      final byte = readByte();
      result |= (byte & 0x7f) << shift;
      if ((byte & 0x80) == 0) return result;
      shift += 7;
    }
  }

  /// Reads a ZigZag-encoded signed integer.
  int readVarInt() {
    final zigzag = readVarUint();
    return (zigzag & 1) == 0 ? zigzag >> 1 : -((zigzag + 1) >> 1);
  }

  /// Reads a length-prefixed UTF-8 string.
  String readString() {
    final length = readVarUint();
    return utf8.decode(readBytes(length));
  }
}

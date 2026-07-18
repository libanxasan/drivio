import 'dart:math' as math;

/// Immutable three-dimensional value.
class Vector3Value {
  /// Creates a vector.
  const Vector3Value(this.x, this.y, this.z);

  /// Zero vector.
  static const zero = Vector3Value(0, 0, 0);

  /// X-axis value.
  final double x;

  /// Y-axis value.
  final double y;

  /// Z-axis value.
  final double z;

  /// Euclidean magnitude.
  double get magnitude => math.sqrt((x * x) + (y * y) + (z * z));

  /// Adds another vector.
  Vector3Value operator +(Vector3Value other) =>
      Vector3Value(x + other.x, y + other.y, z + other.z);

  /// Subtracts another vector.
  Vector3Value operator -(Vector3Value other) =>
      Vector3Value(x - other.x, y - other.y, z - other.z);

  /// Multiplies by a scalar.
  Vector3Value operator *(double scalar) =>
      Vector3Value(x * scalar, y * scalar, z * scalar);

  /// JSON representation.
  Map<String, Object> toJson() => <String, Object>{
        'x': x,
        'y': y,
        'z': z,
      };
}

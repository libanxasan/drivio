/// Street or place context returned by MapTiler or a backend provider.
class StreetContext {
  /// Creates street context.
  const StreetContext({
    this.featureId,
    this.name,
    this.placeName,
    this.roadClass,
    this.properties = const <String, Object?>{},
  });

  /// Provider feature identifier.
  final String? featureId;

  /// Short street or place name.
  final String? name;

  /// Full place label.
  final String? placeName;

  /// Optional road classification.
  final String? roadClass;

  /// Provider-specific properties.
  final Map<String, Object?> properties;
}

// Typed readers for decoded JSON. A missing or mistyped required field
// throws a FormatException naming the field, instead of a cast error deep
// in a model constructor.

/// A JSON object.
typedef JsonMap = Map<String, Object?>;

/// Reads [value] as a JSON object or throws a [FormatException].
JsonMap asJsonMap(Object? value, [String what = 'response']) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) return value.cast<String, Object?>();
  throw FormatException('Expected a JSON object for $what, got '
      '${value == null ? 'null' : value.runtimeType}.');
}

/// Reads [value] as a JSON array or throws a [FormatException].
List<Object?> asJsonList(Object? value, [String what = 'response']) {
  if (value is List) return value.cast<Object?>();
  throw FormatException('Expected a JSON array for $what, got '
      '${value == null ? 'null' : value.runtimeType}.');
}

Never _missing(String key, Object? value, String type) =>
    throw FormatException(value == null
        ? 'Missing required field "$key".'
        : 'Field "$key" is not $type: $value.');

/// A required string field.
String reqString(JsonMap json, String key) {
  final value = json[key];
  if (value is String) return value;
  _missing(key, value, 'a string');
}

/// An optional string field (`null` when absent or JSON null).
String? optString(JsonMap json, String key) {
  final value = json[key];
  if (value == null || value is String) return value as String?;
  _missing(key, value, 'a string');
}

/// A required integer field (a whole JSON number).
int reqInt(JsonMap json, String key) {
  final value = json[key];
  if (value is int) return value;
  if (value is double && value == value.truncateToDouble()) {
    return value.toInt();
  }
  _missing(key, value, 'an integer');
}

/// An optional integer field.
int? optInt(JsonMap json, String key) =>
    json[key] == null ? null : reqInt(json, key);

/// A required number field.
double reqDouble(JsonMap json, String key) {
  final value = json[key];
  if (value is num) return value.toDouble();
  _missing(key, value, 'a number');
}

/// An optional number field.
double? optDouble(JsonMap json, String key) =>
    json[key] == null ? null : reqDouble(json, key);

/// An optional boolean field.
bool? optBool(JsonMap json, String key) {
  final value = json[key];
  if (value == null || value is bool) return value as bool?;
  _missing(key, value, 'a boolean');
}

/// An optional list of strings (`[]` when absent or JSON null).
List<String> stringList(JsonMap json, String key) {
  final value = json[key];
  if (value == null) return const [];
  if (value is List) {
    return [
      for (final item in value)
        if (item is String) item else _missing(key, item, 'a string list'),
    ];
  }
  _missing(key, value, 'a list');
}

/// Puts [value] under [key] unless it is null.
void putIfNotNull(JsonMap json, String key, Object? value) {
  if (value != null) json[key] = value;
}

import 'json.dart';

/// A per-project pronunciation dictionary.
class Dictionary {
  /// Creates a dictionary.
  const Dictionary({
    required this.id,
    required this.projectId,
    required this.name,
    this.description,
    this.language,
    this.isActive = true,
    this.createdAt,
    this.updatedAt,
  });

  /// Parses a dictionary.
  factory Dictionary.fromJson(JsonMap json) => Dictionary(
        id: reqInt(json, 'id'),
        projectId: reqInt(json, 'project_id'),
        name: reqString(json, 'name'),
        description: optString(json, 'description'),
        language: optString(json, 'language'),
        isActive: optBool(json, 'is_active') ?? true,
        createdAt: optString(json, 'created_at'),
        updatedAt: optString(json, 'updated_at'),
      );

  /// Dictionary id, for `dictionaryIds`.
  final int id;

  /// The project it belongs to.
  final int projectId;

  /// Name, unique in the project.
  final String name;

  /// Description, if any.
  final String? description;

  /// ISO 639-1 language filter, if any.
  final String? language;

  /// Whether it applies by default.
  final bool isActive;

  /// Creation time (ISO 8601), if reported.
  final String? createdAt;

  /// Last update time (ISO 8601), if reported.
  final String? updatedAt;

  /// The JSON form of this dictionary.
  JsonMap toJson() {
    final json = <String, Object?>{
      'id': id,
      'project_id': projectId,
      'name': name,
      'is_active': isActive,
    };
    putIfNotNull(json, 'description', description);
    putIfNotNull(json, 'language', language);
    putIfNotNull(json, 'created_at', createdAt);
    putIfNotNull(json, 'updated_at', updatedAt);
    return json;
  }
}

/// One word-to-replacement (or IPA) mapping in a dictionary.
class DictionaryEntry {
  /// Creates an entry.
  const DictionaryEntry({
    required this.id,
    required this.dictionaryId,
    required this.word,
    required this.replacement,
    this.ipa,
    this.caseSensitive = false,
    this.createdAt,
    this.updatedAt,
  });

  /// Parses an entry.
  factory DictionaryEntry.fromJson(JsonMap json) => DictionaryEntry(
        id: reqInt(json, 'id'),
        dictionaryId: reqInt(json, 'dictionary_id'),
        word: reqString(json, 'word'),
        replacement: reqString(json, 'replacement'),
        ipa: optString(json, 'ipa'),
        caseSensitive: optBool(json, 'case_sensitive') ?? false,
        createdAt: optString(json, 'created_at'),
        updatedAt: optString(json, 'updated_at'),
      );

  /// Entry id.
  final int id;

  /// The dictionary it belongs to.
  final int dictionaryId;

  /// The word to match.
  final String word;

  /// What is spoken instead.
  final String replacement;

  /// IPA pronunciation, if any.
  final String? ipa;

  /// Whether [word] matches case-sensitively.
  final bool caseSensitive;

  /// Creation time (ISO 8601), if reported.
  final String? createdAt;

  /// Last update time (ISO 8601), if reported.
  final String? updatedAt;

  /// The JSON form of this entry.
  JsonMap toJson() {
    final json = <String, Object?>{
      'id': id,
      'dictionary_id': dictionaryId,
      'word': word,
      'replacement': replacement,
      'case_sensitive': caseSensitive,
    };
    putIfNotNull(json, 'ipa', ipa);
    putIfNotNull(json, 'created_at', createdAt);
    putIfNotNull(json, 'updated_at', updatedAt);
    return json;
  }
}

/// An entry to write with `dictionaries.entries.replaceAll`.
class DictionaryEntryInput {
  /// Creates an entry input.
  const DictionaryEntryInput({
    required this.word,
    required this.replacement,
    this.ipa,
    this.caseSensitive,
  });

  /// The word to match.
  final String word;

  /// What is spoken instead.
  final String replacement;

  /// IPA pronunciation, if any.
  final String? ipa;

  /// Whether [word] matches case-sensitively; server default when `null`.
  final bool? caseSensitive;

  /// The JSON form of this input.
  JsonMap toJson() {
    final json = <String, Object?>{'word': word, 'replacement': replacement};
    putIfNotNull(json, 'ipa', ipa);
    putIfNotNull(json, 'case_sensitive', caseSensitive);
    return json;
  }
}

/// A page of dictionary entries.
class DictionaryEntryList {
  /// Creates a page.
  const DictionaryEntryList({
    required this.entries,
    required this.total,
    required this.limit,
    required this.offset,
  });

  /// Parses the entries list response.
  factory DictionaryEntryList.fromJson(JsonMap json) => DictionaryEntryList(
        entries: [
          for (final e in asJsonList(json['entries'] ?? const [], 'entries'))
            DictionaryEntry.fromJson(asJsonMap(e, 'entry')),
        ],
        total: reqInt(json, 'total'),
        limit: reqInt(json, 'limit'),
        offset: reqInt(json, 'offset'),
      );

  /// The entries on this page.
  final List<DictionaryEntry> entries;

  /// Number of matching entries across all pages.
  final int total;

  /// Page size.
  final int limit;

  /// Offset of this page.
  final int offset;

  /// The JSON form of this page.
  JsonMap toJson() => {
        'entries': [for (final e in entries) e.toJson()],
        'total': total,
        'limit': limit,
        'offset': offset,
      };
}

/// Counts returned by `dictionaries.entries.replaceAll`.
class BulkReplaceResult {
  /// Creates a result.
  const BulkReplaceResult({
    required this.upserted,
    required this.deleted,
    required this.total,
  });

  /// Parses the replace-all response.
  factory BulkReplaceResult.fromJson(JsonMap json) => BulkReplaceResult(
        upserted: reqInt(json, 'upserted'),
        deleted: reqInt(json, 'deleted'),
        total: reqInt(json, 'total'),
      );

  /// Entries created or updated.
  final int upserted;

  /// Entries removed.
  final int deleted;

  /// Entries in the dictionary afterwards.
  final int total;

  /// The JSON form of this result.
  JsonMap toJson() =>
      {'upserted': upserted, 'deleted': deleted, 'total': total};
}

import '../http_transport.dart';
import '../models/dictionaries.dart';
import '../models/json.dart';

Map<String, String>? _project(int? projectId) =>
    projectId == null ? null : {'project_id': '$projectId'};

/// `client.dictionaries`: per-project pronunciation dictionaries.
///
/// The TTS cache is invalidated after every change, so the next synthesis
/// picks it up at once. `projectId` is only needed with a key that is not
/// bound to a project.
///
/// ```dart
/// final d = await client.dictionaries.create(name: 'Brand names');
/// await client.dictionaries.entries
///     .add(d.id, word: 'K8s', replacement: 'kubernetes');
/// ```
class DictionariesResource {
  /// Creates the resource on [transport].
  DictionariesResource(this._transport)
      : entries = DictionaryEntriesResource(_transport);

  final HttpTransport _transport;

  /// The entries of each dictionary.
  final DictionaryEntriesResource entries;

  /// Lists every dictionary of the project.
  Future<List<Dictionary>> list({int? projectId}) async {
    final json = asJsonMap(await _transport.json('GET', '/v1/dictionaries',
        query: _project(projectId)));
    return [
      for (final d
          in asJsonList(json['dictionaries'] ?? const [], 'dictionaries'))
        Dictionary.fromJson(asJsonMap(d, 'dictionary')),
    ];
  }

  /// Creates a dictionary.
  Future<Dictionary> create({
    required String name,
    String? description,
    String? language,
    int? projectId,
  }) async {
    final body = <String, Object?>{'name': name};
    putIfNotNull(body, 'description', description);
    putIfNotNull(body, 'language', language);
    return Dictionary.fromJson(asJsonMap(await _transport.json(
        'POST', '/v1/dictionaries',
        query: _project(projectId), body: body)));
  }

  /// Gets one dictionary.
  Future<Dictionary> get(int dictionaryId, {int? projectId}) async =>
      Dictionary.fromJson(asJsonMap(await _transport.json(
          'GET', '/v1/dictionaries/$dictionaryId',
          query: _project(projectId))));

  /// Updates name, description, language or active state; only the given
  /// fields change.
  Future<Dictionary> update(
    int dictionaryId, {
    String? name,
    String? description,
    String? language,
    bool? isActive,
    int? projectId,
  }) async {
    final body = <String, Object?>{};
    putIfNotNull(body, 'name', name);
    putIfNotNull(body, 'description', description);
    putIfNotNull(body, 'language', language);
    putIfNotNull(body, 'is_active', isActive);
    return Dictionary.fromJson(asJsonMap(await _transport.json(
        'PATCH', '/v1/dictionaries/$dictionaryId',
        query: _project(projectId), body: body)));
  }

  /// Deletes a dictionary and its entries.
  Future<void> delete(int dictionaryId, {int? projectId}) async {
    await _transport.json('DELETE', '/v1/dictionaries/$dictionaryId',
        query: _project(projectId));
  }
}

/// `client.dictionaries.entries`: the entries of one dictionary.
class DictionaryEntriesResource {
  /// Creates the resource on [transport].
  DictionaryEntriesResource(this._transport);

  final HttpTransport _transport;

  /// Lists entries, optionally filtered by a case-insensitive [search] on
  /// the word; [limit] is 1-500.
  Future<DictionaryEntryList> list(
    int dictionaryId, {
    String? search,
    int limit = 100,
    int offset = 0,
    int? projectId,
  }) async {
    final query = <String, String>{
      'limit': '$limit',
      'offset': '$offset',
      if (search != null) 'search': search,
      if (projectId != null) 'project_id': '$projectId',
    };
    return DictionaryEntryList.fromJson(asJsonMap(await _transport
        .json('GET', '/v1/dictionaries/$dictionaryId/entries', query: query)));
  }

  /// Adds one entry.
  Future<DictionaryEntry> add(
    int dictionaryId, {
    required String word,
    required String replacement,
    String? ipa,
    bool caseSensitive = false,
    int? projectId,
  }) async {
    final body = <String, Object?>{
      'word': word,
      'replacement': replacement,
      'case_sensitive': caseSensitive,
    };
    putIfNotNull(body, 'ipa', ipa);
    return DictionaryEntry.fromJson(asJsonMap(await _transport.json(
        'POST', '/v1/dictionaries/$dictionaryId/entries',
        query: _project(projectId), body: body)));
  }

  /// Updates one entry; only the given fields change.
  Future<DictionaryEntry> update(
    int dictionaryId,
    int entryId, {
    String? word,
    String? replacement,
    String? ipa,
    bool? caseSensitive,
    int? projectId,
  }) async {
    final body = <String, Object?>{};
    putIfNotNull(body, 'word', word);
    putIfNotNull(body, 'replacement', replacement);
    putIfNotNull(body, 'ipa', ipa);
    putIfNotNull(body, 'case_sensitive', caseSensitive);
    return DictionaryEntry.fromJson(asJsonMap(await _transport.json(
        'PATCH', '/v1/dictionaries/$dictionaryId/entries/$entryId',
        query: _project(projectId), body: body)));
  }

  /// Deletes one entry.
  Future<void> delete(int dictionaryId, int entryId, {int? projectId}) async {
    await _transport.json(
        'DELETE', '/v1/dictionaries/$dictionaryId/entries/$entryId',
        query: _project(projectId));
  }

  /// Atomically replaces every entry with [entries]: words not in the list
  /// are deleted. Idempotent, for syncing from another source.
  Future<BulkReplaceResult> replaceAll(
    int dictionaryId,
    List<DictionaryEntryInput> entries, {
    int? projectId,
  }) async =>
      BulkReplaceResult.fromJson(asJsonMap(await _transport.json(
          'PUT', '/v1/dictionaries/$dictionaryId/entries',
          query: _project(projectId),
          body: {
            'entries': [for (final e in entries) e.toJson()],
          })));
}

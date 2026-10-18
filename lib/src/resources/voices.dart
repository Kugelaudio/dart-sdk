import 'dart:convert';

import 'package:http/http.dart' as http;

import '../audio.dart';
import '../http_transport.dart';
import '../models/json.dart';
import '../models/voices.dart';

final _json = http.MediaType('application', 'json');
final _text = http.MediaType('text', 'plain', {'charset': 'utf-8'});
final _wav = http.MediaType('audio', 'wav');

http.MultipartFile _field(String name, String value, [http.MediaType? type]) =>
    http.MultipartFile.fromString(name, value, contentType: type ?? _text);

http.MultipartFile _file(String name, Audio audio) =>
    http.MultipartFile.fromBytes(name, audio.data,
        filename: audio.filename, contentType: _wav);

/// `client.voices`: list, inspect and manage voices.
class VoicesResource {
  /// Creates the resource on [transport].
  VoicesResource(this._transport);

  final HttpTransport _transport;

  /// Lists voices (`GET /v1/voices`).
  ///
  /// [language] filters by ISO 639-1 code (e.g. `de`); [includePublic]
  /// includes public voices besides your own; [limit] (at most 100) and
  /// [offset] page through the results.
  Future<VoiceListResponse> list({
    String? language,
    bool includePublic = true,
    int limit = 20,
    int offset = 0,
  }) async {
    final query = <String, String>{
      'limit': '$limit',
      'offset': '$offset',
      if (language != null && language.isNotEmpty) 'language': language,
      if (includePublic) 'include_public': 'true',
    };
    final json = await _transport.json('GET', '/v1/voices', query: query);
    return VoiceListResponse.fromJson(asJsonMap(json));
  }

  /// Gets one voice (`GET /v1/voices/{id}`).
  Future<VoiceDetail> get(int voiceId) async => VoiceDetail.fromJson(
      asJsonMap(await _transport.json('GET', '/v1/voices/$voiceId')));

  /// Creates a voice (`POST /v1/voices`, multipart).
  ///
  /// [speakerConsent] must be `true`: it confirms you are the speaker of the
  /// recordings or have the speaker's permission to create a synthetic voice
  /// from them; the API rejects the request otherwise. [referenceFiles] are
  /// optional reference recordings to upload with the voice.
  Future<VoiceDetail> create({
    required String name,
    required String sex,
    required bool speakerConsent,
    String description = '',
    String category = 'conversational',
    String age = 'middle_age',
    String quality = 'mid',
    List<String> supportedLanguages = const ['en'],
    bool isPublic = false,
    String sampleText = '',
    List<Audio> referenceFiles = const [],
  }) async {
    final metadata = {
      'name': name,
      'sex': sex,
      'description': description,
      'category': category,
      'age': age,
      'quality': quality,
      'supported_languages': supportedLanguages,
      'is_public': isPublic,
      'sample_text': sampleText,
      'speaker_consent': speakerConsent,
    };
    final parts = [
      _field('metadata', jsonEncode(metadata), _json),
      for (final file in referenceFiles) _file('files', file),
    ];
    final json = await _transport.multipart('POST', '/v1/voices', parts);
    return VoiceDetail.fromJson(asJsonMap(json));
  }

  /// Updates a voice (`PATCH /v1/voices/{id}`); only the given fields
  /// change.
  Future<VoiceDetail> update(
    int voiceId, {
    String? name,
    String? description,
    String? category,
    String? age,
    String? sex,
    String? quality,
    List<String>? supportedLanguages,
    bool? isPublic,
    String? sampleText,
  }) async {
    final body = <String, Object?>{};
    putIfNotNull(body, 'name', name);
    putIfNotNull(body, 'description', description);
    putIfNotNull(body, 'category', category);
    putIfNotNull(body, 'age', age);
    putIfNotNull(body, 'sex', sex);
    putIfNotNull(body, 'quality', quality);
    putIfNotNull(body, 'supported_languages', supportedLanguages);
    putIfNotNull(body, 'is_public', isPublic);
    putIfNotNull(body, 'sample_text', sampleText);
    final json =
        await _transport.json('PATCH', '/v1/voices/$voiceId', body: body);
    return VoiceDetail.fromJson(asJsonMap(json));
  }

  /// Deletes a voice (`DELETE /v1/voices/{id}`).
  Future<void> delete(int voiceId) async {
    await _transport.json('DELETE', '/v1/voices/$voiceId');
  }

  /// Lists a voice's reference recordings.
  Future<List<VoiceReference>> listReferences(int voiceId) async {
    final path = '/v1/voices/$voiceId/references';
    final json = await _transport.json('GET', path);
    return [
      for (final r in asJsonList(json, 'GET $path'))
        VoiceReference.fromJson(asJsonMap(r, 'reference')),
    ];
  }

  /// Uploads a reference recording to a voice.
  ///
  /// [speakerConsent] must be `true` (see [create]); [referenceText] is the
  /// transcript of the recording.
  Future<VoiceReference> addReference(
    int voiceId,
    Audio file, {
    required bool speakerConsent,
    String referenceText = '',
  }) async {
    final parts = [
      _file('file', file),
      _field('speaker_consent', speakerConsent ? 'true' : 'false'),
      if (referenceText.isNotEmpty) _field('reference_text', referenceText),
    ];
    final json = await _transport.multipart(
        'POST', '/v1/voices/$voiceId/references', parts);
    return VoiceReference.fromJson(asJsonMap(json));
  }

  /// Deletes a reference recording.
  Future<void> deleteReference(int voiceId, int referenceId) async {
    await _transport.json(
        'DELETE', '/v1/voices/$voiceId/references/$referenceId');
  }

  /// Requests publication: the voice becomes public once an admin verified
  /// it.
  Future<VoiceDetail> publish(int voiceId) async => VoiceDetail.fromJson(
      asJsonMap(await _transport.json('POST', '/v1/voices/$voiceId/publish')));

  /// Generates the voice's preview sample from its sample text (it needs
  /// at least one reference).
  Future<GeneratedSample> generateSample(int voiceId) async =>
      GeneratedSample.fromJson(asJsonMap(await _transport.json(
          'POST', '/v1/voices/$voiceId/generate-sample')));
}

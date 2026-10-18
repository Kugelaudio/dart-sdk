import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kugelaudio/kugelaudio.dart';
import 'package:test/test.dart';

/// A client whose HTTP calls go to [handler]; every request is recorded.
(KugelAudio, List<http.Request>) mockClient(
  FutureOr<http.Response> Function(http.Request request) handler, {
  Duration timeout = const Duration(seconds: 5),
}) {
  final seen = <http.Request>[];
  final client = KugelAudio(
    apiKey: 'eu-sk-kug-proj_test',
    apiUrl: 'https://api.test',
    telemetry: false,
    timeout: timeout,
    httpClient: MockClient((request) async {
      seen.add(request);
      return handler(request);
    }),
  );
  return (client, seen);
}

http.Response jsonResponse(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});

void main() {
  test('every request carries the auth and SDK headers', () async {
    final (client, seen) =
        mockClient((_) => jsonResponse({'models': <Object?>[]}));
    await client.models.list();
    final headers = seen.single.headers;
    expect(headers['Authorization'], 'Bearer sk-kug-proj_test');
    expect(headers['X-API-Key'], 'sk-kug-proj_test');
    expect(headers['X-KugelAudio-SDK'], 'dart');
    expect(headers['X-KugelAudio-SDK-Version'], packageVersion);
    expect(seen.single.url.toString(), 'https://api.test/v1/models');
  });

  test('models.list', () async {
    final (client, _) = mockClient((_) => jsonResponse({
          'models': [
            {'id': 'kugel-3.5', 'name': 'Kugel 3.5', 'sample_rate': 24000},
          ],
        }));
    final models = await client.models.list();
    expect(models.single.id, 'kugel-3.5');
  });

  group('voices', () {
    test('list sends the filters as query parameters', () async {
      final (client, seen) = mockClient((_) => jsonResponse(
          {'voices': <Object?>[], 'total': 0, 'limit': 5, 'offset': 10}));
      final page =
          await client.voices.list(language: 'de', limit: 5, offset: 10);
      expect(page.offset, 10);
      expect(seen.single.url.queryParameters, {
        'limit': '5',
        'offset': '10',
        'language': 'de',
        'include_public': 'true',
      });
      await client.voices.list(includePublic: false);
      expect(
          seen.last.url.queryParameters.containsKey('include_public'), isFalse);
    });

    test('create sends metadata, consent and reference files', () async {
      final (client, seen) =
          mockClient((_) => jsonResponse({'id': 9, 'name': 'Mine'}));
      final voice = await client.voices.create(
        name: 'Mine',
        sex: 'female',
        speakerConsent: true,
        supportedLanguages: ['de'],
        referenceFiles: [
          Audio(Uint8List.fromList([82, 73, 70, 70]), filename: 'ref.wav'),
        ],
      );
      expect(voice.id, 9);
      final request = seen.single;
      expect(request.method, 'POST');
      expect(
          request.headers['content-type'], startsWith('multipart/form-data'));
      final body = latin1.decode(request.bodyBytes);
      expect(body, contains('name="metadata"'));
      expect(body, contains('"speaker_consent":true'));
      expect(body, contains('"supported_languages":["de"]'));
      expect(body, contains('name="files"; filename="ref.wav"'));
    });

    test('update sends only the given fields', () async {
      final (client, seen) =
          mockClient((_) => jsonResponse({'id': 9, 'name': 'New'}));
      await client.voices.update(9, name: 'New', isPublic: false);
      expect(seen.single.method, 'PATCH');
      expect(jsonDecode(seen.single.body), {'name': 'New', 'is_public': false});
    });

    test('delete accepts an empty 204', () async {
      final (client, seen) = mockClient((_) => http.Response('', 204));
      await client.voices.delete(9);
      expect(seen.single.method, 'DELETE');
      expect(seen.single.url.path, '/v1/voices/9');
    });

    test('references: list, add with consent, delete', () async {
      final (client, seen) = mockClient((request) {
        if (request.method == 'GET') {
          return jsonResponse([
            {'id': 1, 'voice_id': 9, 'name': 'a.wav'},
          ]);
        }
        if (request.method == 'POST') {
          return jsonResponse({'id': 2, 'voice_id': 9});
        }
        return http.Response('', 204);
      });
      expect((await client.voices.listReferences(9)).single.name, 'a.wav');
      final ref = await client.voices.addReference(
          9, Audio(Uint8List(4), filename: 'b.wav'),
          speakerConsent: true, referenceText: 'Hallo');
      expect(ref.id, 2);
      final body = latin1.decode(seen[1].bodyBytes);
      expect(body, contains('name="speaker_consent"'));
      expect(body, contains('true'));
      expect(body, contains('Hallo'));
      await client.voices.deleteReference(9, 2);
      expect(seen.last.url.path, '/v1/voices/9/references/2');
    });

    test('a non-array references body is a FormatException', () async {
      final (client, _) = mockClient((_) => jsonResponse({'oops': true}));
      expect(client.voices.listReferences(9), throwsFormatException);
    });

    test('publish and generateSample', () async {
      final (
        client,
        seen
      ) = mockClient((request) => request.url.path.endsWith('publish')
          ? jsonResponse({'id': 9, 'name': 'v', 'pending_verification': true})
          : jsonResponse({'sample_s3_path': 's', 'sample_url': 'https://u'}));
      expect((await client.voices.publish(9)).pendingVerification, isTrue);
      expect((await client.voices.generateSample(9)).sampleUrl, 'https://u');
      expect(seen.last.url.path, '/v1/voices/9/generate-sample');
    });
  });

  group('dictionaries', () {
    test('CRUD with project_id', () async {
      final dict = {'id': 1, 'project_id': 7, 'name': 'Brands'};
      final (client, seen) = mockClient((request) {
        if (request.method == 'DELETE') return http.Response('', 204);
        if (request.url.path == '/v1/dictionaries' && request.method == 'GET') {
          return jsonResponse({
            'dictionaries': [dict],
          });
        }
        return jsonResponse(dict);
      });
      expect(
          (await client.dictionaries.list(projectId: 7)).single.name, 'Brands');
      expect(seen.last.url.queryParameters, {'project_id': '7'});
      await client.dictionaries.create(name: 'Brands', language: 'de');
      expect(jsonDecode(seen.last.body), {'name': 'Brands', 'language': 'de'});
      await client.dictionaries.update(1, isActive: false);
      expect(jsonDecode(seen.last.body), {'is_active': false});
      await client.dictionaries.get(1);
      await client.dictionaries.delete(1, projectId: 7);
      expect(seen.last.url.toString(),
          'https://api.test/v1/dictionaries/1?project_id=7');
    });

    test('entries: list, add, update, delete, replaceAll', () async {
      final entry = {
        'id': 5,
        'dictionary_id': 1,
        'word': 'K8s',
        'replacement': 'kubernetes',
      };
      final (client, seen) = mockClient((request) {
        if (request.method == 'DELETE') return http.Response('', 204);
        if (request.method == 'PUT') {
          return jsonResponse({'upserted': 2, 'deleted': 1, 'total': 2});
        }
        if (request.method == 'GET') {
          return jsonResponse({
            'entries': [entry],
            'total': 1,
            'limit': 100,
            'offset': 0
          });
        }
        return jsonResponse(entry);
      });
      final page = await client.dictionaries.entries.list(1, search: 'k8');
      expect(page.entries.single.word, 'K8s');
      expect(seen.last.url.queryParameters['search'], 'k8');
      await client.dictionaries.entries
          .add(1, word: 'K8s', replacement: 'kubernetes', ipa: 'k');
      expect(jsonDecode(seen.last.body), {
        'word': 'K8s',
        'replacement': 'kubernetes',
        'case_sensitive': false,
        'ipa': 'k',
      });
      await client.dictionaries.entries.update(1, 5, caseSensitive: true);
      expect(jsonDecode(seen.last.body), {'case_sensitive': true});
      await client.dictionaries.entries.delete(1, 5);
      final result = await client.dictionaries.entries.replaceAll(1, const [
        DictionaryEntryInput(word: 'a', replacement: 'b'),
        DictionaryEntryInput(word: 'c', replacement: 'd', caseSensitive: true),
      ]);
      expect(result.upserted, 2);
      expect(jsonDecode(seen.last.body), {
        'entries': [
          {'word': 'a', 'replacement': 'b'},
          {'word': 'c', 'replacement': 'd', 'case_sensitive': true},
        ],
      });
    });
  });

  group('tts.generate (REST)', () {
    test('posts the request and reads format headers', () async {
      final (client, seen) = mockClient((_) => http.Response.bytes(
            [1, 2, 3, 4],
            200,
            headers: {
              'content-type': 'audio/basic',
              'x-sample-rate': '8000',
              'x-audio-format': 'mulaw',
              'x-request-id': 'rq',
            },
          ));
      final audio = await client.tts.generate(
        text: 'Hallo Welt',
        voiceId: 1071,
        outputFormat: OutputFormat.ulaw8000,
        language: 'de',
        dictionaryIds: const [],
      );
      expect(audio.audio, [1, 2, 3, 4]);
      expect(audio.sampleRate, 8000);
      expect(audio.encoding, AudioEncoding.mulaw);
      expect(audio.samples, 4);
      expect(audio.requestId, 'rq');
      final body = jsonDecode(seen.single.body) as Map;
      expect(seen.single.url.path, '/v1/tts/generate');
      expect(body['text'], 'Hallo Welt');
      expect(body['voice_id'], 1071);
      expect(body['output_format'], 'ulaw_8000');
      expect(body['dictionary_ids'], isEmpty);
      expect(body.containsKey('word_timestamps'), isFalse);
    });

    test('PCM16 defaults when the headers are absent', () async {
      final (client, _) =
          mockClient((_) => http.Response.bytes(List.filled(48000, 0), 200));
      final audio = await client.tts.generate(text: 'Hi', voiceId: 1);
      expect(audio.sampleRate, 24000);
      expect(audio.samples, 24000);
      expect(audio.duration, const Duration(seconds: 1));
    });
  });

  group('errors', () {
    test('401 is an AuthenticationException with the request id', () async {
      final (client, _) = mockClient((_) => http.Response(
          '{"error":"Invalid API key","error_code":"UNAUTHORIZED","code":401}',
          401,
          headers: {'x-request-id': 'req-401'}));
      await expectLater(
        client.models.list(),
        throwsA(isA<AuthenticationException>()
            .having((e) => e.requestId, 'requestId', 'req-401')
            .having((e) => e.message, 'message', 'Invalid API key')),
      );
    });

    test('404 voice is a NotFoundException', () async {
      final (client, _) = mockClient((_) => http.Response(
          '{"error":"Voice not found","error_code":"NOT_FOUND","code":404}',
          404));
      expect(client.voices.get(1), throwsA(isA<NotFoundException>()));
    });

    test('429 carries Retry-After', () async {
      final (client, _) = mockClient((_) => http.Response(
          '{"error":"Rate limit exceeded","error_code":"RATE_LIMITED"}', 429,
          headers: {'retry-after': '30'}));
      expect(
        client.tts.generate(text: 'hi', voiceId: 1),
        throwsA(isA<RateLimitException>().having(
            (e) => e.retryAfter, 'retryAfter', const Duration(seconds: 30))),
      );
    });

    test('a network failure is a ConnectionException', () async {
      final (client, _) =
          mockClient((_) => throw http.ClientException('connection refused'));
      expect(client.models.list(), throwsA(isA<ConnectionException>()));
    });

    test('a slow server times out as a ConnectionException', () async {
      final (client, _) = mockClient(
        (_) => Future.delayed(const Duration(seconds: 2),
            () => jsonResponse({'models': <Object?>[]})),
        timeout: const Duration(milliseconds: 50),
      );
      expect(
        client.models.list(),
        throwsA(isA<ConnectionException>()
            .having((e) => e.message, 'message', contains('timed out'))),
      );
    });
  });
}

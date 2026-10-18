import 'package:kugelaudio/kugelaudio.dart';
import 'package:kugelaudio/src/config.dart';
import 'package:kugelaudio/src/platform/platform.dart' as platform;
import 'package:test/test.dart';

void main() {
  group('parseApiKey', () {
    test('strips a region prefix and reports the region', () {
      final parsed = parseApiKey('eu-abc123');
      expect(parsed.key, 'abc123');
      expect(parsed.region, Region.eu);
      expect(parseApiKey('us-k').region, Region.us);
      expect(parseApiKey('global-k').region, Region.global);
    });

    test('keeps project keys and plain keys unchanged', () {
      final project = parseApiKey('sk-kug-proj_abc_def');
      expect(project.key, 'sk-kug-proj_abc_def');
      expect(project.region, isNull);
      expect(parseApiKey('plainkey').key, 'plainkey');
    });

    test('strips the region prefix of a project key', () {
      final parsed = parseApiKey('eu-sk-kug-proj_abc');
      expect(parsed.key, 'sk-kug-proj_abc');
      expect(parsed.region, Region.eu);
    });
  });

  group('resolveApiUrl', () {
    test('defaults to the canonical endpoint', () {
      expect(resolveApiUrl(), defaultApiUrl);
      expect(resolveApiUrl(region: Region.us), defaultApiUrl);
      expect(resolveApiUrl(region: Region.global), defaultApiUrl);
    });

    test('eu region or key prefix selects the EU endpoint', () {
      expect(resolveApiUrl(region: Region.eu), euApiUrl);
      expect(resolveApiUrl(keyRegion: Region.eu), euApiUrl);
    });

    test('explicit url wins over region, region over key prefix', () {
      expect(
        resolveApiUrl(apiUrl: 'https://onprem.example/', region: Region.eu),
        'https://onprem.example',
      );
      expect(resolveApiUrl(region: Region.us, keyRegion: Region.eu),
          defaultApiUrl);
    });

    test('Region.parse rejects unknown regions', () {
      expect(Region.parse('eu'), Region.eu);
      expect(() => Region.parse('mars'), throwsA(isA<ValidationException>()));
    });
  });

  group('client construction', () {
    test('an empty key is a ValidationException', () {
      expect(() => KugelAudio(apiKey: ''), throwsA(isA<ValidationException>()));
    });

    test('an eu- key routes REST and WebSockets to the EU host', () {
      final client = KugelAudio(apiKey: 'eu-abc', telemetry: false);
      expect(client.apiUrl, euApiUrl);
      expect(client.ttsUrl, euApiUrl);
    });

    test('ttsUrl overrides only the WebSocket host', () {
      final client = KugelAudio(
          apiKey: 'k', apiUrl: 'http://localhost:8000', ttsUrl: 'http://tts:9');
      expect(client.apiUrl, 'http://localhost:8000');
      expect(client.ttsUrl, 'http://tts:9');
    });
  });

  group('URLs', () {
    test('webSocketUri maps the scheme and carries key and sdk metadata', () {
      final uri = webSocketUri('https://api.kugelaudio.com', '/ws/tts', 'k1',
          {'model_id': 'kugel-3.5'});
      expect(uri.scheme, 'wss');
      expect(uri.path, '/ws/tts');
      expect(uri.queryParameters, {
        'api_key': 'k1',
        'model_id': 'kugel-3.5',
        'sdk': 'dart',
        'sdk_version': packageVersion,
      });
      expect(webSocketUri('http://h:1/base/', '/ws/tts', 'k').toString(),
          startsWith('ws://h:1/base/ws/tts?'));
    });

    test('sdk headers name the SDK and version', () {
      final headers = sdkHeaders();
      expect(headers['X-KugelAudio-SDK'], 'dart');
      expect(headers['X-KugelAudio-SDK-Version'], packageVersion);
      // A browser owns User-Agent; everywhere else the SDK sets it.
      expect(headers['User-Agent'],
          platform.isWeb ? isNull : 'kugelaudio-dart/$packageVersion');
    });

    test('auth headers carry the same key twice', () {
      expect(authHeaders('k'), {'Authorization': 'Bearer k', 'X-API-Key': 'k'});
    });
  });
}

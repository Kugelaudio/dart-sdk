import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kugelaudio/kugelaudio.dart';
import 'package:test/test.dart';

import 'fake_ws.dart';

/// An enhancement stream server: echoes each binary chunk, sends `done`
/// on `end`. [session] servers add a request id to ready and done.
ServerScript enhanceServer({bool session = true}) => (conn, message) {
      if (message is List<int>) {
        conn.pushBytes(message);
        return;
      }
      final frame = json(message);
      if (frame['type'] == 'config') {
        conn.push({
          'type': 'ready',
          'sample_rate_hz': 24000,
          'encoding': 'pcm_s16le',
          if (session) 'request_id': 'req',
        });
      } else if (frame['type'] == 'end') {
        conn.push({'type': 'done', 'duration_s': 0.1});
        if (!session) conn.serverClose(1000);
      }
    };

KugelAudio enhanceClient(FakeServer server, [http.Client? httpClient]) =>
    KugelAudio(
      apiKey: 'k',
      apiUrl: 'https://api.test',
      telemetry: false,
      httpClient: httpClient,
      webSocketConnector: server.connect,
    );

void main() {
  group('REST', () {
    test('generate uploads the recording and parses the WAV', () async {
      late http.Request seen;
      final pcm = Uint8List.fromList([1, 0, 2, 0]);
      final client = enhanceClient(
        FakeServer.all(enhanceServer()),
        MockClient((request) async {
          seen = request;
          return http.Response.bytes(wavBytes(pcm, sampleRate: 24000), 200,
              headers: {'content-type': 'audio/wav'});
        }),
      );
      final result = await client.enhance.generate(
        Audio(wavBytes(Uint8List(16), sampleRate: 16000), filename: 'call.wav'),
        model: 'clarity-1',
        speaker: Audio(Uint8List(8), filename: 'me.wav'),
      );
      expect(result.audio, pcm);
      expect(result.sampleRate, 24000);
      expect(seen.url.path, '/v1/audio/enhance');
      final body = latin1.decode(seen.bodyBytes);
      expect(body, contains('name="file"; filename="call.wav"'));
      expect(body, contains('clarity-1'));
      expect(body, contains('target_speaker_extraction'));
      expect(body, contains('name="speaker"; filename="me.wav"'));
    });

    test('an empty model is a ValidationException', () {
      final client = enhanceClient(FakeServer.all(enhanceServer()));
      expect(() => client.enhance.generate(Audio(Uint8List(4)), model: ' '),
          throwsA(isA<ValidationException>()));
    });

    test('a non-WAV response is a KugelAudioException', () async {
      final client = enhanceClient(FakeServer.all(enhanceServer()),
          MockClient((_) async => http.Response('nope', 200)));
      expect(client.enhance.generate(Audio(Uint8List(4)), model: 'clarity-1'),
          throwsA(isA<KugelAudioException>()));
    });

    test('prewarm never throws', () async {
      final client = enhanceClient(FakeServer.all(enhanceServer()),
          MockClient((_) async => http.Response('{"error":"bad key"}', 401)));
      await client.enhance.prewarm();
    });
  });

  group('stream', () {
    test('sends config, audio and end; yields the enhanced chunks', () async {
      final server = FakeServer.all(enhanceServer(session: false));
      final client = enhanceClient(server);
      final input = AudioStream(Uint8List(3200), sampleRate: 16000);
      final chunks =
          await client.enhance.stream(input, model: 'clarity-1').toList();
      expect(chunks.fold<int>(0, (n, c) => n + c.length), 3200);
      final conn = server.connections.single;
      expect(conn.uri.path, '/v1/audio/enhance/stream');
      expect(conn.uri.queryParameters.containsKey('session'), isFalse);
      expect(conn.sentJson.first, {
        'type': 'config',
        'model': 'clarity-1',
        'task': 'noise_removal',
        'sample_rate_hz': 16000,
        'encoding': 'pcm_s16le',
      });
      expect(conn.sentJson.last, {'type': 'end'});
    });

    test('raw chunks need a sample rate and are split to one second', () async {
      final server = FakeServer.all(enhanceServer(session: false));
      final client = enhanceClient(server);
      expect(
          () => client.enhance
              .stream(Stream.value(Uint8List(4)), model: 'clarity-1'),
          throwsA(isA<ValidationException>()));
      await client.enhance
          .stream(Stream.value(Uint8List(5000)),
              model: 'clarity-1', sampleRate: 1000)
          .drain<void>();
      expect(server.connections.single.sentBytes.map((b) => b.length),
          [2000, 2000, 1000]);
    });

    test('an error frame is a typed error', () async {
      final server = FakeServer.all((conn, message) {
        conn.push({
          'type': 'error',
          'error': 'Invalid request',
          'error_code': 'VALIDATION_ERROR',
          'code': 400,
        });
      });
      final client = enhanceClient(server);
      expect(
        client.enhance
            .stream(AudioStream(Uint8List(2), sampleRate: 8000),
                model: 'clarity-1')
            .toList(),
        throwsA(isA<ValidationException>()),
      );
    });

    test('a mismatching sample rate is refused', () {
      final client = enhanceClient(FakeServer.all(enhanceServer()));
      expect(
          () => client.enhance.stream(
              AudioStream(Uint8List(2), sampleRate: 8000),
              model: 'clarity-1',
              sampleRate: 16000),
          throwsA(isA<ValidationException>()));
    });
  });

  group('session', () {
    test('carries several streams on one socket', () async {
      final server = FakeServer.all(enhanceServer());
      final client = enhanceClient(server);
      final session = client.enhance.session();
      await session.connect();
      for (var i = 0; i < 2; i++) {
        final out = await session
            .stream(AudioStream(Uint8List(400), sampleRate: 8000),
                model: 'clarity-1')
            .toList();
        expect(out, isNotEmpty);
      }
      expect(server.connections, hasLength(1));
      expect(server.connections.single.uri.queryParameters['session'], '1');
      expect(
          server.connections.single.sentJson
              .where((m) => m['type'] == 'config'),
          hasLength(2));
      await session.close();
    });

    test('a server without sessions falls back to one socket per stream',
        () async {
      final server = FakeServer.all(enhanceServer(session: false));
      final client = enhanceClient(server);
      final session = client.enhance.session();
      for (var i = 0; i < 2; i++) {
        await session
            .stream(AudioStream(Uint8List(400), sampleRate: 8000),
                model: 'clarity-1')
            .drain<void>();
      }
      expect(server.connections, hasLength(2));
      expect(server.connections[1].uri.queryParameters.containsKey('session'),
          isFalse);
      await session.close();
    });

    test('a socket the server closed is replaced without an error', () async {
      final server = FakeServer.all(enhanceServer());
      final client = enhanceClient(server);
      final session = client.enhance.session();
      await session.connect();
      server.connections.single.serverClose(1000);
      await Future<void>.delayed(Duration.zero);
      final out = await session
          .stream(AudioStream(Uint8List(400), sampleRate: 8000),
              model: 'clarity-1')
          .toList();
      expect(out, isNotEmpty);
      expect(server.connections, hasLength(2));
      await session.close();
    });
  });
}

import 'dart:async';

import 'package:kugelaudio/kugelaudio.dart';
import 'package:test/test.dart';

import 'fake_ws.dart';

/// Answers each /ws/tts request with [chunks] audio frames, word
/// timestamps and a final frame.
ServerScript ttsServer({int chunks = 2}) => (conn, message) {
      final frame = json(message);
      if (frame['update_settings'] != null) {
        conn.push(
            {'settings_updated': true, 'settings': frame['update_settings']});
        return;
      }
      if (frame['cancel'] == true) {
        conn.push(audioFrame(9)); // late audio of the cancelled request
        conn.push({'interrupted': true});
        return;
      }
      for (var i = 0; i < chunks; i++) {
        conn.push(audioFrame(i));
      }
      conn.push({
        'word_timestamps': [
          {
            'word': 'Hi',
            'start_ms': 0,
            'end_ms': 100,
            'char_start': 0,
            'char_end': 2
          },
        ],
      });
      conn.push({
        'final': true,
        'chunks': chunks,
        'total_samples': chunks * 2,
        'dur_ms': 1.0,
        'gen_ms': 2.0,
        'rtf': 2.0,
        'usage': {
          'audio_seconds': 0.001,
          'cost_cents': 0.01,
          'currency': 'eur'
        },
      });
    };

void main() {
  test('streams chunks, word timestamps and the final stats', () async {
    final server = FakeServer.all(ttsServer());
    final client = fakeClient(server);
    final stamps = <WordTimestamp>[];
    final stream = client.tts.stream(
      text: 'Hi',
      voiceId: 1071,
      language: 'en',
      wordTimestamps: true,
      onWordTimestamps: stamps.addAll,
    );
    final chunks = await stream.toList();
    expect(chunks.map((c) => c.index), [0, 1]);
    final stats = await stream.result;
    expect(stats.chunks, 2);
    expect(stats.usage!.costCents, 0.01);
    expect(stamps.single.word, 'Hi');
    expect(stream.wordTimestamps.single.word, 'Hi');

    final conn = server.connections.single;
    expect(conn.uri.path, '/ws/tts');
    expect(conn.uri.queryParameters['api_key'], 'test-key');
    expect(conn.uri.queryParameters['model_id'], 'kugel-3.5');
    expect(conn.uri.queryParameters['sdk'], 'dart');
    final request = conn.sentJson.single;
    expect(request['text'], 'Hi');
    expect(request['voice_id'], 1071);
    expect(request['word_timestamps'], isTrue);
    await client.close();
  });

  test('collect joins the audio with timestamps and usage', () async {
    final client = fakeClient(FakeServer.all(ttsServer(chunks: 3)));
    final audio = await client.tts
        .stream(text: 'Hi', voiceId: 1, wordTimestamps: true)
        .collect();
    expect(audio.audio, hasLength(12));
    expect(audio.samples, 6);
    expect(audio.rtf, 2.0);
    expect(audio.wordTimestamps, hasLength(1));
    expect(audio.usage!.currency, 'eur');
    await client.close();
  });

  test('requests reuse one pooled socket, one at a time', () async {
    final server = FakeServer.all(ttsServer());
    final client = fakeClient(server);
    await client.tts.connect();
    expect(client.tts.isConnected, isTrue);
    final results = await Future.wait([
      client.tts.stream(text: 'one', voiceId: 1).toList(),
      client.tts.stream(text: 'two', voiceId: 1).toList(),
    ]);
    expect(results.map((r) => r.length), [2, 2]);
    expect(server.connections, hasLength(1));
    expect(server.connections.single.sentJson.map((m) => m['text']),
        ['one', 'two']);
    await client.close();
    expect(server.connections.single.closedByClient, isTrue);
  });

  test('reuseConnection: false opens and closes its own socket', () async {
    final server = FakeServer.all(ttsServer());
    final client = fakeClient(server);
    await client.tts
        .stream(text: 'a', voiceId: 1, reuseConnection: false)
        .drain<void>();
    await client.tts
        .stream(text: 'b', voiceId: 1, reuseConnection: false)
        .drain<void>();
    expect(server.connections, hasLength(2));
    expect(server.connections.every((c) => c.closedByClient), isTrue);
    await client.close();
  });

  test('an error frame fails the stream and keeps the socket', () async {
    var first = true;
    final server = FakeServer.all((conn, message) {
      if (first) {
        first = false;
        conn.push({
          'error': 'voice_id is required',
          'error_code': 'MISSING_VOICE_ID',
          'code': 400,
          'request_id': 'r1',
        });
      } else {
        ttsServer()(conn, message);
      }
    });
    final client = fakeClient(server);
    final failing = client.tts.stream(text: 'x');
    await expectLater(
      failing.toList(),
      throwsA(isA<ValidationException>()
          .having((e) => e.requestId, 'requestId', 'r1')),
    );
    await expectLater(failing.result, throwsA(isA<ValidationException>()));
    expect(await client.tts.stream(text: 'y', voiceId: 1).length, 2);
    expect(server.connections, hasLength(1));
    await client.close();
  });

  test('a 4001 close is an AuthenticationException', () async {
    final server =
        FakeServer.all((conn, _) => conn.serverClose(4001, 'bad key'));
    final client = fakeClient(server);
    expect(client.tts.stream(text: 'x', voiceId: 1).toList(),
        throwsA(isA<AuthenticationException>()));
  });

  test('a drop before final is a ConnectionException', () async {
    final server = FakeServer.all((conn, _) {
      conn.push(audioFrame(0));
      conn.serverClose(1006);
    });
    final client = fakeClient(server);
    expect(
      client.tts.stream(text: 'x', voiceId: 1).toList(),
      throwsA(isA<ConnectionException>()
          .having((e) => e.message, 'message', contains('1006'))),
    );
  });

  test('a rolling-deploy close before audio replays the request once',
      () async {
    final server = FakeServer((index) =>
        index == 0 ? (conn, _) => conn.serverClose(1012) : ttsServer());
    final client = fakeClient(server);
    final chunks = await client.tts.stream(text: 'x', voiceId: 1).toList();
    expect(chunks, hasLength(2));
    expect(server.connections, hasLength(2));
    expect(server.connections[1].sentJson.single['text'], 'x');
    await client.close();
  });

  test('a rolling-deploy close after audio surfaces ServerRestarting',
      () async {
    final server = FakeServer.all((conn, _) {
      conn.push(audioFrame(0));
      conn.serverClose(1012);
    });
    final client = fakeClient(server);
    final received = <AudioChunk>[];
    await expectLater(
      client.tts.stream(text: 'x', voiceId: 1).forEach(received.add),
      throwsA(isA<ServerRestartingException>()),
    );
    expect(received, hasLength(1));
    expect(server.connections, hasLength(1));
  });

  test('cancelling the subscription is a barge-in that keeps the socket',
      () async {
    final server = FakeServer.all((conn, message) {
      final frame = json(message);
      if (frame['cancel'] == true) {
        conn.push(audioFrame(7));
        conn.push({'interrupted': true});
      } else if (frame['text'] == 'long') {
        conn.push(audioFrame(0)); // ...and keeps generating
      } else {
        ttsServer()(conn, message);
      }
    });
    final client = fakeClient(server);
    final first = Completer<AudioChunk>();
    late StreamSubscription<AudioChunk> sub;
    sub = client.tts.stream(text: 'long', voiceId: 1).listen(first.complete);
    await first.future;
    await sub.cancel();
    expect(server.connections.single.sentJson.last, {'cancel': true});
    final next = await client.tts.stream(text: 'next', voiceId: 1).toList();
    expect(next.map((c) => c.index), [0, 1]);
    expect(server.connections, hasLength(1));
    await client.close();
  });

  test('updateSettings returns the effective settings', () async {
    final server = FakeServer.all(ttsServer());
    final client = fakeClient(server);
    final settings =
        await client.tts.updateSettings(speed: 1.1, language: 'de');
    expect(settings, {'speed': 1.1, 'language': 'de'});
    expect(server.connections.single.sentJson.single, {
      'update_settings': {'speed': 1.1, 'language': 'de'}
    });
    expect(() => client.tts.updateSettings(), throwsArgumentError);
    await client.close();
  });

  test('KugelAudio.create pre-connects the pooled socket', () async {
    final server = FakeServer.all(ttsServer());
    final client = await KugelAudio.create(
      apiKey: 'k',
      apiUrl: 'https://api.test',
      telemetry: false,
      webSocketConnector: server.connect,
    );
    expect(client.tts.isConnected, isTrue);
    await client.close();
  });

  test('a refused handshake surfaces its typed error', () async {
    final server = FakeServer.all(ttsServer())
      ..refuseWith = classifyHandshakeRejection(401, {'x-request-id': 'h1'});
    final client = fakeClient(server);
    expect(
      client.tts.stream(text: 'x', voiceId: 1).toList(),
      throwsA(isA<AuthenticationException>()
          .having((e) => e.requestId, 'requestId', 'h1')),
    );
  });
}

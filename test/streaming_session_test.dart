import 'dart:async';

import 'package:kugelaudio/kugelaudio.dart';
import 'package:test/test.dart';

import 'fake_ws.dart';

/// A /ws/tts/stream server: audio per text frame, and on flush the end of
/// the turn (final, then session_closed with usage).
void streamServer(FakeConnection conn, Object message) {
  final frame = json(message);
  if (frame['update_settings'] != null) {
    conn.push({'settings_updated': true, 'settings': frame['update_settings']});
    return;
  }
  if (frame['cancel'] == true) {
    conn.push(audioFrame(9)); // late audio of the cancelled turn
    conn.push({'interrupted': true});
    return;
  }
  final text = frame['text'];
  if (text is String && text.isNotEmpty) {
    conn.push({'generation_started': true, 'chunk_id': 0, 'text': text});
    conn.push(audioFrame(0));
  }
  if (frame['flush'] == true || frame['close'] == true) {
    conn.push({'chunk_complete': true, 'chunk_id': 0});
    conn.push(
        {'final': true, 'total_audio_seconds': 1.2, 'total_text_chunks': 1});
    conn.push({
      'session_closed': true,
      'total_audio_seconds': 1.2,
      'usage': {'audio_seconds': 1.2, 'cost_cents': 0.1, 'currency': 'eur'},
    });
  }
}

void main() {
  test('sends the config with the first text and ends the turn on flush',
      () async {
    final server = FakeServer.all(streamServer);
    final client = fakeClient(server);
    final session = client.tts.streamingSession(
        StreamConfig(voiceId: 1071, language: 'en', wordTimestamps: true));
    final chunks = <AudioChunk>[];
    session.audio.listen(chunks.add);
    await session.connect();
    await session.send('Hello, ');
    await session.send('world.');
    final turn = await session.flush();
    expect(turn!.usage!.costCents, 0.1);
    expect(turn.totalTextChunks, 1);
    expect(session.lastUsage!.audioSeconds, 1.2);
    expect(session.lastFinal!['final'], isTrue);
    expect(chunks, hasLength(2));

    final sent = server.connections.single.sentJson;
    expect(server.connections.single.uri.path, '/ws/tts/stream');
    expect(sent[0]['text'], 'Hello, ');
    expect(sent[0]['voice_id'], 1071);
    expect(sent[0]['language'], 'en');
    expect(sent[0]['word_timestamps'], isTrue);
    expect(sent[1], {'text': 'world.'});
    expect(sent[2], {'flush': true});
    await session.close();
    await client.close();
  });

  test('flush without a turn completes with null', () async {
    final session =
        fakeClient(FakeServer.all(streamServer)).tts.streamingSession();
    expect(await session.flush(), isNull);
    await session.close();
  });

  test('speak sends tokens as one turn', () async {
    final server = FakeServer.all(streamServer);
    final session =
        fakeClient(server).tts.streamingSession(StreamConfig(voiceId: 1));
    unawaited(session.audio.drain<void>());
    final turn = await session.speak(Stream.fromIterable(['A ', 'b ', 'c.']));
    expect(turn, isNotNull);
    expect(server.connections.single.sentJson.map((m) => m['text']),
        ['A ', 'b ', 'c.', null]);
    await session.close();
  });

  test('the config is sticky across turns and re-sent after updateConfig',
      () async {
    final server = FakeServer.all(streamServer);
    final session =
        fakeClient(server).tts.streamingSession(StreamConfig(voiceId: 1));
    unawaited(session.audio.drain<void>());
    await session.flush('Turn one.');
    await session.flush('Turn two.');
    session.updateConfig(session.config.copyWith(voiceId: 2));
    await session.flush('Turn three.');
    final sent = server.connections.single.sentJson;
    expect(sent[0]['voice_id'], 1);
    expect(sent[1].containsKey('voice_id'), isFalse);
    expect(sent[2]['voice_id'], 2);
    await session.close();
  });

  test('cancel drops late audio and resolves the pending flush', () async {
    final hold = Completer<void>();
    final server = FakeServer.all((conn, message) {
      final frame = json(message);
      if (frame['flush'] == true && !hold.isCompleted) {
        conn.push(audioFrame(0)); // the turn is still speaking...
        hold.complete();
        return;
      }
      streamServer(conn, message);
    });
    final session =
        fakeClient(server).tts.streamingSession(StreamConfig(voiceId: 1));
    final chunks = <AudioChunk>[];
    session.audio.listen(chunks.add);
    final pending = session.flush('A long answer.');
    await hold.future;
    await Future<void>.delayed(Duration.zero);
    await session.cancel();
    expect(await pending, isNull);
    expect(server.connections.single.sentJson.last, {'cancel': true});
    expect(chunks.map((c) => c.index), isNot(contains(9)));
    // The socket is reused and the config is sent again.
    await session.flush('Next.');
    expect(server.connections, hasLength(1));
    expect(server.connections.single.sentJson.last['voice_id'], 1);
    await session.close();
  });

  test('an error frame fails the pending flush with the typed error', () async {
    final server = FakeServer.all((conn, message) {
      if (json(message)['flush'] == true) {
        conn.push({
          'error': 'Insufficient credits',
          'error_code': 'INSUFFICIENT_CREDITS',
          'code': 402,
        });
      }
    });
    final session =
        fakeClient(server).tts.streamingSession(StreamConfig(voiceId: 1));
    unawaited(session.audio.drain<void>());
    await expectLater(
        session.flush('Hi.'), throwsA(isA<InsufficientCreditsException>()));
    await session.close();
  });

  test('an error without a pending flush reaches the audio stream', () async {
    final server = FakeServer.all((conn, _) => conn.push({
          'error': 'Rate limit exceeded',
          'error_code': 'RATE_LIMITED',
          'code': 429,
        }));
    final session =
        fakeClient(server).tts.streamingSession(StreamConfig(voiceId: 1));
    final errors = <Object>[];
    session.audio.listen(null, onError: errors.add);
    await session.send('Hi');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(errors.single, isA<RateLimitException>());
    await session.close();
  });

  test('a rolling-deploy close of a silent turn replays it', () async {
    final server = FakeServer((index) => index == 0
        ? (conn, message) {
            if (json(message)['flush'] == true) conn.serverClose(1012);
          }
        : streamServer);
    final session =
        fakeClient(server).tts.streamingSession(StreamConfig(voiceId: 1));
    unawaited(session.audio.drain<void>());
    await session.send('Hello ');
    final turn = await session.flush('there.');
    expect(turn!.usage, isNotNull);
    expect(server.connections, hasLength(2));
    final replayed = server.connections[1].sentJson;
    expect(replayed[0]['text'], 'Hello ');
    expect(replayed[0]['voice_id'], 1);
    expect(replayed[1], {'text': 'there.', 'flush': true});
    await session.close();
  });

  test('a rolling-deploy close after audio fails the turn', () async {
    final server = FakeServer.all((conn, message) {
      conn.push(audioFrame(0));
      if (json(message)['flush'] == true) conn.serverClose(1012);
    });
    final session =
        fakeClient(server).tts.streamingSession(StreamConfig(voiceId: 1));
    unawaited(session.audio.drain<void>());
    await expectLater(
        session.flush('Hi.'), throwsA(isA<ServerRestartingException>()));
    await session.close();
  });

  test('updateSettings returns the effective settings and keeps them',
      () async {
    final server = FakeServer.all(streamServer);
    final session =
        fakeClient(server).tts.streamingSession(StreamConfig(voiceId: 1));
    final settings = await session.updateSettings(cfgScale: 1.5);
    expect(settings, {'cfg_scale': 1.5});
    expect(session.config.cfgScale, 1.5);
    await session.close();
  });

  test('warnings are surfaced', () async {
    final server = FakeServer.all((conn, message) {
      conn.push({'warning': 'idle'});
      streamServer(conn, message);
    });
    final session =
        fakeClient(server).tts.streamingSession(StreamConfig(voiceId: 1));
    final warnings = <String>[];
    session.warnings.listen(warnings.add);
    unawaited(session.audio.drain<void>());
    await session.send('Hi');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(warnings, ['idle']);
    await session.close();
  });
}

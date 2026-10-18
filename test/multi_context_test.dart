import 'dart:async';

import 'package:kugelaudio/kugelaudio.dart';
import 'package:test/test.dart';

import 'fake_ws.dart';

/// A /ws/tts/multi server.
void multiServer(FakeConnection conn, Object message) {
  final frame = json(message);
  final ctx = frame['context_id'] as String?;
  if (frame['update_settings'] != null) {
    conn.push({'settings_updated': true, 'settings': frame['update_settings']});
    return;
  }
  if (frame['close_socket'] == true) {
    conn.push({'session_closed': true, 'total_audio_seconds': 3.0});
    return;
  }
  if (frame['close_context'] == true) {
    if (frame['immediate'] != true) {
      conn.push({'final': true, 'context_id': ctx});
    }
    conn.push({
      'context_closed': true,
      'context_id': ctx,
      'usage': {'audio_seconds': 1.0, 'cost_cents': 0.09},
    });
    return;
  }
  if (frame['voice_settings'] != null || frame['text'] == ' ') {
    conn.push({'context_created': true, 'context_id': ctx});
    return;
  }
  final text = frame['text'];
  if (text is String && text.isNotEmpty) {
    conn.push(audioFrame(0, contextId: ctx));
  }
  if (frame['flush'] == true) {
    conn.push({'chunk_complete': true, 'context_id': ctx});
    conn.push({'final': true, 'context_id': ctx});
  }
}

void main() {
  test('contexts with their own voices, flush and close with usage', () async {
    final server = FakeServer.all(multiServer);
    final client = fakeClient(server);
    final session = client.tts.multiContextSession(
        MultiContextConfig(language: 'en', sampleRate: 16000));
    final chunks = <AudioChunk>[];
    session.audio.listen(chunks.add);
    await session.connect();
    await session.createContext('narrator', voiceId: 1071);
    await session.createContext('character', voiceId: 1072);
    expect(session.activeContexts, {'narrator', 'character'});

    await session.flush('narrator', 'The story begins.');
    await session.send('character', 'Hello!', flush: true);
    await session.flush('character');
    final usage = await session.closeContext('narrator');
    expect(usage!.costCents, 0.09);
    expect(session.usageFor('narrator')!.audioSeconds, 1.0);
    expect(session.activeContexts, {'character'});
    expect(chunks.map((c) => c.contextId), ['narrator', 'character']);

    final sent = server.connections.single.sentJson;
    expect(server.connections.single.uri.path, '/ws/tts/multi');
    expect(sent[0]['context_id'], 'narrator');
    expect(sent[0]['sample_rate'], 16000);
    expect(sent[0]['language'], 'en');
    expect(sent[0]['voice_settings'],
        {'voice_id': 1071, 'cfg_scale': 2.0, 'max_new_tokens': 2048});
    expect(sent[1].containsKey('sample_rate'), isFalse);
    expect((sent[1]['voice_settings'] as Map)['voice_id'], 1072);
    expect(sent[2],
        {'text': 'The story begins.', 'context_id': 'narrator', 'flush': true});

    final stats = await session.close();
    expect(stats['total_audio_seconds'], 3.0);
    await client.close();
  });

  test('send creates a missing context with the default voice', () async {
    final server = FakeServer.all(multiServer);
    final session = fakeClient(server)
        .tts
        .multiContextSession(MultiContextConfig(defaultVoiceId: 5));
    unawaited(session.audio.drain<void>());
    await session.send('c1', 'Hi');
    final sent = server.connections.single.sentJson;
    expect((sent[0]['voice_settings'] as Map)['voice_id'], 5);
    expect(sent[1], {'text': 'Hi', 'context_id': 'c1'});
    await session.close();
  });

  test('immediate close is a barge-in', () async {
    final server = FakeServer.all(multiServer);
    final session = fakeClient(server).tts.multiContextSession();
    unawaited(session.audio.drain<void>());
    await session.createContext('c', voiceId: 1);
    await session.send('c', 'A long sentence');
    await session.closeContext('c', immediate: true);
    expect(server.connections.single.sentJson.last,
        {'close_context': true, 'context_id': 'c', 'immediate': true});
    await session.close();
  });

  test('a context error fails that context only', () async {
    final server = FakeServer.all((conn, message) {
      final frame = json(message);
      if (frame['flush'] == true && frame['context_id'] == 'bad') {
        conn.push({
          'error': 'context closed without producing audio',
          'error_code': 'INTERNAL_ERROR',
          'code': 500,
          'context_id': 'bad',
        });
        return;
      }
      multiServer(conn, message);
    });
    final session = fakeClient(server).tts.multiContextSession();
    unawaited(session.audio.drain<void>());
    await session.createContext('good', voiceId: 1);
    await session.createContext('bad', voiceId: 1);
    await expectLater(
        session.flush('bad', 'x'), throwsA(isA<KugelAudioException>()));
    await session.flush('good', 'Fine.');
    await session.close();
  });

  test('too many contexts is a RateLimitException', () async {
    final server = FakeServer.all((conn, message) {
      final frame = json(message);
      conn.push({
        'error': 'Too many concurrent contexts (max 20)',
        'error_code': 'TOO_MANY_CONTEXTS',
        'code': 429,
        'context_id': frame['context_id'],
      });
    });
    final session = fakeClient(server).tts.multiContextSession();
    expect(session.createContext('c21', voiceId: 1),
        throwsA(isA<RateLimitException>()));
  });

  test('a rolling-deploy close restores contexts and replays silent turns',
      () async {
    final server = FakeServer((index) => index == 0
        ? (conn, message) {
            final frame = json(message);
            if (frame['flush'] == true) {
              conn.serverClose(1012);
              return;
            }
            multiServer(conn, message);
          }
        : multiServer);
    final session = fakeClient(server).tts.multiContextSession();
    unawaited(session.audio.drain<void>());
    await session.createContext('a', voiceId: 11);
    await session.flush('a', 'Replay me.');
    expect(server.connections, hasLength(2));
    final second = server.connections[1].sentJson;
    expect(second[0]['context_id'], 'a');
    expect((second[0]['voice_settings'] as Map)['voice_id'], 11);
    expect(second[1], {'text': 'Replay me.', 'context_id': 'a', 'flush': true});
    await session.close();
  });

  test('after a drop, sending needs connect() again', () async {
    final server = FakeServer((index) => index == 0
        ? (conn, message) {
            if (json(message)['flush'] == true) {
              conn.serverClose(1006);
              return;
            }
            multiServer(conn, message);
          }
        : multiServer);
    final session = fakeClient(server).tts.multiContextSession();
    final errors = <Object>[];
    session.audio.listen(null, onError: errors.add);
    await session.createContext('a', voiceId: 1);
    await expectLater(
        session.flush('a', 'x'), throwsA(isA<ConnectionException>()));
    await expectLater(
        session.send('a', 'y'), throwsA(isA<ConnectionException>()));
    await session.connect();
    await session.flush('a', 'z');
    await session.close();
  });

  test('updateSettings and keepAlive', () async {
    final server = FakeServer.all(multiServer);
    final session = fakeClient(server).tts.multiContextSession();
    unawaited(session.audio.drain<void>());
    expect(
        await session.updateSettings(temperature: 0.2), {'temperature': 0.2});
    await session.createContext('k', voiceId: 1);
    await session.keepAlive('k');
    expect(server.connections.single.sentJson.last,
        {'text': '', 'context_id': 'k'});
    await session.close();
  });
}

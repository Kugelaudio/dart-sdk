/// Live checks against the production API. They run only when
/// `KUGELAUDIO_API_KEY` is set and are tagged `live`, so CI (`dart test
/// -x live`) never runs them.
@Tags(['live'])
@TestOn('vm')
library;

import 'dart:io';

import 'package:kugelaudio/kugelaudio.dart';
import 'package:test/test.dart';

void main() {
  final apiKey = Platform.environment['KUGELAUDIO_API_KEY'];
  final skip =
      apiKey == null || apiKey.isEmpty ? 'KUGELAUDIO_API_KEY is not set' : null;

  late KugelAudio client;
  late int voiceId;

  setUpAll(() async {
    if (skip != null) return;
    client = KugelAudio(apiKey: apiKey!, telemetry: false);
    final configured = Platform.environment['KUGELAUDIO_VOICE_ID'];
    voiceId = configured != null
        ? int.parse(configured)
        : (await client.voices.list(language: 'en', limit: 1)).voices.first.id;
  });

  tearDownAll(() async {
    if (skip == null) await client.close();
  });

  test('generates one sentence over REST', () async {
    final audio = await client.tts.generate(
      text: 'Hello from the KugelAudio Dart SDK.',
      voiceId: voiceId,
      language: 'en',
    );
    expect(audio.audio.length, greaterThan(24000));
    expect(audio.sampleRate, 24000);
  }, skip: skip);

  test('streams one turn on a streaming session', () async {
    final session = client.tts
        .streamingSession(StreamConfig(voiceId: voiceId, language: 'en'));
    var bytes = 0;
    final listening = session.audio.forEach((c) => bytes += c.audio.length);
    for (final token in ['This ', 'is ', 'a ', 'streamed ', 'turn.']) {
      await session.send(token);
    }
    final turn = await session.flush();
    await session.close();
    await listening;
    expect(bytes, greaterThan(0));
    expect(turn, isNotNull);
    expect(turn!.usage?.audioSeconds ?? turn.totalAudioSeconds, greaterThan(0));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 1)));
}

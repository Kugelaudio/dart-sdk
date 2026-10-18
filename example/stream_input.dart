// Feed LLM-style tokens into a streaming session: audio starts at the first
// sentence while the "LLM" is still writing. Each turn ends with flush().
//
//   dart run example/stream_input.dart <voiceId>
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:kugelaudio/io.dart';

/// Stands in for an LLM: yields a reply token by token.
Stream<String> fakeLlm(String reply) async* {
  for (final token in reply.split(RegExp(r'(?<= )'))) {
    await Future<void>.delayed(const Duration(milliseconds: 30));
    yield token;
  }
}

Future<void> main(List<String> args) async {
  final client =
      KugelAudio(apiKey: Platform.environment['KUGELAUDIO_API_KEY']!);
  final voiceId = int.parse(args.isEmpty ? '1071' : args.first);
  final session = client.tts.streamingSession(
    StreamConfig(voiceId: voiceId, language: 'en'),
  );
  final pcm = BytesBuilder();
  final playing = session.audio.forEach((chunk) => pcm.add(chunk.audio));
  try {
    await session.connect();

    // Turn 1: send tokens as they arrive, then flush.
    await for (final token
        in fakeLlm('Thanks for calling. Your order shipped this morning. ')) {
      await session.send(token);
    }
    final first = await session.flush();
    stdout.writeln('Turn 1: ${first?.totalAudioSeconds} s, '
        'charged ${first?.usage?.costCents} ct');

    // Turn 2 on the same socket, with the convenience wrapper.
    await session.speak(fakeLlm('Is there anything else I can help with? '));

    // Barge-in: the caller interrupts the agent mid-sentence.
    unawaited(session.speak(fakeLlm('Let me read you the full tracking '
        'history, starting with the first scan at the warehouse. ')));
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await session.cancel();
  } finally {
    await session.close();
    await playing;
    await client.close();
  }
  await AudioResponse(
    audio: pcm.toBytes(),
    sampleRate: 24000,
    samples: pcm.length ~/ 2,
  ).saveWav('conversation.wav');
  stdout.writeln('Wrote conversation.wav');
}

// Stream one request over the pooled WebSocket and print word timestamps.
// The first `connect()` warms the socket so the request starts faster.
//
//   dart run example/streaming_turn.dart <voiceId>
import 'dart:io';

import 'package:kugelaudio/io.dart';

Future<void> main(List<String> args) async {
  final client =
      KugelAudio(apiKey: Platform.environment['KUGELAUDIO_API_KEY']!);
  final voiceId = int.parse(args.isEmpty ? '1071' : args.first);
  try {
    await client.tts.connect();
    final stopwatch = Stopwatch()..start();
    final stream = client.tts.stream(
      text: 'Streaming means the first audio arrives while the rest is '
          'still being generated.',
      voiceId: voiceId,
      language: 'en',
      wordTimestamps: true,
    );
    final chunks = <AudioChunk>[];
    await for (final chunk in stream) {
      if (chunks.isEmpty) {
        stdout.writeln('First audio after ${stopwatch.elapsedMilliseconds} ms');
      }
      chunks.add(chunk); // hand chunk.audio to your player here
    }
    final stats = await stream.result;
    stdout.writeln('${stats.chunks} chunks, ${stats.durationMs} ms of audio, '
        'charged ${stats.usage?.costCents} ct');
    for (final word in stream.wordTimestamps) {
      stdout.writeln('${word.word}: ${word.startMs}-${word.endMs} ms');
    }
    await AudioResponse.fromChunks(chunks, stats: stats).saveWav('stream.wav');
  } finally {
    await client.close();
  }
}

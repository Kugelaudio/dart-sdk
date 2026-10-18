// Quickstart: list voices, generate a sentence, save it as WAV.
//
//   export KUGELAUDIO_API_KEY=...
//   dart run example/main.dart
import 'dart:io';

import 'package:kugelaudio/io.dart';

Future<void> main() async {
  final client =
      KugelAudio(apiKey: Platform.environment['KUGELAUDIO_API_KEY']!);
  try {
    final voices = await client.voices.list(language: 'en', limit: 5);
    for (final voice in voices.voices) {
      stdout.writeln('${voice.id}: ${voice.name}');
    }

    final audio = await client.tts.generate(
      text: 'Hello from the KugelAudio Dart SDK!',
      voiceId: voices.voices.first.id,
      language: 'en',
    );
    await audio.saveWav('hello.wav');
    stdout.writeln('Wrote hello.wav (${audio.duration.inMilliseconds} ms).');
  } on KugelAudioException catch (e) {
    stderr.writeln('KugelAudio error: $e');
    exitCode = 1;
  } finally {
    await client.close();
  }
}

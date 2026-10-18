// Remove background noise from a recording, then stream the same file
// through the real-time endpoint.
//
//   dart run example/enhance.dart noisy.wav
import 'dart:io';
import 'dart:typed_data';

import 'package:kugelaudio/io.dart';

Future<void> main(List<String> args) async {
  final client =
      KugelAudio(apiKey: Platform.environment['KUGELAUDIO_API_KEY']!);
  final path = args.isEmpty ? 'noisy.wav' : args.first;
  try {
    await client.enhance.prewarm();

    final clean = await client.enhance
        .generate(await loadAudioFile(path), model: 'clarity-1');
    await clean.saveWav('clean.wav');
    stdout.writeln('clean.wav: ${clean.duration.inMilliseconds} ms');

    final live = BytesBuilder();
    await client.enhance
        .stream(await loadAudioStreamFile(path), model: 'clarity-1')
        .forEach(live.add);
    await EnhancedAudio(live.toBytes()).saveWav('clean-live.wav');
    stdout.writeln('clean-live.wav written');
  } finally {
    await client.close();
  }
}

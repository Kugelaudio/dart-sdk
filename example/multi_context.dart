// Two speakers on one multi-context socket.
//
//   dart run example/multi_context.dart <narratorVoiceId> <characterVoiceId>
import 'dart:io';
import 'dart:typed_data';

import 'package:kugelaudio/io.dart';

Future<void> main(List<String> args) async {
  final client =
      KugelAudio(apiKey: Platform.environment['KUGELAUDIO_API_KEY']!);
  final narrator = int.parse(args.isNotEmpty ? args[0] : '1071');
  final character = int.parse(args.length > 1 ? args[1] : '1072');
  final session = client.tts.multiContextSession(
    MultiContextConfig(language: 'en'),
  );
  final tracks = <String, BytesBuilder>{};
  final listening = session.audio.forEach((chunk) =>
      tracks.putIfAbsent(chunk.contextId!, BytesBuilder.new).add(chunk.audio));
  try {
    await session.connect();
    await session.createContext('narrator', voiceId: narrator);
    await session.createContext('character', voiceId: character);

    await session.flush('narrator', 'The door creaked open.');
    await session.flush('character', 'Is anybody there?');

    for (final id in ['narrator', 'character']) {
      final usage = await session.closeContext(id);
      stdout.writeln('$id: ${usage?.audioSeconds} s, ${usage?.costCents} ct');
    }
  } finally {
    await session.close();
    await listening;
    await client.close();
  }
  for (final entry in tracks.entries) {
    final pcm = entry.value.toBytes();
    await AudioResponse(audio: pcm, sampleRate: 24000, samples: pcm.length ~/ 2)
        .saveWav('${entry.key}.wav');
  }
}

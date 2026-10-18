// Browse voices and pin pronunciations with a dictionary.
//
//   dart run example/voices.dart
import 'dart:io';

import 'package:kugelaudio/kugelaudio.dart';

Future<void> main() async {
  final client =
      KugelAudio(apiKey: Platform.environment['KUGELAUDIO_API_KEY']!);
  try {
    final models = await client.models.list();
    stdout.writeln('Models: ${models.map((m) => m.id).join(', ')}');

    var offset = 0;
    while (true) {
      final page =
          await client.voices.list(language: 'de', limit: 50, offset: offset);
      for (final voice in page.voices) {
        stdout.writeln('${voice.id}\t${voice.name}\t${voice.category?.value}');
      }
      offset += page.voices.length;
      if (page.voices.isEmpty || offset >= page.total) break;
    }

    // Requires a key bound to a project.
    final dictionary = await client.dictionaries.create(name: 'Brand names');
    await client.dictionaries.entries.replaceAll(dictionary.id, const [
      DictionaryEntryInput(word: 'K8s', replacement: 'Kubernetes'),
      DictionaryEntryInput(word: 'SQL', replacement: 'sequel'),
    ]);
    stdout.writeln('Dictionary ${dictionary.id} ready.');
  } finally {
    await client.close();
  }
}

// Generate speech over REST and write it to a WAV file, with a telephony
// variant (G.711 µ-law at 8 kHz).
//
//   dart run example/generate_wav.dart <voiceId>
import 'dart:io';

import 'package:kugelaudio/io.dart';

Future<void> main(List<String> args) async {
  final client =
      KugelAudio(apiKey: Platform.environment['KUGELAUDIO_API_KEY']!);
  final voiceId = int.parse(args.isEmpty ? '1071' : args.first);
  try {
    final audio = await client.tts.generate(
      text: 'Your appointment is on the 3rd of May at 10:30.',
      voiceId: voiceId,
      language: 'en',
      speed: 1.05,
    );
    await audio.saveWav('appointment.wav');

    final phone = await client.tts.generate(
      text: 'Your verification code is <spell>4815</spell>.',
      voiceId: voiceId,
      language: 'en',
      outputFormat: OutputFormat.ulaw8000,
    );
    await phone.saveWav('code-ulaw.wav');
    stdout.writeln('Wrote appointment.wav and code-ulaw.wav '
        '(request ${phone.requestId}).');
  } finally {
    await client.close();
  }
}

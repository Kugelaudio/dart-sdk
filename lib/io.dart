/// File helpers for platforms with `dart:io` (mobile, desktop, server).
///
/// Not available in the browser; there, pass bytes to [Audio] and use
/// [AudioResponse.toWav] / [EnhancedAudio.toWav].
///
/// ```dart
/// import 'package:kugelaudio/io.dart';
///
/// final audio = await client.tts.generate(text: 'Hi', voiceId: 1071);
/// await audio.saveWav('hello.wav');
/// final clean = await client.enhance
///     .generate(await loadAudioFile('call.wav'), model: 'clarity-1');
/// await clean.saveWav('call-clean.wav');
/// ```
library;

import 'dart:io';

import 'kugelaudio.dart';

export 'kugelaudio.dart';

/// Reads a WAV file for `client.enhance.generate` or a voice reference.
Future<Audio> loadAudioFile(String path) async => Audio(
      await File(path).readAsBytes(),
      filename: File(path).uri.pathSegments.last,
    );

/// Reads a 16-bit PCM WAV file for `client.enhance.stream`, served in
/// chunks of [chunkSeconds]; multi-channel audio is averaged to mono.
Future<AudioStream> loadAudioStreamFile(String path,
        {double chunkSeconds = 0.1}) async =>
    AudioStream.fromWav(await File(path).readAsBytes(),
        chunkSeconds: chunkSeconds);

/// Writes generated audio to files.
extension AudioResponseFiles on AudioResponse {
  /// Writes the audio to [path] as a WAV file.
  Future<File> saveWav(String path) => File(path).writeAsBytes(toWav());

  /// Writes the raw audio bytes (no container) to [path].
  Future<File> saveRaw(String path) => File(path).writeAsBytes(audio);
}

/// Writes enhanced audio to files.
extension EnhancedAudioFiles on EnhancedAudio {
  /// Writes the audio to [path] as a WAV file.
  Future<File> saveWav(String path) => File(path).writeAsBytes(toWav());
}

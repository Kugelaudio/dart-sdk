# KugelAudio for Dart and Flutter

The official [KugelAudio](https://kugelaudio.com) SDK for Dart and Flutter:
low-latency text to speech over REST and WebSockets, voices, pronunciation
dictionaries and speech enhancement. Pure Dart, so it runs in Flutter apps on
Android, iOS, macOS, Windows, Linux and the web, and in plain Dart on servers
and the command line.

Full API documentation: [docs.kugelaudio.com](https://docs.kugelaudio.com).

## Install

```bash
dart pub add kugelaudio      # Dart
flutter pub add kugelaudio   # Flutter
```

Get an API key in the [dashboard](https://www.kugelaudio.com/dashboard).

## Quickstart

```dart
import 'package:kugelaudio/kugelaudio.dart';

Future<void> main() async {
  final client = KugelAudio(apiKey: 'YOUR_API_KEY');

  // Pick a voice.
  final voices = await client.voices.list(language: 'en', limit: 10);
  final voiceId = voices.voices.first.id;

  // Generate one sentence over REST: PCM16 at 24 kHz.
  final audio = await client.tts.generate(
    text: 'Hello from KugelAudio!',
    voiceId: voiceId,
    language: 'en',
  );
  final wav = audio.toWav(); // WAV file bytes, ready for a player

  await client.close();
}
```

Set `language` whenever you know it: normalization (numbers, dates) uses the
voice's primary language otherwise; the text's language is not detected.

On platforms with `dart:io`, `package:kugelaudio/io.dart` adds file helpers:

```dart
import 'package:kugelaudio/io.dart';

await audio.saveWav('hello.wav');
```

## Streaming

`tts.stream` returns a `Stream<AudioChunk>`: the first audio arrives while
the rest is still generated. Requests share one pooled WebSocket; call
`connect()` at startup to open it ahead of the first request.

```dart
await client.tts.connect();

final stream = client.tts.stream(
  text: 'Streaming starts playback before the sentence is finished.',
  voiceId: voiceId,
  language: 'en',
  wordTimestamps: true,
);
await for (final chunk in stream) {
  player.add(chunk.audio); // PCM16 little-endian, chunk.sampleRate Hz
}
final stats = await stream.result;
print('${stats.durationMs} ms of audio, ${stats.usage?.costCents} ct');
```

Cancelling the subscription is a barge-in: the SDK tells the server to stop,
drops the late audio and keeps the socket for the next request. Use
`stream(...).collect()` to get one `AudioResponse` with word timestamps and
usage.

### Text from an LLM: streaming sessions

A `StreamingSession` takes text token by token; the server synthesizes at
sentence boundaries, so the first sentence plays while your LLM is still
writing. End every turn with `flush()`.

```dart
final session = client.tts.streamingSession(
  StreamConfig(voiceId: voiceId, language: 'en'),
);
session.audio.listen((chunk) => player.add(chunk.audio));
await session.connect();

await for (final token in llm.reply(prompt)) {
  await session.send(token);
}
final turn = await session.flush(); // audio delivered, turn closed
print('turn billed: ${turn?.usage?.costCents} ct');

await session.cancel(); // barge-in: stop the current turn, keep the socket
await session.close();
```

`session.speak(tokenStream)` sends a whole token stream and flushes it.
`updateSettings` changes speed, temperature, `cfgScale`, `maxNewTokens`,
language or normalization for the next turn without reconnecting;
`updateConfig` changes the voice or format between turns.

### Several speakers: multi-context sessions

```dart
final multi = client.tts.multiContextSession(MultiContextConfig(language: 'en'));
multi.audio.listen((chunk) => mixer.add(chunk.contextId!, chunk.audio));
await multi.connect();
await multi.createContext('narrator', voiceId: 1071);
await multi.createContext('character', voiceId: 1072);
await multi.flush('narrator', 'The door creaked open.');
await multi.flush('character', 'Is anybody there?');
final usage = await multi.closeContext('narrator');
await multi.close();
```

Up to 20 contexts share one socket; `closeContext(id, immediate: true)` is a
per-context barge-in.

During a rolling deploy of the API, sessions reconnect and replay a turn
that has not produced audio yet; a turn that was already audible fails with
`ServerRestartingException`, so you decide what to resend.

## Playing audio in Flutter

The SDK delivers raw audio and leaves playback to you:

- **Whole clips**: `audio.toWav()` gives WAV bytes that any Flutter audio
  player package accepting in-memory bytes can play.
- **Streamed chunks**: feed `chunk.audio` (mono PCM16 little-endian at
  `chunk.sampleRate`) to a PCM streaming player package as it arrives, or
  collect the chunks and play the WAV.
- **Telephony**: pass `outputFormat: OutputFormat.ulaw8000` (or `alaw8000`)
  to receive G.711 audio; `toWav()` wraps it in a G.711 WAV.

`AudioChunk.toFloat32()` converts PCM16 to floats in [-1, 1) for visualizers
or audio graphs.

The browser can open the WebSockets too, but code running in a browser
exposes its API key to anyone using the page. In web apps, call KugelAudio
from your own server and stream the audio to the page.

## Voices and dictionaries

```dart
final page = await client.voices.list(language: 'de', limit: 50, offset: 0);
final voice = await client.voices.get(1071);

final dictionary = await client.dictionaries.create(name: 'Brand names');
await client.dictionaries.entries.replaceAll(dictionary.id, const [
  DictionaryEntryInput(word: 'K8s', replacement: 'Kubernetes'),
]);
```

Voice creation and reference uploads need `speakerConsent: true`: you
confirm you are the speaker or have the speaker's permission. Recordings are
passed as `Audio(bytes, filename: ...)` (or `loadAudioFile(path)` from
`io.dart`).

## Speech enhancement

```dart
final clean = await client.enhance.generate(
  Audio(wavBytes, filename: 'call.wav'),
  model: 'clarity-1',
);

// Real time: mono PCM16 in, enhanced PCM16 at 24 kHz out.
await for (final chunk in client.enhance.stream(
  AudioStream.fromWav(wavBytes),
  model: 'clarity-1',
)) {
  player.add(chunk);
}
```

Pass `speaker:` (a clean 2-8 s sample) to keep only that voice.
`client.enhance.session()` keeps one warm socket for many streams, and
`client.enhance.prewarm()` readies the service before the first request.

## Regions

```dart
KugelAudio(apiKey: 'YOUR_API_KEY');                    // geo-routed default
KugelAudio(apiKey: 'YOUR_API_KEY', region: Region.eu); // direct EU endpoint
KugelAudio(apiKey: 'eu-YOUR_API_KEY');                 // same, via key prefix
KugelAudio(apiKey: 'YOUR_API_KEY', apiUrl: 'https://tts.example.internal');
```

Priority: `apiUrl`, then `region`, then the key prefix, then
`https://api.kugelaudio.com`. The `eu-` prefix is an SDK feature and is
removed before the key is sent.

## Errors

Every failed call throws a `KugelAudioException` subclass:

| Exception | When |
|---|---|
| `AuthenticationException` | missing, invalid or revoked API key (401, close 4001) |
| `InsufficientCreditsException` | out of credits (402, close 4003) |
| `RateLimitException` | rate, concurrency or context limit (429, close 4029); see `retryAfter` |
| `ValidationException` | invalid request (400), e.g. a missing `voiceId` |
| `NotFoundException` | unknown voice, dictionary or entry (404) |
| `ConnectionException` | network failure, timeout, model unavailable, dropped socket |
| `ServerRestartingException` | a rolling deploy cut an audible turn; resend it |

Each carries `message`, `statusCode`, `errorCode`, `retryAfter` and the
`requestId` to quote to support:

```dart
try {
  await client.tts.generate(text: 'Hallo', voiceId: voiceId, language: 'de');
} on RateLimitException catch (e) {
  await Future<void>.delayed(e.retryAfter ?? const Duration(seconds: 1));
} on KugelAudioException catch (e) {
  print('${e.errorCode}: ${e.message} (request ${e.requestId})');
}
```

## Diagnostics

The SDK reports its own failures (error class, failure stage, timings, the
server request id) to the KugelAudio API host it already talks to, so we
can see problems that never reach our servers. It never sends your text,
audio, keys, URLs or error messages. Reporting is on for the hosted API and
off for custom endpoints. Turn it off with:

```dart
KugelAudio(apiKey: 'YOUR_API_KEY', telemetry: false);
```

or with the environment variable `KUGELAUDIO_TELEMETRY=0` (`1` turns it on),
which overrides the constructor in both directions. In Flutter and web
builds, pass it at compile time: `--dart-define=KUGELAUDIO_TELEMETRY=0`.
Details: [SDK diagnostics](https://docs.kugelaudio.com/sdks/telemetry).

## Logging

Warnings (a missing `language`, a server advisory, a failed prewarm) go to
`package:logging` under the `kugelaudio` logger:

```dart
Logger.root.onRecord.listen((r) => print('${r.level.name}: ${r.message}'));
```

## License

MIT, see [LICENSE](LICENSE).

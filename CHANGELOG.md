## [kugelaudio-dart-sdk-v0.1.1](https://github.com/Kugelaudio/KugelAudio/compare/dart-sdk-v0.1.0...dart-sdk-v0.1.1) (2026-10-18)

# Changelog

## Unreleased

## 0.1.0

First release of the KugelAudio SDK for Dart and Flutter.

- `KugelAudio` client with API-key region prefixes (`eu-`), explicit
  regions, custom API and TTS URLs, timeouts and `close()`.
- `client.models.list()`.
- `client.voices`: list, get, create (with speaker consent and reference
  recordings), update, delete, references, publish and sample generation.
- `client.dictionaries` and `client.dictionaries.entries`, including
  `replaceAll`.
- `client.tts.generate` (REST) and `client.tts.stream` (`Stream<AudioChunk>`
  over a pooled WebSocket, word timestamps, usage, barge-in by cancelling
  the subscription, `updateSettings`, `connect()` warm-up).
- `StreamingSession` for token-by-token text input with turn results and
  usage, cancel, `updateConfig` and `updateSettings`.
- `MultiContextSession` for up to 20 concurrent streams on one socket.
- Silent recovery from rolling deploys of the server while a turn is still
  silent.
- `client.enhance`: REST enhancement, real-time streams, warm sessions and
  `prewarm()`.
- Typed exceptions mirroring the API's error codes and WebSocket close
  codes, with request ids and retry hints.
- WAV and PCM helpers; `package:kugelaudio/io.dart` for files.
- Opt-out client-error diagnostics (`telemetry: false` or
  `KUGELAUDIO_TELEMETRY=0`).

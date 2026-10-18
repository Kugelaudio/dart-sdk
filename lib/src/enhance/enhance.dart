import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../audio.dart';
import '../errors.dart';
import '../http_transport.dart';
import '../models/json.dart';
import '../tts/common.dart';
import '../ws/frame_socket.dart';

/// Task: remove background noise, keep the speech.
const String taskNoiseRemoval = 'noise_removal';

/// Task: keep only the voice of a speaker sample.
const String taskTargetSpeakerExtraction = 'target_speaker_extraction';

/// The sample rate of enhanced audio, in Hz.
const int enhancedSampleRate = 24000;

const _enhancePath = '/v1/audio/enhance';
const _streamPath = '/v1/audio/enhance/stream';
const _warmupPath = '/v1/audio/enhance/warmup';

/// The server closes a session after 60 s without a config and at one
/// hour; a socket is not reused past these, a little before the limits.
const _sessionIdle = Duration(seconds: 55);
const _sessionLifetime = Duration(seconds: 3540);

/// What a server without session mode sends on a socket left without a
/// config for 30 s, before closing it: that socket is stale, the new config
/// is fine.
const _idleFrameCode = 408;

/// Enhanced audio: mono PCM16 at 24 kHz.
class EnhancedAudio {
  /// Creates enhanced audio.
  const EnhancedAudio(this.audio, {this.sampleRate = enhancedSampleRate});

  /// Parses the mono PCM16 WAV the enhancement endpoint returns.
  factory EnhancedAudio.fromWav(Uint8List wav) {
    final WavData parsed;
    try {
      parsed = parseWav(wav);
    } on FormatException catch (e) {
      throw KugelAudioException(
          'Unexpected enhancement response: not a WAV file (${e.message}).');
    }
    if (parsed.channels != 1 || !parsed.isPcm16) {
      throw KugelAudioException(
          'Unexpected enhancement response: expected mono PCM16 WAV.');
    }
    return EnhancedAudio(parsed.data, sampleRate: parsed.sampleRate);
  }

  /// Raw mono PCM16 little-endian samples.
  final Uint8List audio;

  /// Sample rate in Hz.
  final int sampleRate;

  /// Duration of the audio.
  Duration get duration =>
      Duration(microseconds: audio.length ~/ 2 * 1000000 ~/ sampleRate);

  /// The audio as WAV file bytes.
  Uint8List toWav() => wavBytes(audio, sampleRate: sampleRate);
}

void _checkModel(String model) {
  if (model.trim().isEmpty) {
    throw ValidationException(
        "model must be a non-empty string, e.g. model: 'clarity-1'.");
  }
}

int _streamRate(Stream<List<int>> audio, int? sampleRate) {
  if (audio is AudioStream) {
    if (sampleRate != null && sampleRate != audio.sampleRate) {
      throw ValidationException(
        'sampleRate $sampleRate does not match the audio\'s '
        '${audio.sampleRate} Hz; omit sampleRate to use it.',
      );
    }
    return audio.sampleRate;
  }
  if (sampleRate == null) {
    throw ValidationException(
        'sampleRate is required when streaming raw PCM16 chunks.');
  }
  return sampleRate;
}

JsonMap _streamConfig(String model, int sampleRate, Audio? speaker) => {
      'type': 'config',
      'model': model,
      'task': speaker == null ? taskNoiseRemoval : taskTargetSpeakerExtraction,
      'sample_rate_hz': sampleRate,
      'encoding': 'pcm_s16le',
      if (speaker != null) 'speaker_wav_b64': base64.encode(speaker.data),
    };

/// `client.enhance`: speech enhancement.
///
/// Enhancement removes background noise; passing a `speaker` (a clean 2-8 s
/// sample of one voice) keeps only that voice. Results are mono PCM16 at
/// 24 kHz with the duration of the input.
class EnhanceResource {
  /// Creates the resource. Used by `KugelAudio`.
  EnhanceResource(this._transport, this._opener);

  final HttpTransport _transport;
  final SocketOpener _opener;

  /// Enhances a recording (`POST /v1/audio/enhance`).
  ///
  /// [audio] is a WAV file (PCM 16/24/32-bit or float, mono or stereo,
  /// 8-48 kHz, at most 300 s); [model] is e.g. `clarity-1`. With [speaker],
  /// only that voice is kept.
  Future<EnhancedAudio> generate(
    Audio audio, {
    required String model,
    Audio? speaker,
  }) async {
    _checkModel(model);
    final wav = http.MediaType('audio', 'wav');
    final text = http.MediaType('text', 'plain');
    final parts = [
      http.MultipartFile.fromBytes('file', audio.data,
          filename: audio.filename, contentType: wav),
      http.MultipartFile.fromString('model', model, contentType: text),
      http.MultipartFile.fromString('task',
          speaker == null ? taskNoiseRemoval : taskTargetSpeakerExtraction,
          contentType: text),
      if (speaker != null)
        http.MultipartFile.fromBytes('speaker', speaker.data,
            filename: speaker.filename, contentType: wav),
    ];
    final response = await _transport.send('POST', _enhancePath,
        parts: parts, diagnosed: false);
    return EnhancedAudio.fromWav(response.bodyBytes);
  }

  /// Readies enhancement before the first request: the server starts it in
  /// the background (not billed, not rate limited) and the HTTP connection
  /// is opened. Call it as soon as you know audio is coming.
  ///
  /// Never throws: a network error or a refused warm-up is logged at
  /// WARNING and the first real request then reports its own error.
  Future<void> prewarm() async {
    try {
      await _transport.send('POST', _warmupPath, diagnosed: false);
    } on KugelAudioException catch (e) {
      // KEEP-JUSTIFIED: warming is an optimisation; the first real request
      // raises its own typed error for the same cause.
      sdkLog.warning('Could not prewarm speech enhancement ($e); the first '
          'request may wait for a cold start.');
    }
  }

  /// Enhances audio in real time over a WebSocket; listen to the enhanced
  /// mono PCM16 chunks (24 kHz) as they arrive.
  ///
  /// [audio] is an [AudioStream] or any stream of raw mono PCM16 chunks
  /// (chunks over one second are split); [sampleRate] is required for raw
  /// chunks and taken from an [AudioStream]. Input is sent while you
  /// listen; the stream ends once the last input was enhanced. Cancelling
  /// the subscription closes the connection.
  Stream<Uint8List> stream(
    Stream<List<int>> audio, {
    required String model,
    int? sampleRate,
    Audio? speaker,
  }) {
    _checkModel(model);
    final config =
        _streamConfig(model, _streamRate(audio, sampleRate), speaker);
    late final StreamController<Uint8List> controller;
    _Exchange? exchange;
    controller = StreamController<Uint8List>(
      onListen: () {
        unawaited(() async {
          FrameSocket? socket;
          try {
            socket = await _opener.open(_streamPath);
            await _begin(socket, config, reused: false);
            exchange = _Exchange(socket, config, audio, controller);
            await exchange!.run();
          } catch (e, st) {
            if (!controller.isClosed) controller.addError(e, st);
          } finally {
            await socket?.close();
            if (!controller.isClosed) unawaited(controller.close());
          }
        }());
      },
      onCancel: () => exchange?.abort(),
    );
    return controller.stream;
  }

  /// A session: one warm WebSocket for many [stream]-style calls.
  ///
  /// Opening a connection costs a TCP, TLS and WebSocket handshake plus the
  /// server's admission; a session pays that once (or ahead of time with
  /// [EnhanceSession.connect]). Each stream on it is still one request for
  /// rate limits and billing.
  EnhanceSession session() => EnhanceSession._(this);
}

class _StaleSocket implements Exception {}

/// Sends [config] and waits for `ready`; returns it. On a [reused] socket,
/// a close (idle, lifetime or restart) or an old server's idle frame throws
/// [_StaleSocket].
Future<JsonMap> _begin(FrameSocket socket, JsonMap config,
    {required bool reused}) async {
  final ready = Completer<JsonMap>();
  socket
    ..onFrame = (frame) {
      if (frame['type'] == 'ready') {
        completeOnce(ready, frame);
      } else if (frame['type'] == 'error') {
        if (reused && frame['code'] == _idleFrameCode) {
          failCompleter(ready, _StaleSocket());
        } else {
          failCompleter(ready, classifyWsFrame(frame));
        }
      } else {
        failCompleter(
            ready,
            ConnectionException(
                'Unexpected first message from the enhancement stream.'));
      }
    }
    ..onBadFrame = ((e) => failCompleter(ready, e))
    ..onClosed = (code, reason) => failCompleter(ready,
        reused ? _StaleSocket() : closeError(code, reason, 'it was ready'));
  socket.sendJson(config);
  try {
    return await ready.future.timeout(receiveTimeout,
        onTimeout: () => throw ConnectionException(
            'The enhancement stream did not become ready in time.'));
  } finally {
    socket
      ..onFrame = null
      ..onBadFrame = null
      ..onClosed = null;
  }
}

/// After `ready`: sends the audio and `end`, forwards enhanced chunks until
/// `done`. Leaves the socket open.
class _Exchange {
  _Exchange(this._socket, this._config, this._audio, this._out);

  final FrameSocket _socket;
  final JsonMap _config;
  final Stream<List<int>> _audio;
  final StreamController<Uint8List> _out;
  final Completer<void> _done = Completer<void>();
  StreamSubscription<List<int>>? _pump;
  bool aborted = false;
  bool _finished = false;

  Future<void> run() async {
    final maxBytes = (_config['sample_rate_hz']! as int) * 2;
    _socket
      ..onBinary = ((bytes) {
        if (!_out.isClosed) _out.add(bytes);
      })
      ..onFrame = (frame) {
        if (frame['type'] == 'error') {
          failCompleter(_done, classifyWsFrame(frame));
        } else if (frame['type'] == 'done') {
          completeOnce(_done, null);
        }
      }
      ..onBadFrame = ((e) => failCompleter(_done, e))
      ..onClosed = (code, reason) {
        if (aborted) {
          completeOnce(_done, null);
        } else {
          failCompleter(_done, closeError(code, reason, 'the audio was done'));
        }
      };
    _pump = _audio.listen(
      (chunk) {
        if (!_socket.isOpen) return;
        for (var start = 0; start < chunk.length; start += maxBytes) {
          final end =
              start + maxBytes > chunk.length ? chunk.length : start + maxBytes;
          _socket.sendBytes(chunk.sublist(start, end));
        }
      },
      onError: (Object e) => failCompleter(_done, e),
      onDone: () {
        if (_socket.isOpen) _socket.sendJson({'type': 'end'});
      },
      cancelOnError: true,
    );
    try {
      await _done.future;
    } finally {
      _finished = true;
      await _pump?.cancel();
      _socket
        ..onBinary = null
        ..onFrame = null
        ..onBadFrame = null
        ..onClosed = null;
    }
  }

  /// The caller stopped listening: stop sending and end the exchange.
  Future<void> abort() async {
    if (_finished) return;
    aborted = true;
    await _pump?.cancel();
    completeOnce(_done, null);
    await _socket.close();
  }
}

/// One warm WebSocket that carries enhancement streams one after another.
///
/// Each [stream] sends its own config, so task, speaker and sample rate may
/// change between streams; streams run one at a time. A socket the server
/// closed (60 s without a stream, its one-hour lifetime, a restart) is
/// replaced without an error. A server without session support gets one
/// connection per stream instead.
class EnhanceSession {
  EnhanceSession._(this._resource);

  final EnhanceResource _resource;
  final SerialQueue _queue = SerialQueue();
  final Stopwatch _clock = Stopwatch()..start();
  FrameSocket? _socket;
  Duration _openedAt = Duration.zero;
  Duration _idleSince = Duration.zero;
  bool _oneShot = false;
  bool _closed = false;

  /// Opens the session's socket now, so the next [stream] skips the
  /// connection setup. Throws the typed handshake errors (e.g.
  /// [AuthenticationException]).
  Future<void> connect() => _queue.run(() => _acquire());

  /// Enhances one audio on the session's socket; same arguments and output
  /// as [EnhanceResource.stream]. Cancelling the subscription ends this
  /// audio and closes the socket (the next stream opens a new one).
  Stream<Uint8List> stream(
    Stream<List<int>> audio, {
    required String model,
    int? sampleRate,
    Audio? speaker,
  }) {
    _checkModel(model);
    final config =
        _streamConfig(model, _streamRate(audio, sampleRate), speaker);
    late final StreamController<Uint8List> controller;
    _Exchange? exchange;
    controller = StreamController<Uint8List>(
      onListen: () => unawaited(_queue.run(() async {
        try {
          await _run(config, audio, controller, (e) => exchange = e);
        } catch (e, st) {
          if (!controller.isClosed) controller.addError(e, st);
        } finally {
          if (!controller.isClosed) unawaited(controller.close());
        }
      })),
      onCancel: () => exchange?.abort(),
    );
    return controller.stream;
  }

  /// Closes the socket; the session cannot stream afterwards.
  Future<void> close() async {
    _closed = true;
    await _drop();
  }

  Future<void> _run(
    JsonMap config,
    Stream<List<int>> audio,
    StreamController<Uint8List> out,
    void Function(_Exchange) started,
  ) async {
    var (socket, reused) = await _acquire();
    if (socket == null) {
      // One connection for this stream alone.
      final own = await _resource._opener.open(_streamPath);
      try {
        await _begin(own, config, reused: false);
        final exchange = _Exchange(own, config, audio, out);
        started(exchange);
        await exchange.run();
      } finally {
        await own.close();
      }
      return;
    }
    JsonMap ready;
    try {
      try {
        ready = await _begin(socket, config, reused: reused);
      } on _StaleSocket {
        await _drop();
        (socket, reused) = await _acquire();
        if (socket == null) {
          throw ConnectionException(
              'The enhancement session could not be reopened.');
        }
        ready = await _begin(socket, config, reused: false);
      }
    } on RateLimitException {
      // A rate-limit refusal of the config leaves the socket open.
      if (!(socket?.isOpen ?? false)) await _drop();
      rethrow;
    } catch (_) {
      // Refused or failed mid-config: the socket's state is unknown.
      await _drop();
      rethrow;
    }
    if (!ready.containsKey('request_id')) {
      sdkLog.info('The enhancement server does not keep sessions open; '
          'using one connection per stream.');
      _oneShot = true;
    }
    var finished = false;
    try {
      final exchange = _Exchange(socket, config, audio, out);
      started(exchange);
      await exchange.run();
      finished = !exchange.aborted;
    } finally {
      if (finished && !_oneShot) {
        _idleSince = _clock.elapsed;
      } else {
        await _drop();
      }
    }
  }

  /// The session socket and whether it was already open; `(null, false)`
  /// when this stream must use a connection of its own.
  Future<(FrameSocket?, bool)> _acquire() async {
    if (_closed) {
      throw KugelAudioException('The enhancement session is closed.');
    }
    if (_oneShot) return (null, false);
    final current = _socket;
    if (current != null && _reusable(current)) return (current, true);
    await _drop();
    try {
      final socket = await _resource._opener
          .open(_streamPath, query: const {'session': '1'});
      _socket = socket;
      _openedAt = _idleSince = _clock.elapsed;
      return (socket, false);
    } on RateLimitException catch (e) {
      if (e.retryAfter != null) rethrow;
      // The open-session limit: stream on a connection of its own.
      sdkLog.info('The enhancement session was refused ($e); streaming on '
          'a connection of its own.');
      return (null, false);
    } on ValidationException catch (e) {
      // A server that does not know sessions.
      _oneShot = true;
      sdkLog.info('The enhancement session was refused ($e); streaming on '
          'a connection of its own.');
      return (null, false);
    }
  }

  bool _reusable(FrameSocket socket) {
    final now = _clock.elapsed;
    return socket.isOpen &&
        now - _idleSince < _sessionIdle &&
        now - _openedAt < _sessionLifetime;
  }

  Future<void> _drop() async {
    final socket = _socket;
    _socket = null;
    await socket?.close();
  }
}

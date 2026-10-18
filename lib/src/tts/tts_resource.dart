import 'dart:async';

import '../audio.dart';
import '../config.dart' show defaultModelId;
import '../diagnostics/diagnostics.dart';
import '../errors.dart';
import '../http_transport.dart';
import '../models/json.dart';
import '../models/tts.dart';
import '../ws/frame_socket.dart';
import 'common.dart';
import 'multi_context_session.dart';
import 'streaming_session.dart';

/// Streamed audio of one `/ws/tts` request: a `Stream<AudioChunk>` that
/// also reports the request's final stats.
///
/// Nothing is sent until the stream is listened to. Cancelling the
/// subscription is a barge-in: the SDK sends `cancel`, drops the late audio
/// of the abandoned request and keeps the pooled socket for the next one;
/// the future of `subscription.cancel()` completes once the socket is
/// ready again.
class TtsStream extends StreamView<AudioChunk> {
  TtsStream._(super.stream, this._result, this._stamps);

  final Future<GenerationStats> _result;
  final List<WordTimestamp> _stamps;

  /// The request's final stats and usage; completes when the stream ends
  /// and fails with the stream's error. Only completes once the stream is
  /// listened to.
  Future<GenerationStats> get result => _result;

  /// Word timestamps received so far (when `wordTimestamps` is on).
  List<WordTimestamp> get wordTimestamps => List.unmodifiable(_stamps);

  /// Listens to the whole stream and joins it into one [AudioResponse],
  /// with word timestamps and usage.
  Future<AudioResponse> collect() async {
    final chunks = await toList();
    final stats = await result;
    return AudioResponse.fromChunks(chunks,
        stats: stats, wordTimestamps: wordTimestamps);
  }
}

/// `client.tts`: speech synthesis.
///
/// [generate] makes one REST request and returns the complete audio.
/// [stream] streams one request over the pooled `/ws/tts` socket.
/// [streamingSession] streams text in (LLM tokens) and audio out;
/// [multiContextSession] runs up to 20 independent streams on one socket.
class TtsResource {
  /// Creates the resource. Used by `KugelAudio`.
  TtsResource(this._transport, this._opener, this._diagnostics);

  final HttpTransport _transport;
  final SocketOpener _opener;
  final Diagnostics _diagnostics;
  final SerialQueue _queue = SerialQueue();
  FrameSocket? _pool;
  String? _poolModel;
  bool _closed = false;

  /// Generates speech from [text] in one REST request
  /// (`POST /v1/tts/generate`) and returns the complete audio.
  ///
  /// [voiceId] is required by the API (there is no default voice). See
  /// [GenerateRequest] for every parameter. The REST endpoint reports no
  /// word timestamps, usage or timing; use
  /// `stream(..., wordTimestamps: true).collect()` for those.
  Future<AudioResponse> generate({
    required String text,
    int? voiceId,
    String modelId = defaultModelId,
    double cfgScale = 2.0,
    double? temperature,
    int maxNewTokens = 2048,
    int sampleRate = defaultSampleRate,
    String? outputFormat,
    bool normalize = true,
    String? language,
    double speed = 1.0,
    List<int>? dictionaryIds,
    int? projectId,
  }) async {
    final request = GenerateRequest(
      text: text,
      modelId: modelId,
      voiceId: voiceId,
      cfgScale: cfgScale,
      temperature: temperature,
      maxNewTokens: maxNewTokens,
      sampleRate: sampleRate,
      outputFormat: outputFormat,
      normalize: normalize,
      language: language,
      speed: speed,
      dictionaryIds: dictionaryIds,
      projectId: projectId,
    );
    warnIfNoLanguage(language, normalize);
    final response = await _transport.send('POST', '/v1/tts/generate',
        jsonBody: request.toJson());
    final rate = int.tryParse(response.headers['x-sample-rate'] ?? '') ??
        OutputFormat.sampleRateOf(outputFormat) ??
        sampleRate;
    final encoding = response.headers['x-audio-format'] ??
        OutputFormat.encodingOf(outputFormat);
    final audio = response.bodyBytes;
    return AudioResponse(
      audio: audio,
      sampleRate: rate,
      samples: audio.length ~/ AudioEncoding.bytesPerSample(encoding),
      encoding: encoding,
      requestId: requestIdOf(response),
    );
  }

  /// Streams speech for [text] over the `/ws/tts` WebSocket.
  ///
  /// With [reuseConnection] (the default) requests share one pooled socket
  /// per model, which saves the connection setup on every request after the
  /// first (see [connect]); requests on it run one after another. With
  /// [wordTimestamps], [onWordTimestamps] is called as timestamps arrive and
  /// [TtsStream.result] carries them all.
  ///
  /// A rolling deploy of the server before the first audio is absorbed: the
  /// request is replayed once on a fresh socket.
  TtsStream stream({
    required String text,
    int? voiceId,
    String modelId = defaultModelId,
    double cfgScale = 2.0,
    double? temperature,
    int maxNewTokens = 2048,
    int sampleRate = defaultSampleRate,
    String? outputFormat,
    bool normalize = true,
    String? language,
    bool wordTimestamps = false,
    double speed = 1.0,
    List<int>? dictionaryIds,
    int? projectId,
    bool reuseConnection = true,
    void Function(List<WordTimestamp> timestamps)? onWordTimestamps,
  }) {
    final request = GenerateRequest(
      text: text,
      modelId: modelId,
      voiceId: voiceId,
      cfgScale: cfgScale,
      temperature: temperature,
      maxNewTokens: maxNewTokens,
      sampleRate: sampleRate,
      outputFormat: outputFormat,
      normalize: normalize,
      language: language,
      wordTimestamps: wordTimestamps,
      speed: speed,
      dictionaryIds: dictionaryIds,
      projectId: projectId,
    );
    final result = Completer<GenerationStats>();
    result.future.ignore();
    final stamps = <WordTimestamp>[];
    final controller = StreamController<AudioChunk>();
    final run = _Request(this, request, controller, result, stamps,
        onWordTimestamps, reuseConnection);
    controller
      ..onListen = () {
        warnIfNoLanguage(language, normalize);
        run.op = _diagnostics.operation(DiagOp.stream, transportWebSocket);
        unawaited(reuseConnection ? _queue.run(run.run) : run.run());
      }
      ..onCancel = run.cancelByCaller;
    return TtsStream._(controller.stream, result.future, stamps);
  }

  /// Opens the pooled `/ws/tts` socket for [modelId] now, so the first
  /// [stream] skips the connection setup. Call it at application start.
  Future<void> connect({String modelId = defaultModelId}) {
    final op = _diagnostics.operation(DiagOp.stream, transportWebSocket);
    return op.run(() => _queue.run(() => _pooled(modelId, op)));
  }

  /// Whether the pooled socket is open.
  bool get isConnected => _pool?.isOpen ?? false;

  /// Changes sticky generation defaults on the pooled socket without
  /// reconnecting; a later request's own value still wins. Returns the
  /// defaults now in effect. They last as long as the socket.
  ///
  /// Throws an [ArgumentError] when no parameter is given.
  Future<Map<String, Object?>> updateSettings({
    double? cfgScale,
    double? temperature,
    double? speed,
    int? maxNewTokens,
    String? language,
    bool? normalize,
  }) {
    final body = settingsUpdateBody(
      cfgScale: cfgScale,
      temperature: temperature,
      speed: speed,
      maxNewTokens: maxNewTokens,
      language: language,
      normalize: normalize,
    );
    return _queue.run(() async {
      final socket = await _pooled(_poolModel ?? defaultModelId, null);
      return awaitSettingsAck(socket, body);
    });
  }

  /// A session that streams text in and audio out on `/ws/tts/stream`,
  /// for LLM output. See [StreamingSession].
  StreamingSession streamingSession([StreamConfig? config]) =>
      StreamingSession(_opener, config ?? StreamConfig(), _diagnostics);

  /// A session of up to 20 independent audio streams on one
  /// `/ws/tts/multi` socket. See [MultiContextSession].
  MultiContextSession multiContextSession([MultiContextConfig? config]) =>
      MultiContextSession(
          _opener, config ?? MultiContextConfig(), _diagnostics);

  /// Closes the pooled socket.
  Future<void> close() async {
    _closed = true;
    final pool = _pool;
    _pool = null;
    await pool?.close();
  }

  Future<FrameSocket> _pooled(String modelId, Operation? op) async {
    if (_closed) throw StateError('The KugelAudio client is closed.');
    final pool = _pool;
    if (pool != null && pool.isOpen && _poolModel == modelId) return pool;
    _pool = null;
    await pool?.close();
    op?.stage = DiagStage.handshake;
    final socket = await _opener.open('/ws/tts',
        query: {'model_id': modelId}, keepalive: true);
    _pool = socket;
    _poolModel = modelId;
    return socket;
  }

  Future<FrameSocket> _dedicated(String modelId, Operation op) {
    op.stage = DiagStage.handshake;
    return _opener.open('/ws/tts', query: {'model_id': modelId});
  }
}

/// Sends `update_settings` on [socket] and waits for `settings_updated`;
/// returns its `settings`.
Future<Map<String, Object?>> awaitSettingsAck(
    FrameSocket socket, JsonMap body) {
  final ack = Completer<Map<String, Object?>>();
  socket
    ..onFrame = (frame) {
      if (frame['error'] != null) {
        failCompleter(ack, classifyWsFrame(frame));
      } else if (frame['settings_updated'] == true) {
        final settings = frame['settings'];
        completeOnce(ack,
            settings is Map ? asJsonMap(settings) : const <String, Object?>{});
      }
    }
    ..onBadFrame = ((e) => failCompleter(ack, e))
    ..onClosed = ((code, reason) =>
        failCompleter(ack, closeError(code, reason, 'settings_updated')));
  socket.sendJson({'update_settings': body});
  return ack.future
      .timeout(receiveTimeout,
          onTimeout: () => throw KugelAudioException(
              'Timed out waiting for the settings_updated acknowledgement.'))
      .whenComplete(() {
    socket
      ..onFrame = null
      ..onBadFrame = null
      ..onClosed = null;
  });
}

enum _Outcome { done, cancelled, restart }

/// How long a barge-in waits for the server's `interrupted` ack before the
/// pooled socket is dropped instead.
const Duration _cancelAckTimeout = Duration(seconds: 5);

/// One `/ws/tts` request, from listen to `final`.
class _Request {
  _Request(
    this._resource,
    this._request,
    this._controller,
    this._result,
    this._stamps,
    this._onStamps,
    this._reuse,
  );

  final TtsResource _resource;
  final GenerateRequest _request;
  final StreamController<AudioChunk> _controller;
  final Completer<GenerationStats> _result;
  final List<WordTimestamp> _stamps;
  final void Function(List<WordTimestamp>)? _onStamps;
  final bool _reuse;

  /// The diagnostics operation, minted when the stream is listened to.
  late final Operation op;

  FrameSocket? _socket;
  Completer<_Outcome>? _exchange;
  bool _audioSeen = false;
  bool _cancelled = false;
  bool _finished = false;
  final Completer<void> _released = Completer<void>();

  Future<void> run() async {
    Object? error;
    StackTrace? trace;
    try {
      await _attempts();
    } catch (e, st) {
      error = e;
      trace = st;
    }
    // Finished before the controller closes: its onCancel (also called
    // after the done event) must not wait for this run.
    _finished = true;
    completeOnce(_released, null);
    if (_cancelled) return;
    if (error == null) {
      op.succeed();
    } else {
      op.fail(error);
      failCompleter(_result, error);
      _controller.addError(error, trace);
    }
    unawaited(_controller.close());
  }

  /// Sends the request, replaying it once after a silent rolling-deploy
  /// close.
  Future<void> _attempts() async {
    var retried = false;
    while (!_cancelled) {
      final socket = _reuse
          ? await _resource._pooled(_request.modelId, op)
          : await _resource._dedicated(_request.modelId, op);
      _socket = socket;
      if (_cancelled) break;
      final outcome = await _talk(socket);
      if (!_reuse) await socket.close();
      if (outcome != _Outcome.restart) break;
      final restart = ServerRestartingException();
      if (retried) throw restart;
      retried = true;
      op.recordRetry();
      final delay = restartDelay(restart);
      sdkLog.info('Server restarting; replaying the request in '
          '${delay.inMilliseconds} ms');
      await Future<void>.delayed(delay);
    }
  }

  Future<_Outcome> _talk(FrameSocket socket) async {
    final exchange = Completer<_Outcome>();
    _exchange = exchange;
    socket
      ..onFrame = ((frame) => _onFrame(frame, exchange))
      ..onBadFrame = ((e) => failCompleter(exchange, e))
      ..onClosed = (code, reason) {
        op.wsCloseCode = code;
        if (_cancelled) {
          completeOnce(exchange, _Outcome.cancelled);
        } else if (code != null &&
            WsCloseCodes.restartCodes.contains(code) &&
            !_audioSeen) {
          completeOnce(exchange, _Outcome.restart);
        } else {
          failCompleter(exchange, closeError(code, reason, 'the final frame'));
        }
      };
    try {
      op.stage = DiagStage.sendingRequest;
      socket.sendJson(_request.toJson());
      op.expectAudio();
      return await exchange.future;
    } finally {
      socket
        ..onFrame = null
        ..onBadFrame = null
        ..onClosed = null;
    }
  }

  void _onFrame(JsonMap frame, Completer<_Outcome> exchange) {
    if (_cancelled) {
      // Late frames of the abandoned request; the ack (or a final that
      // raced the cancel) ends it.
      if (frame['interrupted'] == true || frame['final'] == true) {
        completeOnce(exchange, _Outcome.cancelled);
      }
      return;
    }
    if (frame['error'] != null) {
      final error = classifyWsFrame(frame);
      op.markServerError(error);
      failCompleter(exchange, error);
      return;
    }
    if (frame['final'] == true) {
      completeOnce(_result, GenerationStats.fromJson(frame));
      completeOnce(exchange, _Outcome.done);
      return;
    }
    if (frame['audio'] != null) {
      final chunk = AudioChunk.fromJson(frame);
      _audioSeen = true;
      op.recordChunk(chunk.audio.length);
      _controller.add(chunk);
    }
    if (frame['word_timestamps'] != null) {
      final stamps = parseWordTimestamps(frame['word_timestamps']);
      _stamps.addAll(stamps);
      _onStamps?.call(stamps);
    }
  }

  /// The caller cancelled the subscription: a barge-in. Completes once the
  /// socket is free for the next request.
  Future<void> cancelByCaller() async {
    if (_finished) return;
    _cancelled = true;
    op.cancel();
    final socket = _socket;
    final exchange = _exchange;
    if (socket != null && exchange != null && !exchange.isCompleted) {
      if (_reuse && socket.isOpen) {
        socket.sendJson({'cancel': true});
        Timer(_cancelAckTimeout, () {
          if (exchange.isCompleted) return;
          // No ack: the socket's state is unknown, so it is not reused.
          unawaited(socket.close());
          completeOnce(exchange, _Outcome.cancelled);
        });
      } else {
        completeOnce(exchange, _Outcome.cancelled);
      }
    }
    await _released.future;
  }
}

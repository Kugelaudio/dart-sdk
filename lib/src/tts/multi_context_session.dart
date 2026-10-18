import 'dart:async';

import '../audio.dart' show defaultSampleRate;
import '../diagnostics/diagnostics.dart';
import '../errors.dart';
import '../models/json.dart';
import '../models/tts.dart';
import '../ws/frame_socket.dart';
import 'common.dart';

/// Session-level settings of a [MultiContextSession], sent with the first
/// context and shared by every context.
class MultiContextConfig {
  /// Creates a configuration. [cfgScale] is clamped into [1.2, 2.5].
  MultiContextConfig({
    this.defaultVoiceId,
    this.modelId,
    this.sampleRate = defaultSampleRate,
    this.outputFormat,
    double cfgScale = 2.0,
    this.temperature,
    this.maxNewTokens = 2048,
    this.normalize = true,
    this.language,
    this.speed = 1.0,
    this.dictionaryIds,
    this.projectId,
    this.wordTimestamps = false,
  }) : cfgScale = clampCfgScale(cfgScale);

  /// Voice of a context created without its own voice.
  final int? defaultVoiceId;

  /// Model id; the server default when `null`.
  final String? modelId;

  /// Output sample rate in Hz.
  final int sampleRate;

  /// A combined codec+rate token, e.g. `ulaw_8000`; set once per session.
  final String? outputFormat;

  /// Classifier-free guidance scale, clamped into [1.2, 2.5].
  final double cfgScale;

  /// Sampling variance in [0.0, 1.0]; `null` uses the server default.
  final double? temperature;

  /// Maximum tokens per generation, 1-2048.
  final int maxNewTokens;

  /// Convert numbers, dates and symbols to words.
  final bool normalize;

  /// ISO 639-1 language for normalization.
  final String? language;

  /// Speed multiplier, 0.8-1.2.
  final double speed;

  /// Dictionary selection: `null` project default, `[]` none, a list
  /// exactly those.
  final List<int>? dictionaryIds;

  /// Project whose dictionaries apply.
  final int? projectId;

  /// Request word-level timestamps.
  final bool wordTimestamps;

  /// The session-level fields of the first message.
  JsonMap sessionFields() {
    final json = <String, Object?>{
      'sample_rate': sampleRate,
      'normalize': normalize,
      'word_timestamps': wordTimestamps,
      'speed': speed,
    };
    putIfNotNull(json, 'output_format', outputFormat);
    putIfNotNull(json, 'model_id', modelId);
    putIfNotNull(json, 'language', language);
    putIfNotNull(json, 'temperature', temperature);
    putIfNotNull(json, 'project_id', projectId);
    putIfNotNull(json, 'dictionary_ids', dictionaryIds);
    return json;
  }
}

/// Word timestamps of one context.
class ContextWordTimestamps {
  /// Creates an event.
  const ContextWordTimestamps(this.contextId, this.timestamps);

  /// The context the words belong to.
  final String contextId;

  /// The words.
  final List<WordTimestamp> timestamps;
}

class _Context {
  _Context(this.voiceId);

  final int? voiceId;
  bool created = false;
  Completer<void>? createAck;
  final List<JsonMap> frames = [];
  bool audio = false;
  bool replayed = false;
  Completer<void>? flushEnd;
  Completer<SessionUsage?>? closeEnd;
  Operation? op;
  List<WordTimestamp> lastStamps = const [];

  void endTurn() {
    frames.clear();
    audio = false;
    replayed = false;
    op = null;
  }
}

/// Up to 20 independent audio streams over one `/ws/tts/multi` socket:
/// several speakers, pre-buffering, interleaved conversations.
///
/// Each context has its own text buffer and voice. Audio of every context
/// arrives on [audio], tagged with [AudioChunk.contextId]; listen to it
/// before sending.
///
/// ```dart
/// final session = client.tts.multiContextSession(
///   MultiContextConfig(language: 'en'),
/// );
/// session.audio.listen((c) => mixer.add(c.contextId!, c.audio));
/// await session.connect();
/// await session.createContext('narrator', voiceId: 1071);
/// await session.createContext('character', voiceId: 1072);
/// await session.flush('narrator', 'The story begins.');
/// await session.flush('character', 'Hello!');
/// final usage = await session.closeContext('narrator');
/// await session.close();
/// ```
///
/// A rolling deploy of the server is absorbed: the session reconnects,
/// re-creates every context and replays each turn that had not produced
/// audio yet; a context whose turn was already audible fails that turn with
/// a [ServerRestartingException]. Any other drop fails every pending call;
/// call [connect] before sending again.
class MultiContextSession {
  /// Creates a session; use `client.tts.multiContextSession` instead.
  MultiContextSession(this._opener, this.config, this._diagnostics);

  final SocketOpener _opener;
  final Diagnostics _diagnostics;

  /// The session-level settings.
  MultiContextConfig config;

  final _audio = StreamController<AudioChunk>();
  final _stampEvents = StreamController<ContextWordTimestamps>.broadcast();
  final _queue = SerialQueue();
  final Map<String, _Context> _contexts = {};
  final Map<String, SessionUsage> _usage = {};

  FrameSocket? _socket;
  Future<void>? _reconnecting;
  bool _started = false;
  bool _closed = false;
  bool _dropped = false;
  Completer<Map<String, Object?>>? _settingsAck;
  Completer<JsonMap>? _sessionClosed;

  /// Audio of every context, in arrival order; [AudioChunk.contextId] says
  /// whose. Single-subscription: chunks are buffered until listened to.
  Stream<AudioChunk> get audio => _audio.stream;

  /// Word timestamps as they arrive (when `wordTimestamps` is on).
  Stream<ContextWordTimestamps> get wordTimestamps => _stampEvents.stream;

  /// Whether the socket is open.
  bool get isConnected => _socket?.isOpen ?? false;

  /// The contexts the server has created and not closed.
  Set<String> get activeContexts => {
        for (final e in _contexts.entries)
          if (e.value.created) e.key,
      };

  /// Usage of a closed context, for per-conversation billing; `null` until
  /// it closed.
  SessionUsage? usageFor(String contextId) => _usage[contextId];

  /// Usage of every closed context.
  Map<String, SessionUsage> get contextUsage => Map.unmodifiable(_usage);

  /// The most recent word timestamps of [contextId].
  List<WordTimestamp> wordTimestampsFor(String contextId) =>
      _contexts[contextId]?.lastStamps ?? const [];

  /// Opens the socket. After a dropped connection, call it again before
  /// sending.
  Future<void> connect() => _queue.run(() async {
        if (_closed) throw StateError('The multi-context session is closed.');
        if (_socket?.isOpen ?? false) return;
        final op =
            _diagnostics.operation(DiagOp.multiContext, transportWebSocket);
        await op.run(() => _open(op));
        _dropped = false;
      });

  /// Creates [contextId] with [voiceId] (else the default voice) and waits
  /// for the server's confirmation. Creating an existing context does
  /// nothing.
  Future<void> createContext(String contextId, {int? voiceId}) =>
      _queue.run(() => _ensureContext(contextId, voiceId));

  /// Sends [text] to [contextId], creating the context with the default
  /// voice if needed. With [flush] the buffer is synthesized at once; await
  /// [flush] instead to wait for the audio.
  Future<void> send(String contextId, String text, {bool flush = false}) =>
      _queue.run(() async {
        final ctx = await _ensureContext(contextId, null);
        _sendTurnFrame(ctx, {
          'text': text,
          'context_id': contextId,
          if (flush) 'flush': true,
        });
      });

  /// Flushes [contextId] (sending [text] first, if any) and completes once
  /// every audio frame of the text sent so far was delivered (the
  /// context's `final` frame).
  Future<void> flush(String contextId, [String text = '']) async {
    final end = await _queue.run(() async {
      if (text.isEmpty && !(_contexts[contextId]?.created ?? false)) {
        return null;
      }
      final ctx = await _ensureContext(contextId, null);
      final end = ctx.flushEnd ??= Completer<void>();
      _sendTurnFrame(ctx, {
        if (text.isNotEmpty) 'text': text,
        'context_id': contextId,
        'flush': true,
      });
      return end;
    });
    await end?.future.timeout(receiveTimeout * 4,
        onTimeout: () => throw ConnectionException(
            'Context $contextId did not finish its audio in time.'));
  }

  /// Closes [contextId] and completes with its usage once the server
  /// removed it. Queued sentences finish first; with [immediate] the
  /// context's generation stops at once and its buffered text is dropped
  /// (barge-in).
  Future<SessionUsage?> closeContext(String contextId,
      {bool immediate = false}) async {
    final end = await _queue.run(() async {
      final ctx = _contexts[contextId];
      final socket = _socket;
      if (ctx == null || !ctx.created || socket == null || !socket.isOpen) {
        return null;
      }
      if (immediate) {
        ctx.op?.cancel();
      } else {
        ctx.op?.stage = DiagStage.finalizing;
      }
      final end = ctx.closeEnd ??= Completer<SessionUsage?>();
      socket.sendJson({
        'close_context': true,
        'context_id': contextId,
        if (immediate) 'immediate': true,
      });
      return end;
    });
    return end?.future.timeout(receiveTimeout * 4,
        onTimeout: () => throw ConnectionException(
            'Context $contextId was not closed in time.'));
  }

  /// Resets [contextId]'s 20 s inactivity timeout without generating audio.
  Future<void> keepAlive(String contextId) => _queue.run(() async {
        final socket = _socket;
        if (!(_contexts[contextId]?.created ?? false) ||
            socket == null ||
            !socket.isOpen) {
          return;
        }
        socket.sendJson({'text': '', 'context_id': contextId});
      });

  /// Changes the session's generation parameters; contexts started after
  /// the change use them. Returns the parameters now in effect.
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
      final socket = await _liveSocket();
      final ack = _settingsAck = Completer<Map<String, Object?>>();
      socket.sendJson({'update_settings': body});
      try {
        return await ack.future.timeout(receiveTimeout,
            onTimeout: () => throw KugelAudioException(
                'Timed out waiting for the settings_updated acknowledgement.'));
      } finally {
        _settingsAck = null;
      }
    });
  }

  /// Closes every context and the socket; returns the server's
  /// `session_closed` frame (empty when it did not answer). Per-context
  /// usage seen meanwhile is in [contextUsage].
  Future<Map<String, Object?>> close() async {
    if (_closed) return const {};
    _closed = true;
    var stats = const <String, Object?>{};
    final socket = _socket;
    if (socket != null && socket.isOpen) {
      final done = _sessionClosed = Completer<JsonMap>();
      socket.sendJson({'close_socket': true});
      try {
        stats = await done.future.timeout(receiveTimeout);
      } on TimeoutException {
        // KEEP-JUSTIFIED: the session is being torn down; a server that
        // does not confirm only costs the stats.
      }
    }
    _socket = null;
    await socket?.close();
    for (final ctx in _contexts.values) {
      ctx.op?.cancel();
    }
    _failAll(ConnectionException('The multi-context session was closed.'));
    _contexts.clear();
    // Not awaited: a stream nobody listened to never delivers its done.
    unawaited(_audio.close());
    unawaited(_stampEvents.close());
    return stats;
  }

  // -- internals ---------------------------------------------------------

  Future<void> _open(Operation op) async {
    op.stage = DiagStage.handshake;
    final socket = await _opener.open('/ws/tts/multi', keepalive: true);
    _socket = socket;
    _started = false;
    socket
      ..onFrame = _onFrame
      ..onBadFrame = ((e) => _audio.isClosed ? null : _audio.addError(e))
      ..onClosed = (code, reason) => _onClosed(socket, code, reason);
  }

  Future<FrameSocket> _liveSocket() async {
    if (_closed) throw StateError('The multi-context session is closed.');
    final reconnecting = _reconnecting;
    if (reconnecting != null) await reconnecting;
    final socket = _socket;
    if (socket != null && socket.isOpen) return socket;
    if (_dropped) {
      throw ConnectionException(
          'KugelAudio WebSocket is not connected. Call connect() (or create '
          'a new session) before sending again.');
    }
    final op = _diagnostics.operation(DiagOp.multiContext, transportWebSocket);
    await op.run(() => _open(op));
    return _socket!;
  }

  Future<_Context> _ensureContext(String contextId, int? voiceId) async =>
      _createOn(await _liveSocket(), contextId, voiceId);

  Future<_Context> _createOn(
      FrameSocket socket, String contextId, int? voiceId) async {
    final existing = _contexts[contextId];
    if (existing != null && existing.created) return existing;
    final ctx = existing ?? (_contexts[contextId] = _Context(voiceId));
    final effectiveVoice = ctx.voiceId ?? config.defaultVoiceId;
    final message = <String, Object?>{'text': ' ', 'context_id': contextId};
    if (!_started) {
      warnIfNoLanguage(config.language, config.normalize);
      message.addAll(config.sessionFields());
    } else if (config.modelId != null) {
      message['model_id'] = config.modelId;
    }
    if (effectiveVoice != null) {
      message['voice_settings'] = {
        'voice_id': effectiveVoice,
        'cfg_scale': config.cfgScale,
        'max_new_tokens': config.maxNewTokens,
      };
    }
    final ack = ctx.createAck = Completer<void>();
    socket.sendJson(message);
    _started = true;
    await ack.future.timeout(receiveTimeout,
        onTimeout: () => throw ConnectionException(
            'Timed out waiting for context $contextId to be created.'));
    return ctx;
  }

  void _sendTurnFrame(_Context ctx, JsonMap frame) {
    final op = ctx.op ??= _diagnostics.operation(
        DiagOp.multiContext, transportWebSocket, DiagStage.sendingRequest);
    ctx.frames.add(frame);
    _socket!.sendJson(frame);
    op.expectAudio();
  }

  void _onFrame(JsonMap frame) {
    final contextId =
        frame['context_id'] is String ? frame['context_id']! as String : null;
    final ctx = contextId == null ? null : _contexts[contextId];
    if (frame['error'] != null) {
      _onError(classifyWsFrame(frame), ctx);
      return;
    }
    if (frame['settings_updated'] == true) {
      final settings = frame['settings'];
      completeOnce(_settingsAck,
          settings is Map ? asJsonMap(settings) : const <String, Object?>{});
      return;
    }
    if (frame['session_closed'] == true) {
      completeOnce(_sessionClosed, frame);
      return;
    }
    if (frame['context_created'] == true && ctx != null) {
      ctx.created = true;
      completeOnce(ctx.createAck, null);
      return;
    }
    if (frame['audio'] != null) {
      final chunk = AudioChunk.fromJson(frame);
      if (ctx != null) {
        ctx.audio = true;
        ctx.op?.recordChunk(chunk.audio.length);
      }
      if (!_audio.isClosed) _audio.add(chunk);
    }
    if (frame['word_timestamps'] != null && contextId != null) {
      final stamps = parseWordTimestamps(frame['word_timestamps']);
      ctx?.lastStamps = stamps;
      if (!_stampEvents.isClosed) {
        _stampEvents.add(ContextWordTimestamps(contextId, stamps));
      }
    }
    if (frame['final'] == true && ctx != null) {
      ctx.op?.succeed();
      ctx.endTurn();
      completeOnce(ctx.flushEnd, null);
      ctx.flushEnd = null;
    }
    if (frame['context_closed'] == true && contextId != null) {
      final usage = SessionUsage.fromFrame(frame);
      if (usage != null) _usage[contextId] = usage;
      if (ctx != null) {
        ctx.op?.succeed();
        completeOnce(ctx.flushEnd, null);
        completeOnce(ctx.closeEnd, usage);
        _contexts.remove(contextId);
      }
    }
  }

  void _onError(KugelAudioException error, _Context? ctx) {
    if (ctx != null) {
      final pending = [ctx.createAck, ctx.flushEnd, ctx.closeEnd]
          .where((c) => c != null && !c.isCompleted);
      ctx.op?.markServerError(error);
      ctx.op?.fail(error);
      ctx.endTurn();
      if (!ctx.created) _contexts.remove(_keyOf(ctx));
      if (pending.isNotEmpty) {
        for (final c in pending) {
          failCompleter(c, error);
        }
        return;
      }
    } else if (_settingsAck != null) {
      failCompleter(_settingsAck, error);
      return;
    }
    if (!_audio.isClosed) _audio.addError(error);
  }

  String? _keyOf(_Context ctx) {
    for (final e in _contexts.entries) {
      if (identical(e.value, ctx)) return e.key;
    }
    return null;
  }

  void _failAll(Object error) {
    failCompleter(_settingsAck, error);
    for (final ctx in _contexts.values) {
      ctx.op?.fail(error);
      failCompleter(ctx.createAck, error);
      failCompleter(ctx.flushEnd, error);
      failCompleter(ctx.closeEnd, error);
    }
  }

  void _onClosed(FrameSocket socket, int? code, String? reason) {
    if (!identical(_socket, socket)) return;
    _socket = null;
    completeOnce(_sessionClosed, const <String, Object?>{});
    if (_closed) return;
    for (final ctx in _contexts.values) {
      ctx.op?.wsCloseCode = code;
    }
    if (code != null && WsCloseCodes.restartCodes.contains(code)) {
      _reconnecting = _recover(classifyWsClose(code, reason))
          .whenComplete(() => _reconnecting = null);
      return;
    }
    _dropped = true;
    final error = closeError(code, reason, 'the contexts finished');
    _failAll(error);
    final hadWork = _contexts.values.any((c) => c.frames.isNotEmpty);
    _contexts.clear();
    if (hadWork && !_audio.isClosed) _audio.addError(error);
  }

  /// Reconnects after a rolling-deploy close, re-creates the contexts and
  /// replays every silent turn.
  Future<void> _recover(KugelAudioException restart) async {
    final contexts = Map.of(_contexts);
    _contexts.clear();
    for (final entry in contexts.entries) {
      final ctx = entry.value;
      if (ctx.frames.isNotEmpty && (ctx.audio || ctx.replayed)) {
        sdkLog.warning('Context ${entry.key} lost the rest of its turn to a '
            'server restart; resend it.');
        ctx.op?.fail(restart);
        failCompleter(ctx.flushEnd, restart);
        failCompleter(ctx.closeEnd, restart);
        ctx.endTurn();
      } else if (ctx.frames.isNotEmpty) {
        ctx.op?.recordRetry();
      }
    }
    final delay = restartDelay(restart);
    sdkLog.info('Server restarting; reconnecting in ${delay.inMilliseconds} '
        'ms and restoring ${contexts.length} context(s)');
    try {
      await Future<void>.delayed(delay);
      if (_closed) return;
      final socket = await _opener.open('/ws/tts/multi', keepalive: true);
      _socket = socket;
      _started = false;
      socket
        ..onFrame = _onFrame
        ..onBadFrame = ((e) => _audio.isClosed ? null : _audio.addError(e))
        ..onClosed = (code, reason) => _onClosed(socket, code, reason);
      // Finish every context setup before replay can produce audio.
      for (final entry in contexts.entries) {
        final old = entry.value;
        final ctx = await _createOn(socket, entry.key, old.voiceId);
        ctx
          ..flushEnd = old.flushEnd
          ..closeEnd = old.closeEnd
          ..op = old.op
          ..lastStamps = old.lastStamps;
      }
      for (final entry in contexts.entries) {
        final old = entry.value;
        final ctx = _contexts[entry.key]!;
        if (old.frames.isNotEmpty && !old.audio && !old.replayed) {
          ctx.replayed = true;
          for (final frame in old.frames) {
            ctx.frames.add(frame);
            socket.sendJson(frame);
          }
          ctx.op?.expectAudio();
        }
        if (_closePending(old)) {
          socket.sendJson({'close_context': true, 'context_id': entry.key});
        }
      }
    } catch (e) {
      _dropped = true;
      for (final old in contexts.values) {
        old.op?.fail(e);
        failCompleter(old.createAck, e);
        failCompleter(old.flushEnd, e);
        failCompleter(old.closeEnd, e);
      }
      _contexts.clear();
    }
  }
}

/// Whether a close of [ctx] was pending when the socket went away.
bool _closePending(_Context ctx) =>
    ctx.closeEnd != null && !ctx.closeEnd!.isCompleted;

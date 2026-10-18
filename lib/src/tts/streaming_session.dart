import 'dart:async';

import '../diagnostics/diagnostics.dart';
import '../errors.dart';
import '../models/json.dart';
import '../models/tts.dart';
import '../ws/frame_socket.dart';
import 'common.dart';
import 'tts_resource.dart' show awaitSettingsAck;

/// Text in, audio out on `/ws/tts/stream`: the session for LLM output.
///
/// Send text as it arrives ([send], token by token is fine: the server
/// buffers and synthesizes at sentence boundaries) and end every turn with
/// [flush]. Audio of every turn arrives on [audio]; listen to it before
/// sending. The socket stays open across turns, so later turns skip the
/// connection setup; [cancel] abandons the current turn (barge-in) and keeps
/// the socket.
///
/// ```dart
/// final session = client.tts.streamingSession(StreamConfig(voiceId: 1071));
/// session.audio.listen((chunk) => player.add(chunk.audio));
/// await session.connect();
/// await for (final token in llmTokens) {
///   await session.send(token);
/// }
/// final turn = await session.flush();
/// print('billed: ${turn?.usage?.costCents} ct');
/// await session.close();
/// ```
///
/// A rolling deploy of the server is absorbed while the turn is still
/// silent: the session reconnects and replays the turn once. Otherwise the
/// turn fails with a [ServerRestartingException].
class StreamingSession {
  /// Creates a session; use `client.tts.streamingSession` instead.
  StreamingSession(this._opener, StreamConfig config, this._diagnostics)
      : _config = config;

  final SocketOpener _opener;
  final Diagnostics _diagnostics;
  StreamConfig _config;

  final _audio = StreamController<AudioChunk>();
  final _stampEvents = StreamController<List<WordTimestamp>>.broadcast();
  final _warnings = StreamController<String>.broadcast();
  final _queue = SerialQueue();

  FrameSocket? _socket;
  Future<void>? _reconnecting;
  bool _configSent = false;
  bool _closed = false;
  bool _discarding = false;

  // The turn in flight.
  final List<JsonMap> _turnFrames = [];
  final List<WordTimestamp> _turnStamps = [];
  bool _turnAudio = false;
  bool _turnReplayed = false;
  Operation? _turnOp;
  JsonMap? _finalFrame;

  // Calls waiting for the server.
  Completer<TurnResult?>? _turnEnd;
  Completer<void>? _cancelAck;
  Timer? _idle;

  List<WordTimestamp> _lastStamps = const [];
  SessionUsage? _lastUsage;
  JsonMap? _lastFinal;

  /// Audio of every turn, in order. Single-subscription: chunks are
  /// buffered until it is listened to.
  Stream<AudioChunk> get audio => _audio.stream;

  /// Word timestamps as they arrive (when `wordTimestamps` is on).
  Stream<List<WordTimestamp>> get wordTimestamps => _stampEvents.stream;

  /// Non-fatal server advisories, e.g. a turn auto-ended after 5 s without
  /// text or flush. A correct integration never sees one.
  Stream<String> get warnings => _warnings.stream;

  /// The most recent word timestamps.
  List<WordTimestamp> get lastWordTimestamps => _lastStamps;

  /// Usage of the most recently ended turn, for per-conversation billing.
  SessionUsage? get lastUsage => _lastUsage;

  /// The `final` (end of audio) frame of the most recently completed turn.
  Map<String, Object?>? get lastFinal => _lastFinal;

  /// The configuration sent with the next turn's first text.
  StreamConfig get config => _config;

  /// Whether the socket is open.
  bool get isConnected => _socket?.isOpen ?? false;

  /// Opens the socket now, so the first [send] skips the connection setup.
  /// [send] connects on its own when needed.
  Future<void> connect() => _queue.run(_ensureOpen);

  /// Sends [text] for the current turn; the first text after a turn ended
  /// starts a new turn. Completes once the frame is written.
  Future<void> send(String text) => _queue.run(() async {
        await _ensureOpen();
        _turn();
        _sendFrame({'text': text});
        _turnOp?.expectAudio();
      });

  /// Ends the turn: sends [text] (if any) with `flush`, and completes with
  /// the turn's [TurnResult] once its audio is delivered and the server
  /// closed the turn. Completes with `null` when no turn was in progress or
  /// the turn was cancelled.
  Future<TurnResult?> flush([String text = '']) async {
    final end = await _queue.run(() async {
      if (_turnFrames.isEmpty && text.isEmpty) return null;
      await _ensureOpen();
      _turn();
      final end = _turnEnd ??= Completer<TurnResult?>();
      _sendFrame({if (text.isNotEmpty) 'text': text, 'flush': true});
      _turnOp?.expectAudio();
      _armIdle();
      return end;
    });
    return end?.future;
  }

  /// Sends every token of [tokens] as one turn and flushes it.
  Future<TurnResult?> speak(Stream<String> tokens) async {
    await for (final token in tokens) {
      await send(token);
    }
    return flush();
  }

  /// Ends the session gracefully (`close`): buffered text is spoken, then
  /// the socket stays open and the next [send] starts a fresh session with
  /// the current [config]. Completes with the turn's result, or `null`
  /// when no turn was in progress.
  Future<TurnResult?> endSession() async {
    final end = await _queue.run(() async {
      final socket = _socket;
      if (socket == null || !socket.isOpen || _turnFrames.isEmpty) {
        _configSent = false;
        return null;
      }
      _turnOp?.stage = DiagStage.finalizing;
      final end = _turnEnd ??= Completer<TurnResult?>();
      socket.sendJson({'close': true});
      _armIdle();
      return end;
    });
    final result = await end?.future;
    _configSent = false;
    _lastStamps = const [];
    return result;
  }

  /// Barge-in: stops the current turn at once and drops its buffered text.
  ///
  /// Late audio of the cancelled turn is discarded, a pending [flush]
  /// completes with `null`, and the socket stays open for the next turn.
  /// Completes when the server acknowledges (or stays silent for 30 s).
  Future<void> cancel() async {
    final socket = _socket;
    _turnOp?.cancel();
    completeOnce(_turnEnd, null);
    _resetTurn();
    if (socket == null || !socket.isOpen) return;
    _discarding = true;
    final ack = _cancelAck = Completer<void>();
    socket.sendJson({'cancel': true});
    _armIdle();
    try {
      await ack.future;
    } finally {
      _discarding = false;
      _cancelAck = null;
      // The server starts a fresh session after a cancel.
      _configSent = false;
      _lastStamps = const [];
    }
  }

  /// Replaces the configuration for the next turn (voice, model, format,
  /// ...). Call it between turns; it is sent with the next text.
  void updateConfig(StreamConfig config) {
    _config = config;
    _configSent = false;
  }

  /// Changes generation parameters on the open connection without
  /// reconnecting; they apply from the next turn. Returns the parameters now
  /// in effect. Voice, model, sample rate, output format, project and
  /// dictionaries cannot change this way; use [updateConfig] for those.
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
      await _ensureOpen();
      final socket = _socket!;
      final settings = await _withHandlersPaused(
          socket, () => awaitSettingsAck(socket, body));
      // Mirrored locally only once the server accepted the change.
      _config = _config.copyWith(
        cfgScale: cfgScale,
        temperature: temperature,
        speed: speed,
        maxNewTokens: maxNewTokens,
        language: language,
        normalize: normalize,
      );
      return settings;
    });
  }

  /// Ends the turn in flight (its audio still arrives on [audio]), closes
  /// the socket and the streams. Returns that turn's result, if any.
  Future<TurnResult?> close() async {
    if (_closed) return null;
    TurnResult? result;
    final socket = _socket;
    if (socket != null && socket.isOpen && _turnFrames.isNotEmpty) {
      _turnOp?.stage = DiagStage.finalizing;
      final end = _turnEnd ??= Completer<TurnResult?>();
      socket.sendJson({'close': true});
      _armIdle();
      try {
        result = await end.future;
      } on KugelAudioException {
        // KEEP-JUSTIFIED: the session is being torn down; the failed turn
        // was already reported to its operation.
        result = null;
      }
    }
    _closed = true;
    _idle?.cancel();
    _socket = null;
    await socket?.close();
    _turnOp?.cancel();
    // Not awaited: a stream nobody listened to never delivers its done.
    unawaited(_audio.close());
    unawaited(_stampEvents.close());
    unawaited(_warnings.close());
    return result;
  }

  // -- internals ---------------------------------------------------------

  Operation _turn() => _turnOp ??= _diagnostics.operation(
      DiagOp.streamSession, transportWebSocket, DiagStage.sendingRequest);

  void _resetTurn() {
    _turnFrames.clear();
    _turnStamps.clear();
    _turnAudio = false;
    _turnReplayed = false;
    _turnOp = null;
    _finalFrame = null;
    _turnEnd = null;
  }

  Future<void> _ensureOpen() async {
    if (_closed) throw StateError('The streaming session is closed.');
    final reconnecting = _reconnecting;
    if (reconnecting != null) await reconnecting;
    if (_socket?.isOpen ?? false) return;
    final op = _diagnostics.operation(DiagOp.streamSession, transportWebSocket);
    await op.run(() => _open(op));
  }

  Future<void> _open(Operation op) async {
    op.stage = DiagStage.handshake;
    final socket = await _opener.open('/ws/tts/stream', keepalive: true);
    _socket = socket;
    _configSent = false;
    _attach(socket);
  }

  void _attach(FrameSocket socket) {
    socket
      ..onFrame = _onFrame
      ..onBadFrame = _failTurn
      ..onClosed = (code, reason) => _onClosed(socket, code, reason);
  }

  Future<T> _withHandlersPaused<T>(
      FrameSocket socket, Future<T> Function() body) async {
    try {
      return await body();
    } finally {
      if (identical(_socket, socket)) _attach(socket);
    }
  }

  void _sendFrame(JsonMap frame) {
    _turnFrames.add(frame);
    final message = <String, Object?>{...frame};
    if (!_configSent) {
      warnIfNoLanguage(_config.language, _config.normalize);
      message.addAll(_config.toJson());
      _configSent = true;
    }
    _socket!.sendJson(message);
  }

  void _armIdle() {
    _idle?.cancel();
    if (_turnEnd == null && _cancelAck == null) return;
    _idle = Timer(receiveTimeout, () {
      completeOnce(_cancelAck, null);
      if (_turnEnd != null) {
        _failTurn(ConnectionException(
            'No reply from KugelAudio for ${receiveTimeout.inSeconds}s; '
            'the turn did not end.'));
      }
    });
  }

  void _onFrame(JsonMap frame) {
    if (_turnEnd != null || _cancelAck != null) _armIdle();
    if (frame['error'] != null) {
      final error = classifyWsFrame(frame);
      if (_cancelAck != null) {
        failCompleter(_cancelAck, error);
        return;
      }
      _turnOp?.markServerError(error);
      _failTurn(error);
      return;
    }
    if (frame['warning'] is String) {
      final warning = frame['warning']! as String;
      sdkLog.warning('KugelAudio: $warning');
      _warnings.add(warning);
    }
    if (frame['interrupted'] == true) {
      completeOnce(_cancelAck, null);
      return;
    }
    if (_discarding) return;
    if (frame['audio'] != null) {
      final chunk = AudioChunk.fromJson(frame);
      _turnAudio = true;
      _turnOp?.recordChunk(chunk.audio.length);
      _audio.add(chunk);
    }
    if (frame['word_timestamps'] != null) {
      final stamps = parseWordTimestamps(frame['word_timestamps']);
      _lastStamps = stamps;
      _turnStamps.addAll(stamps);
      _stampEvents.add(stamps);
    }
    if (frame['final'] == true) {
      _lastFinal = frame;
      _finalFrame = frame;
      _turnOp?.succeed();
    }
    if (frame['session_closed'] == true) {
      _turnOp?.succeed();
      final result = TurnResult.fromFrames(frame,
          finalFrame: _finalFrame, wordTimestamps: List.of(_turnStamps));
      _lastUsage = result.usage ?? _lastUsage;
      final end = _turnEnd;
      _resetTurn();
      _idle?.cancel();
      completeOnce(end, result);
    }
  }

  /// Fails the turn in flight with [error]: a pending [flush] gets it,
  /// otherwise the [audio] stream does.
  void _failTurn(Object error) {
    final end = _turnEnd;
    final inFlight = _turnFrames.isNotEmpty || end != null;
    _turnOp?.fail(error);
    _resetTurn();
    _idle?.cancel();
    if (end != null) {
      failCompleter(end, error);
    } else if (inFlight && !_audio.isClosed) {
      _audio.addError(error);
    } else {
      // No turn to fail (e.g. an error frame between turns): still visible.
      sdkLog.warning('KugelAudio streaming session error outside a turn: '
          '$error');
    }
  }

  void _onClosed(FrameSocket socket, int? code, String? reason) {
    if (!identical(_socket, socket)) return;
    _socket = null;
    _configSent = false;
    completeOnce(_cancelAck, null);
    if (_closed) return;
    _turnOp?.wsCloseCode = code;
    final inFlight = _turnFrames.isNotEmpty || _turnEnd != null;
    if (!inFlight) return; // an idle socket: the next send reconnects
    if (code != null && WsCloseCodes.restartCodes.contains(code)) {
      if (!_turnAudio && !_turnReplayed && _turnFrames.isNotEmpty) {
        _reconnecting = _replay(classifyWsClose(code, reason))
            .whenComplete(() => _reconnecting = null);
        return;
      }
      _failTurn(classifyWsClose(code, reason));
      return;
    }
    _failTurn(closeError(code, reason, 'the turn ended'));
  }

  /// Reconnects after a rolling-deploy close and resends the silent turn.
  Future<void> _replay(KugelAudioException restart) async {
    final op = _turnOp;
    final frames = List.of(_turnFrames);
    op?.recordRetry();
    final delay = restartDelay(restart);
    sdkLog.info('Server restarting; reconnecting in ${delay.inMilliseconds} '
        'ms and replaying ${frames.length} frame(s)');
    try {
      await Future<void>.delayed(delay);
      if (_closed) return;
      final socket = await _opener.open('/ws/tts/stream', keepalive: true);
      _socket = socket;
      _configSent = false;
      _attach(socket);
      _turnFrames.clear();
      _turnReplayed = true;
      frames.forEach(_sendFrame);
      op?.expectAudio();
      _armIdle();
    } catch (e) {
      _failTurn(e);
    }
  }
}

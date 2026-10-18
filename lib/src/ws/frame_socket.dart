import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../config.dart';
import '../errors.dart';
import '../models/json.dart';
import 'connection.dart';

/// How long a close waits for the peer before giving up on the handshake.
const Duration closeTimeout = Duration(seconds: 5);

/// A [WebSocketConnection] that decodes JSON text frames and dispatches
/// them to whoever currently owns the socket.
///
/// Exactly one owner (a request, a session) sets the callbacks at a time;
/// frames that arrive with no owner are dropped, which is how a pooled
/// socket ignores the tail of an abandoned request.
class FrameSocket {
  /// Wraps [connection] and starts listening.
  FrameSocket(this.connection) {
    _sub = connection.messages.listen(
      _onMessage,
      onError: (Object e) => _error ??= e,
      onDone: _onDone,
    );
  }

  /// The wrapped connection.
  final WebSocketConnection connection;

  late final StreamSubscription<Object> _sub;
  final _closedCompleter = Completer<void>();
  Object? _error;
  bool _closed = false;

  /// A decoded JSON text frame.
  void Function(JsonMap frame)? onFrame;

  /// A binary frame.
  void Function(Uint8List bytes)? onBinary;

  /// A text frame that is not a JSON object.
  void Function(KugelAudioException error)? onBadFrame;

  /// The socket closed: the peer's close [code] and [reason], `null` for a
  /// drop without a close frame.
  void Function(int? code, String? reason)? onClosed;

  /// Whether the socket is still open.
  bool get isOpen => !_closed;

  /// Completes once the socket closed.
  Future<void> get closed => _closedCompleter.future;

  /// The close code the peer sent, once closed.
  int? get closeCode => connection.closeCode;

  /// Sends [frame] as a JSON text frame.
  void sendJson(JsonMap frame) => connection.send(jsonEncode(frame));

  /// Sends a binary frame.
  void sendBytes(List<int> bytes) => connection.send(bytes);

  /// Closes the socket, waiting at most [closeTimeout] for the peer.
  Future<void> close([int code = 1000]) async {
    final wasOpen = !_closed;
    // Closed first: a close the SDK asked for is not reported to onClosed.
    _markClosed();
    if (wasOpen) {
      try {
        await connection.close(code).timeout(closeTimeout);
      } on TimeoutException {
        // KEEP-JUSTIFIED: the peer did not answer the close handshake; the
        // socket is abandoned either way.
      }
    }
    await _sub.cancel();
  }

  void _onMessage(Object message) {
    if (_closed) return;
    if (message is Uint8List) {
      onBinary?.call(message);
      return;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(message as String);
    } on FormatException {
      onBadFrame?.call(KugelAudioException(
          'Unexpected non-JSON frame from the KugelAudio server.'));
      return;
    }
    if (decoded is Map) {
      onFrame?.call(decoded.cast<String, Object?>());
    } else {
      onBadFrame?.call(KugelAudioException(
          'Unexpected frame from the KugelAudio server: not a JSON object.'));
    }
  }

  void _onDone() {
    if (_closed) return;
    _markClosed();
    onClosed?.call(connection.closeCode, connection.closeReason);
  }

  void _markClosed() {
    _closed = true;
    if (!_closedCompleter.isCompleted) _closedCompleter.complete();
  }

  /// The error the message stream reported before it closed, if any.
  Object? get streamError => _error;
}

/// Opens the SDK's WebSockets on one API host with one key.
class SocketOpener {
  /// Creates an opener.
  SocketOpener({
    required this.connector,
    required this.baseUrl,
    required this.apiKey,
    required this.timeout,
    this.pingInterval,
  });

  /// The platform (or injected) connector.
  final WebSocketConnector connector;

  /// The HTTP(S) base URL the WebSocket URLs derive from.
  final String baseUrl;

  /// The key, sent as `api_key` in the query.
  final String apiKey;

  /// The opening-handshake budget.
  final Duration timeout;

  /// Keep-alive ping interval for long-lived sockets, `null` for none.
  final Duration? pingInterval;

  /// The URL of [path] with [query] and the SDK metadata.
  Uri uri(String path, [Map<String, String> query = const {}]) =>
      webSocketUri(baseUrl, path, apiKey, query);

  /// Opens [path]; [keepalive] asks for pings at [pingInterval].
  Future<FrameSocket> open(
    String path, {
    Map<String, String> query = const {},
    bool keepalive = false,
  }) async {
    final connection = await connector(
      uri(path, query),
      timeout: timeout,
      pingInterval: keepalive ? pingInterval : null,
    );
    return FrameSocket(connection);
  }
}

/// The typed error for a socket that closed while work was in flight.
///
/// A recognised server close code keeps its specific error; any other code
/// (a drop, a bare normal close) means the stream ended incomplete.
KugelAudioException closeError(int? code, String? reason, String what) {
  if (code != null && WsCloseCodes.errorCodes.contains(code)) {
    return classifyWsClose(code, reason);
  }
  return ConnectionException(
    'KugelAudio WebSocket closed before $what '
    '(close code ${code ?? 'none'}). Retry on a new connection.',
  );
}

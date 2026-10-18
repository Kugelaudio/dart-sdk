import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:kugelaudio/kugelaudio.dart';

/// Scripted server side of one fake WebSocket.
typedef ServerScript = void Function(FakeConnection conn, Object message);

/// An in-memory [WebSocketConnection]; the test plays the server.
class FakeConnection implements WebSocketConnection {
  FakeConnection(this.uri, this._script);

  final Uri uri;
  final ServerScript _script;
  final _incoming = StreamController<Object>();

  /// Every message the client sent, in order.
  final List<Object> sent = [];

  /// Whether the client closed the socket.
  bool closedByClient = false;

  @override
  int? closeCode;

  @override
  String? closeReason;

  @override
  Stream<Object> get messages => _incoming.stream;

  /// The client's JSON text messages, decoded.
  List<Map<String, Object?>> get sentJson => [
        for (final m in sent)
          if (m is String) (jsonDecode(m) as Map).cast<String, Object?>(),
      ];

  /// The client's binary messages.
  List<List<int>> get sentBytes => [
        for (final m in sent)
          if (m is List<int>) m,
      ];

  @override
  void send(Object message) {
    if (_incoming.isClosed) throw StateError('send after close');
    sent.add(message);
    _script(this, message);
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    closedByClient = true;
    closeCode ??= code;
    if (!_incoming.isClosed) await _incoming.close();
  }

  /// Server: sends a JSON text frame.
  void push(Map<String, Object?> frame) {
    if (!_incoming.isClosed) _incoming.add(jsonEncode(frame));
  }

  /// Server: sends a binary frame.
  void pushBytes(List<int> bytes) {
    if (!_incoming.isClosed) _incoming.add(Uint8List.fromList(bytes));
  }

  /// Server: closes the socket with [code].
  void serverClose(int? code, [String reason = '']) {
    closeCode = code;
    closeReason = reason;
    if (!_incoming.isClosed) unawaited(_incoming.close());
  }
}

/// A fake [WebSocketConnector]: each connect runs the script returned by
/// [scriptFor] (by connection number, 0-based).
class FakeServer {
  FakeServer(this.scriptFor);

  /// A server where every connection runs [script].
  FakeServer.all(ServerScript script) : scriptFor = ((_) => script);

  final ServerScript Function(int index) scriptFor;
  final List<FakeConnection> connections = [];

  /// When set, the next connect throws it.
  Object? refuseWith;

  Future<WebSocketConnection> connect(
    Uri uri, {
    required Duration timeout,
    Duration? pingInterval,
  }) async {
    final refusal = refuseWith;
    if (refusal != null) {
      refuseWith = null;
      throw refusal;
    }
    final conn = FakeConnection(uri, scriptFor(connections.length));
    connections.add(conn);
    return conn;
  }
}

/// Decodes a client message the test knows is JSON.
Map<String, Object?> json(Object message) =>
    (jsonDecode(message as String) as Map).cast<String, Object?>();

/// A base64 audio frame of [bytes] PCM16 bytes.
Map<String, Object?> audioFrame(int idx,
        {int bytes = 4, String? contextId, int sr = 24000}) =>
    {
      'audio': base64.encode(List<int>.filled(bytes, idx + 1)),
      'enc': 'pcm_s16le',
      'idx': idx,
      'sr': sr,
      'samples': bytes ~/ 2,
      'chunk_id': 0,
      if (contextId != null) 'context_id': contextId,
    };

/// A client on [server] with telemetry off and a test URL.
KugelAudio fakeClient(FakeServer server, {Duration? timeout}) => KugelAudio(
      apiKey: 'test-key',
      apiUrl: 'https://api.test',
      telemetry: false,
      timeout: timeout ?? const Duration(seconds: 5),
      webSocketConnector: server.connect,
    );

/// The log records of an OTLP diagnostics payload.
List<Map<String, Object?>> otlpRecords(Object? payload) {
  final resourceLogs = (payload! as Map)['resourceLogs'] as List;
  final scopeLogs = (resourceLogs.single as Map)['scopeLogs'] as List;
  final records = (scopeLogs.single as Map)['logRecords'] as List;
  return [for (final r in records) (r as Map).cast<String, Object?>()];
}

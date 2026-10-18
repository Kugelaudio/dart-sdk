import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

/// One open WebSocket, as the SDK uses it.
///
/// The default implementation wraps `package:web_socket_channel` on every
/// platform. Implement this to route the SDK's sockets through your own
/// transport (a proxy, a test double) and pass a [WebSocketConnector] to the
/// client.
abstract interface class WebSocketConnection {
  /// Incoming frames: a [String] for a text frame, a [Uint8List] for a
  /// binary frame. Single-subscription; it closes when the socket closes.
  Stream<Object> get messages;

  /// Sends a text frame ([String]) or a binary frame (`List<int>`).
  void send(Object message);

  /// Closes the socket with an optional close [code] and [reason].
  Future<void> close([int? code, String? reason]);

  /// The close code the peer sent, once [messages] is done; `null` while
  /// open or when the connection dropped without a close frame.
  int? get closeCode;

  /// The close reason the peer sent, once [messages] is done.
  String? get closeReason;
}

/// Opens a [WebSocketConnection] to [uri].
///
/// Must complete within [timeout] or throw. A refused upgrade should throw
/// the typed `KugelAudioException` from `classifyHandshakeRejection`, every
/// other failure to open a `ConnectionException`. [pingInterval], when not
/// null, asks the connection to send keep-alive pings at that interval where
/// the platform supports it.
typedef WebSocketConnector = Future<WebSocketConnection> Function(
  Uri uri, {
  required Duration timeout,
  Duration? pingInterval,
});

/// A [WebSocketConnection] over a `package:web_socket_channel` channel.
class ChannelConnection implements WebSocketConnection {
  /// Wraps an already connected [channel].
  ChannelConnection(this.channel);

  /// The wrapped channel.
  final WebSocketChannel channel;

  @override
  late final Stream<Object> messages = channel.stream.map<Object>((Object? m) {
    if (m is String) return m;
    if (m is Uint8List) return m;
    if (m is List<int>) return Uint8List.fromList(m);
    throw StateError('Unexpected WebSocket message type ${m.runtimeType}.');
  });

  @override
  void send(Object message) => channel.sink.add(message);

  @override
  Future<void> close([int? code, String? reason]) async {
    await channel.sink.close(code, reason);
  }

  @override
  int? get closeCode => channel.closeCode;

  @override
  String? get closeReason => channel.closeReason;
}

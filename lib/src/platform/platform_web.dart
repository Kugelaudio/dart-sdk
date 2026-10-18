import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../errors.dart';
import '../ws/connection.dart';

/// Whether this is a browser build.
const bool isWeb = true;

/// Browsers have no process environment; use `--dart-define` instead.
String? environmentVariable(String name) => null;

/// The browser does not report a Dart runtime version.
String? runtimeString() => null;

/// Opens a browser WebSocket.
///
/// A browser hides the HTTP status of a refused upgrade, so every failure
/// to open is a [ConnectionException]. Browsers send their own keep-alive
/// pings, so [pingInterval] is not used here.
Future<WebSocketConnection> connectWebSocket(
  Uri uri, {
  required Duration timeout,
  Duration? pingInterval,
}) async {
  final channel = WebSocketChannel.connect(uri);
  try {
    await channel.ready.timeout(timeout);
  } on TimeoutException {
    unawaited(channel.sink.close());
    throw ConnectionException(
      'WebSocket opening handshake timed out after ${timeout.inSeconds}s.',
    );
  } on WebSocketChannelException {
    throw ConnectionException(
      'Could not open a KugelAudio WebSocket. Check network connectivity '
      'and the API key.',
    );
  }
  return ChannelConnection(channel);
}

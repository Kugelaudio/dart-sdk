import '../ws/connection.dart';

/// Whether this is a browser build.
const bool isWeb = false;

/// An environment variable, where the platform has an environment.
String? environmentVariable(String name) => null;

/// `dart/<major>.<minor>.<patch>`, where the runtime reports it.
String? runtimeString() => null;

/// Opens a WebSocket. This platform has no WebSocket implementation.
Future<WebSocketConnection> connectWebSocket(
  Uri uri, {
  required Duration timeout,
  Duration? pingInterval,
}) =>
    throw UnsupportedError('WebSockets are not supported on this platform.');

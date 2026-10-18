import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:web_socket_channel/io.dart';

import '../errors.dart';
import '../ws/connection.dart';

/// Whether this is a browser build.
const bool isWeb = false;

/// An environment variable of the current process.
String? environmentVariable(String name) => Platform.environment[name];

/// `dart/<major>.<minor>.<patch>` of the running VM.
String? runtimeString() {
  final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)').firstMatch(Platform.version);
  return match == null ? null : 'dart/${match[1]}.${match[2]}.${match[3]}';
}

const _acceptGuid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const _maxRejectionBody = 16 * 1024;

/// Opens a WebSocket with an explicit HTTP upgrade.
///
/// `dart:io`'s own `WebSocket.connect` reports a refused upgrade only as a
/// message that contains the URL (and with it the API key in the query).
/// Doing the upgrade here keeps the status, the `x-request-id` and
/// `Retry-After` headers and the error body, so a refusal becomes the same
/// typed exception as on the HTTP API.
Future<WebSocketConnection> connectWebSocket(
  Uri uri, {
  required Duration timeout,
  Duration? pingInterval,
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  var opened = false;
  try {
    final socket = await _upgrade(client, uri).timeout(timeout);
    socket.pingInterval = pingInterval;
    opened = true;
    return ChannelConnection(IOWebSocketChannel(socket));
  } on TimeoutException {
    throw ConnectionException(
      'WebSocket opening handshake timed out after ${timeout.inSeconds}s.',
    );
  } on SocketException catch (e) {
    throw ConnectionException(
      'Could not reach KugelAudio at ${uri.host}: ${e.message}. '
      'Check network connectivity.',
    );
  } on HttpException catch (e) {
    throw ConnectionException(
      'KugelAudio WebSocket handshake failed: ${e.message}.',
    );
  } on HandshakeException catch (e) {
    throw ConnectionException(
      'TLS handshake with ${uri.host} failed: ${e.message}.',
    );
  } finally {
    // The upgraded socket is detached from the client, so closing the
    // client never touches it; a failed or timed-out upgrade is torn down.
    client.close(force: !opened);
  }
}

Future<WebSocket> _upgrade(HttpClient client, Uri uri) async {
  final httpUri = uri.replace(scheme: uri.scheme == 'wss' ? 'https' : 'http');
  final random = Random.secure();
  final nonce =
      base64.encode(List<int>.generate(16, (_) => random.nextInt(256)));
  final request = await client.openUrl('GET', httpUri);
  request.followRedirects = false;
  request.headers
    ..set(HttpHeaders.connectionHeader, 'Upgrade')
    ..set(HttpHeaders.upgradeHeader, 'websocket')
    ..set('Sec-WebSocket-Key', nonce)
    ..set('Sec-WebSocket-Version', '13');
  final response = await request.close();
  if (response.statusCode != HttpStatus.switchingProtocols) {
    final headers = <String, String>{};
    response.headers.forEach((name, values) {
      headers[name] = values.join(',');
    });
    final body = await _readBounded(response);
    throw classifyHandshakeRejection(response.statusCode, headers, body);
  }
  final expected =
      base64.encode(sha1.convert(utf8.encode('$nonce$_acceptGuid')).bytes);
  final accept = response.headers.value('Sec-WebSocket-Accept');
  if (accept != expected) {
    await response.drain<void>();
    throw ConnectionException(
      'KugelAudio WebSocket handshake failed: bad Sec-WebSocket-Accept.',
    );
  }
  final socket = await response.detachSocket();
  return WebSocket.fromUpgradedSocket(
    socket,
    serverSide: false,
    compression: CompressionOptions.compressionOff,
  );
}

Future<String> _readBounded(HttpClientResponse response) async {
  final bytes = <int>[];
  await for (final chunk in response) {
    final room = _maxRejectionBody - bytes.length;
    if (room <= 0) continue;
    bytes.addAll(chunk.length <= room ? chunk : chunk.sublist(0, room));
  }
  return utf8.decode(bytes, allowMalformed: true);
}

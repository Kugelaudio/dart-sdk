@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kugelaudio/kugelaudio.dart';
import 'package:kugelaudio/src/platform/platform_io.dart' as io;
import 'package:test/test.dart';

/// The real `dart:io` connector against an in-test server.
void main() {
  late HttpServer server;
  late Uri base;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('ws://127.0.0.1:${server.port}');
    server.listen((request) async {
      final key = request.uri.queryParameters['api_key'];
      if (key != 'good') {
        request.response
          ..statusCode = key == 'busy' ? 429 : 401
          ..headers.set('x-request-id', 'rejected-1')
          ..headers.set('retry-after', '4')
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'error':
                key == 'busy' ? 'Connection limit reached' : 'Invalid API key',
            'error_code': key == 'busy' ? 'RATE_LIMITED' : 'UNAUTHORIZED',
          }));
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((message) {
        if (message == 'close-4029') {
          socket.close(4029, 'slow down');
        } else {
          socket.add(message);
        }
      });
    });
  });

  tearDown(() => server.close(force: true));

  Future<WebSocketConnection> connect(String key) => io.connectWebSocket(
        base.replace(path: '/ws/tts', queryParameters: {'api_key': key}),
        timeout: const Duration(seconds: 5),
      );

  test('a refused upgrade keeps status, request id and Retry-After', () async {
    await expectLater(
      connect('bad'),
      throwsA(isA<AuthenticationException>()
          .having((e) => e.requestId, 'requestId', 'rejected-1')
          .having((e) => e.message, 'message', 'Invalid API key')),
    );
    await expectLater(
      connect('busy'),
      throwsA(isA<RateLimitException>().having(
          (e) => e.retryAfter, 'retryAfter', const Duration(seconds: 4))),
    );
  });

  test('the error never contains the key-bearing URL', () async {
    try {
      await connect('bad');
      fail('expected a refusal');
    } on KugelAudioException catch (e) {
      expect(e.toString(), isNot(contains('api_key')));
    }
  });

  test('an upgraded socket exchanges text and reports the close code',
      () async {
    final conn = await connect('good');
    final messages = StreamIterator(conn.messages);
    conn.send('{"hello":1}');
    expect(await messages.moveNext(), isTrue);
    expect(messages.current, '{"hello":1}');
    conn.send('close-4029');
    expect(await messages.moveNext(), isFalse);
    expect(conn.closeCode, 4029);
    expect(conn.closeReason, 'slow down');
  });

  test('an unreachable host is a ConnectionException', () async {
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();
    expect(
      io.connectWebSocket(Uri.parse('ws://127.0.0.1:$port/ws/tts'),
          timeout: const Duration(seconds: 2)),
      throwsA(isA<ConnectionException>()),
    );
  });
}

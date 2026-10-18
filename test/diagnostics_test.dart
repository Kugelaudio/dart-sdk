import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kugelaudio/kugelaudio.dart';
import 'package:kugelaudio/src/diagnostics/config.dart';
import 'package:kugelaudio/src/diagnostics/diagnostics.dart';
import 'package:test/test.dart';

import 'fake_ws.dart';

const hosted = 'https://api.kugelaudio.com';

/// A reporter whose deliveries are recorded; [status] answers each one.
(Diagnostics, List<List<Map<String, Object?>>>) recorder(
    {int Function()? status, bool autostart = false}) {
  final batches = <List<Map<String, Object?>>>[];
  final reporter = Diagnostics(
    DiagnosticsConfig.resolve(hosted,
        telemetry: true,
        authHeaders: const {'X-API-Key': 'k'},
        environment: (_) => null),
    autostart: autostart,
    sender: (url, headers, body) async {
      expect(url.toString(), '$hosted/v1/sdk-diagnostics');
      expect(headers['Content-Type'], 'application/json');
      expect(headers['X-API-Key'], 'k');
      batches.add(otlpRecords(jsonDecode(utf8.decode(body))));
      return status?.call() ?? 202;
    },
  );
  return (reporter, batches);
}

Map<String, Object?> attrs(Map<String, Object?> record) => {
      for (final a in record['attributes']! as List)
        (a as Map)['key'] as String: ((a['value'] as Map).values.single),
    };

void main() {
  group('enablement', () {
    String? none(String _) => null;

    test('on by default for the hosted API, off for custom endpoints', () {
      expect(
          DiagnosticsConfig.resolve(hosted, environment: none).enabled, isTrue);
      expect(
          DiagnosticsConfig.resolve('https://api.eu.kugelaudio.com',
                  environment: none)
              .endpointKind,
          'hosted');
      final custom =
          DiagnosticsConfig.resolve('http://localhost:8000', environment: none);
      expect(custom.enabled, isFalse);
      expect(custom.endpointKind, 'custom');
    });

    test('the option overrides the default, the env var overrides both', () {
      expect(
          DiagnosticsConfig.resolve(hosted, telemetry: false, environment: none)
              .enabled,
          isFalse);
      expect(
          DiagnosticsConfig.resolve(hosted,
              telemetry: true, environment: (_) => 'off').enabled,
          isFalse);
      expect(
          DiagnosticsConfig.resolve('http://onprem',
              telemetry: false, environment: (_) => 'YES').enabled,
          isTrue);
      expect(
          DiagnosticsConfig.resolve(hosted, environment: (_) => 'maybe')
              .enabled,
          isTrue);
    });

    test('the target is the API host', () {
      expect(DiagnosticsConfig.resolve('$hosted/', environment: none).url,
          Uri.parse('$hosted/v1/sdk-diagnostics'));
    });
  });

  test('encoding drops every attribute outside the allowlist', () {
    final encoded = encodeAttributes({
      'kugel.event': 'request_failed',
      'kugel.http_status': 503,
      'kugel.elapsed_ms': '12',
      'text': 'secret input text',
      'kugel.error_code': null,
    });
    expect(encoded, [
      {
        'key': 'kugel.event',
        'value': {'stringValue': 'request_failed'},
      },
      {
        'key': 'kugel.http_status',
        'value': {'intValue': '503'},
      },
      {
        'key': 'kugel.elapsed_ms',
        'value': {'intValue': '12'},
      },
    ]);
  });

  group('operations', () {
    test('a handshake failure is connection_failed', () async {
      final (reporter, batches) = recorder();
      reporter
          .operation(
              DiagOp.streamSession, transportWebSocket, DiagStage.handshake)
          .fail(AuthenticationException(null, 401, null, 'rid'));
      await reporter.flush();
      final a = attrs(batches.single.single);
      expect(a['kugel.event'], 'connection_failed');
      expect(a['kugel.error_type'], 'AuthenticationException');
      expect(a['kugel.http_status'], '401');
      expect(a['kugel.server_request_id'], 'rid');
      expect(a['kugel.sdk.name'], 'dart');
      expect(a['kugel.endpoint_kind'], 'hosted');
      expect(a['kugel.operation_id'], hasLength(32));
    });

    test('a drop mid-stream is stream_interrupted with audio counts', () async {
      final (reporter, batches) = recorder();
      final op = reporter.operation(DiagOp.stream, transportWebSocket)
        ..expectAudio()
        ..recordChunk(100)
        ..recordChunk(50)
        ..wsCloseCode = 1006;
      op.fail(ConnectionException('dropped'));
      await reporter.flush();
      final a = attrs(batches.single.single);
      expect(a['kugel.event'], 'stream_interrupted');
      expect(a['kugel.failure_stage'], 'receiving_audio');
      expect(a['kugel.audio_chunks'], '2');
      expect(a['kugel.audio_bytes'], '150');
      expect(a['kugel.ws_close_code'], '1006');
    });

    test(
        'a server error frame is request_failed, after a retry '
        'retry_exhausted', () async {
      final (reporter, batches) = recorder();
      final server = buildException(status: 429, errorCode: 'RATE_LIMITED');
      reporter.operation(DiagOp.stream, transportWebSocket)
        ..expectAudio()
        ..markServerError(server)
        ..fail(server);
      reporter.operation(DiagOp.stream, transportWebSocket)
        ..recordRetry()
        ..fail(ServerRestartingException());
      await reporter.flush();
      final events =
          batches.expand((b) => b).map((r) => attrs(r)['kugel.event']);
      expect(events, ['request_failed', 'retry_exhausted']);
    });

    test('success and cancellation are only counted, once each', () async {
      final (reporter, batches) = recorder();
      reporter.operation(DiagOp.models, transportHttp)
        ..succeed()
        ..fail(Exception('ignored after settling'));
      reporter.operation(DiagOp.stream, transportWebSocket).cancel();
      await reporter.flush();
      expect(batches, isEmpty);
      expect(reporter.counters, {'success': 1, 'failure': 0, 'cancelled': 1});
      await reporter.close();
      final stats = attrs(batches.single.single);
      expect(stats['kugel.event'], 'sdk_stats');
      expect(stats['kugel.success_count'], '1');
      expect(stats['kugel.cancelled_count'], '1');
      expect(batches.single.single['severityText'], 'INFO');
    });
  });

  group('delivery', () {
    test('batches of at most 8 records', () async {
      final (reporter, batches) = recorder();
      for (var i = 0; i < 20; i++) {
        reporter.report(DiagEvent.requestFailed);
      }
      await reporter.flush();
      expect(batches.map((b) => b.length), [8, 8, 4]);
    });

    test('the queue keeps the newest 64 records', () {
      final (reporter, _) = recorder();
      for (var i = 0; i < 70; i++) {
        reporter.report(DiagEvent.requestFailed);
      }
      expect(reporter.pending, queueCapacity);
    });

    test('three 404s switch the reporter off', () async {
      final (reporter, batches) = recorder(status: () => 404);
      for (var i = 0; i < 3; i++) {
        reporter.report(DiagEvent.requestFailed);
        await reporter.flush();
      }
      expect(reporter.routeMissing, isTrue);
      reporter.report(DiagEvent.requestFailed);
      await reporter.flush();
      expect(batches, hasLength(3));
    });

    test('a 413 is not retried, a 500 is retried once', () async {
      var answer = 413;
      final (reporter, batches) = recorder(status: () => answer);
      reporter.report(DiagEvent.requestFailed);
      await reporter.flush();
      expect(batches, hasLength(1));
      answer = 500;
      reporter.report(DiagEvent.requestFailed);
      await reporter.flush();
      expect(batches, hasLength(3));
    });

    test('a failing sender never surfaces', () async {
      final reporter = Diagnostics(
        DiagnosticsConfig.resolve(hosted,
            telemetry: true, environment: (_) => null),
        sender: (_, __, ___) async => throw StateError('network down'),
      );
      reporter.report(DiagEvent.requestFailed);
      await reporter.flush();
      await reporter.close();
    });

    test('a disabled reporter sends nothing', () async {
      final reporter = Diagnostics.disabled();
      reporter.report(DiagEvent.requestFailed);
      expect(reporter.pending, 0);
      await reporter.close();
    });
  });

  test(
      'a failed client call is reported to the API host and never '
      'carries the request', () async {
    final posts = <http.Request>[];
    final client = KugelAudio(
      apiKey: 'secret-key',
      telemetry: true,
      httpClient: MockClient((request) async {
        if (request.url.path == '/v1/sdk-diagnostics') {
          posts.add(request);
          return http.Response('', 202);
        }
        return http.Response(
            '{"error":"Voice not found","error_code":"NOT_FOUND"}', 404,
            headers: {'x-request-id': 'req-9'});
      }),
    );
    expect(client.telemetryEnabled, isTrue);
    await expectLater(
        client.voices.get(123), throwsA(isA<NotFoundException>()));
    await client.close();
    expect(posts, hasLength(1));
    expect(posts.single.headers['Authorization'], 'Bearer secret-key');
    final body = posts.single.body;
    expect(body, contains('"request_failed"'));
    expect(body, contains('"req-9"'));
    expect(body, contains('"sdk_stats"'));
    expect(body, isNot(contains('secret-key')));
    expect(body, isNot(contains('/v1/voices')));
  });
}

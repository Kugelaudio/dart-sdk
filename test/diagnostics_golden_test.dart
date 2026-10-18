@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:kugelaudio/src/diagnostics/diagnostics.dart';
import 'package:test/test.dart';

import 'fake_ws.dart';

/// The SDK's golden diagnostics batch: one record per event type, together
/// covering every allowlisted attribute, with fixed ids and timestamps.
/// Regenerate with `UPDATE_GOLDEN=1 dart test test/diagnostics_golden_test.dart`.
const goldenPath = 'test/fixtures/diagnostics_golden_batch.json';

const _time = 1767225600000000000;

Map<String, Object?> _base(String event, String id) => {
      'kugel.event_id': '0a1b2c3d4e5f40718293a4b5c6d7e8f$id',
      'kugel.operation_id': '1b2c3d4e5f60718293a4b5c6d7e8f90$id',
      'kugel.sdk.name': 'dart',
      'kugel.sdk.version': '0.1.0',
      'kugel.runtime': 'dart/3.12.2',
      'kugel.integration': 'none',
      'kugel.endpoint_kind': 'hosted',
      'kugel.event': event,
    };

Map<String, Object?> _failure(
        String event, String id, Map<String, Object?> more) =>
    buildLogRecord(
      event,
      {
        ..._base(event, id),
        'kugel.outcome': 'failed',
        'kugel.elapsed_ms': 1840,
        'kugel.retry_count': 0,
        ...more,
      },
      timeUnixNano: _time,
    );

String encodeGolden() {
  final records = [
    _failure('connection_failed', '1', {
      'kugel.operation': 'stream_session',
      'kugel.transport': 'websocket',
      'kugel.failure_stage': 'handshake',
      'kugel.error_type': 'AuthenticationException',
      'kugel.error_code': 'UNAUTHORIZED',
      'kugel.http_status': 401,
      'kugel.server_request_id': '9f2c1b7e4a6d4c8fb0e5a3d719c26f84',
      'kugel.audio_chunks': 0,
      'kugel.audio_bytes': 0,
    }),
    _failure('request_failed', '2', {
      'kugel.operation': 'voices',
      'kugel.transport': 'http',
      'kugel.failure_stage': 'sending_request',
      'kugel.error_type': 'NotFoundException',
      'kugel.error_code': 'NOT_FOUND',
      'kugel.http_status': 404,
      'kugel.server_request_id': '4a6d4c8fb0e5a3d719c26f849f2c1b7e',
    }),
    _failure('stream_interrupted', '3', {
      'kugel.operation': 'stream',
      'kugel.transport': 'websocket',
      'kugel.failure_stage': 'receiving_audio',
      'kugel.error_type': 'ConnectionException',
      'kugel.ws_close_code': 1006,
      'kugel.audio_chunks': 12,
      'kugel.audio_bytes': 96000,
    }),
    _failure('retry_exhausted', '4', {
      'kugel.operation': 'multi_context',
      'kugel.transport': 'websocket',
      'kugel.failure_stage': 'awaiting_first_audio',
      'kugel.error_type': 'ServerRestartingException',
      'kugel.ws_close_code': 1012,
      'kugel.retry_count': 1,
    }),
    buildLogRecord(
      'sdk_stats',
      {
        ..._base('sdk_stats', '5'),
        'kugel.success_count': 412,
        'kugel.failure_count': 3,
        'kugel.cancelled_count': 9,
      },
      timeUnixNano: _time,
    ),
  ];
  final payload = jsonDecode(utf8.decode(buildPayload(records, '0.1.0')));
  return '${const JsonEncoder.withIndent('  ').convert(payload)}\n';
}

void main() {
  test('the encoder reproduces the golden batch exactly', () {
    final encoded = encodeGolden();
    final file = File(goldenPath);
    if (Platform.environment['UPDATE_GOLDEN'] == '1') {
      file.writeAsStringSync(encoded);
    }
    expect(encoded, file.readAsStringSync());
  });

  test('the golden batch covers every allowlisted attribute', () {
    final records =
        otlpRecords(jsonDecode(File(goldenPath).readAsStringSync()));
    final keys = {
      for (final r in records)
        for (final a in (r as Map)['attributes'] as List) (a as Map)['key'],
    };
    expect(keys, attributeTypes.keys.toSet());
    expect(records, hasLength(batchSize - 3));
  });
}

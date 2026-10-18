// Client-error diagnostics: a dependency-free OTLP/HTTP-JSON log reporter
// and the Operation seam public entry points wrap themselves in. Implements
// the SDK diagnostics contract (v3) shared with the Python, JavaScript and
// Java SDKs: attribute names, enablement order and delivery bounds are fixed
// there.
//
// Every unit of work mints an Operation carrying an operation id, start
// time, transport, audio counters and a retry count. On failure it reports
// exactly one event and the error continues unchanged. A caller-initiated
// cancellation is not a fault: it is only counted in `sdk_stats`. Records
// are encoded against a strict attribute allowlist, queued in a bounded
// queue and delivered in the background; telemetry never blocks a call,
// never throws into the caller and never logs above FINE.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:logging/logging.dart';

import '../errors.dart';
import '../platform/platform.dart' as platform;
import '../version.dart';
import 'config.dart';

final _log = Logger('kugelaudio.diagnostics');

/// Three consecutive 404s switch the reporter off (an ingress without the
/// route).
const int maxConsecutiveNotFound = 3;

/// Queue capacity; the oldest record is dropped on overflow.
const int queueCapacity = 64;

/// Records per POST, on every path.
const int batchSize = 8;

/// Time from the first queued record to its delivery.
const Duration flushInterval = Duration(seconds: 5);

/// Per-request timeout.
const Duration requestTimeout = Duration(seconds: 3);

/// The longest [Diagnostics.close] waits.
const Duration closeDeadline = Duration(seconds: 1);

/// `kugel.event` values.
abstract final class DiagEvent {
  /// Transport failure before any response.
  static const connectionFailed = 'connection_failed';

  /// A response or server error frame failed the operation.
  static const requestFailed = 'request_failed';

  /// An established stream dropped before completion.
  static const streamInterrupted = 'stream_interrupted';

  /// The operation failed after at least one retry.
  static const retryExhausted = 'retry_exhausted';

  /// Success, failure and cancellation counts, sent on close.
  static const sdkStats = 'sdk_stats';
}

/// `kugel.operation` values.
abstract final class DiagOp {
  /// `tts.generate`.
  static const generate = 'generate';

  /// `tts.stream`.
  static const stream = 'stream';

  /// A streaming session turn or connect.
  static const streamSession = 'stream_session';

  /// A multi-context turn or connect.
  static const multiContext = 'multi_context';

  /// The voices resource.
  static const voices = 'voices';

  /// The dictionaries resource.
  static const dictionaries = 'dictionaries';

  /// The models resource.
  static const models = 'models';
}

/// `kugel.failure_stage` values.
abstract final class DiagStage {
  /// Opening the transport.
  static const connecting = 'connecting';

  /// The WebSocket upgrade.
  static const handshake = 'handshake';

  /// Sending the request.
  static const sendingRequest = 'sending_request';

  /// Waiting for the first audio.
  static const awaitingFirstAudio = 'awaiting_first_audio';

  /// Receiving further audio.
  static const receivingAudio = 'receiving_audio';

  /// Ending the turn or session.
  static const finalizing = 'finalizing';
}

/// `kugel.transport` for HTTP calls.
const String transportHttp = 'http';

/// `kugel.transport` for WebSocket calls.
const String transportWebSocket = 'websocket';

const _string = 0;
const _int = 1;

/// The exact attribute allowlist; any other key is dropped when encoding.
const Map<String, int> attributeTypes = {
  'kugel.event': _string,
  'kugel.event_id': _string,
  'kugel.operation_id': _string,
  'kugel.operation': _string,
  'kugel.sdk.name': _string,
  'kugel.sdk.version': _string,
  'kugel.runtime': _string,
  'kugel.integration': _string,
  'kugel.transport': _string,
  'kugel.failure_stage': _string,
  'kugel.error_type': _string,
  'kugel.error_code': _string,
  'kugel.http_status': _int,
  'kugel.ws_close_code': _int,
  'kugel.server_request_id': _string,
  'kugel.elapsed_ms': _int,
  'kugel.audio_chunks': _int,
  'kugel.audio_bytes': _int,
  'kugel.retry_count': _int,
  'kugel.outcome': _string,
  'kugel.endpoint_kind': _string,
  'kugel.success_count': _int,
  'kugel.failure_count': _int,
  'kugel.cancelled_count': _int,
};

final _random = Random.secure();

/// 32 lowercase hex characters.
String newId() {
  final sb = StringBuffer();
  for (var i = 0; i < 16; i++) {
    sb.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// Encodes attributes, dropping every key outside [attributeTypes].
List<Map<String, Object?>> encodeAttributes(Map<String, Object?> attributes) {
  final out = <Map<String, Object?>>[];
  attributes.forEach((key, value) {
    final kind = attributeTypes[key];
    if (kind == null || value == null) return;
    if (kind == _int) {
      final number = value is int ? value : int.tryParse(value.toString());
      if (number == null) return;
      out.add({
        'key': key,
        'value': {'intValue': '$number'},
      });
    } else {
      out.add({
        'key': key,
        'value': {'stringValue': '$value'},
      });
    }
  });
  return out;
}

/// One OTLP log record; `sdk_stats` is INFO, every failure ERROR.
Map<String, Object?> buildLogRecord(
  String event,
  Map<String, Object?> attributes, {
  int? timeUnixNano,
}) {
  final stats = event == DiagEvent.sdkStats;
  return {
    'timeUnixNano':
        '${timeUnixNano ?? DateTime.now().microsecondsSinceEpoch * 1000}',
    'severityNumber': stats ? 9 : 17,
    'severityText': stats ? 'INFO' : 'ERROR',
    'body': {'stringValue': event},
    'attributes': encodeAttributes(attributes),
  };
}

/// The OTLP/HTTP JSON body for [records].
List<int> buildPayload(List<Map<String, Object?>> records, String version) {
  final body = {
    'resourceLogs': [
      {
        'resource': {
          'attributes': [
            {
              'key': 'service.name',
              'value': {'stringValue': 'kugelaudio-sdk'},
            },
            {
              'key': 'service.version',
              'value': {'stringValue': version},
            },
            {
              'key': 'telemetry.sdk.language',
              'value': {'stringValue': sdkName},
            },
          ],
        },
        'scopeLogs': [
          {
            'scope': {'name': 'kugelaudio.diagnostics', 'version': '1'},
            'logRecords': records,
          },
        ],
      },
    ],
  };
  return utf8.encode(jsonEncode(body));
}

/// Delivers one payload and returns the HTTP status. Throws only for a
/// transport failure; every response, 2xx or not, is a status.
typedef DiagnosticsSender = Future<int> Function(
  Uri url,
  Map<String, String> headers,
  List<int> body,
);

/// Bounded, off-path OTLP reporter. One per client.
class Diagnostics {
  /// Creates a reporter for [config], delivering through [sender].
  ///
  /// With [autostart] false, records stay queued until [flush]; tests use
  /// that to inspect the queue.
  Diagnostics(
    this.config, {
    DiagnosticsSender? sender,
    this.integration = 'none',
    String? version,
    this.autostart = true,
  })  : _sender = sender,
        version = version ?? packageVersion;

  /// A reporter that never sends anything.
  Diagnostics.disabled() : this(DiagnosticsConfig.disabled);

  /// Resolved enablement, target and auth.
  final DiagnosticsConfig config;

  /// `kugel.integration` for every record of this client.
  final String integration;

  /// `kugel.sdk.version`.
  final String version;

  /// Whether delivery starts on its own.
  final bool autostart;

  final DiagnosticsSender? _sender;
  final Queue<Map<String, Object?>> _records = Queue();
  Timer? _timer;
  Future<void>? _delivering;
  bool _closed = false;
  bool _routeMissing = false;
  int _consecutiveNotFound = 0;
  int _success = 0;
  int _failure = 0;
  int _cancelled = 0;

  /// Whether no network call may be made, for any reason.
  bool get inert => config.inert || _routeMissing || _sender == null;

  /// Whether three consecutive 404s switched the reporter off.
  bool get routeMissing => _routeMissing;

  /// Records waiting for delivery.
  int get pending => _records.length;

  /// Success, failure and cancellation counts so far.
  Map<String, int> get counters =>
      {'success': _success, 'failure': _failure, 'cancelled': _cancelled};

  /// Mints an operation; its id exists before anything connects.
  Operation operation(String? name, String transport, [String? stage]) =>
      Operation._(this, name, transport, stage);

  /// The OTLP record this reporter would queue for [event]. Pure.
  Map<String, Object?> record(
    String event, [
    Map<String, Object?> attributes = const {},
    int? timeUnixNano,
  ]) {
    final attrs = <String, Object?>{
      'kugel.event_id': newId(),
      'kugel.operation_id': newId(),
      'kugel.sdk.name': sdkName,
      'kugel.sdk.version': version,
      'kugel.runtime': platform.runtimeString(),
      'kugel.integration': integration,
      'kugel.endpoint_kind': config.endpointKind,
      ...attributes,
      'kugel.event': event,
    };
    return buildLogRecord(event, attrs, timeUnixNano: timeUnixNano);
  }

  /// Queues one event. Never throws, never waits on the network.
  void report(String event, [Map<String, Object?> attributes = const {}]) {
    try {
      if (inert || _closed) return;
      if (_records.length >= queueCapacity) _records.removeFirst();
      _records.add(record(event, attributes));
      if (!autostart) return;
      if (_records.length >= batchSize) {
        _kick();
      } else {
        _timer ??= Timer(flushInterval, _kick);
      }
    } catch (e) {
      // KEEP-JUSTIFIED: telemetry must never surface to the caller; the
      // contract caps its logging at debug level.
      _log.fine('diagnostics: dropping event $event', e);
    }
  }

  /// Counts a success (only reported in `sdk_stats`).
  void noteSuccess() => _success++;

  /// Counts a failure.
  void noteFailure() => _failure++;

  /// Counts a caller-initiated cancellation: never an event.
  void noteCancelled() => _cancelled++;

  void _kick() {
    _timer?.cancel();
    _timer = null;
    _delivering ??= _deliverAll().whenComplete(() => _delivering = null);
  }

  Future<void> _deliverAll() async {
    while (_records.isNotEmpty && !inert) {
      final batch = <Map<String, Object?>>[];
      while (batch.length < batchSize && _records.isNotEmpty) {
        batch.add(_records.removeFirst());
      }
      await _deliverBatch(batch);
    }
  }

  Future<void> _deliverBatch(List<Map<String, Object?>> batch) async {
    final payload = buildPayload(batch, version);
    final headers = {
      ...config.authHeaders,
      // Set last, so no caller header can displace it.
      'Content-Type': 'application/json',
    };
    for (var attempt = 0; attempt < 2; attempt++) {
      int status;
      try {
        status = await _sender!(config.url!, headers, payload)
            .timeout(requestTimeout);
      } catch (e) {
        // KEEP-JUSTIFIED: a transport failure of the reporter is absorbed;
        // it neither bumps nor resets the 404 streak. Retried once.
        _log.fine('diagnostics: delivery attempt failed', e);
        continue;
      }
      if (status >= 200 && status < 300) {
        _consecutiveNotFound = 0;
        return;
      }
      if (status == 404) {
        if (++_consecutiveNotFound >= maxConsecutiveNotFound) {
          _routeMissing = true;
          _records.clear();
        }
        return;
      }
      _consecutiveNotFound = 0;
      // A 413 can only be rejected again; never retried.
      if (status == 413) return;
    }
  }

  /// Delivers everything queued, waiting at most [timeout].
  Future<void> flush([Duration timeout = closeDeadline]) async {
    if (inert || _records.isEmpty && _delivering == null) return;
    _kick();
    final delivering = _delivering;
    if (delivering == null) return;
    try {
      await delivering.timeout(timeout);
    } on TimeoutException {
      // KEEP-JUSTIFIED: close waits at most one second; delivery goes on in
      // the background.
    }
  }

  /// Queues `sdk_stats` (when any count is non-zero), flushes, and waits at
  /// most [timeout]. Later reports are dropped.
  Future<void> close([Duration timeout = closeDeadline]) async {
    if (_closed) return;
    if (_success + _failure + _cancelled > 0) {
      report(DiagEvent.sdkStats, {
        'kugel.success_count': _success,
        'kugel.failure_count': _failure,
        'kugel.cancelled_count': _cancelled,
      });
    }
    _closed = true;
    await flush(timeout);
  }
}

/// One unit of work that independently succeeds or fails: a one-shot call,
/// an HTTP request, one session turn, or one session connect.
///
/// Reports at most one event: the first [succeed], [fail] or [cancel]
/// settles it and later calls do nothing.
class Operation {
  Operation._(this._diagnostics, this.name, this.transport, String? stage)
      : stage = stage ??
            (transport == transportHttp
                ? DiagStage.sendingRequest
                : DiagStage.connecting);

  final Diagnostics _diagnostics;
  final Stopwatch _clock = Stopwatch()..start();

  /// `kugel.operation_id`.
  final String id = newId();

  /// `kugel.operation`.
  final String? name;

  /// `kugel.transport`.
  final String transport;

  /// The current failure stage.
  String stage;

  /// Audio chunks received.
  int audioChunks = 0;

  /// Audio bytes received.
  int audioBytes = 0;

  /// Retries within this operation.
  int retryCount = 0;

  /// The close code of the socket that failed this operation.
  int? wsCloseCode;

  /// The server's error for this operation, when it sent an error frame.
  Object? serverError;

  /// Whether the operation succeeded, failed or was cancelled.
  bool settled = false;

  /// Enters the receive phase.
  void expectAudio() {
    stage = audioChunks > 0
        ? DiagStage.receivingAudio
        : DiagStage.awaitingFirstAudio;
  }

  /// Counts one received chunk of [bytes].
  void recordChunk(int bytes) {
    audioChunks++;
    audioBytes += bytes;
    if (stage == DiagStage.awaitingFirstAudio) {
      stage = DiagStage.receivingAudio;
    }
  }

  /// A new attempt of this operation; the previous attempt's details reset.
  void recordRetry() {
    retryCount++;
    serverError = null;
    wsCloseCode = null;
  }

  /// The server answered with an error frame: the event is
  /// `request_failed` (or `retry_exhausted`), never `stream_interrupted`.
  void markServerError(Object error) => serverError = error;

  /// Runs [body] as this operation: success when it completes, one event
  /// when it throws (the error is rethrown unchanged).
  Future<T> run<T>(Future<T> Function() body) async {
    try {
      final result = await body();
      succeed();
      return result;
    } catch (e) {
      fail(e);
      rethrow;
    }
  }

  /// Settles as a success.
  void succeed() {
    if (settled) return;
    settled = true;
    _diagnostics.noteSuccess();
  }

  /// Settles as a caller-initiated cancellation: counted, never reported.
  void cancel() {
    if (settled) return;
    settled = true;
    _diagnostics.noteCancelled();
  }

  /// Settles as a failure and reports one event for [error].
  void fail(Object error) {
    if (settled) return;
    settled = true;
    final reported = serverError ?? error;
    _diagnostics.noteFailure();
    _diagnostics.report(_eventName(), _attributes(reported));
  }

  String _eventName() {
    if (retryCount > 0) return DiagEvent.retryExhausted;
    if (serverError != null) return DiagEvent.requestFailed;
    if (stage == DiagStage.connecting || stage == DiagStage.handshake) {
      return DiagEvent.connectionFailed;
    }
    if (stage == DiagStage.awaitingFirstAudio ||
        stage == DiagStage.receivingAudio ||
        stage == DiagStage.finalizing) {
      return DiagEvent.streamInterrupted;
    }
    return DiagEvent.requestFailed;
  }

  Map<String, Object?> _attributes(Object error) {
    final typed = error is KugelAudioException ? error : null;
    return {
      'kugel.operation_id': id,
      'kugel.operation': name,
      'kugel.transport': transport,
      'kugel.failure_stage': stage,
      'kugel.elapsed_ms': _clock.elapsedMilliseconds,
      'kugel.audio_chunks': audioChunks,
      'kugel.audio_bytes': audioBytes,
      'kugel.retry_count': retryCount,
      'kugel.outcome': 'failed',
      'kugel.error_type': typed?.typeName ??
          (error is TimeoutException
              ? 'TimeoutException'
              : error is Error
                  ? 'Error'
                  : 'Exception'),
      'kugel.error_code': typed?.errorCode,
      'kugel.http_status': typed?.statusCode,
      'kugel.server_request_id': typed?.requestId,
      'kugel.ws_close_code': wsCloseCode,
    };
  }
}

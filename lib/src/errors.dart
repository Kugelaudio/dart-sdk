import 'dart:convert';

import 'config.dart' show apiKeysUrl, billingUrl;

/// Machine-readable `error_code` values the server sends.
abstract final class ErrorCodes {
  /// The API key was missing or rejected.
  static const unauthorized = 'UNAUTHORIZED';

  /// The organization hit its rate or concurrency limit.
  static const rateLimited = 'RATE_LIMITED';

  /// The organization is out of credits.
  static const insufficientCredits = 'INSUFFICIENT_CREDITS';

  /// The model is temporarily unavailable.
  static const modelUnavailable = 'MODEL_UNAVAILABLE';

  /// Generation produced no audio.
  static const emptyAudio = 'EMPTY_AUDIO';

  /// The request was invalid.
  static const validation = 'VALIDATION_ERROR';

  /// The server failed.
  static const internal = 'INTERNAL_ERROR';

  /// The resource does not exist or is not visible.
  static const notFound = 'NOT_FOUND';

  /// Synthesis was requested without a `voice_id`.
  static const missingVoiceId = 'MISSING_VOICE_ID';

  /// A multi-context socket already holds 20 live contexts.
  static const tooManyContexts = 'TOO_MANY_CONTEXTS';
}

/// Server-defined WebSocket close codes.
abstract final class WsCloseCodes {
  /// The API key is not accepted for this connection.
  static const unauthorized = 4001;

  /// The organization ran out of credits.
  static const insufficientCredits = 4003;

  /// The organization exceeded its rate limit.
  static const rateLimited = 4029;

  /// The model is temporarily unavailable.
  static const modelUnavailable = 4500;

  /// The replica is restarting during a rolling deploy (RFC 6455).
  static const serviceRestart = 1012;

  /// The replica accepted the connection only to report it is draining.
  static const tryAgainLater = 1013;

  /// Close codes that report an error the caller must see.
  static const errorCodes = {
    unauthorized,
    insufficientCredits,
    rateLimited,
    modelUnavailable,
    serviceRestart,
    tryAgainLater,
  };

  /// Close codes of a rolling deploy: retryable, not a request failure.
  static const restartCodes = {serviceRestart, tryAgainLater};
}

/// Base class of every error this SDK throws for a failed API call.
///
/// Each exception carries a human-readable [message] and, when known, the
/// HTTP [statusCode], the server's machine-readable [errorCode], the
/// [requestId] to quote to support, and a [retryAfter] hint.
class KugelAudioException implements Exception {
  /// Creates an exception.
  KugelAudioException(
    this.message, {
    this.statusCode,
    this.errorCode,
    this.requestId,
    this.retryAfter,
  });

  /// Human-readable, actionable description. Not for program logic.
  final String message;

  /// HTTP status (or the `code` of a WebSocket error frame), if known.
  final int? statusCode;

  /// The server's `error_code`, e.g. `RATE_LIMITED`, if known.
  final String? errorCode;

  /// The correlation id of the call (`x-request-id` header or the
  /// `request_id` of a WebSocket error frame), if the server sent one.
  final String? requestId;

  /// How long to wait before retrying, if the server said so.
  final Duration? retryAfter;

  /// The exception's class name, stable under web minification.
  String get typeName => 'KugelAudioException';

  @override
  String toString() {
    final id = requestId == null ? '' : ' (request_id: $requestId)';
    return '$typeName: $message$id';
  }
}

/// The API key was missing, malformed, or rejected.
class AuthenticationException extends KugelAudioException {
  /// Creates an authentication error with a default actionable message.
  AuthenticationException([
    String? message,
    int? statusCode,
    String? errorCode,
    String? requestId,
    Duration? retryAfter,
  ]) : super(
          message ??
              'KugelAudio rejected the API key. Check it is current at '
                  '$apiKeysUrl.',
          statusCode: statusCode ?? 401,
          errorCode: errorCode ?? ErrorCodes.unauthorized,
          requestId: requestId,
          retryAfter: retryAfter,
        );

  @override
  String get typeName => 'AuthenticationException';
}

/// The request was rejected by the per-organization rate limiter.
class RateLimitException extends KugelAudioException {
  /// Creates a rate-limit error; the default message quotes [retryAfter].
  RateLimitException([
    String? message,
    int? statusCode,
    String? errorCode,
    String? requestId,
    Duration? retryAfter,
  ]) : super(
          message ??
              (retryAfter != null
                  ? 'KugelAudio rate limit hit; retry after '
                      '${retryAfter.inSeconds}s.'
                  : 'KugelAudio rate limit hit; retry shortly.'),
          statusCode: statusCode ?? 429,
          errorCode: errorCode ?? ErrorCodes.rateLimited,
          requestId: requestId,
          retryAfter: retryAfter,
        );

  @override
  String get typeName => 'RateLimitException';
}

/// The account is out of credits.
class InsufficientCreditsException extends KugelAudioException {
  /// Creates an insufficient-credits error with a default message.
  InsufficientCreditsException([
    String? message,
    int? statusCode,
    String? errorCode,
    String? requestId,
    Duration? retryAfter,
  ]) : super(
          message ??
              'Your KugelAudio account is out of credits. Top up at '
                  '$billingUrl.',
          statusCode: statusCode ?? 402,
          errorCode: errorCode ?? ErrorCodes.insufficientCredits,
          requestId: requestId,
          retryAfter: retryAfter,
        );

  @override
  String get typeName => 'InsufficientCreditsException';
}

/// The request was rejected as invalid (bad parameters, missing fields).
class ValidationException extends KugelAudioException {
  /// Creates a validation error.
  ValidationException(
    super.message, {
    int? statusCode,
    String? errorCode,
    super.requestId,
    super.retryAfter,
  }) : super(
          statusCode: statusCode ?? 400,
          errorCode: errorCode ?? ErrorCodes.validation,
        );

  @override
  String get typeName => 'ValidationException';
}

/// A referenced resource does not exist or is not visible to the caller.
class NotFoundException extends KugelAudioException {
  /// Creates a not-found error.
  NotFoundException([
    String? message,
    int? statusCode,
    String? errorCode,
    String? requestId,
    Duration? retryAfter,
  ]) : super(
          message ?? 'Not found.',
          statusCode: statusCode ?? 404,
          errorCode: errorCode ?? ErrorCodes.notFound,
          requestId: requestId,
          retryAfter: retryAfter,
        );

  @override
  String get typeName => 'NotFoundException';
}

/// The SDK could not reach KugelAudio: a network error, a dropped socket,
/// or a model that is temporarily unavailable.
class ConnectionException extends KugelAudioException {
  /// Creates a connection error.
  ConnectionException(
    super.message, {
    int? statusCode,
    super.errorCode,
    super.requestId,
    super.retryAfter,
  }) : super(statusCode: statusCode ?? 503);

  @override
  String get typeName => 'ConnectionException';
}

/// The replica serving this WebSocket is restarting (rolling deploy).
///
/// Streaming and multi-context sessions absorb a restart on their own while
/// the turn is still silent: they reconnect after [retryAfter] and replay
/// the turn. This error therefore only reaches the caller when audio of the
/// turn was already delivered (a replay would repeat it) or the turn was
/// replayed once already. Reconnect and resend the turn that was in flight;
/// audio already received is complete up to the last chunk.
class ServerRestartingException extends ConnectionException {
  /// Creates a restart error; [retryAfter] defaults to one second.
  ServerRestartingException({
    String? message,
    super.requestId,
    Duration? retryAfter,
  }) : super(
          message ??
              'KugelAudio replica is restarting (rolling deploy). Reconnect '
                  'and resend the current turn; audio already received is '
                  'complete up to the last chunk.',
          retryAfter: retryAfter ?? const Duration(seconds: 1),
        );

  @override
  String get typeName => 'ServerRestartingException';
}

/// Picks the exception class for a status / `error_code` pair, the same
/// mapping for HTTP responses and WebSocket error frames.
KugelAudioException buildException({
  int? status,
  String? errorCode,
  String message = '',
  String? requestId,
  Duration? retryAfter,
}) {
  final msg = message.isEmpty ? null : message;
  if (errorCode == ErrorCodes.unauthorized || status == 401) {
    return AuthenticationException(
        msg, status, errorCode, requestId, retryAfter);
  }
  if (errorCode == ErrorCodes.insufficientCredits || status == 402) {
    return InsufficientCreditsException(
        msg, status, errorCode, requestId, retryAfter);
  }
  if (errorCode == ErrorCodes.rateLimited ||
      errorCode == ErrorCodes.tooManyContexts ||
      status == 429) {
    return RateLimitException(msg, status, errorCode, requestId, retryAfter);
  }
  if (errorCode == ErrorCodes.validation ||
      errorCode == ErrorCodes.missingVoiceId ||
      status == 400) {
    return ValidationException(
      msg ?? 'Request validation failed.',
      statusCode: status,
      errorCode: errorCode,
      requestId: requestId,
      retryAfter: retryAfter,
    );
  }
  if (errorCode == ErrorCodes.modelUnavailable || status == 503) {
    return ConnectionException(
      'KugelAudio is temporarily unavailable: '
      '${msg ?? 'service temporarily unavailable'}. Retry shortly.',
      statusCode: status,
      errorCode: errorCode,
      requestId: requestId,
      retryAfter: retryAfter,
    );
  }
  if (errorCode == ErrorCodes.notFound || status == 404) {
    return NotFoundException(msg, status, errorCode, requestId, retryAfter);
  }
  return KugelAudioException(
    msg ?? 'HTTP $status',
    statusCode: status,
    errorCode: errorCode,
    requestId: requestId,
    retryAfter: retryAfter,
  );
}

String? _header(Map<String, String> headers, String name) {
  final lower = name.toLowerCase();
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == lower && entry.value.isNotEmpty) {
      return entry.value;
    }
  }
  return null;
}

Duration? _seconds(Object? value) {
  if (value is int) return Duration(seconds: value);
  if (value is String) {
    final parsed = int.tryParse(value.trim());
    if (parsed != null) return Duration(seconds: parsed);
  }
  return null;
}

/// Builds the typed exception for a failed HTTP response.
///
/// Reads the structured `{error, error_code, retry_after}` body, falls back
/// to a `detail` field and then to the raw text; `Retry-After` and
/// `x-request-id` come from the headers.
KugelAudioException classifyHttpResponse(
  int status,
  Map<String, String> headers,
  String body,
) {
  String? errorCode;
  String? message;
  Duration? retryAfter;
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    decoded = null;
  }
  if (decoded is Map) {
    final code = decoded['error_code'];
    if (code is String) errorCode = code;
    final raw = decoded['error'] ?? decoded['detail'];
    if (raw is String) {
      message = raw;
    } else if (raw is List) {
      message = raw.map((m) => m.toString()).join('; ');
    } else if (raw != null) {
      message = raw.toString();
    }
    final ra = decoded['retry_after'];
    if (ra is int) retryAfter = Duration(seconds: ra);
  }
  retryAfter ??= _seconds(_header(headers, 'Retry-After'));
  if (message == null || message.isEmpty) message = body.trim();
  return buildException(
    status: status,
    errorCode: errorCode,
    message: message,
    requestId: _header(headers, 'X-Request-Id'),
    retryAfter: retryAfter,
  );
}

/// Builds the typed exception for a server WebSocket error frame
/// (`{error, error_code, code, request_id, retry_after}`).
KugelAudioException classifyWsFrame(Map<String, Object?> frame) {
  final code = frame['code'];
  final errorCode = frame['error_code'];
  final error = frame['error'];
  final requestId = frame['request_id'];
  return buildException(
    status: code is int ? code : null,
    errorCode: errorCode is String ? errorCode : null,
    message: error is String && error.isNotEmpty
        ? error
        : 'Server reported an error.',
    requestId: requestId is String && requestId.isNotEmpty ? requestId : null,
    retryAfter: frame['retry_after'] is int
        ? Duration(seconds: frame['retry_after']! as int)
        : null,
  );
}

/// Builds the typed exception for a refused WebSocket upgrade.
///
/// The server rejects a bad key on a WebSocket upgrade with HTTP 403, so a
/// 403 here is an [AuthenticationException]; `x-request-id` and
/// `Retry-After` come from the rejection response.
KugelAudioException classifyHandshakeRejection(
  int status,
  Map<String, String> headers, [
  String body = '',
]) {
  final requestId = _header(headers, 'X-Request-Id');
  final retryAfter = _seconds(_header(headers, 'Retry-After'));
  if (status == 403) {
    return AuthenticationException(null, null, null, requestId, retryAfter);
  }
  var message = 'WebSocket upgrade refused with HTTP $status.';
  String? errorCode;
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    // KEEP-JUSTIFIED: a non-JSON rejection body keeps the status message.
    decoded = null;
  }
  if (decoded is Map) {
    if (decoded['error'] is String) message = decoded['error'] as String;
    if (decoded['error_code'] is String) {
      errorCode = decoded['error_code'] as String;
    }
  }
  return buildException(
    status: status,
    errorCode: errorCode,
    message: message,
    requestId: requestId,
    retryAfter: retryAfter,
  );
}

/// Builds the typed exception for a WebSocket close [code] and [reason].
KugelAudioException classifyWsClose(int? code, [String? reason]) {
  final why = (reason ?? '').trim();
  switch (code) {
    case WsCloseCodes.unauthorized:
      final base =
          'KugelAudio rejected the API key. Check it is current at $apiKeysUrl.';
      return AuthenticationException(why.isEmpty ? base : '$base ($why)');
    case WsCloseCodes.insufficientCredits:
      return InsufficientCreditsException();
    case WsCloseCodes.rateLimited:
      return RateLimitException();
    case WsCloseCodes.modelUnavailable:
      return ConnectionException(
        'KugelAudio model is temporarily unavailable. Retry shortly.'
        '${why.isEmpty ? '' : ' ($why)'}',
      );
    case WsCloseCodes.serviceRestart:
    case WsCloseCodes.tryAgainLater:
      return ServerRestartingException();
  }
  final detail = why.isEmpty ? 'no reason given' : why;
  final codeText = code == null ? '' : ' (code $code)';
  return ConnectionException(
    'KugelAudio WebSocket closed by server: $detail$codeText.',
  );
}

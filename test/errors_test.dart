import 'package:kugelaudio/kugelaudio.dart';
import 'package:test/test.dart';

void main() {
  group('buildException', () {
    final cases = <(int?, String?, Type)>[
      (401, null, AuthenticationException),
      (null, 'UNAUTHORIZED', AuthenticationException),
      (402, null, InsufficientCreditsException),
      (null, 'INSUFFICIENT_CREDITS', InsufficientCreditsException),
      (429, null, RateLimitException),
      (429, 'TOO_MANY_CONTEXTS', RateLimitException),
      (400, null, ValidationException),
      (400, 'MISSING_VOICE_ID', ValidationException),
      (503, 'MODEL_UNAVAILABLE', ConnectionException),
      (404, 'NOT_FOUND', NotFoundException),
      (500, 'INTERNAL_ERROR', KugelAudioException),
      (409, 'SPEAKER_CONSENT_MISSING', KugelAudioException),
    ];
    for (final (status, code, type) in cases) {
      test('$status / $code -> $type', () {
        final e = buildException(status: status, errorCode: code);
        expect(e.runtimeType, type);
      });
    }

    test('keeps the server status and code over the defaults', () {
      final e = buildException(status: 403, errorCode: 'UNAUTHORIZED');
      expect(e, isA<AuthenticationException>());
      expect(e.statusCode, 403);
      expect(e.errorCode, 'UNAUTHORIZED');
    });

    test('defaults are actionable', () {
      expect(AuthenticationException().message, contains('settings/api-keys'));
      expect(InsufficientCreditsException().message, contains('billing'));
      expect(
          RateLimitException(null, null, null, null, const Duration(seconds: 7))
              .message,
          contains('7s'));
    });
  });

  group('classifyHttpResponse', () {
    test('reads error, error_code, request id and Retry-After', () {
      final e = classifyHttpResponse(
        429,
        {'x-request-id': 'req-1', 'retry-after': '12'},
        '{"error":"Rate limit exceeded","error_code":"RATE_LIMITED","code":429}',
      );
      expect(e, isA<RateLimitException>());
      expect(e.message, 'Rate limit exceeded');
      expect(e.requestId, 'req-1');
      expect(e.retryAfter, const Duration(seconds: 12));
      expect(e.toString(), contains('request_id: req-1'));
    });

    test('falls back to detail lists and raw text', () {
      final detail = classifyHttpResponse(
          422, const {}, '{"detail":["a missing","b wrong"]}');
      expect(detail.message, 'a missing; b wrong');
      final raw = classifyHttpResponse(502, const {}, 'Bad gateway');
      expect(raw.message, 'Bad gateway');
      expect(raw.statusCode, 502);
    });
  });

  test('classifyWsFrame uses code, error_code and request_id', () {
    final e = classifyWsFrame({
      'error': 'voice_id is required',
      'error_code': 'MISSING_VOICE_ID',
      'code': 400,
      'request_id': 'abc',
    });
    expect(e, isA<ValidationException>());
    expect(e.requestId, 'abc');
    expect(e.message, 'voice_id is required');
  });

  group('classifyWsClose', () {
    test('maps the server close codes', () {
      expect(classifyWsClose(4001), isA<AuthenticationException>());
      expect(classifyWsClose(4003), isA<InsufficientCreditsException>());
      expect(classifyWsClose(4029), isA<RateLimitException>());
      expect(classifyWsClose(4500), isA<ConnectionException>());
      expect(classifyWsClose(1012), isA<ServerRestartingException>());
      expect(classifyWsClose(1013), isA<ServerRestartingException>());
      expect(classifyWsClose(1012).retryAfter, const Duration(seconds: 1));
    });

    test('any other code is a ConnectionException with the reason', () {
      final e = classifyWsClose(1011, 'boom');
      expect(e.runtimeType, ConnectionException);
      expect(e.message, contains('boom'));
      expect(e.message, contains('1011'));
    });
  });

  group('classifyHandshakeRejection', () {
    test('403 on an upgrade is an authentication failure', () {
      final e = classifyHandshakeRejection(403, {'X-Request-Id': 'r9'});
      expect(e, isA<AuthenticationException>());
      expect(e.requestId, 'r9');
    });

    test('429 keeps Retry-After and the body message', () {
      final e = classifyHandshakeRejection(
        429,
        {'retry-after': '3'},
        '{"error":"Connection limit reached","error_code":"RATE_LIMITED"}',
      );
      expect(e, isA<RateLimitException>());
      expect(e.retryAfter, const Duration(seconds: 3));
      expect(e.message, 'Connection limit reached');
    });
  });

  test('ServerRestartingException is a ConnectionException', () {
    expect(ServerRestartingException(), isA<ConnectionException>());
  });
}

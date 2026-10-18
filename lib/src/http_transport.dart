import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config.dart';
import 'diagnostics/diagnostics.dart';
import 'errors.dart';

/// `kugel.operation` for a REST path: `/v1/voices/12/references` -> voices.
String? operationForPath(String path) {
  var trimmed = path.startsWith('/') ? path.substring(1) : path;
  if (trimmed.startsWith('v1/')) trimmed = trimmed.substring(3);
  final head = trimmed.split('/').first;
  return switch (head) {
    'models' => DiagOp.models,
    'voices' => DiagOp.voices,
    'dictionaries' => DiagOp.dictionaries,
    'tts' => DiagOp.generate,
    _ => null,
  };
}

/// The client's REST transport: auth and SDK headers, timeouts, typed
/// errors and one diagnostics operation per call.
class HttpTransport {
  /// Creates a transport on [apiUrl].
  HttpTransport({
    required this.client,
    required this.apiUrl,
    required this.headers,
    required this.timeout,
    required this.diagnostics,
  });

  /// The HTTP client; owned by the `KugelAudio` client.
  final http.Client client;

  /// The API base URL.
  final String apiUrl;

  /// Auth and SDK headers sent with every request.
  final Map<String, String> headers;

  /// Budget for one request, response body included.
  final Duration timeout;

  /// The client's diagnostics reporter.
  final Diagnostics diagnostics;

  /// Sends a JSON request and decodes the JSON response (`null` for an
  /// empty body or 204).
  Future<Object?> json(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    final response = await send(method, path, query: query, jsonBody: body);
    return _decode(response, method, path);
  }

  /// Sends a `multipart/form-data` request of [parts] and decodes the JSON
  /// response.
  Future<Object?> multipart(
    String method,
    String path,
    List<http.MultipartFile> parts, {
    Map<String, String>? query,
  }) async {
    final response = await send(method, path, query: query, parts: parts);
    return _decode(response, method, path);
  }

  /// Sends one request and returns the successful response; a status of
  /// 400 or above becomes the typed [KugelAudioException].
  ///
  /// Pass [jsonBody] for a JSON body or [parts] for a multipart body.
  /// [operation] overrides the diagnostics operation derived from [path].
  Future<http.Response> send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? jsonBody,
    List<http.MultipartFile>? parts,
    Map<String, String> extraHeaders = const {},
    bool diagnosed = true,
  }) {
    Future<http.Response> attempt() =>
        _send(method, path, query, jsonBody, parts, extraHeaders);
    if (!diagnosed) return attempt();
    final op = diagnostics.operation(operationForPath(path), transportHttp);
    return op.run(attempt);
  }

  Future<http.Response> _send(
    String method,
    String path,
    Map<String, String>? query,
    Object? jsonBody,
    List<http.MultipartFile>? parts,
    Map<String, String> extraHeaders,
  ) async {
    final url = httpUri(apiUrl, path, query);
    final abort = Completer<void>();
    final timer = Timer(timeout, () {
      if (!abort.isCompleted) abort.complete();
    });
    final http.BaseRequest request;
    if (parts != null) {
      request = http.AbortableMultipartRequest(method, url,
          abortTrigger: abort.future)
        ..files.addAll(parts);
    } else {
      final r = http.AbortableRequest(method, url, abortTrigger: abort.future);
      if (jsonBody != null) {
        r.headers['Content-Type'] = 'application/json; charset=utf-8';
        r.bodyBytes = utf8.encode(jsonEncode(jsonBody));
      }
      request = r;
    }
    request.headers
      ..addAll(headers)
      ..addAll(extraHeaders);
    http.Response response;
    try {
      // The timeout also covers clients that ignore the abort trigger.
      response = await client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(timeout);
    } on TimeoutException {
      throw _timedOut(method, path);
    } on http.RequestAbortedException {
      throw _timedOut(method, path);
    } on http.ClientException catch (e) {
      throw ConnectionException(
        'Could not reach KugelAudio at ${url.origin}: ${e.message}. '
        'Check network connectivity.',
      );
    } finally {
      timer.cancel();
    }
    if (response.statusCode >= 400) {
      throw classifyHttpResponse(
        response.statusCode,
        response.headers,
        utf8.decode(response.bodyBytes, allowMalformed: true),
      );
    }
    return response;
  }

  ConnectionException _timedOut(String method, String path) =>
      ConnectionException(
        'Request to $method $path timed out after ${timeout.inSeconds}s.',
      );
}

/// The `x-request-id` of [response], if any.
String? requestIdOf(http.Response response) => response.headers['x-request-id'];

Object? _decode(http.Response response, String method, String path) {
  if (response.statusCode == 204 || response.bodyBytes.isEmpty) return null;
  try {
    return jsonDecode(utf8.decode(response.bodyBytes));
  } on FormatException {
    throw KugelAudioException(
      'Unexpected response from $method $path: not JSON.',
      statusCode: response.statusCode,
      requestId: requestIdOf(response),
    );
  }
}

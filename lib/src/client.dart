import 'dart:async';

import 'package:http/http.dart' as http;

import 'config.dart';
import 'diagnostics/config.dart';
import 'diagnostics/diagnostics.dart';
import 'enhance/enhance.dart';
import 'errors.dart';
import 'http_transport.dart';
import 'platform/platform.dart' as platform;
import 'resources/dictionaries.dart';
import 'resources/models.dart';
import 'resources/voices.dart';
import 'tts/tts_resource.dart';
import 'ws/connection.dart';
import 'ws/frame_socket.dart';

/// The KugelAudio API client.
///
/// ```dart
/// final client = KugelAudio(apiKey: 'YOUR_API_KEY');
/// final models = await client.models.list();
/// final voices = await client.voices.list(language: 'en');
/// final audio = await client.tts.generate(
///   text: 'Hello, world!',
///   voiceId: voices.voices.first.id,
///   language: 'en',
/// );
/// await client.close();
/// ```
///
/// One client holds one HTTP client and at most one pooled TTS socket;
/// reuse it for the life of your app and [close] it at the end.
class KugelAudio {
  /// Creates a client.
  ///
  /// [apiKey] may carry an `eu-` prefix to select the direct EU endpoint
  /// (the prefix is removed before authenticating). The endpoint is
  /// resolved in this order: [apiUrl], [region], the key prefix, then the
  /// canonical `https://api.kugelaudio.com`. [ttsUrl] overrides the host of
  /// the TTS WebSockets (default: the API URL).
  ///
  /// [timeout] bounds each HTTP request and each WebSocket opening
  /// handshake. [keepalivePingInterval] is the ping interval of long-lived
  /// sockets where the platform supports pings (not in the browser); `null`
  /// disables them.
  ///
  /// [telemetry] opts in or out of anonymous client-error diagnostics. By
  /// default they are on only for the hosted `*.kugelaudio.com` API. The
  /// `KUGELAUDIO_TELEMETRY` environment variable (or a `--dart-define` of
  /// the same name) set to `0/false/off/no` or `1/true/on/yes` overrides
  /// this argument. Reports carry error class, failure stage, timings and
  /// the server request id only; never text, audio, URLs or keys.
  ///
  /// [httpClient] replaces the default `http.Client` (it is closed by
  /// [close]); [webSocketConnector] replaces how WebSockets are opened.
  factory KugelAudio({
    required String apiKey,
    String? apiUrl,
    String? ttsUrl,
    Region? region,
    Duration timeout = const Duration(seconds: 60),
    Duration? keepalivePingInterval = const Duration(seconds: 20),
    bool? telemetry,
    http.Client? httpClient,
    WebSocketConnector? webSocketConnector,
  }) {
    if (apiKey.isEmpty) {
      throw ValidationException(
        'KugelAudio API key is missing. Pass apiKey: ... to the client. '
        'Get a key at $apiKeysUrl.',
      );
    }
    final parsed = parseApiKey(apiKey);
    final resolvedApiUrl =
        resolveApiUrl(apiUrl: apiUrl, region: region, keyRegion: parsed.region);
    final resolvedTtsUrl = resolveApiUrl(apiUrl: ttsUrl ?? resolvedApiUrl);
    final auth = authHeaders(parsed.key);
    final client = httpClient ?? http.Client();
    final diagnostics = Diagnostics(
      DiagnosticsConfig.resolve(resolvedApiUrl,
          telemetry: telemetry, authHeaders: auth),
      sender: (url, headers, body) async =>
          (await client.post(url, headers: headers, body: body)).statusCode,
    );
    final transport = HttpTransport(
      client: client,
      apiUrl: resolvedApiUrl,
      headers: {...auth, ...sdkHeaders()},
      timeout: timeout,
      diagnostics: diagnostics,
    );
    final connector = webSocketConnector ?? platform.connectWebSocket;
    SocketOpener opener(String baseUrl) => SocketOpener(
          connector: connector,
          baseUrl: baseUrl,
          apiKey: parsed.key,
          timeout: timeout,
          pingInterval: keepalivePingInterval,
        );
    return KugelAudio._(
      apiUrl: resolvedApiUrl,
      ttsUrl: resolvedTtsUrl,
      httpClient: client,
      diagnostics: diagnostics,
      transport: transport,
      ttsOpener: opener(resolvedTtsUrl),
      apiOpener: opener(resolvedApiUrl),
    );
  }

  KugelAudio._({
    required this.apiUrl,
    required this.ttsUrl,
    required http.Client httpClient,
    required Diagnostics diagnostics,
    required HttpTransport transport,
    required SocketOpener ttsOpener,
    required SocketOpener apiOpener,
  })  : _httpClient = httpClient,
        _diagnostics = diagnostics,
        models = ModelsResource(transport),
        voices = VoicesResource(transport),
        dictionaries = DictionariesResource(transport),
        tts = TtsResource(transport, ttsOpener, diagnostics),
        enhance = EnhanceResource(transport, apiOpener);

  /// Creates a client and opens its pooled TTS socket for [modelId], so
  /// the first `tts.stream` is fast. Takes the same arguments as the
  /// default constructor.
  static Future<KugelAudio> create({
    required String apiKey,
    String? apiUrl,
    String? ttsUrl,
    Region? region,
    Duration timeout = const Duration(seconds: 60),
    Duration? keepalivePingInterval = const Duration(seconds: 20),
    bool? telemetry,
    http.Client? httpClient,
    WebSocketConnector? webSocketConnector,
    String modelId = defaultModelId,
  }) async {
    final client = KugelAudio(
      apiKey: apiKey,
      apiUrl: apiUrl,
      ttsUrl: ttsUrl,
      region: region,
      timeout: timeout,
      keepalivePingInterval: keepalivePingInterval,
      telemetry: telemetry,
      httpClient: httpClient,
      webSocketConnector: webSocketConnector,
    );
    await client.tts.connect(modelId: modelId);
    return client;
  }

  /// The resolved API base URL.
  final String apiUrl;

  /// The resolved TTS WebSocket base URL.
  final String ttsUrl;

  final http.Client _httpClient;
  final Diagnostics _diagnostics;
  bool _closed = false;

  /// The TTS model catalog.
  final ModelsResource models;

  /// Voices: list, get, create, update, delete, references, publish.
  final VoicesResource voices;

  /// Per-project pronunciation dictionaries and their entries.
  final DictionariesResource dictionaries;

  /// Speech synthesis: generate, stream, streaming and multi-context
  /// sessions.
  final TtsResource tts;

  /// Speech enhancement: noise removal and target-speaker extraction.
  final EnhanceResource enhance;

  /// Whether diagnostics are enabled for this client.
  bool get telemetryEnabled => !_diagnostics.config.inert;

  /// Closes the pooled socket and the HTTP client. Pending diagnostics are
  /// delivered first, waiting at most one second. Sessions created from
  /// this client are closed by their own `close()`.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await tts.close();
    await _diagnostics.close();
    _httpClient.close();
  }
}

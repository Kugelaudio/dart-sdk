/// The official KugelAudio client for Dart and Flutter: text to speech
/// (REST and streaming), voices, pronunciation dictionaries and speech
/// enhancement.
///
/// ```dart
/// import 'package:kugelaudio/kugelaudio.dart';
///
/// final client = KugelAudio(apiKey: 'YOUR_API_KEY');
/// final audio = await client.tts.generate(
///   text: 'Hello from KugelAudio!',
///   voiceId: 1071,
///   language: 'en',
/// );
/// final wav = audio.toWav();
/// await client.close();
/// ```
///
/// Works on every platform Dart and Flutter target, the browser included.
/// File helpers that need `dart:io` live in `package:kugelaudio/io.dart`.
library;

export 'src/audio.dart'
    show
        Audio,
        AudioEncoding,
        AudioStream,
        OutputFormat,
        WavData,
        defaultSampleRate,
        parseWav,
        pcm16ToFloat32,
        supportedSampleRates,
        wavBytes;
export 'src/client.dart' show KugelAudio;
export 'src/config.dart'
    show
        ParsedApiKey,
        Region,
        defaultApiUrl,
        defaultModelId,
        euApiUrl,
        parseApiKey,
        resolveApiUrl;
export 'src/enhance/enhance.dart'
    show
        EnhanceResource,
        EnhanceSession,
        EnhancedAudio,
        enhancedSampleRate,
        taskNoiseRemoval,
        taskTargetSpeakerExtraction;
export 'src/errors.dart';
export 'src/models/dictionaries.dart';
export 'src/models/tts.dart';
export 'src/models/voices.dart';
export 'src/resources/dictionaries.dart';
export 'src/resources/models.dart';
export 'src/resources/voices.dart';
export 'src/tts/multi_context_session.dart'
    show ContextWordTimestamps, MultiContextConfig, MultiContextSession;
export 'src/tts/streaming_session.dart' show StreamingSession;
export 'src/tts/tts_resource.dart' show TtsResource, TtsStream;
export 'src/version.dart' show packageVersion;
export 'src/ws/connection.dart'
    show ChannelConnection, WebSocketConnection, WebSocketConnector;

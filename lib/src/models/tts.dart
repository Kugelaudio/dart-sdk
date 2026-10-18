import 'dart:convert';
import 'dart:typed_data';

import '../audio.dart';
import '../config.dart' show defaultModelId;
import 'json.dart';

/// Lowest accepted classifier-free guidance scale.
const double minCfgScale = 1.2;

/// Highest accepted classifier-free guidance scale.
const double maxCfgScale = 2.5;

/// Clamps [cfgScale] into [[minCfgScale], [maxCfgScale]], as the server does.
double clampCfgScale(double cfgScale) =>
    cfgScale.clamp(minCfgScale, maxCfgScale).toDouble();

/// One word with its time boundaries, sent when word timestamps are on.
class WordTimestamp {
  /// Creates a word timestamp.
  const WordTimestamp({
    required this.word,
    required this.startMs,
    required this.endMs,
    required this.charStart,
    required this.charEnd,
    this.score = 1.0,
  });

  /// Parses an entry of a `word_timestamps` frame.
  factory WordTimestamp.fromJson(JsonMap json) => WordTimestamp(
        word: reqString(json, 'word'),
        startMs: reqInt(json, 'start_ms'),
        endMs: reqInt(json, 'end_ms'),
        charStart: reqInt(json, 'char_start'),
        charEnd: reqInt(json, 'char_end'),
        score: optDouble(json, 'score') ?? 1.0,
      );

  /// The word.
  final String word;

  /// Start in milliseconds from the start of the audio.
  final int startMs;

  /// End in milliseconds.
  final int endMs;

  /// Index of the word's first character in the input text.
  final int charStart;

  /// Index after the word's last character.
  final int charEnd;

  /// Compatibility field, currently always 1.0.
  final double score;

  /// Duration of the word in milliseconds.
  int get durationMs => endMs - startMs;

  /// The JSON form of this timestamp.
  JsonMap toJson() => {
        'word': word,
        'start_ms': startMs,
        'end_ms': endMs,
        'char_start': charStart,
        'char_end': charEnd,
        'score': score,
      };
}

/// Parses a `word_timestamps` frame field.
List<WordTimestamp> parseWordTimestamps(Object? value) => [
      for (final w in asJsonList(value, 'word_timestamps'))
        WordTimestamp.fromJson(asJsonMap(w, 'word timestamp')),
    ];

/// What one request, turn or context consumed and was charged.
///
/// [costCents] is the actual charge in EUR cents; it is `null` (and
/// [costAvailable] false) when the charge could not be determined, never a
/// misleading 0. [audioSeconds] is always reported.
class SessionUsage {
  /// Creates a usage record.
  const SessionUsage({
    required this.audioSeconds,
    this.costCents,
    this.currency,
    this.characters,
    this.modelId,
  });

  /// Parses a `usage` object.
  factory SessionUsage.fromJson(JsonMap json) => SessionUsage(
        audioSeconds: optDouble(json, 'audio_seconds') ?? 0.0,
        costCents: optDouble(json, 'cost_cents'),
        currency: optString(json, 'currency'),
        characters: optInt(json, 'characters'),
        modelId: optString(json, 'model_id'),
      );

  /// Reads usage from a `final`, `session_closed` or `context_closed`
  /// frame: the nested `usage` object, else the top-level
  /// `total_audio_seconds` of older servers. `null` when the frame reports
  /// no usage at all.
  static SessionUsage? fromFrame(JsonMap frame) {
    final usage = frame['usage'];
    if (usage is Map) return SessionUsage.fromJson(asJsonMap(usage));
    if (frame.containsKey('total_audio_seconds')) {
      return SessionUsage(
        audioSeconds: optDouble(frame, 'total_audio_seconds') ?? 0.0,
      );
    }
    return null;
  }

  /// Audio generated, in seconds (the billed unit).
  final double audioSeconds;

  /// Amount charged in EUR cents; `null` when it could not be determined.
  final double? costCents;

  /// Currency of [costCents] (`eur`), when set.
  final String? currency;

  /// Input characters submitted, when reported.
  final int? characters;

  /// Model that produced the audio, when reported.
  final String? modelId;

  /// Whether an authoritative charge was returned.
  bool get costAvailable => costCents != null;

  /// The JSON form of this usage.
  JsonMap toJson() {
    final json = <String, Object?>{'audio_seconds': audioSeconds};
    putIfNotNull(json, 'cost_cents', costCents);
    putIfNotNull(json, 'currency', currency);
    putIfNotNull(json, 'characters', characters);
    putIfNotNull(json, 'model_id', modelId);
    return json;
  }
}

/// One chunk of generated audio.
class AudioChunk {
  /// Creates a chunk.
  const AudioChunk({
    required this.audio,
    required this.index,
    required this.sampleRate,
    required this.samples,
    this.encoding = AudioEncoding.pcmS16le,
    this.chunkId,
    this.contextId,
  });

  /// Parses an audio frame (`audio` is base64).
  factory AudioChunk.fromJson(JsonMap json) => AudioChunk(
        audio: base64.decode(reqString(json, 'audio')),
        index: optInt(json, 'idx') ?? 0,
        sampleRate: reqInt(json, 'sr'),
        samples: reqInt(json, 'samples'),
        encoding: optString(json, 'enc') ?? AudioEncoding.pcmS16le,
        chunkId: optInt(json, 'chunk_id'),
        contextId: optString(json, 'context_id'),
      );

  /// The audio bytes, in [encoding].
  final Uint8List audio;

  /// Chunk index, 0-based.
  final int index;

  /// Sample rate in Hz.
  final int sampleRate;

  /// Samples in this chunk.
  final int samples;

  /// One of [AudioEncoding]: `pcm_s16le` unless a G.711 `outputFormat` was
  /// requested.
  final String encoding;

  /// The server's text chunk id, when sent.
  final int? chunkId;

  /// The multi-context context this chunk belongs to.
  final String? contextId;

  /// Duration of this chunk.
  Duration get duration =>
      Duration(microseconds: samples * 1000000 ~/ sampleRate);

  /// The samples as floats in [-1.0, 1.0). PCM16 chunks only.
  Float32List toFloat32() {
    if (encoding != AudioEncoding.pcmS16le) {
      throw StateError('toFloat32 needs PCM16 audio, this chunk is $encoding.');
    }
    return pcm16ToFloat32(audio);
  }

  /// The JSON form of this chunk (audio as base64), as the server sends it.
  JsonMap toJson() {
    final json = <String, Object?>{
      'audio': base64.encode(audio),
      'enc': encoding,
      'idx': index,
      'sr': sampleRate,
      'samples': samples,
    };
    putIfNotNull(json, 'chunk_id', chunkId);
    putIfNotNull(json, 'context_id', contextId);
    return json;
  }
}

/// The `final` frame of a `/ws/tts` request: stats and usage.
class GenerationStats {
  /// Creates stats.
  const GenerationStats({
    required this.chunks,
    required this.totalSamples,
    required this.durationMs,
    required this.generationMs,
    required this.rtf,
    this.usage,
    this.raw = const {},
  });

  /// Parses a `final` frame.
  factory GenerationStats.fromJson(JsonMap json) => GenerationStats(
        chunks: optInt(json, 'chunks') ?? 0,
        totalSamples: optInt(json, 'total_samples') ?? 0,
        durationMs: optDouble(json, 'dur_ms') ?? 0,
        generationMs: optDouble(json, 'gen_ms') ?? 0,
        rtf: optDouble(json, 'rtf') ?? 0,
        usage: SessionUsage.fromFrame(json),
        raw: json,
      );

  /// Chunks generated.
  final int chunks;

  /// Samples generated.
  final int totalSamples;

  /// Audio duration in milliseconds.
  final double durationMs;

  /// Generation time in milliseconds.
  final double generationMs;

  /// Real-time factor (generation time / audio duration).
  final double rtf;

  /// Usage and charge of the request, when reported.
  final SessionUsage? usage;

  /// The whole frame, including fields this SDK does not model.
  final JsonMap raw;
}

/// Complete generated audio.
class AudioResponse {
  /// Creates a response.
  const AudioResponse({
    required this.audio,
    required this.sampleRate,
    required this.samples,
    this.encoding = AudioEncoding.pcmS16le,
    this.generationMs,
    this.rtf,
    this.wordTimestamps = const [],
    this.usage,
    this.requestId,
  });

  /// Joins streamed [chunks] and the request's final [stats].
  factory AudioResponse.fromChunks(
    List<AudioChunk> chunks, {
    GenerationStats? stats,
    List<WordTimestamp> wordTimestamps = const [],
    int fallbackSampleRate = defaultSampleRate,
  }) {
    final builder = BytesBuilder(copy: false);
    for (final c in chunks) {
      builder.add(c.audio);
    }
    final audio = builder.takeBytes();
    final encoding =
        chunks.isEmpty ? AudioEncoding.pcmS16le : chunks.first.encoding;
    return AudioResponse(
      audio: audio,
      sampleRate: chunks.isEmpty ? fallbackSampleRate : chunks.first.sampleRate,
      samples: stats?.totalSamples ??
          audio.length ~/ AudioEncoding.bytesPerSample(encoding),
      encoding: encoding,
      generationMs: stats?.generationMs,
      rtf: stats?.rtf,
      wordTimestamps: wordTimestamps,
      usage: stats?.usage,
    );
  }

  /// The audio bytes, in [encoding] (raw, no container).
  final Uint8List audio;

  /// Sample rate in Hz.
  final int sampleRate;

  /// Total samples.
  final int samples;

  /// One of [AudioEncoding].
  final String encoding;

  /// Server generation time in milliseconds, when reported (streamed
  /// generation only).
  final double? generationMs;

  /// Real-time factor, when reported (streamed generation only).
  final double? rtf;

  /// Per-word timing, when requested on a streamed generation.
  final List<WordTimestamp> wordTimestamps;

  /// Usage and charge, when reported (streamed generation only).
  final SessionUsage? usage;

  /// The `x-request-id` of the call, for support.
  final String? requestId;

  /// Duration of the audio.
  Duration get duration =>
      Duration(microseconds: samples * 1000000 ~/ sampleRate);

  /// Duration in milliseconds.
  double get durationMs => samples * 1000 / sampleRate;

  /// The samples as floats in [-1.0, 1.0). PCM16 audio only.
  Float32List toFloat32() {
    if (encoding != AudioEncoding.pcmS16le) {
      throw StateError('toFloat32 needs PCM16 audio, this is $encoding.');
    }
    return pcm16ToFloat32(audio);
  }

  /// The audio as WAV file bytes.
  Uint8List toWav() =>
      wavBytes(audio, sampleRate: sampleRate, encoding: encoding);
}

/// The parameters of one synthesis request, shared by REST generation and
/// the `/ws/tts` stream. See `docs/api-reference/tts/generate` for each
/// field's range.
class GenerateRequest {
  /// Creates a request. [cfgScale] is clamped into [1.2, 2.5].
  GenerateRequest({
    required this.text,
    this.modelId = defaultModelId,
    this.voiceId,
    double cfgScale = 2.0,
    this.temperature,
    this.maxNewTokens = 2048,
    this.sampleRate = defaultSampleRate,
    this.outputFormat,
    this.normalize = true,
    this.language,
    this.wordTimestamps = false,
    this.speed = 1.0,
    this.dictionaryIds,
    this.projectId,
  }) : cfgScale = clampCfgScale(cfgScale);

  /// Text to synthesize; supports `<break>`, `<spell>` and
  /// `<prosody rate>` tags.
  final String text;

  /// Model id, `kugel-3.5` by default.
  final String modelId;

  /// Voice id; the API has no default voice.
  final int? voiceId;

  /// Classifier-free guidance scale, clamped into [1.2, 2.5].
  final double cfgScale;

  /// Sampling variance in [0.0, 1.0]; `null` uses the server default.
  final double? temperature;

  /// Maximum tokens to generate, 1-2048.
  final int maxNewTokens;

  /// Output sample rate, one of [supportedSampleRates].
  final int sampleRate;

  /// A combined codec+rate token from [OutputFormat], e.g. `ulaw_8000`.
  /// Authoritative when set; `null` means PCM16 at [sampleRate].
  final String? outputFormat;

  /// Convert numbers, dates and symbols to words.
  final bool normalize;

  /// ISO 639-1 language for normalization. Without it the server uses the
  /// voice's primary language; it does not detect the text's language.
  final String? language;

  /// Request word-level timestamps (WebSocket only).
  final bool wordTimestamps;

  /// Speed multiplier, 0.8-1.2, pitch-preserving.
  final double speed;

  /// Dictionary selection: `null` applies the project's active
  /// dictionaries, `[]` none, a list exactly those.
  final List<int>? dictionaryIds;

  /// Project whose dictionaries apply; `null` sends none.
  final int? projectId;

  /// The request body. `word_timestamps` is only sent when true, since the
  /// REST endpoint rejects the field.
  JsonMap toJson() {
    final json = <String, Object?>{
      'text': text,
      'model_id': modelId,
      'cfg_scale': cfgScale,
      'max_new_tokens': maxNewTokens,
      'sample_rate': sampleRate,
      'normalize': normalize,
      'speed': speed,
    };
    if (wordTimestamps) json['word_timestamps'] = true;
    putIfNotNull(json, 'voice_id', voiceId);
    putIfNotNull(json, 'output_format', outputFormat);
    putIfNotNull(json, 'language', language);
    putIfNotNull(json, 'temperature', temperature);
    putIfNotNull(json, 'project_id', projectId);
    // [] is an explicit opt-out and must be sent; only null is omitted.
    putIfNotNull(json, 'dictionary_ids', dictionaryIds);
    return json;
  }
}

/// Configuration of a streaming session (`/ws/tts/stream`), sent with the
/// first text of the session and sticky for the connection.
class StreamConfig {
  /// Creates a configuration. [cfgScale] is clamped into [1.2, 2.5].
  StreamConfig({
    this.voiceId,
    this.modelId,
    double cfgScale = 2.0,
    this.temperature,
    this.maxNewTokens = 2048,
    this.sampleRate = defaultSampleRate,
    this.outputFormat,
    this.flushTimeoutMs = 500,
    this.maxBufferLength = 1000,
    this.normalize = true,
    this.language,
    this.wordTimestamps = false,
    this.chunkLengthSchedule,
    this.autoMode,
    this.speed = 1.0,
    this.dictionaryIds,
    this.projectId,
  }) : cfgScale = clampCfgScale(cfgScale);

  /// Voice id.
  final int? voiceId;

  /// Model id; the server default when `null`.
  final String? modelId;

  /// Classifier-free guidance scale, clamped into [1.2, 2.5].
  final double cfgScale;

  /// Sampling variance in [0.0, 1.0]; `null` uses the server default.
  final double? temperature;

  /// Maximum tokens per generation, 1-2048.
  final int maxNewTokens;

  /// Output sample rate, one of [supportedSampleRates].
  final int sampleRate;

  /// A combined codec+rate token from [OutputFormat]; set once per session.
  final String? outputFormat;

  /// Longest wait for the next token after an ambiguous period, in ms.
  final int flushTimeoutMs;

  /// Characters buffered before a forced flush.
  final int maxBufferLength;

  /// Convert numbers, dates and symbols to words.
  final bool normalize;

  /// ISO 639-1 language for normalization.
  final String? language;

  /// Request word-level timestamps.
  final bool wordTimestamps;

  /// Minimum buffer sizes (characters) before each successive chunk is
  /// generated; the last value repeats. Smaller values lower the time to
  /// first audio.
  final List<int>? chunkLengthSchedule;

  /// Start generating at the very first clean sentence boundary.
  final bool? autoMode;

  /// Speed multiplier, 0.8-1.2.
  final double speed;

  /// Dictionary selection: `null` project default, `[]` none, a list
  /// exactly those.
  final List<int>? dictionaryIds;

  /// Project whose dictionaries apply.
  final int? projectId;

  /// A copy with the given fields replaced.
  StreamConfig copyWith({
    int? voiceId,
    String? modelId,
    double? cfgScale,
    double? temperature,
    int? maxNewTokens,
    int? sampleRate,
    String? outputFormat,
    int? flushTimeoutMs,
    int? maxBufferLength,
    bool? normalize,
    String? language,
    bool? wordTimestamps,
    List<int>? chunkLengthSchedule,
    bool? autoMode,
    double? speed,
    List<int>? dictionaryIds,
    int? projectId,
  }) =>
      StreamConfig(
        voiceId: voiceId ?? this.voiceId,
        modelId: modelId ?? this.modelId,
        cfgScale: cfgScale ?? this.cfgScale,
        temperature: temperature ?? this.temperature,
        maxNewTokens: maxNewTokens ?? this.maxNewTokens,
        sampleRate: sampleRate ?? this.sampleRate,
        outputFormat: outputFormat ?? this.outputFormat,
        flushTimeoutMs: flushTimeoutMs ?? this.flushTimeoutMs,
        maxBufferLength: maxBufferLength ?? this.maxBufferLength,
        normalize: normalize ?? this.normalize,
        language: language ?? this.language,
        wordTimestamps: wordTimestamps ?? this.wordTimestamps,
        chunkLengthSchedule: chunkLengthSchedule ?? this.chunkLengthSchedule,
        autoMode: autoMode ?? this.autoMode,
        speed: speed ?? this.speed,
        dictionaryIds: dictionaryIds ?? this.dictionaryIds,
        projectId: projectId ?? this.projectId,
      );

  /// The config fields as sent on the wire.
  JsonMap toJson() {
    final json = <String, Object?>{
      'cfg_scale': cfgScale,
      'max_new_tokens': maxNewTokens,
      'sample_rate': sampleRate,
      'flush_timeout_ms': flushTimeoutMs,
      'max_buffer_length': maxBufferLength,
      'normalize': normalize,
      'word_timestamps': wordTimestamps,
      'speed': speed,
    };
    putIfNotNull(json, 'voice_id', voiceId);
    putIfNotNull(json, 'model_id', modelId);
    putIfNotNull(json, 'output_format', outputFormat);
    putIfNotNull(json, 'language', language);
    putIfNotNull(json, 'chunk_length_schedule', chunkLengthSchedule);
    putIfNotNull(json, 'auto_mode', autoMode);
    putIfNotNull(json, 'temperature', temperature);
    putIfNotNull(json, 'project_id', projectId);
    putIfNotNull(json, 'dictionary_ids', dictionaryIds);
    return json;
  }
}

/// How a streaming turn ended: its end-of-audio stats and usage.
class TurnResult {
  /// Creates a turn result.
  const TurnResult({
    this.totalAudioSeconds,
    this.totalTextChunks,
    this.totalAudioChunks,
    this.usage,
    this.wordTimestamps = const [],
    this.raw = const {},
  });

  /// Builds a result from the turn's `session_closed` frame (and its
  /// `final` frame, when one arrived).
  factory TurnResult.fromFrames(
    JsonMap sessionClosed, {
    JsonMap? finalFrame,
    List<WordTimestamp> wordTimestamps = const [],
  }) {
    final source = finalFrame ?? sessionClosed;
    return TurnResult(
      totalAudioSeconds: optDouble(sessionClosed, 'total_audio_seconds') ??
          optDouble(source, 'total_audio_seconds'),
      totalTextChunks: optInt(source, 'total_text_chunks'),
      totalAudioChunks: optInt(source, 'total_audio_chunks'),
      usage: SessionUsage.fromFrame(sessionClosed),
      wordTimestamps: wordTimestamps,
      raw: sessionClosed,
    );
  }

  /// Audio generated in this turn, in seconds.
  final double? totalAudioSeconds;

  /// Text chunks the server synthesized.
  final int? totalTextChunks;

  /// Audio chunks sent.
  final int? totalAudioChunks;

  /// Usage and charge of the turn, for per-conversation billing.
  final SessionUsage? usage;

  /// Every word timestamp of the turn (when enabled).
  final List<WordTimestamp> wordTimestamps;

  /// The `session_closed` frame, including fields this SDK does not model.
  final JsonMap raw;
}

/// Builds an `update_settings` body; at least one field must be set.
///
/// Only these generation parameters can change on an open connection;
/// voice, model, sample rate, output format, project and dictionaries are
/// fixed for it.
JsonMap settingsUpdateBody({
  double? cfgScale,
  double? temperature,
  double? speed,
  int? maxNewTokens,
  String? language,
  bool? normalize,
}) {
  final body = <String, Object?>{};
  putIfNotNull(body, 'cfg_scale', cfgScale);
  putIfNotNull(body, 'temperature', temperature);
  putIfNotNull(body, 'speed', speed);
  putIfNotNull(body, 'max_new_tokens', maxNewTokens);
  putIfNotNull(body, 'language', language);
  putIfNotNull(body, 'normalize', normalize);
  if (body.isEmpty) {
    throw ArgumentError(
      'updateSettings needs at least one parameter to change (cfgScale, '
      'temperature, speed, maxNewTokens, language or normalize).',
    );
  }
  return body;
}

import 'package:logging/logging.dart';

import 'json.dart';

final _log = Logger('kugelaudio');

/// A TTS model from `GET /v1/models`.
class Model {
  /// Creates a model description.
  const Model({
    required this.id,
    required this.name,
    this.description = '',
    this.parameters = '',
    this.maxInputLength = 5000,
    this.sampleRate = 24000,
  });

  /// Parses an entry of `GET /v1/models`.
  factory Model.fromJson(JsonMap json) => Model(
        id: reqString(json, 'id'),
        name: reqString(json, 'name'),
        description: optString(json, 'description') ?? '',
        parameters: optString(json, 'parameters') ?? '',
        maxInputLength: optInt(json, 'max_input_length') ?? 5000,
        sampleRate: optInt(json, 'sample_rate') ?? 24000,
      );

  /// Model id to pass as `modelId`, e.g. `kugel-3.5`.
  final String id;

  /// Display name.
  final String name;

  /// Human-readable description.
  final String description;

  /// Parameter count, as text.
  final String parameters;

  /// Longest accepted input, in characters.
  final int maxInputLength;

  /// Native output sample rate in Hz.
  final int sampleRate;

  /// The JSON form of this model.
  JsonMap toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'parameters': parameters,
        'max_input_length': maxInputLength,
        'sample_rate': sampleRate,
      };
}

/// Voice category.
///
/// The API accepts and returns the categories from [narrativeStory] to
/// [informativeEducational]; it returns [cloned] for a voice without a
/// category.
enum VoiceCategory {
  /// `premade`
  premade('premade'),

  /// `cloned`
  cloned('cloned'),

  /// `designed`
  designed('designed'),

  /// `conversational`
  conversational('conversational'),

  /// `narrative`
  narrative('narrative'),

  /// `narrative_story`
  narrativeStory('narrative_story'),

  /// `characters`
  characters('characters'),

  /// `characters_animation`
  charactersAnimation('characters_animation'),

  /// `social_media`
  socialMedia('social_media'),

  /// `entertainment_tv`
  entertainmentTv('entertainment_tv'),

  /// `advertisement`
  advertisement('advertisement'),

  /// `informative_educational`
  informativeEducational('informative_educational');

  const VoiceCategory(this.value);

  /// The wire value.
  final String value;

  /// Parses a wire value. A category this SDK version does not know maps to
  /// [cloned] and is logged at WARNING, so a new server category never
  /// breaks `voices.list()`.
  static VoiceCategory fromJson(String value) {
    for (final c in values) {
      if (c.value == value) return c;
    }
    _log.warning("Unknown voice category '$value' mapped to 'cloned'; "
        'upgrade the kugelaudio package');
    return cloned;
  }
}

/// Voice sex.
enum VoiceSex {
  /// `male`
  male('male'),

  /// `female`
  female('female'),

  /// `neutral`
  neutral('neutral');

  const VoiceSex(this.value);

  /// The wire value.
  final String value;

  /// Parses a wire value; throws a [FormatException] for an unknown one.
  static VoiceSex fromJson(String value) => values.firstWhere(
        (s) => s.value == value,
        orElse: () => throw FormatException('Unknown voice sex "$value".'),
      );
}

/// Voice age.
enum VoiceAge {
  /// `young`
  young('young'),

  /// `middle_aged`
  middleAged('middle_aged'),

  /// `middle_age`, an alternative spelling the API also uses.
  middleAge('middle_age'),

  /// `old`
  old('old');

  const VoiceAge(this.value);

  /// The wire value.
  final String value;

  /// Parses a wire value; throws a [FormatException] for an unknown one.
  static VoiceAge fromJson(String value) => values.firstWhere(
        (a) => a.value == value,
        orElse: () => throw FormatException('Unknown voice age "$value".'),
      );
}

VoiceCategory? _category(JsonMap json) {
  final v = optString(json, 'category');
  return v == null || v.isEmpty ? null : VoiceCategory.fromJson(v);
}

VoiceSex? _sex(JsonMap json) {
  final v = optString(json, 'sex');
  return v == null || v.isEmpty ? null : VoiceSex.fromJson(v);
}

VoiceAge? _age(JsonMap json) {
  final v = optString(json, 'age');
  return v == null || v.isEmpty ? null : VoiceAge.fromJson(v);
}

/// A voice in a list from `GET /v1/voices`.
class Voice {
  /// Creates a voice.
  const Voice({
    required this.id,
    required this.name,
    this.description,
    this.category,
    this.sex,
    this.age,
    this.quality = 'mid',
    this.supportedLanguages = const [],
    this.sampleText,
    this.avatarUrl,
    this.sampleUrl,
    this.isPublic = false,
    this.verified = false,
  });

  /// Parses a voice list entry.
  factory Voice.fromJson(JsonMap json) => Voice(
        id: reqInt(json, 'id'),
        name: reqString(json, 'name'),
        description: optString(json, 'description'),
        category: _category(json),
        sex: _sex(json),
        age: _age(json),
        quality: optString(json, 'quality') ?? 'mid',
        supportedLanguages: stringList(json, 'supported_languages'),
        sampleText: optString(json, 'sample_text'),
        avatarUrl: optString(json, 'avatar_url'),
        sampleUrl: optString(json, 'sample_url'),
        isPublic: optBool(json, 'is_public') ?? false,
        verified: optBool(json, 'verified') ?? false,
      );

  /// Voice id, passed as `voiceId`.
  final int id;

  /// Display name.
  final String name;

  /// Description, if any.
  final String? description;

  /// Category, if any.
  final VoiceCategory? category;

  /// Sex, if set.
  final VoiceSex? sex;

  /// Age, if set.
  final VoiceAge? age;

  /// Quality: `low`, `mid` or `high`.
  final String quality;

  /// ISO 639-1 codes the voice supports.
  final List<String> supportedLanguages;

  /// Text of the preview sample, if any.
  final String? sampleText;

  /// Avatar image URL, if any.
  final String? avatarUrl;

  /// Preview sample URL, if any.
  final String? sampleUrl;

  /// Whether the voice is public.
  final bool isPublic;

  /// Whether the voice is verified.
  final bool verified;

  /// The JSON form of this voice.
  JsonMap toJson() {
    final json = <String, Object?>{
      'id': id,
      'name': name,
      'quality': quality,
      'supported_languages': supportedLanguages,
      'is_public': isPublic,
      'verified': verified,
    };
    putIfNotNull(json, 'description', description);
    putIfNotNull(json, 'category', category?.value);
    putIfNotNull(json, 'sex', sex?.value);
    putIfNotNull(json, 'age', age?.value);
    putIfNotNull(json, 'sample_text', sampleText);
    putIfNotNull(json, 'avatar_url', avatarUrl);
    putIfNotNull(json, 'sample_url', sampleUrl);
    return json;
  }
}

/// A page of voices from `GET /v1/voices`.
class VoiceListResponse {
  /// Creates a page.
  const VoiceListResponse({
    required this.voices,
    required this.total,
    required this.limit,
    required this.offset,
  });

  /// Parses the list response.
  factory VoiceListResponse.fromJson(JsonMap json) => VoiceListResponse(
        voices: [
          for (final v in asJsonList(json['voices'] ?? const [], 'voices'))
            Voice.fromJson(asJsonMap(v, 'voice')),
        ],
        total: reqInt(json, 'total'),
        limit: reqInt(json, 'limit'),
        offset: reqInt(json, 'offset'),
      );

  /// The voices on this page.
  final List<Voice> voices;

  /// Number of voices across all pages.
  final int total;

  /// Page size.
  final int limit;

  /// Offset of this page.
  final int offset;

  /// The JSON form of this page.
  JsonMap toJson() => {
        'voices': [for (final v in voices) v.toJson()],
        'total': total,
        'limit': limit,
        'offset': offset,
      };
}

/// Full voice details from the voice management endpoints.
class VoiceDetail {
  /// Creates voice details.
  const VoiceDetail({
    required this.id,
    required this.name,
    this.description = '',
    this.generativeVoiceDescription = '',
    this.supportedLanguages = const [],
    this.category,
    this.age,
    this.sex,
    this.quality = 'mid',
    this.isPublic = false,
    this.verified = false,
    this.pendingVerification = false,
    this.sampleUrl,
    this.avatarUrl,
    this.sampleText = '',
  });

  /// Parses a voice detail response.
  factory VoiceDetail.fromJson(JsonMap json) => VoiceDetail(
        id: reqInt(json, 'id'),
        name: reqString(json, 'name'),
        description: optString(json, 'description') ?? '',
        generativeVoiceDescription:
            optString(json, 'generative_voice_description') ?? '',
        supportedLanguages: stringList(json, 'supported_languages'),
        category: _category(json),
        age: _age(json),
        sex: _sex(json),
        quality: optString(json, 'quality') ?? 'mid',
        isPublic: optBool(json, 'is_public') ?? false,
        verified: optBool(json, 'verified') ?? false,
        pendingVerification: optBool(json, 'pending_verification') ?? false,
        sampleUrl: optString(json, 'sample_url'),
        avatarUrl: optString(json, 'avatar_url'),
        sampleText: optString(json, 'sample_text') ?? '',
      );

  /// Voice id.
  final int id;

  /// Display name.
  final String name;

  /// Description.
  final String description;

  /// Description used to design the voice, if it was designed.
  final String generativeVoiceDescription;

  /// ISO 639-1 codes the voice supports.
  final List<String> supportedLanguages;

  /// Category, if any.
  final VoiceCategory? category;

  /// Age, if set.
  final VoiceAge? age;

  /// Sex, if set.
  final VoiceSex? sex;

  /// Quality: `low`, `mid` or `high`.
  final String quality;

  /// Whether the voice is public.
  final bool isPublic;

  /// Whether the voice is verified.
  final bool verified;

  /// Whether a publish request awaits verification.
  final bool pendingVerification;

  /// Preview sample URL, if any.
  final String? sampleUrl;

  /// Avatar image URL, if any.
  final String? avatarUrl;

  /// Text of the preview sample.
  final String sampleText;

  /// The JSON form of these details.
  JsonMap toJson() {
    final json = <String, Object?>{
      'id': id,
      'name': name,
      'description': description,
      'generative_voice_description': generativeVoiceDescription,
      'supported_languages': supportedLanguages,
      'quality': quality,
      'is_public': isPublic,
      'verified': verified,
      'pending_verification': pendingVerification,
      'sample_text': sampleText,
    };
    putIfNotNull(json, 'category', category?.value);
    putIfNotNull(json, 'age', age?.value);
    putIfNotNull(json, 'sex', sex?.value);
    putIfNotNull(json, 'sample_url', sampleUrl);
    putIfNotNull(json, 'avatar_url', avatarUrl);
    return json;
  }
}

/// A reference recording of a voice.
class VoiceReference {
  /// Creates a reference.
  const VoiceReference({
    required this.id,
    required this.voiceId,
    this.name = '',
    this.referenceText = '',
    this.s3Path = '',
    this.audioUrl,
    this.isGenerated = false,
  });

  /// Parses a reference.
  factory VoiceReference.fromJson(JsonMap json) => VoiceReference(
        id: reqInt(json, 'id'),
        voiceId: reqInt(json, 'voice_id'),
        name: optString(json, 'name') ?? '',
        referenceText: optString(json, 'reference_text') ?? '',
        s3Path: optString(json, 's3_path') ?? '',
        audioUrl: optString(json, 'audio_url'),
        isGenerated: optBool(json, 'is_generated') ?? false,
      );

  /// Reference id.
  final int id;

  /// The voice this reference belongs to.
  final int voiceId;

  /// File name.
  final String name;

  /// Transcript of the recording.
  final String referenceText;

  /// Storage path.
  final String s3Path;

  /// Signed download URL, if any.
  final String? audioUrl;

  /// Whether the reference was generated rather than uploaded.
  final bool isGenerated;

  /// The JSON form of this reference.
  JsonMap toJson() {
    final json = <String, Object?>{
      'id': id,
      'voice_id': voiceId,
      'name': name,
      'reference_text': referenceText,
      's3_path': s3Path,
      'is_generated': isGenerated,
    };
    putIfNotNull(json, 'audio_url', audioUrl);
    return json;
  }
}

/// The stored preview sample returned by `voices.generateSample`.
class GeneratedSample {
  /// Creates a sample description.
  const GeneratedSample({required this.sampleS3Path, this.sampleUrl});

  /// Parses the generate-sample response.
  factory GeneratedSample.fromJson(JsonMap json) => GeneratedSample(
        sampleS3Path: reqString(json, 'sample_s3_path'),
        sampleUrl: optString(json, 'sample_url'),
      );

  /// Storage path of the sample.
  final String sampleS3Path;

  /// Signed, time-limited URL; `null` when the server could not sign one.
  final String? sampleUrl;

  /// The JSON form of this sample.
  JsonMap toJson() {
    final json = <String, Object?>{'sample_s3_path': sampleS3Path};
    putIfNotNull(json, 'sample_url', sampleUrl);
    return json;
  }
}

import 'dart:convert';

import 'package:kugelaudio/kugelaudio.dart';
import 'package:test/test.dart';

void main() {
  group('voices', () {
    test('parses a voice list with defaults', () {
      final page = VoiceListResponse.fromJson({
        'voices': [
          {
            'id': 1071,
            'name': 'Anna',
            'category': 'conversational',
            'sex': 'female',
            'age': 'middle_age',
            'supported_languages': ['de', 'en'],
            'is_public': true,
          },
          {'id': 7, 'name': 'Bare', 'supported_languages': null},
        ],
        'total': 2,
        'limit': 20,
        'offset': 0,
      });
      expect(page.voices, hasLength(2));
      final anna = page.voices.first;
      expect(anna.category, VoiceCategory.conversational);
      expect(anna.sex, VoiceSex.female);
      expect(anna.age, VoiceAge.middleAge);
      expect(anna.supportedLanguages, ['de', 'en']);
      expect(anna.isPublic, isTrue);
      expect(page.voices.last.quality, 'mid');
      expect(page.voices.last.supportedLanguages, isEmpty);
      expect(VoiceListResponse.fromJson(page.toJson()).total, 2);
    });

    test('an unknown category maps to cloned', () {
      final v = Voice.fromJson({'id': 1, 'name': 'x', 'category': 'brand_new'});
      expect(v.category, VoiceCategory.cloned);
    });

    test('an unknown sex is a FormatException', () {
      expect(() => Voice.fromJson({'id': 1, 'name': 'x', 'sex': 'robot'}),
          throwsFormatException);
    });

    test('a missing required field names the field', () {
      expect(
        () => Voice.fromJson({'name': 'x'}),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('"id"'))),
      );
    });

    test('voice detail, reference and generated sample round-trip', () {
      final detail = VoiceDetail.fromJson({
        'id': 3,
        'name': 'n',
        'pending_verification': true,
        'category': 'narrative_story',
      });
      expect(detail.pendingVerification, isTrue);
      expect(detail.category, VoiceCategory.narrativeStory);
      expect(VoiceDetail.fromJson(detail.toJson()).name, 'n');
      final ref = VoiceReference.fromJson({'id': 1, 'voice_id': 3});
      expect(ref.isGenerated, isFalse);
      final sample = GeneratedSample.fromJson({'sample_s3_path': 'p'});
      expect(sample.sampleUrl, isNull);
    });
  });

  group('dictionaries', () {
    test('parses dictionaries, entries and bulk results', () {
      final d = Dictionary.fromJson(
          {'id': 1, 'project_id': 2, 'name': 'Brands', 'is_active': false});
      expect(d.isActive, isFalse);
      final list = DictionaryEntryList.fromJson({
        'entries': [
          {'id': 5, 'dictionary_id': 1, 'word': 'K8s', 'replacement': 'k'},
        ],
        'total': 1,
        'limit': 100,
        'offset': 0,
      });
      expect(list.entries.single.caseSensitive, isFalse);
      expect(
          BulkReplaceResult.fromJson({'upserted': 2, 'deleted': 1, 'total': 3})
              .total,
          3);
      expect(const DictionaryEntryInput(word: 'a', replacement: 'b').toJson(),
          {'word': 'a', 'replacement': 'b'});
    });
  });

  group('tts frames', () {
    test('decodes an audio frame', () {
      final chunk = AudioChunk.fromJson({
        'audio': base64.encode([0, 0, 255, 127]),
        'enc': 'pcm_s16le',
        'idx': 3,
        'sr': 24000,
        'samples': 2,
        'chunk_id': 1,
      });
      expect(chunk.audio, [0, 0, 255, 127]);
      expect(chunk.index, 3);
      expect(chunk.toFloat32()[1], closeTo(32767 / 32768, 1e-6));
      expect(chunk.duration, const Duration(microseconds: 83));
    });

    test('a G.711 chunk refuses float conversion', () {
      final chunk = AudioChunk.fromJson({
        'audio': base64.encode([1, 2]),
        'enc': 'mulaw',
        'idx': 0,
        'sr': 8000,
        'samples': 2,
      });
      expect(chunk.toFloat32, throwsStateError);
    });

    test('word timestamps and usage parse', () {
      final stamps = parseWordTimestamps([
        {
          'word': 'Hi',
          'start_ms': 0,
          'end_ms': 300,
          'char_start': 0,
          'char_end': 2
        },
      ]);
      expect(stamps.single.durationMs, 300);
      expect(stamps.single.score, 1.0);
      final usage = SessionUsage.fromFrame({
        'final': true,
        'usage': {
          'audio_seconds': 2.0,
          'cost_cents': null,
          'model_id': 'kugel-3.5'
        },
      })!;
      expect(usage.costAvailable, isFalse);
      expect(usage.audioSeconds, 2.0);
      expect(SessionUsage.fromFrame({'total_audio_seconds': 1.5})!.audioSeconds,
          1.5);
      expect(SessionUsage.fromFrame({'final': true}), isNull);
    });

    test('final stats parse with usage', () {
      final stats = GenerationStats.fromJson({
        'final': true,
        'chunks': 2,
        'total_samples': 48000,
        'dur_ms': 2000,
        'gen_ms': 150,
        'rtf': 0.075,
        'usage': {'audio_seconds': 2.0, 'cost_cents': 0.18, 'currency': 'eur'},
      });
      expect(stats.durationMs, 2000);
      expect(stats.usage!.costCents, 0.18);
    });
  });

  group('requests', () {
    test('GenerateRequest clamps cfg and omits unset fields', () {
      final body =
          GenerateRequest(text: 'Hi', voiceId: 1, cfgScale: 9).toJson();
      expect(body['cfg_scale'], maxCfgScale);
      expect(body['model_id'], 'kugel-3.5');
      expect(body.containsKey('word_timestamps'), isFalse);
      expect(body.containsKey('language'), isFalse);
      expect(body.containsKey('dictionary_ids'), isFalse);
    });

    test('an empty dictionary list is sent as an explicit opt-out', () {
      final body =
          GenerateRequest(text: 'Hi', dictionaryIds: const []).toJson();
      expect(body['dictionary_ids'], isEmpty);
    });

    test('StreamConfig serializes and copies', () {
      final config = StreamConfig(voiceId: 9, cfgScale: 0.5, autoMode: true);
      expect(config.cfgScale, minCfgScale);
      final json = config.copyWith(language: 'de').toJson();
      expect(json['voice_id'], 9);
      expect(json['language'], 'de');
      expect(json['auto_mode'], isTrue);
      expect(json['flush_timeout_ms'], 500);
    });

    test('settingsUpdateBody needs at least one field', () {
      expect(settingsUpdateBody, throwsArgumentError);
      expect(settingsUpdateBody(speed: 1.1), {'speed': 1.1});
    });

    test('TurnResult reads the final and session_closed frames', () {
      final result = TurnResult.fromFrames(
        {
          'session_closed': true,
          'total_audio_seconds': 5.4,
          'usage': {'audio_seconds': 5.4, 'cost_cents': 0.49},
        },
        finalFrame: {
          'final': true,
          'total_text_chunks': 3,
          'total_audio_chunks': 15
        },
      );
      expect(result.totalAudioSeconds, 5.4);
      expect(result.totalTextChunks, 3);
      expect(result.usage!.costCents, 0.49);
    });
  });

  test('Model parses with defaults', () {
    final m = Model.fromJson({'id': 'kugel-3.5', 'name': 'Kugel 3.5'});
    expect(m.sampleRate, 24000);
    expect(m.maxInputLength, 5000);
  });
}

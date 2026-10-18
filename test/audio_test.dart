import 'dart:typed_data';

import 'package:kugelaudio/kugelaudio.dart';
import 'package:test/test.dart';

void main() {
  test('PCM16 WAV round-trips', () {
    final pcm = Uint8List.fromList([1, 0, 255, 255, 0, 128]);
    final wav = wavBytes(pcm, sampleRate: 16000);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(wav.length, 44 + pcm.length);
    final parsed = parseWav(wav);
    expect(parsed.isPcm16, isTrue);
    expect(parsed.sampleRate, 16000);
    expect(parsed.channels, 1);
    expect(parsed.data, pcm);
  });

  test('G.711 WAVs carry their format tag', () {
    final ulaw = parseWav(
        wavBytes([1, 2, 3], sampleRate: 8000, encoding: AudioEncoding.mulaw));
    expect(ulaw.formatTag, 7);
    expect(ulaw.bitsPerSample, 8);
    expect(ulaw.data, [1, 2, 3]);
    final alaw =
        parseWav(wavBytes([1], sampleRate: 8000, encoding: AudioEncoding.alaw));
    expect(alaw.formatTag, 6);
  });

  test('parseWav rejects other bytes', () {
    expect(
        () => parseWav(Uint8List.fromList([1, 2, 3])), throwsFormatException);
  });

  test('pcm16ToFloat32 scales to [-1, 1)', () {
    final f = pcm16ToFloat32([0, 128, 255, 127]);
    expect(f[0], -1.0);
    expect(f[1], closeTo(1.0, 1e-4));
    expect(() => pcm16ToFloat32([1]), throwsArgumentError);
  });

  test('OutputFormat helpers', () {
    expect(OutputFormat.sampleRateOf('ulaw_8000'), 8000);
    expect(OutputFormat.sampleRateOf(null), isNull);
    expect(OutputFormat.encodingOf('alaw_8000'), AudioEncoding.alaw);
    expect(OutputFormat.encodingOf('pcm_16000'), AudioEncoding.pcmS16le);
    expect(AudioEncoding.bytesPerSample(AudioEncoding.mulaw), 1);
  });

  test('AudioStream chunks and replays', () async {
    final stream =
        AudioStream(Uint8List(1000), sampleRate: 1000, chunkSeconds: 0.2);
    final chunks = await stream.toList();
    expect(chunks.map((c) => c.length), [400, 400, 200]);
    expect(await stream.length, 3);
    expect(stream.duration, const Duration(milliseconds: 500));
  });

  test('AudioStream.fromWav downmixes stereo', () async {
    final stereo = Uint8List(8);
    final view = ByteData.sublistView(stereo);
    view.setInt16(0, 100, Endian.little);
    view.setInt16(2, 300, Endian.little);
    view.setInt16(4, -100, Endian.little);
    view.setInt16(6, -300, Endian.little);
    final stream =
        AudioStream.fromWav(wavBytes(stereo, sampleRate: 8000, channels: 2));
    final mono = ByteData.sublistView(stream.pcm);
    expect(stream.pcm.length, 4);
    expect(mono.getInt16(0, Endian.little), 200);
    expect(mono.getInt16(2, Endian.little), -200);
  });

  test('AudioStream.fromWav refuses non-PCM16', () {
    expect(
      () => AudioStream.fromWav(
          wavBytes([1, 2], sampleRate: 8000, encoding: AudioEncoding.mulaw)),
      throwsA(isA<ValidationException>()),
    );
  });

  test('Audio reports its duration when readable', () {
    final audio = Audio(wavBytes(Uint8List(32000), sampleRate: 16000));
    expect(audio.duration, const Duration(seconds: 1));
    expect(Audio(Uint8List(3)).duration, isNull);
  });

  test('AudioResponse joins chunks and writes WAV', () {
    final response = AudioResponse.fromChunks([
      AudioChunk(
          audio: Uint8List.fromList([1, 2]),
          index: 0,
          sampleRate: 8000,
          samples: 1),
      AudioChunk(
          audio: Uint8List.fromList([3, 4]),
          index: 1,
          sampleRate: 8000,
          samples: 1),
    ]);
    expect(response.audio, [1, 2, 3, 4]);
    expect(response.samples, 2);
    expect(response.sampleRate, 8000);
    expect(parseWav(response.toWav()).data, [1, 2, 3, 4]);
  });
}

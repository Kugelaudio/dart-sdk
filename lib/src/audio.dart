import 'dart:async';
import 'dart:typed_data';

import 'errors.dart';

/// The native generation rate of the TTS models, in Hz.
const int defaultSampleRate = 24000;

/// Every `sampleRate` the TTS endpoints accept, in Hz.
const List<int> supportedSampleRates = [8000, 16000, 22050, 24000, 44100];

/// Audio encodings of TTS output (the `enc` field of audio frames).
abstract final class AudioEncoding {
  /// Linear PCM, 16-bit signed little-endian (the default).
  static const pcmS16le = 'pcm_s16le';

  /// G.711 µ-law, one byte per sample.
  static const mulaw = 'mulaw';

  /// G.711 a-law, one byte per sample.
  static const alaw = 'alaw';

  /// Bytes per sample of [encoding]: 2 for PCM16, 1 for G.711.
  static int bytesPerSample(String encoding) => encoding == pcmS16le ? 2 : 1;
}

/// The combined codec and rate tokens accepted as `outputFormat`.
abstract final class OutputFormat {
  /// PCM16 at 8 kHz.
  static const pcm8000 = 'pcm_8000';

  /// PCM16 at 16 kHz.
  static const pcm16000 = 'pcm_16000';

  /// PCM16 at 22.05 kHz.
  static const pcm22050 = 'pcm_22050';

  /// PCM16 at 24 kHz.
  static const pcm24000 = 'pcm_24000';

  /// G.711 µ-law at 8 kHz.
  static const ulaw8000 = 'ulaw_8000';

  /// G.711 a-law at 8 kHz.
  static const alaw8000 = 'alaw_8000';

  /// Every token.
  static const values = [
    pcm8000,
    pcm16000,
    pcm22050,
    pcm24000,
    ulaw8000,
    alaw8000,
  ];

  /// The sample rate a token encodes (`ulaw_8000` -> 8000), or `null`.
  static int? sampleRateOf(String? token) {
    if (token == null) return null;
    final match = RegExp(r'_(\d+)$').firstMatch(token);
    return match == null ? null : int.parse(match[1]!);
  }

  /// The [AudioEncoding] a token produces (`ulaw_8000` -> `mulaw`).
  static String encodingOf(String? token) {
    if (token == null || token.startsWith('pcm_')) {
      return AudioEncoding.pcmS16le;
    }
    if (token.startsWith('ulaw_')) return AudioEncoding.mulaw;
    if (token.startsWith('alaw_')) return AudioEncoding.alaw;
    throw ArgumentError.value(token, 'outputFormat', 'unknown output format');
  }
}

/// Converts PCM16 little-endian [bytes] to float samples in [-1.0, 1.0).
Float32List pcm16ToFloat32(List<int> bytes) {
  if (bytes.length.isOdd) {
    throw ArgumentError.value(
        bytes.length, 'bytes', 'PCM16 needs an even number of bytes');
  }
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final view = ByteData.sublistView(data);
  final out = Float32List(data.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}

/// Wraps raw audio [data] in a WAV container.
///
/// [encoding] is one of [AudioEncoding]: PCM16 becomes a 16-bit PCM WAV,
/// µ-law and a-law become 8-bit G.711 WAVs, which most players read.
Uint8List wavBytes(
  List<int> data, {
  required int sampleRate,
  String encoding = AudioEncoding.pcmS16le,
  int channels = 1,
}) {
  final int formatTag;
  final int bits;
  switch (encoding) {
    case AudioEncoding.pcmS16le:
      formatTag = 1;
      bits = 16;
    case AudioEncoding.alaw:
      formatTag = 6;
      bits = 8;
    case AudioEncoding.mulaw:
      formatTag = 7;
      bits = 8;
    default:
      throw ArgumentError.value(encoding, 'encoding', 'unknown encoding');
  }
  final pcm = formatTag == 1;
  // Non-PCM formats carry an 18-byte fmt chunk (cbSize = 0) and a fact chunk.
  final fmtSize = pcm ? 16 : 18;
  final factSize = pcm ? 0 : 12;
  final blockAlign = channels * bits ~/ 8;
  final headerSize = 12 + 8 + fmtSize + factSize + 8;
  final out = Uint8List(headerSize + data.length);
  final b = ByteData.sublistView(out);
  var o = 0;
  void tag(String s) {
    for (final c in s.codeUnits) {
      out[o++] = c;
    }
  }

  void u32(int v) {
    b.setUint32(o, v, Endian.little);
    o += 4;
  }

  void u16(int v) {
    b.setUint16(o, v, Endian.little);
    o += 2;
  }

  tag('RIFF');
  u32(out.length - 8);
  tag('WAVE');
  tag('fmt ');
  u32(fmtSize);
  u16(formatTag);
  u16(channels);
  u32(sampleRate);
  u32(sampleRate * blockAlign);
  u16(blockAlign);
  u16(bits);
  if (!pcm) {
    u16(0);
    tag('fact');
    u32(4);
    u32(data.length ~/ blockAlign);
  }
  tag('data');
  u32(data.length);
  out.setRange(o, out.length, data);
  return out;
}

/// The parsed contents of a WAV file.
class WavData {
  /// Creates parsed WAV contents.
  const WavData({
    required this.formatTag,
    required this.channels,
    required this.sampleRate,
    required this.bitsPerSample,
    required this.data,
  });

  /// WAV format tag: 1 PCM, 3 float, 6 a-law, 7 µ-law.
  final int formatTag;

  /// Interleaved channels.
  final int channels;

  /// Sample rate in Hz.
  final int sampleRate;

  /// Bits per sample.
  final int bitsPerSample;

  /// The `data` chunk.
  final Uint8List data;

  /// Duration of the audio.
  Duration get duration {
    final frameBytes = channels * bitsPerSample ~/ 8;
    if (frameBytes == 0 || sampleRate == 0) return Duration.zero;
    final frames = data.length ~/ frameBytes;
    return Duration(microseconds: frames * 1000000 ~/ sampleRate);
  }

  /// Whether this is integer PCM at 16 bits.
  bool get isPcm16 => formatTag == 1 && bitsPerSample == 16;
}

/// Parses a WAV file. Throws a [FormatException] when it is not one.
///
/// `WAVE_FORMAT_EXTENSIBLE` files report the format tag of their sub-format.
WavData parseWav(Uint8List bytes) {
  String tagAt(int offset) => String.fromCharCodes(bytes, offset, offset + 4);
  if (bytes.length < 12 || tagAt(0) != 'RIFF' || tagAt(8) != 'WAVE') {
    throw const FormatException('Not a WAV file (no RIFF/WAVE header).');
  }
  final b = ByteData.sublistView(bytes);
  int? formatTag;
  int? channels;
  int? sampleRate;
  int? bits;
  Uint8List? data;
  var o = 12;
  while (o + 8 <= bytes.length) {
    final id = tagAt(o);
    final size = b.getUint32(o + 4, Endian.little);
    final body = o + 8;
    final end = body + size > bytes.length ? bytes.length : body + size;
    if (id == 'fmt ' && size >= 16) {
      formatTag = b.getUint16(body, Endian.little);
      channels = b.getUint16(body + 2, Endian.little);
      sampleRate = b.getUint32(body + 4, Endian.little);
      bits = b.getUint16(body + 14, Endian.little);
      if (formatTag == 0xFFFE && size >= 26) {
        formatTag = b.getUint16(body + 24, Endian.little);
      }
    } else if (id == 'data') {
      data = Uint8List.sublistView(bytes, body, end);
    }
    o = body + size + (size.isOdd ? 1 : 0);
  }
  if (formatTag == null || data == null) {
    throw const FormatException('WAV file has no fmt or data chunk.');
  }
  return WavData(
    formatTag: formatTag,
    channels: channels!,
    sampleRate: sampleRate!,
    bitsPerSample: bits!,
    data: data,
  );
}

Uint8List _downmixPcm16(Uint8List frames, int channels) {
  if (channels == 1) return frames;
  final view = ByteData.sublistView(frames);
  final count = frames.length ~/ (2 * channels);
  final out = Uint8List(count * 2);
  final w = ByteData.sublistView(out);
  for (var i = 0; i < count; i++) {
    var sum = 0;
    for (var c = 0; c < channels; c++) {
      sum += view.getInt16((i * channels + c) * 2, Endian.little);
    }
    w.setInt16(i * 2, sum ~/ channels, Endian.little);
  }
  return out;
}

/// A WAV recording to upload: for speech enhancement and voice references.
class Audio {
  /// Wraps WAV file [data]; [filename] is sent with the upload.
  ///
  /// The bytes are sent as they are. Read a file with `loadAudioFile` from
  /// `package:kugelaudio/io.dart`, or pass bytes you already have (a Flutter
  /// asset, a picked file, a recording).
  Audio(this.data, {this.filename = 'audio.wav'});

  /// The file bytes.
  final Uint8List data;

  /// File name sent with the upload.
  final String filename;

  /// Duration when the WAV header is readable here, else `null`.
  Duration? get duration {
    try {
      return parseWav(data).duration;
    } on FormatException {
      return null;
    }
  }

  @override
  String toString() => 'Audio($filename, ${data.length} bytes)';
}

/// Mono PCM16 audio served in fixed-length chunks, the input of
/// `client.enhance.stream`.
///
/// Every listen replays the audio from the start.
class AudioStream extends Stream<Uint8List> {
  /// Serves mono PCM16 [pcm] at [sampleRate] in chunks of [chunkSeconds].
  AudioStream(this.pcm, {required this.sampleRate, this.chunkSeconds = 0.1}) {
    if (pcm.length.isOdd) {
      throw ArgumentError.value(pcm.length, 'pcm', 'PCM16 is 2 bytes/sample');
    }
    if (chunkSeconds <= 0) {
      throw ArgumentError.value(chunkSeconds, 'chunkSeconds', 'must be > 0');
    }
  }

  /// Parses a 16-bit PCM WAV file; multi-channel audio is averaged to mono.
  ///
  /// Throws a [ValidationException] for any other WAV format.
  factory AudioStream.fromWav(Uint8List wav, {double chunkSeconds = 0.1}) {
    final WavData parsed;
    try {
      parsed = parseWav(wav);
    } on FormatException catch (e) {
      throw ValidationException('Not a readable WAV file: ${e.message}');
    }
    if (!parsed.isPcm16) {
      throw ValidationException(
        'Streaming needs a 16-bit PCM WAV file; got format '
        '${parsed.formatTag} at ${parsed.bitsPerSample} bits.',
      );
    }
    return AudioStream(
      _downmixPcm16(parsed.data, parsed.channels),
      sampleRate: parsed.sampleRate,
      chunkSeconds: chunkSeconds,
    );
  }

  /// The mono PCM16 samples.
  final Uint8List pcm;

  /// Sample rate in Hz.
  final int sampleRate;

  /// Length of each chunk in seconds.
  final double chunkSeconds;

  /// Duration of the audio.
  Duration get duration =>
      Duration(microseconds: pcm.length ~/ 2 * 1000000 ~/ sampleRate);

  Iterable<Uint8List> _chunks() sync* {
    var size = (sampleRate * chunkSeconds).round() * 2;
    if (size < 2) size = 2;
    for (var start = 0; start < pcm.length; start += size) {
      final end = start + size > pcm.length ? pcm.length : start + size;
      yield Uint8List.sublistView(pcm, start, end);
    }
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      Stream<Uint8List>.fromIterable(_chunks()).listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );
}

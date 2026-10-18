import '../http_transport.dart';
import '../models/json.dart';
import '../models/voices.dart';

/// `client.models`: the TTS model catalog.
class ModelsResource {
  /// Creates the resource on [transport].
  ModelsResource(this._transport);

  final HttpTransport _transport;

  /// Lists the available TTS models (`GET /v1/models`).
  Future<List<Model>> list() async {
    final json = asJsonMap(await _transport.json('GET', '/v1/models'));
    return [
      for (final m in asJsonList(json['models'] ?? const [], 'models'))
        Model.fromJson(asJsonMap(m, 'model')),
    ];
  }
}

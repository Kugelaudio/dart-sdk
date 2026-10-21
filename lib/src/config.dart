import 'errors.dart';
import 'platform/platform.dart' as platform;
import 'version.dart';

/// The canonical, geo-routed API endpoint.
const String defaultApiUrl = 'https://api.kugelaudio.com';

/// The direct EU endpoint.
const String euApiUrl = 'https://api.eu.kugelaudio.com';

/// The default TTS model.
const String defaultModelId = 'kugel-3.5';

/// Where an API key is created or rotated, quoted in authentication errors.
const String apiKeysUrl = 'https://www.kugelaudio.com/dashboard';

/// Where credits are topped up, quoted in insufficient-credit errors.
const String billingUrl = 'https://www.kugelaudio.com/dashboard';

/// A deployment region hint.
///
/// Only [eu] has a dedicated endpoint (`api.eu.kugelaudio.com`); [us] and
/// [global] are accepted compatibility hints that use the canonical
/// geo-routed endpoint.
enum Region {
  /// The direct EU endpoint.
  eu,

  /// Compatibility hint for the canonical endpoint.
  us,

  /// Compatibility hint for the canonical endpoint.
  global;

  /// Parses `eu`, `us` or `global`.
  ///
  /// Throws a [ValidationException] for any other value.
  static Region parse(String value) {
    for (final region in Region.values) {
      if (region.name == value) return region;
    }
    throw ValidationException(
      "Invalid region '$value'. Must be one of: "
      '${Region.values.map((r) => r.name).join(', ')}',
    );
  }
}

/// An API key with its region prefix removed.
class ParsedApiKey {
  /// Creates a parsed key.
  const ParsedApiKey(this.key, this.region);

  /// The key as sent to the API, without a region prefix.
  final String key;

  /// The region selected by an `eu-`, `us-` or `global-` prefix, if any.
  final Region? region;
}

/// Strips a region prefix (`eu-`, `us-`, `global-`) from [apiKey].
///
/// Project keys (`sk-kug-proj_...`) and every other key shape pass through
/// unchanged; only the region prefix is an SDK feature, the API itself does
/// not recognise it.
ParsedApiKey parseApiKey(String apiKey) {
  for (final region in Region.values) {
    final prefix = '${region.name}-';
    if (apiKey.startsWith(prefix)) {
      return ParsedApiKey(apiKey.substring(prefix.length), region);
    }
  }
  return ParsedApiKey(apiKey, null);
}

/// The API URL for a region hint: [euApiUrl] for [Region.eu], else
/// [defaultApiUrl].
String resolveRegionUrl(Region? region) =>
    region == Region.eu ? euApiUrl : defaultApiUrl;

/// Resolves the effective API base URL.
///
/// Priority: an explicit [apiUrl], then [region], then the key's prefix
/// region, then the canonical endpoint. Trailing slashes are removed.
String resolveApiUrl({String? apiUrl, Region? region, Region? keyRegion}) {
  if (apiUrl != null && apiUrl.isNotEmpty) return _trimSlash(apiUrl);
  return resolveRegionUrl(region ?? keyRegion);
}

String _trimSlash(String url) {
  var out = url;
  while (out.endsWith('/')) {
    out = out.substring(0, out.length - 1);
  }
  return out;
}

/// The auth headers every HTTP request carries, diagnostics included.
Map<String, String> authHeaders(String key) => {
      'Authorization': 'Bearer $key',
      'X-API-Key': key,
    };

/// SDK metadata headers.
///
/// `User-Agent` is only set where the platform lets a library set it; a
/// browser owns that header.
Map<String, String> sdkHeaders() => {
      'X-KugelAudio-SDK': sdkName,
      'X-KugelAudio-SDK-Version': packageVersion,
      if (!platform.isWeb) 'User-Agent': 'kugelaudio-dart/$packageVersion',
    };

/// The `sdk` / `sdk_version` query parameters WebSocket URLs carry, since a
/// browser WebSocket cannot send custom headers.
Map<String, String> sdkQuery() => {
      'sdk': sdkName,
      'sdk_version': packageVersion,
    };

/// Builds a WebSocket URL on [baseUrl] (http(s) is mapped to ws(s)) for
/// [path], with the API key and SDK metadata in the query.
///
/// The key travels in the query because browser WebSockets cannot set
/// handshake headers.
Uri webSocketUri(
  String baseUrl,
  String path,
  String apiKey, [
  Map<String, String> extra = const {},
]) {
  final base = Uri.parse(baseUrl);
  final scheme = switch (base.scheme) {
    'https' => 'wss',
    'http' => 'ws',
    final other => other,
  };
  final basePath = base.path.endsWith('/')
      ? base.path.substring(0, base.path.length - 1)
      : base.path;
  return base.replace(
    scheme: scheme,
    path: '$basePath$path',
    queryParameters: {
      'api_key': apiKey,
      ...extra,
      ...sdkQuery(),
    },
  );
}

/// Builds an HTTP URL on [baseUrl] for [path] with optional [query].
Uri httpUri(String baseUrl, String path, [Map<String, String>? query]) {
  final base = Uri.parse(baseUrl);
  final basePath = base.path.endsWith('/')
      ? base.path.substring(0, base.path.length - 1)
      : base.path;
  return base.replace(
    path: '$basePath$path',
    queryParameters: (query == null || query.isEmpty) ? null : query,
  );
}

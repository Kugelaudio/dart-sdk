// Diagnostics enablement and target, shared contract with the Python,
// JavaScript and Java SDKs ("SDK diagnostics contract", sections
// "Enablement" and "Wire format"). Nothing here touches the network.

import '../platform/platform.dart' as platform;

/// Appended to the effective API base URL. Diagnostics go to the same
/// authenticated host the SDK already calls; there is no override, so the
/// auth headers are never sent anywhere else.
const String diagnosticsPath = '/v1/sdk-diagnostics';

/// The opt-out (and opt-in) environment variable.
const String telemetryEnvVar = 'KUGELAUDIO_TELEMETRY';

/// `--dart-define=KUGELAUDIO_TELEMETRY=0` for builds without a process
/// environment (Flutter, the browser).
const String _compiledTelemetry = String.fromEnvironment(telemetryEnvVar);

const _trueValues = {'1', 'true', 'on', 'yes'};
const _falseValues = {'0', 'false', 'off', 'no'};

/// `hosted` for the KugelAudio API.
const String endpointKindHosted = 'hosted';

/// `custom` for any other endpoint.
const String endpointKindCustom = 'custom';

/// `hosted` when [apiUrl]'s host ends in `.kugelaudio.com`, else `custom`.
String endpointKindFor(String? apiUrl) {
  if (apiUrl == null || apiUrl.isEmpty) return endpointKindCustom;
  final uri = Uri.tryParse(apiUrl);
  final host = uri?.host.toLowerCase() ?? '';
  return host.endsWith('.kugelaudio.com')
      ? endpointKindHosted
      : endpointKindCustom;
}

/// Resolved telemetry configuration.
class DiagnosticsConfig {
  /// Creates a configuration.
  const DiagnosticsConfig({
    required this.enabled,
    this.url,
    this.authHeaders = const {},
    this.endpointKind = endpointKindCustom,
  });

  /// A configuration that never sends anything.
  static const disabled = DiagnosticsConfig(enabled: false);

  /// Whether reporting is on.
  final bool enabled;

  /// `<api url>/v1/sdk-diagnostics`, or `null` with nowhere to send.
  final Uri? url;

  /// The client's own auth headers, verbatim.
  final Map<String, String> authHeaders;

  /// `hosted` or `custom`.
  final String endpointKind;

  /// Whether the reporter must make no network call at all.
  bool get inert => !enabled || url == null;

  /// Resolves enablement; the first match wins:
  ///
  /// 1. `KUGELAUDIO_TELEMETRY` in the environment (or a `--dart-define`),
  /// 2. the explicit [telemetry] client option,
  /// 3. on only when the API host ends in `.kugelaudio.com`.
  static DiagnosticsConfig resolve(
    String? apiUrl, {
    bool? telemetry,
    Map<String, String> authHeaders = const {},
    String? Function(String name)? environment,
  }) {
    final kind = endpointKindFor(apiUrl);
    final env = environment ?? platform.environmentVariable;
    final raw =
        (env(telemetryEnvVar) ?? _compiledTelemetry).trim().toLowerCase();
    final bool enabled;
    if (_falseValues.contains(raw)) {
      enabled = false;
    } else if (_trueValues.contains(raw)) {
      enabled = true;
    } else if (telemetry != null) {
      enabled = telemetry;
    } else {
      enabled = kind == endpointKindHosted;
    }
    Uri? url;
    if (apiUrl != null && apiUrl.isNotEmpty) {
      var base = apiUrl;
      while (base.endsWith('/')) {
        base = base.substring(0, base.length - 1);
      }
      url = Uri.tryParse('$base$diagnosticsPath');
    }
    return DiagnosticsConfig(
      enabled: enabled,
      url: url,
      authHeaders: authHeaders,
      endpointKind: kind,
    );
  }
}

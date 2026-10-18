import 'dart:async';

import 'package:logging/logging.dart';

import '../errors.dart';

/// The SDK's logger: language warnings, restart replays, prewarm failures.
final Logger sdkLog = Logger('kugelaudio');

bool _languageWarned = false;

/// Logs once per process that normalization runs without a language.
void warnIfNoLanguage(String? language, bool normalize) {
  if (language != null || !normalize || _languageWarned) return;
  _languageWarned = true;
  sdkLog.warning(
    "No 'language' set with normalization enabled: the server normalizes in "
    "the voice's primary language (English if it has none). Set language "
    "(e.g. language: 'de') when the text is in another language.",
  );
}

/// How long a reply may take before a session call gives up.
const Duration receiveTimeout = Duration(seconds: 30);

/// Default wait before reconnecting after a rolling-deploy close.
const Duration restartReconnectDelay = Duration(seconds: 1);

/// The wait before reconnecting after [error]: its retry hint, else one
/// second.
Duration restartDelay(KugelAudioException error) =>
    error.retryAfter ?? restartReconnectDelay;

/// Runs actions strictly one after another, in call order.
class SerialQueue {
  Future<void> _tail = Future<void>.value();

  /// Runs [action] after every action queued before it has finished.
  Future<T> run<T>(Future<T> Function() action) {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    return previous.then((_) => action()).whenComplete(done.complete);
  }
}

/// Completes [completer] with [error] unless it already completed.
void failCompleter<T>(Completer<T>? completer, Object error) {
  if (completer != null && !completer.isCompleted) {
    completer.completeError(error);
  }
}

/// Completes [completer] with [value] unless it already completed.
void completeOnce<T>(Completer<T>? completer, T value) {
  if (completer != null && !completer.isCompleted) completer.complete(value);
}

/// Credentials used exclusively by the autonomous HTTPS callback transport.
///
/// Tokens must be scoped to callback delivery. Adapters must keep them out of
/// events, diagnostics and logs, and use secure storage where available.
final class CallbackAuth {
  /// Supplies an opaque bearer token; rotating configuration replaces it.
  const CallbackAuth.bearer(this.token);

  /// The secret sent as the HTTPS Authorization bearer credential.
  final String token;
}

/// Optional autonomous HTTPS delivery, independent of Flutter event delivery.
///
/// Initialization validates HTTPS, positive queue bounds and a positive TTL.
/// Successful delivery never acknowledges the Flutter event inbox.
final class CallbackConfiguration {
  /// Configures a callback destination and bounded retention.
  const CallbackConfiguration({
    required this.endpoint,
    required this.auth,
    this.timeToLive = const Duration(hours: 24),
    this.maxPendingEvents = 1000,
  });

  /// HTTPS destination without embedded credentials or a URL fragment.
  final Uri endpoint;

  /// Credentials consumed only by the callback transport.
  final CallbackAuth auth;

  /// Maximum age of a callback awaiting delivery.
  final Duration timeToLive;

  /// Maximum pending callback count before storage admission fails.
  final int maxPendingEvents;
}

/// The transport-independent outcome of one callback attempt.
sealed class RetryDecision {
  /// Creates a retry decision.
  const RetryDecision();
}

/// A 2xx response completed HTTP delivery.
final class DeliverySucceeded extends RetryDecision {
  /// Creates a successful delivery outcome.
  const DeliverySucceeded();
}

/// A credential failure suspends HTTP delivery until credentials rotate.
final class PauseForAuthentication extends RetryDecision {
  /// Creates an authentication pause outcome.
  const PauseForAuthentication();
}

/// A transient failure may be retried after [delay].
final class RetryLater extends RetryDecision {
  /// Creates a delayed retry outcome.
  const RetryLater(this.delay);

  /// Deterministic delay before platform-provided jitter is applied.
  final Duration delay;
}

/// A permanent response or expired event must not be retried.
final class DoNotRetry extends RetryDecision {
  /// Creates a terminal delivery outcome.
  const DoNotRetry();
}

/// Classifies HTTPS outcomes without networking or platform scheduling.
///
/// Adapters apply jitter to [RetryLater.delay], enforce event TTL before each
/// attempt, and persist terminal outcomes. No credentials enter decisions.
final class RetryPolicy {
  /// Creates a retry policy with a one-second base and fifteen-minute ceiling.
  const RetryPolicy();

  /// The shared callback retry policy.
  static const RetryPolicy standard = RetryPolicy();

  /// Classifies a response, or a network failure when [statusCode] is null.
  ///
  /// [attempt] starts at one. A positive [retryAfter] takes precedence over
  /// exponential backoff, subject to the same fifteen-minute ceiling.
  RetryDecision classify({
    int? statusCode,
    required int attempt,
    Duration? retryAfter,
  }) {
    if (attempt < 1) {
      throw RangeError.value(attempt, 'attempt', 'Must start at one');
    }
    if (statusCode != null && statusCode >= 200 && statusCode < 300) {
      return const DeliverySucceeded();
    }
    if (statusCode == 401 || statusCode == 403) {
      return const PauseForAuthentication();
    }
    if (statusCode == null ||
        statusCode == 429 ||
        (statusCode >= 500 && statusCode < 600)) {
      return RetryLater(_boundedDelay(attempt, retryAfter));
    }
    return const DoNotRetry();
  }

  static Duration _boundedDelay(int attempt, Duration? retryAfter) {
    const maximum = Duration(minutes: 15);
    if (retryAfter != null && retryAfter > Duration.zero) {
      return retryAfter > maximum ? maximum : retryAfter;
    }
    var seconds = 1;
    for (var i = 1; i < attempt && seconds < maximum.inSeconds; i++) {
      seconds *= 2;
    }
    return Duration(
      seconds: seconds > maximum.inSeconds ? maximum.inSeconds : seconds,
    );
  }
}

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

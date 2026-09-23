import '../api/callback_configuration.dart';
import '../api/events.dart';
import '../platform/wire_codec.dart';
import '../storage/event_journal.dart';

/// Applies shared HTTP receipt policy to a platform transport result.
///
/// Native adapters own networking, scheduling, durable terminal state and
/// credential storage. This class only changes the journal on success or
/// authentication pause; other outcomes are returned for the adapter to store.
final class CallbackDispatcher {
  /// Creates a policy dispatcher for [journal].
  const CallbackDispatcher(
    this.journal, {
    this.retryPolicy = RetryPolicy.standard,
    this.timeToLive = const Duration(hours: 24),
  });

  /// The journal with independent Flutter and HTTP receipts.
  final EventJournal journal;

  /// Classifies response outcomes and retry delays.
  final RetryPolicy retryPolicy;

  /// Maximum event age before a callback becomes terminal.
  final Duration timeToLive;

  /// Processes one HTTP outcome, without touching the Flutter receipt.
  ///
  /// A null [responseStatus] represents a network failure. The caller must
  /// persist [RetryLater] and [DoNotRetry] outcomes in its platform outbox.
  Future<RetryDecision> deliver(
    JackfieldEvent event, {
    required int? responseStatus,
    required int attempt,
    Duration? retryAfter,
    DateTime? now,
  }) async {
    final currentTime = now ?? DateTime.now().toUtc();
    if (!currentTime.isBefore(event.occurredAt.add(timeToLive))) {
      return const DoNotRetry();
    }
    final decision = retryPolicy.classify(
      statusCode: responseStatus,
      attempt: attempt,
      retryAfter: retryAfter,
    );
    if (decision is DeliverySucceeded) {
      await journal.acknowledgeHttp({event.eventId});
    } else if (decision is PauseForAuthentication) {
      await journal.pauseHttpForAuthentication();
    }
    return decision;
  }

  /// Canonical version 1 callback body; send the event ID as Idempotency-Key.
  static Map<String, Object?> envelope(JackfieldEvent event) => {
    'version': WireCodec.version,
    'event': WireCodec.encodeEvent(event),
  };
}

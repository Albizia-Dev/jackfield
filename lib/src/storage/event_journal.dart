import '../api/events.dart';
import '../api/identifiers.dart';

/// Whether an event was admitted to the durable journal.
enum EventAppendResult {
  /// The event was first recorded and may now be published.
  appended,

  /// This event ID was already recorded; its receipts remain unchanged.
  duplicate,

  /// A newer or equal sequence was already admitted for this call.
  staleSequence,
}

/// Stores events and independent Flutter and HTTP delivery receipts.
///
/// Native adapters must commit an event before exposing it to either consumer.
/// An event ID remains known after both receipts are acknowledged so a replayed
/// append cannot recreate a completed delivery.
abstract interface class EventJournal {
  /// Admits [event] once by event ID and increasing per-call sequence.
  ///
  /// Duplicate IDs preserve their existing receipts. A new ID whose sequence
  /// is not higher than the call's last admitted sequence is rejected.
  Future<EventAppendResult> append(JackfieldEvent event);

  /// Returns events awaiting Flutter acknowledgement, ordered within each call.
  Future<List<JackfieldEvent>> pendingFlutter();

  /// Returns events awaiting HTTP acknowledgement, ordered within each call.
  ///
  /// This includes records while HTTP delivery is paused for authentication.
  Future<List<JackfieldEvent>> pendingHttp();

  /// Acknowledges Flutter delivery for [ids], ignoring unknown or repeated IDs.
  Future<void> acknowledgeFlutter(Set<EventId> ids);

  /// Acknowledges HTTP delivery for [ids], ignoring unknown or repeated IDs.
  Future<void> acknowledgeHttp(Set<EventId> ids);

  /// Suspends HTTP attempts until the adapter restores authentication.
  ///
  /// Pausing does not acknowledge or remove either delivery receipt.
  Future<void> pauseHttpForAuthentication();
}

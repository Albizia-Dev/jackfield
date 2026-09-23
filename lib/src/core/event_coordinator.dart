import 'dart:async';

import '../api/events.dart';
import '../api/identifiers.dart';
import '../storage/event_journal.dart';

/// Persists events before publication and replays unacknowledged Flutter work.
final class EventCoordinator {
  /// Creates a coordinator over the adapter-owned [journal].
  EventCoordinator(this.journal);

  /// The journal that owns delivery receipts.
  final EventJournal journal;
  final StreamController<JackfieldEvent> _live =
      StreamController<JackfieldEvent>.broadcast(sync: true);
  final Map<CallId, Future<void>> _callTails = {};

  /// Replays pending Flutter events, then emits newly persisted events.
  ///
  /// Each subscription suppresses duplicate event IDs seen during its lifetime.
  Stream<JackfieldEvent> get events => Stream.multi((controller) async {
    final seen = <EventId>{};
    final buffered = <JackfieldEvent>[];
    var replaying = true;
    final subscription = _live.stream.listen((event) {
      if (replaying) {
        buffered.add(event);
      } else if (seen.add(event.eventId)) {
        controller.add(event);
      }
    });
    controller.onCancel = subscription.cancel;

    try {
      for (final event in await journal.pendingFlutter()) {
        if (seen.add(event.eventId)) controller.add(event);
      }
      replaying = false;
      for (final event in buffered) {
        if (seen.add(event.eventId)) controller.add(event);
      }
    } catch (error, stackTrace) {
      controller.addError(error, stackTrace);
      await subscription.cancel();
    }
  });

  /// Records [event] before any active Flutter listener can receive it.
  Future<void> publish(JackfieldEvent event) async {
    final previous = _callTails[event.callId];
    final completion = Completer<void>();
    final tail = completion.future;
    _callTails[event.callId] = tail;
    try {
      if (previous != null) await previous;
      final result = await journal.append(event);
      if (result == EventAppendResult.appended) _live.add(event);
    } finally {
      completion.complete();
      if (identical(_callTails[event.callId], tail)) {
        _callTails.remove(event.callId);
      }
    }
  }
}

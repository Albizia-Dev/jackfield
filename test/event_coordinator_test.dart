import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jackfield/src/api/call_models.dart';
import 'package:jackfield/src/api/events.dart';
import 'package:jackfield/src/api/identifiers.dart';
import 'package:jackfield/src/core/event_coordinator.dart';
import 'package:jackfield/src/storage/event_journal.dart';
import 'package:jackfield/src/storage/memory_event_journal.dart';

void main() {
  late MemoryEventJournal journal;
  late EventCoordinator coordinator;

  setUp(() {
    journal = MemoryEventJournal();
    coordinator = EventCoordinator(journal);
  });

  test('duplicate event is stored once and ACK is idempotent', () async {
    final event = _ended('call-a', 'event-1', 1);

    await coordinator.publish(event);
    await coordinator.publish(event);
    expect(await journal.append(event), EventAppendResult.duplicate);
    expect(await journal.pendingFlutter(), [event]);
    expect(await journal.pendingHttp(), [event]);

    await journal.acknowledgeFlutter({event.eventId});
    await journal.acknowledgeFlutter({event.eventId});
    expect(await journal.pendingFlutter(), isEmpty);
    expect(await journal.pendingHttp(), [event]);

    await coordinator.publish(event);
    expect(await journal.pendingFlutter(), isEmpty);
  });

  test(
    'ACKed event is not delivered to a new listener on duplicate publish',
    () async {
      final event = _ended('call-a', 'event-1', 1);
      await coordinator.publish(event);
      await journal.acknowledgeFlutter({event.eventId});
      expect(await journal.pendingFlutter(), isEmpty);

      final delivered = <JackfieldEvent>[];
      final subscription = coordinator.events.listen(delivered.add);
      await Future<void>.delayed(Duration.zero);

      await coordinator.publish(event);
      await Future<void>.delayed(Duration.zero);

      expect(delivered, isEmpty);
      expect(await journal.pendingFlutter(), isEmpty);
      await subscription.cancel();
    },
  );

  test('live delivery rejects regressive sequence for the same call', () async {
    final callA2 = _ended('call-a', 'event-a2', 2);
    final callA1 = _ended('call-a', 'event-a1', 1);
    final delivered = <JackfieldEvent>[];
    final subscription = coordinator.events.listen(delivered.add);
    await Future<void>.delayed(Duration.zero);

    await coordinator.publish(callA2);
    await coordinator.publish(callA1);
    await Future<void>.delayed(Duration.zero);

    expect(delivered, [callA2]);
    expect(await journal.pendingFlutter(), [callA2]);
    await subscription.cancel();
  });

  test('stale sequence is rejected without blocking another call', () async {
    final callB1 = _ended('call-b', 'event-b1', 1);
    final callA2 = _ended('call-a', 'event-a2', 2);
    final callA1 = _ended('call-a', 'event-a1', 1);

    await coordinator.publish(callB1);
    await coordinator.publish(callA2);
    await coordinator.publish(callA1);

    expect(await journal.append(callA1), EventAppendResult.staleSequence);
    expect(await journal.pendingFlutter(), [callB1, callA2]);
    expect(await journal.pendingHttp(), [callB1, callA2]);
  });

  test('HTTP ACK never consumes the Flutter receipt', () async {
    final event = _ended('call-a', 'event-1', 1);
    await coordinator.publish(event);

    await journal.acknowledgeHttp({event.eventId});
    await journal.acknowledgeHttp({event.eventId});

    expect(await journal.pendingHttp(), isEmpty);
    expect(await journal.pendingFlutter(), [event]);
  });

  test('live event is visible in journal before emission', () async {
    final event = _ended('call-a', 'event-1', 1);
    final observed = Completer<List<JackfieldEvent>>();
    final subscription = coordinator.events.listen((_) async {
      observed.complete(await journal.pendingFlutter());
    });

    await coordinator.publish(event);

    expect(await observed.future, [event]);
    await subscription.cancel();
  });

  test(
    'new listener replays pending events after coordinator restart',
    () async {
      final event = _ended('call-a', 'event-1', 1);
      await coordinator.publish(event);

      final restarted = EventCoordinator(journal);
      expect(await restarted.events.first, event);
    },
  );

  test('authentication pause retains both receipts', () async {
    final event = _ended('call-a', 'event-1', 1);
    await coordinator.publish(event);

    await journal.pauseHttpForAuthentication();

    expect(journal.isHttpPausedForAuthentication, isTrue);
    expect(await journal.pendingHttp(), [event]);
    expect(await journal.pendingFlutter(), [event]);
  });

  test('slow append blocks its call but not another call', () async {
    final callA1 = _ended('call-a', 'event-a1', 1);
    final callA2 = _ended('call-a', 'event-a2', 2);
    final callB1 = _ended('call-b', 'event-b1', 1);
    final gatedJournal = _GatedJournal(callA1.eventId);
    final gatedCoordinator = EventCoordinator(gatedJournal);
    final delivered = <JackfieldEvent>[];
    final subscription = gatedCoordinator.events.listen(delivered.add);
    await Future<void>.delayed(Duration.zero);

    final first = gatedCoordinator.publish(callA1);
    final second = gatedCoordinator.publish(callA2);
    try {
      await gatedCoordinator.publish(callB1);
      await Future<void>.delayed(Duration.zero);
      expect(delivered, [callB1]);
      expect(await gatedJournal.pendingFlutter(), [callB1]);
    } finally {
      gatedJournal.release();
      await Future.wait([first, second]);
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();
    }
    expect(delivered, [callB1, callA1, callA2]);
  });
}

CallEnded _ended(String callId, String eventId, int sequence) => CallEnded(
  callId: CallId(callId),
  eventId: EventId(eventId),
  sequence: sequence,
  occurredAt: DateTime.utc(2026, 9, 23),
  reason: EndReason.remote,
);

final class _GatedJournal implements EventJournal {
  _GatedJournal(this.gatedId);

  final EventId gatedId;
  final MemoryEventJournal _journal = MemoryEventJournal();
  final Completer<void> _gate = Completer<void>();

  void release() => _gate.complete();

  @override
  Future<EventAppendResult> append(JackfieldEvent event) async {
    if (event.eventId == gatedId) await _gate.future;
    return _journal.append(event);
  }

  @override
  Future<List<JackfieldEvent>> pendingFlutter() => _journal.pendingFlutter();

  @override
  Future<List<JackfieldEvent>> pendingHttp() => _journal.pendingHttp();

  @override
  Future<void> acknowledgeFlutter(Set<EventId> ids) =>
      _journal.acknowledgeFlutter(ids);

  @override
  Future<void> acknowledgeHttp(Set<EventId> ids) =>
      _journal.acknowledgeHttp(ids);

  @override
  Future<void> pauseHttpForAuthentication() =>
      _journal.pauseHttpForAuthentication();
}

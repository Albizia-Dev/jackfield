import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jackfield/jackfield.dart';
import 'package:jackfield/jackfield_platform_interface.dart';
import 'package:jackfield/src/storage/memory_event_journal.dart';

class JournalPlatform extends JackfieldPlatform {
  final journal = MemoryEventJournal();
  final controller = StreamController<JackfieldEvent>.broadcast();
  final completed = <ActionId>[];

  @override
  Stream<JackfieldEvent> get events => controller.stream;

  @override
  Future<JackfieldResult<void>> completeAction(
    ActionId id,
    ActionResult result,
  ) async {
    completed.add(id);
    return const JackfieldSuccess(null);
  }

  @override
  Future<JackfieldResult<void>> acknowledgeEvents(Set<EventId> ids) async {
    await journal.acknowledgeFlutter(ids);
    return const JackfieldSuccess(null);
  }
}

void main() {
  test('action completion and event ACK remain independent', () async {
    final platform = JournalPlatform();
    addTearDown(platform.controller.close);
    final jackfield = Jackfield.withPlatform(platform);
    final event = AnswerRequested(
      callId: const CallId('call-1'),
      actionId: const ActionId('action-1'),
      eventId: const EventId('event-1'),
      sequence: 1,
      occurredAt: DateTime.utc(2026),
      deadline: DateTime.utc(2026, 1, 1, 0, 1),
    );
    await platform.journal.append(event);
    final delivered = jackfield.events.first;
    platform.controller.add(event);
    expect(await delivered, same(event));
    await jackfield.completeAction(
      event.actionId,
      const ActionResult.success(),
    );
    expect(platform.completed, [event.actionId]);
    expect(await platform.journal.pendingFlutter(), [event]);
    await jackfield.acknowledgeEvents({event.eventId});
    expect(await platform.journal.pendingFlutter(), isEmpty);
    expect(await platform.journal.pendingHttp(), [event]);
    expect(platform.completed, [event.actionId]);
  });

  test(
    'injected facades keep their adapters separate from registration',
    () async {
      final registered = JackfieldPlatform.instance;
      final first = JournalPlatform();
      final second = JournalPlatform();
      addTearDown(first.controller.close);
      addTearDown(second.controller.close);
      await Jackfield.withPlatform(
        first,
      ).completeAction(const ActionId('first'), const ActionResult.success());
      await Jackfield.withPlatform(
        second,
      ).completeAction(const ActionId('second'), const ActionResult.failure());
      expect(first.completed, [const ActionId('first')]);
      expect(second.completed, [const ActionId('second')]);
      expect(JackfieldPlatform.instance, same(registered));
    },
  );
}

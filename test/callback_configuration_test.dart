import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jackfield/src/api/callback_configuration.dart';
import 'package:jackfield/src/api/events.dart';
import 'package:jackfield/src/api/identifiers.dart';
import 'package:jackfield/src/core/callback_dispatcher.dart';
import 'package:jackfield/src/storage/memory_event_journal.dart';

void main() {
  final occurredAt = DateTime.utc(2026, 9, 23, 5);
  final event = AnswerRequested(
    callId: const CallId('call-1'),
    actionId: const ActionId('action-3'),
    eventId: const EventId('event-7'),
    sequence: 2,
    occurredAt: occurredAt,
    deadline: occurredAt.add(const Duration(seconds: 30)),
  );

  test('401 and 403 pause HTTP delivery', () {
    for (final status in [401, 403]) {
      expect(
        RetryPolicy.standard.classify(
          statusCode: status,
          attempt: 1,
          retryAfter: null,
        ),
        isA<PauseForAuthentication>(),
      );
    }
  });

  test('retry-after is bounded to fifteen minutes', () {
    final decision = RetryPolicy.standard.classify(
      statusCode: 429,
      attempt: 2,
      retryAfter: const Duration(days: 1),
    );
    expect((decision as RetryLater).delay, const Duration(minutes: 15));
  });

  test('network and server failures retry with capped exponential delay', () {
    for (final status in <int?>[null, 500, 503, 599]) {
      final first = RetryPolicy.standard.classify(
        statusCode: status,
        attempt: 1,
      );
      final second = RetryPolicy.standard.classify(
        statusCode: status,
        attempt: 2,
      );
      final late = RetryPolicy.standard.classify(
        statusCode: status,
        attempt: 1000,
      );
      expect((first as RetryLater).delay, const Duration(seconds: 1));
      expect((second as RetryLater).delay, const Duration(seconds: 2));
      expect((late as RetryLater).delay, const Duration(minutes: 15));
    }
  });

  test('all 2xx succeed; redirects and non-auth client errors stop', () {
    for (final status in [200, 201, 204, 299]) {
      expect(
        RetryPolicy.standard.classify(statusCode: status, attempt: 1),
        isA<DeliverySucceeded>(),
      );
    }
    for (final status in [301, 302, 307, 400, 404, 422]) {
      expect(
        RetryPolicy.standard.classify(statusCode: status, attempt: 1),
        isA<DoNotRetry>(),
      );
    }
  });

  test('HTTP success acknowledges only the HTTP receipt', () async {
    final journal = MemoryEventJournal();
    await journal.append(event);
    final dispatcher = CallbackDispatcher(journal);

    final decision = await dispatcher.deliver(
      event,
      responseStatus: 204,
      attempt: 1,
      now: occurredAt.add(const Duration(seconds: 1)),
    );

    expect(decision, isA<DeliverySucceeded>());
    expect(await journal.pendingHttp(), isEmpty);
    expect(await journal.pendingFlutter(), [event]);
  });

  test('authentication pause keeps both delivery records pending', () async {
    final journal = MemoryEventJournal();
    await journal.append(event);
    final dispatcher = CallbackDispatcher(journal);

    final decision = await dispatcher.deliver(
      event,
      responseStatus: 401,
      attempt: 1,
      now: occurredAt.add(const Duration(seconds: 1)),
    );

    expect(decision, isA<PauseForAuthentication>());
    expect(journal.isHttpPausedForAuthentication, isTrue);
    expect(await journal.pendingHttp(), [event]);
    expect(await journal.pendingFlutter(), [event]);
  });

  test(
    'event reaching TTL is terminal even after a successful response',
    () async {
      final journal = MemoryEventJournal();
      await journal.append(event);
      final dispatcher = CallbackDispatcher(
        journal,
        timeToLive: const Duration(minutes: 10),
      );

      final decision = await dispatcher.deliver(
        event,
        responseStatus: 200,
        attempt: 1,
        now: occurredAt.add(const Duration(minutes: 10)),
      );

      expect(decision, isA<DoNotRetry>());
      expect(await journal.pendingFlutter(), [event]);
    },
  );

  test('canonical callback envelope matches fixture without credentials', () {
    final fixture = jsonDecode(
      File(
        'test/fixtures/callback_answer_requested_v1.json',
      ).readAsStringSync(),
    );
    final envelope = CallbackDispatcher.envelope(event);

    expect(envelope, fixture);
    expect(jsonEncode(envelope), isNot(contains('opaque-secret')));
  });
}

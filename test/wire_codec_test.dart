import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jackfield/jackfield.dart';

Map<String, Object?> jsonFixture(String name) {
  final decoded = jsonDecode(File('test/fixtures/$name').readAsStringSync());
  return (decoded as Map<String, dynamic>).cast<String, Object?>();
}

void main() {
  test('answer fixture round-trips without identity loss', () {
    final fixture = jsonFixture('event_answer_requested_v1.json');
    final event = WireCodec.decodeEvent(fixture);
    expect(event, isA<AnswerRequested>());
    expect(event.callId, const CallId('call-1'));
    expect(event.eventId, const EventId('event-7'));
    expect((event as AnswerRequested).actionId, const ActionId('action-3'));
    expect(WireCodec.encodeEvent(event), fixture);
  });

  test('ended fixture round-trips with its reason', () {
    final fixture = jsonFixture('event_ended_v1.json');
    final event = WireCodec.decodeEvent(fixture);
    expect(event, isA<CallEnded>());
    expect((event as CallEnded).reason, EndReason.remote);
    expect(WireCodec.encodeEvent(event), fixture);
  });

  test('newer version is rejected safely', () {
    expect(
      () => WireCodec.decodeEvent({'version': 99, 'type': 'ended'}),
      throwsA(isA<JackfieldProtocolException>()),
    );
  });

  test('malformed envelope is rejected safely', () {
    expect(
      () => WireCodec.decodeEvent({
        ...jsonFixture('event_ended_v1.json'),
        'sequence': -1,
      }),
      throwsA(isA<JackfieldProtocolException>()),
    );
  });

  test('invalid event fields fail with typed protocol errors', () {
    final ended = jsonFixture('event_ended_v1.json');
    final invalid = <Map<String, Object?>>[
      {...ended, 'callId': ''},
      {...ended, 'eventId': ''},
      {...ended}..remove('callId'),
      {...ended, 'sequence': 1.5},
      {...ended, 'type': 'unknown'},
      {...ended, 'occurredAt': 'not-a-date'},
      {...ended, 'reason': 'unknown'},
      {...ended, 'extra': true},
      {...jsonFixture('event_answer_requested_v1.json'), 'actionId': ''},
      {...jsonFixture('event_answer_requested_v1.json'), 'deadline': null},
    ];
    for (final payload in invalid) {
      expect(
        () => WireCodec.decodeEvent(payload),
        throwsA(isA<JackfieldProtocolException>()),
        reason: '$payload',
      );
    }
  });

  test('non-string map keys and non-map inputs fail with protocol errors', () {
    for (final payload in <Object?>[
      null,
      [],
      {1: 'bad', ...jsonFixture('event_ended_v1.json')},
    ]) {
      expect(
        () => WireCodec.decodeEvent(payload),
        throwsA(isA<JackfieldProtocolException>()),
      );
    }
  });

  test('push token snapshot cannot change through its source list', () {
    final source = [const PushToken(provider: 'apns', value: 'first')];
    final snapshot = PushTokenSnapshot(source);
    source.add(const PushToken(provider: 'apns', value: 'second'));
    expect(snapshot.tokens, hasLength(1));
    expect(
      () => snapshot.tokens.add(
        const PushToken(provider: 'apns', value: 'third'),
      ),
      throwsUnsupportedError,
    );
  });
}

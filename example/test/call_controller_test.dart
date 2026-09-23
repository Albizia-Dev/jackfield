import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jackfield/jackfield.dart';
import 'package:jackfield_example/call_controller.dart';

void main() {
  final event = AnswerRequested(
    callId: const CallId('call-1'),
    eventId: const EventId('event-1'),
    sequence: 1,
    occurredAt: DateTime.utc(2026),
    actionId: const ActionId('action-1'),
    deadline: DateTime.utc(2026, 1, 1, 0, 1),
  );

  test('answer waits for signaling before completion and ACK', () async {
    final plugin = RecordingJackfield();
    final signaling = ControlledSignaling();
    final controller = CallController(jackfield: plugin, signaling: signaling);
    final handling = controller.handle(event);

    await Future<void>.delayed(Duration.zero);
    expect(plugin.operations, isEmpty);
    signaling.finish(true);
    await handling;

    expect(plugin.operations, ['complete:action-1:success', 'ack:event-1']);
    expect(controller.status, contains('успеш'));
  });

  test('failed signaling completes failure then ACKs', () async {
    final plugin = RecordingJackfield();
    final signaling = ControlledSignaling();
    final controller = CallController(jackfield: plugin, signaling: signaling);
    final handling = controller.handle(event);
    signaling.finish(false);
    await handling;

    expect(plugin.operations, ['complete:action-1:failure', 'ack:event-1']);
    expect(controller.status, contains('ошиб'));
  });

  test(
    'signaling exception remains visible and ACK still follows failure',
    () async {
      final plugin = RecordingJackfield();
      final signaling = ControlledSignaling();
      final controller = CallController(
        jackfield: plugin,
        signaling: signaling,
      );
      final handling = controller.handle(event);
      signaling.fail(StateError('manual signaling unavailable'));
      await handling;

      expect(plugin.operations, ['complete:action-1:failure', 'ack:event-1']);
      expect(
        controller.eventLog.join(' '),
        contains('manual signaling unavailable'),
      );
    },
  );

  test(
    'failed action completion leaves event unacknowledged for replay',
    () async {
      final plugin = RecordingJackfield()..completionFails = true;
      final signaling = ControlledSignaling();
      final controller = CallController(
        jackfield: plugin,
        signaling: signaling,
      );
      final handling = controller.handle(event);
      signaling.finish(false);
      await handling;

      expect(plugin.operations, ['complete:action-1:failure']);
      expect(controller.eventLog.join(' '), contains('platformFailure'));
    },
  );
}

final class ControlledSignaling implements DemoSignaling {
  final _result = Completer<bool>();

  @override
  Future<bool> connect(CallId callId) => _result.future;

  void finish(bool success) => _result.complete(success);

  void fail(Object error) => _result.completeError(error);
}

final class RecordingJackfield implements Jackfield {
  final List<String> operations = [];
  bool completionFails = false;

  @override
  Future<JackfieldResult<void>> completeAction(
    ActionId id,
    ActionResult result,
  ) async {
    operations.add(
      'complete:${id.value}:${result.succeeded ? 'success' : 'failure'}',
    );
    if (completionFails) {
      return const JackfieldFailure(
        JackfieldError(JackfieldErrorCode.platformFailure),
      );
    }
    return const JackfieldSuccess<void>(null);
  }

  @override
  Future<JackfieldResult<void>> acknowledgeEvents(Set<EventId> ids) async {
    operations.add('ack:${ids.single.value}');
    return const JackfieldSuccess<void>(null);
  }

  @override
  Future<JackfieldCapabilities> capabilities() async =>
      JackfieldCapabilities.unavailable(platform: 'test', reason: 'test');

  @override
  Future<JackfieldDiagnostics> diagnostics() async => JackfieldDiagnostics(
    mechanism: JackfieldMechanism.unavailable,
    permissions: const {},
    httpPausedForAuthentication: false,
  );

  @override
  Future<JackfieldResult<CallSnapshot>> endCall(
    CallId id,
    EndReason reason,
  ) async =>
      const JackfieldFailure(JackfieldError(JackfieldErrorCode.unsupported));

  @override
  Stream<JackfieldEvent> get events => const Stream.empty();

  @override
  Future<JackfieldResult<void>> initialize(
    JackfieldConfiguration configuration,
  ) async => const JackfieldSuccess<void>(null);

  @override
  Future<JackfieldResult<PushTokenSnapshot>> pushTokens() async =>
      JackfieldSuccess(PushTokenSnapshot(const []));

  @override
  Stream<PushTokenUpdate> get pushTokenUpdates => const Stream.empty();

  @override
  Future<JackfieldResult<CallSnapshot>> reportIncomingCall(
    IncomingCall call,
  ) async =>
      const JackfieldFailure(JackfieldError(JackfieldErrorCode.unsupported));

  @override
  Future<JackfieldResult<CallSnapshot>> startOutgoingCall(
    OutgoingCall call,
  ) async =>
      const JackfieldFailure(JackfieldError(JackfieldErrorCode.unsupported));

  @override
  Future<JackfieldResult<CallSnapshot>> updateCall(CallUpdate update) async =>
      const JackfieldFailure(JackfieldError(JackfieldErrorCode.unsupported));
}

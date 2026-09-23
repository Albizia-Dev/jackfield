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

  test('failed ACK remains the visible status', () async {
    final plugin = RecordingJackfield()..ackFails = true;
    final signaling = ControlledSignaling();
    final controller = CallController(jackfield: plugin, signaling: signaling);
    final handling = controller.handle(event);
    signaling.finish(true);
    await handling;

    expect(plugin.operations, ['complete:action-1:success', 'ack:event-1']);
    expect(controller.status, contains('ACK event-1: ошибка platformFailure'));
  });

  test('concurrent and late duplicate answer events execute once', () async {
    final plugin = RecordingJackfield();
    final signaling = ControlledSignaling();
    final controller = CallController(jackfield: plugin, signaling: signaling);

    final first = controller.handle(event);
    final duplicate = controller.handle(event);
    expect(signaling.connectCount, 1);
    signaling.finish(true);
    await Future.wait([first, duplicate]);
    await controller.handle(event);

    expect(signaling.connectCount, 1);
    expect(plugin.operations, ['complete:action-1:success', 'ack:event-1']);
  });

  test(
    'replay retries failed completion without reconnecting signaling',
    () async {
      final plugin = RecordingJackfield()..completionFails = true;
      final signaling = ControlledSignaling();
      final controller = CallController(
        jackfield: plugin,
        signaling: signaling,
      );

      final first = controller.handle(event);
      signaling.finish(true);
      await first;
      expect(controller.currentCallId, isNull);

      plugin.completionFails = false;
      await controller.handle(event);

      expect(signaling.connectCount, 1);
      expect(plugin.operations, [
        'complete:action-1:success',
        'complete:action-1:success',
        'ack:event-1',
      ]);
      expect(controller.currentCallId, const CallId('call-1'));
    },
  );

  test(
    'replay retries failed ACK without reconnecting or completing',
    () async {
      final plugin = RecordingJackfield()..ackFails = true;
      final signaling = ControlledSignaling();
      final controller = CallController(
        jackfield: plugin,
        signaling: signaling,
      );

      final first = controller.handle(event);
      signaling.finish(true);
      await first;
      plugin.ackFails = false;
      await controller.handle(event);

      expect(signaling.connectCount, 1);
      expect(plugin.operations, [
        'complete:action-1:success',
        'ack:event-1',
        'ack:event-1',
      ]);
    },
  );

  test(
    'replayed answer selects a call that this controller never reported',
    () async {
      final plugin = RecordingJackfield();
      final signaling = ControlledSignaling();
      final controller = CallController(
        jackfield: plugin,
        signaling: signaling,
      );
      expect(controller.currentCallId, isNull);

      final handling = controller.handle(event);
      signaling.finish(true);
      await handling;
      await controller.endCurrentCall();

      expect(plugin.operations, [
        'complete:action-1:success',
        'ack:event-1',
        'end:call-1',
      ]);
    },
  );

  test(
    'ending another call does not clear the selected replayed call',
    () async {
      final plugin = RecordingJackfield();
      final signaling = ControlledSignaling();
      final controller = CallController(
        jackfield: plugin,
        signaling: signaling,
      );
      final handling = controller.handle(event);
      signaling.finish(true);
      await handling;

      await controller.handle(
        CallEnded(
          callId: const CallId('other-call'),
          eventId: const EventId('other-ended'),
          sequence: 2,
          occurredAt: DateTime.utc(2026),
          reason: EndReason.remote,
        ),
      );

      expect(controller.currentCallId, const CallId('call-1'));
    },
  );

  test('selected call clears when its ended event arrives', () async {
    final plugin = RecordingJackfield()..endSucceeds = true;
    final signaling = ControlledSignaling();
    final controller = CallController(jackfield: plugin, signaling: signaling);
    final handling = controller.handle(event);
    signaling.finish(true);
    await handling;

    await controller.endCurrentCall();
    expect(controller.currentCallId, const CallId('call-1'));

    await controller.handle(
      CallEnded(
        callId: const CallId('call-1'),
        eventId: const EventId('call-1-ended'),
        sequence: 2,
        occurredAt: DateTime.utc(2026),
        reason: EndReason.local,
      ),
    );
    expect(controller.currentCallId, isNull);
  });

  test('ended event during signaling cannot reselect that call', () async {
    final plugin = RecordingJackfield();
    final signaling = ControlledSignaling();
    final controller = CallController(jackfield: plugin, signaling: signaling);
    final answering = controller.handle(event);

    await controller.handle(
      CallEnded(
        callId: const CallId('call-1'),
        eventId: const EventId('call-1-ended'),
        sequence: 2,
        occurredAt: DateTime.utc(2026),
        reason: EndReason.remote,
      ),
    );
    signaling.finish(true);
    await answering;

    expect(controller.currentCallId, isNull);
  });

  test('disposing during answer still completes and acknowledges it', () async {
    final plugin = RecordingJackfield();
    final signaling = ControlledSignaling();
    final controller = CallController(jackfield: plugin, signaling: signaling);
    final handling = controller.handle(event);

    controller.dispose();
    signaling.finish(true);
    await handling;

    expect(plugin.operations, ['complete:action-1:success', 'ack:event-1']);
  });

  test(
    'disposing during initialize or refresh causes no late notification',
    () async {
      final plugin = RecordingJackfield()
        ..initialization = Completer<JackfieldResult<void>>()
        ..capability = Completer<JackfieldCapabilities>();
      final signaling = ControlledSignaling();
      final initializing = CallController(
        jackfield: plugin,
        signaling: signaling,
      );
      final refreshing = CallController(
        jackfield: plugin,
        signaling: signaling,
      );

      final initialization = initializing.initialize();
      final refresh = refreshing.refresh();
      initializing.dispose();
      refreshing.dispose();
      plugin.initialization!.complete(const JackfieldSuccess<void>(null));
      plugin.capability!.complete(
        JackfieldCapabilities.unavailable(platform: 'test', reason: 'test'),
      );

      await initialization;
      await refresh;
    },
  );
}

final class ControlledSignaling implements DemoSignaling {
  final _result = Completer<bool>();
  int connectCount = 0;

  @override
  Future<bool> connect(CallId callId) {
    connectCount++;
    return _result.future;
  }

  void finish(bool success) => _result.complete(success);

  void fail(Object error) => _result.completeError(error);
}

final class RecordingJackfield implements Jackfield {
  final List<String> operations = [];
  bool completionFails = false;
  bool ackFails = false;
  bool endSucceeds = false;
  Completer<JackfieldResult<void>>? initialization;
  Completer<JackfieldCapabilities>? capability;

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
    if (ackFails) {
      return const JackfieldFailure(
        JackfieldError(JackfieldErrorCode.platformFailure),
      );
    }
    return const JackfieldSuccess<void>(null);
  }

  @override
  Future<JackfieldCapabilities> capabilities() async => capability == null
      ? JackfieldCapabilities.unavailable(platform: 'test', reason: 'test')
      : await capability!.future;

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
  ) async {
    operations.add('end:${id.value}');
    if (endSucceeds) {
      return JackfieldSuccess(
        CallSnapshot(
          callId: id,
          state: CallState.ending,
          media: CallMedia.audio,
        ),
      );
    }
    return const JackfieldFailure(
      JackfieldError(JackfieldErrorCode.unsupported),
    );
  }

  @override
  Stream<JackfieldEvent> get events => const Stream.empty();

  @override
  Future<JackfieldResult<void>> initialize(
    JackfieldConfiguration configuration,
  ) async => initialization == null
      ? const JackfieldSuccess<void>(null)
      : await initialization!.future;

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

import 'package:flutter_test/flutter_test.dart';
import 'package:jackfield/src/api/call_models.dart';
import 'package:jackfield/src/api/identifiers.dart';
import 'package:jackfield/src/api/results.dart';
import 'package:jackfield/src/core/call_state_machine.dart';

void main() {
  const callId = CallId('call-1');
  const actionId = ActionId('answer-1');
  final now = DateTime.utc(2026, 9, 23, 5);
  final deadline = now.add(const Duration(seconds: 30));
  const machine = CallStateMachine();

  CallSnapshot snapshot(
    CallState state, {
    ActionId? actionId,
    DateTime? deadline,
  }) => CallSnapshot(
    callId: callId,
    state: state,
    media: CallMedia.audio,
    actionId: actionId,
    actionDeadline: deadline,
  );

  test('answer moves ringing to connecting once', () {
    final ringing = snapshot(CallState.ringing);
    final transition = AnswerRequestedTransition(actionId, deadline);

    final first = machine.apply(ringing, transition, now: now);
    final repeated = machine.apply(first.snapshot, transition, now: now);

    expect(first.snapshot.state, CallState.connecting);
    expect(first.snapshot.actionId, actionId);
    expect(first.snapshot.actionDeadline, deadline);
    expect(first.error, isNull);
    expect(repeated.wasDuplicate, isTrue);
    expect(repeated.snapshot, same(first.snapshot));
  });

  test('expired answer cannot become active', () {
    final connecting = snapshot(
      CallState.connecting,
      actionId: actionId,
      deadline: deadline,
    );

    final result = machine.apply(
      connecting,
      const CompleteActionTransition.success(actionId),
      now: deadline.add(const Duration(microseconds: 1)),
    );

    expect(result.error?.code, JackfieldErrorCode.deadlineExceeded);
    expect(result.snapshot.state, CallState.failed);
  });

  test('legal state edges advance without changing call identity', () {
    const edges = <CallState, List<CallState>>{
      CallState.created: [
        CallState.ringing,
        CallState.connecting,
        CallState.ending,
        CallState.failed,
      ],
      CallState.ringing: [
        CallState.connecting,
        CallState.ending,
        CallState.failed,
      ],
      CallState.connecting: [
        CallState.active,
        CallState.ending,
        CallState.failed,
      ],
      CallState.active: [CallState.ending, CallState.failed],
      CallState.ending: [CallState.ended, CallState.failed],
    };

    for (final entry in edges.entries) {
      for (final target in entry.value) {
        final result = machine.apply(
          snapshot(entry.key),
          MoveCallTransition(target),
          now: now,
        );
        expect(result.error, isNull, reason: '${entry.key} → $target');
        expect(result.snapshot.state, target);
        expect(result.snapshot.callId, callId);
      }
    }
  });

  test('illegal edge returns invalidState and original snapshot', () {
    final original = snapshot(CallState.ringing);

    final result = machine.apply(
      original,
      const MoveCallTransition(CallState.active),
      now: now,
    );

    expect(result.error?.code, JackfieldErrorCode.invalidState);
    expect(result.snapshot, same(original));
  });

  test('terminal states cannot transition', () {
    for (final state in [CallState.ended, CallState.failed]) {
      final original = snapshot(state);
      final result = machine.apply(
        original,
        const MoveCallTransition(CallState.ending),
        now: now,
      );
      expect(result.error?.code, JackfieldErrorCode.invalidState);
      expect(result.snapshot, same(original));
    }
  });

  test('completion at the deadline activates the call once', () {
    final connecting = snapshot(
      CallState.connecting,
      actionId: actionId,
      deadline: deadline,
    );
    const transition = CompleteActionTransition.success(actionId);

    final first = machine.apply(connecting, transition, now: deadline);
    final repeated = machine.apply(first.snapshot, transition, now: deadline);

    expect(first.error, isNull);
    expect(first.snapshot.state, CallState.active);
    expect(repeated.wasDuplicate, isTrue);
    expect(repeated.snapshot, same(first.snapshot));
  });

  test('unrelated action cannot complete a pending answer', () {
    final connecting = snapshot(
      CallState.connecting,
      actionId: actionId,
      deadline: deadline,
    );

    final result = machine.apply(
      connecting,
      const CompleteActionTransition.success(ActionId('other')),
      now: now,
    );

    expect(result.error?.code, JackfieldErrorCode.invalidState);
    expect(result.snapshot, same(connecting));
  });

  test('pending answer cannot be bypassed by a state move', () {
    final connecting = snapshot(
      CallState.connecting,
      actionId: actionId,
      deadline: deadline,
    );

    final result = machine.apply(
      connecting,
      const MoveCallTransition(CallState.active),
      now: deadline.add(const Duration(seconds: 1)),
    );

    expect(result.error?.code, JackfieldErrorCode.deadlineExceeded);
    expect(result.snapshot.state, CallState.failed);
  });

  test('replayed answer stays duplicate after activation', () {
    final active = snapshot(
      CallState.active,
      actionId: actionId,
      deadline: deadline,
    );

    final result = machine.apply(
      active,
      AnswerRequestedTransition(actionId, deadline),
      now: deadline.add(const Duration(seconds: 1)),
    );

    expect(result.wasDuplicate, isTrue);
    expect(result.snapshot, same(active));
  });

  test('expired answer request fails before connecting', () {
    final ringing = snapshot(CallState.ringing);

    final result = machine.apply(
      ringing,
      AnswerRequestedTransition(actionId, deadline),
      now: deadline.add(const Duration(microseconds: 1)),
    );

    expect(result.error?.code, JackfieldErrorCode.deadlineExceeded);
    expect(result.snapshot.state, CallState.failed);
  });

  test('different action cannot replace a pending answer', () {
    final connecting = snapshot(
      CallState.connecting,
      actionId: actionId,
      deadline: deadline,
    );

    final result = machine.apply(
      connecting,
      AnswerRequestedTransition(const ActionId('other'), deadline),
      now: now,
    );

    expect(result.error?.code, JackfieldErrorCode.invalidState);
    expect(result.snapshot, same(connecting));
  });

  test(
    'failed completion is terminal and repeated completion is duplicate',
    () {
      final connecting = snapshot(
        CallState.connecting,
        actionId: actionId,
        deadline: deadline,
      );
      const transition = CompleteActionTransition.failure(actionId);

      final first = machine.apply(connecting, transition, now: now);
      final repeated = machine.apply(first.snapshot, transition, now: now);

      expect(first.error, isNull);
      expect(first.snapshot.state, CallState.failed);
      expect(repeated.wasDuplicate, isTrue);
    },
  );

  test('timed-out completion remains duplicate when replayed', () {
    final connecting = snapshot(
      CallState.connecting,
      actionId: actionId,
      deadline: deadline,
    );
    const transition = CompleteActionTransition.success(actionId);
    final late = deadline.add(const Duration(seconds: 1));

    final first = machine.apply(connecting, transition, now: late);
    final repeated = machine.apply(first.snapshot, transition, now: late);

    expect(first.error?.code, JackfieldErrorCode.deadlineExceeded);
    expect(repeated.wasDuplicate, isTrue);
    expect(repeated.error?.code, JackfieldErrorCode.deadlineExceeded);
    expect(repeated.snapshot, same(first.snapshot));
  });

  test('completed answer remains idempotent after the call starts ending', () {
    final ringing = snapshot(CallState.ringing);
    final answered = machine.apply(
      ringing,
      AnswerRequestedTransition(actionId, deadline),
      now: now,
    );
    final completed = machine.apply(
      answered.snapshot,
      const CompleteActionTransition.success(actionId),
      now: now,
    );
    final ending = machine.apply(
      completed.snapshot,
      const MoveCallTransition(CallState.ending),
      now: now,
    );

    final replayed = machine.apply(
      ending.snapshot,
      const CompleteActionTransition.success(actionId),
      now: now,
    );

    expect(replayed.wasDuplicate, isTrue);
    expect(replayed.error, isNull);
    expect(replayed.snapshot, same(ending.snapshot));
    expect(ending.snapshot.actionReceipts.single.succeeded, isTrue);
  });

  test('restored snapshot recognizes a completed action receipt', () {
    final source = snapshot(CallState.ringing);
    final answered = machine.apply(
      source,
      AnswerRequestedTransition(actionId, deadline),
      now: now,
    );
    final completed = machine.apply(
      answered.snapshot,
      const CompleteActionTransition.success(actionId),
      now: now,
    );
    final restored = CallSnapshot(
      callId: callId,
      state: CallState.ending,
      media: CallMedia.audio,
      actionReceipts: completed.snapshot.actionReceipts,
    );

    final replayed = machine.apply(
      restored,
      const CompleteActionTransition.success(actionId),
      now: now,
    );

    expect(replayed.wasDuplicate, isTrue);
    expect(replayed.error, isNull);
    expect(replayed.snapshot, same(restored));
  });
}

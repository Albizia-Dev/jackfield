import '../api/call_models.dart';
import '../api/identifiers.dart';
import '../api/results.dart';
import 'clock.dart';

const _legalEdges = <CallState, Set<CallState>>{
  CallState.created: {
    CallState.ringing,
    CallState.connecting,
    CallState.ending,
    CallState.failed,
  },
  CallState.ringing: {CallState.connecting, CallState.ending, CallState.failed},
  CallState.connecting: {CallState.active, CallState.ending, CallState.failed},
  CallState.active: {CallState.ending, CallState.failed},
  CallState.ending: {CallState.ended, CallState.failed},
  CallState.ended: {},
  CallState.failed: {},
};

/// An input to the deterministic call state machine.
sealed class CallTransition {
  /// Creates a transition subtype.
  const CallTransition();
}

/// Moves a call along one legal state edge.
final class MoveCallTransition extends CallTransition {
  /// Creates a request to move to [target].
  const MoveCallTransition(this.target);

  /// The state requested by this transition.
  final CallState target;
}

/// Records a system answer request that the application must complete.
final class AnswerRequestedTransition extends CallTransition {
  /// Creates an answer request with its identity and last valid instant.
  const AnswerRequestedTransition(this.actionId, this.deadline);

  /// The identity to use when completing this answer request.
  final ActionId actionId;

  /// The last instant at which this action may succeed.
  final DateTime deadline;
}

/// Completes an outstanding application-owned action.
final class CompleteActionTransition extends CallTransition {
  /// Completes the action successfully.
  const CompleteActionTransition.success(this.actionId) : succeeded = true;

  /// Completes the action with failure.
  const CompleteActionTransition.failure(this.actionId) : succeeded = false;

  /// The action being completed.
  final ActionId actionId;

  /// Whether the application completed the action successfully.
  final bool succeeded;
}

/// The result of applying one transition to a snapshot.
final class CallTransitionResult {
  /// Creates a transition result.
  const CallTransitionResult(
    this.snapshot, {
    this.error,
    this.wasDuplicate = false,
  });

  /// The resulting call snapshot.
  final CallSnapshot snapshot;

  /// A typed error when the transition could not be applied.
  final JackfieldError? error;

  /// Whether the same action was already applied.
  final bool wasDuplicate;
}

/// Applies call transitions without consulting a platform or wall clock.
final class CallStateMachine {
  /// Creates a stateless call state machine.
  const CallStateMachine();

  /// Applies [transition] at the caller-supplied [now].
  CallTransitionResult apply(
    CallSnapshot snapshot,
    CallTransition transition, {
    required DateTime now,
  }) {
    return switch (transition) {
      MoveCallTransition(:final target) => _move(snapshot, target, now),
      AnswerRequestedTransition(:final actionId, :final deadline) => _answer(
        snapshot,
        actionId,
        deadline,
        now,
      ),
      CompleteActionTransition(:final actionId, :final succeeded) => _complete(
        snapshot,
        actionId,
        succeeded,
        now,
      ),
    };
  }

  CallTransitionResult _move(
    CallSnapshot snapshot,
    CallState target,
    DateTime now,
  ) {
    if (!_legalEdges[snapshot.state]!.contains(target)) {
      return _invalid(snapshot);
    }
    if (target == CallState.active && snapshot.actionId != null) {
      final deadline = snapshot.actionDeadline;
      if (deadline != null && isPastDeadline(now, deadline)) {
        const error = JackfieldError(JackfieldErrorCode.deadlineExceeded);
        return CallTransitionResult(
          _copy(
            snapshot,
            CallState.failed,
            receipt: CallActionReceipt(
              actionId: snapshot.actionId!,
              succeeded: false,
              error: error,
            ),
          ),
          error: error,
        );
      }
      return _invalid(snapshot);
    }
    return CallTransitionResult(_copy(snapshot, target));
  }

  CallTransitionResult _answer(
    CallSnapshot snapshot,
    ActionId actionId,
    DateTime deadline,
    DateTime now,
  ) {
    final receipt = _receiptFor(snapshot, actionId);
    if (receipt != null) {
      return CallTransitionResult(
        snapshot,
        error: receipt.error,
        wasDuplicate: true,
      );
    }
    if (snapshot.actionId == actionId) {
      return CallTransitionResult(snapshot, wasDuplicate: true);
    }
    if (snapshot.state != CallState.ringing) {
      return _invalid(snapshot);
    }
    if (isPastDeadline(now, deadline)) {
      const error = JackfieldError(JackfieldErrorCode.deadlineExceeded);
      return CallTransitionResult(
        _copy(
          snapshot,
          CallState.failed,
          actionId: actionId,
          deadline: deadline,
          receipt: CallActionReceipt(
            actionId: actionId,
            succeeded: false,
            error: error,
          ),
        ),
        error: error,
      );
    }
    return CallTransitionResult(
      _copy(
        snapshot,
        CallState.connecting,
        actionId: actionId,
        deadline: deadline,
      ),
    );
  }

  CallTransitionResult _complete(
    CallSnapshot snapshot,
    ActionId actionId,
    bool succeeded,
    DateTime now,
  ) {
    final receipt = _receiptFor(snapshot, actionId);
    if (receipt != null) {
      return CallTransitionResult(
        snapshot,
        error: receipt.error,
        wasDuplicate: true,
      );
    }
    if (snapshot.state != CallState.connecting ||
        snapshot.actionId != actionId ||
        snapshot.actionDeadline == null) {
      return _invalid(snapshot);
    }
    if (isPastDeadline(now, snapshot.actionDeadline!)) {
      const error = JackfieldError(JackfieldErrorCode.deadlineExceeded);
      return CallTransitionResult(
        _copy(
          snapshot,
          CallState.failed,
          receipt: CallActionReceipt(
            actionId: actionId,
            succeeded: false,
            error: error,
          ),
        ),
        error: error,
      );
    }
    return CallTransitionResult(
      _copy(
        snapshot,
        succeeded ? CallState.active : CallState.failed,
        receipt: CallActionReceipt(actionId: actionId, succeeded: succeeded),
      ),
    );
  }

  CallActionReceipt? _receiptFor(CallSnapshot snapshot, ActionId actionId) {
    for (final receipt in snapshot.actionReceipts) {
      if (receipt.actionId == actionId) return receipt;
    }
    return null;
  }

  CallTransitionResult _invalid(CallSnapshot snapshot) => CallTransitionResult(
    snapshot,
    error: const JackfieldError(JackfieldErrorCode.invalidState),
  );

  CallSnapshot _copy(
    CallSnapshot snapshot,
    CallState state, {
    ActionId? actionId,
    DateTime? deadline,
    CallActionReceipt? receipt,
  }) => CallSnapshot(
    callId: snapshot.callId,
    state: state,
    media: snapshot.media,
    caller: snapshot.caller,
    actionId: actionId ?? snapshot.actionId,
    actionDeadline: deadline ?? snapshot.actionDeadline,
    actionReceipts: [...snapshot.actionReceipts, ?receipt],
  );
}

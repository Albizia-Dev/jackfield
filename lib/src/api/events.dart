import 'call_models.dart';
import 'identifiers.dart';

/// A durable event associated with one call.
sealed class JackfieldEvent {
  /// Creates a call event.
  const JackfieldEvent({
    required this.callId,
    required this.eventId,
    required this.sequence,
    required this.occurredAt,
  });

  /// The call to which this event belongs.
  final CallId callId;

  /// The delivery identity, independent of any action identity.
  final EventId eventId;

  /// The nonnegative sequence within [callId].
  final int sequence;

  /// The UTC time at which the event occurred.
  final DateTime occurredAt;
}

/// The system user requested an answer that the application must complete.
final class AnswerRequested extends JackfieldEvent {
  /// Creates an answer request event.
  const AnswerRequested({
    required super.callId,
    required super.eventId,
    required super.sequence,
    required super.occurredAt,
    required this.actionId,
    required this.deadline,
  });

  /// The identity passed to completeAction.
  final ActionId actionId;

  /// The last instant at which this action may succeed.
  final DateTime deadline;
}

/// The call has reached its ended state.
final class CallEnded extends JackfieldEvent {
  /// Creates a call-ended event.
  const CallEnded({
    required super.callId,
    required super.eventId,
    required super.sequence,
    required super.occurredAt,
    required this.reason,
  });

  /// Why the call ended.
  final EndReason reason;
}

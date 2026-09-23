import 'identifiers.dart';
import 'results.dart';

/// The media requested for a call; Jackfield does not transport it.
enum CallMedia {
  /// Audio only.
  audio,

  /// Audio and video.
  video,
}

/// Caller information suitable for a system call presentation.
final class Caller {
  /// Creates caller information.
  const Caller({required this.id, required this.displayName});

  /// Application-owned identifier for the caller.
  final String id;

  /// Human-readable name for the call presentation.
  final String displayName;
}

/// A request to present an incoming call.
final class IncomingCall {
  /// Creates an incoming-call request.
  const IncomingCall({
    required this.callId,
    required this.caller,
    required this.media,
  });

  /// The call attempt identifier.
  final CallId callId;

  /// The remote caller.
  final Caller caller;

  /// The requested media kind.
  final CallMedia media;
}

/// A request to start an outgoing call.
final class OutgoingCall {
  /// Creates an outgoing-call request.
  const OutgoingCall({
    required this.callId,
    required this.callee,
    required this.media,
  });

  /// The call attempt identifier.
  final CallId callId;

  /// The remote party being called.
  final Caller callee;

  /// The requested media kind.
  final CallMedia media;
}

/// A partial update to the system presentation of a call.
final class CallUpdate {
  /// Creates a call update.
  const CallUpdate({required this.callId, this.caller, this.media});

  /// The call to update.
  final CallId callId;

  /// A replacement caller, if supplied.
  final Caller? caller;

  /// A replacement media kind, if supplied.
  final CallMedia? media;
}

/// The local state of a call.
enum CallState {
  /// The call is known but not presented yet.
  created,

  /// The call is ringing.
  ringing,

  /// An answer or outgoing connection is in progress.
  connecting,

  /// The call is active.
  active,

  /// Termination is in progress.
  ending,

  /// The call has ended.
  ended,

  /// The call failed.
  failed,
}

/// Why a call ended.
enum EndReason {
  /// The local user ended the call.
  local,

  /// The remote participant or server ended the call.
  remote,

  /// The local user rejected the call.
  rejected,

  /// The call was not answered in time.
  missed,

  /// The call ended because of an error.
  failed,
}

/// The current local view of one call.
final class CallSnapshot {
  /// Creates a snapshot of a call.
  CallSnapshot({
    required this.callId,
    required this.state,
    required this.media,
    this.caller,
    this.actionId,
    this.actionDeadline,
    Iterable<CallActionReceipt> actionReceipts = const [],
  }) : actionReceipts = List<CallActionReceipt>.unmodifiable(actionReceipts);

  /// The call attempt identifier.
  final CallId callId;

  /// Its current local state.
  final CallState state;

  /// The call media kind.
  final CallMedia media;

  /// The other participant, when known.
  final Caller? caller;

  /// The most recently accepted system action, including a completed one.
  final ActionId? actionId;

  /// The deadline associated with [actionId], when one exists.
  final DateTime? actionDeadline;

  /// Persisted outcomes needed to recognize completed action replays.
  final List<CallActionReceipt> actionReceipts;
}

/// The known outcome of one application-owned action.
final class CallActionReceipt {
  /// Creates a durable action outcome.
  const CallActionReceipt({
    required this.actionId,
    required this.succeeded,
    this.error,
  });

  /// The identity of the action whose outcome is recorded.
  final ActionId actionId;

  /// Whether the action succeeded before its deadline.
  final bool succeeded;

  /// The typed failure when the action expired.
  final JackfieldError? error;
}

/// The outcome of an application-owned action, such as connecting media.
final class ActionResult {
  /// Reports that the application completed the action.
  const ActionResult.success() : succeeded = true;

  /// Reports that the application could not complete the action.
  const ActionResult.failure() : succeeded = false;

  /// Whether the requested action succeeded.
  final bool succeeded;
}

/// A push token and its provider-assigned value.
final class PushToken {
  /// Creates a provider-agnostic token record.
  const PushToken({required this.provider, required this.value});

  /// Provider label, such as APNs or Web Push.
  final String provider;

  /// Opaque token value supplied by the provider.
  final String value;
}

/// The currently known push tokens.
final class PushTokenSnapshot {
  /// Creates a snapshot of the tokens currently known to Jackfield.
  PushTokenSnapshot(Iterable<PushToken> tokens)
    : tokens = List<PushToken>.unmodifiable(tokens);

  /// The tokens available from this adapter.
  final List<PushToken> tokens;
}

/// A change in a platform push token.
final class PushTokenUpdate {
  /// Creates a token update.
  const PushTokenUpdate({required this.token, required this.removed});

  /// The added, changed, or removed token.
  final PushToken token;

  /// Whether this token was removed rather than supplied.
  final bool removed;
}

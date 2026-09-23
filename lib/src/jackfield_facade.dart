import 'api/call_models.dart';
import 'api/capabilities.dart';
import 'api/configuration.dart';
import 'api/diagnostics.dart';
import 'api/events.dart';
import 'api/identifiers.dart';
import 'api/results.dart';
import 'platform/jackfield_platform.dart';

/// Application API for system call presentation and durable event delivery.
///
/// The application owns signaling and media. Expected command failures are
/// returned as [JackfieldFailure]; malformed diagnostic/capability responses
/// throw protocol exceptions. Stream protocol failures are stream errors.
/// Query and stream transport failures use [JackfieldTransportException] without
/// native exception payloads. Stream cancellation failures are reported through
/// FlutterError with the same safe exception when no listener remains.
abstract class Jackfield {
  /// Creates an independently injected facade without changing registration.
  factory Jackfield.withPlatform(JackfieldPlatform platform) = _Jackfield;

  /// The shared facade, bound to the adapter registered at first access.
  ///
  /// Platform plugins must register before this property is first read.
  static final Jackfield instance = Jackfield.withPlatform(
    JackfieldPlatform.instance,
  );

  /// Initializes the adapter without requesting system permissions.
  Future<JackfieldResult<void>> initialize(
    JackfieldConfiguration configuration,
  );

  /// Reports the available features and actual presentation mechanism.
  Future<JackfieldCapabilities> capabilities();

  /// Reports an incoming call using its stable call-attempt identity.
  Future<JackfieldResult<CallSnapshot>> reportIncomingCall(IncomingCall call);

  /// Starts the system presentation of an outgoing call; the app owns media.
  Future<JackfieldResult<CallSnapshot>> startOutgoingCall(OutgoingCall call);

  /// Updates the system presentation of an existing call.
  Future<JackfieldResult<CallSnapshot>> updateCall(CallUpdate update);

  /// Ends the specified call with an explicit termination reason.
  Future<JackfieldResult<CallSnapshot>> endCall(CallId id, EndReason reason);

  /// Completes an OS action after application work; never acknowledges events.
  Future<JackfieldResult<void>> completeAction(
    ActionId id,
    ActionResult result,
  );

  /// Acknowledges Flutter delivery only; never completes actions or HTTP delivery.
  Future<JackfieldResult<void>> acknowledgeEvents(Set<EventId> ids);

  /// Reads permission and queue health without exposing tokens or credentials.
  Future<JackfieldDiagnostics> diagnostics();

  /// Returns all currently known provider tokens without requesting permission.
  Future<JackfieldResult<PushTokenSnapshot>> pushTokens();

  /// Broadcast events, including replay of unacknowledged records on attachment.
  ///
  /// Deduplicate by eventId and explicitly acknowledge after durable handling.
  /// Listening and cancelling subscriptions never acknowledge an event.
  Stream<JackfieldEvent> get events;

  /// Broadcast provider-token additions, rotations and removals.
  ///
  /// Subscribe before calling [pushTokens] when combining updates and snapshot.
  Stream<PushTokenUpdate> get pushTokenUpdates;
}

final class _Jackfield implements Jackfield {
  _Jackfield(this._platform);
  final JackfieldPlatform _platform;

  @override
  Future<JackfieldResult<void>> initialize(
    JackfieldConfiguration configuration,
  ) => _platform.initialize(configuration);

  @override
  Future<JackfieldCapabilities> capabilities() => _platform.capabilities();

  @override
  Future<JackfieldResult<CallSnapshot>> reportIncomingCall(IncomingCall call) =>
      _platform.reportIncomingCall(call);

  @override
  Future<JackfieldResult<CallSnapshot>> startOutgoingCall(OutgoingCall call) =>
      _platform.startOutgoingCall(call);

  @override
  Future<JackfieldResult<CallSnapshot>> updateCall(CallUpdate update) =>
      _platform.updateCall(update);

  @override
  Future<JackfieldResult<CallSnapshot>> endCall(CallId id, EndReason reason) =>
      _platform.endCall(id, reason);

  @override
  Future<JackfieldResult<void>> completeAction(
    ActionId id,
    ActionResult result,
  ) => _platform.completeAction(id, result);

  @override
  Future<JackfieldResult<void>> acknowledgeEvents(Set<EventId> ids) =>
      _platform.acknowledgeEvents(ids);

  @override
  Future<JackfieldDiagnostics> diagnostics() => _platform.diagnostics();

  @override
  Future<JackfieldResult<PushTokenSnapshot>> pushTokens() =>
      _platform.pushTokens();

  @override
  Stream<JackfieldEvent> get events => _platform.events;

  @override
  Stream<PushTokenUpdate> get pushTokenUpdates => _platform.pushTokenUpdates;
}

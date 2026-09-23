import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../api/call_models.dart';
import '../api/capabilities.dart';
import '../api/configuration.dart';
import '../api/diagnostics.dart';
import '../api/events.dart';
import '../api/identifiers.dart';
import '../api/results.dart';
import 'method_channel_jackfield.dart';

/// Typed adapter contract for platform plugin implementations.
///
/// Extend this class to retain token verification and unsupported defaults.
/// Register before the application's first access to Jackfield.instance.
/// Durable adapters must persist events before publishing, replay the pending
/// inbox on stream attachment, and keep action, Flutter and HTTP receipts separate.
abstract class JackfieldPlatform extends PlatformInterface {
  /// Constructs a token-verified platform adapter.
  JackfieldPlatform() : super(token: _token);
  static final Object _token = Object();
  static JackfieldPlatform _instance = MethodChannelJackfield();

  /// The registered adapter, defaulting to the method-channel implementation.
  static JackfieldPlatform get instance => _instance;

  /// Registers an adapter that extends this contract.
  ///
  /// Test/application injection belongs in Jackfield.withPlatform and does not
  /// mutate this process-wide registration.
  static set instance(JackfieldPlatform platform) {
    PlatformInterface.verifyToken(platform, _token);
    _instance = platform;
  }

  /// Initializes the adapter without requesting system permissions.
  Future<JackfieldResult<void>> initialize(
    JackfieldConfiguration configuration,
  ) async =>
      const JackfieldFailure(JackfieldError(JackfieldErrorCode.unsupported));

  /// Reports the available features and actual presentation mechanism.
  Future<JackfieldCapabilities> capabilities() async =>
      JackfieldCapabilities.unavailable(
        platform: 'unregistered',
        reason: 'No adapter registered',
      );

  /// Reports an incoming call using its stable call-attempt identity.
  Future<JackfieldResult<CallSnapshot>> reportIncomingCall(
    IncomingCall call,
  ) async =>
      const JackfieldFailure(JackfieldError(JackfieldErrorCode.unsupported));

  /// Starts the system presentation of an outgoing call; the app owns media.
  Future<JackfieldResult<CallSnapshot>> startOutgoingCall(
    OutgoingCall call,
  ) async =>
      const JackfieldFailure(JackfieldError(JackfieldErrorCode.unsupported));

  /// Updates the system presentation of an existing call.
  Future<JackfieldResult<CallSnapshot>> updateCall(CallUpdate update) async =>
      const JackfieldFailure(JackfieldError(JackfieldErrorCode.unsupported));

  /// Ends the specified call with an explicit termination reason.
  Future<JackfieldResult<CallSnapshot>> endCall(
    CallId id,
    EndReason reason,
  ) async =>
      const JackfieldFailure(JackfieldError(JackfieldErrorCode.unsupported));

  /// Completes an OS action after application work; never acknowledges events.
  Future<JackfieldResult<void>> completeAction(
    ActionId id,
    ActionResult result,
  ) async =>
      const JackfieldFailure(JackfieldError(JackfieldErrorCode.unsupported));

  /// Acknowledges Flutter delivery only; never completes actions or HTTP delivery.
  Future<JackfieldResult<void>> acknowledgeEvents(Set<EventId> ids) async =>
      const JackfieldFailure(JackfieldError(JackfieldErrorCode.unsupported));

  /// Reads permission and queue health without exposing tokens or credentials.
  Future<JackfieldDiagnostics> diagnostics() async => JackfieldDiagnostics(
    mechanism: JackfieldMechanism.unavailable,
    permissions: const {},
    httpPausedForAuthentication: false,
    lastError: const JackfieldError(JackfieldErrorCode.unsupported),
  );

  /// Returns all currently known provider tokens without requesting permission.
  Future<JackfieldResult<PushTokenSnapshot>> pushTokens() async =>
      const JackfieldFailure(JackfieldError(JackfieldErrorCode.unsupported));

  /// Broadcast durable events; attachment must replay unacknowledged events.
  Stream<JackfieldEvent> get events => const Stream.empty();

  /// Broadcast changes to provider tokens, without permission prompts.
  Stream<PushTokenUpdate> get pushTokenUpdates => const Stream.empty();
}

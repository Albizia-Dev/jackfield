import 'capabilities.dart';
import 'results.dart';

/// The adapter's last observed state of a system permission.
enum JackfieldPermissionState {
  /// Permission has not been inspected or cannot be determined.
  unknown,

  /// Permission has not yet been requested by the application.
  notDetermined,

  /// The permission is currently granted.
  granted,

  /// The permission is currently denied.
  denied,

  /// The system restricts permission independently of application requests.
  restricted,
}

/// A read-only snapshot of adapter health, excluding credentials and tokens.
final class JackfieldDiagnostics {
  /// Creates diagnostics; null queue counts mean the counts are unavailable.
  JackfieldDiagnostics({
    required this.mechanism,
    required Map<String, JackfieldPermissionState> permissions,
    this.pendingFlutterEvents,
    this.pendingHttpEvents,
    required this.httpPausedForAuthentication,
    this.lastError,
  }) : permissions = Map.unmodifiable(permissions);

  /// The currently active system presentation mechanism.
  final JackfieldMechanism mechanism;

  /// Adapter-defined permission names and their last observed states.
  final Map<String, JackfieldPermissionState> permissions;

  /// Unacknowledged Flutter events, or null when unavailable.
  final int? pendingFlutterEvents;

  /// Pending HTTP callbacks, or null when unavailable.
  final int? pendingHttpEvents;

  /// Whether HTTP delivery awaits credential rotation.
  final bool httpPausedForAuthentication;

  /// The latest typed adapter failure, with safe diagnostic text only.
  final JackfieldError? lastError;
}

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

/// A permission Jackfield can inspect or request for call presentation.
enum JackfieldPermission {
  /// Capturing the local participant's voice.
  microphone,

  /// Posting incoming-call and foreground-service notifications.
  notifications,

  /// Connecting to nearby Bluetooth call-audio devices.
  bluetooth,

  /// Presenting an incoming call above the Android lock screen.
  fullScreenIntent,
}

/// Selects the call permissions to request from the current platform.
final class JackfieldPermissionRequest {
  /// Creates a request for the permissions needed by a normal audio call.
  ///
  /// Platforms ignore inapplicable permissions and report them as [JackfieldPermissionState.unknown].
  const JackfieldPermissionRequest({
    this.microphone = true,
    this.notifications = true,
    this.bluetooth = true,
    this.fullScreenIntent = true,
  });

  /// Whether microphone access should be requested.
  final bool microphone;

  /// Whether notification access should be requested.
  final bool notifications;

  /// Whether Bluetooth call-audio access should be requested.
  final bool bluetooth;

  /// Whether lock-screen full-screen presentation should be requested.
  final bool fullScreenIntent;
}

/// The observed result after a platform permission request completes.
final class JackfieldPermissionReport {
  /// Creates an immutable permission report.
  JackfieldPermissionReport({
    required Map<JackfieldPermission, JackfieldPermissionState> states,
    required this.openedSettings,
  }) : states = Map.unmodifiable(states);

  /// State of every permission included in the request.
  final Map<JackfieldPermission, JackfieldPermissionState> states;

  /// Whether the platform had to open a system settings page.
  final bool openedSettings;
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

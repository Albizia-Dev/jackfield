import 'callback_configuration.dart';

/// Configuration applied when initializing an adapter.
///
/// Initialization must not prompt for system permissions. The host application
/// remains responsible for requesting permission in a user-initiated flow.
final class JackfieldConfiguration {
  /// Creates configuration with autonomous callbacks disabled by default.
  const JackfieldConfiguration({this.callbacks});

  /// Autonomous callback delivery, or null to disable it.
  final CallbackConfiguration? callbacks;
}

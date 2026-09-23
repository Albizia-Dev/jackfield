/// A call feature that a platform adapter may support.
enum JackfieldFeature {
  /// Display an incoming call.
  incoming,

  /// Start an outgoing call.
  outgoing,

  /// Answer an incoming call.
  answer,

  /// Reject an incoming call.
  reject,

  /// End an active call.
  end,

  /// Mute an active call.
  mute,

  /// Put an active call on hold.
  hold,

  /// Persist events until they are acknowledged.
  durableEvents,

  /// Deliver events through HTTP callbacks.
  httpCallbacks,

  /// Register push tokens.
  pushTokens,
}

/// The mechanism used to present calls on a platform.
enum JackfieldMechanism {
  /// No call presentation mechanism is available.
  unavailable,

  /// The platform's native call interface is used.
  nativeCallUi,

  /// A system notification is used.
  systemNotification,

  /// A browser notification is used.
  webNotification,
}

/// Reports the features and presentation mechanism available on a platform.
final class JackfieldCapabilities {
  /// Creates an explicit platform capability report.
  const JackfieldCapabilities({
    required this.platform,
    required this.mechanism,
    required this.features,
    this.reason,
  });

  /// Reports that no features are available for [platform].
  factory JackfieldCapabilities.unavailable({
    required String platform,
    required String reason,
  }) => JackfieldCapabilities(
    platform: platform,
    mechanism: JackfieldMechanism.unavailable,
    features: const {},
    reason: reason,
  );

  /// The platform whose capabilities are reported.
  final String platform;

  /// The call presentation mechanism available on [platform].
  final JackfieldMechanism mechanism;

  /// The call features available on [platform].
  final Set<JackfieldFeature> features;

  /// Why the adapter is unavailable, when applicable.
  final String? reason;
}

/// Identifies one local attempt to place or receive a call.
extension type const CallId(
  /// Stable application identity for one call attempt.
  String value
) {}

/// Identifies one user or operating-system action on a call.
extension type const ActionId(
  /// Stable operating-system action identity used by completeAction.
  String value
) {}

/// Identifies one durable event delivery record.
extension type const EventId(
  /// Stable delivery identity used by acknowledgeEvents.
  String value
) {}

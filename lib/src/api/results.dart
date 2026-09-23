/// Stable categories for expected Jackfield failures.
enum JackfieldErrorCode {
  /// The adapter does not support the requested operation.
  unsupported,

  /// Required system permission was denied.
  permissionDenied,

  /// The operation is not legal in the current call state.
  invalidState,

  /// The action deadline has passed.
  deadlineExceeded,

  /// Durable storage cannot accept more data.
  storageFull,

  /// Callback credentials require renewal.
  authenticationRequired,

  /// A dependency is currently unavailable.
  temporarilyUnavailable,

  /// The platform adapter failed.
  platformFailure,

  /// A wire payload is malformed or has an unsupported version.
  protocolFailure,
}

/// An expected, typed Jackfield error.
final class JackfieldError {
  /// Creates an error with safe diagnostic information.
  const JackfieldError(this.code, {this.message, this.nativeCode});

  /// Stable error category for application logic.
  final JackfieldErrorCode code;

  /// Optional safe diagnostic text.
  final String? message;

  /// Optional native adapter error code.
  final String? nativeCode;
}

/// A typed operation outcome.
sealed class JackfieldResult<T> {
  /// Creates an outcome subtype.
  const JackfieldResult();
}

/// An operation that completed successfully.
final class JackfieldSuccess<T> extends JackfieldResult<T> {
  /// Creates a successful outcome containing [value].
  const JackfieldSuccess(this.value);

  /// The result value.
  final T value;
}

/// An operation that returned an expected error.
final class JackfieldFailure<T> extends JackfieldResult<T> {
  /// Creates a failed outcome containing [error].
  const JackfieldFailure(this.error);

  /// The structured failure.
  final JackfieldError error;
}

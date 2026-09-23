/// Typed application API for system calls, durable events and diagnostics.
///
/// Applications import this library. Adapter authors use
/// `jackfield_platform_interface.dart` for the wire codec and registration.
library;

export 'src/api/capabilities.dart';
export 'src/api/callback_configuration.dart';
export 'src/api/call_models.dart';
export 'src/api/configuration.dart';
export 'src/api/diagnostics.dart';
export 'src/api/events.dart';
export 'src/api/identifiers.dart';
export 'src/api/results.dart';
export 'src/platform/wire_codec.dart' show JackfieldProtocolException;
export 'src/jackfield_facade.dart';

import 'jackfield_platform_interface.dart';

export 'src/api/capabilities.dart';
export 'src/api/call_models.dart';
export 'src/api/events.dart';
export 'src/api/identifiers.dart';
export 'src/api/results.dart';
export 'src/platform/wire_codec.dart';

/// The generated platform-version facade for the Jackfield plugin scaffold.
class Jackfield {
  /// Returns the host platform version reported by the registered adapter.
  Future<String?> getPlatformVersion() {
    return JackfieldPlatform.instance.getPlatformVersion();
  }
}

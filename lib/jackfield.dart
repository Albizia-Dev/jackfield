import 'jackfield_platform_interface.dart';

export 'src/api/capabilities.dart';

/// The generated platform-version facade for the Jackfield plugin scaffold.
class Jackfield {
  /// Returns the host platform version reported by the registered adapter.
  Future<String?> getPlatformVersion() {
    return JackfieldPlatform.instance.getPlatformVersion();
  }
}

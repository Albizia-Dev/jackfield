import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'jackfield_method_channel.dart';

/// Base interface used to register a platform-specific Jackfield adapter.
abstract class JackfieldPlatform extends PlatformInterface {
  /// Constructs a JackfieldPlatform.
  JackfieldPlatform() : super(token: _token);

  static final Object _token = Object();

  static JackfieldPlatform _instance = MethodChannelJackfield();

  /// The default instance of [JackfieldPlatform] to use.
  ///
  /// Defaults to [MethodChannelJackfield].
  static JackfieldPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [JackfieldPlatform] when
  /// they register themselves.
  static set instance(JackfieldPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Returns the platform version, or throws when the adapter omits it.
  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}

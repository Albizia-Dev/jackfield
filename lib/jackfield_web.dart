import 'package:flutter_web_plugins/flutter_web_plugins.dart';

import 'jackfield_platform_interface.dart';
import 'src/api/capabilities.dart';

/// Web registration placeholder until the durable browser adapter is installed.
class JackfieldWeb extends JackfieldPlatform {
  /// Creates an adapter that truthfully advertises no implemented features.
  JackfieldWeb();

  /// Registers the browser adapter with Flutter's plugin registry.
  static void registerWith(Registrar registrar) {
    JackfieldPlatform.instance = JackfieldWeb();
  }

  @override
  Future<JackfieldCapabilities> capabilities() async =>
      JackfieldCapabilities.unavailable(
        platform: 'web',
        reason: 'Browser adapter not implemented',
      );
}

import 'package:flutter_web_plugins/flutter_web_plugins.dart';

import 'jackfield_platform_interface.dart';
import 'src/web/jackfield_web_platform.dart';
import 'src/web/web_bridge.dart';

/// Registers the browser adapter with Flutter's plugin registry.
class JackfieldWeb {
  /// Requests permission and creates a Web Push subscription from a user action.
  ///
  /// Call this directly from a button or other user gesture. Initialization and
  /// [JackfieldPlatform.pushTokens] never prompt for permission.
  static Future<String> subscribePushFromUserGesture(
    String applicationServerKey,
  ) => WebBridge.subscribePush(applicationServerKey);

  /// Registers the browser adapter with Flutter's plugin registry.
  static void registerWith(Registrar registrar) {
    JackfieldPlatform.instance = JackfieldWebPlatform();
  }
}

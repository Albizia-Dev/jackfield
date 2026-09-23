import 'package:flutter_web_plugins/flutter_web_plugins.dart';

import 'jackfield_platform_interface.dart';
import 'src/web/jackfield_web_platform.dart';
import 'src/web/web_bridge.dart';

/// Registers the browser adapter with Flutter's plugin registry.
class JackfieldWeb {
  /// Binds incoming push invitations to the current installation and login session.
  ///
  /// Use server-issued opaque IDs before enabling Web Push, and rotate the session ID
  /// when the signed-in account changes. Invitations for another binding are rejected.
  static Future<void> bindPushIdentity({
    required String installationId,
    required String sessionId,
  }) async {
    if (installationId.isEmpty || sessionId.isEmpty) {
      throw ArgumentError('Push identity must be nonempty');
    }
    final response = await WebBridge.invoke({
      'command': 'bindPush',
      'installationId': installationId,
      'sessionId': sessionId,
    });
    if (response['status'] != 'success') {
      throw StateError('Push identity could not be bound');
    }
  }

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

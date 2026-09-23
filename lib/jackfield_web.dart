// In order to *not* need this ignore, consider extracting the "web" version
// of your plugin as a separate package, instead of inlining it in the same
// package as the core of your plugin.
// ignore: avoid_web_libraries_in_flutter

import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:web/web.dart' as web;

import 'jackfield_platform_interface.dart';

/// A web implementation of the JackfieldPlatform of the Jackfield plugin.
class JackfieldWeb extends JackfieldPlatform {
  /// Constructs a JackfieldWeb
  JackfieldWeb();

  /// Registers the web adapter with Flutter's plugin registry.
  static void registerWith(Registrar registrar) {
    JackfieldPlatform.instance = JackfieldWeb();
  }

  /// Returns a [String] containing the version of the platform.
  @override
  Future<String?> getPlatformVersion() async {
    final version = web.window.navigator.userAgent;
    return version;
  }
}

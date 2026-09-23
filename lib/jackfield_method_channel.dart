import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'jackfield_platform_interface.dart';

/// An implementation of [JackfieldPlatform] that uses method channels.
class MethodChannelJackfield extends JackfieldPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('jackfield');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}

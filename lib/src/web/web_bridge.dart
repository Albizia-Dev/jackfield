import 'dart:convert';
import 'dart:js_interop';

@JS('JackfieldBridge.invoke')
external JSPromise<JSString> _invoke(JSString message);

@JS('JackfieldBridge.claim')
external JSPromise<JSBoolean> _claim();

@JS('JackfieldBridge.available')
external JSPromise<JSBoolean> _available();

@JS('JackfieldBridge.listen')
external void _listen(JSFunction listener);

@JS('JackfieldBridge.permission')
external JSString _permission();

@JS('JackfieldBridge.pushEndpoint')
external JSPromise<JSString> _pushEndpoint();

@JS('JackfieldBridge.subscribePush')
external JSPromise<JSString> _subscribePush(JSString applicationServerKey);

/// Typed boundary to the host-installed browser worker.
abstract final class WebBridge {
  /// Invokes one versioned worker command.
  static Future<Map<String, Object?>> invoke(
    Map<String, Object?> message,
  ) async {
    final result = await _invoke(jsonEncode(message).toJS).toDart;
    return (jsonDecode(result.toDart) as Map).cast<String, Object?>();
  }

  /// Claims or renews the single-tab delivery lease.
  static Future<bool> claim() async => (await _claim().toDart).toDart;

  /// Whether the intended host worker registration is active.
  static Future<bool> available() async => (await _available().toDart).toDart;

  /// Receives worker events in the current owning tab.
  static void listen(void Function(Map<String, Object?>) callback) {
    _listen(
      ((JSString value) {
        callback((jsonDecode(value.toDart) as Map).cast<String, Object?>());
      }).toJS,
    );
  }

  /// Current notification permission, read without prompting.
  static String permission() => _permission().toDart;

  /// Existing Push API endpoint, without requesting subscription or permission.
  static Future<String> pushEndpoint() async =>
      (await _pushEndpoint().toDart).toDart;

  /// Requests browser permission and subscribes to Push API after user action.
  static Future<String> subscribePush(String applicationServerKey) async =>
      (await _subscribePush(applicationServerKey.toJS).toDart).toDart;
}

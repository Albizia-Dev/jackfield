import 'package:flutter/services.dart';

import '../api/call_models.dart';
import '../api/capabilities.dart';
import '../api/configuration.dart';
import '../api/diagnostics.dart';
import '../api/events.dart';
import '../api/identifiers.dart';
import '../api/results.dart';
import 'jackfield_platform.dart';
import 'wire_codec.dart';

/// Channel-backed adapter that validates every request and decoded payload.
///
/// Commands return typed transport/protocol failures. Capability/diagnostic
/// protocol failures throw [JackfieldProtocolException]. Invalid stream messages
/// are stream errors and do not acknowledge events or close the subscription.
class MethodChannelJackfield extends JackfieldPlatform {
  /// Creates the adapter for Jackfield's registered native channels.
  MethodChannelJackfield();
  static const _channel = MethodChannel('jackfield');
  static const _eventsChannel = EventChannel('jackfield/events');
  static const _tokensChannel = EventChannel('jackfield/push_token_updates');

  late final Stream<JackfieldEvent> _events = _eventsChannel
      .receiveBroadcastStream(WireCodec.encodeQuery())
      .map(WireCodec.decodeEvent);
  late final Stream<PushTokenUpdate> _tokens = _tokensChannel
      .receiveBroadcastStream(WireCodec.encodeQuery())
      .map(WireCodec.decodePushTokenUpdate);

  @override
  Future<JackfieldResult<void>> initialize(
    JackfieldConfiguration configuration,
  ) => _invoke(
    'initialize',
    () => WireCodec.encodeConfiguration(configuration),
    WireCodec.decodeVoidResult,
  );

  @override
  Future<JackfieldResult<CallSnapshot>> reportIncomingCall(IncomingCall call) =>
      _invoke(
        'reportIncomingCall',
        () => WireCodec.encodeIncomingCall(call),
        WireCodec.decodeCallResult,
      );

  @override
  Future<JackfieldResult<CallSnapshot>> startOutgoingCall(OutgoingCall call) =>
      _invoke(
        'startOutgoingCall',
        () => WireCodec.encodeOutgoingCall(call),
        WireCodec.decodeCallResult,
      );

  @override
  Future<JackfieldResult<CallSnapshot>> updateCall(CallUpdate update) =>
      _invoke(
        'updateCall',
        () => WireCodec.encodeCallUpdate(update),
        WireCodec.decodeCallResult,
      );

  @override
  Future<JackfieldResult<CallSnapshot>> endCall(CallId id, EndReason reason) =>
      _invoke(
        'endCall',
        () => WireCodec.encodeEndCall(id, reason),
        WireCodec.decodeCallResult,
      );

  @override
  Future<JackfieldResult<void>> completeAction(
    ActionId id,
    ActionResult result,
  ) => _invoke(
    'completeAction',
    () => WireCodec.encodeActionResult(id, result),
    WireCodec.decodeVoidResult,
  );

  @override
  Future<JackfieldResult<void>> acknowledgeEvents(Set<EventId> ids) => _invoke(
    'acknowledgeEvents',
    () => WireCodec.encodeAcknowledgements(ids),
    WireCodec.decodeVoidResult,
  );

  @override
  Future<JackfieldResult<PushTokenSnapshot>> pushTokens() => _invoke(
    'pushTokens',
    () => WireCodec.encodeQuery(),
    WireCodec.decodePushTokensResult,
  );

  @override
  Future<JackfieldCapabilities> capabilities() async {
    try {
      return WireCodec.decodeCapabilities(
        await _channel.invokeMethod<Object?>(
          'capabilities',
          WireCodec.encodeQuery(),
        ),
      );
    } on MissingPluginException {
      return super.capabilities();
    }
  }

  @override
  Future<JackfieldDiagnostics> diagnostics() async {
    try {
      return WireCodec.decodeDiagnostics(
        await _channel.invokeMethod<Object?>(
          'diagnostics',
          WireCodec.encodeQuery(),
        ),
      );
    } on MissingPluginException {
      return super.diagnostics();
    }
  }

  @override
  Stream<JackfieldEvent> get events => _events;

  @override
  Stream<PushTokenUpdate> get pushTokenUpdates => _tokens;

  Future<JackfieldResult<T>> _invoke<T>(
    String method,
    Map<String, Object?> Function() encode,
    JackfieldResult<T> Function(Object?) decode,
  ) async {
    try {
      return decode(await _channel.invokeMethod<Object?>(method, encode()));
    } on JackfieldProtocolException catch (error) {
      return JackfieldFailure(
        JackfieldError(
          JackfieldErrorCode.protocolFailure,
          message: error.message,
        ),
      );
    } on MissingPluginException {
      return const JackfieldFailure(
        JackfieldError(
          JackfieldErrorCode.unsupported,
          message: 'No adapter registered',
        ),
      );
    } on PlatformException {
      // PlatformException details are not part of the validated wire contract.
      return const JackfieldFailure(
        JackfieldError(
          JackfieldErrorCode.platformFailure,
          message: 'Platform operation failed',
        ),
      );
    }
  }
}

import 'dart:async';

import 'package:flutter/foundation.dart';
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
/// Transport failures use [JackfieldTransportException]. A cancellation failure
/// after the last listener leaves is reported to FlutterError in sanitized form.
class MethodChannelJackfield extends JackfieldPlatform {
  /// Creates the adapter for Jackfield's registered native channels.
  MethodChannelJackfield();
  static const _channel = MethodChannel('jackfield');
  static const _eventsChannel = EventChannel('jackfield/events');
  static const _tokensChannel = EventChannel('jackfield/push_token_updates');

  late final Stream<JackfieldEvent> _events = _receiveSafeBroadcastStream(
    _eventsChannel,
    WireCodec.decodeEvent,
  );
  late final Stream<PushTokenUpdate> _tokens = _receiveSafeBroadcastStream(
    _tokensChannel,
    WireCodec.decodePushTokenUpdate,
  );

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
    } on PlatformException {
      throw const JackfieldTransportException.platformFailure();
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
    } on PlatformException {
      throw const JackfieldTransportException.platformFailure();
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

// EventChannel.receiveBroadcastStream reports raw listen/cancel exceptions to
// FlutterError before a stream transformer can sanitize them. Own that boundary
// here while retaining the native EventChannel wire protocol and broadcast life.
Stream<T> _receiveSafeBroadcastStream<T>(
  EventChannel channel,
  T Function(Object?) decode,
) {
  final messenger = channel.binaryMessenger;
  final control = MethodChannel(channel.name, channel.codec, messenger);
  late StreamController<T> controller;

  StreamController<T> createController() {
    late StreamController<T> current;

    void reportTransportFailure(Object error, {required bool cancelling}) {
      final safe = error is MissingPluginException
          ? const JackfieldTransportException.unsupported()
          : const JackfieldTransportException.platformFailure();
      if (!cancelling && current.hasListener && !current.isClosed) {
        current.addError(safe, StackTrace.empty);
      } else {
        // There may be no subscriber left to receive cancellation errors.
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: safe,
            stack: StackTrace.empty,
            library: 'jackfield',
            context: ErrorDescription(
              'while changing a Jackfield stream subscription',
            ),
          ),
        );
      }
    }

    Future<void> changeSubscription(String method) async {
      try {
        await control.invokeMethod<void>(method, WireCodec.encodeQuery());
      } catch (error) {
        reportTransportFailure(error, cancelling: method == 'cancel');
      }
    }

    current = StreamController<T>.broadcast(
      onListen: () {
        try {
          messenger.setMessageHandler(channel.name, (reply) async {
            if (current.isClosed) return null;
            if (reply == null) {
              await current.close();
              return null;
            }
            try {
              current.add(decode(channel.codec.decodeEnvelope(reply)));
            } on PlatformException {
              current.addError(
                const JackfieldTransportException.platformFailure(),
                StackTrace.empty,
              );
            } on JackfieldProtocolException catch (error) {
              current.addError(error, StackTrace.empty);
            } catch (_) {
              current.addError(
                const JackfieldProtocolException('Invalid transport envelope'),
                StackTrace.empty,
              );
            }
            return null;
          });
          unawaited(changeSubscription('listen'));
        } catch (error) {
          reportTransportFailure(error, cancelling: false);
        }
      },
      onCancel: () {
        if (!identical(controller, current)) return;
        try {
          messenger.setMessageHandler(channel.name, null);
          unawaited(changeSubscription('cancel'));
        } catch (error) {
          reportTransportFailure(error, cancelling: true);
        }
      },
    );
    return current;
  }

  controller = createController();
  return _RecoverableBroadcastStream(() {
    if (controller.isClosed) controller = createController();
    return controller.stream;
  });
}

class _RecoverableBroadcastStream<T> extends Stream<T> {
  _RecoverableBroadcastStream(this._current);

  final Stream<T> Function() _current;

  @override
  bool get isBroadcast => true;

  @override
  StreamSubscription<T> listen(
    void Function(T event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _current().listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
}

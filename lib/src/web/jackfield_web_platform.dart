import 'dart:async';

import '../api/call_models.dart';
import '../api/capabilities.dart';
import '../api/configuration.dart';
import '../api/diagnostics.dart';
import '../api/events.dart';
import '../api/identifiers.dart';
import '../api/results.dart';
import '../platform/jackfield_platform.dart';
import '../platform/wire_codec.dart';
import 'web_bridge.dart';

/// Browser adapter backed by a host-installed Service Worker and IndexedDB.
final class JackfieldWebPlatform extends JackfieldPlatform {
  final StreamController<JackfieldEvent> _events = StreamController.broadcast();
  final StreamController<PushTokenUpdate> _tokens =
      StreamController.broadcast();
  bool _listening = false;

  Future<Map<String, Object?>> _command(
    String name, [
    Map<String, Object?> arguments = const {},
  ]) => WebBridge.invoke({'command': name, ...arguments});

  @override
  Future<JackfieldResult<void>> initialize(
    JackfieldConfiguration configuration,
  ) async {
    final wire = WireCodec.encodeConfiguration(configuration);
    try {
      final result = await _command('initialize', {
        'callbacks': wire['callbacks'],
      });
      if (!_listening) {
        _listening = true;
        WebBridge.listen((payload) {
          if (payload['type'] == 'pushToken' &&
              payload['provider'] is String &&
              payload['value'] is String) {
            _tokens.add(
              PushTokenUpdate(
                token: PushToken(
                  provider: payload['provider']! as String,
                  value: payload['value']! as String,
                ),
                removed: payload['removed'] == true,
              ),
            );
            return;
          }
          try {
            _events.add(WireCodec.decodeEvent(payload));
          } catch (error, stack) {
            _events.addError(error, stack);
          }
        });
      }
      await WebBridge.claim();
      return WireCodec.decodeVoidResult(result);
    } catch (_) {
      return const JackfieldFailure(
        JackfieldError(JackfieldErrorCode.platformFailure),
      );
    }
  }

  @override
  Future<JackfieldCapabilities> capabilities() async {
    try {
      final permission = WebBridge.permission();
      if (permission == 'unsupported') {
        return JackfieldCapabilities.unavailable(
          platform: 'web',
          reason: 'Notifications API unavailable',
        );
      }
      if (!await WebBridge.available()) {
        return JackfieldCapabilities.unavailable(
          platform: 'web',
          reason: 'Host worker unavailable',
        );
      }
      return JackfieldCapabilities(
        platform: 'web',
        mechanism: JackfieldMechanism.webNotification,
        features: {
          JackfieldFeature.incoming,
          JackfieldFeature.answer,
          JackfieldFeature.reject,
          JackfieldFeature.end,
          JackfieldFeature.durableEvents,
          JackfieldFeature.httpCallbacks,
          JackfieldFeature.pushTokens,
        },
        reason: permission == 'granted'
            ? null
            : 'Notification permission is $permission',
      );
    } catch (_) {
      return JackfieldCapabilities.unavailable(
        platform: 'web',
        reason: 'Host worker unavailable',
      );
    }
  }

  @override
  Future<JackfieldResult<CallSnapshot>> reportIncomingCall(
    IncomingCall call,
  ) async {
    try {
      return WireCodec.decodeCallResult(
        await _command('reportIncoming', {
          'call': WireCodec.encodeIncomingCall(call),
        }),
      );
    } catch (_) {
      return const JackfieldFailure(
        JackfieldError(JackfieldErrorCode.platformFailure),
      );
    }
  }

  @override
  Future<JackfieldResult<CallSnapshot>> endCall(
    CallId id,
    EndReason reason,
  ) async {
    try {
      final wire = WireCodec.encodeEndCall(id, reason);
      return WireCodec.decodeCallResult(await _command('end', wire));
    } catch (_) {
      return const JackfieldFailure(
        JackfieldError(JackfieldErrorCode.platformFailure),
      );
    }
  }

  @override
  Future<JackfieldResult<void>> completeAction(
    ActionId id,
    ActionResult result,
  ) async {
    try {
      return WireCodec.decodeVoidResult(
        await _command(
          'completeAction',
          WireCodec.encodeActionResult(id, result),
        ),
      );
    } catch (_) {
      return const JackfieldFailure(
        JackfieldError(JackfieldErrorCode.platformFailure),
      );
    }
  }

  @override
  Future<JackfieldResult<void>> acknowledgeEvents(Set<EventId> ids) async {
    try {
      return WireCodec.decodeVoidResult(
        await _command('acknowledge', WireCodec.encodeAcknowledgements(ids)),
      );
    } catch (_) {
      return const JackfieldFailure(
        JackfieldError(JackfieldErrorCode.platformFailure),
      );
    }
  }

  @override
  Future<JackfieldResult<PushTokenSnapshot>> pushTokens() async {
    try {
      final endpoint = await WebBridge.pushEndpoint();
      return JackfieldSuccess(
        PushTokenSnapshot(
          endpoint.isEmpty
              ? const []
              : [PushToken(provider: 'webPush', value: endpoint)],
        ),
      );
    } catch (_) {
      return const JackfieldFailure(
        JackfieldError(JackfieldErrorCode.platformFailure),
      );
    }
  }

  @override
  Stream<PushTokenUpdate> get pushTokenUpdates => _tokens.stream;

  @override
  Future<JackfieldDiagnostics> diagnostics() async {
    final permission = WebBridge.permission();
    Map<String, Object?>? worker;
    try {
      final response = await _command('diagnostics');
      if (response['status'] == 'success') {
        worker = (response['value'] as Map).cast<String, Object?>();
      }
    } catch (_) {
      // Browser permission remains queryable if the worker is unavailable.
    }
    final httpDiagnostic = worker?['httpDiagnostic'];
    return JackfieldDiagnostics(
      mechanism: JackfieldMechanism.webNotification,
      permissions: {
        'notifications': switch (permission) {
          'granted' => JackfieldPermissionState.granted,
          'denied' => JackfieldPermissionState.denied,
          'default' => JackfieldPermissionState.notDetermined,
          _ => JackfieldPermissionState.unknown,
        },
      },
      pendingFlutterEvents: worker?['pendingFlutterEvents'] as int?,
      pendingHttpEvents: worker?['pendingHttpEvents'] as int?,
      httpPausedForAuthentication: worker?['authPaused'] == true,
      lastError: httpDiagnostic is Map
          ? JackfieldError(switch (httpDiagnostic['code']) {
              'queueFull' || 'storageFailure' => JackfieldErrorCode.storageFull,
              'schedulerFailure' => JackfieldErrorCode.temporarilyUnavailable,
              _ => JackfieldErrorCode.platformFailure,
            }, nativeCode: httpDiagnostic['code'] as String?)
          : null,
    );
  }

  @override
  Stream<JackfieldEvent> get events => _events.stream;
}

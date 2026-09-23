import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jackfield/jackfield.dart';
import 'package:jackfield/jackfield_method_channel.dart';

const snapshot = <String, Object?>{
  'callId': 'call-1',
  'state': 'ringing',
  'media': 'audio',
  'caller': {'id': 'peer-1', 'displayName': 'Peer'},
  'actionId': 'action-1',
  'actionDeadline': '2026-01-01T00:01:00.000Z',
  'actionReceipts': [
    {
      'actionId': 'old-action',
      'succeeded': false,
      'error': {'code': 'deadlineExceeded'},
    },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('jackfield');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Jackfield api;
  late List<MethodCall> calls;
  Object? response;

  setUp(() {
    api = Jackfield.withPlatform(MethodChannelJackfield());
    calls = [];
    response = {'version': 1, 'status': 'success', 'value': null};
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return response;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('completion and ACK encode separate identities and methods', () async {
    expect(
      await api.completeAction(
        const ActionId('action-1'),
        const ActionResult.failure(),
      ),
      isA<JackfieldSuccess<void>>(),
    );
    expect(calls.single.method, 'completeAction');
    expect(calls.single.arguments, {
      'version': 1,
      'actionId': 'action-1',
      'succeeded': false,
    });
    await api.acknowledgeEvents({
      const EventId('event-1'),
      const EventId('event-2'),
    });
    expect(calls.last.method, 'acknowledgeEvents');
    expect(calls.last.arguments, {
      'version': 1,
      'eventIds': ['event-1', 'event-2'],
    });
  });

  test(
    'configuration encodes optional callbacks with opaque credentials',
    () async {
      await api.initialize(
        JackfieldConfiguration(
          callbacks: CallbackConfiguration(
            endpoint: Uri.parse('https://example.test/callback'),
            auth: const CallbackAuth.bearer('opaque'),
            timeToLive: const Duration(hours: 2),
            maxPendingEvents: 20,
          ),
        ),
      );
      expect(calls.single.method, 'initialize');
      expect(calls.single.arguments, {
        'version': 1,
        'callbacks': {
          'endpoint': 'https://example.test/callback',
          'auth': {'type': 'bearer', 'token': 'opaque'},
          'timeToLiveMs': 7200000,
          'maxPendingEvents': 20,
        },
      });
    },
  );

  test('invalid outgoing payload never crosses the channel', () async {
    final result = await api.reportIncomingCall(
      const IncomingCall(
        callId: CallId(''),
        caller: Caller(id: 'peer', displayName: 'Peer'),
        media: CallMedia.audio,
      ),
    );
    expect(
      (result as JackfieldFailure<CallSnapshot>).error.code,
      JackfieldErrorCode.protocolFailure,
    );
    expect(calls, isEmpty);
  });

  test(
    'unsafe callbacks are rejected locally without exposing credentials',
    () async {
      final configurations = [
        CallbackConfiguration(
          endpoint: Uri.parse('http://example.test'),
          auth: const CallbackAuth.bearer('secret'),
        ),
        CallbackConfiguration(
          endpoint: Uri.parse('https://user:secret@example.test'),
          auth: const CallbackAuth.bearer('secret'),
        ),
        CallbackConfiguration(
          endpoint: Uri.parse('https://example.test/#fragment'),
          auth: const CallbackAuth.bearer('secret'),
        ),
        CallbackConfiguration(
          endpoint: Uri.parse('https://example.test'),
          auth: const CallbackAuth.bearer('secret\r\nInjected: value'),
        ),
        CallbackConfiguration(
          endpoint: Uri.parse('https://example.test'),
          auth: const CallbackAuth.bearer(' '),
        ),
        CallbackConfiguration(
          endpoint: Uri.parse('https://example.test'),
          auth: const CallbackAuth.bearer('secret'),
          timeToLive: Duration.zero,
        ),
        CallbackConfiguration(
          endpoint: Uri.parse('https://example.test'),
          auth: const CallbackAuth.bearer('secret'),
          maxPendingEvents: 0,
        ),
      ];
      for (final callbacks in configurations) {
        final result =
            await api.initialize(JackfieldConfiguration(callbacks: callbacks))
                as JackfieldFailure<void>;
        expect(result.error.code, JackfieldErrorCode.protocolFailure);
        expect(result.error.message, isNot(contains('secret')));
      }
      expect(calls, isEmpty);
    },
  );

  test(
    'missing adapter reports unavailable health without invented queue counts',
    () async {
      messenger.setMockMethodCallHandler(channel, null);
      final capabilities = await api.capabilities();
      expect(capabilities.mechanism, JackfieldMechanism.unavailable);
      expect(capabilities.features, isEmpty);
      final diagnostics = await api.diagnostics();
      expect(diagnostics.pendingFlutterEvents, isNull);
      expect(diagnostics.pendingHttpEvents, isNull);
      expect(diagnostics.lastError!.code, JackfieldErrorCode.unsupported);
    },
  );

  test('call commands preserve payloads and typed snapshot receipts', () async {
    response = {'version': 1, 'status': 'success', 'value': snapshot};
    const caller = Caller(id: 'peer-1', displayName: 'Peer');
    final incoming = await api.reportIncomingCall(
      const IncomingCall(
        callId: CallId('call-1'),
        caller: caller,
        media: CallMedia.audio,
      ),
    );
    final value = (incoming as JackfieldSuccess<CallSnapshot>).value;
    expect(value.state, CallState.ringing);
    expect(value.caller!.displayName, 'Peer');
    expect(value.actionId, const ActionId('action-1'));
    expect(value.actionDeadline, DateTime.utc(2026, 1, 1, 0, 1));
    expect(
      value.actionReceipts.single.error!.code,
      JackfieldErrorCode.deadlineExceeded,
    );
    expect(calls.last.method, 'reportIncomingCall');
    expect(calls.last.arguments, {
      'version': 1,
      'callId': 'call-1',
      'caller': {'id': 'peer-1', 'displayName': 'Peer'},
      'media': 'audio',
    });
    await api.startOutgoingCall(
      const OutgoingCall(
        callId: CallId('call-1'),
        callee: caller,
        media: CallMedia.video,
      ),
    );
    expect(calls.last.method, 'startOutgoingCall');
    expect(calls.last.arguments, {
      'version': 1,
      'callId': 'call-1',
      'callee': {'id': 'peer-1', 'displayName': 'Peer'},
      'media': 'video',
    });
    await api.updateCall(
      const CallUpdate(callId: CallId('call-1'), media: CallMedia.video),
    );
    expect(calls.last.method, 'updateCall');
    expect(calls.last.arguments, {
      'version': 1,
      'callId': 'call-1',
      'media': 'video',
    });
    await api.endCall(const CallId('call-1'), EndReason.remote);
    expect(calls.last.method, 'endCall');
    expect(calls.last.arguments, {
      'version': 1,
      'callId': 'call-1',
      'reason': 'remote',
    });
  });

  test('typed failures survive the platform boundary', () async {
    response = {
      'version': 1,
      'status': 'failure',
      'error': {
        'code': 'permissionDenied',
        'message': 'Call permission denied',
        'nativeCode': 'denied',
      },
    };
    final result = await api.initialize(const JackfieldConfiguration());
    final error = (result as JackfieldFailure<void>).error;
    expect(error.code, JackfieldErrorCode.permissionDenied);
    expect(error.nativeCode, 'denied');
    expect(error.message, 'Call permission denied');
  });

  test(
    'malformed responses return protocol failure without raw data',
    () async {
      for (final invalid in <Object?>[
        null,
        'secret',
        {'version': 2, 'status': 'success', 'value': null},
        {'version': 1.0, 'status': 'success', 'value': null},
        {'version': 1, 'status': 'success', 'value': 'secret'},
        {
          'version': 1,
          'status': 'failure',
          'error': {'code': 'unknown'},
        },
        {'version': 1, 'status': 'success', 'value': null, 'secret': true},
      ]) {
        response = invalid;
        final result = await api.initialize(const JackfieldConfiguration());
        final error = (result as JackfieldFailure<void>).error;
        expect(error.code, JackfieldErrorCode.protocolFailure);
        expect(error.message, isNot(contains('secret')));
      }
    },
  );

  test(
    'malformed nested snapshot is rejected before application use',
    () async {
      for (final invalid in <Object?>[
        {...snapshot, 'state': 'unknown'},
        {...snapshot, 'callId': ''},
        {...snapshot, 'actionDeadline': 'not-a-date'},
        {
          ...snapshot,
          'actionReceipts': [
            {'actionId': 'a', 'succeeded': 'yes'},
          ],
        },
        {
          ...snapshot,
          'caller': {'id': 'peer', 'displayName': 123},
        },
      ]) {
        response = {'version': 1, 'status': 'success', 'value': invalid};
        final result = await api.endCall(
          const CallId('call-1'),
          EndReason.local,
        );
        expect(
          (result as JackfieldFailure<CallSnapshot>).error.code,
          JackfieldErrorCode.protocolFailure,
        );
      }
    },
  );

  test(
    'missing adapter and native exceptions are structured failures',
    () async {
      messenger.setMockMethodCallHandler(channel, null);
      expect(
        ((await api.initialize(const JackfieldConfiguration()))
                as JackfieldFailure<void>)
            .error
            .code,
        JackfieldErrorCode.unsupported,
      );
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(code: 'native', message: 'secret'),
      );
      final result =
          await api.initialize(const JackfieldConfiguration())
              as JackfieldFailure<void>;
      expect(result.error.code, JackfieldErrorCode.platformFailure);
      expect(result.error.message, isNot(contains('secret')));
    },
  );

  test(
    'capabilities decode the actual mechanism and supported features',
    () async {
      response = {
        'version': 1,
        'platform': 'test',
        'mechanism': 'systemNotification',
        'features': ['incoming', 'durableEvents'],
        'reason': 'limited',
      };
      final capabilities = await api.capabilities();
      expect(capabilities.mechanism, JackfieldMechanism.systemNotification);
      expect(capabilities.features, {
        JackfieldFeature.incoming,
        JackfieldFeature.durableEvents,
      });
      expect(calls.single.method, 'capabilities');
      expect(calls.single.arguments, {'version': 1});
      response = {
        'version': 1,
        'platform': 'test',
        'mechanism': 'unknown',
        'features': <String>[],
      };
      await expectLater(
        api.capabilities(),
        throwsA(isA<JackfieldProtocolException>()),
      );
    },
  );

  test(
    'diagnostics expose queue health permissions and typed last error',
    () async {
      response = {
        'version': 1,
        'mechanism': 'nativeCallUi',
        'permissions': {'calls': 'denied'},
        'pendingFlutterEvents': 2,
        'pendingHttpEvents': 3,
        'httpPausedForAuthentication': true,
        'lastError': {'code': 'authenticationRequired'},
      };
      final diagnostics = await api.diagnostics();
      expect(diagnostics.permissions['calls'], JackfieldPermissionState.denied);
      expect(diagnostics.pendingFlutterEvents, 2);
      expect(diagnostics.pendingHttpEvents, 3);
      expect(diagnostics.httpPausedForAuthentication, isTrue);
      expect(
        diagnostics.lastError!.code,
        JackfieldErrorCode.authenticationRequired,
      );
      expect(calls.single.method, 'diagnostics');
      expect(calls.single.arguments, {'version': 1});
      response = {
        'version': 1,
        'mechanism': 'unavailable',
        'permissions': <String, Object?>{},
        'pendingFlutterEvents': -1,
        'pendingHttpEvents': 0,
        'httpPausedForAuthentication': false,
      };
      await expectLater(
        api.diagnostics(),
        throwsA(isA<JackfieldProtocolException>()),
      );
    },
  );

  test(
    'push token snapshot preserves provider identity and validates tokens',
    () async {
      response = {
        'version': 1,
        'status': 'success',
        'value': {
          'tokens': [
            {'provider': 'apns', 'value': 'opaque'},
          ],
        },
      };
      final result =
          await api.pushTokens() as JackfieldSuccess<PushTokenSnapshot>;
      expect(result.value.tokens.single.provider, 'apns');
      expect(result.value.tokens.single.value, 'opaque');
      expect(calls.single.method, 'pushTokens');
      expect(calls.single.arguments, {'version': 1});
      response = {
        'version': 1,
        'status': 'success',
        'value': {
          'tokens': [
            {'provider': '', 'value': 'secret'},
          ],
        },
      };
      expect(
        ((await api.pushTokens()) as JackfieldFailure<PushTokenSnapshot>)
            .error
            .code,
        JackfieldErrorCode.protocolFailure,
      );
    },
  );

  test(
    'event and token streams validate every emission and survive bad data',
    () async {
      const eventNames = ['jackfield/events', 'jackfield/push_token_updates'];
      final listens = [Completer<void>(), Completer<void>()];
      for (var i = 0; i < eventNames.length; i++) {
        messenger.setMockMethodCallHandler(MethodChannel(eventNames[i]), (
          call,
        ) async {
          if (call.method == 'listen' && !listens[i].isCompleted) {
            listens[i].complete();
          }
          return null;
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(
            MethodChannel(eventNames[i]),
            null,
          ),
        );
      }
      final events = <JackfieldEvent>[];
      final tokens = <PushTokenUpdate>[];
      final errors = <Object>[];
      final eventSubscription = api.events.listen(
        events.add,
        onError: errors.add,
      );
      final tokenSubscription = api.pushTokenUpdates.listen(
        tokens.add,
        onError: errors.add,
      );
      await Future.wait(listens.map((e) => e.future));
      Future<void> emit(String name, Object? payload) async {
        await messenger.handlePlatformMessage(
          name,
          const StandardMethodCodec().encodeSuccessEnvelope(payload),
          (_) {},
        );
        await Future<void>.delayed(Duration.zero);
      }

      await emit(eventNames[0], {'version': 99});
      await emit(eventNames[0], {
        'version': 1,
        'type': 'ended',
        'callId': 'call-1',
        'eventId': 'event-1',
        'sequence': 1,
        'occurredAt': '2026-01-01T00:00:00.000Z',
        'reason': 'remote',
      });
      await emit(eventNames[1], {
        'version': 1,
        'token': {'provider': 'apns', 'value': ''},
        'removed': false,
      });
      await emit(eventNames[1], {
        'version': 1,
        'token': {'provider': 'apns', 'value': 'opaque'},
        'removed': true,
      });
      expect(events.single, isA<CallEnded>());
      expect(tokens.single.removed, isTrue);
      expect(tokens.single.token.value, 'opaque');
      expect(errors, hasLength(2));
      expect(errors, everyElement(isA<JackfieldProtocolException>()));
      await eventSubscription.cancel();
      await tokenSubscription.cancel();
      expect(calls, isEmpty);
    },
  );
}

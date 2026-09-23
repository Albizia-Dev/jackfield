import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jackfield/jackfield.dart';
import 'package:jackfield/jackfield_method_channel.dart';

const secret = 'credential-must-not-escape';

ByteData nativeFailure() {
  final buffer = WriteBuffer()..putUint8(1);
  const codec = StandardMessageCodec();
  codec.writeValue(buffer, secret);
  codec.writeValue(buffer, 'native message $secret');
  codec.writeValue(buffer, {'credentials': secret});
  codec.writeValue(buffer, 'native stack $secret');
  return buffer.done();
}

void expectSanitized(Object error, [StackTrace? stack]) {
  expect(error, isA<JackfieldTransportException>());
  expect(
    (error as JackfieldTransportException).code,
    JackfieldErrorCode.platformFailure,
  );
  expect(error.toString(), isNot(contains(secret)));
  expect(stack.toString(), isNot(contains(secret)));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Jackfield api;
  late List<FlutterErrorDetails> reports;
  FlutterExceptionHandler? originalHandler;
  setUp(() {
    api = Jackfield.withPlatform(MethodChannelJackfield());
    reports = [];
    originalHandler = FlutterError.onError;
    FlutterError.onError = reports.add;
  });
  tearDown(() {
    FlutterError.onError = originalHandler;
    for (final name in [
      'jackfield',
      'jackfield/events',
      'jackfield/push_token_updates',
    ]) {
      messenger.setMockMessageHandler(name, null);
    }
  });

  for (final query in ['capabilities', 'diagnostics']) {
    test(
      '$query sanitizes native transport message details code and stack',
      () async {
        messenger.setMockMessageHandler(
          'jackfield',
          (_) async => nativeFailure(),
        );
        Object? caught;
        StackTrace? caughtStack;
        try {
          if (query == 'capabilities') {
            await api.capabilities();
          } else {
            await api.diagnostics();
          }
        } catch (error, stack) {
          caught = error;
          caughtStack = stack;
        }
        expect(caught, isNotNull);
        expectSanitized(caught!, caughtStack);
        expect(reports, isEmpty);
      },
    );
  }

  for (final name in ['jackfield/events', 'jackfield/push_token_updates']) {
    Stream<Object> stream() =>
        name == 'jackfield/events' ? api.events : api.pushTokenUpdates;
    final payload = name == 'jackfield/events'
        ? <String, Object?>{
            'version': 1,
            'type': 'ended',
            'callId': 'call-1',
            'eventId': 'event-1',
            'sequence': 1,
            'occurredAt': '2026-01-01T00:00:00.000Z',
            'reason': 'remote',
          }
        : <String, Object?>{
            'version': 1,
            'token': {'provider': 'apns', 'value': 'opaque'},
            'removed': false,
          };

    Future<void> send(ByteData? bytes) async {
      await messenger.handlePlatformMessage(name, bytes, (_) {});
      await Future<void>.delayed(Duration.zero);
    }

    test(
      '$name can subscribe again after native error and stream end',
      () async {
        var listens = 0;
        messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
          if (call.method == 'listen') listens++;
          return null;
        });
        final firstErrors = <Object>[];
        final firstDone = Completer<void>();
        stream().listen(
          (_) {},
          onError: firstErrors.add,
          onDone: firstDone.complete,
        );
        await Future<void>.delayed(Duration.zero);
        await send(nativeFailure());
        await send(null);
        await firstDone.future;
        expect(firstErrors, hasLength(1));
        expectSanitized(firstErrors.single);

        final replayed = <Object>[];
        final second = stream().listen(replayed.add);
        addTearDown(second.cancel);
        final secondObserver = <Object>[];
        final observer = stream().listen(secondObserver.add);
        addTearDown(observer.cancel);
        await Future<void>.delayed(Duration.zero);
        expect(listens, 2);
        await send(const StandardMethodCodec().encodeSuccessEnvelope(payload));
        expect(replayed, hasLength(1));
        expect(secondObserver, hasLength(1));
        expect(reports, isEmpty);
      },
    );

    test(
      '$name sanitizes error envelopes and delivers subsequent valid data',
      () async {
        messenger.setMockMethodCallHandler(
          MethodChannel(name),
          (_) async => null,
        );
        final items = <Object>[];
        final errors = <Object>[];
        final stacks = <StackTrace>[];
        final subscription = stream().listen(
          items.add,
          onError: (Object error, StackTrace stack) {
            errors.add(error);
            stacks.add(stack);
          },
        );
        addTearDown(subscription.cancel);
        await Future<void>.delayed(Duration.zero);
        await send(nativeFailure());
        await send(const StandardMethodCodec().encodeSuccessEnvelope(payload));
        expect(errors, hasLength(1));
        expectSanitized(errors.single, stacks.single);
        expect(items, hasLength(1));
        expect(reports, isEmpty);
      },
    );

    test(
      '$name sanitizes listen failure before FlutterError and can recover',
      () async {
        messenger.setMockMessageHandler(name, (bytes) async {
          final call = const StandardMethodCodec().decodeMethodCall(bytes);
          return call.method == 'listen'
              ? nativeFailure()
              : const StandardMethodCodec().encodeSuccessEnvelope(null);
        });
        final items = <Object>[];
        final errors = <Object>[];
        final subscription = stream().listen(items.add, onError: errors.add);
        addTearDown(subscription.cancel);
        await Future<void>.delayed(Duration.zero);
        await send(const StandardMethodCodec().encodeSuccessEnvelope(payload));
        expect(errors, hasLength(1));
        expectSanitized(errors.single);
        expect(items, hasLength(1));
        expect(reports, isEmpty);
      },
    );

    test(
      '$name reports a sanitized cancel failure without a listener',
      () async {
        messenger.setMockMessageHandler(name, (bytes) async {
          final call = const StandardMethodCodec().decodeMethodCall(bytes);
          return call.method == 'cancel'
              ? nativeFailure()
              : const StandardMethodCodec().encodeSuccessEnvelope(null);
        });
        final subscription = stream().listen((_) {});
        await Future<void>.delayed(Duration.zero);
        await subscription.cancel();
        await Future<void>.delayed(Duration.zero);
        expect(reports, hasLength(1));
        expectSanitized(reports.single.exception, reports.single.stack);
        expect(reports.single.toString(), isNot(contains(secret)));
      },
    );
  }
}

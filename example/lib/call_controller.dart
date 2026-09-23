import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:jackfield/jackfield.dart';

/// Application-owned signaling seam used by the manual stand.
abstract interface class DemoSignaling {
  Future<bool> connect(CallId callId);
}

/// Controllable signaling result. It never connects real media or a server.
final class FakeSignaling implements DemoSignaling {
  bool shouldConnect = true;

  @override
  Future<bool> connect(CallId callId) async => shouldConnect;
}

/// Drives only public Jackfield operations for the manual integration stand.
final class CallController extends ChangeNotifier {
  CallController({required this.jackfield, required this.signaling});

  final Jackfield jackfield;
  final DemoSignaling signaling;
  final List<String> eventLog = [];
  String status = 'Ожидание инициализации';
  JackfieldCapabilities? capabilities;
  JackfieldDiagnostics? diagnostics;
  PushTokenSnapshot? tokens;
  CallId? currentCallId;
  StreamSubscription<JackfieldEvent>? _events;
  StreamSubscription<PushTokenUpdate>? _tokenUpdates;

  Future<void> initialize({CallbackConfiguration? callbacks}) async {
    try {
      final result = await jackfield.initialize(
        JackfieldConfiguration(callbacks: callbacks),
      );
      _showResult('Инициализация', result);
      if (result is JackfieldFailure<void>) return;
      _events ??= jackfield.events.listen(
        (event) => unawaited(handle(event)),
        onError: (Object error) => _failure('Поток событий', error),
      );
      _tokenUpdates ??= jackfield.pushTokenUpdates.listen(
        (update) => _record(
          'Токен ${update.token.provider}: ${update.removed ? 'удалён' : 'обновлён'}',
        ),
        onError: (Object error) => _failure('Поток токенов', error),
      );
      await refresh();
    } catch (error) {
      _failure('Инициализация', error);
    }
  }

  Future<void> refresh() async {
    try {
      capabilities = await jackfield.capabilities();
      diagnostics = await jackfield.diagnostics();
      notifyListeners();
    } catch (error) {
      _failure('Диагностика', error);
    }
  }

  Future<void> inspectTokens() async {
    try {
      final result = await jackfield.pushTokens();
      if (result is JackfieldSuccess<PushTokenSnapshot>) {
        tokens = result.value;
        _record('Токены: ${tokens!.tokens.length}');
      } else {
        _showResult('Токены', result);
      }
    } catch (error) {
      _failure('Токены', error);
    }
  }

  Future<void> incoming({required String callId, required String party}) async {
    try {
      final id = CallId(callId.trim());
      final result = await jackfield.reportIncomingCall(
        IncomingCall(
          callId: id,
          caller: Caller(id: party.trim(), displayName: party.trim()),
          media: CallMedia.audio,
        ),
      );
      if (result is JackfieldSuccess<CallSnapshot>) currentCallId = id;
      _showResult('Входящий $callId', result);
    } catch (error) {
      _failure('Входящий', error);
    }
  }

  Future<void> outgoing({required String callId, required String party}) async {
    try {
      final id = CallId(callId.trim());
      final result = await jackfield.startOutgoingCall(
        OutgoingCall(
          callId: id,
          callee: Caller(id: party.trim(), displayName: party.trim()),
          media: CallMedia.audio,
        ),
      );
      if (result is JackfieldSuccess<CallSnapshot>) currentCallId = id;
      _showResult('Исходящий $callId', result);
    } catch (error) {
      _failure('Исходящий', error);
    }
  }

  Future<void> endCurrentCall() async {
    final id = currentCallId;
    if (id == null) {
      _record('Нет выбранного звонка для завершения');
      return;
    }
    try {
      final result = await jackfield.endCall(id, EndReason.local);
      _showResult('Завершение ${id.value}', result);
      if (result is JackfieldSuccess<CallSnapshot>) currentCallId = null;
    } catch (error) {
      _failure('Завершение', error);
    }
  }

  Future<void> handle(JackfieldEvent event) async {
    _record(
      'Событие ${event.eventId.value} #${event.sequence}: ${event.runtimeType}',
    );
    if (event is AnswerRequested) {
      var connected = false;
      try {
        connected = await signaling.connect(event.callId);
        _record(connected ? 'Сигналинг успешен' : 'Сигналинг вернул ошибку');
      } catch (error) {
        _failure('Сигналинг', error);
      }
      try {
        final completion = await jackfield.completeAction(
          event.actionId,
          connected
              ? const ActionResult.success()
              : const ActionResult.failure(),
        );
        _showResult('Завершение действия', completion);
        if (completion is JackfieldFailure<void>) return;
      } catch (error) {
        _failure('Завершение действия', error);
        return;
      }
      final acknowledged = await _ack(event.eventId);
      if (!acknowledged) return;
      _record(
        connected ? 'Ответ успешно обработан' : 'Ответ: ошибка сигналинга',
      );
      return;
    }
    if (event is CallEnded && event.callId == currentCallId) {
      currentCallId = null;
      _record('Звонок завершён: ${event.reason.name}');
    }
    await _ack(event.eventId);
  }

  Future<bool> _ack(EventId id) async {
    try {
      final result = await jackfield.acknowledgeEvents({id});
      if (result is JackfieldFailure<void>) {
        _record('ACK ${id.value}: ошибка ${result.error.code.name}');
        return false;
      } else {
        _record('ACK ${id.value}: успешно', updateStatus: false);
        return true;
      }
    } catch (error) {
      _failure('ACK ${id.value}', error);
      return false;
    }
  }

  void _showResult<T>(String operation, JackfieldResult<T> result) {
    if (result is JackfieldFailure<T>) {
      _record(
        '$operation: ошибка ${result.error.code.name} ${result.error.message ?? ''}'
            .trim(),
      );
    } else {
      _record('$operation: успешно');
    }
  }

  void _failure(String operation, Object error) =>
      _record('$operation: ошибка $error');

  void _record(String message, {bool updateStatus = true}) {
    if (updateStatus) status = message;
    eventLog.insert(0, '${DateTime.now().toIso8601String()} $message');
    if (eventLog.length > 100) eventLog.removeLast();
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    unawaited(_tokenUpdates?.cancel());
    super.dispose();
  }
}

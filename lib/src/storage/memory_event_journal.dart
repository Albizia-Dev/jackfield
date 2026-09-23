import '../api/events.dart';
import '../api/identifiers.dart';
import 'event_journal.dart';

/// In-memory journal for tests; native adapters provide durable storage.
final class MemoryEventJournal implements EventJournal {
  final Map<EventId, _Record> _records = {};
  final Map<CallId, int> _callOrder = {};
  bool _httpPausedForAuthentication = false;

  /// Whether a test adapter should suspend HTTP delivery attempts.
  bool get isHttpPausedForAuthentication => _httpPausedForAuthentication;

  @override
  Future<void> append(JackfieldEvent event) async {
    if (_records.containsKey(event.eventId)) return;
    final callOrder = _callOrder.putIfAbsent(
      event.callId,
      () => _callOrder.length,
    );
    _records[event.eventId] = _Record(
      event,
      callOrder: callOrder,
      insertionOrder: _records.length,
    );
  }

  @override
  Future<List<JackfieldEvent>> pendingFlutter() async =>
      _pending((record) => !record.flutterAcknowledged);

  @override
  Future<List<JackfieldEvent>> pendingHttp() async =>
      _pending((record) => !record.httpAcknowledged);

  @override
  Future<void> acknowledgeFlutter(Set<EventId> ids) async {
    for (final id in ids) {
      final record = _records[id];
      if (record != null) record.flutterAcknowledged = true;
    }
  }

  @override
  Future<void> acknowledgeHttp(Set<EventId> ids) async {
    for (final id in ids) {
      final record = _records[id];
      if (record != null) record.httpAcknowledged = true;
    }
  }

  @override
  Future<void> pauseHttpForAuthentication() async {
    _httpPausedForAuthentication = true;
  }

  List<JackfieldEvent> _pending(bool Function(_Record) include) {
    final records = _records.values.where(include).toList()
      ..sort((a, b) {
        final callComparison = a.callOrder.compareTo(b.callOrder);
        if (callComparison != 0) return callComparison;
        final sequenceComparison = a.event.sequence.compareTo(b.event.sequence);
        if (sequenceComparison != 0) return sequenceComparison;
        return a.insertionOrder.compareTo(b.insertionOrder);
      });
    return [for (final record in records) record.event];
  }
}

final class _Record {
  _Record(this.event, {required this.callOrder, required this.insertionOrder});

  final JackfieldEvent event;
  final int callOrder;
  final int insertionOrder;
  bool flutterAcknowledged = false;
  bool httpAcknowledged = false;
}

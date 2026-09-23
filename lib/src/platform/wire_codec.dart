import '../api/call_models.dart';
import '../api/events.dart';
import '../api/identifiers.dart';

/// A malformed or unsupported platform wire payload.
final class JackfieldProtocolException implements Exception {
  /// Creates a safe protocol failure description.
  const JackfieldProtocolException(this.message);

  /// A description that excludes the rejected payload and its personal data.
  final String message;

  @override
  String toString() => 'JackfieldProtocolException: $message';
}

/// Encodes and decodes canonical Jackfield event envelopes, version 1.
abstract final class WireCodec {
  /// The version understood by this codec.
  static const int version = 1;

  /// Decodes one event, rejecting unknown or malformed payloads safely.
  static JackfieldEvent decodeEvent(Object? payload) {
    if (payload is! Map) {
      throw const JackfieldProtocolException('Expected an event object');
    }
    final data = <String, Object?>{};
    for (final entry in payload.entries) {
      if (entry.key is! String) {
        throw const JackfieldProtocolException('Expected string field names');
      }
      data[entry.key as String] = entry.value;
    }
    if (data['version'] is! int || data['version'] != version) {
      throw const JackfieldProtocolException('Unsupported event version');
    }
    final type = data['type'];
    final requiredKeys = switch (type) {
      'answer_requested' => const {
        'version',
        'type',
        'callId',
        'actionId',
        'eventId',
        'sequence',
        'occurredAt',
        'deadline',
      },
      'ended' => const {
        'version',
        'type',
        'callId',
        'eventId',
        'sequence',
        'occurredAt',
        'reason',
      },
      _ => throw const JackfieldProtocolException('Unknown event type'),
    };
    if (data.keys.toSet().difference(requiredKeys).isNotEmpty ||
        requiredKeys.difference(data.keys.toSet()).isNotEmpty) {
      throw const JackfieldProtocolException('Invalid event fields');
    }
    final callId = CallId(_nonemptyString(data, 'callId'));
    final eventId = EventId(_nonemptyString(data, 'eventId'));
    final sequence = data['sequence'];
    if (sequence is! int || sequence < 0) {
      throw const JackfieldProtocolException('Invalid event sequence');
    }
    final occurredAt = _timestamp(data, 'occurredAt');
    return switch (type) {
      'answer_requested' => AnswerRequested(
        callId: callId,
        eventId: eventId,
        sequence: sequence,
        occurredAt: occurredAt,
        actionId: ActionId(_nonemptyString(data, 'actionId')),
        deadline: _timestamp(data, 'deadline'),
      ),
      'ended' => CallEnded(
        callId: callId,
        eventId: eventId,
        sequence: sequence,
        occurredAt: occurredAt,
        reason: _endReason(data),
      ),
      _ => throw const JackfieldProtocolException('Unknown event type'),
    };
  }

  /// Encodes an event as a version 1 map suitable for JSON or a channel.
  static Map<String, Object?> encodeEvent(JackfieldEvent event) {
    final common = <String, Object?>{
      'version': version,
      'callId': event.callId.value,
      'eventId': event.eventId.value,
      'sequence': event.sequence,
      'occurredAt': event.occurredAt.toUtc().toIso8601String(),
    };
    final encoded = switch (event) {
      AnswerRequested(:final actionId, :final deadline) => {
        ...common,
        'type': 'answer_requested',
        'actionId': actionId.value,
        'deadline': deadline.toUtc().toIso8601String(),
      },
      CallEnded(:final reason) => {
        ...common,
        'type': 'ended',
        'reason': reason.name,
      },
    };
    decodeEvent(encoded);
    return encoded;
  }

  static String _nonemptyString(Map<String, Object?> data, String key) {
    final value = data[key];
    if (value is! String || value.trim().isEmpty) {
      throw JackfieldProtocolException('Invalid $key');
    }
    return value;
  }

  static DateTime _timestamp(Map<String, Object?> data, String key) {
    final value = data[key];
    if (value is! String || !value.endsWith('Z')) {
      throw JackfieldProtocolException('Invalid $key');
    }
    final parsed = DateTime.tryParse(value);
    if (parsed == null || !parsed.isUtc) {
      throw JackfieldProtocolException('Invalid $key');
    }
    return parsed;
  }

  static EndReason _endReason(Map<String, Object?> data) {
    final value = data['reason'];
    for (final reason in EndReason.values) {
      if (reason.name == value) return reason;
    }
    throw const JackfieldProtocolException('Invalid end reason');
  }
}

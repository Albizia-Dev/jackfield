import '../api/call_models.dart';
import '../api/capabilities.dart';
import '../api/configuration.dart';
import '../api/diagnostics.dart';
import '../api/events.dart';
import '../api/identifiers.dart';
import '../api/results.dart';

/// A malformed or unsupported platform wire payload.
final class JackfieldProtocolException implements Exception {
  /// Creates a safe protocol failure description.
  const JackfieldProtocolException(this.message);

  /// A description that excludes the rejected payload and its personal data.
  final String message;

  @override
  String toString() => 'JackfieldProtocolException: $message';
}

/// Validates all Jackfield channel commands, results and event envelopes, v1.
abstract final class WireCodec {
  /// The version understood by this codec.
  static const int version = 1;

  /// Encodes a versioned query or stream attachment with no application data.
  static Map<String, Object?> encodeQuery() => {'version': version};

  /// Encodes initialization, rejecting unsafe callback destinations and bounds.
  static Map<String, Object?> encodeConfiguration(
    JackfieldConfiguration config,
  ) {
    final callbacks = config.callbacks;
    if (callbacks == null) return encodeQuery();
    final endpoint = callbacks.endpoint;
    if (endpoint.scheme != 'https' ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasFragment ||
        callbacks.timeToLive.inMilliseconds <= 0 ||
        callbacks.maxPendingEvents <= 0 ||
        callbacks.auth.token.trim().isEmpty ||
        callbacks.auth.token.contains(RegExp(r'[\r\n]'))) {
      throw const JackfieldProtocolException('Invalid callback configuration');
    }
    return {
      'version': version,
      'callbacks': {
        'endpoint': endpoint.toString(),
        'auth': {'type': 'bearer', 'token': callbacks.auth.token},
        'timeToLiveMs': callbacks.timeToLive.inMilliseconds,
        'maxPendingEvents': callbacks.maxPendingEvents,
      },
    };
  }

  /// Encodes and validates an incoming call before crossing a channel.
  static Map<String, Object?> encodeIncomingCall(IncomingCall call) => {
    'version': version,
    'callId': _validatedId(call.callId.value),
    'caller': _encodeCaller(call.caller),
    'media': call.media.name,
  };

  /// Encodes and validates an outgoing call before crossing a channel.
  static Map<String, Object?> encodeOutgoingCall(OutgoingCall call) => {
    'version': version,
    'callId': _validatedId(call.callId.value),
    'callee': _encodeCaller(call.callee),
    'media': call.media.name,
  };

  /// Encodes a partial update, omitting fields that should remain unchanged.
  static Map<String, Object?> encodeCallUpdate(CallUpdate update) => {
    'version': version,
    'callId': _validatedId(update.callId.value),
    if (update.caller case final caller?) 'caller': _encodeCaller(caller),
    if (update.media case final media?) 'media': media.name,
  };

  /// Encodes explicit call termination.
  static Map<String, Object?> encodeEndCall(CallId id, EndReason reason) => {
    'version': version,
    'callId': _validatedId(id.value),
    'reason': reason.name,
  };

  /// Encodes action completion without any event acknowledgement.
  static Map<String, Object?> encodeActionResult(
    ActionId id,
    ActionResult result,
  ) => {
    'version': version,
    'actionId': _validatedId(id.value),
    'succeeded': result.succeeded,
  };

  /// Encodes Flutter delivery acknowledgements without action completion.
  static Map<String, Object?> encodeAcknowledgements(Set<EventId> ids) => {
    'version': version,
    'eventIds': ids.map((id) => _validatedId(id.value)).toList(),
  };

  /// Decodes a command outcome whose successful value must be null.
  static JackfieldResult<void> decodeVoidResult(Object? payload) =>
      _decodeResult<void>(payload, (value) {
        if (value != null) {
          throw const JackfieldProtocolException('Invalid void result');
        }
      });

  /// Decodes a call command outcome, including durable action receipts.
  static JackfieldResult<CallSnapshot> decodeCallResult(Object? payload) =>
      _decodeResult(payload, _decodeSnapshot);

  /// Decodes a push-token query outcome with opaque provider token values.
  static JackfieldResult<PushTokenSnapshot> decodePushTokensResult(
    Object? payload,
  ) => _decodeResult(payload, (value) {
    final data = _object(value, {'tokens'});
    return PushTokenSnapshot(_list(data['tokens']).map(_decodeToken));
  });

  /// Decodes an explicit capability report, rejecting unknown feature names.
  static JackfieldCapabilities decodeCapabilities(Object? payload) {
    final data = _envelope(
      payload,
      {'platform', 'mechanism', 'features'},
      {'reason'},
    );
    return JackfieldCapabilities(
      platform: _nonemptyString(data, 'platform'),
      mechanism: _enum(data['mechanism'], JackfieldMechanism.values),
      features: Set.unmodifiable(
        _list(data['features']).map((e) => _enum(e, JackfieldFeature.values)),
      ),
      reason: _optionalString(data, 'reason'),
    );
  }

  /// Decodes health without accepting unrecognized fields or negative counts.
  static JackfieldDiagnostics decodeDiagnostics(Object? payload) {
    final data = _envelope(
      payload,
      {
        'mechanism',
        'permissions',
        'pendingFlutterEvents',
        'pendingHttpEvents',
        'httpPausedForAuthentication',
      },
      {'lastError'},
    );
    final permissions = _stringMap(data['permissions']);
    return JackfieldDiagnostics(
      mechanism: _enum(data['mechanism'], JackfieldMechanism.values),
      permissions: permissions.map((name, value) {
        _validatedId(name);
        return MapEntry(name, _enum(value, JackfieldPermissionState.values));
      }),
      pendingFlutterEvents: _nullableCount(data['pendingFlutterEvents']),
      pendingHttpEvents: _nullableCount(data['pendingHttpEvents']),
      httpPausedForAuthentication: _bool(data['httpPausedForAuthentication']),
      lastError: data['lastError'] == null
          ? null
          : _decodeError(data['lastError']),
    );
  }

  /// Decodes a versioned token addition, rotation or removal stream emission.
  static PushTokenUpdate decodePushTokenUpdate(Object? payload) {
    final data = _envelope(payload, {'token', 'removed'});
    return PushTokenUpdate(
      token: _decodeToken(data['token']),
      removed: _bool(data['removed']),
    );
  }

  static JackfieldResult<T> _decodeResult<T>(
    Object? payload,
    T Function(Object?) decode,
  ) {
    final data = _envelope(payload, {'status'}, {'value', 'error'});
    if (data['status'] == 'success' &&
        data.containsKey('value') &&
        !data.containsKey('error')) {
      return JackfieldSuccess(decode(data['value']));
    }
    if (data['status'] == 'failure' &&
        data.containsKey('error') &&
        !data.containsKey('value')) {
      return JackfieldFailure(_decodeError(data['error']));
    }
    throw const JackfieldProtocolException('Invalid result envelope');
  }

  static CallSnapshot _decodeSnapshot(Object? payload) {
    final data = _object(
      payload,
      {'callId', 'state', 'media', 'actionReceipts'},
      {'caller', 'actionId', 'actionDeadline'},
    );
    return CallSnapshot(
      callId: CallId(_nonemptyString(data, 'callId')),
      state: _enum(data['state'], CallState.values),
      media: _enum(data['media'], CallMedia.values),
      caller: data['caller'] == null ? null : _decodeCaller(data['caller']),
      actionId: data['actionId'] == null
          ? null
          : ActionId(_nonemptyString(data, 'actionId')),
      actionDeadline: data['actionDeadline'] == null
          ? null
          : _timestamp(data, 'actionDeadline'),
      actionReceipts: _list(data['actionReceipts']).map((value) {
        final receipt = _object(value, {'actionId', 'succeeded'}, {'error'});
        return CallActionReceipt(
          actionId: ActionId(_nonemptyString(receipt, 'actionId')),
          succeeded: _bool(receipt['succeeded']),
          error: receipt['error'] == null
              ? null
              : _decodeError(receipt['error']),
        );
      }),
    );
  }

  static JackfieldError _decodeError(Object? payload) {
    final data = _object(payload, {'code'}, {'message', 'nativeCode'});
    return JackfieldError(
      _enum(data['code'], JackfieldErrorCode.values),
      message: _optionalString(data, 'message'),
      nativeCode: _optionalString(data, 'nativeCode'),
    );
  }

  static PushToken _decodeToken(Object? payload) {
    final data = _object(payload, {'provider', 'value'});
    return PushToken(
      provider: _nonemptyString(data, 'provider'),
      value: _nonemptyString(data, 'value'),
    );
  }

  static Caller _decodeCaller(Object? payload) {
    final data = _object(payload, {'id', 'displayName'});
    return Caller(
      id: _nonemptyString(data, 'id'),
      displayName: _nonemptyString(data, 'displayName'),
    );
  }

  static Map<String, Object?> _encodeCaller(Caller caller) {
    final data = {'id': caller.id, 'displayName': caller.displayName};
    _decodeCaller(data);
    return data;
  }

  static String _validatedId(String value) =>
      _nonemptyString({'id': value}, 'id');

  static Map<String, Object?> _stringMap(Object? payload) {
    if (payload is! Map) {
      throw const JackfieldProtocolException('Expected an object');
    }
    final result = <String, Object?>{};
    for (final entry in payload.entries) {
      if (entry.key is! String) {
        throw const JackfieldProtocolException('Expected string field names');
      }
      result[entry.key as String] = entry.value;
    }
    return result;
  }

  static Map<String, Object?> _object(
    Object? payload,
    Set<String> required, [
    Set<String> optional = const {},
  ]) {
    final data = _stringMap(payload);
    if (!data.keys.toSet().containsAll(required) ||
        data.keys.any(
          (key) => !required.contains(key) && !optional.contains(key),
        )) {
      throw const JackfieldProtocolException('Invalid object fields');
    }
    return data;
  }

  static Map<String, Object?> _envelope(
    Object? payload,
    Set<String> required, [
    Set<String> optional = const {},
  ]) {
    final data = _object(payload, {'version', ...required}, optional);
    if (data['version'] is! int || data['version'] != version) {
      throw const JackfieldProtocolException('Unsupported wire version');
    }
    return data;
  }

  static List<Object?> _list(Object? value) {
    if (value is! List) {
      throw const JackfieldProtocolException('Expected a list');
    }
    return List<Object?>.from(value);
  }

  static T _enum<T extends Enum>(Object? value, List<T> values) {
    for (final candidate in values) {
      if (candidate.name == value) return candidate;
    }
    throw const JackfieldProtocolException('Invalid enum value');
  }

  static bool _bool(Object? value) {
    if (value is! bool) {
      throw const JackfieldProtocolException('Expected a boolean');
    }
    return value;
  }

  static int? _nullableCount(Object? value) {
    if (value == null) return null;
    if (value is! int || value < 0) {
      throw const JackfieldProtocolException('Invalid queue count');
    }
    return value;
  }

  static String? _optionalString(Map<String, Object?> data, String key) {
    final value = data[key];
    if (value == null) return null;
    if (value is! String) {
      throw const JackfieldProtocolException('Expected a string');
    }
    return value;
  }

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

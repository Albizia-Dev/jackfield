import 'dart:convert';
import 'dart:io';

void main(List<String> arguments) {
  final rootArgument = arguments
      .where((value) => value.startsWith('--root='))
      .firstOrNull;
  final root = rootArgument == null
      ? Directory.current.path
      : rootArgument.substring('--root='.length);
  final errors = <String>[];
  Map<String, Object?> read(String name) {
    final file = File('$root/test/fixtures/$name');
    try {
      return (jsonDecode(file.readAsStringSync()) as Map<String, dynamic>)
          .cast<String, Object?>();
    } catch (error) {
      errors.add('$name: cannot decode canonical JSON: $error');
      return {};
    }
  }

  final answer = read('event_answer_requested_v1.json');
  final ended = read('event_ended_v1.json');
  final callback = read('callback_answer_requested_v1.json');
  const canonicalAnswer = <String, Object?>{
    'version': 1,
    'type': 'answer_requested',
    'callId': 'call-1',
    'actionId': 'action-3',
    'eventId': 'event-7',
    'sequence': 2,
    'occurredAt': '2026-09-23T05:00:00.000Z',
    'deadline': '2026-09-23T05:00:30.000Z',
  };
  const canonicalEnded = <String, Object?>{
    'version': 1,
    'type': 'ended',
    'callId': 'call-1',
    'eventId': 'event-8',
    'sequence': 3,
    'occurredAt': '2026-09-23T05:01:00.000Z',
    'reason': 'remote',
  };
  if (!_sameJson(answer, canonicalAnswer)) {
    errors.add('canonical answer fixture changed without a protocol migration');
  }
  if (!_sameJson(ended, canonicalEnded)) {
    errors.add('canonical ended fixture changed without a protocol migration');
  }
  final nested = callback['event'];
  if (callback['version'] != 1 ||
      nested is! Map ||
      !_sameJson(nested, answer)) {
    errors.add(
      'callback_answer_requested_v1.json: callback event diverges from canonical answer event',
    );
  }
  _validateEvent(answer, 'event_answer_requested_v1.json', errors);
  _validateEvent(ended, 'event_ended_v1.json', errors);
  if (answer['type'] != 'answer_requested' ||
      answer['actionId'] is! String ||
      answer['deadline'] is! String) {
    errors.add('answer fixture must carry action identity and deadline');
  }
  if (ended['type'] != 'ended' ||
      ended['reason'] != 'remote' ||
      ended.containsKey('actionId')) {
    errors.add(
      'ended fixture must carry a remote reason and no action identity',
    );
  }
  if (errors.isNotEmpty) {
    for (final error in errors) {
      stderr.writeln(error);
    }
    exitCode = 1;
  } else {
    stdout.writeln(
      'Canonical call events and callback envelope agree semantically.',
    );
  }
}

void _validateEvent(
  Map<String, Object?> event,
  String name,
  List<String> errors,
) {
  for (final key in <String>['callId', 'eventId', 'type', 'occurredAt']) {
    if (event[key] is! String || (event[key] as String).isEmpty) {
      errors.add('$name: $key must be a nonempty string');
    }
  }
  if (event['version'] != 1 ||
      event['sequence'] is! int ||
      (event['sequence'] is int ? event['sequence'] as int : -1) < 0) {
    errors.add('$name: expected version 1 and nonnegative integer sequence');
  }
  DateTime? parse(String key) {
    final value = event[key];
    if (value is! String || !value.endsWith('Z')) {
      errors.add('$name: $key must be a UTC timestamp');
      return null;
    }
    final date = DateTime.tryParse(value);
    if (date == null || !date.isUtc) {
      errors.add('$name: invalid $key');
    }
    return date;
  }

  final occurredAt = parse('occurredAt');
  if (event['type'] == 'answer_requested') {
    final deadline = parse('deadline');
    if (occurredAt != null &&
        deadline != null &&
        !deadline.isAfter(occurredAt)) {
      errors.add('$name: action deadline must follow occurrence');
    }
  }
}

bool _sameJson(Object? left, Object? right) {
  if (left is Map && right is Map) {
    if (left.length != right.length ||
        !left.keys.toSet().containsAll(right.keys)) {
      return false;
    }
    return left.keys.every((key) => _sameJson(left[key], right[key]));
  }
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!_sameJson(left[index], right[index])) return false;
    }
    return true;
  }
  return left == right && left.runtimeType == right.runtimeType;
}

import 'package:flutter_test/flutter_test.dart';
import 'package:jackfield/jackfield.dart';

void main() {
  test('unavailable capabilities advertise no features', () {
    final value = JackfieldCapabilities.unavailable(
      platform: 'test',
      reason: 'not-registered',
    );
    expect(value.features, isEmpty);
    expect(value.mechanism, JackfieldMechanism.unavailable);
  });
}

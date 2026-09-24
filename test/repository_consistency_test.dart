import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<Directory> isolatedCopy() async {
    final copy = await Directory.systemTemp.createTemp('jackfield-contract-');
    for (final path in <String>[
      'pubspec.yaml',
      'doc/capabilities.md',
      'doc/validation-matrix.md',
      'doc/ci.md',
      'test/fixtures/event_answer_requested_v1.json',
      'test/fixtures/event_ended_v1.json',
      'test/fixtures/callback_answer_requested_v1.json',
    ]) {
      final source = File(path);
      if (!source.existsSync()) continue;
      final target = File('${copy.path}/$path');
      target.parent.createSync(recursive: true);
      source.copySync(target.path);
    }
    final workflows = Directory('.github/workflows');
    if (workflows.existsSync()) {
      for (final source in workflows.listSync().whereType<File>()) {
        final target = File(
          '${copy.path}/.github/workflows/${source.uri.pathSegments.last}',
        );
        target.parent.createSync(recursive: true);
        source.copySync(target.path);
      }
    }
    addTearDown(() => copy.deleteSync(recursive: true));
    return copy;
  }

  Future<ProcessResult> check(String script, Directory root) =>
      Process.run('dart', ['run', 'tool/$script.dart', '--root=${root.path}']);

  test('Android gate generates the ignored Gradle wrapper before tests', () {
    final script = File('tool/verify.sh').readAsStringSync();
    final build = script.indexOf("run 'example debug APK'");
    final unitTests = script.indexOf("run 'Android plugin unit tests'");

    expect(build, isNonNegative);
    expect(unitTests, isNonNegative);
    expect(build, lessThan(unitTests));
  });

  test('CocoaPods source sets include shared EventStore dependencies', () {
    for (final platform in <String>['ios', 'macos']) {
      for (final source in <String>[
        'CallbackQueue.swift',
        'EventStore.swift',
        'HTTPDispatchCoordination.swift',
        'WireEnvelope.swift',
      ]) {
        final file = File('$platform/Classes/$source');
        expect(
          file.existsSync(),
          isTrue,
          reason: '$platform CocoaPods sources are missing $source',
        );
      }
    }
  });

  test('capability checker rejects unsupported platform registration', () async {
    final root = await isolatedCopy();
    final file = File('${root.path}/pubspec.yaml');
    file.writeAsStringSync(
      file.readAsStringSync().replaceFirst(
        '      web:\n',
        '      windows:\n        pluginClass: JackfieldPluginCApi\n      web:\n',
      ),
    );
    final result = await check('check_capability_matrix', root);
    expect(result.exitCode, isNonZero);
    expect('${result.stdout}${result.stderr}', contains('registrations'));
  });

  test('capability checker rejects a supported Windows claim', () async {
    final root = await isolatedCopy();
    final file = File('${root.path}/doc/capabilities.md');
    file.writeAsStringSync(
      file.readAsStringSync().replaceFirst(
        'Windows | Task 11 отложен: только scaffold',
        'Windows | Реализован: nativeCallUi',
      ),
    );
    final result = await check('check_capability_matrix', root);
    expect(
      result.exitCode,
      isNonZero,
      reason: '${result.stdout}${result.stderr}',
    );
    expect('${result.stdout}${result.stderr}', contains('windows'));
  });

  test('capability checker rejects an incomplete Android claim', () async {
    final root = await isolatedCopy();
    final file = File('${root.path}/doc/capabilities.md');
    file.writeAsStringSync(
      file.readAsStringSync().replaceFirst(
        'Android | Реализован:',
        'Android | Не реализован:',
      ),
    );
    final result = await check('check_capability_matrix', root);
    expect(
      result.exitCode,
      isNonZero,
      reason: '${result.stdout}${result.stderr}',
    );
    expect('${result.stdout}${result.stderr}', contains('android'));
  });

  test('fixture checker rejects a divergent callback event', () async {
    final root = await isolatedCopy();
    final file = File(
      '${root.path}/test/fixtures/callback_answer_requested_v1.json',
    );
    file.writeAsStringSync(
      file.readAsStringSync().replaceFirst('"sequence": 2', '"sequence": 999'),
    );
    final result = await check('check_fixtures', root);
    expect(
      result.exitCode,
      isNonZero,
      reason: '${result.stdout}${result.stderr}',
    );
    expect('${result.stdout}${result.stderr}', contains('callback'));
  });

  test(
    'fixture checker rejects jointly changed canonical identities',
    () async {
      final root = await isolatedCopy();
      for (final name in <String>[
        'event_answer_requested_v1.json',
        'callback_answer_requested_v1.json',
      ]) {
        final file = File('${root.path}/test/fixtures/$name');
        file.writeAsStringSync(
          file.readAsStringSync().replaceFirst(
            '"eventId": "event-7"',
            '"eventId": "mutated-event"',
          ),
        );
      }
      final result = await check('check_fixtures', root);
      expect(
        result.exitCode,
        isNonZero,
        reason: '${result.stdout}${result.stderr}',
      );
      expect('${result.stdout}${result.stderr}', contains('canonical'));
    },
  );

  test('capability checker rejects workflow command drift', () async {
    final root = await isolatedCopy();
    final file = File('${root.path}/.github/workflows/dart.yml');
    expect(file.existsSync(), isTrue);
    file.writeAsStringSync(
      file.readAsStringSync().replaceFirst(
        'tool/verify.sh dart',
        'tool/verify.sh fake',
      ),
    );
    final result = await check('check_capability_matrix', root);
    expect(
      result.exitCode,
      isNonZero,
      reason: '${result.stdout}${result.stderr}',
    );
    expect('${result.stdout}${result.stderr}', contains('dart'));
  });
}

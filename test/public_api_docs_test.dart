import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every exported public API element has nonblank DartDoc', () async {
    final result = await Process.run('dart', [
      'run',
      'tool/check_public_api_docs.dart',
      '--machine',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final report = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(report['undocumented'], isEmpty);
  });

  test('checker resolves re-exports and nested public members', () async {
    final sandbox = await Directory.systemTemp.createTemp(
      'jackfield-doc-gate-',
    );
    try {
      final lib = await Directory('${sandbox.path}/lib').create();
      await File(
        '${lib.path}/public.dart',
      ).writeAsString("export 'hidden.dart' show Sample, Choice;\n");
      await File('${lib.path}/hidden.dart').writeAsString('''
/// Documented type.
class Sample {
  Sample();
  String get title => 'example';
}

/// Documented enum.
enum Choice { first }
''');
      final result = await Process.run('dart', [
        'run',
        'tool/check_public_api_docs.dart',
        '--machine',
        '--root=${sandbox.path}',
      ]);
      expect(result.exitCode, 1, reason: '${result.stdout}\n${result.stderr}');
      final report =
          jsonDecode(result.stdout as String) as Map<String, dynamic>;
      final missing = (report['undocumented'] as List<dynamic>).cast<String>();
      expect(missing, contains('public.dart:Sample.Sample'));
      expect(missing, contains('public.dart:Sample.title'));
      expect(missing, contains('public.dart:Choice.first'));
    } finally {
      await sandbox.delete(recursive: true);
    }
  });
}

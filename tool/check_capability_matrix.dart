import 'dart:io';

const _platforms = <String>{
  'android',
  'ios',
  'macos',
  'windows',
  'linux',
  'web',
};
const _implemented = <String>{'android', 'ios', 'macos', 'web'};
const _workflowStages = <String, String>{
  'dart': 'dart',
  'android': 'android',
  'apple': 'apple',
  'web': 'web',
  'go-example': 'go',
  'windows': 'windows-scaffold',
  'linux': 'linux-scaffold',
  'secrets': 'secrets',
};

void main(List<String> arguments) {
  final rootArgument = arguments
      .where((value) => value.startsWith('--root='))
      .firstOrNull;
  final root = rootArgument == null
      ? Directory.current.path
      : rootArgument.substring('--root='.length);
  final errors = <String>[];
  String read(String path) {
    final file = File('$root/$path');
    if (!file.existsSync()) {
      errors.add('missing $path');
      return '';
    }
    return file.readAsStringSync();
  }

  final pubspec = read('pubspec.yaml');
  final platformBlock =
      RegExp(
        r'^    platforms:\s*\n((?:      .*\n|        .*\n)+)',
        multiLine: true,
      ).firstMatch(pubspec)?.group(1) ??
      '';
  final registrations = RegExp(
    r'^      ([a-z]+):\s*$',
    multiLine: true,
  ).allMatches(platformBlock).map((match) => match.group(1)!).toSet();
  if (registrations.length != _platforms.length ||
      !registrations.containsAll(_platforms)) {
    errors.add(
      'pubspec platform registrations differ from ${_platforms.join(', ')}: $registrations',
    );
  }

  for (final path in <String>[
    'docs/capabilities.md',
    'docs/validation-matrix.md',
  ]) {
    final contents = read(path);
    for (final platform in _platforms) {
      final rows = contents
          .split('\n')
          .where(
            (line) => RegExp(
              '^\\| $platform \\|',
              caseSensitive: false,
            ).hasMatch(line),
          )
          .toList();
      if (rows.length != 1) {
        errors.add(
          '$path: $platform must have exactly one row, found ${rows.length}',
        );
        continue;
      }
      final row = rows.single.split('|')[2].trim().toLowerCase();
      final supported = _implemented.contains(platform);
      if (supported &&
          (!row.contains('реализован') || row.contains('не реализован'))) {
        errors.add('$path: $platform must be marked implemented');
      }
      if (!supported &&
          !(row.contains('не реализован') || row.contains('отложен'))) {
        errors.add('$path: $platform must be marked incomplete');
      }
      if (!supported &&
          row.contains('реализован') &&
          !row.contains('не реализован')) {
        errors.add('$path: $platform cannot claim implemented');
      }
    }
  }

  final ci = read('docs/ci.md');
  for (final entry in _workflowStages.entries) {
    final path = '.github/workflows/${entry.key}.yml';
    final workflow = read(path);
    final command = 'tool/verify.sh ${entry.value}';
    if (!RegExp(
      '^\\s*-?\\s*run: $command\\s*\$',
      multiLine: true,
    ).hasMatch(workflow)) {
      errors.add('$path: missing executable command $command');
    }
    if (!ci.contains('| `${entry.key}.yml` | `$command` |')) {
      errors.add('docs/ci.md: ${entry.key}.yml must document $command');
    }
    if (!workflow.contains('contents: read')) {
      errors.add('$path: requires read-only contents permission');
    }
    if (workflow.contains('secrets.') ||
        workflow.contains('pull_request_target:')) {
      errors.add(
        '$path: required CI cannot consume provider secrets or pull_request_target',
      );
    }
  }
  if (errors.isNotEmpty) {
    for (final error in errors) {
      stderr.writeln(error);
    }
    exitCode = 1;
  } else {
    stdout.writeln(
      'Capability rows, registrations, workflow commands and CI docs agree.',
    );
  }
}

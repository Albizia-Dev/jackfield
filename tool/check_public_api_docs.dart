import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/element/element.dart';

/// Checks declarations visible from every public `lib/*.dart` entrypoint.
///
/// The analyzer resolves export combinators and re-exports. Only declarations
/// written by this package are checked; inherited and synthetic members are
/// deliberately excluded because they cannot carry local DartDoc.
Future<void> main(List<String> arguments) async {
  final machine = arguments.contains('--machine');
  final rootOption = arguments
      .where((arg) => arg.startsWith('--root='))
      .firstOrNull;
  final root = rootOption == null
      ? Directory.current.absolute.path
      : Directory(rootOption.substring('--root='.length)).absolute.path;
  final libraryFiles =
      Directory('$root/lib')
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final collection = AnalysisContextCollection(includedPaths: ['$root/lib']);
  final missing = <String>{};
  var checked = 0;
  try {
    for (final file in libraryFiles) {
      final result = await collection
          .contextFor(file.path)
          .currentSession
          .getLibraryByUri(file.uri.toString());
      if (result is! LibraryElementResult) {
        throw StateError('Cannot resolve ${file.path}: $result');
      }
      final namespace = result.element.exportNamespace.definedNames2;
      for (final entry in namespace.entries) {
        if (entry.key.startsWith('_')) continue;
        final element = _declaredElement(entry.value);
        if (!_belongsToPackage(element, root)) continue;
        checked += _check(
          element,
          missing,
          '${file.uri.pathSegments.last}:${entry.key}',
        );
      }
    }
  } finally {
    await collection.dispose();
  }
  final sorted = missing.toList()..sort();
  if (machine) {
    stdout.writeln(jsonEncode({'checked': checked, 'undocumented': sorted}));
  } else {
    stdout.writeln('Checked $checked public declarations and members.');
    for (final item in sorted) {
      stdout.writeln('Missing DartDoc: $item');
    }
  }
  if (sorted.isNotEmpty) exitCode = 1;
}

Element _declaredElement(Element element) {
  if (element is PropertyAccessorElement && element.isSynthetic) {
    return element.variable;
  }
  return element.baseElement;
}

bool _belongsToPackage(Element element, String root) {
  final sourcePath = element.firstFragment.libraryFragment?.source.fullName;
  return sourcePath != null && sourcePath.startsWith('$root/lib/');
}

int _check(Element element, Set<String> missing, String label) {
  if (element.isPrivate || element.isSynthetic || !_isDocumentable(element)) {
    return 0;
  }
  var count = 1;
  if (!_hasSubstantiveDoc(element.documentationComment)) missing.add(label);
  if (element is InstanceElement) {
    for (final child in element.children) {
      // The extension-type representation syntax creates these two elements;
      // Dart has no separate declaration site to attach their DartDoc to.
      if (element is ExtensionTypeElement &&
          (identical(child, element.primaryConstructor) ||
              identical(child, element.representation))) {
        continue;
      }
      if (child.isPrivate || child.isSynthetic || !_isDocumentable(child)) {
        continue;
      }
      count += _check(child, missing, '$label.${child.displayName}');
    }
  }
  return count;
}

bool _isDocumentable(Element element) =>
    element is ClassElement ||
    element is EnumElement ||
    element is MixinElement ||
    element is ExtensionElement ||
    element is ExtensionTypeElement ||
    element is TypeAliasElement ||
    element is TopLevelFunctionElement ||
    element is TopLevelVariableElement ||
    element is ConstructorElement ||
    element is FieldElement ||
    element is MethodElement ||
    element is GetterElement ||
    element is SetterElement;

bool _hasSubstantiveDoc(String? comment) {
  if (comment == null) return false;
  final body = comment
      .replaceAll(RegExp(r'///|/\*\*|\*/|^\s*\*', multiLine: true), '')
      .trim();
  return body.isNotEmpty;
}

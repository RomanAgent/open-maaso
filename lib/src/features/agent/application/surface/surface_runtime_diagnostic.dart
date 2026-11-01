import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:html/parser.dart' as html_parser;

/// Closed facts from the authenticated host error observer. Never includes
/// exception prose, stack traces, URLs, or model-authored file identities.
class SurfaceRuntimeDiagnostic {
  const SurfaceRuntimeDiagnostic({
    required this.category,
    required this.sourceHash,
    required this.line,
    required this.column,
  });

  static const categories = <String>{
    'reference_error',
    'type_error',
    'syntax_error',
    'range_error',
    'runtime_error',
  };
  final String category;
  final String sourceHash;
  final int line;
  final int column;

  Map<String, Object?> toJson() => {
    'category': category,
    'sourceHash': sourceHash,
    'line': line,
    'column': column,
  };

  static String hashSource(String source) =>
      sha256.convert(utf8.encode(source)).toString();

  static SurfaceRuntimeDiagnostic? tryParse(Object? value) {
    const keys = {'category', 'sourceHash', 'line', 'column'};
    if (value is! Map<String, dynamic> ||
        value.length != keys.length ||
        !value.keys.every(keys.contains) ||
        !categories.contains(value['category']) ||
        value['sourceHash'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['sourceHash'] as String) ||
        value['line'] is! int ||
        value['column'] is! int) {
      return null;
    }
    final line = value['line'] as int;
    final column = value['column'] as int;
    if (line < 1 ||
        column < 1 ||
        line > 8 * 1024 * 1024 ||
        column > 8 * 1024 * 1024) {
      return null;
    }
    return SurfaceRuntimeDiagnostic(
      category: value['category'] as String,
      sourceHash: value['sourceHash'] as String,
      line: line,
      column: column,
    );
  }

  /// Local scripts mounted as data resources belong to the saved HTML. No
  /// remote content is fetched or trusted as an owned source location.
  static Map<String, String> mountedScriptSources(String html) {
    final result = <String, String>{};
    for (final script
        in html_parser.parse(html).querySelectorAll('script[src]')) {
      final url = script.attributes['src']!;
      if (!url.startsWith('data:')) continue;
      try {
        final source = Uri.parse(url).data!.contentAsString(encoding: utf8);
        if (source.length <= 8 * 1024 * 1024) result[url] = source;
      } on FormatException {
        /* Browser reports invalid resources itself. */
      }
    }
    return result;
  }

  bool matchesProjectSource({required String html, required String js}) =>
      sourceOffset(js) != null ||
      mountedScriptSources(
        html,
      ).values.any((source) => sourceOffset(source) != null);

  /// Engine positions use normalized line endings and UTF-16 columns. Source
  /// is mounted exactly, so closing-script text no longer changes positions.
  int? sourceOffset(String source) {
    if (hashSource(source) != sourceHash) return null;
    var currentLine = 1;
    var start = 0;
    for (var index = 0; index <= source.length; index++) {
      final end = index == source.length;
      final newline =
          !end &&
          (source.codeUnitAt(index) == 10 || source.codeUnitAt(index) == 13);
      if (!end && !newline) continue;
      if (currentLine == line) {
        final offset = start + column - 1;
        return offset <= index ? offset : null;
      }
      if (newline &&
          source.codeUnitAt(index) == 13 &&
          index + 1 < source.length &&
          source.codeUnitAt(index + 1) == 10) {
        index++;
      }
      start = index + 1;
      currentLine++;
    }
    return null;
  }
}

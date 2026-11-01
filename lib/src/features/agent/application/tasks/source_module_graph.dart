import 'dart:convert';

import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';

import 'source_workspace.dart';

/// Links only quoted owned module references. Persisted authored sources are
/// never changed; the browser executes the derived graph using its own module
/// parser and cache, including live bindings and cyclic imports.
class SourceModuleGraph {
  SourceModuleGraph(
    this.files, {
    required this.namespace,
    this.authoredImportMap = const {},
  });

  final Map<String, SourceFileSnapshot> files;
  final String namespace;
  final Map<String, dynamic> authoredImportMap;
  static final _documentBase = Uri.parse('https://maaso-module.invalid/files/');
  final Set<String> moduleIds = {};
  final Map<String, String> _compiled = {};

  String alias(String id) => '$namespace/$id';

  String? ownedId(String specifier, String owner) {
    final uri = Uri.tryParse(specifier);
    if (uri == null ||
        ((uri.hasScheme || uri.hasAuthority) &&
            (uri.scheme != _documentBase.scheme ||
                uri.host != _documentBase.host)) ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }
    final resolved = _documentBase.resolve(owner).resolveUri(uri);
    if (!resolved.path.startsWith('/files/')) return null;
    final id = resolved.path.substring('/files/'.length);
    final file = files[id];
    return file != null && file.complete && file.plan.kind == SourceFileKind.js
        ? id
        : null;
  }

  // Resolve authored imports/scopes before moving an owned module to a data
  // URL. Its original file context must still select the same vendor mapping.
  ({bool matched, String? value}) _mapped(String specifier, String owner) {
    bool urlLike(String value) =>
        value.startsWith('/') ||
        value.startsWith('./') ||
        value.startsWith('../') ||
        (Uri.tryParse(value)?.hasScheme ?? false);
    final ownerUrl = _documentBase.resolve(owner);
    final normalized = urlLike(specifier)
        ? ownerUrl.resolve(specifier).toString()
        : specifier;
    ({bool matched, String? value}) match(Object? raw) {
      if (raw is! Map) return (matched: false, value: null);
      String? selectedKey;
      Object? selectedValue;
      var selectedLength = -1;
      for (final entry in raw.entries) {
        if (entry.key is! String) continue;
        final key = entry.key as String;
        final normalizedKey = urlLike(key)
            ? _documentBase.resolve(key).toString()
            : key;
        if ((normalized == normalizedKey ||
                normalizedKey.endsWith('/') &&
                    normalized.startsWith(normalizedKey)) &&
            normalizedKey.length > selectedLength) {
          selectedKey = normalizedKey;
          selectedValue = entry.value;
          selectedLength = normalizedKey.length;
        }
      }
      if (selectedKey == null) return (matched: false, value: null);
      if (selectedValue is! String || !urlLike(selectedValue)) {
        return (matched: true, value: null);
      }
      final target = _documentBase.resolve(selectedValue).toString();
      if (normalized == selectedKey) return (matched: true, value: target);
      if (!target.endsWith('/')) return (matched: true, value: null);
      final expanded = Uri.parse(
        target,
      ).resolve(normalized.substring(selectedKey.length)).toString();
      return (
        matched: true,
        value: expanded.startsWith(target) ? expanded : null,
      );
    }

    final scopes = authoredImportMap['scopes'];
    if (scopes is Map) {
      final applicable =
          scopes.entries.where((entry) {
            if (entry.key is! String) return false;
            final scope = _documentBase.resolve(entry.key as String).toString();
            return scope == ownerUrl.toString() ||
                scope.endsWith('/') && ownerUrl.toString().startsWith(scope);
          }).toList()..sort(
            (a, b) => _documentBase
                .resolve(b.key as String)
                .toString()
                .length
                .compareTo(
                  _documentBase.resolve(a.key as String).toString().length,
                ),
          );
      for (final scope in applicable) {
        final result = match(scope.value);
        if (result.matched) return result;
      }
    }
    return match(authoredImportMap['imports']);
  }

  void include(String id) {
    if (!moduleIds.add(id)) return;
    _compiled[id] = rewrite(files[id]!.source, owner: id);
  }

  String rewrite(String source, {required String owner}) {
    final references = SurfaceJavaScriptModuleReferences.read(source);
    if (references == null) return source;
    final edits = <({int start, int end, String value})>[];
    for (final reference in references) {
      final mapping = _mapped(reference.specifier, owner);
      if (mapping.matched && mapping.value == null) continue;
      final specifier = mapping.value ?? reference.specifier;
      final id = ownedId(specifier, owner);
      if (id != null) include(id);
      final replacement = id == null ? mapping.value : alias(id);
      if (replacement == null || replacement == reference.specifier) continue;
      edits.add((
        start: reference.start,
        end: reference.end,
        value: jsonEncode(replacement),
      ));
    }
    // Right-to-left application retains every untouched UTF-16 source unit,
    // including comments, raw literals, regular expressions and line endings.
    edits.sort((a, b) => b.start.compareTo(a.start));
    var result = source;
    for (final edit in edits) {
      result = result.replaceRange(edit.start, edit.end, edit.value);
    }
    return result;
  }

  String resourceUrl(String id) {
    include(id);
    return 'data:text/javascript;charset=utf-8;base64,${base64Encode(utf8.encode(_compiled[id]!))}';
  }

  Map<String, String> get imports => {
    for (final id in moduleIds) alias(id): resourceUrl(id),
  };
}

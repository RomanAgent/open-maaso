import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'source_workspace.dart';
import 'source_module_graph.dart';

/// Assembles owned files without changing persisted drafts. Ordinary classic
/// files retain the shared-script path. HTML with external/module mounts keeps
/// its authored order; referenced owned files become data resources, avoiding
/// missing virtual URLs and duplicate execution alongside third-party libraries.
class SourceWorkspaceAssembly {
  const SourceWorkspaceAssembly._(
    this.html,
    this.css,
    this.js,
    this.inlineJavaScriptOwners,
    this.inlineStyleOwners,
    this.javaScriptFileIds,
  );

  final String html, css, js;

  /// Declared JS files remaining in the aggregate source, in exact order.
  final List<String> javaScriptFileIds;

  /// Owned HTML files whose classic inline code joins [js]. This is assembly
  /// metadata for source repair, never an additional project/protocol field.
  final List<String> inlineJavaScriptOwners;

  /// Owned HTML files whose inline style blocks join [css].
  final List<String> inlineStyleOwners;

  factory SourceWorkspaceAssembly.fromWorkspace(SourceWorkspaceSnapshot value) {
    final order = value.blueprint!.orderedFiles();
    final files = {for (final file in value.files) file.plan.id: file};
    final kinds = {for (final plan in order) plan.id: plan.kind};
    final positions = <SourceFileKind, Map<String, int>>{
      for (final kind in [SourceFileKind.css, SourceFileKind.js])
        kind: {
          for (final (index, plan)
              in order.where((plan) => plan.kind == kind).indexed)
            plan.id: index,
        },
    };
    final inlineKinds = <SourceFileKind>{};
    final deferredKinds = <SourceFileKind>{};
    final htmlPlans = order
        .where((p) => p.kind == SourceFileKind.html)
        .toList();
    final mounted = <String>{};
    final resourceDocuments = <String, String>{};
    for (final plan in htmlPlans) {
      final resourceDocument = _resourceDocument(
        files[plan.id]!.source,
        files,
        ownerId: plan.id,
      );
      if (resourceDocument != null) {
        resourceDocuments[plan.id] = resourceDocument.html;
        mounted.addAll(resourceDocument.mounted);
      }
    }
    ({String html, List<String> css, List<String> js}) assemble(
      SourceFilePlan plan,
    ) {
      if (resourceDocuments.containsKey(plan.id)) {
        return (
          html: resourceDocuments[plan.id]!,
          css: <String>[],
          js: <String>[],
        );
      }
      final source = files[plan.id]!.source;
      final normalized = _normalizeDocument(
        source,
        files,
        kinds,
        positions,
        inlineKinds,
        deferredKinds,
      );
      if (normalized.html == source &&
          files.values.every((file) => file.complete)) {
        final resourceDocument = _resourceDocument(
          source,
          files,
          ownerId: plan.id,
          force: true,
        );
        if (resourceDocument != null && resourceDocument.mounted.isNotEmpty) {
          mounted.addAll(resourceDocument.mounted);
          return (html: resourceDocument.html, css: <String>[], js: <String>[]);
        }
      }
      return normalized;
    }

    final documents = [for (final plan in htmlPlans) assemble(plan)];
    String concatenate(SourceFileKind kind) => [
      ...order
          .where((plan) => plan.kind == kind && !mounted.contains(plan.id))
          .map((plan) => files[plan.id]!.source),
      for (final document in documents)
        ...(kind == SourceFileKind.js ? document.js : document.css),
    ].join(kind == SourceFileKind.js ? '\n;\n' : '\n');
    return SourceWorkspaceAssembly._(
      documents.map((document) => document.html).join('\n'),
      concatenate(SourceFileKind.css),
      concatenate(SourceFileKind.js),
      List<String>.unmodifiable([
        for (final (index, document) in documents.indexed)
          if (document.js.any((source) => source.isNotEmpty))
            htmlPlans[index].id,
      ]),
      List<String>.unmodifiable([
        for (final (index, document) in documents.indexed)
          if (document.css.any((source) => source.isNotEmpty))
            htmlPlans[index].id,
      ]),
      List<String>.unmodifiable(
        order
            .where(
              (plan) =>
                  plan.kind == SourceFileKind.js && !mounted.contains(plan.id),
            )
            .map((plan) => plan.id),
      ),
    );
  }

  static ({String html, Set<String> mounted})? _resourceDocument(
    String source,
    Map<String, SourceFileSnapshot> files, {
    required String ownerId,
    bool force = false,
  }) {
    final full = RegExp(
      r'<(?:!doctype\s+html|html)(?:\s|>)',
      caseSensitive: false,
    ).hasMatch(source);
    final dom.Node document = full
        ? html_parser.parse(source)
        : html_parser.parseFragment(source);
    final elements = document is dom.Document
        ? document.querySelectorAll('script,link')
        : (document as dom.DocumentFragment).querySelectorAll('script,link');
    bool external(String? value) {
      if (value == null) return false;
      final uri = Uri.tryParse(value);
      return uri != null && (uri.hasScheme || uri.hasAuthority);
    }

    if (!force &&
        !source.contains('@import') &&
        !elements.any(
          (element) =>
              element.attributes['type']?.toLowerCase() == 'module' ||
              element.attributes['type']?.toLowerCase() == 'importmap' ||
              external(element.attributes['src']) ||
              external(element.attributes['href']),
        )) {
      return null;
    }
    dom.Element? authoredMap;
    Map<String, dynamic>? map;
    for (final element in elements) {
      if (element.localName != 'script' ||
          element.attributes['type']?.trim().toLowerCase() != 'importmap') {
        continue;
      }
      try {
        final value = jsonDecode(element.text);
        if (value is Map<String, dynamic> &&
            (value['imports'] == null || value['imports'] is Map)) {
          authoredMap = element;
          map = value;
          break;
        }
      } on FormatException {
        // Invalid authored maps stay intact for the browser to diagnose.
      }
    }
    final graph = SourceModuleGraph(
      files,
      authoredImportMap: map ?? const {},
      namespace:
          'maaso-owned-${sourceWorkspaceDigest(jsonEncode([
            for (final file in files.values) [file.plan.id, file.source],
          ])).substring(0, 24)}',
    );
    for (final element in elements) {
      if (element.localName != 'script' ||
          element.attributes['type']?.trim().toLowerCase() != 'module') {
        continue;
      }
      final reference = element.attributes['src'];
      if (reference != null) {
        final id = graph.ownedId(reference, ownerId);
        if (id != null) graph.include(id);
      } else {
        final rewritten = graph.rewrite(element.text, owner: ownerId);
        if (rewritten != element.text) element.text = rewritten;
      }
    }
    final mounted = <String>{};
    final explicitIds = elements
        .map(
          (element) => element.attributes['src'] ?? element.attributes['href'],
        )
        .whereType<String>()
        .map((value) => value.startsWith('./') ? value.substring(2) : value)
        .toSet();
    String resourceUrl(SourceFileSnapshot file) =>
        graph.moduleIds.contains(file.plan.id)
        ? graph.resourceUrl(file.plan.id)
        : 'data:${file.plan.kind == SourceFileKind.js ? 'text/javascript' : 'text/css'};charset=utf-8;base64,${base64Encode(utf8.encode(file.source))}';
    final visiting = <String>{};
    void mountDependencies(SourceFileSnapshot file, dom.Element before) {
      if (!visiting.add(file.plan.id)) return;
      for (final id in file.plan.dependsOn) {
        final dependency = files[id];
        if (dependency == null ||
            !dependency.complete ||
            mounted.contains(id) ||
            graph.moduleIds.contains(id) ||
            explicitIds.contains(id) ||
            dependency.plan.kind == SourceFileKind.html) {
          continue;
        }
        mountDependencies(dependency, before);
        final script = dependency.plan.kind == SourceFileKind.js;
        final element = dom.Element.tag(script ? 'script' : 'link');
        if (!script) element.attributes['rel'] = 'stylesheet';
        element.attributes[script ? 'src' : 'href'] = resourceUrl(dependency);
        before.parentNode!.nodes.insert(
          before.parentNode!.nodes.indexOf(before),
          element,
        );
        mounted.add(id);
      }
      visiting.remove(file.plan.id);
    }

    for (final element in elements) {
      final script = element.localName == 'script';
      if (!script && element.attributes['rel']?.toLowerCase() != 'stylesheet') {
        continue;
      }
      final attribute = script ? 'src' : 'href';
      final reference = element.attributes[attribute];
      if (reference == null || external(reference)) continue;
      final id = reference.startsWith('./')
          ? reference.substring(2)
          : reference;
      final file = files[id];
      if (file == null ||
          !file.complete ||
          file.plan.kind != (script ? SourceFileKind.js : SourceFileKind.css)) {
        continue;
      }
      mountDependencies(file, element);
      element.attributes[attribute] = resourceUrl(file);
      mounted.add(id);
    }
    if (graph.moduleIds.isNotEmpty) {
      mounted.addAll(graph.moduleIds);
      final imports = graph.imports;
      map ??= <String, dynamic>{};
      final originalImports = map['imports'] as Map? ?? const {};
      // One import map also supports WebKit versions which do not merge
      // multiple maps. Preserve authored imports/scopes; owned IDs are unique
      // to this exact source snapshot and never replace a third-party name.
      map['imports'] = {...imports, ...originalImports};
      final importMap = authoredMap ?? dom.Element.tag('script');
      importMap.attributes['type'] = 'importmap';
      importMap.text = jsonEncode(map).replaceAll('<', r'\u003c');
      if (authoredMap == null) {
        final parent = document is dom.Document
            ? (document.head ?? document.documentElement!)
            : document;
        parent.nodes.insert(0, importMap);
      }
    }
    return (
      html: document is dom.Document
          ? document.outerHtml
          : (document as dom.DocumentFragment).outerHtml,
      mounted: mounted,
    );
  }

  static ({String html, List<String> css, List<String> js}) _normalizeDocument(
    String source,
    Map<String, SourceFileSnapshot> files,
    Map<String, SourceFileKind> kinds,
    Map<SourceFileKind, Map<String, int>> positions,
    Set<SourceFileKind> precedingInlineKinds,
    Set<SourceFileKind> precedingDeferredKinds,
  ) {
    final unchanged = (html: source, css: <String>[], js: <String>[]);
    final fullDocument =
        RegExp(
          r'^\s*(?:<!doctype\s+html\s*>\s*)?<html(?:\s|>)',
          caseSensitive: false,
        ).hasMatch(source) &&
        RegExp(r'</html>\s*$', caseSensitive: false).hasMatch(source);
    // Preserve ordinary fragments byte-for-byte. Browser parsing and execution
    // decide validity; assembly is not a second HTML/CSS/JS policy scanner.
    if (!fullDocument &&
        !RegExp(
          r'<\s*(?:script|style|link)\b',
          caseSensitive: false,
        ).hasMatch(source)) {
      return unchanged;
    }
    try {
      late final dom.Node content;
      late final List<dom.Node> headNodes;
      late final String Function() contentHtml;
      if (fullDocument) {
        final hasDoctype = RegExp(
          r'^\s*<!doctype\s+html\s*>',
          caseSensitive: false,
        ).hasMatch(source);
        final document = html_parser.HtmlParser(
          hasDoctype ? source : '<!doctype html>$source',
          strict: true,
        ).parse();
        final root = document.documentElement;
        final head = document.head;
        final body = document.body;
        if (root == null || head == null || body == null) return unchanged;
        if (!_attributes(root, const {'lang', 'dir'}) ||
            root.attributes['dir'] != null &&
                !const {
                  'ltr',
                  'rtl',
                  'auto',
                }.contains(root.attributes['dir']) ||
            head.attributes.isNotEmpty ||
            body.attributes.isNotEmpty) {
          return unchanged;
        }
        if (!document.nodes.every(
          (node) =>
              identical(node, root) ||
              _whitespace(node) ||
              node is dom.DocumentType &&
                  node.name?.toLowerCase() == 'html' &&
                  (node.publicId?.isEmpty ?? true) &&
                  (node.systemId?.isEmpty ?? true),
        )) {
          return unchanged;
        }
        if (!root.nodes.every(
          (node) =>
              identical(node, head) ||
              identical(node, body) ||
              _whitespace(node),
        )) {
          return unchanged;
        }
        content = body;
        headNodes = head.nodes.toList();
        contentHtml = () => body.innerHtml;
      } else {
        final fragment = html_parser.HtmlParser(
          source,
          strict: true,
        ).parseFragment('body');
        content = fragment;
        headNodes = const [];
        contentHtml = () => fragment.outerHtml;
      }
      final lastReference = <SourceFileKind, int>{};
      final inlineKinds = {...precedingInlineKinds};
      final deferredKinds = {...precedingDeferredKinds};
      final inlineCss = <String>[];
      final inlineJs = <String>[];
      bool resource(dom.Element element) {
        final tag = element.localName;
        final kind = tag == 'link' ? SourceFileKind.css : SourceFileKind.js;
        if (inlineKinds.contains(kind)) return false;
        if (tag == 'link') {
          if (!_attributes(element, const {'rel', 'href', 'type'}) ||
              element.attributes['rel']?.toLowerCase() != 'stylesheet' ||
              element.attributes['type'] != null &&
                  element.attributes['type']?.toLowerCase() != 'text/css') {
            return false;
          }
        } else if (tag == 'script') {
          if (!_attributes(element, const {'src', 'type', 'defer'}) ||
              element.attributes['type'] != null &&
                  !const {
                    'text/javascript',
                    'application/javascript',
                  }.contains(element.attributes['type']?.toLowerCase()) ||
              !element.nodes.every(_whitespace)) {
            return false;
          }
          if (element.attributes.containsKey('defer')) {
            deferredKinds.add(SourceFileKind.js);
          }
        } else {
          return false;
        }
        final reference = element.attributes[tag == 'link' ? 'href' : 'src'];
        if (reference == null) return false;
        final id = reference.startsWith('./')
            ? reference.substring(2)
            : reference;
        if (kinds[id] != kind || files[id]?.complete != true) return false;
        final position = positions[kind]![id]!;
        if (position <= (lastReference[kind] ?? -1)) return false;
        lastReference[kind] = position;
        return true;
      }

      bool mount(dom.Element element) {
        if (element.namespaceUri != 'http://www.w3.org/1999/xhtml') {
          return false;
        }
        final tag = element.localName;
        if (tag == 'link' ||
            tag == 'script' && element.attributes.containsKey('src')) {
          return resource(element);
        }
        if (tag != 'script' && tag != 'style') return false;
        if (!_attributes(element, const {'type'}) ||
            !element.nodes.every((node) => node is dom.Text)) {
          return false;
        }
        final type = element.attributes['type']?.trim().toLowerCase() ?? '';
        final kind = tag == 'script' ? SourceFileKind.js : SourceFileKind.css;
        if (kind == SourceFileKind.js) {
          if (!const {
                '',
                'text/javascript',
                'application/javascript',
              }.contains(type) ||
              deferredKinds.contains(kind)) {
            return false;
          }
          inlineJs.add(element.text);
        } else {
          if (!const {'', 'text/css'}.contains(type)) return false;
          inlineCss.add(element.text);
        }
        inlineKinds.add(kind);
        return true;
      }

      bool metadata(dom.Element element) {
        if (element.localName == 'title') {
          return element.attributes.isEmpty &&
              element.nodes.every((node) => node is dom.Text);
        }
        if (element.localName != 'meta' || element.nodes.isNotEmpty) {
          return false;
        }
        if (element.attributes.containsKey('charset')) {
          return _attributes(element, const {'charset'}) &&
              const {
                'utf-8',
                'utf8',
              }.contains(element.attributes['charset']?.toLowerCase());
        }
        return _attributes(element, const {'name', 'content'}) &&
            element.attributes.containsKey('content') &&
            const {
              'viewport',
              'theme-color',
              'description',
              'application-name',
            }.contains(element.attributes['name']?.toLowerCase());
      }

      for (final node in headNodes) {
        if (_whitespace(node)) continue;
        if (node is! dom.Element) return unchanged;
        if (const {'script', 'style', 'link'}.contains(node.localName)) {
          if (!mount(node)) return unchanged;
        } else if (!metadata(node)) {
          return unchanged;
        }
      }
      bool normalizeBody(dom.Node parent) {
        for (final node in parent.nodes.toList()) {
          if (node is dom.Comment || node is dom.DocumentType) return false;
          if (node is! dom.Element) continue;
          if (node.localName == 'template') return false;
          if (const {'script', 'style', 'link'}.contains(node.localName)) {
            if (!mount(node)) return false;
            node.remove();
          } else if (!normalizeBody(node)) {
            return false;
          }
        }
        return true;
      }

      if (!normalizeBody(content)) return unchanged;
      // The host owns the document, title, viewport and stylesheet/script
      // mounting. All declared CSS/JS files (also unlinked ones) are included
      // once in their original plan order by the factory above.
      precedingInlineKinds.addAll(inlineKinds);
      precedingDeferredKinds.addAll(deferredKinds);
      return (html: contentHtml(), css: inlineCss, js: inlineJs);
    } catch (_) {
      return unchanged;
    }
  }

  static bool _attributes(dom.Element element, Set<String> allowed) => element
      .attributes
      .keys
      .every((name) => name is String && allowed.contains(name));

  static bool _whitespace(dom.Node node) =>
      node is dom.Text && node.data.trim().isEmpty;
}

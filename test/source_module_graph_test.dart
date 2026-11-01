import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime_diagnostic.dart';
import 'package:maaso/src/features/agent/application/tasks/source_module_graph.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace.dart';

SourceModuleGraph _graph(Map<String, String> sources) => SourceModuleGraph({
  for (final entry in sources.entries)
    entry.key: SourceFileSnapshot(
      plan: SourceFilePlan(
        id: entry.key,
        kind: SourceFileKind.js,
        purpose: 'Module',
      ),
      source: entry.value,
      complete: true,
    ),
}, namespace: 'maaso-test-owned');
String _source(String url) =>
    Uri.parse(url).data!.contentAsString(encoding: utf8);

void main() {
  test('resource linking selects only real quoted module references', () {
    const source = r'''
// import './not-a-module.js';
const prose = "import('./not-a-module.js')";
const pattern = /import\(['"]\.\/not-a-module\.js['"]\)/;
const raw = String.raw`export * from './not-a-module.js'`;
import value, {name as other} from /* keep */ './leaf.js';
export {name} from './leaf.js';
export * as namespace from './leaf.js';
import './leaf.js';
const loaded = import( /* keep */ './leaf.js');
const literalExpression = `${import('./leaf.js')}`;
const external = import('https://example.com/external.js');
const variable = import('./' + file);
object.import('./not-a-module.js');
''';
    final references = SurfaceJavaScriptModuleReferences.read(source)!;
    expect(references.map((value) => value.specifier), [
      './leaf.js',
      './leaf.js',
      './leaf.js',
      './leaf.js',
      './leaf.js',
      './leaf.js',
      'https://example.com/external.js',
    ]);
    final graph = _graph({
      'main.js': source,
      'leaf.js': 'export const name=42;',
    });
    graph.include('main.js');
    final compiled = _source(graph.resourceUrl('main.js'));
    expect(compiled, contains('// import \'./not-a-module.js\';'));
    expect(
      compiled,
      contains('const prose = "import(\'./not-a-module.js\')";'),
    );
    expect(
      compiled,
      contains(
        source
            .split('\n')
            .firstWhere((line) => line.startsWith('const pattern')),
      ),
    );
    expect(compiled, contains("String.raw`export * from './not-a-module.js'`"));
    expect(compiled, contains("object.import('./not-a-module.js')"));
    expect(compiled, contains("import('./' + file)"));
    expect(compiled, contains("import('https://example.com/external.js')"));
    expect(compiled, contains('from /* keep */ "maaso-test-owned/leaf.js"'));
    expect(graph.moduleIds, {'main.js', 'leaf.js'});
    // A changed specifier shifts columns. Never map that engine hash directly
    // into original authored-file columns without a real source map.
    final diagnostic = SurfaceRuntimeDiagnostic(
      category: 'reference_error',
      sourceHash: SurfaceRuntimeDiagnostic.hashSource(compiled),
      line: 1,
      column: 1,
    );
    expect(diagnostic.sourceOffset(source), isNull);
  });

  test('nested and cyclic graphs use stable browser module identities', () {
    final graph = _graph({
      'main.js': 'import {x} from "./lib.js";export const result=x;',
      'lib.js': 'export {x} from "./leaf.js";',
      'leaf.js': 'import {read} from "./cycle.js";export const x=read();',
      'cycle.js':
          'import {x} from "./leaf.js";export function read(){return 42;}',
    });
    final original = {
      for (final entry in graph.files.entries) entry.key: entry.value.source,
    };
    graph.include('main.js');
    expect(graph.moduleIds, original.keys.toSet());
    expect(graph.imports, hasLength(4));
    expect(graph.imports[graph.alias('main.js')], graph.resourceUrl('main.js'));
    expect(
      _source(graph.imports[graph.alias('cycle.js')]!),
      contains('"maaso-test-owned/leaf.js"'),
    );
    expect({
      for (final entry in graph.files.entries) entry.key: entry.value.source,
    }, original);
  });

  test(
    'unfamiliar lexical input is preserved, never rejected as a dialect',
    () {
      const source = r'import "./leaf.js"; class State { #value=1; }';
      final graph = _graph({'main.js': source, 'leaf.js': 'export const x=1;'});
      graph.include('main.js');
      expect(_source(graph.resourceUrl('main.js')), source);
    },
  );
}

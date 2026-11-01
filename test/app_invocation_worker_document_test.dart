import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_descriptor.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_execution_contract.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_surface_bridge.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';

void main() {
  String documentFor(String markup) {
    final project = SurfaceProject.fromJson({
      'id': 'script-type-probe',
      'rendering': 'webApp',
      'html': markup,
      'js': 'globalThis.sourceBody = true;',
    });
    final before = jsonEncode(project.toJson());
    try {
      return AppInvocationSurfaceBridge.build(
        source: project,
        descriptor: AppInvocationDescriptor.fromSurface(
          project: project,
          identity: AppInvocationIdentity(
            scopeKey: 'probe|owner',
            sourceId: project.id,
            revisionId: 'script-types-v1',
            sourceDigest: sha256.convert(utf8.encode(before)).toString(),
          ),
        ),
        nonce: 'a' * 48,
      );
    } finally {
      expect(jsonEncode(project.toJson()), before);
    }
  }

  List<Object?> scriptsFor(String markup) {
    final document = documentFor(markup);
    final configuration = RegExp(
      r' const config=(.*), workerSource=',
    ).firstMatch(document)!.group(1)!;
    return (jsonDecode(configuration) as Map)['scripts'] as List<Object?>;
  }

  test('classic script MIME and legacy language preserve source order', () {
    expect(
      scriptsFor('''
<script>untyped()</script>
<script type="">emptyType()</script>
<script type=" \tTeXT/JaVaScRiPt\r\n">classic()</script>
<script type="application/x-ecmascript">legacyMime()</script>
<script language="JavaScript1.5">legacyLanguage()</script>
<script type="text/jscript" language="vbscript">typeOverridesLanguage()</script>
'''),
      [
        'untyped()',
        'emptyType()',
        'classic()',
        'legacyMime()',
        'legacyLanguage()',
        'typeOverridesLanguage()',
        'globalThis.sourceBody = true;',
      ],
    );
  });

  test('inert data scripts are never evaluated or fetched', () {
    expect(
      scriptsFor('''
<script type="application/json">{"invalidAsJavaScript":true}</script>
<script type="text/x-template">throw Error('must stay inert')</script>
<script type="application/json" src="https://example.invalid/data">inertSource()</script>
<script type="importmap">{"imports":{}}</script>
<script type="text/javascript; charset=utf-8">mimeParametersAreInert()</script>
<script type="\u00a0text/javascript\u00a0">unicodeWhitespaceIsNotAscii()</script>
<script language="vbscript">legacyOtherLanguage()</script>
<script type=" module ">moduleWhitespaceIsData()</script>
'''),
      ['globalThis.sourceBody = true;'],
    );
  });

  test('nomodule fallback is skipped before considering an external src', () {
    expect(
      scriptsFor('''
<script nomodule>doNotRunFallback()</script>
<script nomodule src="https://example.invalid/fallback.js"></script>
'''),
      ['globalThis.sourceBody = true;'],
    );
  });

  test('inline and external modules explicitly require ordinary open', () {
    for (final markup in [
      '<script type="module">globalThis.marker = true;</script>',
      '<script type="MoDuLe" src="https://example.invalid/module.js"></script>',
    ]) {
      expect(
        () => documentFor(markup),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'reason',
            'invocation_module_requires_open',
          ),
        ),
      );
    }
  });

  test('classic external dependencies still require ordinary open', () {
    expect(
      () => documentFor(
        '<script src="https://example.invalid/main.js"></script>',
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'reason',
          'invocation_network_dependency_requires_open',
        ),
      ),
    );
  });

  test(
    'worker probe uses exact original sources and arbitrary declared actions',
    () {
      final source = File(
        'tool/fixtures/app_invocation_worker_fixture.js',
      ).readAsStringSync();
      final project = SurfaceProject.fromJson({
        'id': 'invocation-worker-probe',
        'title': 'Invocation probe',
        'rendering': 'webApp',
        'html': '''<main>Manual view stays unchanged</main>
<script type=" \tTeXT/JaVaScRiPt ">globalThis.__classicMarker = 42;</script>
<script type="application/json">{"inertJson":true}</script>
<script type="text/x-template">throw Error('inert_template_executed');</script>''',
        'js':
            "if (globalThis.__classicMarker !== 42) throw Error('classic_script_missing');\n$source",
        'manifest': {
          'schemaVersion': 2,
          'actions': [
            for (final entry in <String, Map<String, Object?>>{
              'values.total': {
                'values': {
                  'type': 'array',
                  'maxItems': 16,
                  'items': {
                    'type': 'number',
                    'minimum': -1000000,
                    'maximum': 1000000,
                  },
                },
              },
              'pixels.make': {
                'red': {'type': 'integer', 'minimum': 0, 'maximum': 255},
              },
              'image.echo': {
                'image': {
                  'type': 'string',
                  'maxLength': 128,
                  r'$comment': appInvocationImageHandleAnnotation,
                },
              },
              'network.probe': {
                'url': {'type': 'string', 'maxLength': 512},
              },
              'storage.probe': {
                'url': {'type': 'string', 'maxLength': 512},
                'write': {'type': 'boolean'},
              },
              'spin.forever': {},
            }.entries)
              {
                'name': entry.key,
                'schema': {
                  'type': 'object',
                  'properties': entry.value,
                  'required': entry.value.keys.toList(),
                  'additionalProperties': false,
                },
                'risk': 'localMutation',
                'consequencePolicy': 'reversible',
              },
          ],
          'events': <Object?>[],
        },
      });
      final before = jsonEncode(project.toJson());
      final descriptor = AppInvocationDescriptor.fromSurface(
        project: project,
        identity: AppInvocationIdentity(
          scopeKey: 'probe|owner',
          sourceId: project.id,
          revisionId: 'fixture-v1',
          sourceDigest: sha256.convert(utf8.encode(before)).toString(),
        ),
      );
      final document = AppInvocationSurfaceBridge.build(
        source: project,
        descriptor: descriptor,
        nonce: 'a' * 48,
      );
      expect(descriptor.contractIssues, isEmpty);
      expect(jsonEncode(project.toJson()), before);
      expect(document, contains("connect-src 'none'"));
      expect(document, contains('worker.terminate()'));
      expect(descriptor.documentSource, AppInvocationDocumentSource.absent);
      // The standalone native probe consumes this ACTUAL production host document.
      // Generating it is not a claim that a platform passed runtime isolation.
      final directory = Directory(
        'build/verification/home-app-invocation/worker-probe',
      )..createSync(recursive: true);
      File('${directory.path}/document.html').writeAsStringSync(document);
      File('${directory.path}/source-identity.json').writeAsStringSync(
        jsonEncode({
          'sourceSha256': sha256.convert(utf8.encode(before)).toString(),
          'sourceUnchanged': jsonEncode(project.toJson()) == before,
          'documentSha256': sha256.convert(utf8.encode(document)).toString(),
          'nonce': 'a' * 48,
          'adapterVersion': 1,
        }),
      );
    },
  );
}

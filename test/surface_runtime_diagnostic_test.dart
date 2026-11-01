import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:maaso/src/features/agent/application/surface/surface_manifest.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime_diagnostic.dart';
import 'package:maaso/src/features/agent/application/surface/surface_web_app_host.dart';
import 'package:maaso/src/features/agent/application/surface/surface_worker_health_gate.dart';

SurfaceProject _project(String source) => SurfaceProject(
  id: 'generic-error-contract',
  title: 'Contract',
  kind: SurfaceKind.fullscreen,
  rendering: SurfaceRendering.webApp,
  html: '<main>\n<button>Run</button>\n</main>',
  css: 'button{height:48px}\r\nmain{color:black}',
  js: source,
  transparent: false,
  placement: const SurfacePlacement(x: 0, y: 0, width: 1, height: 1),
  manifest: const SurfaceManifest(),
  backend: const {},
  revisions: const [],
);

SurfaceRuntimeDiagnostic _diagnostic(
  String source, {
  int line = 1,
  int column = 1,
}) => SurfaceRuntimeDiagnostic(
  category: 'reference_error',
  sourceHash: SurfaceRuntimeDiagnostic.hashSource(source),
  line: line,
  column: column,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('positions verify source hash, normalized lines and UTF-16 columns', () {
    const source = 'const title="😀";\r\nmissing();\rnext();';
    expect(
      _diagnostic(source, line: 2, column: 2).sourceOffset(source),
      source.indexOf('missing') + 1,
    );
    expect(
      _diagnostic(source, line: 3).sourceOffset(source),
      source.indexOf('next'),
    );
    expect(_diagnostic(source).sourceOffset('$source\n'), isNull);
    expect(_diagnostic(source, column: 900).sourceOffset(source), isNull);
    expect(_diagnostic(source, line: 900).sourceOffset(source), isNull);
    const escaped = 'const label="</script>"; missing();';
    expect(_diagnostic(escaped).sourceOffset(escaped), 0);
  });

  test('owned mounted script errors bind exact saved bytes only', () {
    const source = 'const title="😀";\nmissing();';
    final url =
        'data:text/javascript;base64,${base64Encode(utf8.encode(source))}';
    final markup = '<script src="$url"></script>';
    final diagnostic = _diagnostic(source, line: 2);
    expect(
      diagnostic.matchesProjectSource(html: markup, js: 'other();'),
      isTrue,
    );
    expect(
      diagnostic.matchesProjectSource(
        html: markup.replaceFirst(url, 'https://example.org/external.js'),
        js: 'other();',
      ),
      isFalse,
    );
    expect(
      _diagnostic(
        '$source changed',
        line: 2,
      ).matchesProjectSource(html: markup, js: 'other();'),
      isFalse,
    );
  });

  test(
    'diagnostic rejects arbitrary error prose, URLs, IDs and malformed facts',
    () {
      final valid = _diagnostic('missing();').toJson();
      expect(SurfaceRuntimeDiagnostic.tryParse(valid), isNotNull);
      for (final invalid in [
        {...valid, 'message': 'private'},
        {...valid, 'stack': 'private'},
        {...valid, 'fileId': 'model-picked'},
        {...valid, 'url': 'https://secret'},
        {...valid, 'category': 'private error'},
        {...valid, 'line': 1.5},
        {...valid, 'column': -1},
        {...valid, 'sourceHash': 'wrong'},
      ]) {
        expect(SurfaceRuntimeDiagnostic.tryParse(invalid), isNull);
      }
    },
  );

  test(
    'authenticated lifecycle preserves bounded metadata and old messages',
    () {
      final base = {
        'version': 1,
        'session': 7,
        'kind': 'lifecycle',
        'status': 'fatal',
        'reason': 'runtime_failed',
        'nonce': '0' * 32,
      };
      final old = SurfaceWebAppLifecycleMessage.tryParse(jsonEncode(base));
      expect(old, isNotNull);
      expect(old!.diagnostic, isNull);
      final next = SurfaceWebAppLifecycleMessage.tryParse(
        jsonEncode({...base, 'diagnostic': _diagnostic('missing();').toJson()}),
      );
      expect(next!.diagnostic!.category, 'reference_error');
      expect(
        SurfaceWorkerLifecycleMessage.tryParse(
          next.gatePayloadJson,
        )!.diagnostic!.line,
        1,
      );
      expect(
        SurfaceWebAppLifecycleMessage.tryParse(
          jsonEncode({
            ...base,
            'diagnostic': {'message': 'private'},
          }),
        ),
        isNull,
      );
      expect(
        SurfaceWebAppLifecycleMessage.tryParse(
          jsonEncode({
            ...base,
            'status': 'ready',
            'reason': 'first_frame_ready',
            'diagnostic': _diagnostic('missing();').toJson(),
          }),
        ),
        isNull,
      );
    },
  );

  test(
    'gate requires exact current session and source for runtime facts',
    () async {
      const source = 'missing();';
      final runtime = SurfaceRuntime();
      runtime.activeProject.value = _project(source);
      final gate = SurfaceWorkerHealthGate();
      addTearDown(gate.closeLifecycle);
      gate.beginPresentation(runtime: runtime);
      final waiting = gate.waitForFirstFrame(
        session: 17,
        document: 'host',
        timeout: const Duration(seconds: 1),
      );
      final assertion = expectLater(
        waiting,
        throwsA(
          isA<SurfaceWorkerFirstFrameException>().having(
            (error) => error.diagnostic?.sourceHash,
            'current hash',
            SurfaceRuntimeDiagnostic.hashSource(source),
          ),
        ),
      );
      Map<String, Object?> payload(
        int session,
        SurfaceRuntimeDiagnostic diagnostic,
      ) => {
        'version': 1,
        'session': session,
        'status': 'fatal',
        'reason': 'runtime_failed',
        'diagnostic': diagnostic.toJson(),
      };
      expect(
        gate.acceptLifecycleMessage(
          jsonEncode(payload(16, _diagnostic(source))),
          currentSession: 17,
        ),
        isFalse,
      );
      expect(
        gate.acceptLifecycleMessage(
          jsonEncode(payload(17, _diagnostic('other();'))),
          currentSession: 17,
        ),
        isFalse,
      );
      expect(
        gate.acceptLifecycleMessage(
          jsonEncode(payload(17, _diagnostic(source, column: 900))),
          currentSession: 17,
        ),
        isFalse,
      );
      expect(
        gate.acceptLifecycleMessage(
          jsonEncode(payload(17, _diagnostic(source))),
          currentSession: 17,
        ),
        isTrue,
      );
      expect(gate.releaseValidationHost(17), isTrue);
      await assertion;
    },
  );

  test('resource source mapping starts at the exact source first line', () {
    const source = 'const label="😀";\r\nmissing();';
    final document = SurfaceWebAppHost.build(
      _project(source),
      lifecycleToken: 7,
    );
    expect(document, contains('var authoredFirstSourceLine = 1;'));
    final url = html_parser
        .parse(document)
        .querySelectorAll('script')
        .last
        .attributes['src']!;
    expect(Uri.parse(url).data!.contentAsString(), source);
    expect(document, contains('event.isTrusted === true'));
  });

  test('writes generic native diagnostic fixtures when requested', () async {
    final root = Platform.environment['MAASO_NATIVE_DIAGNOSTIC_ROOT'];
    if (root == null) return;
    for (final entry in {
      'reference_error': 'missingContractSymbol();',
      'type_error': 'const contractValue=null; contractValue.run();',
      'synthetic_error':
          "window.dispatchEvent(new ErrorEvent('error',{filename:window.location.href,lineno:800,colno:1,error:new ReferenceError('private')}));",
      'unclassifiable_error':
          "throw new Proxy({}, {getPrototypeOf(){throw new Error('private');}});",
    }.entries) {
      final project = _project('const marker=1;\n${entry.value}');
      final directory = Directory('$root/${entry.key}');
      await directory.create(recursive: true);
      await File(
        '${directory.path}/document.html',
      ).writeAsString(SurfaceWebAppHost.build(project, lifecycleToken: 7));
      await File('${directory.path}/input.json').writeAsString(
        jsonEncode({
          'sourceHash': SurfaceRuntimeDiagnostic.hashSource(project.js),
          'source': project.js,
          'category': entry.key,
          'baseUrl': SurfaceWebAppHost.documentBaseUrl(
            project,
            lifecycleToken: 7,
            role: SurfaceWebAppDocumentRole.preflight,
          ),
        }),
      );
    }
  });
}

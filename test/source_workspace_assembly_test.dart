import 'dart:async';
import 'dart:convert';

import 'package:flutter_js/flutter_js.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_game_artifact.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_task_diagnostics.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace_assembly.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';

import 'support/project_source_fixture.dart';

const _instruction = '生成完整的魂斗罗小游戏，保留玩法、控制和所有页面。';
const _body =
    '<main id="game"><canvas id="stage"></canvas>'
    '<button id="start" type="button">开始</button></main>';
const _css =
    'html,body{overscroll-behavior:none;scroll-behavior:smooth}'
    '#stage{width:100%;height:100%}';
const _js =
    'document.querySelector("#start").addEventListener("click",()=>{'
    'document.querySelector("#stage").getContext("2d").fillRect(0,0,10,10);});';

String _document({
  String head = '<link rel="stylesheet" href="styles.css">',
  String body = _body,
  String scripts = '<script src="game.js"></script>',
  String htmlAttributes = 'lang="zh-CN"',
  String bodyAttributes = '',
}) =>
    '<!doctype html><html $htmlAttributes><head><meta charset="utf-8">'
    '<meta name="viewport" content="width=device-width,initial-scale=1">'
    '<meta name="theme-color" content="#071013"><title>离线行动</title>'
    '$head</head><body $bodyAttributes>$body$scripts</body></html>';

SourceWorkspaceSnapshot _workspace({
  String? html,
  String css = _css,
  String js = _js,
  Map<String, (SourceFileKind, String)> extra = const {},
  bool jsComplete = true,
  List<String> gameDependsOn = const [],
}) {
  final plans = <SourceFilePlan>[
    SourceFilePlan(id: 'styles.css', kind: SourceFileKind.css, purpose: '样式'),
    SourceFilePlan(
      id: 'game.js',
      kind: SourceFileKind.js,
      purpose: '完整玩法',
      dependsOn: gameDependsOn,
    ),
    for (final entry in extra.entries)
      SourceFilePlan(id: entry.key, kind: entry.value.$1, purpose: '附加模块'),
    SourceFilePlan(
      id: 'index.html',
      kind: SourceFileKind.html,
      purpose: '完整屏幕',
      dependsOn: ['styles.css', 'game.js'],
    ),
  ];
  final sources = {
    'styles.css': css,
    'game.js': js,
    'index.html': html ?? _body,
    for (final entry in extra.entries) entry.key: entry.value.$2,
  };
  return SourceWorkspaceSnapshot(
    requirementSha256: sourceWorkspaceDigest(_instruction),
    experienceType: 'game',
    blueprintComplete: true,
    blueprint: SourceBlueprint(
      title: '魂斗罗',
      summary: '完整离线游戏',
      skillInstructions: '按开始行动',
      files: plans,
    ),
    files: [
      for (final plan in plans)
        SourceFileSnapshot(
          plan: plan,
          source: sources[plan.id]!,
          complete: plan.id != 'game.js' || jsComplete,
        ),
    ],
  );
}

Future<SurfaceProject> _generate(
  SourceWorkspaceSnapshot draft, {
  List<SourceWorkspaceSnapshot>? saved,
  bool Function()? shouldCancel,
  void Function(GeneratedGameArtifact)? capture,
}) async {
  final client = SourceFixtureClient([]);
  final producer = GeneratedGameArtifact(
    client: client,
    instruction: _instruction,
    surfaceId: 'host-owned-game',
    zh: true,
    initialDraft: draft,
    onDraft: saved?.add,
    shouldCancel: shouldCancel,
  );
  capture?.call(producer);
  final envelope = await producer.generate();
  expect(client.requests, isEmpty);
  expect(client.ordinaryCalls, 0);
  return SurfaceProject.fromJson(envelope.actions.single['surface'] as Map);
}

void main() {
  test(
    'complete local document mounts declared files without losing draft source',
    () async {
      final html = _document();
      final draft = _workspace(html: html);
      final before = jsonEncode(draft.toJson());
      final project = await _generate(draft);
      expect(project.html, _body);
      expect(project.css, _css);
      expect(project.js, _js);
      expect(project.id, 'host-owned-game');
      expect(project.manifest.actions, isEmpty);
      expect(jsonEncode(draft.toJson()), before);
      expect(SurfaceProjectValidator.diagnoseForPublicGame(project), isEmpty);
    },
  );

  test('body fragments preserve exact source bytes', () {
    const fragment = '\n<main title="A &amp; B">中文</main>\n';
    expect(
      SourceWorkspaceAssembly.fromWorkspace(_workspace(html: fragment)).html,
      fragment,
    );
  });

  test(
    'all planned modules stay present once in original dependency order',
    () async {
      const otherJs = 'const secondModule = 2;';
      const otherCss = '.second{color:red}';
      final project = await _generate(
        _workspace(
          html: _document(),
          extra: {
            'second.js': (SourceFileKind.js, otherJs),
            'extra.css': (SourceFileKind.css, otherCss),
          },
        ),
      );
      expect(project.js, '$_js\n;\n$otherJs');
      expect(project.css, '$_css\n$otherCss');
      expect(SurfaceProjectValidator.diagnoseForPublicGame(project), isEmpty);
    },
  );

  test(
    'local dot-prefixed references and classic deferred scripts are compiled',
    () {
      final source = _document(
        head: '<link rel="stylesheet" type="text/css" href="./styles.css">',
        scripts:
            '<script type="text/javascript" src="./game.js" defer></script>',
      );
      expect(
        SourceWorkspaceAssembly.fromWorkspace(_workspace(html: source)).html,
        _body,
      );
    },
  );

  test(
    'classic inline bootstrap is retained and starts the owned game once',
    () async {
      const game = 'window.GameUI=class{init(){window.started+=1;}};';
      const bootstrap =
          "window.addEventListener('load',()=>{var ui=new window.GameUI();ui.init();});";
      final source = _document(
        scripts: '<script src="game.js"></script><script>$bootstrap</script>',
      );
      final draft = _workspace(html: source, js: game);
      final before = jsonEncode(draft.toJson());
      final project = await _generate(draft);
      expect(project.html, _body);
      expect(project.js, '$game\n;\n$bootstrap');
      expect(
        SourceWorkspaceAssembly.fromWorkspace(draft).inlineJavaScriptOwners,
        ['index.html'],
      );
      expect(project.css, _css);
      expect(jsonEncode(draft.toJson()), before);
      expect(SurfaceProjectValidator.diagnoseForPublicGame(project), isEmpty);
      final javascript = getJavascriptRuntime(xhr: false);
      addTearDown(javascript.dispose);
      final setup = javascript.evaluate('''
var window={started:0,callbacks:[],addEventListener:function(name,callback){
  if(name==='load')this.callbacks.push(callback);
}};
''');
      expect(setup.isError, isFalse, reason: setup.stringResult);
      final mounted = javascript.evaluate("'use strict';\n${project.js}");
      expect(mounted.isError, isFalse, reason: mounted.stringResult);
      final launched = javascript.evaluate(
        'window.callbacks.forEach(callback=>callback());window.started;',
      );
      expect(launched.isError, isFalse, reason: launched.stringResult);
      expect(launched.stringResult, '1');
    },
  );

  test('fragment inline style and script retain literals and mount order', () {
    const style = '.literal::after{content:"A & B"}';
    const first = 'const label="A &amp; B";// source comment';
    const second = 'const next="</not-script>";';
    final fragment =
        '$_body<style type="text/css">$style</style>'
        '<script type="application/javascript">$first</script>'
        '<script>$second</script>';
    final draft = _workspace(html: fragment);
    final before = jsonEncode(draft.toJson());
    final assembly = SourceWorkspaceAssembly.fromWorkspace(draft);
    expect(assembly.html, _body);
    expect(assembly.css, '$_css\n$style');
    expect(assembly.js, '$_js\n;\n$first\n;\n$second');
    expect(assembly.inlineJavaScriptOwners, ['index.html']);
    expect(assembly.inlineStyleOwners, ['index.html']);
    expect(jsonEncode(draft.toJson()), before);
  });

  test('head and body inline styles append after declared styles in order', () {
    const first = '#stage{color:red}', second = '#stage{color:blue}';
    final html = _document(
      head: '<link rel="stylesheet" href="styles.css"><style>$first</style>',
      body: '$_body<style>$second</style>',
    );
    final assembly = SourceWorkspaceAssembly.fromWorkspace(
      _workspace(html: html),
    );
    expect(assembly.html, _body);
    expect(assembly.css, '$_css\n$first\n$second');
    expect(assembly.js, _js);
    expect(assembly.inlineJavaScriptOwners, isEmpty);
    expect(assembly.inlineStyleOwners, ['index.html']);
  });

  test(
    'inline mounts never reorder later local references or deferred execution',
    () {
      for (final source in [
        _document(
          scripts:
              '<script>const boot=1;</script><script src="game.js"></script>',
        ),
        _document(
          head:
              '<style>#stage{color:red}</style><link rel="stylesheet" href="styles.css">',
        ),
        _document(
          scripts:
              '<script src="game.js" defer></script><script>const boot=1;</script>',
        ),
        '$_body<script>const boot=1;</script><script src="game.js"></script>',
      ]) {
        final assembly = SourceWorkspaceAssembly.fromWorkspace(
          _workspace(html: source),
        );
        final parsed = html_parser.parse(assembly.html);
        final mounted = parsed
            .querySelectorAll('script[src],link[href]')
            .map(
              (element) =>
                  element.attributes['src'] ?? element.attributes['href'],
            )
            .whereType<String>()
            .where((url) => url.startsWith('data:'))
            .map((url) => Uri.parse(url).data!.contentAsString())
            .toList();
        expect([...mounted, assembly.js, assembly.css], contains(_js));
        expect([...mounted, assembly.js, assembly.css], contains(_css));
        expect(
          assembly.html,
          anyOf(contains('const boot=1;'), contains('color:red')),
        );
      }
    },
  );

  test(
    'extracted browser code is not rejected for network or stylesheet syntax',
    () async {
      final game = await _generate(
        _workspace(
          html: _document(scripts: '<script>fetch("/private");</script>'),
        ),
      );
      expect(game.html, _body);
      expect(game.js, '$_js\n;\nfetch("/private");');
      expect(SurfaceProjectValidator.diagnoseForPublicGame(game), isEmpty);
      final styles = await _generate(
        _workspace(
          html: _document(head: '<style>@import "remote.css";</style>'),
        ),
      );
      expect(styles.html, contains('@import "remote.css";'));
      expect(styles.css, _css);
      expect(SurfaceProjectValidator.diagnoseForPublicGame(styles), isEmpty);
    },
  );

  for (final startup in [true]) {
    test(
      '${startup ? 'startup' : 'inline policy'} repair reaches the HTML bootstrap owner with two healthy JS files',
      () async {
        final broken = startup ? 'missingStartup();' : 'fetch("/blocked");';
        const repaired = 'const inlineRepaired=true;';
        const second = 'const healthySecond=2;';
        final html = _document(
          scripts:
              '<script src="game.js"></script><script src="second.js"></script>'
              '<script>$broken</script>',
        );
        final draft = _workspace(
          html: html,
          extra: {'second.js': (SourceFileKind.js, second)},
        );
        final originalDraft = jsonEncode(draft.toJson());
        final client = _InlineOwnerRepairClient(
          {for (final file in draft.files) file.plan.id: file.source},
          broken,
          repaired,
        );
        final saved = <SourceWorkspaceSnapshot>[];
        final producer = GeneratedGameArtifact(
          client: client,
          instruction: _instruction,
          surfaceId: 'repair-inline-owner',
          zh: true,
          initialDraft: draft,
          onDraft: saved.add,
        );
        final original = await producer.generate();
        final originalProject = SurfaceProject.fromJson(
          original.actions.single['surface'] as Map,
        );
        final result = await producer.repair(
          original,
          startup
              ? 'surface worker first frame rejected: runtime_failed'
              : SurfaceProjectValidator.diagnoseForPublicGame(
                  originalProject,
                ).join('; '),
        );
        expect(client.requestedFiles, contains('index.html'));
        expect(client.requestedFiles.toSet(), {
          'game.js',
          'second.js',
          'index.html',
        });
        final project = SurfaceProject.fromJson(
          result.actions.single['surface'] as Map,
        );
        expect(project.js, '$_js\n;\n$second\n;\n$repaired');
        expect(project.html, _body);
        expect(project.css, _css);
        expect(SurfaceProjectValidator.diagnoseForPublicGame(project), isEmpty);
        for (final id in ['game.js', 'second.js']) {
          expect(
            saved.last.files.singleWhere((file) => file.plan.id == id).source,
            draft.files.singleWhere((file) => file.plan.id == id).source,
          );
        }
        expect(
          saved.last.files
              .singleWhere((file) => file.plan.id == 'index.html')
              .source,
          html.replaceFirst(broken, repaired),
        );
        expect(result.reply, original.reply);
        expect(jsonEncode(draft.toJson()), originalDraft);
      },
    );
  }

  test(
    'mixed remote and local dependencies keep authored order without duplication',
    () async {
      const remote = '<script src="https://cdn.example/library.js"></script>';
      final source = _document(
        head: '<link rel="stylesheet" href="styles.css">',
        scripts:
            '$remote<script src="game.js"></script><script type="module">import "https://cdn.example/module.js";</script>',
      );
      final draft = _workspace(html: source);
      final before = jsonEncode(draft.toJson());
      final project = await _generate(draft);
      final parsed = html_parser.parse(project.html);
      final scripts = parsed.querySelectorAll('script');
      expect(scripts[0].attributes['src'], 'https://cdn.example/library.js');
      expect(
        Uri.parse(scripts[1].attributes['src']!).data!.contentAsString(),
        _js,
      );
      expect(scripts[2].attributes['type'], 'module');
      expect(
        Uri.parse(
          parsed.querySelector('link')!.attributes['href']!,
        ).data!.contentAsString(),
        _css,
      );
      expect(project.js, isEmpty);
      expect(project.css, isEmpty);
      expect(jsonEncode(draft.toJson()), before);
      expect(SurfaceProjectValidator.diagnoseForPublicGame(project), isEmpty);
    },
  );

  test('browser markup is preserved for actual runtime parsing', () async {
    final unsafe = <String>[
      _document(head: '<link rel="stylesheet" href="missing.css">'),
      _document(head: '<link rel="stylesheet" href="game.js">'),
      _document(head: '<link rel="stylesheet" href="/styles.css">'),
      _document(
        head: '<link rel="stylesheet" href="https://example.com/style.css">',
      ),
      _document(head: '<link rel="stylesheet" href="//example.com/style.css">'),
      _document(head: '<link rel="stylesheet" href="styles.css?remote=true">'),
      _document(
        head: '<link rel="stylesheet" href="styles.css" onload="start()">',
      ),
      _document(
        head: '<link rel="stylesheet" href="styles.css" media="print">',
      ),
      _document(head: '<base href="https://example.com/">'),
      _document(
        head:
            '<meta http-equiv="refresh" content="0;url=https://example.com/">',
      ),
      _document(head: '<style media="print">body{color:red}</style>'),
      _document(head: '<div>parser must not silently discard this</div>'),
      _document(head: '<!-- hidden head content -->'),
      _document(scripts: '<script src="missing.js"></script>'),
      _document(scripts: '<script src="styles.css"></script>'),
      _document(scripts: '<script src="https://example.com/game.js"></script>'),
      _document(scripts: '<script src="game.js">start()</script>'),
      _document(scripts: '<script type="module">start()</script>'),
      _document(scripts: '<script onload="start()">start()</script>'),
      _document(scripts: '<script async>start()</script>'),
      _document(scripts: '<script type="module" src="game.js"></script>'),
      _document(scripts: '<script async src="game.js"></script>'),
      _document(scripts: '<script src="game.js" src="missing.js"></script>'),
      _document(htmlAttributes: 'lang="zh-CN" onload="start()"'),
      _document(bodyAttributes: 'onload="start()"'),
      _document(body: '<main onclick="start()">Start</main>'),
      _document(body: '<main><!-- hidden body content -->Start</main>'),
      '${_document()}<script>start()</script>',
    ];
    for (final source in unsafe) {
      final project = await _generate(_workspace(html: source));
      expect(
        SurfaceProjectValidator.diagnoseForPublicGame(project),
        isEmpty,
        reason: source,
      );
    }
  });

  test(
    'unreferenced planned dependencies mount before their referencing script',
    () {
      final draft = _workspace(
        html: _document(
          scripts:
              '<script src="https://cdn.example/library.js"></script><script src="game.js"></script>',
        ),
        js: 'window.result=engineReady;',
        gameDependsOn: ['engine.js'],
        extra: {'engine.js': (SourceFileKind.js, 'var engineReady=42;')},
      );
      final assembly = SourceWorkspaceAssembly.fromWorkspace(draft);
      final mounted = html_parser
          .parse(assembly.html)
          .querySelectorAll('script[src]')
          .map((element) => element.attributes['src']!)
          .where((url) => url.startsWith('data:'))
          .map((url) => Uri.parse(url).data!.contentAsString())
          .toList();
      expect(mounted, ['var engineReady=42;', 'window.result=engineReady;']);
      expect(assembly.js, isEmpty);
      expect(assembly.javaScriptFileIds, isEmpty);
      final engine = getJavascriptRuntime(xhr: false);
      addTearDown(engine.dispose);
      final result = engine.evaluate(
        'var window=globalThis;${mounted.join("\n")}window.result;',
      );
      expect(result.isError, isFalse, reason: result.stringResult);
      expect(result.stringResult, '42');
    },
  );

  test('an incomplete declared resource cannot be consumed', () {
    final source = _document();
    final assembly = SourceWorkspaceAssembly.fromWorkspace(
      _workspace(html: source, jsComplete: false),
    );
    expect(assembly.html, source);
  });

  test(
    'reordered or duplicated script mounts are not silently reordered',
    () async {
      for (final scripts in [
        '<script src="second.js"></script><script src="game.js"></script>',
        '<script src="game.js"></script><script src="game.js"></script>',
      ]) {
        final html = _document(scripts: scripts);
        final draft = _workspace(
          html: html,
          extra: {'second.js': (SourceFileKind.js, 'const second=2;')},
        );
        final project = await _generate(draft);
        final mounted = html_parser
            .parse(project.html)
            .querySelectorAll('script[src]')
            .map(
              (element) =>
                  Uri.parse(element.attributes['src']!).data!.contentAsString(),
            )
            .toList();
        expect(
          mounted,
          scripts.startsWith('<script src="second.js"')
              ? ['const second=2;', _js]
              : [_js, _js],
        );
        expect(SurfaceProjectValidator.diagnoseForPublicGame(project), isEmpty);
      }
    },
  );

  test('normalization preserves browser network code', () async {
    final project = await _generate(
      _workspace(html: _document(), js: 'fetch("/private");'),
    );
    expect(project.html, _body);
    expect(project.js, 'fetch("/private");');
    expect(SurfaceProjectValidator.diagnoseForPublicGame(project), isEmpty);
  });

  test(
    'CSS is interpreted by the browser rather than a keyword scanner',
    () async {
      for (final safe in [
        _css,
        '.control{overscroll-behavior-x:contain;overscroll-behavior-y:none}',
        '.control{scroll-behavior : smooth;--behavior:0}',
        '.control::after{content:"behavior:"}',
        '.control::after{content:";behavior:"}',
        ".control::after{content:'{behavior:example'}",
      ]) {
        final project = await _generate(_workspace(css: safe));
        expect(
          SurfaceProjectValidator.diagnoseForPublicGame(project),
          isEmpty,
          reason: safe,
        );
      }
      for (final unsafe in [
        '.control{behavior:bad}',
        '.control{BEHAVIOR :bad}',
        '.control{behavior/**/ :bad}',
        '.control{*behavior:bad}',
        '.control{_behavior:bad}',
        '.control{color:red;behavior :bad}',
        '.control{background:u/**/rl(/asset.png)}',
        '@import "remote.css";',
        '.control{background:url(//example.com/a)}',
      ]) {
        final project = await _generate(_workspace(css: unsafe));
        expect(
          SurfaceProjectValidator.diagnoseForPublicGame(project),
          isEmpty,
          reason: unsafe,
        );
      }
    },
  );

  test(
    'host validation diagnostics persist only closed facts with cancellation fence',
    () async {
      final saved = <SourceWorkspaceSnapshot>[];
      var cancel = false;
      late GeneratedGameArtifact producer;
      final draft = _workspace(html: _document());
      await _generate(
        draft,
        saved: saved,
        shouldCancel: () => cancel,
        capture: (value) => producer = value,
      );
      await producer.recordValidationDiagnostic();
      expect(saved.last.diagnostic!.toJson(), {
        'phase': 'validation',
        'reason': 'validationRejected',
      });
      await producer.recordValidationDiagnostic(startup: true);
      expect(saved.last.diagnostic!.toJson(), {
        'phase': 'validation',
        'reason': 'runtimeFirstFrameRejected',
      });
      expect(
        saved.last.files.map((f) => f.source),
        draft.files.map((f) => f.source),
      );
      expect(
        SourceWorkspaceSnapshot.fromJson(
          saved.last.toJson(),
        ).diagnostic!.reason,
        SourceDiagnosticReason.runtimeFirstFrameRejected,
      );
      final count = saved.length;
      cancel = true;
      await expectLater(
        producer.recordValidationDiagnostic(),
        throwsA(
          isA<GeneratedTaskFailure>().having(
            (e) => e.code,
            'code',
            GeneratedTaskFailureCode.interrupted,
          ),
        ),
      );
      expect(saved, hasLength(count));
    },
  );

  test(
    'default repair sees the complete 19.6KiB script and actual HTML/CSS interfaces',
    () async {
      final js =
          '${'// retained prefix\n' * 500}'
          'const UNIQUE_MIDDLE_SYNTAX_MARKER = ;\n'
          '${'// retained suffix\n' * 600}';
      expect(utf8.encode(js).length, greaterThan(19600));
      final draft = _workspace(html: _document(), js: js);
      final client = SourceFixtureClient([
        jsonEncode(boundSourceChunk('game.js', _js)),
      ]);
      final producer = GeneratedGameArtifact(
        client: client,
        instruction: _instruction,
        surfaceId: 'repair-host-owned',
        zh: true,
        initialDraft: draft,
      );
      final original = await producer.generate();
      expect(client.requests, isEmpty);
      final repaired = await producer.repair(
        original,
        'surface worker first frame rejected: runtime_failed',
      );
      expect(client.requests, hasLength(1));
      final prompt = client.requests.single.first.content;
      const marker = 'Host-owned source display (immutable data): ';
      final display =
          jsonDecode(prompt.substring(prompt.indexOf(marker) + marker.length))
              as Map;
      final current = display['current'] as Map;
      expect(current['sourceVersion'], 'current');
      expect(current['fullBytes'], utf8.encode(js).length);
      final ranges = current['ranges'] as List;
      expect(ranges, hasLength(1));
      expect((ranges.single as Map)['text'], js);
      expect((ranges.single as Map)['startByte'], 0);
      expect((ranges.single as Map)['endByte'], utf8.encode(js).length);
      final dependencies = (display['dependencies'] as List).cast<Map>();
      expect(dependencies.map((v) => v['fileId']).toSet(), {
        'index.html',
        'styles.css',
      });
      for (final dependency in dependencies) {
        final file = draft.files.singleWhere(
          (f) => f.plan.id == dependency['fileId'],
        );
        expect((dependency['ranges'] as List).single['text'], file.source);
      }
      expect((repaired.actions.single['surface'] as Map)['js'], _js);
      expect((repaired.actions.single['surface'] as Map)['html'], _body);
      expect((repaired.actions.single['surface'] as Map)['css'], _css);
    },
  );
}

class _InlineOwnerRepairClient extends SourceFixtureClient {
  _InlineOwnerRepairClient(this.sources, this.broken, this.repaired)
    : super([]);
  final Map<String, String> sources;
  final String broken, repaired;
  final List<String> requestedFiles = [];

  @override
  Future<ProjectSourceResponse> generateProjectSource(
    List<Message> messages, {
    Duration? timeout,
    FutureOr<void> Function()? onAdmitted,
    bool Function()? shouldCancel,
  }) async {
    await onAdmitted?.call();
    requests.add(List<Message>.unmodifiable(messages));
    final id = RegExp(
      r'File binding: \{"fileId":"([^"]+)"',
    ).firstMatch(messages.first.content)!.group(1)!;
    requestedFiles.add(id);
    return ProjectSourceResponse(
      visibleText: jsonEncode({
        'fileId': id,
        'baseHash': sourceWorkspaceDigest(sources[id]!),
        'edits': [
          if (id == 'index.html') {'oldText': broken, 'newText': repaired},
        ],
      }),
      termination: ProjectSourceTermination.complete,
    );
  }
}

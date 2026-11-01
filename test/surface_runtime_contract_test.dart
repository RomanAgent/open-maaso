import 'dart:async';
import 'dart:convert';

import 'package:flutter_js/flutter_js.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/foundation/app_services.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/action/action_definition.dart';
import 'package:maaso/src/features/agent/application/surface/surface_manifest.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:webview_flutter/webview_flutter.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

void main() {
  test('surface project serializes freeform floating canvas metadata', () {
    final project = SurfaceProject(
      id: 'surface_1',
      title: 'Orbit Toy',
      kind: SurfaceKind.floatingCanvas,
      rendering: SurfaceRendering.canvas,
      html: '<canvas id="c"></canvas>',
      css: 'html,body{background:transparent}',
      js: 'console.log("ok")',
      transparent: true,
      placement: const SurfacePlacement(
        x: 0.1,
        y: 0.2,
        width: 0.8,
        height: 0.5,
      ),
      manifest: const SurfaceManifest(),
      backend: const {},
      revisions: const [],
    );

    final json = project.toJson();
    final decoded = SurfaceProject.fromJson(json);

    expect(decoded.kind, SurfaceKind.floatingCanvas);
    expect(decoded.rendering, SurfaceRendering.canvas);
    expect(decoded.transparent, isTrue);
    expect(decoded.placement.width, 0.8);
  });

  test('surface manifest validates action names and renders prompt text', () {
    const manifest = SurfaceManifest(
      events: [
        SurfaceEntry('tap_star', {'id': 'string'}),
      ],
      actions: [
        SurfaceEntry('spawn_star', {'x': 'number'}),
      ],
      instructions: 'React briefly.',
    );

    expect(manifest.validateAction('spawn_star', {'x': 1}), isNull);
    expect(manifest.validateAction('missing', {}), contains('unknown action'));
    expect(manifest.toPromptText('surface_1'), contains('spawn_star'));
  });

  test('surface runtime exposes active manifest prompt block', () async {
    final rt = SurfaceRuntime();
    await rt.show(
      SurfaceProject(
        id: 'surface_1',
        title: 'Canvas Toy',
        kind: SurfaceKind.floatingCanvas,
        rendering: SurfaceRendering.canvas,
        html: '<canvas></canvas>',
        css: '',
        js: 'window.ready=true;',
        transparent: true,
        placement: const SurfacePlacement(x: 0, y: 0, width: 1, height: 1),
        manifest: const SurfaceManifest(actions: [SurfaceEntry('pulse', {})]),
        backend: const {},
        revisions: const [],
      ),
    );

    expect(rt.isVisible.value, isTrue);
    expect(rt.activeSurfaceId, 'surface_1');
    expect(rt.manifestForPrompt(), contains('pulse'));
  });

  test(
    'surface runtime validates and snapshots the exact bridge payload',
    () async {
      final platformController = _RecordingPlatformWebViewController();
      final rt = SurfaceRuntime()
        ..attach(WebViewController.fromPlatform(platformController));
      const payloadSchema = <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'value': <String, Object?>{'type': 'string'},
        },
        'required': <String>['value'],
        'additionalProperties': false,
      };
      await rt.show(
        SurfaceProject(
          id: 'surface_bridge_contract',
          title: 'Bridge Contract',
          kind: SurfaceKind.card,
          rendering: SurfaceRendering.dom,
          html: '<main>Ready</main>',
          css: '',
          js: '',
          transparent: false,
          placement: const SurfacePlacement(x: 0, y: 0, width: 1, height: 1),
          manifest: SurfaceManifest.v2(
            events: <SurfaceEntry>[
              SurfaceEntry.v2(
                name: 'contract.event',
                schema: payloadSchema,
                risk: ActionRisk.readOnly,
                consequencePolicy: ActionConsequencePolicy.reversible,
              ),
            ],
            actions: <SurfaceEntry>[
              SurfaceEntry.v2(
                name: 'contract.action',
                schema: payloadSchema,
                risk: ActionRisk.localMutation,
                consequencePolicy: ActionConsequencePolicy.reversible,
              ),
            ],
          ),
          backend: const <String, Object?>{},
          revisions: const <SurfaceRevision>[],
        ),
      );

      for (final invalid in <Object?>['not-an-object', <Object?>[], null]) {
        expect(
          await rt.surfaceCall('contract.action', invalid),
          contains('invalid_arguments'),
        );
        rt.onPageEvent('contract.event', invalid);
      }
      expect(
        await rt.surfaceCall('contract.action', <String, Object?>{
          'value': List<String>.filled(64 * 1024 + 1, 'x').join(),
        }),
        contains('payload_not_json'),
      );
      expect(platformController.scripts, isEmpty);

      final changedAfterPreflight = <String, Object?>{'value': 'before'};
      expect(
        rt.preflightCall('contract.action', changedAfterPreflight),
        isNull,
      );
      changedAfterPreflight['value'] = 7;
      expect(
        await rt.surfaceCall('contract.action', changedAfterPreflight),
        contains('invalid_arguments'),
      );
      expect(platformController.scripts, isEmpty);

      final received = <SurfaceEvent>[];
      final subscription = rt.onEvent.listen(received.add);
      final actionPayload = <String, Object?>{'value': 'before'};
      expect(await rt.surfaceCall('contract.action', actionPayload), isNull);
      actionPayload['value'] = 'after';
      expect(platformController.scripts, hasLength(1));
      expect(platformController.scripts.single, contains('"value":"before"'));
      expect(platformController.scripts.single, isNot(contains('after')));

      final eventPayload = <String, Object?>{'value': 'before'};
      rt.onPageEvent('contract.event', eventPayload);
      eventPayload['value'] = 'after';
      await pumpEventQueue();

      expect(received, hasLength(1));
      expect(received.single.data, <String, Object?>{'value': 'before'});
      expect(
        () => (received.single.data as Map<String, Object?>)['value'] = 'after',
        throwsUnsupportedError,
      );
      await subscription.cancel();
    },
  );

  for (final legacy in [false, true]) {
    test(
      '${legacy ? "legacy category" : "explicit"} game rejects declared model actions before JavaScript',
      () async {
        final platformController = _RecordingPlatformWebViewController();
        final runtime = SurfaceRuntime()
          ..attach(WebViewController.fromPlatform(platformController));
        final manifest = legacy
            ? const SurfaceManifest(actions: [SurfaceEntry('game.move', {})])
            : SurfaceManifest.v2(
                actions: [
                  SurfaceEntry.v2(
                    name: 'game.move',
                    schema: const {
                      'type': 'object',
                      'properties': <String, Object?>{},
                      'required': <String>[],
                      'additionalProperties': false,
                    },
                    risk: ActionRisk.localMutation,
                    consequencePolicy: ActionConsequencePolicy.reversible,
                  ),
                ],
              );
        final project = SurfaceProject(
          id: 'voice-only-game',
          title: 'Voice Only Game',
          kind: SurfaceKind.fullscreen,
          rendering: legacy
              ? SurfaceRendering.dom
              : SurfaceRendering.workerCanvas,
          html: legacy
              ? '<main><button onclick="move()">Move</button></main>'
              : '',
          css: '',
          js: legacy
              ? 'let moves=0; function move(){moves++;}'
                    'globalThis.__applyAgent=()=>moves++;'
              : _workerGameJs,
          transparent: false,
          placement: const SurfacePlacement(x: 0, y: 0, width: 1, height: 1),
          manifest: manifest,
          backend: const {},
          revisions: const [],
          experienceType: legacy
              ? SurfaceExperienceType.utility
              : SurfaceExperienceType.game,
          category: 'game',
        );
        await runtime.show(
          legacy ? SurfaceProject.fromJson(project.toJson()) : project,
        );
        expect(manifest.validateAction('game.move', const {}), isNull);
        expect(
          runtime.preflightCall('game.move', const {}),
          'game actions are controlled by the player',
        );
        expect(
          await runtime.surfaceCall('game.move', const {}),
          'game actions are controlled by the player',
        );
        expect(platformController.scripts, isEmpty);
        await runtime.close();
      },
    );
  }

  test(
    'legacy runtime normalizes null bridge payloads to empty objects',
    () async {
      final platformController = _RecordingPlatformWebViewController();
      final rt = SurfaceRuntime()
        ..attach(WebViewController.fromPlatform(platformController));
      await rt.show(
        SurfaceProject(
          id: 'surface_legacy_null',
          title: 'Legacy Null',
          kind: SurfaceKind.card,
          rendering: SurfaceRendering.dom,
          html: '<main>Ready</main>',
          css: '',
          js: '',
          transparent: false,
          placement: const SurfacePlacement(x: 0, y: 0, width: 1, height: 1),
          manifest: const SurfaceManifest(
            events: <SurfaceEntry>[SurfaceEntry('legacy.event', {})],
            actions: <SurfaceEntry>[SurfaceEntry('legacy.action', {})],
          ),
          backend: const <String, Object?>{},
          revisions: const <SurfaceRevision>[],
        ),
      );

      final received = <SurfaceEvent>[];
      final subscription = rt.onEvent.listen(received.add);
      expect(await rt.surfaceCall('legacy.action', null), isNull);
      rt.onPageEvent('legacy.event', null);
      await pumpEventQueue();

      expect(platformController.scripts, hasLength(1));
      expect(
        platformController.scripts.single,
        endsWith('"legacy.action", {})'),
      );
      expect(received, hasLength(1));
      expect(received.single.data, isEmpty);
      await subscription.cancel();
    },
  );

  test('surface call cannot complete across a capability generation', () async {
    await appServices.reset();
    addTearDown(appServices.reset);
    final snapshots = appServices.put<AppCapabilitySnapshotService>(
      AppCapabilitySnapshotService(
        resolver: AppPlatformCapabilitySnapshotResolver(routeIds: const {}),
        initialContext: AppCapabilitySnapshotContext(
          hostPlatform: AppHostPlatform.macos,
          rolloutGeneration: 0,
        ),
      ),
    );
    final platformController = _DeferredPlatformWebViewController();
    final runtime = SurfaceRuntime()
      ..attach(WebViewController.fromPlatform(platformController));
    await runtime.show(
      SurfaceProject(
        id: 'surface_capability_call',
        title: 'Capability call',
        kind: SurfaceKind.card,
        rendering: SurfaceRendering.dom,
        html: '<main>Ready</main>',
        css: '',
        js: '',
        transparent: false,
        placement: const SurfacePlacement(x: 0, y: 0, width: 1, height: 1),
        manifest: const SurfaceManifest(
          actions: <SurfaceEntry>[SurfaceEntry('pulse', {})],
        ),
        backend: const <String, Object?>{},
        revisions: const <SurfaceRevision>[],
      ),
    );

    final calling = runtime.surfaceCall('pulse', const <String, Object?>{});
    expect(platformController.scripts, hasLength(1));
    snapshots.refresh(snapshots.context.copyWith(rolloutGeneration: 1));
    platformController.completeNext();

    expect(await calling, contains('capability unavailable'));
  });

  test('surface call cannot complete against a replacement session', () async {
    final platformController = _DeferredPlatformWebViewController();
    final runtime = SurfaceRuntime()
      ..attach(WebViewController.fromPlatform(platformController));
    await runtime.show(
      SurfaceProject(
        id: 'surface_call_owner',
        title: 'Call owner',
        kind: SurfaceKind.card,
        rendering: SurfaceRendering.dom,
        html: '<main>Owner</main>',
        css: '',
        js: '',
        transparent: false,
        placement: const SurfacePlacement(x: 0, y: 0, width: 1, height: 1),
        manifest: const SurfaceManifest(
          actions: <SurfaceEntry>[SurfaceEntry('pulse', {})],
        ),
        backend: const <String, Object?>{},
        revisions: const <SurfaceRevision>[],
      ),
    );

    final calling = runtime.surfaceCall('pulse', const <String, Object?>{});
    expect(platformController.scripts, hasLength(1));
    await runtime.show(_project(id: 'surface_call_replacement'));
    platformController.completeNext();

    expect(await calling, contains('capability unavailable'));
    expect(runtime.activeSurfaceId, 'surface_call_replacement');
  });

  test('surface validator rejects remote resource urls', () {
    final issues = SurfaceProjectValidator.diagnoseForShow(
      _project(
        id: 'surface_remote',
        html: '<main><img src="https://example.com/star.png"></main>',
        css: '@import url("https://example.com/theme.css");',
        js: 'const sprite = "https://example.com/sprite.png";',
      ),
    );

    expect(issues, contains('surface source must not reference remote URLs'));
  });

  test('webApp games use runtime first-frame admission without a Web DSL', () {
    final project = _project(
      id: 'surface_rich_web_game',
      experienceType: SurfaceExperienceType.game,
      rendering: SurfaceRendering.webApp,
      html: '''
<main id="game">
  <img src="https://example.com/sprite.png" alt="sprite">
  <section data-view="menu"><button id="play">Play</button></section>
  <section data-view="game" hidden><canvas id="stage"></canvas></section>
</main>
''',
      css: '@import url("https://example.com/game.css");',
      js: '''
async function start() {
  await Promise.resolve();
  setTimeout(() => document.querySelector('[data-view="game"]').hidden = false, 0);
}
document.querySelector('#play').addEventListener('click', start);
''',
    );

    expect(SurfaceProjectValidator.diagnoseForShow(project), isEmpty);
    expect(surfaceRequiresFirstFrameValidation(project), isTrue);
    expect(
      SurfaceProject.fromJson(project.toJson()).rendering,
      SurfaceRendering.webApp,
    );
    expect(SurfaceProjectValidator.diagnoseForPublicGame(project), isEmpty);
  });

  test('public webApp games keep normal DOM and timer APIs', () {
    final project = _project(
      id: 'surface_public_web_game',
      experienceType: SurfaceExperienceType.game,
      rendering: SurfaceRendering.webApp,
      html: '''
<main id="game" class="game-shell">
  <section data-view="menu"><button id="play" type="button">Play</button></section>
  <section data-view="game" hidden><canvas id="stage" width="320" height="480"></canvas></section>
</main>
''',
      css: '''
/* self-contained */.game-shell{display:grid;min-height:100vh;background:#10131a;color:white}
#stage{width:100%;height:100%}
''',
      js: '''
const play = document.querySelector('#play');
const stage = document.querySelector('#stage');
const context = stage.getContext('2d');
async function start() {
  await Promise.resolve();
  window.setTimeout(() => {
    document.querySelector('[data-view="game"]').hidden = false;
    window.requestAnimationFrame(() => context.fillRect(8, 8, 24, 24));
  }, 0);
}
play.addEventListener('click', (event) => {
  if (event.target === play) start();
});
''',
    );

    expect(SurfaceProjectValidator.diagnoseForPublicGame(project), isEmpty);
  });

  test('webApp source admission delegates browser operations to the host', () {
    final safe = _project(
      id: 'surface_public_local_history',
      experienceType: SurfaceExperienceType.game,
      rendering: SurfaceRendering.webApp,
      html:
          '<main><canvas id="stage" width="320" height="480"></canvas></main>',
      css: '#stage{display:block;width:100%;height:100%}',
      js: '''
let history = []
history = []
const stage = document.querySelector('#stage')
const rect = stage.getBoundingClientRect()
const board = document.getElementById('stage')
const boardRect = board.getBoundingClientRect()
const [row, column] = [1, 2]
const {width, height} = rect
const cells = [[0, 1, 2], [3, 4, 5]]
const cell = cells[row][column]
const status = `cell \${cell}`
let nextRow = 0;
let nextColumn = 0;
[nextRow, nextColumn] = [row, column];
({x: nextRow, y: nextColumn} = {x: row, y: column});
history.push({row: 1, column: 2});
history[0] = {row: nextRow, column: nextColumn};
history.pop();
stage.getContext('2d').fillRect(
  row + width,
  column + cell + status.length + height + rect.top + boardRect.top,
  8,
  8,
);
''',
    );
    final authoredSources = <String>[
      'history.pushState({}, "", "/account");',
      'window.history.back();',
      'globalThis["history"].forward();',
      'window.top.location = "/account";',
      'if (false) { const history = []; } history.pushState({}, "", "/account");',
      "const fetch = Reflect.get(globalThis, 'fetch'); fetch('https:' + '//evil.example');",
      'this.top["postMessage"]("score", "*");',
      'document.defaultView.top["postMessage"]("score", "*");',
      "const history = Reflect.get(globalThis, 'history'); history.back();",
      "let history = []; history = Reflect.get(globalThis, 'history');",
      'const rect = window; rect.top["postMessage"]("score", "*");',
      'let rect = stage.getBoundingClientRect(); rect = window; rect.top["postMessage"]("score", "*");',
      'const rect = stage.getBoundingClientRect(); { const rect = window; rect.top["postMessage"]("score", "*"); }',
      'const rect = stage.getBoundingClientRect(); const evil = {rect: window}; evil.rect.top["postMessage"]("score", "*");',
      'const view = document.defaultView; view["history"].back();',
      'let history = []; history += []; history.pushState({}, "", "/account");',
      'const history = [].foo; history.push(1);',
      'const history = [] || window.history; history.push(1);',
      'const rect = board.getBoundingClientRect(); rect.top;',
      'const stage = document.querySelector("#stage"); const rect = stage.getBoundingClientRect() || window; rect.top;',
      'const board = window; board.getBoundingClientRect = () => window; const rect = board.getBoundingClientRect(); rect.top["postMessage"]("score", "*");',
      'const board = document.querySelector("#game"); board.getBoundingClientRect = () => window; const rect = board.getBoundingClientRect(); rect.top;',
      'const board = document.querySelector("#game"); board["getBoundingClientRect"] = () => window; const rect = board.getBoundingClientRect(); rect.top;',
      'let board = document.querySelector("#game"); board = window; const rect = board.getBoundingClientRect(); rect.top;',
      'const board = document.querySelector("#game"); Object.assign(board, {getBoundingClientRect: () => window}); const rect = board.getBoundingClientRect(); rect.top;',
      'const board = document.querySelector("#game"); Object.defineProperty(board, "getBoundingClientRect", {value: () => window}); const rect = board.getBoundingClientRect(); rect.top;',
      'const board = document.querySelector("#game"); board.__defineGetter__("getBoundingClientRect", () => () => window); const rect = board.getBoundingClientRect(); rect.top;',
      'const board = document.querySelector("#game"); const rect = board?.getBoundingClientRect(); rect.top;',
      'const board = document.querySelector("#game"); function escape(board) { const rect = board.getBoundingClientRect(); rect.top["postMessage"]("score", "*"); } escape({getBoundingClientRect() { return window; }});',
      'const board = document.querySelector("#game"); ((board) => { const rect = board.getBoundingClientRect(); rect.top["postMessage"]("score", "*"); })({getBoundingClientRect() { return window; }});',
      'const board = document.querySelector("#game"); const escape = board => board.getBoundingClientRect().top;',
      'const board = document.querySelector("#game"); const helper = {escape(board) { const rect = board.getBoundingClientRect(); rect.top["postMessage"]("score", "*"); }}; helper.escape({getBoundingClientRect() { return window; }});',
      'const board = document.querySelector("#game"); try { throw {getBoundingClientRect() { return window; }}; } catch (board) { const rect = board.getBoundingClientRect(); rect.top["postMessage"]("score", "*"); }',
      'const board = document.querySelector("#game"); let rect = board.getBoundingClientRect(); [rect] = [window]; rect.top["postMessage"]("score", "*");',
      'const board = document.querySelector("#game"); let rect = board.getBoundingClientRect(); ({rect} = {rect: window}); rect.top["postMessage"]("score", "*");',
      'const board = document.querySelector("#game"); with ({board: {getBoundingClientRect() { return window; }}}) { const rect = board.getBoundingClientRect(); rect.top["postMessage"]("score", "*"); }',
      'this["parent"]["postMessage"]("score", "*");',
      'this[`parent`][`postMessage`]("score", "*");',
      'this["par" + "ent"]["post" + "Message"]("score", "*");',
      'const key = "postMessage"; parent[key]("score", "*");',
      'const root = this; const name = "fetch"; root[name]("/private");',
      'const root = window; const name = "fetch"; root[name]("/private");',
      'const name = "assign"; Object[name](document.querySelector("#game"), {});',
      'const board = document.querySelector("#game"); board[`__defineGetter__`]("getBoundingClientRect", () => () => window); const rect = board.getBoundingClientRect(); rect.top;',
      'const board = document.querySelector("#game"); const key = "getBoundingClientRect"; Object[`assign`](board, {[key]: () => window}); const rect = board.getBoundingClientRect(); rect.top;',
      'const {assign: mutate} = Object; const board = document.querySelector("#game"); mutate(board, {getBoundingClientRect: () => window}); const rect = board.getBoundingClientRect(); rect.top;',
      'const board = document.querySelector("#game"); const helper = {["escape"](board) { const rect = board["getBoundingClientRect"](); return rect.top; }}; helper.escape({getBoundingClientRect() { return window; }});',
      'const document = {querySelector: () => window}; const board = document.querySelector("#game"); const rect = board.getBoundingClientRect(); rect.top;',
      'document.querySelector = () => window;',
      'const marker = "</script>"; document.querySelector("main").textContent = marker;',
    ];

    expect(SurfaceProjectValidator.diagnoseForPublicGame(safe), isEmpty);
    for (final source in authoredSources) {
      final candidate = _project(
        id: 'surface_public_browser_history',
        experienceType: SurfaceExperienceType.game,
        rendering: SurfaceRendering.webApp,
        html: '<main id="game">Game</main>',
        js: source,
      );
      expect(
        SurfaceProjectValidator.diagnoseForPublicGame(candidate),
        isEmpty,
        reason: source,
      );
    }
  });

  test(
    'webApp admission accepts browser features without a static dialect',
    () {
      final authoredProjects = <SurfaceProject>[
        _project(
          id: 'surface_public_remote_markup',
          experienceType: SurfaceExperienceType.game,
          rendering: SurfaceRendering.webApp,
          html: '<main><img src="/sprite.png"></main>',
          js: 'document.querySelector("img");',
        ),
        _project(
          id: 'surface_public_remote_css',
          experienceType: SurfaceExperienceType.game,
          rendering: SurfaceRendering.webApp,
          html: '<main id="game">Game</main>',
          css: '#game{background-image:url(data:image/png;base64,AAAA)}',
          js: 'document.querySelector("#game");',
        ),
        _project(
          id: 'surface_public_inline_handler',
          experienceType: SurfaceExperienceType.game,
          rendering: SurfaceRendering.webApp,
          html: '<button onclick="start()">Play</button>',
          js: 'function start() {}',
        ),
        _project(
          id: 'surface_public_html_comment',
          experienceType: SurfaceExperienceType.game,
          rendering: SurfaceRendering.webApp,
          html: '<main><!-- hidden contract -->Play</main>',
          js: 'document.querySelector("main");',
        ),
        _project(
          id: 'surface_public_html_doctype',
          experienceType: SurfaceExperienceType.game,
          rendering: SurfaceRendering.webApp,
          html: '<!doctype html><main>Play</main>',
          js: 'document.querySelector("main");',
        ),
        _project(
          id: 'surface_public_invalid_control_type',
          experienceType: SurfaceExperienceType.game,
          rendering: SurfaceRendering.webApp,
          html: '<main><input type="submit" value="Play"></main>',
          js: 'document.querySelector("input");',
        ),
        _project(
          id: 'surface_public_comment_split_css',
          experienceType: SurfaceExperienceType.game,
          rendering: SurfaceRendering.webApp,
          html: '<main id="game">Game</main>',
          css: '#game{background:u/**/rl(/asset.png)}',
          js: 'document.querySelector("#game");',
        ),
        _project(
          id: 'surface_public_network_js',
          experienceType: SurfaceExperienceType.game,
          rendering: SurfaceRendering.webApp,
          html: '<main id="game">Game</main>',
          js: 'fetch("/score");',
        ),
        _project(
          id: 'surface_public_computed_network_js',
          experienceType: SurfaceExperienceType.game,
          rendering: SurfaceRendering.webApp,
          html: '<main id="game">Game</main>',
          js: 'window["fetch"]("/score");',
        ),
        _project(
          id: 'surface_public_cross_frame_js',
          experienceType: SurfaceExperienceType.game,
          rendering: SurfaceRendering.webApp,
          html: '<main id="game">Game</main>',
          js: 'window.parent.postMessage("score", "*");',
        ),
        _project(
          id: 'surface_public_navigation_js',
          experienceType: SurfaceExperienceType.game,
          rendering: SurfaceRendering.webApp,
          html: '<main id="game">Game</main>',
          js: 'window.location.assign("/login");',
        ),
        _project(
          id: 'surface_public_dynamic_code',
          experienceType: SurfaceExperienceType.game,
          rendering: SurfaceRendering.webApp,
          html: '<main id="game">Game</main>',
          js: 'const run = Function("return 1"); run();',
        ),
        _project(
          id: 'surface_public_constructor_escape',
          experienceType: SurfaceExperienceType.game,
          rendering: SurfaceRendering.webApp,
          html: '<main id="game">Game</main>',
          js: '({}).constructor.constructor("return this")();',
        ),
        _project(
          id: 'surface_public_html_mutation',
          experienceType: SurfaceExperienceType.game,
          rendering: SurfaceRendering.webApp,
          html: '<main id="game">Game</main>',
          js: 'document.body.setAttribute("onclick", "alert(1)");',
        ),
        _project(
          id: 'surface_public_storage',
          experienceType: SurfaceExperienceType.game,
          rendering: SurfaceRendering.webApp,
          html: '<main id="game">Game</main>',
          js: 'localStorage.setItem("score", "1");',
        ),
      ];

      for (final project in authoredProjects) {
        expect(
          SurfaceProjectValidator.diagnoseForPublicGame(project),
          isEmpty,
          reason: project.id,
        );
      }
    },
  );

  test('only first-frame renderers arm presentation validation', () {
    expect(
      surfaceRequiresFirstFrameValidation(
        _project(id: 'surface_dom', rendering: SurfaceRendering.dom),
      ),
      isFalse,
    );
    expect(
      surfaceRequiresFirstFrameValidation(
        _project(
          id: 'surface_worker',
          rendering: SurfaceRendering.workerCanvas,
          html: '',
          js: _workerGameJs,
        ),
      ),
      isTrue,
    );
  });

  test('public game validator requires the declarative worker contract', () {
    final safe = _project(
      id: 'surface_game',
      experienceType: SurfaceExperienceType.game,
      rendering: SurfaceRendering.workerCanvas,
      html: '',
      js: _workerGameJs,
    );
    final unsafe = _project(
      id: 'surface_window_game',
      experienceType: SurfaceExperienceType.game,
      rendering: SurfaceRendering.workerCanvas,
      html: '',
      js: 'Game.define({init(){return {};},update(){},draw(){return [];},input(){}}); fetch("/score");',
    );
    final legacyWindowGame = _project(
      id: 'surface_legacy_game',
      experienceType: SurfaceExperienceType.game,
    );

    expect(SurfaceProjectValidator.diagnoseForPublicGame(safe), isEmpty);
    expect(
      SurfaceProjectValidator.diagnoseForPublicGame(unsafe),
      contains('workerCanvas js must use only the declarative Game API'),
    );
    expect(
      SurfaceProjectValidator.diagnoseForPublicGame(legacyWindowGame),
      contains('game surfaces must use webApp or workerCanvas rendering'),
    );
    for (final blockedSource in const [
      'indexedDB.open("scores")',
      'new WebSocketStream("wss://example.invalid")',
      'navigator.serviceWorker',
      'new Notification("score")',
      'queueMicrotask(function(){})',
      'new WebAssembly.Module([])',
      'createImageBitmap(sprite)',
      'new StorageManager()',
      'scheduler.postTask(run)',
      'new MessagePort()',
    ]) {
      final blocked = _project(
        id: 'surface_blocked_worker_api',
        experienceType: SurfaceExperienceType.game,
        rendering: SurfaceRendering.workerCanvas,
        html: '',
        js: '$_workerGameJs\n$blockedSource;',
      );
      expect(
        SurfaceProjectValidator.diagnoseForPublicGame(blocked),
        contains('workerCanvas js must use only the declarative Game API'),
      );
    }
  });

  test(
    'workerCanvas allows data properties that share browser global names',
    () {
      const gomokuStateJs = r'''
Game.define({
  init() {
    return {
      history: [],
      self: {piece: 1},
      parent: {turn: 0},
      location: {row: 0, column: 0}
    };
  },
  update(state, frame) {
    const label = "history self parent location setTimeout Promise";
    const documentation = `self, setTimeout, and Promise are unavailable`;
    // history, self, parent, setTimeout, and Promise are inert text here.
    return state?.history.length + label.length + documentation.length + frame.time >= 0
        ? state
        : state;
  },
  draw(state) {
    return [{type: 'text', text: `moves ${state.history.length}`, x: 8, y: 20,
      size: 14, color: '#ffffff', align: 'left'}];
  },
  input(state, event) {
    if (event.type !== 'pointerDown') return state;
    return {
      ...state,
      history: [...state["history"], {x: event.x, y: event.y}],
      self: state.self,
      parent: state.parent,
      location: state.location
    };
  }
});
''';
      final project = _project(
        id: 'surface_gomoku_state_names',
        experienceType: SurfaceExperienceType.game,
        rendering: SurfaceRendering.workerCanvas,
        html: '',
        js: gomokuStateJs,
      );

      expect(SurfaceProjectValidator.diagnoseForShow(project), isEmpty);
      expect(SurfaceProjectValidator.diagnoseForPublicGame(project), isEmpty);
    },
  );

  test(
    'workerCanvas still rejects ambient globals, timers, and async code',
    () {
      for (final blockedSource in const [
        'history.back()',
        'self.postMessage({})',
        'parent.location = "/other"',
        'const root = true ? self : null',
        'switch (1) { case self: break; }',
        'switch (1) { case 0, self: break; }',
        'this.history.back()',
        'this["parent"].location = "/other"',
        '(this).self.postMessage({})',
        '(this)?.["self"].postMessage({})',
        '((this))["self"].postMessage({})',
        'const root = this; root.self.postMessage({})',
        'this[/self/.source]',
        r'this[`self`]',
        '({})?.constructor',
        '1..constructor',
        r'const n = `1` / (fetch("/score")) / 1',
        'const n = helper.if(true) / (fetch("x")) / 1',
        'const n = helper.return / (fetch("x")) / 1',
        'const of = 1; const n = of / (fetch("x")) / 1',
        'var yield = 2; const n = yield / (fetch("x")) / 1',
        'const n = .5.constructor',
        'setTimeout(function () {}, 1)',
        'async function moveLater() {}',
        'await moveLater()',
        'Promise.resolve(1)',
        r'`${self.postMessage({})}`',
        r'`nested ${`value ${Promise.resolve(1)}`}`',
        r'\u0073elf.postMessage({})',
        '({})["constr\\u0075ctor"]',
        '/* unterminated worker comment',
        '"unterminated worker string',
        '`unterminated worker template',
      ]) {
        final project = _project(
          id: 'surface_worker_forbidden_code',
          experienceType: SurfaceExperienceType.game,
          rendering: SurfaceRendering.workerCanvas,
          html: '',
          js: '$_workerGameJs\n$blockedSource;',
        );

        expect(
          SurfaceProjectValidator.diagnoseForShow(project),
          contains('workerCanvas js must use only the declarative Game API'),
          reason: blockedSource,
        );
      }
    },
  );

  test('workerCanvas accepts inert regular expressions and division', () {
    for (final allowedSource in const [
      'const hasHistory = /history/.test("history")',
      'if (true) /history/.test("history")',
      'if (true) {} /history/.test("history")',
      'while (false) /self/.test("self")',
      r'const quotient = `1` / 2',
      r'const label = `${{history: 1}.history}`',
      'const numericMember = 1..toString()',
    ]) {
      final project = _project(
        id: 'surface_worker_safe_literal',
        experienceType: SurfaceExperienceType.game,
        rendering: SurfaceRendering.workerCanvas,
        html: '',
        js: '$_workerGameJs\n$allowedSource;',
      );

      expect(
        SurfaceProjectValidator.diagnoseForShow(project),
        isEmpty,
        reason: allowedSource,
      );
    }
  });

  test('public utility Applets require an explicitly public-safe renderer', () {
    final safe = _project(
      id: 'surface_utility_applet',
      experienceType: SurfaceExperienceType.utility,
      rendering: SurfaceRendering.workerCanvas,
      html: '',
      js: _workerGameJs,
    );
    final localOnly = _project(
      id: 'surface_local_utility',
      experienceType: SurfaceExperienceType.utility,
    );

    expect(SurfaceProjectValidator.diagnoseForPublicApplet(safe), isEmpty);
    expect(
      SurfaceProjectValidator.diagnoseForPublicApplet(localOnly),
      contains('public Applets must use webApp or workerCanvas rendering'),
    );
    expect(
      SurfaceProjectValidator.diagnoseForPublicGame(safe),
      contains('only game surfaces can be published'),
    );
  });

  test('workerCanvas requires host-owned empty markup and style', () {
    final project = _project(
      id: 'surface_worker_markup',
      experienceType: SurfaceExperienceType.game,
      rendering: SurfaceRendering.workerCanvas,
      html: '<canvas id="game"></canvas>',
      css: 'canvas{width:100%}',
      js: _workerGameJs,
    );

    final issues = SurfaceProjectValidator.diagnoseForShow(project);

    expect(
      issues,
      contains('workerCanvas html must be empty because the host owns it'),
    );
    expect(
      issues,
      contains('workerCanvas css must be empty because the host owns layout'),
    );

    final whitespaceOnly = _project(
      id: 'surface_worker_whitespace_markup',
      experienceType: SurfaceExperienceType.game,
      rendering: SurfaceRendering.workerCanvas,
      html: ' ',
      css: '\n',
      js: _workerGameJs,
    );
    final whitespaceIssues = SurfaceProjectValidator.diagnoseForShow(
      whitespaceOnly,
    );
    expect(
      whitespaceIssues,
      contains('workerCanvas html must be empty because the host owns it'),
    );
    expect(
      whitespaceIssues,
      contains('workerCanvas css must be empty because the host owns layout'),
    );
  });

  test('surface runtime validates projects before opening', () async {
    final rt = SurfaceRuntime();
    await rt.show(_project(id: 'surface_safe'));

    await expectLater(
      rt.show(
        _project(
          id: 'surface_remote',
          html:
              '<main><script src="https://example.com/app.js"></script></main>',
        ),
      ),
      throwsA(isA<SurfaceProjectValidationException>()),
    );

    expect(rt.activeSurfaceId, 'surface_safe');
  });

  test('surface runtime wraps documents with JS diagnostics safely', () async {
    final rt = SurfaceRuntime();
    await rt.show(
      SurfaceProject(
        id: 'surface_diag',
        title: 'Diagnostics',
        kind: SurfaceKind.fullscreen,
        rendering: SurfaceRendering.dom,
        html: '<main id="app"></main>',
        css: 'body:after{content:"</style>"}',
        js: 'console.log("</script>");',
        transparent: false,
        placement: const SurfacePlacement(x: 0, y: 0, width: 1, height: 1),
        manifest: const SurfaceManifest(),
        backend: const {},
        revisions: const [],
      ),
    );

    final document = rt.document.value!;
    expect(document, contains('window.addEventListener("error"'));
    expect(document, contains('window.addEventListener("unhandledrejection"'));
    expect(document, contains('<\\/script>'));
    expect(document, contains('<\\/style>'));
    expect(document, isNot(contains('console.log("</script>");')));
  });

  test(
    'workerCanvas runs generated source only inside a locked Worker',
    () async {
      const marker = 'USER_GAME_SOURCE_MARKER';
      final rt = SurfaceRuntime();
      await rt.show(
        _project(
          id: 'surface_worker',
          experienceType: SurfaceExperienceType.game,
          rendering: SurfaceRendering.workerCanvas,
          html: '',
          css: '',
          js:
              '''
const marker = "$marker";
$_workerGameJs
''',
        ),
      );

      final document = rt.document.value!;
      final encoded = RegExp(
        r"atob\('([^']+)'\)",
      ).firstMatch(document)!.group(1)!;
      final workerSource = utf8.decode(base64Decode(encoded));

      expect(document, contains("worker-src blob:"));
      expect(document, contains("connect-src 'none'"));
      expect(document, contains('new Worker(workerUrl'));
      expect(document, contains("data-game-stopped', 'true"));
      expect(document, contains('transferControlToOffscreen'));
      expect(document, contains('applyCommands(message.commands)'));
      expect(document, contains('normalizeHostCommand(raw)'));
      expect(document, contains('Game stopped. Tap back to leave.'));
      expect(document, contains('__disposeSurfaceWorker'));
      expect(document, contains('expectedToken !== lifecycleToken'));
      expect(document, isNot(contains(marker)));
      expect(document, isNot(contains('eval(workerSource)')));
      expect(document, isNot(contains('Function(workerSource)')));
      expect(workerSource, contains(marker));
      expect(workerSource, contains('Game.define'));
      expect(workerSource, contains('function verifyGlobalLock'));
      expect(
        workerSource,
        contains('lockDescriptor(current, name, replacement)'),
      );
      expect(workerSource, contains('lockGlobals(disabledGlobals, undefined)'));
      expect(workerSource, contains('worker security boundary could not lock'));
      expect(workerSource, contains("'fetch', 'XMLHttpRequest'"));
      expect(workerSource, contains("'indexedDB', 'caches'"));
      expect(workerSource, contains("'WebSocketStream'"));
      expect(workerSource, contains("lockGlobal('console', quietConsole)"));
      expect(workerSource, contains("lockGlobal('navigator'"));
      expect(workerSource, contains("'postMessage'"));
      expect(workerSource, contains("'requestAnimationFrame'"));
      expect(workerSource, contains("'cancelAnimationFrame'"));
      expect(workerSource, contains("'requestIdleCallback'"));
      expect(workerSource, contains("'cancelIdleCallback'"));
      expect(workerSource, contains("'setImmediate'"));
      expect(workerSource, contains("'clearImmediate'"));
      expect(workerSource, contains('draw may return at most 512 commands'));
      expect(
        workerSource.indexOf('lockGlobals(disabledGlobals, undefined)'),
        lessThan(workerSource.indexOf(marker)),
      );
      expect(
        workerSource.indexOf('throw new Error'),
        lessThan(workerSource.indexOf(marker)),
      );
    },
  );

  test('workerCanvas flattens bounded legacy helper command lists', () async {
    final rt = SurfaceRuntime();
    await rt.show(
      _project(
        id: 'surface_worker_legacy_commands',
        experienceType: SurfaceExperienceType.game,
        rendering: SurfaceRendering.workerCanvas,
        html: '',
        css: '',
        js: _workerGameJs,
      ),
    );

    final encoded = RegExp(
      r"atob\('([^']+)'\)",
    ).firstMatch(rt.document.value!)!.group(1)!;
    final workerSource = utf8.decode(base64Decode(encoded));

    expect(workerSource, contains('const flattenedCommands = [];'));
    expect(
      workerSource,
      contains('nested draw command list must contain only commands'),
    );
    expect(
      workerSource,
      contains('flattenedCommands[flattenedCommands.length] = candidate;'),
    );
    expect(workerSource, contains('if (flattenedCommands.length > 512)'));
    expect(
      workerSource,
      contains("typeof raw !== 'object' || arrayIsArray(raw)"),
    );
    expect(
      workerSource.indexOf('if (flattenedCommands.length > 512)'),
      lessThan(
        workerSource.indexOf('arrayMap(flattenedCommands, normalizeCommand)'),
      ),
    );
  });

  test('workerCanvas executes nested-command compatibility limits', () async {
    final rt = SurfaceRuntime();
    await rt.show(
      _project(
        id: 'surface_worker_normalizer_execution',
        experienceType: SurfaceExperienceType.game,
        rendering: SurfaceRendering.workerCanvas,
        html: '',
        css: '',
        js: _workerGameJs,
      ),
    );
    final encoded = RegExp(
      r"atob\('([^']+)'\)",
    ).firstMatch(rt.document.value!)!.group(1)!;
    final workerSource = utf8.decode(base64Decode(encoded));
    final normalizerStart = workerSource.indexOf('function finiteNumber');
    final normalizerEnd = workerSource.indexOf('function contextMember');
    expect(normalizerStart, greaterThanOrEqualTo(0));
    expect(normalizerEnd, greaterThan(normalizerStart));
    final normalizer = workerSource.substring(normalizerStart, normalizerEnd);
    final javascript = getJavascriptRuntime(xhr: false);
    addTearDown(javascript.dispose);
    final initialized = javascript.evaluate('''
const arrayIsArray = Array.isArray;
const arrayMap = Array.prototype.map.call.bind(Array.prototype.map);
const jsonStringify = JSON.stringify;
const jsonParse = JSON.parse;
const encodeText = function (value) {
  return { length: unescape(encodeURIComponent(value)).length };
};
const numberIsFinite = Number.isFinite;
const mathMax = Math.max;
const mathMin = Math.min;
const regexpTest = RegExp.prototype.test.call.bind(RegExp.prototype.test);
const colorPattern = new RegExp('^#(?:[0-9a-f]{3}|[0-9a-f]{4}|[0-9a-f]{6}|[0-9a-f]{8})\$', 'i');
const safeString = String;
$normalizer
''');
    expect(initialized.isError, isFalse, reason: initialized.stringResult);

    final oneNested = javascript.evaluate('''
JSON.stringify(normalizeCommands([[
  {type:'clear',color:'#10131a'},
  {type:'line',x1:0,y1:0,x2:1,y2:1,color:'#ffffff'}
]]))
''');
    expect(oneNested.isError, isFalse, reason: oneNested.stringResult);
    expect(jsonDecode(oneNested.stringResult), hasLength(2));

    final helperLists = javascript.evaluate('''
JSON.stringify(normalizeCommands([
  [{type:'clear',color:'#10131a'}],
  [{type:'line',x1:0,y1:0,x2:1,y2:1,color:'#ffffff'}],
  {type:'text',x:4,y:12,text:'turn',color:'#ffffff',size:12,align:'left'}
]))
''');
    expect(helperLists.isError, isFalse, reason: helperLists.stringResult);
    expect(
      (jsonDecode(helperLists.stringResult) as List<Object?>)
          .map((item) => (item! as Map<String, Object?>)['type'])
          .toList(),
      <String>['clear', 'line', 'text'],
    );

    for (final invalidExpression in <String>[
      'normalizeCommands([null])',
      "normalizeCommands([[[{type:'clear',color:'#000'}]]])",
      "normalizeCommands([{type:'clear',color:'#000'},new Array(512).fill({type:'clear',color:'#000'})])",
    ]) {
      final result = javascript.evaluate(invalidExpression);
      expect(result.isError, isTrue, reason: invalidExpression);
    }

    final exactLimit = javascript.evaluate('''
normalizeCommands([
  {type:'clear',color:'#000'},
  new Array(511).fill({type:'clear',color:'#000'})
]).length
''');
    expect(exactLimit.isError, isFalse, reason: exactLimit.stringResult);
    expect(exactLimit.stringResult, '512');
  });

  test('workerCanvas stopped overlay follows the captured locale', () async {
    Future<String> buildDocument(AppLocale locale) async {
      return AgentPromptCatalog.runWithLocale(locale, () async {
        final rt = SurfaceRuntime();
        await rt.show(
          _project(
            id: 'surface_worker_locale_${locale.code}',
            experienceType: SurfaceExperienceType.game,
            rendering: SurfaceRendering.workerCanvas,
            html: '',
            css: '',
            js: _workerGameJs,
          ),
        );
        return rt.document.value!;
      });
    }

    expect(
      await buildDocument(AppLocale.en),
      contains('Game stopped. Tap back to leave.'),
    );
    expect(await buildDocument(AppLocale.zh), contains('游戏已停止。请点返回退出。'));
  });

  test('workerCanvas prompt requires flat drawing commands', () {
    final en = AgentPromptCatalog.text(
      'runtime.structured.rules',
      locale: AppLocale.en,
    );
    final zh = AgentPromptCatalog.text(
      'runtime.structured.rules',
      locale: AppLocale.zh,
    );

    expect(en, contains('flat array'));
    expect(en.toLowerCase(), contains('spread helper command arrays'));
    expect(zh, contains('扁平数组'));
    expect(zh, contains('辅助命令数组展开'));
  });

  test('ordinary utility surfaces keep the existing Window runtime', () async {
    final rt = SurfaceRuntime();
    await rt.show(
      _project(
        id: 'surface_utility',
        html: '<main id="utility">Utility</main>',
        js: 'window.utilityReady = true;',
      ),
    );

    final document = rt.document.value!;
    expect(document, contains('<main id="utility">Utility</main>'));
    expect(document, contains('window.utilityReady = true;'));
    expect(document, isNot(contains('maaso-agent-game')));
  });

  test('surface runtime session close does not close newer surface', () async {
    final rt = SurfaceRuntime();
    await rt.show(_project(id: 'surface_1'));
    final firstSession = rt.activeSession;

    await rt.show(_project(id: 'surface_2'));
    await rt.closeIfSession(firstSession);

    expect(rt.isVisible.value, isTrue);
    expect(rt.activeSurfaceId, 'surface_2');

    await rt.closeIfSession(rt.activeSession);
    expect(rt.isVisible.value, isFalse);
  });

  test(
    'delayed worker disposal cannot clear or terminate a newer surface',
    () async {
      final platformController = _DeferredPlatformWebViewController();
      final rt = SurfaceRuntime()
        ..attach(WebViewController.fromPlatform(platformController));
      await rt.show(
        _project(
          id: 'surface_worker_1',
          experienceType: SurfaceExperienceType.game,
          rendering: SurfaceRendering.workerCanvas,
          html: '',
          js: _workerGameJs,
        ),
      );
      final firstSession = rt.activeSession;
      final firstDocument = rt.document.value!;

      final closeFuture = rt.closeIfSession(firstSession);

      expect(rt.isVisible.value, isFalse);
      expect(platformController.scripts, hasLength(1));
      expect(
        platformController.scripts.single,
        contains('__disposeSurfaceWorker($firstSession)'),
      );
      expect(firstDocument, contains('const lifecycleToken = $firstSession;'));

      await rt.show(
        _project(
          id: 'surface_worker_2',
          experienceType: SurfaceExperienceType.game,
          rendering: SurfaceRendering.workerCanvas,
          html: '',
          js: _workerGameJs,
        ),
      );
      final secondSession = rt.activeSession;
      expect(secondSession, isNot(firstSession));
      expect(
        rt.document.value,
        contains('const lifecycleToken = $secondSession;'),
      );

      platformController.completeNext();
      await closeFuture;

      expect(rt.isVisible.value, isTrue);
      expect(rt.activeSurfaceId, 'surface_worker_2');
      expect(rt.activeSession, secondSession);
    },
  );

  test(
    'showWithSession returns its own token after being superseded',
    () async {
      final rt = _PostShowBlockingRuntime();
      final firstShow = rt.showWithSession(_project(id: 'surface_first'));
      await rt.firstShowStarted.future;

      await rt.show(_project(id: 'surface_newer'));
      final newerSession = rt.activeSession;
      rt.releaseFirstShow.complete();
      final firstSession = await firstShow;

      expect(firstSession, isNot(newerSession));
      expect(rt.activeSurfaceId, 'surface_newer');
      await rt.closeIfSession(firstSession);
      expect(rt.activeSurfaceId, 'surface_newer');
      expect(rt.isVisible.value, isTrue);
    },
  );
}

SurfaceProject _project({
  required String id,
  String html = '<canvas></canvas>',
  String css = '',
  String js = 'window.ready=true;',
  SurfaceExperienceType experienceType = SurfaceExperienceType.utility,
  SurfaceRendering rendering = SurfaceRendering.canvas,
}) {
  return SurfaceProject(
    id: id,
    title: id,
    kind: SurfaceKind.fullscreen,
    rendering: rendering,
    html: html,
    css: css,
    js: js,
    transparent: false,
    placement: const SurfacePlacement(x: 0, y: 0, width: 1, height: 1),
    manifest: const SurfaceManifest(),
    backend: const {},
    revisions: const [],
    experienceType: experienceType,
  );
}

const String _workerGameJs = '''
Game.define({
  init({width, height, dpr}) { return {x: width / 2, y: height / 2}; },
  update(state, {dt, time, width, height}) { return state; },
  draw(state, {time, width, height}) {
    return [
      {type: 'clear', color: '#10131a'},
      {type: 'circle', x: state.x, y: state.y, r: 16, fillColor: '#55ccff'}
    ];
  },
  input(state, event) { return state; }
});
''';

class _DeferredPlatformWebViewController extends PlatformWebViewController {
  _DeferredPlatformWebViewController()
    : super.implementation(const PlatformWebViewControllerCreationParams());

  final List<String> scripts = <String>[];
  final List<Completer<void>> _completions = <Completer<void>>[];

  @override
  Future<void> runJavaScript(String javaScript) {
    scripts.add(javaScript);
    final completer = Completer<void>();
    _completions.add(completer);
    return completer.future;
  }

  void completeNext() {
    _completions.removeAt(0).complete();
  }
}

class _RecordingPlatformWebViewController extends PlatformWebViewController {
  _RecordingPlatformWebViewController()
    : super.implementation(const PlatformWebViewControllerCreationParams());

  final List<String> scripts = <String>[];

  @override
  Future<void> runJavaScript(String javaScript) async {
    scripts.add(javaScript);
  }
}

class _PostShowBlockingRuntime extends SurfaceRuntime {
  final Completer<void> firstShowStarted = Completer<void>();
  final Completer<void> releaseFirstShow = Completer<void>();
  var _blockNextShow = true;

  @override
  Future<void> show(SurfaceProject project) async {
    await super.show(project);
    if (!_blockNextShow) return;
    _blockNextShow = false;
    firstShowStarted.complete();
    await releaseFirstShow.future;
  }
}

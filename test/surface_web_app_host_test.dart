import 'dart:convert';

import 'package:flutter_js/flutter_js.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:maaso/src/features/agent/application/surface/surface_manifest.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_web_app_host.dart';

const String _lifecycleNonce = '00112233445566778899aabbccddeeff';

void main() {
  group('SurfaceWebAppHost', () {
    test('builds a top-level document for rich asynchronous web apps', () {
      final document = SurfaceWebAppHost.build(
        _project(
          html: '''
<main data-view="menu">
  <img alt="ship" src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg'/%3E">
  <button id="start">Start</button>
</main>
<section data-view="game" hidden><canvas id="game"></canvas></section>
''',
          css:
              '[data-view]{min-height:100vh} button{touch-action:manipulation}',
          js: '''
async function startGame() {
  await Promise.resolve();
  document.querySelector('[data-view="menu"]').hidden = true;
  document.querySelector('[data-view="game"]').hidden = false;
}
document.querySelector('#start').addEventListener('click', startGame);
''',
        ),
        lifecycleToken: 27,
      );

      expect(document, startsWith('<!DOCTYPE html>'));
      expect(document, contains('<main data-view="menu">'));
      expect(document, contains('data:image/svg+xml'));
      expect(document, contains('<button id="start">Start</button>'));
      expect(document, contains('<section data-view="game" hidden>'));
      final authored = _authoredScript(document);
      expect(authored, contains('async function startGame()'));
      expect(authored, contains('await Promise.resolve()'));
      expect(document, isNot(contains('<iframe')));
      expect(document, isNot(contains('new Worker')));
      expect(document, isNot(contains('SurfaceLifecycle.postMessage')));
      expect(document, isNot(contains('SurfaceEvent.postMessage')));
      expect(document, contains('cryptoSource.getRandomValues'));
      expect(document, contains('SurfaceValidationLifecycle'));
      expect(document, contains('"kind":"bootstrap"'));
      expect(document, contains('hasVisibleContent()'));
      expect(document, contains("readQueryAll.call(body, '*')"));
      expect(document, contains('node.complete && node.naturalWidth > 0'));
      expect(document, contains('canvasHasPixels(node)'));
      expect(document, contains('readCanvasPixels.call(context, 0, 0'));
      expect(document, contains('scheduleInterval(reportFirstFrame, 100)'));
      expect(document, contains('new ObserverConstructor'));
      expect(
        RegExp(
          r'requestFrame\(function \(\) \{[\s\S]*requestFrame\(function \(\) \{',
        ).hasMatch(document),
        isTrue,
      );
      expect(document, contains('"status":"ready"'));
      expect(document, contains('"reason":"first_frame_ready"'));
      expect(document, contains('session: lifecycleToken'));
    });

    test(
      'mounts exact script/style source including raw delimiters and imports',
      () {
        const css =
            '@import url("https://example.org/style.css"); body::after{content:"</style>"}';
        const js = r'const marker = String.raw`</script>\n`;';
        final document = SurfaceWebAppHost.build(
          _project(css: css, js: js),
          lifecycleToken: 3,
        );
        expect(_authoredScript(document), js);
        final link = html
            .parse(document)
            .querySelector('link[rel="stylesheet"]')!;
        expect(
          Uri.parse(link.attributes['href']!).data!.contentAsString(),
          css,
        );
      },
    );

    test(
      'permits browser libraries and resources without granting native APIs',
      () {
        final source = SurfaceWebAppHost.build(
          _project(
            html:
                '<button onclick="play()">Play</button><script type="module" src="https://cdn.example/game.js"></script>',
          ),
          lifecycleToken: 4,
        );
        final policy = html
            .parse(source)
            .querySelector('meta[http-equiv="Content-Security-Policy"]')!
            .attributes['content']!;
        expect(
          policy,
          contains(
            "script-src 'unsafe-inline' 'unsafe-eval' http: https: data: blob:",
          ),
        );
        expect(
          policy,
          contains("style-src 'unsafe-inline' http: https: data: blob:"),
        );
        expect(policy, contains('connect-src http: https: ws: wss:'));
        expect(policy, contains('frame-src http: https: data: blob:'));
        expect(policy, contains('worker-src http: https: data: blob:'));
        for (final directive in ['object-src', 'base-uri', 'form-action']) {
          expect(policy, contains("$directive 'none'"));
        }
        expect(source, contains('https://cdn.example/game.js'));
        expect(source, isNot(contains('MaasoProjectBridge')));
      },
    );

    test('complete documents keep their head and body attributes', () {
      final source = SurfaceWebAppHost.build(
        _project(
          html:
              '<!doctype html><html lang="en"><head><link rel="stylesheet" href="https://cdn.example/game.css"></head>'
              '<body class="pixel" onload="start()"><button>Play</button></body></html>',
        ),
        lifecycleToken: 2,
      );
      final document = html.parse(source);
      expect(document.documentElement!.attributes['lang'], 'en');
      expect(document.body!.attributes['class'], 'pixel');
      expect(document.body!.attributes['onload'], 'start()');
      expect(
        document.head!
            .querySelector('link[href^="https:"]')!
            .attributes['href'],
        'https://cdn.example/game.css',
      );
      expect(
        source.indexOf('var lifecycleToken'),
        lessThan(
          source.indexOf(
            '<link rel="stylesheet" href="https://cdn.example/game.css"',
          ),
        ),
      );
    });

    test(
      'assembled classic files keep browser global and inline-handler semantics',
      () {
        final document = SurfaceWebAppHost.build(
          _project(
            js: '''
// First file's lexical state remains available to the following files.
var board = {score: 7};
function Actor() { return this; }
// Later file.
window.scopeProbe = {
 score: board.score,
 unboundThisUndefined: Actor() === undefined,
 topLevelThisUndefined: this === undefined,
 ambientBoard: Object.prototype.hasOwnProperty.call(window, 'board'),
 ambientActor: Object.prototype.hasOwnProperty.call(window, 'Actor')
};
''',
          ),
          lifecycleToken: 1,
        );
        final authored = _authoredScript(document);
        expect(authored, startsWith(SurfaceWebAppHost.authoredScriptPrefix));
        expect(
          '\n'.allMatches(SurfaceWebAppHost.authoredScriptPrefix).length,
          SurfaceWebAppHost.authoredScriptSourceLineOffset,
        );
        final javascript = getJavascriptRuntime(xhr: false);
        addTearDown(javascript.dispose);
        final result = javascript.evaluate(
          'var window=globalThis;$authored;JSON.stringify(window.scopeProbe);',
        );
        expect(result.isError, isFalse, reason: result.stringResult);
        expect(jsonDecode(result.stringResult), {
          'score': 7,
          'unboundThisUndefined': false,
          'topLevelThisUndefined': false,
          'ambientBoard': true,
          'ambientActor': true,
        });
      },
    );

    test('rejects a non-positive lifecycle token', () {
      expect(
        () => SurfaceWebAppHost.build(_project(), lifecycleToken: 0),
        throwsArgumentError,
      );
    });

    test('binds each load to a strict document URL', () {
      final first = SurfaceWebAppHost.documentBaseUrl(
        _project(id: 'surface_a'),
        lifecycleToken: 1,
        role: SurfaceWebAppDocumentRole.visible,
      );
      final second = SurfaceWebAppHost.documentBaseUrl(
        _project(id: 'surface_a'),
        lifecycleToken: 2,
        role: SurfaceWebAppDocumentRole.visible,
      );
      final preflight = SurfaceWebAppHost.documentBaseUrl(
        _project(id: 'surface_a'),
        lifecycleToken: 1,
        role: SurfaceWebAppDocumentRole.preflight,
      );

      expect(first, isNot(second));
      expect(Uri.parse(first).origin, Uri.parse(second).origin);
      expect(Uri.parse(first).origin, isNot(Uri.parse(preflight).origin));
      expect(Uri.parse(first).host, endsWith('.maaso-visible.invalid'));
      expect(Uri.parse(preflight).host, endsWith('.maaso-preflight.invalid'));
      expect(SurfaceWebAppHost.isDocumentBaseUrl(first), isTrue);
      expect(
        SurfaceWebAppHost.matchesDocumentBaseUrl('$first#menu', first),
        isTrue,
      );
      expect(SurfaceWebAppHost.matchesDocumentBaseUrl(second, first), isFalse);
      expect(
        SurfaceWebAppHost.isDocumentBaseUrl('https://example.com/session/1/'),
        isFalse,
      );
    });

    test('emits a syntactically valid host bootstrap', () {
      final document = SurfaceWebAppHost.build(_project(), lifecycleToken: 9);
      final hostSource = RegExp(
        r'<script>([\s\S]*?)</script>',
      ).firstMatch(document)!.group(1)!;
      final javascript = getJavascriptRuntime(xhr: false);
      addTearDown(javascript.dispose);

      final parsed = javascript.evaluate(
        'new Function(${jsonEncode(hostSource)}); true;',
      );

      expect(parsed.isError, isFalse, reason: parsed.stringResult);
    });

    test(
      'does not accept empty containers, blank canvas, or unloaded image',
      () {
        final navigations = _runVisualProbe('''
nodes.push(element('DIV'));
nodes.push(element('CANVAS', {width: 320, height: 180}));
nodes.push(element('IMG', {
  complete: false, naturalWidth: 0, naturalHeight: 0
}));
''');

        expect(
          _validationMessagesOfKind(navigations, 'bootstrap'),
          hasLength(1),
        );
        expect(_validationMessagesOfKind(navigations, 'lifecycle'), isEmpty);
      },
    );

    test('accepts a visible browser control as a painted first frame', () {
      final navigations = _runVisualProbe(
        "nodes.push(element('BUTTON', {textContent: 'Play'}));",
      );

      expect(_validationMessagesOfKind(navigations, 'bootstrap'), hasLength(1));
      expect(_validationMessagesOfKind(navigations, 'lifecycle'), hasLength(1));
    });

    test('a playable menu does not require optional companion telemetry', () {
      const visibleShell =
          "nodes.push(element('BUTTON', {textContent: 'Play'}));";
      final uninitialized = _runVisualProbe(
        visibleShell,
        requireGameState: true,
      );
      expect(
        _validationMessagesOfKind(uninitialized, 'bootstrap'),
        hasLength(1),
      );
      expect(
        _validationMessagesOfKind(uninitialized, 'lifecycle'),
        hasLength(1),
      );

      final initialized = _runVisualProbe(
        visibleShell,
        requireGameState: true,
        deferFrames: true,
        afterLoadSource:
            "window.Surface.emit('game.state',{revision:0,state:{phase:'playing',score:0}});",
      );
      expect(_validationMessagesOfKind(initialized, 'lifecycle'), hasLength(1));

      final blank = _runVisualProbe(
        "nodes.push(element('CANVAS', {width:320,height:180}));",
        requireGameState: true,
        authoredSource:
            "window.Surface.emit('game.state',{revision:1,state:{phase:'playing'}});",
      );
      expect(_validationMessagesOfKind(blank, 'lifecycle'), isEmpty);
    });

    test('optional observations do not decide visual admission', () {
      const visibleShell =
          "nodes.push(element('BUTTON', {textContent: 'Play'}));";
      const invalid = [
        '{state:{score:0}}',
        '{revision:-1,state:{score:0}}',
        '{revision:0.5,state:{score:0}}',
        '{revision:0,state:[]}',
        '{revision:0,state:{}}',
        '{revision:0,state:{score:0},event:{type:"ready"}}',
        '{revision:0,state:{label:"x".repeat(513)}}',
        '{revision:0,state:{values:Array.from({length:513},()=>0)}}',
        '{revision:0,state:{values:Array.from({length:20},()=>"x".repeat(512))}}',
        '{revision:0,state:{a:{b:{c:{d:{e:{f:{g:{h:{i:1}}}}}}}}}}',
      ];
      for (final payload in invalid) {
        final messages = _runVisualProbe(
          visibleShell,
          requireGameState: true,
          authoredSource: "window.Surface.emit('game.state',$payload);",
        );
        expect(
          _validationMessagesOfKind(messages, 'lifecycle'),
          hasLength(1),
          reason: payload,
        );
      }
      final eventOnly = _runVisualProbe(
        visibleShell,
        requireGameState: true,
        authoredSource:
            "window.Surface.emit('game.event',{revision:0,state:{score:0},event:{type:'game.ready',summary:'Ready'}});",
      );
      expect(_validationMessagesOfKind(eventOnly, 'lifecycle'), hasLength(1));
    });

    test('ordinary Applets retain their existing paint admission', () {
      final document = SurfaceWebAppHost.build(
        _project(
          rendering: SurfaceRendering.webApp,
          experienceType: SurfaceExperienceType.utility,
          manifest: const SurfaceManifest(
            events: [
              SurfaceEntry('game.state', {
                'revision': 'number',
                'state': 'object',
              }),
            ],
          ),
        ),
        lifecycleToken: 1,
      );
      expect(document, isNot(contains('requireInitialGameState')));
    });

    for (final event in <String>['error', 'unhandledrejection']) {
      test('rejects a visible menu when startup has an uncaught $event', () {
        final messages = _runVisualProbe(
          "nodes.push(element('BUTTON', {textContent: 'Play'}));",
          authoredSource:
              '''
windowEvents['$event'].forEach(function (callback) {
  callback({target: window, message: 'private authored source',
    reason: 'private rejection detail'});
});
''',
        );
        final terminal = _validationMessagesOfKind(
          messages,
          'lifecycle',
        ).single;
        expect(terminal['status'], 'fatal');
        expect(terminal['reason'], 'runtime_failed');
        expect(
          terminal['nonce'],
          _validationMessagesOfKind(messages, 'bootstrap').single['nonce'],
        );
        expect(
          terminal.keys,
          unorderedEquals(<String>[
            'version',
            'session',
            'kind',
            'status',
            'reason',
            'nonce',
          ]),
        );
        expect(
          jsonEncode(messages.validationMessages),
          isNot(contains('private')),
        );
      });
    }

    test('startup error wins over a queued visual-ready frame', () {
      final messages = _runVisualProbe(
        "nodes.push(element('BUTTON', {textContent: 'Play'}));",
        deferFrames: true,
        afterLoadSource: '''
windowEvents.error.forEach(function (callback) {callback({target: window});});
windowEvents.error.forEach(function (callback) {callback({target: window});});
''',
      );
      expect(
        _validationMessagesOfKind(messages, 'lifecycle').single['status'],
        'fatal',
      );
    });

    test('reports a current runtime error after a painted first frame', () {
      final messages = _runVisualProbe(
        "nodes.push(element('BUTTON', {textContent: 'Play'}));",
        afterLoadSource: '''
windowEvents.error.forEach(function (callback) {callback({target: window});});
''',
      );
      expect(
        _validationMessagesOfKind(
          messages,
          'lifecycle',
        ).map((message) => message['status']),
        <String>['ready', 'fatal'],
      );
    });

    test('rejects painted content outside the visible viewport', () {
      final navigations = _runVisualProbe('''
nodes.push(element('DIV', {
  rect: {
    width: 100, height: 40,
    left: -500, top: 20, right: -400, bottom: 60
  },
  style: Object.assign(defaultStyle(), {backgroundColor: 'rgb(255, 0, 0)'})
}));
''');

      expect(_validationMessagesOfKind(navigations, 'bootstrap'), hasLength(1));
      expect(_validationMessagesOfKind(navigations, 'lifecycle'), isEmpty);
    });

    test('rejects controls removed from the paint hit-test by clipping', () {
      final messages = _runVisualProbe('''
nodes.push(element('BUTTON', {
  textContent: 'Play', hitTestVisible: false,
  style: Object.assign(defaultStyle(), {clipPath: 'inset(100%)'})
}));
''');

      expect(_validationMessagesOfKind(messages, 'bootstrap'), hasLength(1));
      expect(_validationMessagesOfKind(messages, 'lifecycle'), isEmpty);
    });

    test('rejects controls whose text and chrome are fully transparent', () {
      final messages = _runVisualProbe('''
nodes.push(element('BUTTON', {
  textContent: 'Play',
  style: Object.assign(defaultStyle(), {
    color: 'transparent', backgroundColor: 'transparent',
    backgroundImage: 'none', borderTopStyle: 'none',
    borderRightStyle: 'none', borderBottomStyle: 'none',
    borderLeftStyle: 'none'
  })
}));
''');

      expect(_validationMessagesOfKind(messages, 'bootstrap'), hasLength(1));
      expect(_validationMessagesOfKind(messages, 'lifecycle'), isEmpty);
    });

    test('rejects transparent gradients and borders as painted content', () {
      final messages = _runVisualProbe('''
nodes.push(element('DIV', {
  style: Object.assign(defaultStyle(), {
    backgroundImage: 'linear-gradient(transparent, rgba(0, 0, 0, 0))',
    borderTopWidth: '2px', borderTopStyle: 'solid',
    borderTopColor: 'rgba(0, 0, 0, 0)'
  })
}));
''');

      expect(_validationMessagesOfKind(messages, 'bootstrap'), hasLength(1));
      expect(_validationMessagesOfKind(messages, 'lifecycle'), isEmpty);
    });

    test('waits for CSS background URLs to finish loading', () {
      const nodes = '''
nodes.push(element('DIV', {
  style: Object.assign(defaultStyle(), {
    backgroundImage: 'url("https://missing.invalid/game.png")'
  })
}));
''';

      final pending = _runVisualProbe(nodes, imageState: 'pending');
      final failed = _runVisualProbe(nodes, imageState: 'failed');

      expect(_validationMessagesOfKind(pending, 'bootstrap'), hasLength(1));
      expect(_validationMessagesOfKind(pending, 'lifecycle'), isEmpty);
      expect(_validationMessagesOfKind(failed, 'bootstrap'), hasLength(1));
      expect(_validationMessagesOfKind(failed, 'lifecycle'), isEmpty);
    });

    test('accepts a CSS background URL only after it has loaded', () {
      final messages = _runVisualProbe('''
nodes.push(element('DIV', {
  style: Object.assign(defaultStyle(), {
    backgroundImage: 'url("data:image/png;base64,painted")'
  })
}));
''', imageState: 'loaded');

      expect(_validationMessagesOfKind(messages, 'bootstrap'), hasLength(1));
      expect(_validationMessagesOfKind(messages, 'lifecycle'), hasLength(1));
    });

    test(
      'rejects transparent text fill, shadow, pseudo text, and body text',
      () {
        final messages = _runVisualProbe(
          '''
nodes.push(element('BUTTON', {
  textContent: 'Play',
  style: Object.assign(defaultStyle(), {
    color: 'rgb(0, 0, 0)', webkitTextFillColor: 'transparent'
  })
}));
nodes.push(element('DIV', {
  style: Object.assign(defaultStyle(), {
    boxShadow: 'rgba(0, 0, 0, 0) 0px 2px 8px'
  })
}));
nodes.push(element('DIV', {
  beforeStyle: Object.assign(defaultStyle(), {
    content: '"Hidden"', color: 'transparent'
  })
}));
''',
          bodySource: '''
body.style = Object.assign(defaultStyle(), {color: 'transparent'});
body.firstChild = {nodeType: 3, textContent: 'Hidden', nextSibling: null};
''',
        );

        expect(_validationMessagesOfKind(messages, 'bootstrap'), hasLength(1));
        expect(_validationMessagesOfKind(messages, 'lifecycle'), isEmpty);
      },
    );

    test('rejects a fully transparent mask but accepts an opaque mask', () {
      final hidden = _runVisualProbe('''
nodes.push(element('DIV', {
  style: Object.assign(defaultStyle(), {
    backgroundColor: 'rgb(255, 0, 0)',
    maskImage: 'linear-gradient(transparent, rgba(0, 0, 0, 0))'
  })
}));
''');
      final visible = _runVisualProbe('''
nodes.push(element('DIV', {
  style: Object.assign(defaultStyle(), {
    backgroundColor: 'rgb(255, 0, 0)',
    webkitMaskImage: 'linear-gradient(rgb(0, 0, 0), transparent)'
  })
}));
''');

      expect(_validationMessagesOfKind(hidden, 'lifecycle'), isEmpty);
      expect(_validationMessagesOfKind(visible, 'lifecycle'), hasLength(1));
    });

    test('admits DOM-ready content without waiting for window load', () {
      const nodes = "nodes.push(element('BUTTON', {textContent: 'Play'}));";

      final messages = _runVisualProbe(nodes);

      expect(_validationMessagesOfKind(messages, 'lifecycle'), hasLength(1));
    });

    test('prototype hooks cannot observe the lifecycle nonce', () {
      final messages = _runVisualProbe(
        "nodes.push(element('BUTTON', {textContent: 'Play'}));",
        authoredSource: '''
Object.prototype.toJSON = function () {
  if (this && typeof this.nonce === 'string') {
    leakedLifecycleNonce = this.nonce;
  }
  return this;
};
''',
      );

      expect(messages.leakedLifecycleNonce, isNull);
      expect(_validationMessagesOfKind(messages, 'lifecycle'), hasLength(1));
    });

    test(
      'standard polyfills remain available and captured probes still work',
      () {
        final messages = _runVisualProbe(
          "nodes.push(element('BUTTON', {textContent: 'Play'}));",
          authoredSource: '''
Array.prototype.gameDouble = function () { return this.map(x => x * 2); };
if ([1,2].gameDouble().join(',') !== '2,4') throw Error('polyfill failed');
delete Array.prototype.gameDouble;
function Actor() { this.score = 1; }
Actor.prototype.step = function () { this.score++; };
var actor = new Actor(); actor.step();
if (actor.score !== 2) throw Error('prototype method failed');
window.getComputedStyle = function () { throw Error('replaced style probe'); };
document.body.querySelectorAll = function () { throw Error('replaced DOM query'); };
''',
        );
        expect(_validationMessagesOfKind(messages, 'lifecycle'), hasLength(1));
      },
    );
  });

  group('Surface webApp bridges', () {
    test('strictly parses only fixed runtime fatal lifecycle messages', () {
      final payload = <String, Object?>{
        'version': 1,
        'session': 41,
        'kind': 'lifecycle',
        'status': 'fatal',
        'reason': 'runtime_failed',
        'nonce': _lifecycleNonce,
      };
      final message = SurfaceWebAppLifecycleMessage.tryParse(
        jsonEncode(payload),
      );
      expect(message, isNotNull);
      expect(message!.kind.name, 'fatal');
      expect(jsonDecode(message.gatePayloadJson), <String, Object?>{
        'version': 1,
        'session': 41,
        'status': 'fatal',
        'reason': 'runtime_failed',
      });
      for (final changed in <Map<String, Object?>>[
        {...payload, 'reason': 'raw error'},
        {...payload, 'error': 'raw source'},
        {...payload, 'status': 'ready'},
        {...payload, 'nonce': 'invalid'},
      ]) {
        expect(
          SurfaceWebAppLifecycleMessage.tryParse(jsonEncode(changed)),
          isNull,
        );
      }
    });

    test('strictly parses first-frame lifecycle channel messages', () {
      final payload = <String, Object?>{
        'version': 1,
        'session': 41,
        'kind': 'lifecycle',
        'status': 'ready',
        'reason': 'first_frame_ready',
        'nonce': _lifecycleNonce,
      };

      final message = SurfaceWebAppLifecycleMessage.tryParse(
        jsonEncode(payload),
      );

      expect(message, isNotNull);
      expect(message!.kind, SurfaceWebAppLifecycleKind.ready);
      expect(message.session, 41);
      expect(message.nonce, _lifecycleNonce);
      expect(jsonDecode(message.gatePayloadJson), <String, Object?>{
        'version': 1,
        'session': 41,
        'status': 'ready',
        'reason': 'first_frame_ready',
      });
    });

    test('strictly parses lifecycle bootstrap channel messages', () {
      final payload = <String, Object?>{
        'version': 1,
        'session': 40,
        'kind': 'bootstrap',
        'nonce': _lifecycleNonce,
      };

      final message = SurfaceWebAppLifecycleMessage.tryParse(
        jsonEncode(payload),
      );

      expect(message, isNotNull);
      expect(message!.kind, SurfaceWebAppLifecycleKind.bootstrap);
      expect(message.session, 40);
      expect(message.nonce, _lifecycleNonce);
    });

    test('strictly parses a bounded event navigation', () {
      final payload = <String, Object?>{
        'version': 1,
        'session': 42,
        'event': 'game.round_complete',
        'data': <String, Object?>{
          'score': 12,
          'players': <String>['maaso', 'friend'],
        },
      };

      final message = SurfaceWebAppNavigationMessage.tryParse(
        _navigationUrl(SurfaceWebAppNavigationKind.event, payload),
      );

      expect(message, isNotNull);
      expect(message!.kind, SurfaceWebAppNavigationKind.event);
      expect(message.payload, payload);
      expect(message.session, 42);
      expect(message.event, 'game.round_complete');
      expect(message.data, payload['data']);
    });

    test('rejects malformed lifecycle and event messages', () {
      final event = <String, Object?>{
        'version': 1,
        'session': 8,
        'event': 'game.ready',
        'data': null,
      };
      final valid = _navigationUrl(SurfaceWebAppNavigationKind.event, event);
      final encodedPayload = Uri.parse(valid).queryParameters['payload']!;

      expect(
        SurfaceWebAppNavigationMessage.tryParse(
          valid.replaceFirst('maaso-surface:', 'https:'),
        ),
        isNull,
      );
      expect(
        SurfaceWebAppNavigationMessage.tryParse('$valid#fragment'),
        isNull,
      );
      expect(
        SurfaceWebAppNavigationMessage.tryParse(
          'maaso-surface://event/path?payload=$encodedPayload',
        ),
        isNull,
      );
      expect(
        SurfaceWebAppNavigationMessage.tryParse(
          '$valid&payload=$encodedPayload',
        ),
        isNull,
      );
      expect(
        SurfaceWebAppLifecycleMessage.tryParse(
          jsonEncode(<String, Object?>{
            'version': 1,
            'session': 8,
            'kind': 'lifecycle',
            'status': 'ready',
            'reason': 'first_frame_ready',
            'nonce': 'predictable',
          }),
        ),
        isNull,
      );
      expect(
        SurfaceWebAppLifecycleMessage.tryParse(
          jsonEncode(<String, Object?>{
            'version': 1,
            'session': 8,
            'kind': 'lifecycle',
            'status': 'fatal',
            'reason': 'first_frame_ready',
            'nonce': _lifecycleNonce,
          }),
        ),
        isNull,
      );
      expect(
        SurfaceWebAppNavigationMessage.tryParse(
          _navigationUrl(SurfaceWebAppNavigationKind.event, <String, Object?>{
            'version': 1,
            'session': 8,
            'event': '../invalid',
            'data': null,
          }),
        ),
        isNull,
      );

      final oversized = <String, Object?>{
        'version': 1,
        'session': 8,
        'event': 'large_payload',
        'data': 'x' * SurfaceWebAppNavigationMessage.maximumPayloadBytes,
      };
      expect(
        SurfaceWebAppNavigationMessage.tryParse(
          _navigationUrl(SurfaceWebAppNavigationKind.event, oversized),
        ),
        isNull,
      );
    });
  });
}

({List<Map<String, dynamic>> validationMessages, String? leakedLifecycleNonce})
_runVisualProbe(
  String nodesSource, {
  String authoredSource = '',
  String bodySource = '',
  String imageState = 'unavailable',
  bool deferFrames = false,
  String afterLoadSource = '',
  bool requireGameState = false,
}) {
  final document = SurfaceWebAppHost.build(
    _project(
      rendering: SurfaceRendering.webApp,
      manifest: requireGameState
          ? const SurfaceManifest(
              events: [
                SurfaceEntry('game.state', {
                  'revision': 'number',
                  'state': 'object',
                }),
              ],
            )
          : const SurfaceManifest(),
    ),
    lifecycleToken: 12,
  );
  final hostSource = RegExp(
    r'<script>([\s\S]*?)</script>',
  ).firstMatch(document)!.group(1)!;
  final javascript = getJavascriptRuntime(xhr: false);
  addTearDown(javascript.dispose);
  final imageConstructor = switch (imageState) {
    'loaded' =>
      '''function () {
      this.complete = false;
      this.naturalWidth = 0;
      this.naturalHeight = 0;
      Object.defineProperty(this, 'src', {
        set: function () {
          this.complete = true;
          this.naturalWidth = 64;
          this.naturalHeight = 64;
          if (typeof this.onload === 'function') this.onload();
        }
      });
    }''',
    'failed' =>
      '''function () {
      this.complete = false;
      this.naturalWidth = 0;
      this.naturalHeight = 0;
      Object.defineProperty(this, 'src', {
        set: function () {
          this.complete = true;
          if (typeof this.onerror === 'function') this.onerror();
        }
      });
    }''',
    'pending' =>
      '''function () {
      this.complete = false;
      this.naturalWidth = 0;
      this.naturalHeight = 0;
    }''',
    _ => 'null',
  };
  final evaluated = javascript.evaluate('''
var navigations = [];
var validationMessages = [];
var leakedLifecycleNonce = null;
var domContentLoadedCallback = null;
var windowEvents = {};
var pendingFrames = [];
function defaultStyle() {
  return {
    display: 'block', visibility: 'visible', opacity: '1',
    contentVisibility: 'visible', filter: 'none', overflow: 'visible',
    overflowX: 'visible', overflowY: 'visible', clipPath: 'none',
    color: 'rgb(0, 0, 0)',
    webkitTextFillColor: 'currentcolor', webkitTextStrokeWidth: '0px',
    webkitTextStrokeColor: 'currentcolor',
    backgroundColor: 'rgba(0, 0, 0, 0)', backgroundImage: 'none',
    boxShadow: 'none', borderTopWidth: '0px', borderRightWidth: '0px',
    borderBottomWidth: '0px', borderLeftWidth: '0px',
    borderTopStyle: 'none', borderRightStyle: 'none',
    borderBottomStyle: 'none', borderLeftStyle: 'none',
    borderTopColor: 'transparent', borderRightColor: 'transparent',
    borderBottomColor: 'transparent', borderLeftColor: 'transparent',
    maskImage: 'none', webkitMaskImage: 'none',
    content: 'normal'
  };
}
function Element() {}
Element.prototype.getBoundingClientRect = function () { return this.rect; };
Element.prototype.contains = function (other) {
  for (var current = other; current !== null; current = current.parentElement) {
    if (current === this) return true;
  }
  return false;
};
Element.prototype.querySelectorAll = function () {
  return this === body ? nodes : [];
};
Element.prototype.querySelector = function () { return null; };
function element(tag, overrides) {
  return Object.assign({
    nodeType: 1, tagName: tag, parentElement: null,
    rect: {
      width: 100, height: 40, left: 0, top: 0, right: 100, bottom: 40
    },
    style: defaultStyle(),
    hitTestVisible: true,
    textContent: '', controls: false, querySelector: function () { return null; },
    querySelectorAll: function () { return []; }
  }, overrides || {});
}
var body = element('BODY', {
  rect: {
    width: 390, height: 844, left: 0, top: 0, right: 390, bottom: 844
  },
  clientWidth: 390,
  clientHeight: 844
});
var nodes = [];
$nodesSource
for (var nodeIndex = 0; nodeIndex < nodes.length; nodeIndex += 1) {
  nodes[nodeIndex].parentElement = body;
}
body.querySelectorAll = function () { return nodes; };
body.firstChild = null;
$bodySource
var window = {
  Element: Element,
  MutationObserver: MutationObserver,
  innerWidth: 390,
  innerHeight: 844,
  Image: $imageConstructor,
  requestAnimationFrame: function (callback) {
    if ($deferFrames) pendingFrames.push(callback); else callback();
  },
  setTimeout: function (callback) { callback(); return 1; },
  setInterval: function () { return 1; },
  clearInterval: function () {},
  getComputedStyle: function (target, pseudo) {
    if (pseudo === '::before') return target.beforeStyle || defaultStyle();
    if (pseudo === '::after') return target.afterStyle || defaultStyle();
    return target.style;
  },
  encodeURIComponent: encodeURIComponent,
  btoa: function (value) { return value; },
  unescape: function (value) { return value; },
  crypto: {
    getRandomValues: function (bytes) {
      for (var byteIndex = 0; byteIndex < bytes.length; byteIndex += 1) {
        bytes[byteIndex] = byteIndex + 1;
      }
      return bytes;
    }
  },
  addEventListener: function (event, callback) {
    (windowEvents[event] || (windowEvents[event] = [])).push(callback);
  },
  SurfaceValidationLifecycle: {
    postMessage: function (message) { validationMessages.push(message); }
  },
  location: {
    assign: function (value) { navigations.push(value); }
  }
};
var document = {
  body: body,
  documentElement: body,
  readyState: 'loading',
  addEventListener: function (event, callback) {
    if (event === 'DOMContentLoaded') domContentLoadedCallback = callback;
  },
  elementsFromPoint: function (x, y) {
    var hits = [];
    for (var hitIndex = 0; hitIndex < nodes.length; hitIndex += 1) {
      var candidate = nodes[hitIndex];
      var rect = candidate.rect;
      if (candidate.hitTestVisible !== false &&
          x >= rect.left && x <= rect.right &&
          y >= rect.top && y <= rect.bottom) {
        hits.push(candidate);
      }
    }
    hits.push(body);
    return hits.reverse();
  },
  createElement: function () {
    return {
      width: 0, height: 0,
      getContext: function () {
        return {
          drawImage: function () {},
          getImageData: function () {
            return {data: new Uint8ClampedArray(32 * 32 * 4)};
          }
        };
      }
    };
  }
};
function MutationObserver() {}
MutationObserver.prototype.observe = function () {};
MutationObserver.prototype.disconnect = function () {};
$hostSource
${authoredSource.isEmpty ? '' : authoredSource}
document.readyState = 'interactive';
if (domContentLoadedCallback !== null) {
  domContentLoadedCallback();
}
$afterLoadSource
while (pendingFrames.length > 0) pendingFrames.shift()();
delete Object.prototype.toJSON;
JSON.stringify({
  validationMessages: validationMessages,
  leakedLifecycleNonce: leakedLifecycleNonce
});
''');
  expect(evaluated.isError, isFalse, reason: evaluated.stringResult);
  final decoded = jsonDecode(evaluated.stringResult) as Map<String, dynamic>;
  return (
    validationMessages: (decoded['validationMessages'] as List<dynamic>)
        .map(
          (message) => (jsonDecode(message as String) as Map<String, dynamic>),
        )
        .toList(growable: false),
    leakedLifecycleNonce: decoded['leakedLifecycleNonce'] as String?,
  );
}

Iterable<Map<String, dynamic>> _validationMessagesOfKind(
  ({
    List<Map<String, dynamic>> validationMessages,
    String? leakedLifecycleNonce,
  })
  messages,
  String kind,
) => messages.validationMessages.where((message) => message['kind'] == kind);

SurfaceProject _project({
  String id = 'surface_web_app',
  String html = '<main><button>Play</button></main>',
  String css = '',
  String js = '',
  SurfaceRendering rendering = SurfaceRendering.dom,
  SurfaceExperienceType experienceType = SurfaceExperienceType.game,
  SurfaceManifest manifest = const SurfaceManifest(),
}) {
  return SurfaceProject(
    id: id,
    title: 'Web App Game',
    kind: SurfaceKind.fullscreen,
    rendering: rendering,
    html: html,
    css: css,
    js: js,
    transparent: false,
    placement: const SurfacePlacement(x: 0, y: 0, width: 1, height: 1),
    manifest: manifest,
    backend: const <String, Object?>{},
    revisions: const <SurfaceRevision>[],
    experienceType: experienceType,
  );
}

String _navigationUrl(
  SurfaceWebAppNavigationKind kind,
  Map<String, Object?> payload,
) {
  final encoded = base64UrlEncode(
    utf8.encode(jsonEncode(payload)),
  ).replaceAll('=', '');
  return '${SurfaceWebAppNavigationMessage.navigationScheme}://'
      '${kind.name}?payload=$encoded';
}

String _authoredScript(String document) => Uri.parse(
  html.parse(document).querySelectorAll('script').last.attributes['src']!,
).data!.contentAsString();

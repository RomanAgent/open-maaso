import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';

SurfaceProject _web({
  String html = '',
  String css = '',
  String js = '',
  String experienceType = 'game',
  Map<String, Object?> manifest = const {'actions': [], 'events': []},
}) => SurfaceProject.fromJson({
  'id': 'free-web-entry',
  'title': 'A freely authored project',
  'kind': 'fullscreen',
  'rendering': 'webApp',
  'experienceType': experienceType,
  'html': html,
  'css': css,
  'js': js,
  'manifest': manifest,
});

void main() {
  test('HTML-only apps can own their scripts, styles, menus and controls', () {
    final project = _web(
      html: r'''
<!doctype html><html><head>
  <link rel="stylesheet" href="https://example.com/theme.css">
  <style>@layer base { body { margin: 0 } }</style>
</head><body>
  <form id="menu"><label>Difficulty <input type="range"></label>
    <button type="button" onclick="start()">Play</button></form>
  <canvas id="game" hidden></canvas>
  <script>
    function start() {
      document.querySelector('#menu').hidden = true;
      document.querySelector('#game').hidden = false;
    }
  </script>
  <script type="module" src="https://example.com/game.js"></script>
</body></html>
''',
    );
    expect(SurfaceProjectValidator.diagnoseForShow(project), isEmpty);
    expect(SurfaceProjectValidator.diagnoseForPublicGame(project), isEmpty);
  });

  test(
    'JavaScript-only entry may construct its entire DOM and use libraries',
    () {
      final project = _web(
        js: r'''
import {start} from 'https://example.com/game-module.js';
const root = document.createElement('main');
root.innerHTML = '<button>Play</button><canvas></canvas>';
document.body.append(root);
root.querySelector('button').addEventListener('click', () => start(root));
''',
      );
      expect(SurfaceProjectValidator.diagnoseForShow(project), isEmpty);
      expect(SurfaceProjectValidator.diagnoseForPublicGame(project), isEmpty);
    },
  );

  test(
    'arbitrary CSS, fonts and imagery are admitted without a style subset',
    () {
      final project = _web(
        html:
            '<main><img src="https://example.com/hero.png"><p>Play</p></main>',
        css: r'''
@import url('https://example.com/theme.css');
@font-face { font-family: game; src: url('https://example.com/game.woff2'); }
@supports (container-type: inline-size) { main { container-type: inline-size; } }
@container (width > 300px) { main { display: grid; } }
main::before { content: 'https://example.com is a resource'; }
main { background: url(data:image/svg+xml;base64,PHN2Zy8+); mask: url(#shape); }
p { --caption: "</style>"; font: 1rem game; }
''',
      );
      expect(SurfaceProjectValidator.diagnoseForPublicGame(project), isEmpty);
    },
  );

  test(
    'empty entries remain incomplete without requiring both HTML and JS',
    () {
      for (final project in [
        _web(),
        _web(html: '  ', js: '\n'),
        _web(css: 'body{}'),
      ]) {
        expect(SurfaceProjectValidator.diagnoseForShow(project), [
          'webApp must contain authored HTML or JavaScript',
        ]);
        expect(SurfaceProjectValidator.diagnoseForPublicGame(project), [
          'webApp must contain authored HTML or JavaScript',
        ]);
      }
      expect(
        SurfaceProjectValidator.diagnoseForPublicApplet(
          _web(html: '<h1>Notebook</h1>', experienceType: 'utility'),
        ),
        isEmpty,
      );
    },
  );

  test(
    'source byte storage boundary remains separate from authoring syntax',
    () {
      final limit = SurfaceProjectValidator.maximumPublicSourceBytes;
      expect(
        SurfaceProjectValidator.diagnoseForPublicGame(_web(js: ';' * limit)),
        isEmpty,
      );
      expect(
        SurfaceProjectValidator.diagnoseForPublicGame(
          _web(js: ';' * (limit + 1)),
        ),
        ['public Applet source is too large'],
      );
      expect(
        SurfaceProjectValidator.diagnoseForPublicGame(
          _web(js: '界' * (limit ~/ 3 + 1)),
        ),
        ['public Applet source is too large'],
      );
    },
  );

  test('browser freedom does not grant native manifest authority', () {
    final project = _web(
      html: '<main>App</main>',
      manifest: {
        'schemaVersion': 2,
        'events': [],
        'actions': [
          {
            'name': 'restart',
            'schema': {'type': 'object'},
            'risk': 'nativeAdmin',
            'consequencePolicy': 'reversible',
          },
        ],
      },
    );
    expect(
      SurfaceProjectValidator.diagnoseForPublicApplet(project),
      contains('surface.manifest.actions[0].risk_invalid'),
    );
    expect(
      () => SurfaceProjectValidator.validateForPublicApplet(project),
      throwsA(isA<SurfaceProjectValidationException>()),
    );
  });

  test(
    'workerCanvas retains its distinct declarative API and source ownership',
    () {
      final worker = SurfaceProject.fromJson({
        ..._web(
          html: '<main>App</main>',
          css: 'body{}',
          js: 'fetch("/state");',
        ).toJson(),
        'rendering': 'workerCanvas',
      });
      final issues = SurfaceProjectValidator.diagnoseForPublicGame(worker);
      expect(
        issues,
        contains('workerCanvas html must be empty because the host owns it'),
      );
      expect(
        issues,
        contains('workerCanvas css must be empty because the host owns layout'),
      );
      expect(
        issues,
        contains(
          'workerCanvas js must call Game.define with init, update, draw, and input',
        ),
      );
      expect(
        issues,
        contains('workerCanvas js must use only the declarative Game API'),
      );
    },
  );
}

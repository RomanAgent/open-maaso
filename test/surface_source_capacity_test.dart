import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/surface/surface_manifest.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';

const _html = '<main><button id="play">Play</button></main>';
const _js = 'document.getElementById("play").addEventListener("click",()=>{});';

SurfaceProject _project(String html, String css, String js) => SurfaceProject(
  id: 'large-generated-game',
  title: 'Complete project',
  kind: SurfaceKind.floatingCanvas,
  experienceType: SurfaceExperienceType.game,
  rendering: SurfaceRendering.webApp,
  html: html,
  css: css,
  js: js,
  transparent: false,
  placement: const SurfacePlacement(x: 0, y: 0, width: 1, height: 1),
  manifest: const SurfaceManifest(),
  backend: const {},
  revisions: const [],
);

void main() {
  test('complete sources may exceed every legacy field limit', () {
    final padding = 'a' * (400 * 1024);
    final project = _project(
      '$_html<div>$padding</div>',
      'button{min-height:48px}/*$padding*/',
      '$_js/*$padding*/',
    );
    expect(SurfaceProjectValidator.diagnoseForPublicGame(project), isEmpty);
  });

  test(
    'the project capacity is aggregate UTF-8 bytes, with inclusive limit',
    () {
      final available =
          SurfaceProjectValidator.maximumPublicSourceBytes -
          utf8.encode(_html).length -
          utf8.encode(_js).length -
          4;
      final padding = 'a' * available;
      final atLimit = _project(_html, '', '$_js/*$padding*/');
      expect(SurfaceProjectValidator.diagnoseForPublicGame(atLimit), isEmpty);
      final overLimit = _project(_html, '', '$_js/*$padding🕹*/');
      expect(
        SurfaceProjectValidator.diagnoseForPublicGame(overLimit),
        contains('public Applet source is too large'),
      );
    },
  );

  test('large projects do not regain a retired browser API restriction', () {
    final project = _project(
      _html,
      '',
      '$_js/*${'a' * (400 * 1024)}*/fetch("https://example.com");',
    );
    expect(SurfaceProjectValidator.diagnoseForPublicGame(project), isEmpty);
  });
}

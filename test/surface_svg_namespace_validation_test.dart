import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';

const _namespace = 'http://www.w3.org/2000/svg';

SurfaceProject _project(String js, {String? html}) => SurfaceProject.fromJson({
  'id': 'namespace-boundary',
  'title': 'Web shape',
  'kind': 'fullscreen',
  'rendering': 'webApp',
  'experienceType': 'game',
  'html': html ?? '<main id="stage">Web shape</main>',
  'css': '#stage{height:100%;}',
  'js': js,
  'manifest': {'actions': [], 'events': []},
});

void main() {
  test('SVG namespaces and factories are ordinary Web source', () {
    for (final source in [
      'const svg=document.createElementNS("$_namespace","svg");'
          'document.getElementById("stage").append(svg);',
      "function icon(){var ns='$_namespace';"
          "var svg=document.createElementNS(ns,'svg');"
          "var path=document.createElementNS(ns,'path');"
          'svg.append(path);return svg;}icon();',
      'const uri="$_namespace";document.getElementById("stage").textContent=uri;',
      'const ns="$_namespace";document.createElementNS(ns,chooseNode());',
      'const doc=document;const create=doc.createElementNS.bind(doc);'
          'create("$_namespace","svg");',
    ]) {
      expect(
        SurfaceProjectValidator.diagnoseForPublicGame(_project(source)),
        isEmpty,
        reason: source,
      );
    }
  });

  test('resource-bearing SVG and dynamic attributes have no static dialect', () {
    for (final tag in ['script', 'image', 'foreignObject', 'use', 'a']) {
      final source = 'document.createElementNS("$_namespace","$tag");';
      expect(
        SurfaceProjectValidator.diagnoseForPublicGame(_project(source)),
        isEmpty,
        reason: tag,
      );
    }
    for (final source in [
      'const svg=document.createElementNS("$_namespace","svg");'
          'svg.setAttributeNS("http://www.w3.org/1999/xlink", "href",'
          '"https://example.com/sprite.svg#hero");',
      'const remote="https://example.com/asset.svg";'
          'document.getElementById("stage").setAttribute("src",remote);',
      r"""document.getElementById('stage').innerHTML='<svg><use href="https://example.com/sprite.svg#hero"></use></svg>';""",
    ]) {
      expect(
        SurfaceProjectValidator.diagnoseForPublicGame(_project(source)),
        isEmpty,
        reason: source,
      );
    }
  });

  test('inline SVG can be the complete HTML-only entry', () {
    final project = _project(
      '',
      html:
          '<svg xmlns="$_namespace" viewBox="0 0 100 100">'
          '<defs><linearGradient id="glow"><stop stop-color="blue"/>'
          '</linearGradient></defs><circle cx="50" cy="50" r="40" '
          'fill="url(#glow)"/></svg>',
    );
    expect(SurfaceProjectValidator.diagnoseForShow(project), isEmpty);
    expect(SurfaceProjectValidator.diagnoseForPublicGame(project), isEmpty);
  });
}
